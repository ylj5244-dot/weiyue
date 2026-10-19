import Foundation
import AppKit
import PDFKit
import ImageIO

@main struct DirectInputTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
    static func assertError(_ block: () throws -> Void, contains: String) {
        do { try block(); fatalError("Expected error: " + contains) } catch { check(error.localizedDescription.contains(contains), "Actionable error: " + error.localizedDescription) }
    }
    static func png() -> Data {
        let image = NSImage(size: NSSize(width: 600, height: 300))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 300).fill()
        ("Synthetic direct-reading sample" as NSString).draw(at: NSPoint(x: 30, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black]); image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    static func pdf(_ url: URL, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages { context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0.3, alpha: 1)); context.fill(CGRect(x: 10, y: 10, width: 200, height: 300)); context.endPDFPage() }
        context.closePDF()
    }
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-direct-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("sample.png"), document = folder.appendingPathComponent("sample.pdf")
        let rawImage = png(); try rawImage.write(to: image); pdf(document, pages: 2)
        let visual: [String: Any] = ["images": true, "pdf": false], full: [String: Any] = ["images": true, "pdf": true]
        let imageInfo = try DirectInput.prepare(file: image, name: "sample.png", capabilities: visual)
        check(imageInfo["mode"] as? String == "direct-image" && imageInfo["processedPages"] as? Int == 1, "Raw image metadata")
        check(!String(describing: imageInfo).contains("base64"), "Metadata must never send base64 to JS or persistent state")
        let imageParts = try DirectInput.parts(file: image, name: "sample.png", capabilities: visual)
        let dataURL = (imageParts.first?["image_url"] as? [String: String])?["url"] ?? ""
        check(imageParts.count == 1 && dataURL == "data:image/png;base64," + rawImage.base64EncodedString(), "Compact PNG text images preserved exactly")
        let pdfInfo = try DirectInput.prepare(file: document, name: "sample.pdf", capabilities: full)
        check(pdfInfo["mode"] as? String == "direct-pdf" && pdfInfo["pageCount"] as? Int == 2, "Provider native PDF mode")
        let pdfParts = try DirectInput.parts(file: document, name: "sample.pdf", capabilities: full)
        let file = pdfParts.first?["file"] as? [String: String]
        check(file?["filename"] == "sample.pdf" && file?["file_data"]?.hasPrefix("data:application/pdf;base64,") == true, "OpenAI file content format")
        let pageInfo = try DirectInput.prepare(file: document, name: "sample.pdf", capabilities: visual)
        check(pageInfo["mode"] as? String == "pdf-pages" && pageInfo["processedPages"] as? Int == 2, "Vision-only provider reads all page images")
        check((pageInfo["warnings"] as? [String])?.first?.contains("没有运行本地 OCR") == true, "Mode description discloses no OCR")
        let pageParts = try DirectInput.parts(file: document, name: "sample.pdf", capabilities: visual)
        check(pageParts.count == 4 && (pageParts[0]["text"] as? String)?.contains("第 1/2 页") == true && (pageParts[2]["text"] as? String)?.contains("第 2/2 页") == true, "Every page labeled without truncation")
        for item in pageParts.filter({ $0["type"] as? String == "image_url" }) {
            let url = (item["image_url"] as! [String: String])["url"]!, raw = Data(base64Encoded: String(url.split(separator: ",", maxSplits: 1)[1]))!
            let source = CGImageSourceCreateWithData(raw as CFData, nil)!, cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            check(max(cgImage.width, cgImage.height) == 1800, "PDF page rendering has bounded size and decodable JPEG")
        }
        let large = folder.appendingPathComponent("13pages.pdf"); pdf(large, pages: 13)
        assertError({ _ = try DirectInput.prepare(file: large, name: "large.pdf", capabilities: visual) }, contains: "最多 12 页")
        let big = folder.appendingPathComponent("large.png"); try Data(repeating: 0, count: DirectInput.maxFileBytes + 1).write(to: big)
        assertError({ _ = try DirectInput.prepare(file: big, name: "large.png", capabilities: visual) }, contains: "25 MB")
        let text = folder.appendingPathComponent("sample.docx"); try Data("synthetic text".utf8).write(to: text)
        assertError({ _ = try DirectInput.prepare(file: text, name: "sample.docx", capabilities: visual) }, contains: "本地提取文字")
        assertError({ _ = try DirectInput.parts(file: image, name: "sample.png", capabilities: [:]) }, contains: "不支持直接读图")
        assertError({ _ = try DirectInput.parts(file: document, name: "sample.pdf", capabilities: [:]) }, contains: "不能直接读取")
        assertError({ _ = try DirectInput.prepare(file: URL(string: "https://example.invalid/image.png")!, name: "x", capabilities: visual) }, contains: "本机")
        assertError({ _ = try DirectInput.prepare(file: folder, name: "x", capabilities: visual) }, contains: "普通")
        print("PASS: \(checks) direct image/PDF metadata, byte preservation, real PDF rendering, explicit page/input limits and unsupported-format assertions (local synthetic fixtures)")
    }
}
