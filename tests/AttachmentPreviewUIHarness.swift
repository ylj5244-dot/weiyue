import AppKit
import AVKit
import AVFoundation
import CoreVideo
import CoreImage

// Synthetic local files only. No application state, credentials, account or network is loaded.
@main @MainActor final class AttachmentPreviewUIHarness: NSObject, NSApplicationDelegate {
    var temporary: URL!
    var previousApp: NSRunningApplication?
    var checks = 0
    var closes = 0
    var active: AttachmentPreviewController?
    static func main() {
        let app = NSApplication.shared, delegate = AttachmentPreviewUIHarness()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        previousApp = NSWorkspace.shared.frontmostApplication
        do {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-preview-fixture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let image = temporary.appendingPathComponent("synthetic-long-image.png")
            try makeImage().write(to: image)
            Task { @MainActor in
                do {
                    try await self.imageTests(file: image)
                    self.makeVideo(at: self.temporary.appendingPathComponent("synthetic-video.mov")) { result in
                        Task { @MainActor in
                            do { try await self.videoTests(file: result.get()) } catch { self.finish(false, error.localizedDescription) }
                        }
                    }
                } catch { self.finish(false, error.localizedDescription) }
            }
        } catch { finish(false, error.localizedDescription) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { self.finish(false, "preview UI test timed out") }
    }
    func check(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw ReaderError.message(message) }
    }
    func makeImage() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 1500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 1500).fill()
        for index in 0..<15 {
            NSColor(calibratedRed: 0.1, green: CGFloat(index) / 24, blue: 0.65, alpha: 1).setFill()
            NSRect(x: 32, y: CGFloat(index * 100 + 10), width: 836, height: 4).fill()
            ("原始附件 · 清晰文字 \(index + 1) / 15" as NSString).draw(at: NSPoint(x: 40, y: CGFloat(index * 100 + 35)), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
    func prepare(_ file: URL, kind: AttachmentPreviewKind) async throws -> AttachmentPreviewController {
        let controller = try AttachmentPreviewController(file: file, name: "合成附件预览验收", kind: kind)
        controller.onClose = { [weak self] in self?.closes += 1 }
        let window = controller.window!
        window.setContentSize(NSSize(width: 800, height: 620)); window.center()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        let activationDeadline = Date().addingTimeInterval(2)
        while !window.isKeyWindow && Date() < activationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            if NSApp.isActive { window.makeKey() }
        }
        try check(window.isKeyWindow, "Synthetic preview window must be key before testing native input (active=\(NSApp.isActive))")
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        active = controller
        return controller
    }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func button(_ controller: AttachmentPreviewController, _ identifier: String) -> NSButton {
        views(controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier }!
    }
    func click(_ controller: AttachmentPreviewController, point: NSPoint) {
        let window = controller.window!
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }
    func escape(_ controller: AttachmentPreviewController) {
        let window = controller.window!
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(event)
    }
    func snapshot(_ controller: AttachmentPreviewController, name: String) throws {
        let view = controller.window!.contentView!; view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReaderError.message("snapshot unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/" + name + ".png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
    }
    func windowSnapshot(_ controller: AttachmentPreviewController, name: String) async throws {
        // AVKit renders through composited layers, which NSView.cacheDisplay does not include.
        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/" + name + ".png")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(controller.window!.windowNumber), destination.path]
        try process.run()
        while process.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: destination.path) {
            print("PASS: captured composited preview window at \(destination.lastPathComponent)"); fflush(stdout)
        } else {
            print("NOTE: system window capture unavailable; decoded-frame and playback assertions still apply"); fflush(stdout)
        }
    }
    func imageTests(file: URL) async throws {
        var controller: AttachmentPreviewController? = try await prepare(file, kind: .image)
        let canvas = controller!.imageView!
        try check(canvas.imageSize == NSSize(width: 900, height: 1500), "Preview must use the original image dimensions")
        try check(canvas.fitsWindow && canvas.zoomScale < 1, "Initial long image fits fully")
        let fitScale = canvas.zoomScale
        button(controller!, "preview-zoom-in").performClick(nil)
        try check(canvas.zoomScale > fitScale && !controller!.isClosed, "Zoom in works without closing")
        button(controller!, "preview-zoom-out").performClick(nil)
        try check(abs(canvas.zoomScale - fitScale) < 0.0001, "Zoom out returns the previous scale")
        button(controller!, "preview-actual").performClick(nil)
        try check(canvas.zoomScale == 1, "100 percent uses original size")
        controller!.window!.setContentSize(NSSize(width: 620, height: 480)); controller!.window!.contentView!.layoutSubtreeIfNeeded()
        try check(canvas.zoomScale == 1, "Manual zoom survives resize")
        button(controller!, "preview-fit").performClick(nil)
        try check(canvas.fitsWindow && canvas.imageRect.width <= canvas.bounds.width + 0.1 && canvas.imageRect.height <= canvas.bounds.height + 0.1, "Fit after resize shows the full image")
        try snapshot(controller!, name: "v107-preview-image-fit")
        click(controller!, point: canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil))
        try check(!controller!.isClosed, "Clicking image content keeps preview open")
        click(controller!, point: canvas.convert(NSPoint(x: 2, y: canvas.bounds.midY), to: nil))
        try check(controller!.isClosed && !controller!.window!.isVisible && closes == 1, "Clicking inner letterbox closes once (closed=\(controller!.isClosed), visible=\(controller!.window!.isVisible), callbacks=\(closes))")
        try check(canvas.image == nil, "Closing releases decoded image")
        controller = nil; active = nil

        controller = try await prepare(file, kind: .image)
        controller!.window!.makeFirstResponder(button(controller!, "preview-actual"))
        escape(controller!)
        try check(controller!.isClosed && closes == 2, "Escape closes with toolbar focus")
        controller = nil; active = nil
        for _ in 0..<12 {
            var candidate: AttachmentPreviewController? = try await prepare(file, kind: .image)
            weak let released = candidate
            click(candidate!, point: NSPoint(x: 8, y: 80))
            try check(candidate!.isClosed, "Outer backdrop closes")
            candidate = nil; active = nil
            try await Task.sleep(nanoseconds: 10_000_000)
            try check(released == nil, "Closed preview controller has no retain cycle")
        }
        print("PASS: image preview zoom, fit, resize, background/Escape and repeated release"); fflush(stdout)
    }
    func makeVideo(at file: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
                let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? ReaderError.message("video fixture writer failed") }
                writer.startSession(atSourceTime: .zero)
                for frame in 0..<30 {
                    let deadline = Date().addingTimeInterval(5)
                    while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                    guard input.isReadyForMoreMediaData, let pool = adapter.pixelBufferPool else { throw writer.error ?? ReaderError.message("video fixture input timeout") }
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw ReaderError.message("video fixture pixel buffer unavailable") }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
                    for y in 0..<180 { for x in 0..<320 { let p = bytes.advanced(by: y * stride + x * 4); p[0] = 255; p[1] = UInt8(x * 255 / 320); p[2] = UInt8(y * 255 / 180); p[3] = UInt8(frame * 8) } }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else { throw writer.error ?? ReaderError.message("video fixture append failed") }
                }
                input.markAsFinished()
                writer.finishWriting { DispatchQueue.main.async { completion(writer.status == .completed ? .success(file) : .failure(writer.error ?? ReaderError.message("video fixture failed"))) } }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func videoTests(file: URL) async throws {
        let controller = try await prepare(file, kind: .video)
        let deadline = Date().addingTimeInterval(8)
        while controller.player?.currentItem?.status != .readyToPlay && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(controller.player?.currentItem?.status == .readyToPlay, "Synthetic video did not become ready")
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let player = controller.player!, view = controller.playerView!
        try check(abs(view.frame.width / view.frame.height - 16 / 9) < 0.01, "Video frame matches actual aspect ratio")
        try check(view.controlsStyle == .floating && !view.showsFullScreenToggleButton, "Native playback controls stay in the preview window")
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        player.currentItem!.add(output)
        player.play()
        let playbackDeadline = Date().addingTimeInterval(8)
        var decodedFrame: CVPixelBuffer?
        while Date() < playbackDeadline {
            let time = player.currentTime()
            if time.seconds >= 0.25 && view.isReadyForDisplay && output.hasNewPixelBuffer(forItemTime: time) {
                decodedFrame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
                if decodedFrame != nil { break }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(player.currentTime().seconds >= 0.25, "Native video playback time must advance")
        try check(view.isReadyForDisplay, "AVPlayerView must have a decoded frame ready for display")
        guard let decodedFrame else { throw ReaderError.message("Native player did not return a decoded video frame") }
        try check(CVPixelBufferGetWidth(decodedFrame) == 320 && CVPixelBufferGetHeight(decodedFrame) == 180, "Decoded video has original fixture dimensions")
        CVPixelBufferLockBaseAddress(decodedFrame, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(decodedFrame)!.assumingMemoryBound(to: UInt8.self), rowBytes = CVPixelBufferGetBytesPerRow(decodedFrame)
        let topLeft = pixels.advanced(by: 10 * rowBytes + 10 * 4), bottomRight = pixels.advanced(by: 160 * rowBytes + 300 * 4)
        let hasGradient = Int(bottomRight[2]) - Int(topLeft[2]) > 100 && Int(bottomRight[1]) - Int(topLeft[1]) > 100
        CVPixelBufferUnlockBaseAddress(decodedFrame, .readOnly)
        try check(hasGradient, "Decoded frame contains the synthetic color gradients, not an empty frame")
        let cgFrame = CIContext().createCGImage(CIImage(cvPixelBuffer: decodedFrame), from: CGRect(x: 0, y: 0, width: 320, height: 180))!
        let frameDestination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/v107-preview-video-decoded-frame.png")
        try NSBitmapImageRep(cgImage: cgFrame).representation(using: .png, properties: [:])!.write(to: frameDestination)
        print(String(format: "PASS: native video played %.3f seconds; AVPlayerView ready; decoded nonempty 320 × 180 frame", player.currentTime().seconds)); fflush(stdout)
        try await windowSnapshot(controller, name: "v107-preview-video-window")
        controller.window!.makeFirstResponder(view)
        escape(controller)
        try check(controller.isClosed && player.rate == 0 && player.currentItem == nil && view.player == nil, "Escape from player focus stops playback and releases item")
        active = nil
        let second = try await prepare(file, kind: .video)
        let secondPlayer = second.player!
        secondPlayer.play(); click(second, point: NSPoint(x: 8, y: 80))
        try check(second.isClosed && secondPlayer.currentItem == nil && secondPlayer.rate == 0, "Background close also stops video before readiness")
        active = nil
        finish(true, "\(checks) native image/video preview assertions; only synthetic local files")
    }
    func finish(_ success: Bool, _ message: String) {
        active?.close(); active = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        previousApp?.activate(options: [])
        print((success ? "PASS: " : "FAIL: ") + message); fflush(stdout); exit(success ? 0 : 1)
    }
}
