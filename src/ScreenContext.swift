import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ScreenContext {
    var enabled = true
    private var gate = ScreenContextGate()
    func capture(turn: UUID, modelHasVision: Bool) async throws -> String? {
        guard enabled else { return nil }
        guard modelHasVision else { throw ScreenFailure.unsupported }
        try Task.checkCancellation()
        guard ScreenPermissionAccess.allowed(preflight: CGPreflightScreenCaptureAccess,
                                             request: CGRequestScreenCaptureAccess) else {
            throw ScreenFailure.permission
        }
        try Task.checkCancellation()
        gate.begin(turn: turn, enabled: true, permissionGranted: true, modelHasVision: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
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
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let encoded = await Task.detached(priority: .userInitiated) { () -> Data? in
            for quality in [0.75, 0.55, 0.35] {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), data.length <= ScreenContextGate.maximumBytes { return data as Data }
            }
            return nil
        }.value
        try Task.checkCancellation()
        guard let encoded else { throw ScreenFailure.unavailable }
        try gate.capturedJPEG(encoded, width: image.width, height: image.height, turn: turn, now: ProcessInfo.processInfo.systemUptime)
        return try gate.consumeDataURL(turn: turn, now: ProcessInfo.processInfo.systemUptime)
    }
    func cancel() { gate.cancel() }
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
