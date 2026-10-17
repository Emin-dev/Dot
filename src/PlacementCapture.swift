import AppKit
import ScreenCaptureKit
import Vision
import CoreGraphics
import OSLog

/// A sparse local screen-analysis adapter. Never requests permission, emits text, or sends pixels to a model.
@MainActor
final class PlacementCapture {
    private static let log = Logger(subsystem: "app.dot", category: "placement")
    private var gate = PlacementScanGate()
    private(set) var lastDiagnostic: PlacementDiagnostic?
    var onDiagnostic: ((PlacementDiagnostic) -> Void)?
    private func report(_ value: PlacementDiagnostic) {
        lastDiagnostic = value; onDiagnostic?(value)
        Self.log.notice("\(value.logLine, privacy: .public)")
    }
    private var work: Task<Void, Never>?
    var onCaptureChanged: ((Bool) -> Void)?
    var onSnapshotUpdated: ((PlacementSnapshot) -> Void)?
    private var acceptedWindows: [CGRect]?
    private var lastPreflightCheck = 0.0
    private var cachedPreflight = false
    private func checkPreflight(now: Double) -> Bool {
        if now - lastPreflightCheck >= 5.0 {
            lastPreflightCheck = now
            cachedPreflight = CGPreflightScreenCaptureAccess()
        }
        return cachedPreflight
    }
    func current(screen: NSScreen) -> PlacementSnapshot? {
        guard let snapshot = gate.snapshot else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let reason: PlacementDiagnostic.Reason?
        if !checkPreflight(now: now) { reason = .permission }
        else if now - snapshot.capturedAt > PlacementSnapshot.lifetime {
            // A refresh may already be in flight; its result replaces this map.
            // Rejecting here would cancel that capture and guarantee the next
            // validation is blind, which is the cycle the old ordering wasted.
            if gate.active != nil { return nil }
            reason = .expired
        } else if screen.frame != snapshot.displayFrame || screen.visibleFrame != snapshot.visibleFrame { reason = .invalidMap }
        else if (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != snapshot.displayID { reason = .displayMissing }
        else if let top = NSScreen.screens.first?.frame.maxY,
                let windows = try? Self.windowRegions(primaryTop: top, display: screen.frame) {
            reason = acceptedWindows.map { PlacementSnapshot.sameGeometry(windows, $0) } == true ? nil : .windowsChanged
        } else { reason = .windowMetadata }
        guard reason == nil, snapshot.valid(displayID: snapshot.displayID, visible: screen.visibleFrame, now: now) else {
            report(PlacementDiagnostic(stage: .validation, outcome: .rejected, reason: reason ?? .invalidMap,
                elapsed: now - snapshot.capturedAt, regions: snapshot.protected.count))
            invalidate(); return nil
        }
        return snapshot
    }
    /// True when the held map is absent, display-invalid, or will age out before
    /// the next movement check. Callers ask this before `current` so a refresh
    /// starts while the old map is still valid instead of being rejected first.
    func needsRefresh(screen: NSScreen) -> Bool {
        guard let snapshot = gate.snapshot else { return true }
        return screen.frame != snapshot.displayFrame || screen.visibleFrame != snapshot.visibleFrame
            || ProcessInfo.processInfo.systemUptime - snapshot.capturedAt > PlacementSnapshot.lifetime - 1.0
    }
    func fastWindowSnapshot(screen: NSScreen) -> PlacementSnapshot? {
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let primaryTop = NSScreen.screens.first?.frame.maxY,
              let windows = try? Self.windowRegions(primaryTop: primaryTop, display: screen.frame) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        return PlacementSnapshot(displayID: id, displayFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                 capturedAt: now, protected: windows)
    }
    func invalidate() { gate.invalidate(); acceptedWindows = nil; work?.cancel() }
    func request(screen: NSScreen, eligible: Bool, immediate: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard eligible,
              let token = gate.begin(now: now, eligible: eligible, immediate: immediate) else { return }
        guard checkPreflight(now: now),
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let primaryTop = NSScreen.screens.first?.frame.maxY else {
            gate.finish(token: token, result: nil)
            return
        }
        let frame = screen.frame, visible = screen.visibleFrame
        onCaptureChanged?(true)
        work = Task { [weak self] in
            guard let self else { return }
            var result: PlacementSnapshot?
            var windows: [CGRect]?
            var stage = PlacementDiagnostic.Stage.windows
            var reason: PlacementDiagnostic.Reason?
            var outcome = PlacementDiagnostic.Outcome.rejected
            var captureElapsed = 0.0, analysisElapsed = 0.0
            var captureStarted: Double?, analysisStarted: Double?
            var imageWidth = 0, imageHeight = 0
            var observedAlpha: Int?
            var unknownTiles = 0, addedWindows = 0
            var code: Int?
            defer {
                if let started = captureStarted { captureElapsed = ProcessInfo.processInfo.systemUptime - started }
                if let started = analysisStarted { analysisElapsed = ProcessInfo.processInfo.systemUptime - started }
                self.gate.finish(token: token, result: result)
                if let valid = self.gate.snapshot {
                    self.acceptedWindows = windows
                    self.onSnapshotUpdated?(valid)
                }
                self.work = nil; self.onCaptureChanged?(false)
                self.report(PlacementDiagnostic(stage: stage, outcome: outcome, reason: reason,
                    elapsed: ProcessInfo.processInfo.systemUptime - now, capture: captureElapsed,
                    analysis: analysisElapsed, regions: result?.protected.count ?? 0, errorCode: code, imageWidth: imageWidth, imageHeight: imageHeight, observedAlpha: observedAlpha, unknownTiles: unknownTiles, addedWindows: addedWindows))
            }
            do {
                try Task.checkCancellation()
                let before = try Self.windowRegions(primaryTop: primaryTop, display: frame)
                stage = .shareable
                guard checkPreflight(now: ProcessInfo.processInfo.systemUptime) else { reason = .permission; return }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard checkPreflight(now: ProcessInfo.processInfo.systemUptime) else { reason = .permission; return }
                guard let display = content.displays.first(where: { $0.displayID == id }),
                      display.width > 0, display.height > 0 else { reason = .displayMissing; return }
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let scale = min(1, sqrt(2_097_152 / (Double(display.width) * Double(display.height))),
                                2048 / Double(max(display.width, display.height)))
                config.width = max(1, Int(Double(display.width) * scale))
                config.height = max(1, Int(Double(display.height) * scale))
                config.showsCursor = false; config.capturesAudio = false
                stage = .capture
                let capturedAt = ProcessInfo.processInfo.systemUptime
                captureStarted = capturedAt
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                captureElapsed = ProcessInfo.processInfo.systemUptime - capturedAt; captureStarted = nil
                imageWidth = image.width; imageHeight = image.height
                try Task.checkCancellation()
                stage = .analysis
                analysisStarted = ProcessInfo.processInfo.systemUptime
                let worker = Task.detached(priority: .utility) { try Self.analyzeImage(image, display: frame) }
                let pixels = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                analysisElapsed = ProcessInfo.processInfo.systemUptime - (analysisStarted ?? ProcessInfo.processInfo.systemUptime); analysisStarted = nil
                observedAlpha = pixels.firstNonOpaqueAlpha; unknownTiles = pixels.unknownTiles
                try Task.checkCancellation()
                stage = .validation
                guard checkPreflight(now: ProcessInfo.processInfo.systemUptime) else { reason = .permission; return }
                let after = try Self.windowRegions(primaryTop: primaryTop, display: frame)
                guard PlacementSnapshot.preservesGeometry(before, in: after) else { reason = .windowsChanged; return }
                addedWindows = after.count - before.count
                let candidate = PlacementSnapshot(displayID: id, displayFrame: frame, visibleFrame: visible,
                    capturedAt: capturedAt, protected: after + pixels.regions)
                guard ProcessInfo.processInfo.systemUptime - capturedAt <= PlacementSnapshot.lifetime else { reason = .expired; return }
                guard candidate.valid(displayID: id, visible: visible, now: ProcessInfo.processInfo.systemUptime) else { reason = .invalidMap; return }
                // Added overlays are fully blocked; later geometry changes still invalidate the map.
                windows = after; result = candidate; outcome = .ready
            } catch {
                if Task.isCancelled || error is CancellationError { outcome = .cancelled; reason = .cancelled }
                else {
                    outcome = .failed
                    reason = (error as? PlacementFailure)?.reason ?? .framework
                    // Domain/description are intentionally omitted: they may contain private content or paths.
                    if let failure = error as? PlacementFailure {
                        if case .textAnalysis(let underlyingCode) = failure { code = underlyingCode }
                    } else { code = (error as NSError).code }
                }
            }
        }
    }
    static func windowRegions(primaryTop: CGFloat, display: CGRect) throws -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              windows.count <= 512 else { throw PlacementFailure.windowMetadata }
        var regions: [CGRect] = []
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber else { throw PlacementFailure.windowMetadata }
            if owner.int32Value == ProcessInfo.processInfo.processIdentifier || alpha.doubleValue == 0 { continue }
            guard let values = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: values as CFDictionary),
                  let mapped = PlacementSnapshot.quartzRect(rect, primaryTop: primaryTop) else { throw PlacementFailure.windowMetadata }
            if mapped.intersects(display) {
                guard mapped.width >= 60 && mapped.height >= 60 else { continue }
                if mapped.width >= display.width * 0.85 && mapped.height >= display.height * 0.85 {
                    regions.append(mapped.insetBy(dx: 48, dy: 48))
                } else {
                    regions.append(mapped.insetBy(dx: -8, dy: -8))
                }
            }
        }
        return regions
    }
    private nonisolated static func analyzeImage(_ image: CGImage, display: CGRect) throws -> PixelAnalysis {
        try Task.checkCancellation()
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 2048, height <= 2048, width * height <= 2_097_152,
              PlacementSnapshot.validRect(display) else { throw PlacementFailure.imageBounds }
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        do { try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request]) }
        catch { throw PlacementFailure.textAnalysis(code: (error as NSError).code) }
        try Task.checkCancellation()
        let boxes = request.results ?? []
        guard boxes.count <= 1024 else { throw PlacementFailure.pixelAnalysis }
        var regions: [CGRect] = []
        for box in boxes {
            guard let rect = PlacementSnapshot.visionRect(box.boundingBox, display: display) else { throw PlacementFailure.pixelAnalysis }
            regions.append(rect.insetBy(dx: -12, dy: -12))
        }
        let bytes = try topDownRGBA(image)
        var analysis = try analyzePixels(bytes, width: width, height: height, display: display)
        regions += analysis.regions
        guard regions.count <= PlacementSnapshot.maximumRegions else { throw PlacementFailure.pixelAnalysis }
        analysis.regions = regions
        return analysis
    }
    nonisolated static func topDownRGBA(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 2048, height <= 2048, width * height <= 2_097_152 else { throw PlacementFailure.pixelAnalysis }
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
        guard drawn else { throw PlacementFailure.pixelAnalysis }
        return bytes
    }
    /// Top-down RGBA tiles: per-channel extrema retain colored/low-area edges missed by mean luminance.
    struct PixelAnalysis {
        var regions: [CGRect]
        let unknownTiles: Int
        let firstNonOpaqueAlpha: Int?
    }
    nonisolated static func contrastRegions(_ rgba: [UInt8], width: Int, height: Int, display: CGRect) throws -> [CGRect] {
        try analyzePixels(rgba, width: width, height: height, display: display).regions
    }
    nonisolated static func analyzePixels(_ rgba: [UInt8], width: Int, height: Int, display: CGRect) throws -> PixelAnalysis {
        guard width > 0, height > 0, width <= 2048, height <= 2048, width * height <= 2_097_152,
              rgba.count == width * height * 4 else { throw PlacementFailure.pixelAnalysis }
        var regions: [CGRect] = []
        var unknownTiles = 0
        var firstNonOpaqueAlpha: Int?
        for y in stride(from: 0, to: height, by: 32) {
            try Task.checkCancellation()
            for x in stride(from: 0, to: width, by: 32) {
                var low = [255, 255, 255], high = [0, 0, 0]
                var unknown = false
                for row in max(0, y - 1)..<min(y + 33, height) {
                    for col in max(0, x - 1)..<min(x + 33, width) {
                        let index = (row * width + col) * 4
                        if rgba[index + 3] != 255 {
                            unknown = true
                            if firstNonOpaqueAlpha == nil { firstNonOpaqueAlpha = Int(rgba[index + 3]) }
                        }
                        for channel in 0..<3 { let value = Int(rgba[index + channel]); low[channel] = min(low[channel], value); high[channel] = max(high[channel], value) }
                    }
                }
                // Transparency is unknown occupancy, never evidence of an empty background.
                if unknown { unknownTiles += 1 }
                if unknown || (0..<3).contains(where: { high[$0] - low[$0] > 28 }) {
                    let box = CGRect(x: x, y: y, width: min(32, width - x), height: min(32, height - y))
                    guard let mapped = PlacementSnapshot.rasterRect(box, width: width, height: height, display: display) else { throw PlacementFailure.pixelAnalysis }
                    regions.append(mapped.insetBy(dx: -12, dy: -12))
                }
            }
        }
        return PixelAnalysis(regions: regions, unknownTiles: unknownTiles, firstNonOpaqueAlpha: firstNonOpaqueAlpha)
    }
    enum PlacementFailure: Error {
        case windowMetadata, imageBounds, pixelAnalysis
        case textAnalysis(code: Int)
        var reason: PlacementDiagnostic.Reason {
            switch self {
            case .windowMetadata: return .windowMetadata
            case .imageBounds: return .imageBounds
            case .textAnalysis: return .textAnalysis
            case .pixelAnalysis: return .pixelAnalysis
            }
        }
    }
}
