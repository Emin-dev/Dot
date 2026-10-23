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

    /// Test seams: fixtures inject an isolated defaults suite, a scratch marker
    /// root and a fake preflight so they never write the owner's preferences or
    /// consult the real Screen Recording (TCC) state.
    static var defaults: UserDefaults = .standard
    static var markerRoot: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    static var preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }

    static var hasRequestedAccess: Bool {
        get { defaults.bool(forKey: "dot.screenAccessRequested") }
        set {
            defaults.set(newValue, forKey: "dot.screenAccessRequested")
            defaults.synchronize()
        }
    }
    private static var cachedAccessStatus: Bool? = nil
    private static var lastPreflightCheck: Double = 0

    static var isPermanentlyConfigured: Bool {
        let marker = markerRoot?.appendingPathComponent("Dot/.screen_permission_configured")
        if let marker, FileManager.default.fileExists(atPath: marker.path) {
            // The marker only records that the prompt was offered, and older builds wrote
            // it before the owner answered. While preflight still disagrees it is not
            // evidence of a decision, so clear it and let the next interaction ask again.
            guard Self.preflight() else {
                try? FileManager.default.removeItem(at: marker)
                defaults.removeObject(forKey: "dot.screenAccessRequested")
                defaults.removeObject(forKey: "dot.screenAccessGrantedInSettings")
                return false
            }
            return true
        }
        if defaults.bool(forKey: "dot.screenAccessGrantedInSettings") {
            return Self.preflight()
        }
        if defaults.bool(forKey: "dot.screenAccessRequested") {
            // Same honesty rule as the marker branch: this key only records that
            // the prompt was offered, so while preflight still disagrees it must
            // not suppress the next prompt. Clear it and ask again.
            guard Self.preflight() else {
                defaults.removeObject(forKey: "dot.screenAccessRequested")
                return false
            }
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
        defaults.set(true, forKey: "dot.screenAccessRequested")
        defaults.synchronize()
        if let support = markerRoot {
            let dotDir = support.appendingPathComponent("Dot")
            let marker = dotDir.appendingPathComponent(".screen_permission_configured")
            if !FileManager.default.fileExists(atPath: marker.path) {
                do {
                    try FileManager.default.createDirectory(at: dotDir, withIntermediateDirectories: true)
                    try Data().write(to: marker)
                } catch {
                    // The flag and the marker must never diverge silently: a marker
                    // that could not be written would otherwise make the next launch
                    // believe the prompt was never offered while the flag says it was.
                    DiagnosticChatLogger.recordEvent(category: "screen_permission",
                        message: "Screen-permission marker could not be written at \(marker.path): \(error.localizedDescription)")
                }
            }
        }
    }

    static func hasScreenAccess(refresh: Bool = false) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if !refresh, let cached = cachedAccessStatus, (now - lastPreflightCheck) < 5.0 {
            return cached
        }
        let access = Self.preflight()
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
        if Self.isPermanentlyConfigured || Self.hasScreenAccess(refresh: true) || Self.preflight() {
            Self.markPermanentlyConfigured()
            // This branch never prompts: access is already granted or the prompt was
            // already offered, and a second prompt could let a lost answer suppress
            // every future ask. The explicit `false` is intentional dead logic.
            _ = permission.prepare(turn: turn, enabled: enabled, preflight: Self.preflight,
                                   request: { false })
            try Task.checkCancellation()
            return
        }
        // 2. If access was already requested in the past or permission prompt is suppressed, do not prompt.
        if Self.hasRequestedAccess || !requestPermission {
            // Never prompts by design (already asked or suppressed at this site);
            // the explicit `false` keeps that decision visible instead of hidden.
            _ = permission.prepare(turn: turn, enabled: enabled, preflight: Self.preflight,
                                   request: { false })
            try Task.checkCancellation()
            return
        }
        // 3. Ask at most once in the lifetime of the application.
        Self.markPermanentlyConfigured()
        guard permission.prepare(turn: turn, enabled: enabled, preflight: CGPreflightScreenCaptureAccess,
                                 request: { requestPermission && CGRequestScreenCaptureAccess() }) else {
            throw Self.preflight() ? ScreenFailure.unavailable : ScreenFailure.permission
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
        guard permission.mayCapture(turn: turn, preflight: Self.preflight) else {
            throw Self.preflight() ? ScreenFailure.unavailable : ScreenFailure.permission
        }
    }
    func extractVisibleScreenText() async throws -> [ScreenOCRLine] {
        try await extractVisibleScreenTextAndScreen().lines
    }

    /// The captured screen is returned with its lines: OCR boxes are normalized to
    /// that display, so callers must convert them using the same screen, never
    /// `NSScreen.main` (which may be a different monitor).
    func extractVisibleScreenTextAndScreen() async throws -> (lines: [ScreenOCRLine], screen: NSScreen?) {
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
        let lines = try await NativeScreenOCR.recognizeText(in: image)
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        } ?? selected
        return (lines, screen)
        #else
        return ([], selected)
        #endif
    }
    /// R8, R23: an Apple Vision feature print of a small capture, used only to measure
    /// how much the screen changed. No OCR and no model payload; Dot's own windows and
    /// the pointer are excluded, and the print stays in memory.
    func captureFeaturePrint() async -> ScreenFeaturePrint? {
        guard enabled, Self.preflight() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let selected = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let displayID = (selected?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 256
            configuration.height = 160
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            // Vision runs off the main thread, like the OCR above.
            return await Task.detached(priority: .utility) { ScreenFeaturePrint(image: image) }.value
        } catch { return nil }
    }

    func captureSilentScreenSnapshot() async {
        guard enabled, Self.preflight() else { return }
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

/// R23: an Apple Vision feature print of one small screen capture. The distance between
/// two prints says how much the screen changed, so a ticking clock or a blinking caret no
/// longer counts as a change the way any changed pixel did with the old hash. Prints are
/// kept in memory only; they are never stored, logged or sent anywhere.
/// `@unchecked Sendable`: the observation is an immutable Vision result that is only read.
struct ScreenFeaturePrint: @unchecked Sendable {
    /// At or above this distance the screen changed (a new window, page or dialog); below
    /// it the screen is the same. The fixture test prints both distances in CI; retune this
    /// from those numbers and from real screens.
    static let changeThreshold: Float = 0.1

    private let observation: VNFeaturePrintObservation

    init?(image: CGImage) {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch { return nil }
        guard let observation = request.results?.first else { return nil }
        self.observation = observation
    }

    func distance(to other: ScreenFeaturePrint) -> Float? {
        var distance: Float = 0
        do { try observation.computeDistance(&distance, to: other.observation) } catch { return nil }
        return distance
    }

    /// A print that cannot be compared counts as a change, so watching never stops on an
    /// error.
    func differs(from earlier: ScreenFeaturePrint) -> Bool {
        (distance(to: earlier) ?? .infinity) >= Self.changeThreshold
    }
}
