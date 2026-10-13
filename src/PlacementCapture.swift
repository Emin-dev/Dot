import AppKit
import ScreenCaptureKit
import Vision
import CoreGraphics

/// A sparse local screen-analysis adapter. Never requests permission, emits text, or sends pixels to a model.
@MainActor
final class PlacementCapture {
    private var gate = PlacementScanGate()
    private var work: Task<Void, Never>?
    var onCaptureChanged: ((Bool) -> Void)?
    private var acceptedWindows: [CGRect]?
    func current(screen: NSScreen) -> PlacementSnapshot? {
        guard let snapshot = gate.snapshot else { return nil }
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              screen.frame == snapshot.displayFrame, snapshot.valid(displayID: id, visible: screen.visibleFrame, now: ProcessInfo.processInfo.systemUptime),
              CGPreflightScreenCaptureAccess(), Self.inputIdleSeconds() >= ProcessInfo.processInfo.systemUptime - snapshot.capturedAt,
              let top = NSScreen.screens.first?.frame.maxY,
              let windows = try? Self.windowRegions(primaryTop: top, display: screen.frame), windows == acceptedWindows else {
            invalidate(); return nil
        }
        return snapshot
    }
    static func inputIdleSeconds() -> Double {
        let events: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
         .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let ages = events.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        return ages.allSatisfy { $0.isFinite && $0 >= 0 } ? (ages.min() ?? 0) : 0
    }
    func invalidate() { gate.invalidate(); acceptedWindows = nil; work?.cancel() }
    func request(screen: NSScreen, eligible: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard eligible, CGPreflightScreenCaptureAccess(), Self.inputIdleSeconds() >= 2,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let primaryTop = NSScreen.screens.first?.frame.maxY,
              let token = gate.begin(now: now, eligible: eligible) else { return }
        let frame = screen.frame, visible = screen.visibleFrame
        onCaptureChanged?(true)
        work = Task { [weak self] in
            guard let self else { return }
            var result: PlacementSnapshot?
            var windows: [CGRect]?
            defer { self.gate.finish(token: token, result: result); if self.gate.snapshot != nil { self.acceptedWindows = windows }; self.work = nil; self.onCaptureChanged?(false) }
            do {
                try Task.checkCancellation()
                let before = try Self.windowRegions(primaryTop: primaryTop, display: frame)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard CGPreflightScreenCaptureAccess(), Self.inputIdleSeconds() >= 2, let display = content.displays.first(where: { $0.displayID == id }),
                      display.width > 0, display.height > 0 else { return }
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let scale = min(1, sqrt(2_097_152 / (Double(display.width) * Double(display.height))),
                                2048 / Double(max(display.width, display.height)))
                config.width = max(1, Int(Double(display.width) * scale))
                config.height = max(1, Int(Double(display.height) * scale))
                config.showsCursor = false; config.capturesAudio = false
                let capturedAt = ProcessInfo.processInfo.systemUptime
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .utility) { try Self.imageRegions(image, display: frame) }
                let pixels = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard CGPreflightScreenCaptureAccess(), Self.inputIdleSeconds() >= ProcessInfo.processInfo.systemUptime - capturedAt,
                      before == (try Self.windowRegions(primaryTop: primaryTop, display: frame)) else { return }
                let candidate = PlacementSnapshot(displayID: id, displayFrame: frame, visibleFrame: visible,
                    capturedAt: capturedAt, protected: before + pixels)
                guard candidate.valid(displayID: id, visible: visible, now: ProcessInfo.processInfo.systemUptime) else { return }
                windows = before; result = candidate
            } catch { /* Unavailable/uncertain analysis means no autonomous movement. No content is logged. */ }
        }
    }
    static func windowRegions(primaryTop: CGFloat, display: CGRect) throws -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              windows.count <= 512 else { throw PlacementFailure.uncertain }
        var regions: [CGRect] = []
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber else { throw PlacementFailure.uncertain }
            if owner.int32Value == ProcessInfo.processInfo.processIdentifier || alpha.doubleValue == 0 { continue }
            guard let values = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: values as CFDictionary),
                  let mapped = PlacementSnapshot.quartzRect(rect, primaryTop: primaryTop) else { throw PlacementFailure.uncertain }
            if mapped.intersects(display) { regions.append(mapped.insetBy(dx: -12, dy: -12)) }
        }
        return regions
    }
    nonisolated static func imageRegions(_ image: CGImage, display: CGRect) throws -> [CGRect] {
        try Task.checkCancellation()
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 2048, height <= 2048, width * height <= 2_097_152,
              PlacementSnapshot.validRect(display) else { throw PlacementFailure.uncertain }
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        try Task.checkCancellation()
        let boxes = request.results ?? []
        guard boxes.count <= 1024 else { throw PlacementFailure.uncertain }
        var regions: [CGRect] = []
        for box in boxes {
            guard let rect = PlacementSnapshot.visionRect(box.boundingBox, display: display) else { throw PlacementFailure.uncertain }
            regions.append(rect.insetBy(dx: -12, dy: -12))
        }
        let bytes = try topDownRGBA(image)
        regions += try contrastRegions(bytes, width: width, height: height, display: display)
        guard regions.count <= PlacementSnapshot.maximumRegions else { throw PlacementFailure.uncertain }
        return regions
    }
    nonisolated static func topDownRGBA(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 2048, height <= 2048, width * height <= 2_097_152 else { throw PlacementFailure.uncertain }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            // Native synthetic-provider fixture confirms identity rendering preserves top-down byte rows.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw PlacementFailure.uncertain }
        return bytes
    }
    /// Top-down RGBA tiles: per-channel extrema retain colored/low-area edges missed by mean luminance.
    nonisolated static func contrastRegions(_ rgba: [UInt8], width: Int, height: Int, display: CGRect) throws -> [CGRect] {
        guard width > 0, height > 0, width <= 2048, height <= 2048, width * height <= 2_097_152,
              rgba.count == width * height * 4 else { throw PlacementFailure.uncertain }
        var regions: [CGRect] = []
        for y in stride(from: 0, to: height, by: 32) {
            try Task.checkCancellation()
            for x in stride(from: 0, to: width, by: 32) {
                var low = [255, 255, 255], high = [0, 0, 0]
                for row in max(0, y - 1)..<min(y + 33, height) {
                    for col in max(0, x - 1)..<min(x + 33, width) {
                        let index = (row * width + col) * 4
                        guard rgba[index + 3] == 255 else { throw PlacementFailure.uncertain }
                        for channel in 0..<3 { let value = Int(rgba[index + channel]); low[channel] = min(low[channel], value); high[channel] = max(high[channel], value) }
                    }
                }
                if (0..<3).contains(where: { high[$0] - low[$0] > 8 }) {
                    let box = CGRect(x: x, y: y, width: min(32, width - x), height: min(32, height - y))
                    guard let mapped = PlacementSnapshot.rasterRect(box, width: width, height: height, display: display) else { throw PlacementFailure.uncertain }
                    regions.append(mapped.insetBy(dx: -12, dy: -12))
                }
            }
        }
        return regions
    }
    enum PlacementFailure: Error { case uncertain }
}
