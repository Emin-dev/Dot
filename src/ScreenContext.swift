import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

@MainActor
final class ScreenContext {
    var enabled = true
    private var gate = ScreenContextGate()
    private var permission = ScreenPermissionTurn()
    private var encoding: (turn: UUID, task: Task<Data?, Never>)?
    static var hasRequestedAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "dot.screenAccessRequested") }
        set {
            UserDefaults.standard.set(newValue, forKey: "dot.screenAccessRequested")
            UserDefaults.standard.synchronize()
        }
    }
    private static var cachedAccessStatus: Bool? = nil
    private static var lastPreflightCheck: Double = 0

    static var isPermanentlyConfigured: Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let marker = support?.appendingPathComponent("Dot/.screen_permission_configured")
        if let marker, FileManager.default.fileExists(atPath: marker.path) {
            // The marker only records that the prompt was offered, and older builds wrote
            // it before the owner answered. While preflight still disagrees it is not
            // evidence of a decision, so clear it and let the next interaction ask again.
            guard CGPreflightScreenCaptureAccess() else {
                try? FileManager.default.removeItem(at: marker)
                UserDefaults.standard.removeObject(forKey: "dot.screenAccessRequested")
                UserDefaults.standard.removeObject(forKey: "dot.screenAccessGrantedInSettings")
                return false
            }
            return true
        }
        if UserDefaults.standard.bool(forKey: "dot.screenAccessGrantedInSettings") {
            return CGPreflightScreenCaptureAccess()
        }
        if UserDefaults.standard.bool(forKey: "dot.screenAccessRequested") {
            return true
        }
        return false
    }

    /// Record that the prompt has been *offered*. This must never claim that access was
    /// granted: an earlier build wrote `screenAccessGrantedInSettings` here, before the
    /// owner had answered anything, and because that key decides whether to ask again the
    /// app then never asked - the microphone failure again, but persisted to disk.
    static func markPermanentlyConfigured() {
        hasRequestedAccess = true
        UserDefaults.standard.set(true, forKey: "dot.screenAccessRequested")
        UserDefaults.standard.synchronize()
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dotDir = support.appendingPathComponent("Dot")
            try? FileManager.default.createDirectory(at: dotDir, withIntermediateDirectories: true)
            let marker = dotDir.appendingPathComponent(".screen_permission_configured")
            if !FileManager.default.fileExists(atPath: marker.path) {
                try? Data().write(to: marker)
            }
        }
    }

    static func hasScreenAccess(refresh: Bool = false) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if !refresh, let cached = cachedAccessStatus, (now - lastPreflightCheck) < 5.0 {
            return cached
        }
        let access = CGPreflightScreenCaptureAccess()
        cachedAccessStatus = access
        lastPreflightCheck = now
        if access {
            markPermanentlyConfigured()
        }
        return access
    }

    func prepare(turn: UUID, requestPermission: Bool = true) throws {
        try Task.checkCancellation()
        // 1. If already authorized or permanently configured, never prompt or request access.
        if Self.isPermanentlyConfigured || Self.hasScreenAccess(refresh: true) || CGPreflightScreenCaptureAccess() {
            Self.markPermanentlyConfigured()
            _ = permission.prepare(turn: turn, enabled: enabled, preflight: CGPreflightScreenCaptureAccess,
                                   request: { false && (requestPermission && CGRequestScreenCaptureAccess()) })
            try Task.checkCancellation()
            return
        }
        // 2. If access was already requested in the past or permission prompt is suppressed, do not prompt.
        if Self.hasRequestedAccess || !requestPermission {
            _ = permission.prepare(turn: turn, enabled: enabled, preflight: CGPreflightScreenCaptureAccess,
                                   request: { false && (requestPermission && CGRequestScreenCaptureAccess()) })
            try Task.checkCancellation()
            return
        }
        // 3. Ask at most once in the lifetime of the application.
        Self.markPermanentlyConfigured()
        guard permission.prepare(turn: turn, enabled: enabled, preflight: CGPreflightScreenCaptureAccess,
                                 request: { requestPermission && CGRequestScreenCaptureAccess() }) else {
            throw CGPreflightScreenCaptureAccess() ? ScreenFailure.unavailable : ScreenFailure.permission
        }
        try Task.checkCancellation()
    }
    func capture(turn: UUID, modelHasVision: Bool) async throws -> CapturedScreenImage? {
        guard enabled else { return nil }
        guard modelHasVision else { throw ScreenFailure.unsupported }
        try Task.checkCancellation()
        guard permission.mayCapture(turn: turn, preflight: CGPreflightScreenCaptureAccess) else {
            throw CGPreflightScreenCaptureAccess() ? ScreenFailure.unavailable : ScreenFailure.permission
        }
        try Task.checkCancellation()
        encoding?.task.cancel(); encoding = nil
        gate.begin(turn: turn, enabled: true, permissionGranted: true, modelHasVision: true)
        defer {
            gate.cancel(turn: turn)
            if encoding?.turn == turn { encoding?.task.cancel(); encoding = nil }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try validateCapture(turn: turn)
        let activeScreen: NSScreen? = {
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                    for w in windows {
                        if let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid == frontApp.processIdentifier,
                           let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                           let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                           rect.width > 100, rect.height > 100 {
                            if let s = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
                                return s
                            }
                        }
                    }
                }
            }
            return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }()
        let selected = activeScreen ?? NSScreen.main
        let displayID = (selected?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw ScreenFailure.unavailable }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(1, sqrt(Double(ScreenContextGate.maximumPixels) / Double(display.width * display.height)),
                        4096 / Double(max(display.width, display.height)))
        configuration.width = max(1, Int(Double(display.width) * scale))
        configuration.height = max(1, Int(Double(display.height) * scale))
        configuration.showsCursor = true; configuration.capturesAudio = false
        // captureImage supplies no acquisition timestamp. Start conservatively before
        // the request so framework delay, JPEG encoding and submission all count.
        let acquiredAt = ProcessInfo.processInfo.systemUptime
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        Task.detached(priority: .utility) {
            let start = ProcessInfo.processInfo.systemUptime
            let request = VNRecognizeTextRequest { req, _ in
                guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Active App"
                PreviousScreenMemory.shared.recordScreen(appName: app, windowTitle: "", ocrText: text)
                let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000.0
                DiagnosticChatLogger.recordScreen(app: app, ocrLineCount: observations.count, durationMs: elapsedMs)
            }
            request.recognitionLevel = .fast
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
        try validateCapture(turn: turn)
        let encoder = Task.detached(priority: .userInitiated) { () -> Data? in
            for quality in [0.75, 0.55, 0.35] {
                guard !Task.isCancelled else { return nil }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                let finished = CGImageDestinationFinalize(destination)
                guard !Task.isCancelled else { return nil }
                if finished, data.length <= ScreenContextGate.maximumBytes { return data as Data }
            }
            return nil
        }
        encoding = (turn, encoder)
        let encoded = await withTaskCancellationHandler(operation: { await encoder.value }, onCancel: { encoder.cancel() })
        try validateCapture(turn: turn)
        guard let encoded else { throw ScreenFailure.unavailable }
        try gate.capturedJPEG(encoded, width: image.width, height: image.height, turn: turn,
                              acquiredAt: acquiredAt, now: ProcessInfo.processInfo.systemUptime)
        return try gate.consume(turn: turn, now: ProcessInfo.processInfo.systemUptime)
    }
    private func validateCapture(turn: UUID) throws {
        try Task.checkCancellation()
        try gate.validateCapture(turn: turn)
        guard enabled else { throw ScreenContextGate.Failure.disabled }
        guard permission.mayCapture(turn: turn, preflight: CGPreflightScreenCaptureAccess) else {
            throw CGPreflightScreenCaptureAccess() ? ScreenFailure.unavailable : ScreenFailure.permission
        }
    }
    func extractVisibleScreenText() async throws -> [ScreenOCRLine] {
        guard Self.hasScreenAccess() else { throw ScreenFailure.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let selected = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let displayID = (selected?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw ScreenFailure.unavailable }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        #if canImport(Vision) && canImport(CoreGraphics)
        return await NativeScreenOCR.recognizeText(in: image)
        #else
        return []
        #endif
    }
    /// R8: a cheap 32x24 grayscale fingerprint used to decide whether the screen is
    /// changing. No OCR and no model payload; the cursor is excluded.
    func captureFingerprint() async -> UInt64? {
        guard enabled, CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let selected = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let displayID = (selected?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 160
            configuration.height = 120
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return Self.fingerprint(of: image)
        } catch { return nil }
    }

    static func fingerprint(of image: CGImage) -> UInt64? {
        let width = 32, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height)
        return pixels.withUnsafeMutableBytes { raw -> UInt64? in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in raw { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            return hash
        }
    }

    func captureSilentScreenSnapshot() async {
        guard enabled, CGPreflightScreenCaptureAccess() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let selected = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let displayID = (selected?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 1024
            configuration.height = 768
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            Task.detached(priority: .utility) {
                let request = VNRecognizeTextRequest { req, _ in
                    guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
                    let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Active App"
                    PreviousScreenMemory.shared.recordScreen(appName: app, windowTitle: "", ocrText: text)
                }
                request.recognitionLevel = .fast
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])
            }
        } catch {}
    }
    func cancel() { gate.cancel(); permission.cancel(); encoding?.task.cancel(); encoding = nil }
    enum ScreenFailure: LocalizedError {
        case permission, unavailable, unsupported
        var errorDescription: String? {
            switch self {
            case .permission: return "Allow Dot in System Settings → Privacy & Security → Screen Recording so I can see your screen, or turn off Screen context in my menu."
            case .unavailable: return "I couldn't capture your screen. Nothing was shared. Click me to retry, or turn off Screen context."
            case .unsupported: return "My local model hasn't enabled screen vision. I haven't seen your screen."
            }
        }
    }
}
