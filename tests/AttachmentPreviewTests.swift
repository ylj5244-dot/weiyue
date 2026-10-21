import AppKit

@main struct AttachmentPreviewTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }
    static func main() {
        let viewport = NSRect(x: 20, y: 30, width: 800, height: 600)
        let portrait = NSSize(width: 1600, height: 2400)
        let landscape = NSSize(width: 2400, height: 1200)
        check(AttachmentPreviewKind(rawValue: "image") == .image, "Image route")
        check(AttachmentPreviewKind(rawValue: "video") == .video, "Video route")
        check(AttachmentPreviewKind(rawValue: "document") == nil && AttachmentPreviewKind(rawValue: "link") == nil, "Documents and links retain their existing route")
        check(near(AttachmentPreviewLayout.fitScale(portrait, in: viewport), 0.25), "Fit portrait without cropping")
        check(near(AttachmentPreviewLayout.fitScale(landscape, in: viewport), 1 / 3), "Fit landscape without cropping")
        check(AttachmentPreviewLayout.fitScale(NSSize(width: 100, height: 50), in: viewport) == 1, "Small image is not enlarged by default")
        let fit = AttachmentPreviewLayout.imageRect(portrait, in: viewport, scale: 0.25, offset: .zero)
        check(fit == NSRect(x: 220, y: 30, width: 400, height: 600), "Portrait is centered at its full aspect ratio")
        check(!AttachmentPreviewLayout.containsContent(NSPoint(x: 100, y: 300), imageRect: fit, viewport: viewport), "Side letterbox closes")
        check(AttachmentPreviewLayout.containsContent(NSPoint(x: 400, y: 300), imageRect: fit, viewport: viewport), "Image click stays open")
        let zoomed = AttachmentPreviewLayout.imageRect(landscape, in: viewport, scale: 1, offset: NSPoint(x: 9999, y: -9999))
        check(near(zoomed.minX, viewport.minX) && near(zoomed.maxY, viewport.maxY), "Panning cannot lose image beyond its edge")
        check(!AttachmentPreviewLayout.containsContent(NSPoint(x: 10, y: 100), imageRect: zoomed, viewport: viewport), "Clipped image outside the viewport still counts as background")
        check(AttachmentPreviewLayout.clampedScale(99, fit: 0.25) == 8, "Zoom has a finite upper bound")
        check(AttachmentPreviewLayout.clampedScale(0.001, fit: 0.02) == 0.02, "Large image can still fit below five percent")
        check(AttachmentPreviewLayout.clampedScale(.nan, fit: 0.25) == 0.25, "Nonfinite gesture cannot corrupt geometry")
        check(!AttachmentPreviewLayout.validSize(NSSize(width: 0, height: 900)), "Unknown video dimensions are not divided")
        check(!AttachmentPreviewLayout.validSize(NSSize(width: CGFloat.infinity, height: 900)), "Invalid video dimensions are rejected")
        let video = AttachmentPreviewLayout.fittedRect(NSSize(width: 1920, height: 1080), in: viewport)
        check(near(video.width / video.height, 16 / 9) && viewport.contains(video), "Video retains its aspect ratio within clickable surrounding space")
        let longSize = NSSize(width: 900, height: 6000)
        check(AttachmentPreviewLayout.isLongImage(longSize), "Tall screenshot is identified as long")
        check(!AttachmentPreviewLayout.isLongImage(portrait), "Ordinary portrait still fits entirely")
        check(!AttachmentPreviewLayout.isLongImage(NSSize(width: 100, height: 400)), "Small emoji is not a long screenshot")
        let longScale = AttachmentPreviewLayout.widthScale(longSize, in: viewport)
        let longRect = AttachmentPreviewLayout.imageRect(longSize, in: viewport, scale: longScale, offset: AttachmentPreviewLayout.topOffset(longSize, in: viewport, scale: longScale))
        check(near(longRect.width, viewport.width) && near(longRect.maxY, viewport.maxY), "Long preview opens at readable width aligned to the top")
        let scrolled = AttachmentPreviewLayout.imageRect(longSize, in: viewport, scale: longScale, offset: AttachmentPreviewLayout.topOffset(longSize, in: viewport, scale: longScale, sourceTop: 1500))
        check(near((scrolled.maxY - viewport.maxY) / longScale, 1500), "Resize preserves the reading position in original image coordinates")
        print("PASS: \(checks) attachment-preview route, fit, zoom, pan, content-hit and video-aspect assertions")
    }
}
