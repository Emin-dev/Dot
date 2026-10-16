import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
        if let marker, FileManager.default.fileExists(atPath: marker.path) { return true }
        if UserDefaults.standard.bool(forKey: "dot.screenAccessRequested") ||
           UserDefaults.standard.bool(forKey: "dot.screenAccessGrantedInSettings") {
            return true
        }
        return false
    }

    static func markPermanentlyConfigured() {
        hasRequestedAccess = true
        UserDefaults.standard.set(true, forKey: "dot.screenAccessGrantedInSettings")
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
        let selected = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
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
