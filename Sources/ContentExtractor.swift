import Foundation
import AppKit
import Vision
import PDFKit
import ImageIO
import Darwin

struct ExtractedContent {
    let text: String
    let name: String
    let kind: String
    let method: String
    let pageCount: Int
    let processedPages: Int
    let truncated: Bool
    let warnings: [String]

    var json: [String: Any] {
        ["text": text, "name": name, "kind": kind, "method": method,
         "pageCount": pageCount, "processedPages": processedPages,
         "truncated": truncated, "warnings": warnings]
    }
}

/// Local text extraction only. The caller decides whether to send the resulting text to its AI service.
/// Run on a background queue: OCR and document conversion are deliberately synchronous and bounded.
enum ContentExtractor {
    static let maximumInputBytes = 25 * 1024 * 1024
    static let maximumCharacters = 80_000
    static let maximumPDFPages = 50
    static let maximumOCRPages = 12
    private static let maximumImageDimension = 2400
    private static let maximumXMLBytes = 8 * 1024 * 1024
    private static let ocrWarning = "图片文字由本机 OCR 识别，可能存在错字或遗漏；请对照原图核实。仅提取文字，不代表已理解图表、照片或版式。"
    private static let documentWarning = "已提取可读取的正文；图片、图表、批注、页眉页脚及复杂排版可能未包含，请对照原文。"
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"]
    private static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "json", "log", "yaml", "yml", "xml"]

    static func extract(file: URL, name: String? = nil) throws -> ExtractedContent {
        guard file.isFileURL else { throw ReaderError.message("请先把文件保存到本机，再读取内容。") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ReaderError.message("请选择一个文档或图片文件，不能直接读取文件夹。") }
        guard let size = values.fileSize, size > 0 else { throw ReaderError.message("文件为空，没有可读取的内容。") }
        guard size <= maximumInputBytes else { throw ReaderError.message("文件过大：本地解读单次支持 25 MB 以内的文件，请拆分或压缩后重试。") }
        let displayName = (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : file.lastPathComponent)
        let ext = file.pathExtension.lowercased()
        if ext == "pdf" { return try extractPDF(file: file, name: displayName) }
        if imageExtensions.contains(ext) { return try extractImage(file: file, name: displayName) }
        if textExtensions.contains(ext) {
            let text = try decodeText(Data(contentsOf: file, options: .mappedIfSafe))
            return try finish(text, name: displayName, kind: "document", method: "text")
        }
        if ext == "docx" || ext == "odt" {
            let entry = ext == "docx" ? "word/document.xml" : "content.xml"
            try validateZIP(file, requiredEntry: entry)
            let output = try runProcess("/usr/bin/unzip", ["-p", file.path, entry], limit: maximumXMLBytes, seconds: 15)
            guard !output.truncated else { throw ReaderError.message("文档解压后的正文过大，请拆分文档后重试。") }
            let delegate = OfficeTextParser(kind: ext, limit: maximumCharacters)
            // Disable external entities and reject declarations, including internal entity expansion.
            guard let header = String(data: output.data, encoding: .utf8), !header.contains("\u{0000}"), !header.localizedCaseInsensitiveContains("<!DOCTYPE"), !header.localizedCaseInsensitiveContains("<!ENTITY") else {
                throw ReaderError.message("文档包含不受支持的 XML 声明，请另存为 PDF 或纯文本后重试。")
            }
            let parser = XMLParser(data: output.data)
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse() || delegate.truncated else { throw ReaderError.message("文档内容损坏或格式不完整，请在原应用中重新另存后重试。") }
            return try finish(delegate.text, name: displayName, kind: "document", method: "office-text", truncated: delegate.truncated, warnings: [documentWarning])
        }
        if ["doc", "rtf"].contains(ext) {
            // No shell, scripts, macros, or subsidiary resources are executed or loaded.
            let output = try runProcess("/usr/bin/textutil", ["-convert", "txt", "-stdout", "-encoding", "UTF-8", "-format", ext, "-noload", "-nostore", "--", file.path], limit: 1024 * 1024, seconds: 15)
            let text = String(decoding: output.data, as: UTF8.self)
            return try finish(text, name: displayName, kind: "document", method: "office-text", truncated: output.truncated, warnings: [documentWarning])
        }
        throw ReaderError.message("暂不支持读取这种文件（\(ext.isEmpty ? "无扩展名" : ext.uppercased())）。目前支持图片、PDF、TXT、Markdown、CSV、JSON、DOCX、DOC、RTF 和 ODT；表格或演示文稿可先导出为 PDF。")
    }

    private static func finish(_ source: String, name: String, kind: String, method: String,
                               pages: Int = 1, processed: Int = 1, truncated: Bool = false,
                               warnings: [String] = []) throws -> ExtractedContent {
        let clean = source.replacingOccurrences(of: "\u{0000}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ReaderError.message(kind == "image" ? "图片中没有识别到清晰文字。请换用更清晰、完整的原图。" : "没有提取到可读取的文字。文档可能为空、受保护，或仅含无法识别的图片。") }
        let isTruncated = truncated || clean.count > maximumCharacters
        var notes = warnings
        if isTruncated { notes.append("本次仅提取部分内容（最多 \(maximumCharacters.formatted()) 字、\(maximumPDFPages) 页，扫描页最多 \(maximumOCRPages) 页）。解读仅针对已提取部分，请拆分文档继续读取。") }
        return ExtractedContent(text: String(clean.prefix(maximumCharacters)), name: name, kind: kind, method: method,
                                pageCount: pages, processedPages: processed, truncated: isTruncated, warnings: notes)
    }

    private static func decodeText(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(3))
        let text: String?
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) }
        guard let result = text, !result.contains("\u{0000}") else { throw ReaderError.message("无法读取文本编码，或该文件实际是二进制文件。请另存为 UTF-8 或 UTF-16 文本后重试。") }
        let controls = result.unicodeScalars.prefix(10_000).filter { $0.value < 32 && ![9, 10, 13].contains($0.value) }.count
        guard controls == 0 else { throw ReaderError.message("该文件不是可读取的纯文本，请另存为 UTF-8 文本或 PDF 后重试。") }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
    }

    private static func extractImage(file: URL, name: String) throws -> ExtractedContent {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ReaderError.message("图片无法解码，可能已损坏或格式不受系统支持。请转为 PNG 或 JPEG 后重试。")
        }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            guard width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 120_000_000 else {
                throw ReaderError.message("图片尺寸过大，请缩小至 1.2 亿像素以内后再识别。")
            }
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maximumImageDimension,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReaderError.message("图片无法解码，请尝试保存原图，或转为 PNG/JPEG。")
        }
        var warnings = [ocrWarning]
        let count = CGImageSourceGetCount(source)
        if count > 1 { warnings.append("该图片含 \(count) 帧或页面，本次仅识别第一页。") }
        let text = try recognize(image, seconds: 45)
        return try finish(text, name: name, kind: "image", method: "ocr", pages: max(1, count), processed: 1, truncated: count > 1, warnings: warnings)
    }

    private static func extractPDF(file: URL, name: String) throws -> ExtractedContent {
        guard let document = PDFDocument(url: file) else { throw ReaderError.message("PDF 无法打开，文件可能损坏。请在预览中检查或重新保存后重试。") }
        guard !document.isLocked else { throw ReaderError.message("PDF 需要密码。请先在预览中解锁，并导出不带密码的副本后再读取。") }
        guard document.allowsCopying else { throw ReaderError.message("这个 PDF 禁止复制文字。请取得可复制的文档副本后再读取。") }
        let total = document.pageCount
        guard total > 0 else { throw ReaderError.message("PDF 没有可读取的页面。") }
        let deadline = ProcessInfo.processInfo.systemUptime + 55
        var chunks: [String] = [], used = 0, processed = 0, ocrPages = 0, missing = 0
        var truncated = total > maximumPDFPages
        var notes = [documentWarning]
        for index in 0..<min(total, maximumPDFPages) {
            if ProcessInfo.processInfo.systemUptime >= deadline { truncated = true; notes.append("本次读取达到时间上限，剩余页面尚未处理。"); break }
            guard let page = document.page(at: index) else { missing += 1; processed += 1; continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                guard ocrPages < maximumOCRPages else { truncated = true; notes.append("已达到扫描页面识别上限，剩余页面尚未处理。"); break }
                ocrPages += 1
                guard let image = render(page) else { missing += 1; processed += 1; continue }
                do { text = try recognize(image, seconds: min(20, max(1, deadline - ProcessInfo.processInfo.systemUptime))) }
                catch {
                    // Keep useful earlier pages, but never imply a failing page was read.
                    if chunks.isEmpty { throw error }
                    truncated = true; notes.append("第 \(index + 1) 页识别未完成，已保留此前成功提取的内容。"); break
                }
            }
            processed += 1
            if text.isEmpty { missing += 1; continue }
            let chunk = "[第 \(index + 1) 页]\n" + text
            let remaining = maximumCharacters - used
            if chunk.count > remaining { chunks.append(String(chunk.prefix(max(0, remaining)))); truncated = true; break }
            chunks.append(chunk); used += chunk.count + 2
        }
        if ocrPages > 0 { notes.append(ocrWarning) }
        if missing > 0 { notes.append("\(missing) 页未提取到文字（可能为空白、图片不清晰或无法渲染）；这些页面未纳入解读。"); truncated = true }
        if processed < total { truncated = true }
        return try finish(chunks.joined(separator: "\n\n"), name: name, kind: "document", method: ocrPages > 0 ? "pdf-text+ocr" : "pdf-text",
                          pages: total, processed: processed, truncated: truncated, warnings: notes)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(3, CGFloat(maximumImageDimension) / max(bounds.width, bounds.height))
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private static func recognize(_ image: CGImage, seconds: TimeInterval) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let cancellation = DispatchWorkItem { request.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: cancellation)
        defer { cancellation.cancel() }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { throw ReaderError.message("文字识别未完成（图片复杂、超时或系统识别失败）。请缩小图片或拆分扫描文档后重试。") }
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private struct ProcessOutput { let data: Data; let truncated: Bool }
    private static func runProcess(_ executable: String, _ arguments: [String], limit: Int, seconds: TimeInterval) throws -> ProcessOutput {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
        let outFD = stdout.fileHandleForReading.fileDescriptor, errFD = stderr.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK); _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
        defer { try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
        do { try process.run() } catch { throw ReaderError.message("本机文档转换工具无法启动，请将文件另存为 PDF 或纯文本后重试。") }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var data = Data(), truncated = false, buffer = [UInt8](repeating: 0, count: 16_384)
        func drain(_ fd: Int32, keep: Bool) {
            for _ in 0..<64 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if count <= 0 { break }
                if keep {
                    let available = max(0, limit - data.count)
                    data.append(contentsOf: buffer.prefix(min(count, available)))
                    if count > available { truncated = true; break }
                }
            }
        }
        while process.isRunning {
            drain(outFD, keep: true); drain(errFD, keep: false)
            if truncated { _ = Darwin.kill(process.processIdentifier, SIGKILL); break }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                throw ReaderError.message("文档读取超过 15 秒，已停止处理。请拆分文档，或另存为 PDF/纯文本后重试。")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit(); drain(outFD, keep: true); drain(errFD, keep: false)
        guard process.terminationStatus == 0 || truncated else { throw ReaderError.message("文档无法转换，可能损坏、加密或格式不符。请在原应用中另存为 PDF/纯文本后重试。") }
        return ProcessOutput(data: data, truncated: truncated)
    }

    /// Inspect central-directory sizes before invoking unzip; ZIP64, very large archives and ambiguous duplicate bodies are rejected.
    private static func validateZIP(_ file: URL, requiredEntry: String) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 22 else { throw ReaderError.message("文档格式不完整，请重新保存后重试。") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if u32(offset) == 0x06054b50 && offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10) else { throw ReaderError.message("文档不是完整的 DOCX/ODT 文件，请重新保存后重试。") }
        let count = u16(end + 10), directorySize = u32(end + 12), directoryOffset = u32(end + 16)
        guard count < 10_000, directoryOffset < end, directorySize <= end - directoryOffset else { throw ReaderError.message("文档结构过大或不受支持，请另存为 PDF 后重试。") }
        var cursor = directoryOffset, expanded = 0, matches = 0
        for _ in 0..<count {
            guard cursor <= end - 46, u32(cursor) == 0x02014b50 else { throw ReaderError.message("文档目录损坏，请重新保存后重试。") }
            let flags = u16(cursor + 8), unpacked = u32(cursor + 24), nameLength = u16(cursor + 28), extra = u16(cursor + 30), comment = u16(cursor + 32)
            let next = cursor + 46 + nameLength + extra + comment
            guard flags & 1 == 0 else { throw ReaderError.message("文档需要密码，请先解锁并导出副本后再读取。") }
            guard next <= end, unpacked != 0xffff_ffff else { throw ReaderError.message("文档使用了不支持的大型压缩格式，请另存为 PDF 后重试。") }
            expanded += unpacked
            guard expanded <= 80 * 1024 * 1024 else { throw ReaderError.message("文档解压后过大，请移除大型附件或拆分文档后重试。") }
            let entry = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if entry == requiredEntry {
                matches += 1
                guard unpacked <= maximumXMLBytes else { throw ReaderError.message("文档正文过大，请拆分文档后重试。") }
            }
            cursor = next
        }
        guard matches == 1 else { throw ReaderError.message("文档缺少有效正文或存在重复正文，请在原应用中重新保存后重试。") }
    }
}

