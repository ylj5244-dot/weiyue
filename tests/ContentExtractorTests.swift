import Foundation
import AppKit
import PDFKit
import CoreGraphics

@main struct ContentExtractorTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-extract-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); passed += 1
        }
        func rejects(_ url: URL, containing text: String) {
            do { _ = try ContentExtractor.extract(file: url); fatalError("Expected rejection: \(url.lastPathComponent)") }
            catch { check(error.localizedDescription.contains(text), "Unexpected error: \(error.localizedDescription)") }
        }
        let plain = folder.appendingPathComponent("notes.md")
        try Data("Hello world\n英文阅读记录 中文".utf8).write(to: plain)
        let p = try ContentExtractor.extract(file: plain, name: "Saved chat notes.md")
        check(p.text.contains("英文阅读记录"), "UTF-8 text lost")
        check(p.kind == "document" && p.method == "text" && !p.truncated, "plain text metadata")
        check((p.json["text"] as? String) == p.text && p.name == "Saved chat notes.md", "bridge JSON text/name")
        let utf16 = folder.appendingPathComponent("utf16.txt")
        try "Unicode 世界".data(using: .utf16)!.write(to: utf16)
        let decodedUTF16 = try ContentExtractor.extract(file: utf16)
        check(decodedUTF16.text.contains("世界"), "UTF-16 lost")
        let long = folder.appendingPathComponent("long.txt")
        try Data(String(repeating: "阅读", count: 60_000).utf8).write(to: long)
        let limited = try ContentExtractor.extract(file: long)
        check(limited.truncated && !limited.warnings.isEmpty && limited.text.count <= ContentExtractor.maximumCharacters, "truncation must be explicit")
        let unknown = folder.appendingPathComponent("table.xlsx")
        try Data("unknown".utf8).write(to: unknown)
        rejects(unknown, containing: "暂不支持")
        let empty = folder.appendingPathComponent("empty.txt")
        try Data().write(to: empty); rejects(empty, containing: "空")
        let binary = folder.appendingPathComponent("binary.txt")
        try Data([0, 255, 10, 0, 121, 0]).write(to: binary); rejects(binary, containing: "文本")
        let huge = folder.appendingPathComponent("huge.pdf")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let h = try FileHandle(forWritingTo: huge); try h.truncate(atOffset: UInt64(ContentExtractor.maximumInputBytes + 1)); try h.close()
        rejects(huge, containing: "过大")
        let corrupt = folder.appendingPathComponent("corrupt.pdf")
        try Data("broken PDF".utf8).write(to: corrupt); rejects(corrupt, containing: "PDF")
        let png = folder.appendingPathComponent("english.png")
        let image = drawTextImage("Read carefully before you reply.\nSave important messages for later.\n请保存重要聊天记录")
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        print("Testing image OCR"); fflush(stdout)
        let ocr = try ContentExtractor.extract(file: png)
        check(ocr.text.lowercased().contains("read carefully"), "image OCR: \(ocr.text)")
        check(ocr.text.contains("聊天记录"), "Chinese image OCR: \(ocr.text)")
        check(ocr.method == "ocr" && ocr.kind == "image" && !ocr.warnings.isEmpty, "OCR provenance required")
        let searchable = folder.appendingPathComponent("searchable.pdf")
        try makePDF(searchable, image: nil, pages: 2)
        let pdf = try ContentExtractor.extract(file: searchable)
        check(pdf.text.contains("Useful reading notes"), "searchable PDF text lost: \(pdf.text)")
        check(pdf.pageCount == 2 && pdf.processedPages == 2 && !pdf.truncated, "PDF page counts")
        let scanned = folder.appendingPathComponent("scanned.pdf")
        try makePDF(scanned, image: image, pages: 1)
        print("Testing scanned PDF OCR"); fflush(stdout)
        let scan = try ContentExtractor.extract(file: scanned)
        check(scan.text.lowercased().contains("read carefully"), "scanned PDF OCR: \(scan.text)")
        check(scan.method.contains("ocr"), "scan provenance")
        let manyPages = folder.appendingPathComponent("many-pages.pdf")
        try makePDF(manyPages, image: nil, pages: ContentExtractor.maximumPDFPages + 1)
        let partial = try ContentExtractor.extract(file: manyPages)
        check(partial.truncated && partial.processedPages == ContentExtractor.maximumPDFPages && partial.pageCount == ContentExtractor.maximumPDFPages + 1, "PDF cap provenance")
        let locked = folder.appendingPathComponent("locked.pdf")
        let doc = PDFDocument(url: searchable)!
        check(doc.write(to: locked, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "secret"]), "write encrypted PDF")
        rejects(locked, containing: "密码")
        let docx = folder.appendingPathComponent("notes.docx")
        try makeDOCX(docx, in: folder)
        let word = try ContentExtractor.extract(file: docx)
        check(word.text.contains("Document reading works") && word.text.contains("保留中文内容"), "DOCX paragraphs")
        let officeXML = folder.appendingPathComponent("odt-fixture")
        try FileManager.default.createDirectory(at: officeXML, withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:text><text:p>Open document content <text:span>with formatting</text:span></text:p></office:text></office:body></office:document-content>".utf8).write(to: officeXML.appendingPathComponent("content.xml"))
        let odt = folder.appendingPathComponent("notes.odt")
        try zip(odt, directory: officeXML, entries: ["content.xml"])
        let openDocument = try ContentExtractor.extract(file: odt)
        check(openDocument.text.contains("Open document content with formatting"), "ODT content")
        let corruptOffice = folder.appendingPathComponent("broken.docx")
        try Data("not a zip".utf8).write(to: corruptOffice); rejects(corruptOffice, containing: "格式")
        let bomb = folder.appendingPathComponent("oversized-office.docx")
        var bombData = try Data(contentsOf: docx)
        for i in 0..<(bombData.count - 46) where bombData[i..<(i+4)].elementsEqual([0x50, 0x4b, 0x01, 0x02]) {
            bombData.replaceSubrange((i+24)..<(i+28), with: [0, 0, 0, 0x40]); break
        }
        try bombData.write(to: bomb); rejects(bomb, containing: "过大")
        let hostile = folder.appendingPathComponent("entity.docx")
        try Data("<?xml version=\"1.0\"?><!DOCTYPE doc [<!ENTITY xxe SYSTEM \"file:///etc/hosts\">]><doc>&xxe;</doc>".utf8).write(to: folder.appendingPathComponent("word-fixture/word/document.xml"))
        try zip(hostile, directory: folder.appendingPathComponent("word-fixture"), entries: ["word/document.xml"])
        rejects(hostile, containing: "XML")
        let rtf = folder.appendingPathComponent("notes.rtf")
        try Data("{\\rtf1\\ansi Read this rich text document.}".utf8).write(to: rtf)
        let legacy = folder.appendingPathComponent("legacy.doc")
        let converter = Process(); converter.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        converter.arguments = ["-convert", "doc", "-output", legacy.path, plain.path]
        try converter.run(); converter.waitUntilExit(); check(converter.terminationStatus == 0, "legacy DOC fixture")
        let legacyText = try ContentExtractor.extract(file: legacy)
        check(legacyText.text.contains("Hello world") && legacyText.text.contains("中文"), "legacy DOC conversion")
        let badImage = folder.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: badImage); rejects(badImage, containing: "图片")
        let richText = try ContentExtractor.extract(file: rtf)
        check(richText.text.contains("rich text"), "RTF conversion")
        print("PASS: \(passed) content extraction assertions (UTF-8/16, metadata, image OCR, PDF text/scans/limits/password, DOCX/DOC/ODT/RTF, XML entity/ZIP expansion guards, invalid/oversized files)")
    }
    static func drawTextImage(_ text: String) -> CGImage {
        let image = NSImage(size: NSSize(width: 1400, height: 420))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1400, height: 420).fill()
        (text as NSString).draw(in: NSRect(x: 55, y: 120, width: 1300, height: 230), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    static func makePDF(_ url: URL, image: CGImage?, pages: Int) throws {
        var rect = CGRect(x: 0, y: 0, width: 700, height: 500)
        guard let context = CGContext(url as CFURL, mediaBox: &rect, nil) else { fatalError("PDF context") }
        for i in 0..<pages {
            context.beginPDFPage(nil)
            if let image { context.draw(image, in: CGRect(x: 0, y: 100, width: 700, height: 210)) }
            else {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                ("Useful reading notes. Page \(i + 1)." as NSString).draw(at: NSPoint(x: 40, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
                NSGraphicsContext.restoreGraphicsState()
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
    static func makeDOCX(_ url: URL, in folder: URL) throws {
        let package = folder.appendingPathComponent("word-fixture")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("word"), withIntermediateDirectories: true)
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>Document reading works</w:t></w:r></w:p><w:p><w:r><w:t>保留中文内容</w:t></w:r></w:p></w:body></w:document>"
        try Data(xml.utf8).write(to: package.appendingPathComponent("word/document.xml"))
        try zip(url, directory: package, entries: ["word/document.xml"])
    }
    static func zip(_ url: URL, directory: URL, entries: [String]) throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); task.arguments = ["-q", url.path] + entries; task.currentDirectoryURL = directory
        try task.run(); task.waitUntilExit(); precondition(task.terminationStatus == 0)
    }
}
