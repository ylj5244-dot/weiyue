import AppKit
import AVKit
import AVFoundation

enum AttachmentPreviewKind: String { case image, video }

// Shared by drawing, hit testing and the offline geometry tests.
enum AttachmentPreviewLayout {
    static func validSize(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
    static func fitScale(_ size: NSSize, in viewport: NSRect) -> CGFloat {
        guard validSize(size), validSize(viewport.size) else { return 1 }
        return min(1, viewport.width / size.width, viewport.height / size.height)
    }
    static func clampedScale(_ requested: CGFloat, fit: CGFloat) -> CGFloat {
        guard requested.isFinite else { return fit }
        return min(8, max(min(0.05, fit), requested))
    }
    static func clampedOffset(_ offset: NSPoint, size: NSSize, viewport: NSRect, scale: CGFloat) -> NSPoint {
        let xLimit = max(0, (size.width * scale - viewport.width) / 2)
        let yLimit = max(0, (size.height * scale - viewport.height) / 2)
        return NSPoint(x: min(xLimit, max(-xLimit, offset.x)), y: min(yLimit, max(-yLimit, offset.y)))
    }
    static func imageRect(_ size: NSSize, in viewport: NSRect, scale: CGFloat, offset: NSPoint) -> NSRect {
        let offset = clampedOffset(offset, size: size, viewport: viewport, scale: scale)
        let scaled = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: viewport.midX - scaled.width / 2 + offset.x,
                      y: viewport.midY - scaled.height / 2 + offset.y, width: scaled.width, height: scaled.height)
    }
    static func containsContent(_ point: NSPoint, imageRect: NSRect, viewport: NSRect) -> Bool {
        viewport.contains(point) && imageRect.contains(point)
    }
    static func fittedRect(_ size: NSSize, in viewport: NSRect) -> NSRect {
        guard validSize(size), validSize(viewport.size) else { return viewport }
        let scale = min(viewport.width / size.width, viewport.height / size.height)
        return imageRect(size, in: viewport, scale: scale, offset: .zero)
    }
}

final class AttachmentPreviewWindow: NSWindow {
    var onEscape: (() -> Void)?
    // Intercept before delivery to AVKit or a focused toolbar button.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { onEscape?(); return }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class AttachmentPreviewBackdrop: NSView {
    var onClose: (() -> Void)?
    var onLayout: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func layout() { super.layout(); onLayout?() }
}

