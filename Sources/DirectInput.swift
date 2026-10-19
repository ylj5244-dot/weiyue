import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Raw file preparation is local. Only `parts` constructs the outbound content,
// and callers must run it off the main thread after the user starts an AI request.
// This module never performs OCR, network requests, or writes document contents.
enum DirectInput {
    static let maxFileBytes = 25 * 1024 * 1024
    static let maxEncodedBytes = 35_000_000
    static let maxVisualPDFPages = 12
    static let maxDirectPDFPages = 50
    private static let imageEdge = 2400
    private static let pdfEdge = 1800
    private static let maxImagePixels: Double = 120_000_000

    private struct FileInfo {
        let data: Data
        let name: String
        let image: CGImageSource?
        let pdf: CGPDFDocument?
        let metadata: [String: Any]
    }
    static func prepare(file: URL, name: String, capabilities: [String: Any]) throws -> [String: Any] {
        try inspect(file: file, name: name, capabilities: capabilities).metadata
    }
    static func parts(file: URL, name: String, capabilities: [String: Any]) throws -> [[String: Any]] {
        let info = try inspect(file: file, name: name, capabilities: capabilities)
        switch info.metadata["mode"] as? String {
        case "direct-pdf":
            return [["type": "file", "file": ["filename": info.name.lowercased().hasSuffix(".pdf") ? info.name : info.name + ".pdf",
                "file_data": try encoded(info.data, mime: "application/pdf")]]]
        case "pdf-pages":
            guard let pdf = info.pdf else { throw ReaderError.message("PDF 文档无法打开。") }
            var output: [[String: Any]] = [], encodedBytes = 0
            for index in 1...pdf.numberOfPages {
                guard let page = pdf.page(at: index) else { throw ReaderError.message("PDF 第 \(index) 页无法读取，未发送不完整文档。") }
                let image = try render(page)
                let jpeg = try encode(image, type: UTType.jpeg.identifier, quality: 0.9)
                let value = try encoded(jpeg, mime: "image/jpeg"); encodedBytes += value.utf8.count
                guard encodedBytes <= maxEncodedBytes else { throw ReaderError.message("PDF 页面图片合计过大，请拆分文档后分别发送。") }
                output.append(["type": "text", "text": "以下是文件「\(info.name)」第 \(index)/\(pdf.numberOfPages) 页的原始页面图片。请按页码引用；不要将看不清的内容猜成事实。"])
                output.append(["type": "image_url", "image_url": ["url": value, "detail": "auto"]])
            }
            return output
        case "direct-image":
            guard let source = info.image else { throw ReaderError.message("图片无法解码。") }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let originalType = CGImageSourceGetType(source) as String?
            let frameCount = CGImageSourceGetCount(source)
            // Keep compact PNG screenshots exactly, retaining legible text and alpha.
            if originalType == UTType.png.identifier, max(width, height) <= Double(imageEdge), frameCount == 1, info.data.count <= 8_000_000 {
                return [["type": "image_url", "image_url": ["url": try encoded(info.data, mime: "image/png"), "detail": "auto"]]]
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: imageEdge, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ReaderError.message("图片无法转换为模型支持的格式。可重新保存为 PNG 或 JPEG 后重试。")
            }
            let jpeg = try encode(try flatten(thumbnail), type: UTType.jpeg.identifier, quality: 0.92)
            return [["type": "image_url", "image_url": ["url": try encoded(jpeg, mime: "image/jpeg"), "detail": "auto"]]]
        default: throw ReaderError.message("此文件尚未准备好直接交给模型。")
        }
    }
    private static func inspect(file: URL, name: String, capabilities: [String: Any]) throws -> FileInfo {
        guard file.isFileURL else { throw ReaderError.message("仅能读取已保存到本机的资料。") }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ReaderError.message("请选择普通图片或文档文件。") }
        guard let byteCount = attributes[.size] as? NSNumber, byteCount.int64Value > 0, byteCount.int64Value <= Int64(maxFileBytes) else {
            throw ReaderError.message("文件为空或超过 25 MB，请拆分或压缩后重试。")
        }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maxFileBytes else { throw ReaderError.message("文件为空或超过 25 MB，未发送。") }
        let cleanName = String((name.isEmpty ? file.lastPathComponent : (name as NSString).lastPathComponent).prefix(240))
        let canImage = capabilities["images"] as? Bool == true, canPDF = capabilities["pdf"] as? Bool == true
        let pdfHeader = data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
        if pdfHeader {
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else { throw ReaderError.message("PDF 文档已损坏或无法打开。") }
            guard !pdf.isEncrypted || pdf.isUnlocked else { throw ReaderError.message("此 PDF 有密码保护，请先导出解锁后的副本。") }
            guard pdf.allowsCopying else { throw ReaderError.message("此 PDF 限制内容读取，请使用有读取权限的副本。") }
            guard canPDF || canImage else { throw ReaderError.message("当前模型不能直接读取 PDF 或页面图片。请切换支持视觉的模型，或选择「本地提取文字」。") }
            let limit = canPDF ? maxDirectPDFPages : maxVisualPDFPages
            guard (1...limit).contains(pdf.numberOfPages) else {
                throw ReaderError.message("此 PDF 共 \(pdf.numberOfPages) 页；\(canPDF ? "文件直读" : "页面直读")一次最多 \(limit) 页，请拆分后发送。不会只读前几页并冒充完整文档。")
            }
            let warnings = canPDF ? [String]() : ["当前模型通过原始页面图片读取 PDF，保留版式、图表与扫描文字；没有运行本地 OCR。"]
            return FileInfo(data: data, name: cleanName, image: nil, pdf: pdf,
                metadata: ["mode": canPDF ? "direct-pdf" : "pdf-pages", "name": cleanName,
                    "mimeType": "application/pdf", "pageCount": pdf.numberOfPages,
                    "processedPages": pdf.numberOfPages, "warnings": warnings, "sizeBytes": data.count])
        }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0 {
            guard canImage else { throw ReaderError.message("当前模型不支持直接读图，请选择视觉模型（例如 DeepSeek Flash），或选择「本地提取文字」。") }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            guard width > 0, height > 0, width.isFinite, height.isFinite, width * height <= maxImagePixels else {
                throw ReaderError.message("图片尺寸无效或超过 1.2 亿像素，请缩小后重试。")
            }
            var warnings: [String] = []
            let count = CGImageSourceGetCount(source)
            if count > 1 { warnings.append("此图片有 \(count) 帧/页，直接读图仅发送第一帧；若需完整内容，请分别导出各帧/页。") }
            if max(width, height) > Double(imageEdge) { warnings.append("图片长边会缩至 \(imageEdge) 像素以减少等待；细小文字可裁剪后单独发送。") }
            let type = CGImageSourceGetType(source) as String?
            let mime = type == UTType.png.identifier && count == 1 && max(width, height) <= Double(imageEdge) && data.count <= 8_000_000 ? "image/png" : "image/jpeg"
            return FileInfo(data: data, name: cleanName, image: source, pdf: nil,
                metadata: ["mode": "direct-image", "name": cleanName, "mimeType": mime, "pageCount": count,
                    "processedPages": 1, "warnings": warnings, "sizeBytes": data.count])
        }
        throw ReaderError.message("直接文件读取支持图片和 PDF。Word 等文档可选择「本地提取文字」（正文读取，无需 OCR），或导出为 PDF 后交给模型。")
    }
    private static func encoded(_ data: Data, mime: String) throws -> String {
        guard data.count <= maxFileBytes else { throw ReaderError.message("转换后的文件超过 25 MB，请缩小或拆分材料。") }
        let result = "data:\(mime);base64," + data.base64EncodedString()
        guard result.utf8.count <= maxEncodedBytes else { throw ReaderError.message("编码后的文件过大，请压缩或拆分后重试。") }
        return result
    }
    private static func encode(_ image: CGImage, type: String, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw ReaderError.message("图片编码器不可用。") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ReaderError.message("图片转换失败。") }
        return data as Data
    }
    private static func flatten(_ image: CGImage) throws -> CGImage {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ReaderError.message("图片转换内存不足。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ReaderError.message("图片转换失败。") }; return result
    }
    private static func render(_ page: CGPDFPage) throws -> CGImage {
        let rect = page.getBoxRect(.mediaBox)
        guard rect.width.isFinite, rect.height.isFinite, (0.1...1_000_000).contains(rect.width), (0.1...1_000_000).contains(rect.height) else { throw ReaderError.message("PDF 页面尺寸无效。") }
        let rotated = abs(page.rotationAngle) % 180 == 90
        let sourceWidth = rotated ? rect.height : rect.width, sourceHeight = rotated ? rect.width : rect.height
        let scale = Double(pdfEdge) / max(sourceWidth, sourceHeight)
        let width = max(1, Int(ceil(sourceWidth * scale))), height = max(1, Int(ceil(sourceHeight * scale)))
        guard let color = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ReaderError.message("PDF 页面渲染内存不足。") }
        let output = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(output)
        context.interpolationQuality = .high
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: output, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ReaderError.message("PDF 页面渲染失败。") }; return image
    }
}