private final class OfficeTextParser: NSObject, XMLParserDelegate {
    let kind: String, limit: Int
    var text = "", truncated = false
    private var textDepth = 0
    private var bodyDepth = 0
    private var characterCount = 0
    init(kind: String, limit: Int) { self.kind = kind; self.limit = limit }
    private func append(_ value: String, parser: XMLParser) {
        let remaining = limit - characterCount
        if value.count > remaining { text += String(value.prefix(max(0, remaining))); truncated = true; parser.abortParsing() }
        else { text += value; characterCount += value.count }
    }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if kind == "docx" {
            if element == "t" { textDepth += 1 }
            if element == "tab" { append("\t", parser: parser) }
            if ["br", "cr"].contains(element) { append("\n", parser: parser) }
        } else {
            if element == "body" { bodyDepth += 1 }
            if bodyDepth > 0 && ["p", "h"].contains(element) { textDepth += 1 }
            if bodyDepth > 0 && element == "tab" { append("\t", parser: parser) }
            if bodyDepth > 0 && element == "line-break" { append("\n", parser: parser) }
            if bodyDepth > 0 && element == "s" { append(" ", parser: parser) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if textDepth > 0 { append(string, parser: parser) } }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if kind == "docx" {
            if element == "t" { textDepth = max(0, textDepth - 1) }
            if element == "p" { append("\n", parser: parser) }
            if element == "tc" { append("\t", parser: parser) }
        } else {
            if bodyDepth > 0 && ["p", "h"].contains(element) { textDepth = max(0, textDepth - 1); append("\n", parser: parser) }
            if element == "body" { bodyDepth = max(0, bodyDepth - 1) }
        }
    }
}