final class AttachmentImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    let imageSize: NSSize
    private(set) var zoomScale: CGFloat = 1
    private(set) var fitsWindow = true
    private var offset = NSPoint.zero
    private var dragPoint: NSPoint?
    var onClose: (() -> Void)?
    var onScaleChanged: ((CGFloat, Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    var imageRect: NSRect { AttachmentPreviewLayout.imageRect(imageSize, in: bounds, scale: zoomScale, offset: offset) }

    init(image: NSImage) {
        self.image = image
        // Use the original representation rather than the 960 px message thumbnail.
        let pixels = image.representations.first { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
        let pixelSize = pixels.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        // NSImage's size follows orientation; preserve that aspect ratio when metadata rotates a photo.
        let rotated = (image.size.width > image.size.height) != (pixelSize.width > pixelSize.height)
        imageSize = rotated ? NSSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("attachment-preview-image")
        setAccessibilityLabel("图片预览，可捏合缩放，放大后拖动；点击空白或按 Esc 关闭")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitsWindow { zoomScale = AttachmentPreviewLayout.fitScale(imageSize, in: bounds); offset = .zero }
        else { offset = AttachmentPreviewLayout.clampedOffset(offset, size: imageSize, viewport: bounds, scale: zoomScale) }
        onScaleChanged?(zoomScale, fitsWindow); needsDisplay = true
    }
    func setZoom(_ requested: CGFloat, anchor: NSPoint? = nil) {
        let next = AttachmentPreviewLayout.clampedScale(requested, fit: AttachmentPreviewLayout.fitScale(imageSize, in: bounds))
        let anchor = anchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let relative = NSPoint(x: anchor.x - bounds.midX, y: anchor.y - bounds.midY)
        let ratio = next / zoomScale
        offset = NSPoint(x: relative.x - (relative.x - offset.x) * ratio, y: relative.y - (relative.y - offset.y) * ratio)
        zoomScale = next; fitsWindow = false
        offset = AttachmentPreviewLayout.clampedOffset(offset, size: imageSize, viewport: bounds, scale: zoomScale)
        onScaleChanged?(zoomScale, fitsWindow); needsDisplay = true; window?.invalidateCursorRects(for: self)
    }
    func fitImage() {
        fitsWindow = true; offset = .zero; zoomScale = AttachmentPreviewLayout.fitScale(imageSize, in: bounds)
        onScaleChanged?(zoomScale, fitsWindow); needsDisplay = true; window?.invalidateCursorRects(for: self)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard AttachmentPreviewLayout.containsContent(point, imageRect: imageRect, viewport: bounds) else { onClose?(); return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { if fitsWindow { setZoom(1, anchor: point) } else { fitImage() }; return }
        dragPoint = point; NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previous = dragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        offset = AttachmentPreviewLayout.clampedOffset(NSPoint(x: offset.x + point.x - previous.x, y: offset.y + point.y - previous.y), size: imageSize, viewport: bounds, scale: zoomScale)
        dragPoint = point; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { dragPoint = nil; window?.invalidateCursorRects(for: self) }
    override func magnify(with event: NSEvent) { setZoom(zoomScale * max(0.1, 1 + event.magnification), anchor: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            setZoom(zoomScale * exp(-event.scrollingDeltaY * 0.015), anchor: convert(event.locationInWindow, from: nil))
        } else {
            offset = AttachmentPreviewLayout.clampedOffset(NSPoint(x: offset.x + event.scrollingDeltaX, y: offset.y - event.scrollingDeltaY), size: imageSize, viewport: bounds, scale: zoomScale)
            needsDisplay = true
        }
    }
    override func resetCursorRects() {
        let visible = imageRect.intersection(bounds)
        if !visible.isEmpty { addCursorRect(visible, cursor: .openHand) }
    }
}

final class AttachmentPreviewController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private(set) var imageView: AttachmentImageView?
    private(set) var playerView: AVPlayerView?
    private(set) var player: AVPlayer?
    private(set) var isClosed = false
    private let backdrop = AttachmentPreviewBackdrop(frame: .zero)
    private let toolbar = NSStackView()
    private let scaleLabel = NSTextField(labelWithString: "100%")
    private let helpLabel = NSTextField(labelWithString: "点击空白处或按 Esc 关闭")
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private var videoSize = NSSize(width: 16, height: 9)
    private var observations: [NSKeyValueObservation] = []

    init(file: URL, name: String, kind: AttachmentPreviewKind) throws {
        guard file.isFileURL else { throw ReaderError.message("预览只能打开已保存的本地附件。") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ReaderError.message("附件文件不可用，请重新打开或下载。") }
        let original: NSImage?
        if kind == .image {
            guard let image = NSImage(contentsOf: file), image.isValid, AttachmentPreviewLayout.validSize(image.size) else {
                throw ReaderError.message("图片无法读取，请重新下载或另存为后查看。")
            }
            original = image
        } else { original = nil }
        let panel = AttachmentPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = name; panel.minSize = NSSize(width: 520, height: 360); panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1); panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true; panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        backdrop.wantsLayer = true; backdrop.layer?.backgroundColor = panel.backgroundColor.cgColor
        backdrop.onClose = { [weak self] in self?.close() }; backdrop.onLayout = { [weak self] in self?.layoutContents() }
        panel.contentView = backdrop
        toolbar.orientation = .horizontal; toolbar.spacing = 8; toolbar.alignment = .centerY
        scaleLabel.alignment = .center; scaleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        scaleLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        helpLabel.font = NSFont.systemFont(ofSize: 11); helpLabel.textColor = .secondaryLabelColor; helpLabel.alignment = .center
        closeButton.target = self; closeButton.action = #selector(closePreview); closeButton.bezelStyle = .rounded
        closeButton.identifier = NSUserInterfaceItemIdentifier("preview-close"); closeButton.setAccessibilityLabel("关闭预览")
        backdrop.addSubview(toolbar); backdrop.addSubview(helpLabel); backdrop.addSubview(closeButton)
        if let original {
            let canvas = AttachmentImageView(image: original); imageView = canvas; backdrop.addSubview(canvas)
            canvas.onClose = { [weak self] in self?.close() }
            canvas.onScaleChanged = { [weak self] scale, fits in self?.updateScale(scale, fits: fits) }
            toolbar.addArrangedSubview(control("−", id: "preview-zoom-out", label: "缩小图片", action: #selector(zoomOut)))
            toolbar.addArrangedSubview(scaleLabel)
            toolbar.addArrangedSubview(control("+", id: "preview-zoom-in", label: "放大图片", action: #selector(zoomIn)))
            toolbar.addArrangedSubview(control("适应窗口", id: "preview-fit", label: "图片适应窗口", action: #selector(fitImage)))
            toolbar.addArrangedSubview(control("100%", id: "preview-actual", label: "图片原始大小", action: #selector(actualSize)))
            helpLabel.stringValue = "捏合缩放 · 放大后拖动 · 双击切换原始大小 · 点击空白处或按 Esc 关闭"
        } else {
            let item = AVPlayerItem(url: file), player = AVPlayer()
            let view = AVPlayerView(frame: .zero); view.identifier = NSUserInterfaceItemIdentifier("attachment-preview-video")
            view.controlsStyle = .floating; view.videoGravity = .resizeAspect
            // A single preview window owns Escape and lifetime, including while the native controls are focused.
            view.showsFullScreenToggleButton = false; view.allowsPictureInPicturePlayback = false
            view.player = player; self.player = player; playerView = view; backdrop.addSubview(view)
            player.replaceCurrentItem(with: item)
            observations.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosed, self.player?.currentItem === item, AttachmentPreviewLayout.validSize(item.presentationSize) else { return }
                    self.videoSize = item.presentationSize; self.backdrop.needsLayout = true
                }
            })
            observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosed, self.player?.currentItem === item else { return }
                    if item.status == .failed { self.helpLabel.stringValue = "视频暂时无法播放，可另存为后使用其他播放器。点击空白处或按 Esc 关闭。" }
                }
            })
        }
        layoutContents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func control(_ title: String, id: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(id); button.toolTip = label; button.setAccessibilityLabel(label)
        return button
    }
    private func updateScale(_ scale: CGFloat, fits: Bool) {
        scaleLabel.stringValue = String(format: scale < 0.1 ? "%.1f%%" : "%.0f%%", Double(scale * 100))
        toolbar.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "preview-fit" }?.state = fits ? .on : .off
    }
    private func layoutContents() {
        let bounds = backdrop.bounds
        let area = NSRect(x: 28, y: 38, width: max(1, bounds.width - 56), height: max(1, bounds.height - 100))
        imageView?.frame = area
        playerView?.frame = AttachmentPreviewLayout.fittedRect(videoSize, in: area)
        let size = toolbar.fittingSize
        toolbar.frame = NSRect(x: max(20, (bounds.width - size.width) / 2), y: bounds.height - 48, width: size.width, height: 30)
        closeButton.frame = NSRect(x: bounds.width - 78, y: bounds.height - 48, width: 58, height: 30)
        helpLabel.frame = NSRect(x: 20, y: 9, width: max(1, bounds.width - 40), height: 18)
    }
    func present(relativeTo parent: NSWindow?) {
        guard let window else { return }
        if let screen = parent?.screen ?? NSScreen.main {
            let available = screen.visibleFrame.insetBy(dx: 30, dy: 30)
            window.setContentSize(NSSize(width: min(1040, available.width), height: min(780, available.height - 28)))
        }
        window.center(); showWindow(nil); window.makeKeyAndOrderFront(nil)
        if let imageView { window.makeFirstResponder(imageView) }
    }
    @objc private func closePreview() { close() }
    @objc private func zoomIn() { if let imageView { imageView.setZoom(imageView.zoomScale * 1.25) } }
    @objc private func zoomOut() { if let imageView { imageView.setZoom(imageView.zoomScale / 1.25) } }
    @objc private func fitImage() { imageView?.fitImage() }
    @objc private func actualSize() { imageView?.setZoom(1) }
    private func releaseContent() {
        guard !isClosed else { return }
        isClosed = true
        observations.forEach { $0.invalidate() }; observations.removeAll()
        player?.pause(); player?.replaceCurrentItem(with: nil); playerView?.player = nil; player = nil
        imageView?.image = nil
    }
    override func close() { releaseContent(); super.close() }
    func windowWillClose(_ notification: Notification) {
        releaseContent()
        let completion = onClose; onClose = nil; completion?()
    }
}
