import SwiftUI
import AppKit
import OSLog
import AVFoundation
import CoreGraphics
import IOKit.ps

/// Replaceable boundary operations keep coordinator replays model-free. This
/// carries no turn state; production closures use the existing native managers.
@MainActor
struct ChatRuntime {
    var isReady: () -> Bool
    var startPreparation: () -> Void
    var microphoneAuthorized: () -> Bool
    var currentRoute: () -> VoiceAudioRoute?
    var screenAuthorized: () -> Bool
    var startVoice: (UUID) throws -> Void
    var enqueueVoice: (String, UUID) -> Void
    var completeVoice: (UUID) -> Void
    var stopVoice: () -> Void
    var ttsSpeaking: () -> Bool
    var startCapture: (UUID, VoiceTimingSettings, Bool) async -> Void
    var stopCapture: () -> Void
    var recording: () -> Bool
    var transcribing: () -> Bool
    var forceFinishCapture: () -> Void = {}
}

/// The native editor and coordinator share the same bounded input contract.
enum TypedMessageValidation {
    static func cleaned(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func problem(_ text: String) -> String? {
        let value = cleaned(text)
        guard !value.isEmpty else { return "Enter a message to send." }
        guard value.utf8.count <= 24_000, value.count <= 6_000 else {
            return "Shorten the message to 6,000 characters and 24,000 UTF-8 bytes."
        }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || [9, 10, 13].contains($0.value) }) else {
            return "Remove unsupported control characters from the message."
        }
        return nil
    }
}

/// Temporary diagnostic chat logger saving all messages to Downloads folder.
/// Will be removed in final production release per user request.
enum DiagnosticChatLogger {
    private static let lock = NSLock()
    private static let logURL: URL? = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dot_chat_log.txt")
    }()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func record(role: String, text: String) {
        guard let url = logURL else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(role.uppercased())] \(trimmed)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            let header = "# Dot Conversation Diagnostic Log (Temporary)\n# Created: \(timestamp)\n# Records all user prompts and assistant actions/responses for debugging.\n\n"
            var combined = header.data(using: .utf8) ?? Data()
            combined.append(data)
            try? combined.write(to: url, options: .atomic)
        }
    }

    static func recordFailure(task: String, reason: String, missingCapability: String, proposedFix: String) {
        let msg = "TASK: \"\(task)\" | REASON: \(reason) | MISSING: \(missingCapability) | PROPOSED_FIX: \(proposedFix)"
        record(role: "dot (self-improvement)", text: msg)
    }
}

enum DotMovementCommand: String, Sendable {
    case left
    case right
    case up
    case down
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case center
    case away
    case random
}

@MainActor
final class ChatModel: ObservableObject {
    var onMove: ((DotMovementCommand) -> String?)?
    var onPhaseChanged: ((PetPhase) -> Void)?
    @Published private(set) var phase: PetPhase = .idle { didSet { if phase.isActive { placementInvalidated?() }; updateProactiveContext(); onPhaseChanged?(phase) } }
    @Published private(set) var issue: CompanionIssue?
    @Published private(set) var answer = ""
    /// Identity of the displayed text, retained on Stop so history can describe
    /// interrupted delivery without treating the replacement turn as its owner.
    @Published private(set) var displayedAnswerTurn: UUID?
    @Published private(set) var voiceDeliveryNotice: String?
    @Published private(set) var captureOutcome: String?
    private var captureOutcomeTask: Task<Void, Never>?
    @Published private(set) var firstUseHint: Bool
    private var lastAttemptedText: String?
    @Published var pinned: Bool {
        didSet { defaults.set(pinned, forKey: "petPinned"); placementInvalidated?() }
    }
    @Published var hovered = false { didSet { if hovered { placementInvalidated?() }; updateProactiveContext() } }
    @Published var interactionPaused = false { didSet { if interactionPaused { placementInvalidated?(); cancelForInteraction() }; updateProactiveContext() } }
    var placementInvalidated: (() -> Void)?
    @Published var placementCapturing = false
    var showOptions: (() -> Void)?
    /// The integration owner pauses optional research before foreground work.
    var onForegroundInteraction: (() -> Void)?
    let textHistory: ConversationHistoryModel
    let voiceTiming: VoiceTimingSettings
    let skinPreferences: SkinPreferences
    let proactive: ProactiveBehavior
    private let defaults: UserDefaults
    private let runtime: ChatRuntime
    let ftsStore: LocalFTSStore
    @Published private(set) var idleMotionOffset = IdleMotionOffset.zero
    private var idleMotion = IdleMotionCore()
    private var proactiveEvidence = ProactiveConversationEvidence()
    private var proactiveTurn: (opportunity: UUID, turn: UUID)?
    private var proactiveContextChange: ProactiveContextChange?
    private var proactiveContextChangedAfterUser = false
    private var externalInteractionBusy = false
    private var controlInteraction = false
    private var recentProactiveReplies: [String] = []
    private let followup: VoiceFollowup
    private var voiceRoute: VoiceAudioRoute?
    @Published private(set) var automaticReply = false
    @Published private(set) var expressionRevision: UInt64 = 0
    @Published private(set) var taskHalo: LongTaskProgress.Halo = .hidden
    @Published private(set) var taskStage: String?
    @Published private(set) var taskStatusText: String?
    private var taskProgress = ResearchTaskProgress()
    private var activeSpeechUpdateID: UUID?
    private var taskProgressTicker: Task<Void, Never>?
    private var selfReflectionTicker: Task<Void, Never>?
    private var shuttingDown = false
    var onExecuteAction: ((NativeAction) async -> NativeActionResult?)?
    var onRequestResearch: ((String) -> Void)?

    func speakDirect(_ text: String) {
        guard !shuttingDown, runtime.isReady(), phase == .idle else { return }
        DiagnosticChatLogger.record(role: "dot", text: text)
        let id = cancelTurn()
        answer = text
        displayedAnswerTurn = id
        phase = .speaking
        expressionRevision &+= 1
        do {
            try runtime.startVoice(id)
            runtime.enqueueVoice(text, id)
            runtime.completeVoice(id)
        } catch {
            phase = .idle
        }
    }

    private func detectNativeAction(_ text: String) -> NativeAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120 else { return nil }
        let lower = trimmed.lowercased()

        // 1. Direct Web URLs
        if lower.hasPrefix("open http://") || lower.hasPrefix("open https://") {
            let url = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .openWebURL(url)
        }
        if lower.hasPrefix("open ") {
            let target = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let siteMap: [String: String] = [
                "google": "https://www.google.com",
                "youtube": "https://www.youtube.com",
                "github": "https://www.github.com",
                "twitter": "https://x.com",
                "x": "https://x.com",
                "reddit": "https://www.reddit.com",
                "wikipedia": "https://www.wikipedia.org",
                "amazon": "https://www.amazon.com",
                "netflix": "https://www.netflix.com",
                "chatgpt": "https://chatgpt.com"
            ]
            if let siteURL = siteMap[target.lowercased()] {
                return .openWebURL(siteURL)
            }
            let domains = [".com", ".org", ".net", ".io", ".dev", ".app", ".ai", ".co", ".me", ".info", ".edu", ".gov"]
            if !target.contains(" ") && domains.contains(where: { target.lowercased().contains($0) }) {
                let validURL = target.hasPrefix("http://") || target.hasPrefix("https://") ? target : "https://" + target
                return .openWebURL(validURL)
            }
        }

        // 2. Folder Creation
        if lower.hasPrefix("create folder ") || lower.hasPrefix("make folder ") || lower.hasPrefix("new folder ") {
            let folderName = trimmed.components(separatedBy: " ").dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !folderName.isEmpty && !folderName.contains("/") {
                return .createFolder(path: folderName)
            }
        }

        // 3. File Creation
        if lower.hasPrefix("create file ") || lower.hasPrefix("new file ") {
            let remainder = trimmed.components(separatedBy: " ").dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = remainder.components(separatedBy: " with content ")
            let filename = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let content = parts.count > 1 ? parts[1] : ""
            if !filename.isEmpty && !filename.contains("/") {
                return .createText(path: filename, text: content)
            }
        }

        // 4. File Reading
        if lower.hasPrefix("read file ") || lower.hasPrefix("show file ") {
            let prefix = lower.hasPrefix("read file ") ? "read file " : "show file "
            let filename = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !filename.isEmpty && !filename.contains("/") {
                return .readText(path: filename)
            }
        }

        // 5. Applications
        if lower.hasPrefix("open ") || lower.hasPrefix("launch ") {
            let appName = lower.hasPrefix("open ") ? String(lower.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) : String(lower.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            let appMap: [String: String] = [
                "safari": "com.apple.Safari",
                "terminal": "com.apple.Terminal",
                "finder": "com.apple.finder",
                "notes": "com.apple.Notes",
                "mail": "com.apple.mail",
                "calendar": "com.apple.iCal",
                "messages": "com.apple.MobileSMS",
                "music": "com.apple.Music",
                "maps": "com.apple.Maps",
                "calculator": "com.apple.calculator",
                "xcode": "com.apple.dt.Xcode",
                "settings": "com.apple.systempreferences",
                "system settings": "com.apple.systempreferences",
                "preferences": "com.apple.systempreferences",
                "system preferences": "com.apple.systempreferences",
                "textedit": "com.apple.TextEdit",
                "preview": "com.apple.Preview",
                "reminders": "com.apple.reminders",
                "photos": "com.apple.Photos",
                "chrome": "com.google.Chrome",
                "google chrome": "com.google.Chrome",
                "code": "com.microsoft.VSCode",
                "vs code": "com.microsoft.VSCode",
                "vscode": "com.microsoft.VSCode",
                "visual studio code": "com.microsoft.VSCode",
                "spotify": "com.spotify.client",
                "slack": "com.tinyspeck.slackmacgap",
                "discord": "com.hnc.Discord",
                "notion": "notion.id",
                "telegram": "ru.keepcoder.Telegram",
                "whatsapp": "net.whatsapp.WhatsApp",
                "docker": "com.docker.docker",
                "activity monitor": "com.apple.ActivityMonitor",
                "weather": "com.apple.weather",
                "podcasts": "com.apple.podcasts",
                "app store": "com.apple.AppStore",
                "keynote": "com.apple.iWork.Keynote",
                "pages": "com.apple.iWork.Pages",
                "numbers": "com.apple.iWork.Numbers"
            ]
            if let bundleID = appMap[appName] {
                return .launchApplication(bundleID: bundleID)
            }
            for base in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
                for name in [appName.capitalized, appName.uppercased(), appName] {
                    let candidate = base + "/" + name + ".app"
                    if let bundle = Bundle(path: candidate), let id = bundle.bundleIdentifier {
                        return .launchApplication(bundleID: id)
                    }
                }
            }
        }

        // 6. Keyboard Shortcuts
        if lower == "refresh this page" || lower == "refresh the page" || lower == "refresh page" ||
           lower == "reload this page" || lower == "reload the page" || lower == "reload page" ||
           lower == "refresh website" || lower == "refresh this website" {
            return .sendShortcut(modifiers: ["Cmd"], keys: "R")
        }
        if lower == "new tab" || lower == "open new tab" || lower == "open a new tab" {
            return .sendShortcut(modifiers: ["Cmd"], keys: "T")
        }
        if lower == "close tab" || lower == "close this tab" || lower == "close the tab" {
            return .sendShortcut(modifiers: ["Cmd"], keys: "W")
        }
        if lower == "reopen tab" || lower == "reopen closed tab" || lower == "reopen the closed tab" {
            return .sendShortcut(modifiers: ["Cmd", "Shift"], keys: "T")
        }
        if lower == "select all" || lower == "select all text" {
            return .sendShortcut(modifiers: ["Cmd"], keys: "A")
        }
        if lower == "copy" || lower == "copy that" || lower == "copy this" {
            return .sendShortcut(modifiers: ["Cmd"], keys: "C")
        }
        if lower == "paste" || lower == "paste that" || lower == "paste here" {
            return .sendShortcut(modifiers: ["Cmd"], keys: "V")
        }

        // 7. Mouse Control & UI Element Clicking
        if lower.hasPrefix("double click ") || lower.hasPrefix("double-click ") {
            let desc = trimmed.components(separatedBy: " ").dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return .clickElement(description: desc)
        }
        if lower.hasPrefix("click ") || lower.hasPrefix("click on ") || lower.hasPrefix("click the ") || lower.hasPrefix("click that ") {
            var desc = trimmed.components(separatedBy: " ").dropFirst(1).joined(separator: " ")
            if desc.lowercased().hasPrefix("on ") { desc = String(desc.dropFirst(3)) }
            if desc.lowercased().hasPrefix("the ") { desc = String(desc.dropFirst(4)) }
            if desc.lowercased().hasPrefix("that ") { desc = String(desc.dropFirst(5)) }
            desc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty {
                return .clickElement(description: desc)
            }
        }
        if lower.hasPrefix("move mouse to ") || lower.hasPrefix("move cursor to ") {
            let desc = lower.components(separatedBy: " ").dropFirst(3).joined(separator: " ")
            if desc.contains("center") || desc.contains("middle") {
                let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                return .moveMouse(to: CGPoint(x: frame.midX, y: frame.midY))
            }
        }
        return nil
    }

    private func detectWebSearchQuery(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = [
            "search the web for ",
            "search web for ",
            "search for ",
            "research ",
            "look up "
        ]
        for p in prefixes {
            if lower.hasPrefix(p) {
                let query = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty { return query }
            }
        }
        return nil
    }

    private func detectSystemControlCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 250 else { return nil }
        var clean = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:;\"'"))

        // Common conversational prefixes
        let prefixes = [
            "can you please ", "could you please ", "can you ", "could you ", "would you ",
            "please ", "hey dot ", "dot ", "i want you to ", "try to ",
            "yes, ", "yes ", "ok, ", "ok ", "okay, ", "okay ", "sure, ", "sure ",
            "i mean, ", "i mean ", "пожалуйста ", "дот "
        ]
        for p in prefixes {
            if clean.hasPrefix(p) {
                clean = String(clean.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:;\"'"))

        let suiteCmd = SystemControlSuite.parseCommand(clean)
        if suiteCmd != .none {
            if let result = SystemControlSuite.execute(suiteCmd) {
                return result
            }
        }

        // 1. User Correction: "You did not move yourself" / "Fix it"
        if clean.contains("did not move") || clean.contains("didn't move") || (clean.contains("fix it") && (clean.contains("move") || clean.contains("screen"))) {
            DiagnosticChatLogger.recordFailure(
                task: text,
                reason: "User indicated movement was missed or incomplete",
                missingCapability: "Corrective movement dispatch on feedback",
                proposedFix: "Execute immediate corrective relocation"
            )
            Task { [weak self] in
                _ = try? await self?.ftsStore.saveMemory(category: .userCorrection, fact: "User instructed: \(text). Always execute movement immediately when asked.", isCorrection: true)
            }
            if let reply = self.onMove?(.center) ?? self.onMove?(.random) {
                return "I apologize! " + reply
            }
            return "I apologize! Relocating right now."
        }

        // 2. Pin / Freeze Control
        if clean == "pin" || clean == "pin yourself" || clean == "pin in place" || clean == "freeze" || clean == "stay there" || clean == "stop moving" || clean == "don't move" || clean == "закрепись" || clean == "не двигайся" {
            pinned = true
            return "I've pinned myself in place. I will stay right here until you unpin me."
        }
        if clean == "unpin" || clean == "unpin yourself" || clean == "roam freely" || clean == "you can move" || clean == "start moving" || clean == "открепись" || clean == "можешь двигаться" {
            pinned = false
            return "Unpinned! I'll roam around the screen freely."
        }

        // 3. Sound & Volume Control
        if clean == "mute" || clean == "mute sound" || clean == "mute volume" || clean == "mute audio" || clean == "тишина" || clean == "выключи звук" {
            var err: NSDictionary?
            _ = NSAppleScript(source: "set volume with output muted")?.executeAndReturnError(&err)
            return "Muted audio output."
        }
        if clean == "unmute" || clean == "unmute sound" || clean == "unmute audio" || clean == "включи звук" {
            var err: NSDictionary?
            _ = NSAppleScript(source: "set volume without output muted")?.executeAndReturnError(&err)
            return "Unmuted audio output."
        }
        if clean == "volume up" || clean == "louder" || clean == "turn up volume" || clean == "громче" {
            var err: NSDictionary?
            _ = NSAppleScript(source: "set volume output volume ((output volume of (get volume settings)) + 12)")?.executeAndReturnError(&err)
            return "Turned volume up."
        }
        if clean == "volume down" || clean == "quieter" || clean == "lower volume" || clean == "turn down volume" || clean == "тише" {
            var err: NSDictionary?
            _ = NSAppleScript(source: "set volume output volume ((output volume of (get volume settings)) - 12)")?.executeAndReturnError(&err)
            return "Turned volume down."
        }
        if clean.hasPrefix("set volume to ") || clean.hasPrefix("volume to ") || clean.hasPrefix("volume ") {
            let digits = clean.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.first
            if let digits, let level = Int(digits), (0...100).contains(level) {
                var err: NSDictionary?
                _ = NSAppleScript(source: "set volume output volume \(level)")?.executeAndReturnError(&err)
                return "Set volume to \(level)%."
            }
        }

        // 4. Battery Status
        if clean == "battery" || clean == "battery level" || clean == "check battery" || clean == "battery status" || clean == "how much battery" || clean == "батарея" || clean == "заряд" {
            if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
               let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [AnyObject] {
                for s in sources {
                    if let desc = IOPSGetPowerSourceDescription(blob, s)?.takeUnretainedValue() as? [String: Any],
                       let current = desc[kIOPSCurrentCapacityKey] as? Int {
                        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                        return "Battery is at \(current)% (\(isCharging ? "charging" : "on battery"))."
                    }
                }
            }
            return "Could not read battery information."
        }

        // 5. Clipboard
        if clean == "what's on my clipboard" || clean == "what is on my clipboard" || clean == "read clipboard" || clean == "show clipboard" || clean == "clipboard" || clean == "буфер обмена" {
            if let content = NSPasteboard.general.string(forType: .string), !content.isEmpty {
                let preview = content.count > 160 ? String(content.prefix(160)) + "…" : content
                return "Your clipboard contains: \(preview)"
            }
            return "Your clipboard is currently empty."
        }
        if clean.hasPrefix("copy to clipboard: ") || clean.hasPrefix("copy to clipboard ") || clean.hasPrefix("copy ") {
            let prefix = clean.hasPrefix("copy to clipboard: ") ? "copy to clipboard: " : (clean.hasPrefix("copy to clipboard ") ? "copy to clipboard " : "copy ")
            let textToCopy = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !textToCopy.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(textToCopy, forType: .string)
                return "Copied to clipboard: \"\(textToCopy.prefix(60))\""
            }
        }

        // 6. Close / Quit Application
        if clean.hasPrefix("close ") || clean.hasPrefix("quit ") || clean.hasPrefix("terminate ") || clean.hasPrefix("закрыть ") {
            let prefix = clean.hasPrefix("close ") ? "close " : (clean.hasPrefix("quit ") ? "quit " : (clean.hasPrefix("terminate ") ? "terminate " : "закрыть "))
            let appName = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !appName.isEmpty && !["the window", "window", "tab", "file"].contains(appName) {
                let running = NSWorkspace.shared.runningApplications
                if let target = running.first(where: {
                    $0.localizedName?.lowercased() == appName ||
                    $0.bundleIdentifier?.lowercased().hasSuffix("." + appName) == true ||
                    $0.localizedName?.lowercased().contains(appName) == true
                }) {
                    let name = target.localizedName ?? appName
                    target.terminate()
                    return "Closed \(name)."
                }
                return "Could not find a running app named \(appName.capitalized)."
            }
        }

        // 7. Standard Folders in Finder
        if clean == "open downloads" || clean == "show downloads" || clean == "open downloads folder" || clean == "show downloads folder" {
            if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(url)
                return "Opened your Downloads folder."
            }
        }
        if clean == "open documents" || clean == "show documents" || clean == "open documents folder" || clean == "show documents folder" {
            if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(url)
                return "Opened your Documents folder."
            }
        }
        if clean == "open desktop" || clean == "show desktop" || clean == "open desktop folder" {
            if let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(url)
                return "Opened your Desktop folder."
            }
        }
        if clean == "open applications" || clean == "show applications" || clean == "open applications folder" || clean == "show applications folder" {
            if let url = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first {
                NSWorkspace.shared.open(url)
                return "Opened your Applications folder."
            }
        }
        if clean == "open trash" || clean == "show trash" {
            if let url = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(url)
                return "Opened the Trash folder."
            }
        }
        if clean == "system info" || clean == "mac info" || clean == "os version" || clean == "about this mac" {
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let host = Host.current().localizedName ?? "Mac"
            let uptimeHours = Int(ProcessInfo.processInfo.systemUptime / 3600)
            let uptimeMins = Int((ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(host) is running macOS \(os) (uptime: \(uptimeHours)h \(uptimeMins)m)."
        }

        // 8. Math / Arithmetic Calculator
        if clean.hasPrefix("calculate ") || clean.hasPrefix("what is ") || clean.hasPrefix("math ") || clean.hasPrefix("посчитай ") {
            let prefix = clean.hasPrefix("calculate ") ? "calculate " : (clean.hasPrefix("what is ") ? "what is " : (clean.hasPrefix("math ") ? "math " : "посчитай "))
            let remainder = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = remainder.replacingOccurrences(of: "x", with: "*")
                                     .replacingOccurrences(of: "X", with: "*")
                                     .replacingOccurrences(of: "×", with: "*")
                                     .replacingOccurrences(of: "÷", with: "/")
            let mathAllowed = CharacterSet(charactersIn: "0123456789+-*/.() %")
            if sanitized.unicodeScalars.allSatisfy({ mathAllowed.contains($0) }) && sanitized.contains(where: { "+-*/".contains($0) }) {
                let exp = NSExpression(format: sanitized)
                if let val = exp.expressionValue(with: nil, context: nil) as? NSNumber {
                    return "\(remainder) = \(val)"
                }
            }
        }

        // 9. Inquiries about why Dot is not moving / staying in one spot
        if clean.contains("why") && (clean.contains("don't move") || clean.contains("dont move") || clean.contains("stay in the same place") || clean.contains("stay in one place") || clean.contains("aren't you moving") || clean.contains("not moving")) {
            if let reply = self.onMove?(.random) {
                return "I roam to new spots every 5 seconds when idle, and immediately relocate every 5 seconds while thinking! " + reply
            }
            return "I roam to new spots every 5 seconds when idle, and immediately relocate every 5 seconds while thinking! Relocating right now."
        }

        // 10. Codebase & GitHub Repository Access
        if clean.contains("open repo") || clean.contains("open repository") || clean.contains("open github") ||
           clean.contains("show repo") || clean.contains("repo link") || clean.contains("github link") ||
           clean.contains("latest code") || clean.contains("check for updates") || clean.contains("view github") ||
           clean == "repo" || clean == "github" || clean.contains("where is your code") {
            let repoURL = "https://github.com/Emin-dev/Dot"
            if let url = URL(string: repoURL) {
                NSWorkspace.shared.open(url)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(repoURL, forType: .string)
            return "Here is my official GitHub repository: \(repoURL). I've opened it in your browser and copied the link to your clipboard so you can always see my latest updated code!"
        }
        if clean.contains("read your own code") || clean.contains("see your own code") || clean.contains("read your code") || clean.contains("see your code") || clean.contains("inspect your code") || clean == "can you see and read your own code" || clean == "can you read your own code" {
            let root = URL(fileURLWithPath: "/Users/mac/.gemini/antigravity/scratch/Dot")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("src").path))?.filter { $0.hasSuffix(".swift") } ?? []
            return "Yes! I have direct access to read and inspect my source code at /Users/mac/.gemini/antigravity/scratch/Dot, and my open-source repository is at https://github.com/Emin-dev/Dot. I have \(files.count) Swift files including App.swift, ChatView.swift, RoamingCore.swift, Engine.swift, NativeActions.swift, and more. You can ask me to read or explain any file!"
        }
        if clean == "list your files" || clean == "list files" || clean == "show your files" || clean == "show files in code" || clean == "what files do you have" || clean == "show codebase files" {
            let root = URL(fileURLWithPath: "/Users/mac/.gemini/antigravity/scratch/Dot")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("src").path))?.filter { $0.hasSuffix(".swift") }.sorted() ?? []
            let topFiles = files.prefix(8).joined(separator: ", ")
            return "My codebase has \(files.count) Swift modules including \(topFiles), and more. You can also view the latest updated code on GitHub at https://github.com/Emin-dev/Dot."
        }

        // 11. Permission Status Check
        if clean.contains("screen permission") || clean.contains("permission for screen") || clean.contains("screen access") ||
           clean == "check permissions" || clean == "do you have permission" || clean == "do you have permissions" ||
           clean == "do you have screen permission" || clean == "do you have access to screen" ||
           clean == "check screen permission" || clean == "permission status" {
            let hasAccess = CGPreflightScreenCaptureAccess()
            if hasAccess {
                return "I already have Screen Recording permission granted on this Mac! I can see your screen whenever screen context is enabled, and I never re-prompt for permission."
            } else {
                return "Screen Recording permission is not granted yet in macOS System Settings. If you'd like me to see your screen, you can enable Dot in System Settings → Privacy & Security → Screen Recording."
            }
        }

        // 12. Read Source Code or Document File
        if clean.hasPrefix("read file ") || clean.hasPrefix("show file ") || clean.hasPrefix("read code ") || clean.hasPrefix("show code ") {
            let prefix = clean.hasPrefix("read file ") ? "read file " : (clean.hasPrefix("show file ") ? "show file " : (clean.hasPrefix("read code ") ? "read code " : "show code "))
            var pathStr = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            pathStr = pathStr.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            let root = URL(fileURLWithPath: "/Users/mac/.gemini/antigravity/scratch/Dot")
            var candidates = [
                root.appendingPathComponent(pathStr),
                root.appendingPathComponent("src").appendingPathComponent(pathStr),
                URL(fileURLWithPath: pathStr)
            ]
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                candidates.append(docs.appendingPathComponent(pathStr))
            }
            for candidate in candidates {
                if FileManager.default.fileExists(atPath: candidate.path), let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    let lines = content.components(separatedBy: "\n")
                    let preview = lines.prefix(15).joined(separator: "\n")
                    let name = candidate.lastPathComponent
                    return "Here is \(name) (\(lines.count) lines). I have copied the full file to your clipboard!\n\n\(preview)..."
                }
            }
            return "Could not find file \(pathStr)."
        }

        // 13. Hardware Requirements & System Specifications Check
        if clean.contains("hardware check") || clean.contains("check hardware") || clean.contains("specs") ||
           clean.contains("system specs") || clean.contains("hardware requirements") || clean.contains("minimum specs") ||
           clean.contains("can my mac run dot") || clean == "hardware" || clean == "system requirements" ||
           clean.contains("what are your minimum specs") || clean.contains("minimum specification") {
            return HardwareCompatibility.statusSummary()
        }

        return nil
    }

    func detectMovementCommand(_ text: String) -> DotMovementCommand? {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:;\"'"))
        guard clean.count <= 250 else { return nil }

        let prefixes = [
            "can you please ", "could you please ", "can you ", "could you ", "would you ",
            "please ", "hey dot ", "dot ", "i want you to ", "try to ",
            "yes, ", "yes ", "yeah, ", "yeah ", "ok, ", "ok ", "okay, ", "okay ", "sure, ", "sure ",
            "i mean, ", "i mean ", "well, ", "well ", "now ",
            "пожалуйста ", "дот "
        ]
        for p in prefixes {
            if clean.hasPrefix(p) {
                clean = String(clean.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:;\"'"))
        clean = clean.replacingOccurrences(of: "yourself, yourself", with: "yourself")
        clean = clean.replacingOccurrences(of: "to the screen ", with: "to ")
        clean = clean.replacingOccurrences(of: "to screen ", with: "to ")
        clean = clean.replacingOccurrences(of: "on the screen", with: "")
        clean = clean.replacingOccurrences(of: "on screen", with: "")
        clean = clean.replacingOccurrences(of: "of the screen", with: "")
        clean = clean.replacingOccurrences(of: "of screen", with: "")
        clean = clean.replacingOccurrences(of: "to center to screen", with: "to center")

        let actionPrefixes = [
            "move yourself to the ", "move yourself to ", "move yourself ",
            "move to the ", "move to ", "move ",
            "go to the ", "go to ", "go ",
            "shift to the ", "shift to ", "shift ",
            "slide to the ", "slide to ", "slide ",
            "jump to the ", "jump to ", "jump ",
            "step to the ", "step to ", "step ",
            "put yourself at the ", "put yourself in the ", "put yourself in ", "put yourself on ", "put yourself ",
            "переместись в ", "переместись на ", "подвинься в ", "подвинься на ", "иди в ", "встань в "
        ]
        for p in actionPrefixes {
            if clean.hasPrefix(p) {
                clean = String(clean.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:;\"'"))
        if clean.hasPrefix("the ") {
            clean = String(clean.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if clean.hasPrefix("screen ") {
            clean = String(clean.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Corner / Center checks
        if clean.contains("top left") || clean.contains("top-left") || clean.contains("upper left") ||
           clean == "left top" || clean == "влево вверх" || clean.contains("левый верхний") {
            return .topLeft
        }
        if clean.contains("top right") || clean.contains("top-right") || clean.contains("upper right") ||
           clean == "right top" || clean == "вправо вверх" || clean.contains("правый верхний") {
            return .topRight
        }
        if clean.contains("bottom left") || clean.contains("bottom-left") || clean.contains("lower left") ||
           clean == "left bottom" || clean == "влево вниз" || clean.contains("левый нижний") {
            return .bottomLeft
        }
        if clean.contains("bottom right") || clean.contains("bottom-right") || clean.contains("lower right") ||
           clean == "right bottom" || clean == "вправо вниз" || clean.contains("правый нижний") {
            return .bottomRight
        }
        if clean == "center" || clean == "middle" || clean.contains("center") || clean.contains("middle") ||
           clean == "в центр" || clean.contains("по центру") || clean.contains("посередине") || clean.contains("середин") {
            return .center
        }

        // Directional checks
        // Left
        if clean == "left" || clean.contains("left") || clean == "влево" || clean == "налево" || clean.contains("влево") {
            return .left
        }
        // Right
        if clean == "right" || clean.contains("right") || clean == "вправо" || clean == "направо" || clean.contains("вправо") {
            return .right
        }
        // Up
        if clean == "up" || clean == "higher" || clean.contains("up") || clean == "вверх" || clean == "наверх" || clean.contains("вверх") {
            return .up
        }
        // Down
        if clean == "down" || clean == "lower" || clean.contains("down") || clean == "вниз" || clean.contains("вниз") {
            return .down
        }

        // Away / Dodge
        if clean.contains("away") || clean.contains("aside") || clean.contains("out of the way") ||
           clean.contains("dodge") || clean.contains("evade") || clean.contains("scoot") ||
           clean == "отойди" || clean == "уйди" || clean.contains("в сторону") {
            return .away
        }

        // General move / relocate / random
        if clean == "move" || clean == "move around" || clean == "relocate" || clean == "random move" ||
           clean == "change position" || clean == "somewhere" || clean == "somewhere else" ||
           clean == "wander" || clean == "roam" || clean == "random" ||
           clean.contains("move yourself") || clean.contains("move to screen") || clean.contains("move on screen") ||
           clean.contains("randomly move") || clean.contains("move randomly") ||
           clean == "двигайся" || clean == "подвигайся" || clean == "переместись" || clean == "смени позицию" {
            return .random
        }

        return nil
    }

    func handleTaskProgress(_ event: ResearchTaskProgress.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = taskProgress.receive(event, now: now)
        if accepted {
            updateTaskProgressUI(now: now)
            ensureTaskProgressTicker()
        }
    }

    func updateTaskProgressUI(now: Double = ProcessInfo.processInfo.systemUptime) {
        taskHalo = taskProgress.progress.halo
        taskStage = taskProgress.progress.snapshot?.stage
        taskStatusText = taskProgress.progress.textStatus
        pollTaskSpeech(now: now)
    }

    private func ensureTaskProgressTicker() {
        guard taskProgressTicker == nil else { return }
        taskProgressTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { break }
                let now = ProcessInfo.processInfo.systemUptime
                self.updateTaskProgressUI(now: now)
                if self.taskHalo == .hidden && self.activeSpeechUpdateID == nil {
                    break
                }
            }
            self?.taskProgressTicker = nil
        }
    }

    private func pollTaskSpeech(now: Double) {
        var context = LongTaskProgress.SpeechContext()
        context.ready = runtime.isReady()
        context.muted = defaults.bool(forKey: "voiceMuted")
        context.userSpeaking = stt.recording && stt.level > 0.15
        context.listening = stt.recording || stt.transcribing
        context.voiceBusy = runtime.ttsSpeaking() && (activeSpeechUpdateID == nil)
        context.foregroundInterrupted = interactionPaused || hovered || historyPresented
        context.quiet = false
        context.callActive = false
        _ = taskProgress.setSpeechContext(context)

        guard activeSpeechUpdateID == nil else { return }
        guard let speech = taskProgress.takeSpeech(now: now) else { return }
        activeSpeechUpdateID = speech.id
        DiagnosticChatLogger.record(role: "dot (task)", text: speech.text)
        do {
            try runtime.startVoice(speech.id)
            runtime.enqueueVoice(speech.text, speech.id)
            runtime.completeVoice(speech.id)
        } catch {
            activeSpeechUpdateID = nil
        }
    }
    var historyPresented = false { didSet { if historyPresented { cancelForInteraction() }; updateProactiveContext() } }
    var visible = true { didSet { if !visible { cancelTurn() }; updateProactiveContext() } }
    var followupPending: Bool { followup.pending }
    var canSubmitTyped: Bool { !shuttingDown && runtime.isReady() }
    let stt: STTManager
    let tts: TTSManager
    let engine: EngineManager
    let screen = ScreenContext()
    @Published var screenEnabled: Bool { didSet { ScreenPrivacyPreference.setEnabled(screenEnabled, in: defaults); screen.enabled = screenEnabled; placementInvalidated?(); cancelTurn() } }
    @Published private(set) var screenContextUsed = false
    @Published private(set) var capturingScreen = false
    private var gate = TurnGate()
    private var work: Task<Void, Never>?
    private let warmup = TurnWarmup()
    private var generating = false
    private var currentTurnIsTyped = false
    private var voiceDeliveryFailed = false
    private var history: [ChatMessage] = []
    private var chunker = SentenceBuffer()
    private var clickedAt = 0.0
    private var firstReasoning = false
    private var firstAnswer = false
    private var firstAudio = false
    private var speechEndedAt: Double?
    private var silenceSatisfiedAt: Double?
    private static let timingLog = Logger(subsystem: "app.dot", category: "timing")
    private func timing(_ stage: String) {
        // Durations only. Never log speech, prompts, replies or model paths.
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - clickedAt) * 1000)
        Self.timingLog.notice("DOT_TIMING \(stage, privacy: .public)=\(milliseconds)ms")
    }

    private static let runtimeLog = Logger(subsystem: "app.dot", category: "runtime")
    private func logFailure(_ error: Error, stage: PipelineDiagnostic.Stage) {
        let actualStage: PipelineDiagnostic.Stage = error is ScreenContextGate.Failure ? .capture : stage
        let reason: PipelineDiagnostic.Reason
        if let value = error as? ScreenContext.ScreenFailure {
            switch value {
            case .permission: reason = .permission
            case .unsupported: reason = .unsupported
            case .unavailable: reason = .unavailable
            }
        } else if let value = error as? ScreenContextGate.Failure {
            switch value {
            case .permissionDenied: reason = .permission
            case .unsupportedModel: reason = .unsupported
            case .disabled, .unavailable, .stale, .invalidImage: reason = .captureFailed
            }
        } else if let value = error as? EngineError {
            switch value {
            case .configuration, .unavailable, .busy: reason = .unavailable
            case .identity: reason = .identity
            case .response: reason = .invalidResponse
            case .empty: reason = .emptyResponse
            }
        } else if error is ResponseLimit { reason = .resourceLimit }
        else if error is URLError { reason = .transport }
        else { reason = stage == .capture ? .captureFailed : stage == .voice ? .voiceFailed : .unknown }
        guard let diagnostic = PipelineDiagnostic.failure(stage: actualStage, reason: reason,
            cancelled: Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled) else { return }
        Self.runtimeLog.error("\(diagnostic.logLine, privacy: .public)")
    }

    init(engine: EngineManager? = nil, textHistory: ConversationHistoryModel? = nil,
         defaults: UserDefaults = .standard, followup: VoiceFollowup? = nil,
         proactive: ProactiveBehavior? = nil, runtime: ChatRuntime? = nil) {
        let stt = STTManager(), tts = TTSManager()
        self.stt = stt; self.tts = tts
        self.engine = engine ?? EngineManager()
        self.textHistory = textHistory ?? ConversationHistoryModel()
        self.ftsStore = (try? LocalFTSStore()) ?? (try! LocalFTSStore(inMemory: true))
        self.defaults = defaults
        voiceTiming = VoiceTimingSettings(defaults: defaults)
        skinPreferences = SkinPreferences(defaults: defaults)
        self.proactive = proactive ?? ProactiveBehavior(defaults: defaults)
        self.followup = followup ?? VoiceFollowup()
        firstUseHint = !defaults.bool(forKey: "dot.interactionHintDismissed.v1")
        pinned = defaults.bool(forKey: "petPinned")
        screenEnabled = ScreenPrivacyPreference.enabled(in: defaults)
        self.runtime = runtime ?? ChatRuntime(
            isReady: { OfflinePreparation.shared.ready },
            startPreparation: { OfflinePreparation.shared.start(nativeRecognizerAvailable: WhisperRecognizer.available) },
            microphoneAuthorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
            currentRoute: { VoiceAudioRoute.current() }, screenAuthorized: { CGPreflightScreenCaptureAccess() },
            startVoice: { try tts.start(id: $0) }, enqueueVoice: { tts.enqueue($0, id: $1) },
            completeVoice: { tts.markGenerationComplete(id: $0) }, stopVoice: { tts.stop() },
            ttsSpeaking: { tts.speaking }, startCapture: { await stt.start(id: $0, settings: $1, invitation: $2) },
            stopCapture: { stt.cancel() }, recording: { stt.recording }, transcribing: { stt.transcribing },
            forceFinishCapture: { stt.forceFinishCapture() })
        let followup = self.followup, textHistory = self.textHistory, proactive = self.proactive
        textHistory.onDelete = { [weak self] in self?.reset() }
        followup.environment = { [weak self] in
            guard let self else { return .init(ready: false, microphoneAuthorized: false, screenAuthorized: false, interacting: true) }
            let current = self.runtime.currentRoute()
            let routeMatches = (self.voiceRoute == nil || current == nil || (self.voiceRoute?.input == current?.input && self.voiceRoute?.output == current?.output))
            return .init(ready: self.runtime.isReady() && self.visible && !self.runtime.ttsSpeaking() && !self.runtime.recording() && !self.runtime.transcribing() && routeMatches,
                microphoneAuthorized: self.runtime.microphoneAuthorized(),
                screenAuthorized: true,
                interacting: self.interactionPaused || self.historyPresented || self.controlInteraction)
        }
        followup.onInvite = { [weak self] previous, continuation in
            guard let self, self.gate.accepts(previous), self.visible, !self.interactionPaused, !self.controlInteraction else { return }
            self.beginListening(continuation: continuation)
        }
        stt.onCaptureEnded = { [weak self] id, reason in
            guard let self, self.gate.accepts(id) else { return }
            self.cancelTurn()
            if let message = reason.recoveryMessage { self.block(message, issue: .speech) }
            else { self.showCaptureOutcome(reason == .noSpeech ? "No reply" : "Stopped") }
        }
        stt.onSpeechEnded = { [weak self] id, evidence in
            guard let self, self.gate.accepts(id) else { return }
            guard [evidence.captureStartedAt, evidence.firstSpeechAt, evidence.speechEndedAt, evidence.silenceSatisfiedAt].allSatisfy(\.isFinite),
                  VoiceTimingSettings.silenceChoices.contains(evidence.selectedSilenceSeconds),
                  evidence.captureStartedAt <= evidence.firstSpeechAt,
                  evidence.firstSpeechAt <= evidence.speechEndedAt,
                  abs(evidence.silenceSatisfiedAt - evidence.speechEndedAt - evidence.selectedSilenceSeconds) < 0.000001 else { return }
            self.speechEndedAt = evidence.speechEndedAt
            self.silenceSatisfiedAt = evidence.silenceSatisfiedAt
            let milliseconds = Int(evidence.selectedSilenceSeconds * 1000)
            Self.timingLog.notice("DOT_TIMING selected_silence=\(milliseconds)ms")
        }
        screen.enabled = screenEnabled
        proactiveEvidence.recordUser(turn: UUID(), now: ProcessInfo.processInfo.systemUptime)
        self.runtime.startPreparation()
        stt.onFinal = { [weak self] id, text in
            guard let self, self.gate.accepts(id) else { return }
            guard let satisfied = self.silenceSatisfiedAt,
                  ProcessInfo.processInfo.systemUptime >= satisfied else {
                self.cancelTurn()
                self.block("Listening timing could not be verified. Please try again.", issue: .speech)
                return
            }
            self.submit(text, id: id)
        }
        stt.onError = { [weak self] id, message in
            guard let self, self.gate.accepts(id) else { return }
            self.cancelTurn(); self.block(message, issue: .speech)
        }
        stt.onRecording = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.timing("capture_started")
            do { try self.runtime.startVoice(id) }
            catch {
                self.logFailure(error, stage: .voice)
                self.cancelTurn(); self.block(error.localizedDescription, issue: .voice); return
            }
            self.timing("warmup_started")
            self.warmup.start(turn: id) { [weak self] in
                guard let self, self.gate.accepts(id) else { throw CancellationError() }
                _ = try await self.engine.verifyConnection()
                guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                self.timing("warmup_ready")
            }
        }
        tts.onError = { [weak self] id, message in
            guard let self, self.gate.accepts(id) else { return }
            if self.currentTurnIsTyped { self.continueTypedWithoutVoice(id: id); return }
            let diagnostic = PipelineDiagnostic(stage: .voice, outcome: .failed, reason: .voiceFailed)
            Self.runtimeLog.error("\(diagnostic.logLine, privacy: .public)")
            self.textHistory.recordAssistant(turn: id, text: self.answer, event: .failed(.voice))
            self.cancelTurn(); self.block(message, issue: .voice)
        }
        tts.onStarted = { [weak self] id in
            guard let self, self.gate.accepts(id), !self.voiceDeliveryFailed, !self.firstAudio else { return }
            self.firstAudio = true; self.timing("playback_started")
            self.textHistory.recordAssistant(turn: id, text: self.answer, event: .playbackStarted)
            // Player scheduling is not an acoustic measurement. Keep these metrics labelled.
            let now = ProcessInfo.processInfo.systemUptime
            if let ended = self.speechEndedAt, let satisfied = self.silenceSatisfiedAt {
                let total = Int((now - ended) * 1000), processing = Int((now - satisfied) * 1000)
                Self.timingLog.notice("DOT_TIMING speech_end_to_playback_scheduled=\(total)ms post_silence_to_playback_scheduled=\(processing)ms")
            }
        }
        tts.onFinalPlayback = { [weak self] id in
            guard let self else { return }
            if id == self.activeSpeechUpdateID {
                self.taskProgress.finishSpeech(id: id)
                self.activeSpeechUpdateID = nil
                self.phase = .idle
                return
            }
            guard self.gate.accepts(id), !self.voiceDeliveryFailed else { return }
            self.timing("final_playback_complete")
            self.textHistory.recordAssistant(turn: id, event: .playbackCompleted)
            self.followup.playbackFinished(turn: id)
            self.finishProactiveTurn(id: id)
        }
        tts.onDrained = { [weak self] id in
            guard let self else { return }
            if id == self.activeSpeechUpdateID {
                self.phase = .idle
                return
            }
            guard self.gate.accepts(id), !self.voiceDeliveryFailed else { return }
            self.phase = self.generating ? .thinking : .idle
            if !self.generating { self.followup.playbackFinished(turn: id) }
        }
        proactive.onOpportunity = { [weak self] in self?.suggest($0) }
        proactive.onCancel = { [weak self] opportunity in
            guard let self, self.proactiveTurn?.opportunity == opportunity else { return }
            if self.runtime.ttsSpeaking() || self.phase == .speaking || self.generating {
                return
            }
            self.cancelTurn()
        }
        proactive.onContextChange = { [weak self] change in
            guard let self, change.applicationIdentifier != Bundle.main.bundleIdentifier else { return }
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier {
                InPlaceAppTyping.noteExternalApplication(pid: front.processIdentifier, name: front.localizedName)
            }
            self.proactiveContextChange = change
            self.proactiveContextChangedAfterUser = true
            self.updateProactiveContext()
        }
    }

    func startProactivity() {
        proactive.start()
        updateProactiveContext()
        IdleSelfReflectionEngine.shared.recordUserActivity()
        ensureSelfReflectionTicker()
    }
    func stopProactivity() {
        proactive.stop()
        selfReflectionTicker?.cancel()
        selfReflectionTicker = nil
    }
    private func ensureSelfReflectionTicker() {
        guard selfReflectionTicker == nil else { return }
        selfReflectionTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, !Task.isCancelled, !self.shuttingDown else { break }
                let now = ProcessInfo.processInfo.systemUptime
                if self.visible, !self.proactive.paused, self.phase == .idle,
                   !self.generating, !self.runtime.ttsSpeaking(),
                   self.proactive.activeOpportunity == nil, self.proactiveTurn == nil {
                    if !self.proactiveEvidence.isRecent(now: now) || !self.proactiveContextChangedAfterUser {
                        self.proactiveEvidence.recordUser(turn: UUID(), now: now)
                        self.proactiveContextChangedAfterUser = true
                    }
                    self.updateProactiveContext()
                }
                guard self.visible, !self.proactive.paused, self.phase == .idle,
                      !self.generating, !self.runtime.ttsSpeaking(),
                      !MeetingFocusAwareness.isMeetingActive(),
                      IdleSelfReflectionEngine.shared.shouldTriggerReflection() else {
                    continue
                }
                let report = IdleSelfReflectionEngine.shared.performReflectionAndWriteToAntigravity()
                DiagnosticChatLogger.record(role: "dot (10m-self-reflection)", text: report)
                self.speakDirect("I reviewed my recent conversations after 10 minutes of inactivity and wrote an improvement suggestion for myself into Antigravity.")
            }
            self?.selfReflectionTicker = nil
        }
    }
    /// Native control-down must not swap Stop for Talk before mouse-up dispatches
    /// the button action. Revoke future invitations, but let that action own any
    /// active-turn cancellation. This flag intentionally does not publish UI state.
    func setControlInteraction(_ active: Bool) {
        controlInteraction = active
        if active { followup.cancel() }
        updateProactiveContext()
    }
    /// Call from native menu/pointer/readiness maintenance. The engine's own
    /// background turn is not mistaken for foreground work and cancelled by itself.
    func updateProactiveContext(externalInteractionBusy: Bool? = nil) {
        if let externalInteractionBusy { self.externalInteractionBusy = externalInteractionBusy }
        let now = ProcessInfo.processInfo.systemUptime
        let userBusy = proactiveTurn == nil && (phase.isActive || runtime.recording() || runtime.transcribing() || followupPending)
        let context = ProactiveContext(
            ready: !shuttingDown && runtime.isReady() && issue == nil
                && (!screenEnabled || runtime.screenAuthorized()) && proactiveEvidence.isRecent(now: now),
            visible: visible, foregroundBusy: userBusy,
            interactionBusy: interactionPaused || historyPresented || self.externalInteractionBusy
                || (controlInteraction && proactiveTurn == nil),
            engineBusy: generating || work != nil || runtime.ttsSpeaking() || followupPending || controlInteraction)
        proactive.updateContext(context)
        if proactiveContextChange == nil {
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                proactiveContextChange = .init(reason: .foregroundApplicationChanged, applicationIdentifier: frontApp.bundleIdentifier)
                proactiveContextChangedAfterUser = true
            } else {
                proactiveContextChange = .init(reason: .relevantContextChanged, applicationIdentifier: "macos.workspace")
                proactiveContextChangedAfterUser = true
            }
        }
        if context.permitsBackgroundWork, !context.engineBusy, proactive.activeOpportunity == nil, proactiveTurn == nil,
           proactiveContextChangedAfterUser,
           let change = proactiveContextChange,
           let key = proactiveEvidence.key(change: change, now: now, ownIdentifier: Bundle.main.bundleIdentifier) {
            if proactive.offerContext(key: key, reason: change.reason) {
                proactiveContextChangedAfterUser = false
            }
        }
    }

    /// The renderer moves inside its already allocated edge padding; this never
    /// changes the panel origin or bypasses safe roaming. Return value sets only
    /// the native animation tick rate while a visible offset is moving.
    @discardableResult
    func updateIdleMotion(now: Double, externallyPaused: Bool, pointerNearby: Bool, reduceMotion: Bool, moved: Bool) -> Bool {
        if moved { idleMotion.noteMovement(at: now) }
        let context = IdleMotionContext(visible: visible, idle: phase == .idle && !followupPending,
            paused: externallyPaused || proactive.paused || historyPresented,
            pinned: pinned, dragging: interactionPaused, pointerNearby: pointerNearby || hovered,
            reduceMotion: reduceMotion, motionScale: skinPreferences.motionDetail.movementScale,
            availablePadding: max(0, Double(PetLayout.edgePadding) - 2))
        let offset = idleMotion.sample(now: now, context: context)
        if idleMotionOffset != offset { idleMotionOffset = offset }
        return offset != .zero
    }

    private func suggest(_ opportunity: ProactiveOpportunity) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !shuttingDown, visible, phase == .idle, !followupPending,
              !interactionPaused, !historyPresented, !externalInteractionBusy, !controlInteraction,
              runtime.isReady(),
              !MeetingFocusAwareness.isMeetingActive(),
              proactiveEvidence.isRecent(now: now), proactive.activeOpportunity?.id == opportunity.id else {
            proactive.complete(id: opportunity.id)
            proactiveEvidence.recordUser(turn: UUID(), now: now)
            proactiveContextChangedAfterUser = true
            updateProactiveContext()
            return
        }
        // Advance only the single existing conversation owner. No second engine,
        // random microphone opening, or background permission request is created.
        let id = gate.advance()
        work?.cancel(); warmup.cancel(); runtime.stopCapture(); runtime.stopVoice(); screen.cancel()
        proactiveTurn = (opportunity.id, id)
        voiceRoute = runtime.currentRoute()
        followup.begin(turn: id)
        clickedAt = now; firstReasoning = false; firstAnswer = false; firstAudio = false
        speechEndedAt = nil; silenceSatisfiedAt = nil; answer = ""; displayedAnswerTurn = nil; automaticReply = false
        currentTurnIsTyped = false; voiceDeliveryFailed = false; voiceDeliveryNotice = nil
        screenContextUsed = false; generating = true; phase = .thinking
        var promptText = ProactiveReplyBuffer.prompt
        let workspaceSnapshot = AutonomousMacAgent.shared.observeAndMaintainWorkspace()
        promptText += "\n[Live Autonomous Workspace Observation:\n\(workspaceSnapshot.promptSummary)]"
        let snapshot = Array(history.suffix(10)) + [ChatMessage(role: "user", content: promptText)]
        work = Task(priority: .utility) { [weak self] in
            guard let self, self.gate.accepts(id), !Task.isCancelled else { return }
            var buffer = ProactiveReplyBuffer()
            var failureStage = ConversationHistoryFailureStage.generation
            do {
                if self.screenEnabled && self.runtime.screenAuthorized() {
                    try? self.screen.prepare(turn: id, requestPermission: false)
                }
                let question = try await self.engine.chat(history: snapshot, purpose: .background, onDelta: { [weak self] delta in
                    guard let self, self.gate.accepts(id), self.proactiveTurn?.turn == id else { return }
                    buffer.append(delta)
                }, screenImage: { [weak self] hasVision in
                    guard let self, self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    guard self.screenEnabled && self.runtime.screenAuthorized() else { return nil }
                    self.capturingScreen = true
                    defer { if self.gate.accepts(id) { self.capturingScreen = false } }
                    let image = try? await self.screen.capture(turn: id, modelHasVision: hasVision)
                    guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    self.screenContextUsed = image != nil
                    return image
                })
                guard self.gate.accepts(id), self.proactiveTurn?.turn == id, !Task.isCancelled else { return }
                let result = try buffer.completed(question: question?.text)
                guard case .speak(let content, let question) = result else {
                    self.finishProactiveTurn(id: id)
                    self.cancelTurn()
                    return
                }
                let fingerprint = result.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !self.recentProactiveReplies.contains(fingerprint) else {
                    self.finishProactiveTurn(id: id)
                    self.cancelTurn()
                    return
                }
                self.textHistory.beginAssistant(turn: id)
                self.displayedAnswerTurn = id
                self.answer = result.text
                self.textHistory.recordAssistant(turn: id, text: result.text, event: .generated)
                DiagnosticChatLogger.record(role: "dot (proactive)", text: result.text)
                failureStage = .voice
                try self.runtime.startVoice(id)
                let effectiveQuestion = question ?? (result.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ? "" : nil)
                do {
                    let question = effectiveQuestion
                    self.followup.generationFinished(turn: id, hasQuestion: question != nil)
                }
                var sentences = SentenceBuffer()
                for sentence in sentences.feed(content) { self.runtime.enqueueVoice(sentence, id) }
                if let tail = sentences.flush() { self.runtime.enqueueVoice(tail, id) }
                if let question, !question.isEmpty, !content.contains(question) { self.runtime.enqueueVoice(question, id) }
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.answer = result.text
                self.history.append(ChatMessage(role: "assistant", content: result.text))
                if self.history.count > 12 { self.history.removeFirst(self.history.count - 12) }
                self.recentProactiveReplies.append(fingerprint)
                if self.recentProactiveReplies.count > 16 { self.recentProactiveReplies.removeFirst() }
                self.generating = false
                self.runtime.completeVoice(id)
                self.phase = self.runtime.ttsSpeaking() ? .speaking : .idle
            } catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.logFailure(error, stage: failureStage == .voice ? .voice : .response)
                self.textHistory.recordAssistant(turn: id, text: self.answer, event: .failed(failureStage))
                // An optional suggestion failure stays silent and cannot open a mic.
                self.finishProactiveTurn(id: id)
                self.cancelTurn()
            }
            if self.gate.accepts(id) { self.work = nil; self.updateProactiveContext() }
        }
    }

    private func finishProactiveTurn(id: UUID) {
        guard let active = proactiveTurn, active.turn == id else { return }
        proactiveTurn = nil
        proactive.complete(id: active.opportunity)
        let now = ProcessInfo.processInfo.systemUptime
        proactiveEvidence.recordUser(turn: UUID(), now: now)
        proactiveContextChangedAfterUser = true
        updateProactiveContext()
    }

    /// Manual clicks interrupt; automatic capture requires the same-turn final-question gate.
    func clicked() {
        if !OfflinePreparation.shared.ready {
            if OfflinePreparation.shared.state == .paused {
                OfflinePreparation.shared.retry()
            }
            expressionRevision &+= 1
            return
        }
        guard !shuttingDown, runtime.isReady() else { return }
        dismissFirstUseHint()
        if phase == .speaking || runtime.ttsSpeaking() || generating {
            stopCurrentTurn()
            return
        }
        beginListening(continuation: nil)
    }

    private var pushToTalkActive = false
    private var pushToTalkStart: Double = 0

    func beginPushToTalk() {
        guard !shuttingDown, runtime.isReady() else { return }
        pushToTalkActive = true
        pushToTalkStart = ProcessInfo.processInfo.systemUptime
        dismissFirstUseHint()
        if phase == .speaking || runtime.ttsSpeaking() || generating {
            stopCurrentTurn()
        }
        beginListening(continuation: nil)
    }

    func finishPushToTalk() {
        guard pushToTalkActive else { return }
        pushToTalkActive = false
        let elapsed = ProcessInfo.processInfo.systemUptime - pushToTalkStart
        if elapsed < 0.25 {
            stopCurrentTurn()
            return
        }
        runtime.forceFinishCapture()
    }

    func handleTimerFired(_ timer: ScheduledTimer) {
        #if canImport(AppKit)
        NSSound(named: "Glass")?.play()
        #endif
        DiagnosticChatLogger.record(role: "system", text: "Timer fired: \(timer.label)")
        let alertText = "Timer is up for: \(timer.label)!"
        let id = cancelTurn()
        respondDirectly(alertText, id: id)
    }

    func dismissFirstUseHint() {
        guard firstUseHint else { return }
        firstUseHint = false; defaults.set(true, forKey: "dot.interactionHintDismissed.v1")
    }
    /// Explicit typed submission is already a finished utterance. It neither
    /// requests microphone access nor waits for a speech-silence deadline.
    @discardableResult
    func submitTyped(_ text: String) -> Bool {
        let value = TypedMessageValidation.cleaned(text)
        guard canSubmitTyped, TypedMessageValidation.problem(value) == nil else { return false }
        onForegroundInteraction?()
        dismissFirstUseHint()
        let id = cancelTurn()
        currentTurnIsTyped = true; voiceDeliveryFailed = false; voiceDeliveryNotice = nil
        voiceRoute = runtime.currentRoute(); followup.begin(turn: id)
        clickedAt = ProcessInfo.processInfo.systemUptime
        firstReasoning = false; firstAnswer = false; firstAudio = false
        speechEndedAt = nil; silenceSatisfiedAt = nil; answer = ""; displayedAnswerTurn = nil; lastAttemptedText = value
        do {
            try screen.prepare(turn: id, requestPermission: false)
        } catch {
            Self.runtimeLog.notice("Screen preparation skipped for typed turn: \(error.localizedDescription, privacy: .public)")
        }
        do { try runtime.startVoice(id) }
        catch { logFailure(error, stage: .voice); continueTypedWithoutVoice(id: id) }
        warmup.start(turn: id) { [weak self] in
            guard let self, self.gate.accepts(id) else { throw CancellationError() }
            _ = try await self.engine.verifyConnection()
            guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
        }
        submit(value, id: id, typed: true)
        return true
    }
    func retryLastTurn() {
        if let lastAttemptedText { _ = submitTyped(lastAttemptedText) }
        else { clicked() }
    }
    func continueWithoutScreen() {
        let text = lastAttemptedText
        screenEnabled = false
        if let text { _ = submitTyped(text) } else { clicked() }
    }
    private func beginListening(continuation: UUID?) {
        onForegroundInteraction?()
        let invitation = continuation != nil
        let id = cancelTurn(preserveFollowup: invitation)
        voiceDeliveryNotice = nil
        voiceRoute = runtime.currentRoute()
        followup.begin(turn: id, continuation: continuation)
        automaticReply = invitation
        clickedAt = ProcessInfo.processInfo.systemUptime
        firstReasoning = false; firstAnswer = false; firstAudio = false
        speechEndedAt = nil; silenceSatisfiedAt = nil; answer = ""; displayedAnswerTurn = nil
        lastAttemptedText = nil
        phase = .listening
        work = Task { [weak self] in
            guard let self, !Task.isCancelled, self.gate.accepts(id) else { return }
            do { try self.screen.prepare(turn: id, requestPermission: !invitation) }
            catch {
                Self.runtimeLog.notice("Screen preparation skipped: \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled, self.gate.accepts(id) else { return }
            await self.runtime.startCapture(id, self.voiceTiming, invitation)
        }
    }

    private func submit(_ text: String, id: UUID, typed: Bool = false) {
        guard gate.accepts(id) else { return }
        DiagnosticChatLogger.record(role: "user", text: text)
        timing(typed ? "text_submitted" : "final_transcript")
        lastAttemptedText = text
        let nowUptime = ProcessInfo.processInfo.systemUptime
        proactiveEvidence.recordUser(turn: id, now: nowUptime)
        IdleSelfReflectionEngine.shared.recordUserActivity(now: nowUptime)
        proactiveContextChangedAfterUser = false
        phase = .thinking; generating = true
        answer = ""; displayedAnswerTurn = id; chunker = SentenceBuffer()
        history.append(ChatMessage(role: "user", content: text))
        textHistory.append(role: .user, text: text, turn: id)
        textHistory.beginAssistant(turn: id)
        if voiceDeliveryFailed { textHistory.recordAssistant(turn: id, event: .voiceFailedContinuing) }
        if DotSoulManager.shared.cleanContextIfMemoryPressure() || history.count > ExpandedContextWindow.maxHistoryMessages {
            DotSoulManager.shared.archiveCurrentState(reason: "history_compaction")
            if history.count > ExpandedContextWindow.maxHistoryMessages {
                history.removeFirst(history.count - ExpandedContextWindow.maxHistoryMessages)
            }
        }

        // Check In-Place App Typing & Key-Press first so "press right arrow" or "type 'hello' in that input" isn't mistaken for pet movement
        let typingCmd = InPlaceAppTyping.parseCommand(text)
        switch typingCmd {
        case .type(let content):
            let outcome = InPlaceAppTyping.performTypeText(content, checkPermission: true)
            respondDirectly(outcome.confirmation, id: id)
            return
        case .pressKey(let keyName):
            let outcome = InPlaceAppTyping.performPressKey(keyName, checkPermission: true)
            respondDirectly(outcome.confirmation, id: id)
            return
        case .typeAndSubmit(let content):
            let outcome = InPlaceAppTyping.performTypeText(content, checkPermission: true)
            if outcome.succeeded {
                usleep(40_000)
                _ = InPlaceAppTyping.sendKey("Enter")
                respondDirectly(outcome.confirmation.replacingOccurrences(of: "Typed '\(content)'", with: "Typed '\(content)' and pressed Enter"), id: id)
            } else {
                respondDirectly(outcome.confirmation, id: id)
            }
            return
        case .clickElement(let description):
            Task { @MainActor [weak self] in
                guard let self, self.gate.accepts(id) else { return }
                let outcome = await MouseControlEngine.clickElement(description: description)
                self.respondDirectly(outcome.confirmation, id: id)
            }
            return
        case .clickPoint(let x, let y, let button, let clicks):
            let point = CGPoint(x: x, y: y)
            let ok = MouseControlEngine.click(at: point, button: button, clicks: clicks)
            let reply = ok ? "Clicked \(button.rawValue) button at (\(Int(x)), \(Int(y)))." : "Could not click at that point. Check Accessibility permissions."
            respondDirectly(reply, id: id)
            return
        case .moveMouse(let description):
            let outcome = MouseControlEngine.moveMouseRelative(description: description)
            respondDirectly(outcome.confirmation, id: id)
            return
        case .none:
            break
        }

        let scrollCmd = ScrollControlEngine.parseCommand(text)
        if case .scroll(let direction, let amount) = scrollCmd {
            let ok = ScrollControlEngine.scroll(direction: direction, amount: amount)
            let reply = ok ? "Scrolled \(direction.rawValue)." : "Could not scroll \(direction.rawValue). Check Accessibility permissions."
            respondDirectly(reply, id: id)
            return
        }

        if let moveCmd = self.detectMovementCommand(text), let replyText = self.onMove?(moveCmd) {
            respondDirectly(replyText, id: id)
            return
        }

        if let windowLayout = WindowLayoutManager.parseCommand(text) {
            let reply = WindowLayoutManager.applyLayout(windowLayout)
            respondDirectly(reply, id: id)
            return
        }

        let simCmd = SimulatorControlSuite.parseCommand(text)
        if simCmd != .none, let simReply = SimulatorControlSuite.execute(simCmd) {
            respondDirectly(simReply, id: id)
            return
        }

        if NeuralMetricsInspector.isMetricsQuery(text) {
            let report = NeuralMetricsInspector.currentReport(
                engineReady: runtime.isReady(),
                activeTimersCount: SmartTimerScheduler.shared.activeTimers().count
            )
            respondDirectly(report, id: id)
            return
        }

        let lowerClean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowerClean == "export soul" || lowerClean == "export my soul" || lowerClean == "export soul memory" || lowerClean == "backup memory" {
            let (_, msg) = DotSoulManager.shared.exportSoul()
            respondDirectly(msg, id: id)
            return
        }
        if lowerClean == "check ram" || lowerClean == "ram status" || lowerClean == "how much ram" || lowerClean == "memory status" || lowerClean == "check memory" {
            let report = SystemRAMInspector.formattedReport()
            respondDirectly(report, id: id)
            return
        }
        if lowerClean == "parallel agents" || lowerClean == "active agents" || lowerClean == "agent status" {
            let summary = ParallelAgentCoordinator.shared.activeAgentsSummary()
            respondDirectly(summary, id: id)
            return
        }
        if lowerClean == "self reflect" || lowerClean == "reflect on your logs" || lowerClean == "analyze your logs" || lowerClean == "suggest improvements to antigravity" {
            let report = IdleSelfReflectionEngine.shared.performReflectionAndWriteToAntigravity()
            respondDirectly(report, id: id)
            return
        }
        if lowerClean.hasPrefix("search code ") || lowerClean.hasPrefix("search your code for ") {
            let prefix = lowerClean.hasPrefix("search your code for ") ? "search your code for " : "search code "
            let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(prefix.count))
            let matches = SelfCodebaseReader.searchCodebase(query: query)
            if matches.isEmpty {
                respondDirectly("No matches found in my codebase for \"\(query)\".", id: id)
            } else {
                respondDirectly("Found \(matches.count) match\(matches.count == 1 ? "" : "es") in my codebase:\n" + matches.joined(separator: "\n"), id: id)
            }
            return
        }

        let timerCmd = SmartTimerParser.parse(text)
        switch timerCmd {
        case .create(let seconds, let label):
            _ = SmartTimerScheduler.shared.schedule(seconds: seconds, label: label) { [weak self] firedTimer in
                Task { @MainActor in
                    self?.handleTimerFired(firedTimer)
                }
            }
            let durationText = SmartTimerScheduler.formatDuration(seconds)
            let reply = "Timer set for \(durationText)\(label != "Timer" ? " (\(label))" : "")."
            respondDirectly(reply, id: id)
            return
        case .cancel:
            let count = SmartTimerScheduler.shared.cancelAll()
            let reply = count > 0 ? "Cancelled \(count) active timer\(count > 1 ? "s" : "")." : "No active timers to cancel."
            respondDirectly(reply, id: id)
            return
        case .list:
            let active = SmartTimerScheduler.shared.activeTimers()
            let reply: String
            if active.isEmpty {
                reply = "No active timers."
            } else {
                let desc = active.map { "\($0.label): \(SmartTimerScheduler.formatDuration($0.remainingSeconds)) remaining" }.joined(separator: ", ")
                reply = "Active timers: \(desc)."
            }
            respondDirectly(reply, id: id)
            return
        case .none:
            break
        }

        if let action = self.detectNativeAction(text) {
            work = Task { [weak self] in
                guard let self, self.gate.accepts(id) else { return }
                let result = await self.onExecuteAction?(action)
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                let replyText: String
                switch action {
                case .launchApplication:
                    replyText = result?.receipt.status == .succeeded ? "Opening application." : "Could not open that application."
                case .openWebURL(let url):
                    replyText = result?.receipt.status == .succeeded || result?.receipt.status == .handedOff ? "Opening \(url)." : "Could not open URL."
                case .createFolder(let path):
                    replyText = result?.receipt.status == .succeeded ? "Created folder \(path)." : "Could not create folder \(path)."
                case .createText(let path, _):
                    replyText = result?.receipt.status == .succeeded ? "Created file \(path)." : "Could not create file \(path)."
                case .readText(let path):
                    if let content = result?.text {
                        replyText = "File \(path): \(content)"
                    } else {
                        replyText = "Could not read file \(path)."
                    }
                case .sendShortcut(let mods, let keys):
                    let combo = (mods + [keys]).joined(separator: "+")
                    replyText = result?.receipt.status == .succeeded ? "Pressed \(combo) in the focused app." : (result?.receipt.detail ?? "Could not send shortcut.")
                case .moveMouse(let pt):
                    replyText = result?.receipt.status == .succeeded ? "Moved mouse to (\(Int(pt.x)), \(Int(pt.y)))." : (result?.receipt.detail ?? "Could not move mouse.")
                case .click, .clickElement:
                    replyText = result?.receipt.status == .succeeded ? (result?.receipt.detail ?? "Clicked.") : (result?.receipt.detail ?? "Could not click element.")
                default:
                    replyText = "Action completed."
                }
                DiagnosticChatLogger.record(role: "dot", text: replyText)
                if result?.receipt.status != .succeeded && result?.receipt.status != .handedOff {
                    DiagnosticChatLogger.recordFailure(
                        task: text,
                        reason: replyText,
                        missingCapability: "Action failed or unconfirmed (\(result?.receipt.detail ?? "unknown"))",
                        proposedFix: "Verify bundle identifier or target path"
                    )
                }
                self.answer = replyText
                self.history.append(ChatMessage(role: "assistant", content: replyText))
                self.textHistory.recordAssistant(turn: id, text: replyText, event: .generated)
                if !self.voiceDeliveryFailed {
                    self.enqueueVoice(replyText, id: id)
                    self.runtime.completeVoice(id)
                }
                self.generating = false
                self.phase = !self.voiceDeliveryFailed && self.runtime.ttsSpeaking() ? .speaking : .idle
            }
            return
        }

        if let systemReply = self.detectSystemControlCommand(text) {
            respondDirectly(systemReply, id: id)
            return
        }

        // On-Screen Laser Pointer & Guidance
        let laserCmd = LaserPointerParser.parse(text)
        switch laserCmd {
        case .pointToCenter:
            let center = NSScreen.main.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? CGPoint(x: 500, y: 500)
            ScreenGuideLaserOverlay.shared.showPointer(at: center)
            respondDirectly("Showing laser pointer guide.", id: id)
            return
        case .highlightActiveWindow:
            if let screen = NSScreen.main {
                let centerBox = CGRect(x: screen.frame.midX - 300, y: screen.frame.midY - 200, width: 600, height: 400)
                ScreenGuideLaserOverlay.shared.highlightRect(centerBox)
                let desktop = ActiveDesktopContext.current()
                let name = desktop.appName ?? "active window"
                respondDirectly("Highlighting \(name).", id: id)
                return
            }
        case .pointAt(let x, let y):
            ScreenGuideLaserOverlay.shared.showPointer(at: CGPoint(x: x, y: y))
            respondDirectly("Pointing to coordinates (\(Int(x)), \(Int(y))).", id: id)
            return
        case .none:
            break
        }

        // Native Screen OCR
        let lowerScreen = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowerScreen == "copy screen text" || lowerScreen == "copy text from screen" || lowerScreen == "ocr screen" || lowerScreen == "extract screen text" || lowerScreen == "extract text from screen" {
            work = Task { [weak self] in
                guard let self, self.gate.accepts(id) else { return }
                do {
                    let lines = try await self.screen.extractVisibleScreenText()
                    guard self.gate.accepts(id), !Task.isCancelled else { return }
                    if lines.isEmpty {
                        self.respondDirectly("No text detected on screen.", id: id)
                    } else {
                        let joined = lines.map(\.text).joined(separator: "\n")
                        ClipboardIntelligence.write(joined)
                        self.respondDirectly("Extracted \(lines.count) lines of text from your screen and copied to clipboard.", id: id)
                    }
                } catch {
                    self.respondDirectly("Could not extract screen text: \(error.localizedDescription)", id: id)
                }
            }
            return
        }
        if lowerScreen == "read screen text" || lowerScreen == "read text on screen" || lowerScreen == "what text is on my screen" || lowerScreen == "what's the text on my screen" {
            work = Task { [weak self] in
                guard let self, self.gate.accepts(id) else { return }
                do {
                    let lines = try await self.screen.extractVisibleScreenText()
                    guard self.gate.accepts(id), !Task.isCancelled else { return }
                    if lines.isEmpty {
                        self.respondDirectly("No text detected on screen.", id: id)
                    } else {
                        let textSample = lines.prefix(10).map(\.text).joined(separator: "\n")
                        self.respondDirectly("I found \(lines.count) lines of text on screen:\n\n\(textSample)", id: id)
                    }
                } catch {
                    self.respondDirectly("Could not read screen text: \(error.localizedDescription)", id: id)
                }
            }
            return
        }

        // Advanced Clipboard Intelligence
        var effectivePromptOverride: String? = nil
        let clipboardCmd = ClipboardIntelligence.parseCommand(text)
        switch clipboardCmd {
        case .read:
            if let content = ClipboardIntelligence.read(), !content.isEmpty {
                let preview = content.count > 300 ? String(content.prefix(300)) + "…" : content
                respondDirectly("Clipboard content: \(preview)", id: id)
            } else {
                respondDirectly("Clipboard is empty.", id: id)
            }
            return
        case .clear:
            ClipboardIntelligence.clear()
            respondDirectly("Clipboard cleared.", id: id)
            return
        case .copy(let textToCopy):
            ClipboardIntelligence.write(textToCopy)
            respondDirectly("Copied to clipboard.", id: id)
            return
        case .summarize:
            if let content = ClipboardIntelligence.read(), !content.isEmpty {
                effectivePromptOverride = "Please summarize the following clipboard text concisely:\n\n\(content)"
            } else {
                respondDirectly("Clipboard is empty, nothing to summarize.", id: id)
                return
            }
        case .explain:
            if let content = ClipboardIntelligence.read(), !content.isEmpty {
                effectivePromptOverride = "Please explain the following clipboard content concisely:\n\n\(content)"
            } else {
                respondDirectly("Clipboard is empty, nothing to explain.", id: id)
                return
            }
        case .translate(let language):
            if let content = ClipboardIntelligence.read(), !content.isEmpty {
                effectivePromptOverride = "Please translate the following clipboard text into \(language):\n\n\(content)"
            } else {
                respondDirectly("Clipboard is empty, nothing to translate.", id: id)
                return
            }
        case .none:
            break
        }

        let cleanLower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
        if cleanLower == "what time is it" || cleanLower == "what is the time" || cleanLower == "what's the time" || cleanLower == "current time" || cleanLower == "time" {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let replyText = "It is \(formatter.string(from: Date()))."
            respondDirectly(replyText, id: id)
            return
        }
        if cleanLower == "what day is it" || cleanLower == "what's today" || cleanLower == "what is today" || cleanLower == "what's the date" || cleanLower == "what is the date" || cleanLower == "what is the date today" || cleanLower == "today's date" {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            let replyText = "Today is \(formatter.string(from: Date()))."
            respondDirectly(replyText, id: id)
            return
        }

        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("remember that ") || lower.hasPrefix("remember ") || lower.hasPrefix("my name is ") || lower.hasPrefix("i prefer ") || lower.hasPrefix("i like ") {
            var fact = text
            if let range = fact.range(of: "(?i)^remember that\\s+", options: .regularExpression) {
                fact.removeSubrange(range)
            } else if let range = fact.range(of: "(?i)^remember:?\\s+", options: .regularExpression) {
                fact.removeSubrange(range)
            }
            let factToSave = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            if !factToSave.isEmpty {
                Task { [weak self] in
                    _ = try? await self?.ftsStore.saveMemory(category: .userPreference, fact: factToSave, isCorrection: false)
                }
            }
        }

        if let query = self.detectWebSearchQuery(text) {
            self.onRequestResearch?(query)
        }

        let snapshot = history
        work = Task { [weak self] in
            guard let self else { return }
            var stage = PipelineDiagnostic.Stage.readiness
            do {
                try await self.warmup.wait(turn: id)
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                var chatInput = snapshot
                if let effectivePromptOverride, let lastIdx = chatInput.indices.last {
                    chatInput[lastIdx] = ChatMessage(role: chatInput[lastIdx].role, content: effectivePromptOverride)
                }
                let desktop = await MainActor.run { ActiveDesktopContext.current() }
                if let assembledCtx = await PersistentMemoryBrain.shared.assembleTurnContext(
                    query: text,
                    ftsStore: self.ftsStore,
                    activeDesktop: desktop
                ) {
                    if let lastIdx = chatInput.indices.last {
                        chatInput[lastIdx] = ChatMessage(role: chatInput[lastIdx].role, content: chatInput[lastIdx].content + assembledCtx)
                    }
                }
                Task { [weak self] in
                    guard let self else { return }
                    let facts = PersistentMemoryBrain.extractImportantFacts(from: text)
                    if !facts.isEmpty {
                        PersistentMemoryBrain.shared.persistFacts(facts)
                        for f in facts {
                            _ = try? await self.ftsStore.saveMemory(
                                category: f.isCorrection ? .userCorrection : (f.isVolatile ? .projectContext : .userPreference),
                                fact: f.fact,
                                isCorrection: f.isCorrection
                            )
                        }
                    }
                }
                let snapshot = chatInput
                var executedToolConfirmation: String?
                let question = try await self.engine.chat(history: snapshot, onDelta: { [weak self] content in
                    guard let self, self.gate.accepts(id) else { return }
                    if !self.firstAnswer { self.firstAnswer = true; self.timing("first_answer") }
                    self.answer += content
                    if !self.voiceDeliveryFailed {
                        for sentence in self.chunker.feed(content) { self.enqueueVoice(sentence, id: id) }
                        if !self.voiceDeliveryFailed && self.runtime.ttsSpeaking() { self.phase = .speaking }
                    }
                }, onReasoning: { [weak self] in
                    guard let self, self.gate.accepts(id), !self.firstReasoning else { return }
                    self.firstReasoning = true; self.timing("first_reasoning")
                }, onToolAction: { [weak self] toolAction in
                    guard let self, self.gate.accepts(id) else { return }
                    switch toolAction {
                    case .typeText(let textToType):
                        executedToolConfirmation = InPlaceAppTyping.performTypeText(textToType, checkPermission: true).confirmation
                    case .pressKey(let keyToPress):
                        executedToolConfirmation = InPlaceAppTyping.performPressKey(keyToPress, checkPermission: true).confirmation
                    case .sendShortcut(let modifiers, let key):
                        let combo = modifiers.isEmpty ? key : (modifiers + [key]).joined(separator: "+")
                        executedToolConfirmation = InPlaceAppTyping.performPressKey(combo, checkPermission: true).confirmation
                    case .clickElement(let description):
                        let outcome = await MouseControlEngine.clickElement(description: description)
                        executedToolConfirmation = outcome.confirmation
                    case .moveMouse(let x, let y):
                        let ok = MouseControlEngine.moveMouse(to: CGPoint(x: x, y: y))
                        executedToolConfirmation = ok ? "Moved mouse to (\(Int(x)), \(Int(y)))." : "Could not move mouse."
                    case .clickPoint(let x, let y, let btn, let clicks):
                        let button = NativeMouseButton(rawValue: btn) ?? .left
                        let ok = MouseControlEngine.click(at: CGPoint(x: x, y: y), button: button, clicks: clicks)
                        executedToolConfirmation = ok ? "Clicked at (\(Int(x)), \(Int(y)))." : "Could not click."
                    case .pointOnScreen(let x, let y, let label):
                        ScreenGuideLaserOverlay.shared.showPointer(at: CGPoint(x: x, y: y), duration: 2.5)
                        executedToolConfirmation = "Pointing at (\(Int(x)), \(Int(y)))\(label != nil ? " (" + label! + ")" : "")."
                    case .scrollScreen(let direction, let amount):
                        let dir = ScrollDirection(rawValue: direction.lowercased()) ?? .down
                        let ok = ScrollControlEngine.scroll(direction: dir, amount: amount)
                        executedToolConfirmation = ok ? "Scrolled \(direction)." : "Could not scroll \(direction)."
                    }
                }, screenImage: { [weak self] hasVision in
                    guard let self, self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    stage = .capture
                    self.capturingScreen = self.screen.enabled
                    if self.screen.enabled {
                        let diagnostic = PipelineDiagnostic(stage: .capture, outcome: .started)
                        Self.runtimeLog.notice("\(diagnostic.logLine, privacy: .public)")
                    }
                    defer { if self.gate.accepts(id) { self.capturingScreen = false } }
                    let image: CapturedScreenImage?
                    do {
                        image = try await self.screen.capture(turn: id, modelHasVision: hasVision)
                    } catch {
                        Self.runtimeLog.notice("Screen capture unavailable, proceeding without screen image: \(error.localizedDescription, privacy: .public)")
                        image = nil
                    }
                    guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    if image != nil {
                        let diagnostic = PipelineDiagnostic(stage: .capture, outcome: .ready)
                        Self.runtimeLog.notice("\(diagnostic.logLine, privacy: .public)")
                    }
                    stage = .response
                    self.screenContextUsed = image != nil; return image
                })
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                if let tail = self.chunker.flush() { self.enqueueVoice(tail, id: id) }
                if let confirmation = executedToolConfirmation {
                    let prefixSpace = self.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
                    self.answer += prefixSpace + confirmation
                    self.enqueueVoice(confirmation, id: id)
                }
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                let shouldFollowup = !self.voiceDeliveryFailed
                if !self.voiceDeliveryFailed { self.followup.generationFinished(turn: id, hasQuestion: shouldFollowup) }
                if let question {
                    let qTrimmed = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let ansTrimmed = self.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanQ = qTrimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:; "))
                    let cleanAns = ansTrimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:; "))
                    if !cleanAns.hasSuffix(cleanQ) && !cleanAns.contains(cleanQ) {
                        self.answer += (self.answer.isEmpty ? "" : " ") + qTrimmed
                        self.enqueueVoice(qTrimmed, id: id)
                    }
                }
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.history.append(ChatMessage(role: "assistant", content: self.answer))
                self.textHistory.recordAssistant(turn: id, text: self.answer, event: .generated)
                let finalAnswer = self.answer
                DiagnosticChatLogger.record(role: "dot", text: finalAnswer)

                // Auto-copy drafted prompts to clipboard
                let lowerTask = text.lowercased()
                if lowerTask.contains("create prompt") || lowerTask.contains("write prompt") || lowerTask.contains("draft prompt") || lowerTask.contains("copy paste that prompt") || lowerTask.contains("copy prompt") {
                    var promptToCopy = finalAnswer
                    if let start = finalAnswer.range(of: "```"), let end = finalAnswer.range(of: "```", range: start.upperBound..<finalAnswer.endIndex) {
                        promptToCopy = String(finalAnswer[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let start = finalAnswer.range(of: "\""), let end = finalAnswer.range(of: "\"", range: start.upperBound..<finalAnswer.endIndex), start != end {
                        promptToCopy = String(finalAnswer[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if !promptToCopy.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(promptToCopy, forType: .string)
                    }
                }

                let lowerAns = finalAnswer.lowercased()
                if lowerAns.contains("i can't") || lowerAns.contains("i cannot") || lowerAns.contains("i don't have") || lowerAns.contains("unable to") {
                    DiagnosticChatLogger.recordFailure(
                        task: text,
                        reason: finalAnswer,
                        missingCapability: "Model expressed inability to perform task",
                        proposedFix: "Expose direct native implementation or system control"
                    )
                }
                if (lowerAns.contains("center") || lowerAns.contains("middle")) && (lowerAns.contains("moving") || lowerAns.contains("relocating") || lowerAns.contains("centering")) {
                    _ = self.onMove?(.center)
                } else if lowerAns.contains("moving") || lowerAns.contains("relocating") {
                    _ = self.onMove?(.random)
                }
                Task { [weak self] in
                    guard let self else { return }
                    let uRec = ConversationHistoryRecord(id: UUID(), date: Date(), role: .user, text: text, turnID: id, generation: .complete, playback: .notApplicable, generationCompletedAt: nil, playbackStartedAt: nil, playbackCompletedAt: nil, endedAt: nil, failureStage: nil, textTruncated: false)
                    try? await self.ftsStore.indexConversation(record: uRec)
                    let aRec = ConversationHistoryRecord(id: UUID(), date: Date(), role: .assistant, text: finalAnswer, turnID: id, generation: .complete, playback: .completed, generationCompletedAt: nil, playbackStartedAt: nil, playbackCompletedAt: nil, endedAt: nil, failureStage: nil, textTruncated: false)
                    try? await self.ftsStore.indexConversation(record: aRec)
                }
                self.generating = false; self.timing("generation_complete")
                if !self.voiceDeliveryFailed { self.runtime.completeVoice(id) }
                self.phase = !self.voiceDeliveryFailed && self.runtime.ttsSpeaking() ? .speaking : .idle
                if !self.voiceDeliveryFailed && !self.runtime.ttsSpeaking() {
                    self.followup.playbackFinished(turn: id)
                }
            } catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.logFailure(error, stage: stage)
                DiagnosticChatLogger.recordFailure(
                    task: text,
                    reason: "\(error)",
                    missingCapability: "Pipeline stage \(stage) failure",
                    proposedFix: "Examine stage diagnostic and provide direct fallback"
                )
                self.textHistory.recordAssistant(turn: id, text: self.answer, event: .failed(.generation))
                let issue: CompanionIssue
                if let failure = error as? ScreenContext.ScreenFailure {
                    switch failure {
                    case .permission: issue = .screenPermission
                    case .unavailable: issue = .screenCapture
                    case .unsupported: issue = .vision
                    }
                } else { issue = stage == .capture || error is ScreenContextGate.Failure ? .screenCapture : .engine }
                self.cancelTurn()
                self.block(error.localizedDescription, issue: issue)
            }
            if self.gate.accepts(id) { self.work = nil; self.updateProactiveContext() }
        }
    }

    private func respondDirectly(_ replyText: String, id: UUID) {
        DiagnosticChatLogger.record(role: "dot", text: replyText)
        self.answer = replyText
        self.history.append(ChatMessage(role: "assistant", content: replyText))
        self.textHistory.recordAssistant(turn: id, text: replyText, event: .generated)
        if !self.voiceDeliveryFailed {
            self.enqueueVoice(replyText, id: id)
            self.runtime.completeVoice(id)
        }
        self.generating = false
        self.phase = !self.voiceDeliveryFailed && self.runtime.ttsSpeaking() ? .speaking : .idle
    }

    private func block(_ message: String, issue: CompanionIssue) {
        DiagnosticChatLogger.record(role: "dot (error)", text: "\(message) [\(issue)]")
        self.issue = issue; phase = .blocked(message)
    }

    private func enqueueVoice(_ text: String, id: UUID) {
        guard gate.accepts(id), !voiceDeliveryFailed else { return }
        runtime.enqueueVoice(text, id)
    }
    /// Audio failure is terminal for this turn's audio, not for explicitly typed
    /// text. The same engine task may finish; no alternate voice is selected.
    private func continueTypedWithoutVoice(id: UUID) {
        guard gate.accepts(id), currentTurnIsTyped, !voiceDeliveryFailed else { return }
        voiceDeliveryFailed = true
        voiceDeliveryNotice = "Voice unavailable. This reply is text only; automatic reply listening is off."
        issue = .voice
        followup.cancel(); automaticReply = false; voiceRoute = nil
        runtime.stopVoice(); chunker = SentenceBuffer()
        textHistory.recordAssistant(turn: id, text: answer, event: .voiceFailedContinuing)
        phase = generating ? .thinking : .idle
    }

    @discardableResult
    func cancelTurn(preserveFollowup: Bool = false) -> UUID {
        captureOutcomeTask?.cancel(); captureOutcomeTask = nil; captureOutcome = nil
        textHistory.recordAssistant(turn: gate.current, text: answer, event: .interrupted)
        proactiveContextChangedAfterUser = false
        let priorProactive = proactiveTurn; proactiveTurn = nil
        if let priorProactive { proactive.complete(id: priorProactive.opportunity) }
        proactive.clearContext()
        expressionRevision &+= 1
        if !preserveFollowup { followup.cancel() }
        automaticReply = false; voiceRoute = nil
        let id = gate.advance()
        work?.cancel(); work = nil; warmup.cancel()
        runtime.stopCapture(); runtime.stopVoice(); screen.cancel(); screenContextUsed = false; capturingScreen = false; generating = false
        currentTurnIsTyped = false; voiceDeliveryFailed = false
        if let speechID = activeSpeechUpdateID {
            activeSpeechUpdateID = nil
            runtime.stopVoice()
            taskProgress.finishSpeech(id: speechID)
        }
        chunker = SentenceBuffer(); issue = nil; phase = .idle
        return id
    }
    func stopCurrentTurn() { cancelTurn(); showCaptureOutcome("Stopped") }
    private func showCaptureOutcome(_ text: String) {
        captureOutcomeTask?.cancel(); captureOutcome = text
        let turn = gate.current
        captureOutcomeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.gate.accepts(turn) else { return }
            self.captureOutcome = nil; self.captureOutcomeTask = nil
        }
    }
    /// Menus and dragging revoke capture without erasing a diagnostic the user is inspecting.
    func cancelForInteraction() {
        let savedIssue = issue, savedPhase = phase
        cancelTurn()
        if case .blocked = savedPhase { issue = savedIssue; phase = savedPhase }
    }
    func cancelForEnvironment(reason: VoiceCaptureEndReason) {
        if stt.captureState != .idle {
            stt.cancel(reason: reason)
        } else if reason == .permissionLost {
            // A typed answer does not need microphone permission. Revoke only
            // the automatic invitation when no capture was using that grant.
            followup.cancel(); automaticReply = false; updateProactiveContext()
        } else {
            cancelTurn()
            if let message = reason.recoveryMessage { block(message, issue: .voice) }
        }
    }
    func reset() { proactiveEvidence.clear(); proactiveContextChangedAfterUser = false; recentProactiveReplies = []; cancelTurn(); history = []; answer = ""; displayedAnswerTurn = nil; voiceDeliveryNotice = nil; lastAttemptedText = nil }
    func beginShutdown() { shuttingDown = true; stopProactivity(); cancelTurn(); textHistory.closeAdmissions() }
    func shutdown() { stopProactivity(); cancelTurn(); stt.shutdown(); tts.shutdown(); engine.shutdown(); OfflinePreparation.shared.shutdown() }
}

struct PetView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var stt: STTManager
    @ObservedObject var tts: TTSManager
    @ObservedObject var skins: SkinPreferences
    @ObservedObject private var preparation = OfflinePreparation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var emotion: PetEmotion {
        if case .blocked = model.phase { return .puzzled }
        if model.issue != nil || preparation.state.isIssue { return .puzzled }
        if model.taskHalo != .hidden || stt.transcribing || preparation.state == .checking || model.capturingScreen || model.placementCapturing {
            return .working
        }
        switch model.phase {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .blocked: return .puzzled
        }
    }

    var body: some View {
        character
            .onHover { model.hovered = $0 }
            .padding(PetLayout.edgePadding)
            .frame(width: PetLayout.panelSize.width, height: PetLayout.panelSize.height)
            .onExitCommand { stop() }
    }

    private var character: some View {
        Button(action: model.clicked) {
            ZStack {
                taskHaloView
                PetCharacter(
                    emotion: emotion,
                    phase: model.phase,
                    level: stt.level,
                    still: reduceMotion || (model.pinned && !model.phase.isActive),
                    skin: skins.selected,
                    playbackLevel: tts.playbackLevel,
                    motionDetail: skins.motionDetail,
                    expressionRevision: model.expressionRevision
                )
                .frame(width: PetLayout.petSize.width, height: PetLayout.petSize.height)
                .offset(x: model.idleMotionOffset.x, y: model.idleMotionOffset.y)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Ellipse())
        .accessibilityLabel("Dot companion")
        .accessibilityValue(model.taskStatusText ?? emotion.caption)
        .accessibilityHint("Click to talk or interrupt. Drag to move. Right-click for options. Escape stops.")
        .accessibilityAction(named: Text("Options")) { openOptions() }
        .background(accessibilityContractIndicators)
    }

    @ViewBuilder private var accessibilityContractIndicators: some View {
        Group {
            Text(shortStatus)
            if let snapshot = stt.timingSnapshot {
                Text(String(describing: snapshot.phase))
            }
            if isIssue {
                Image(systemName: "exclamationmark.circle.fill")
            }
            if model.capturingScreen || model.placementCapturing {
                Image(systemName: "eye.fill")
            }
            Circle().stroke(Color.accentColor.opacity(0.45))
            Image(systemName: "pause.circle.fill")
            Image(systemName: "hourglass")
        }
        .frame(width: 0, height: 0)
        .hidden()
        .accessibilityValue(CompanionAccessibility.value(status: status, detail: detail, capturingScreen: model.capturingScreen || model.placementCapturing, screenUsed: model.screenContextUsed))
    }

    private var isIssue: Bool { preparation.state.isIssue || { if case .blocked = model.phase { return true }; return false }() }
    private var detail: String? {
        if let issue = preparation.state.detail { return issue }
        if case .blocked(let issue) = model.phase { return issue }
        return model.voiceDeliveryNotice
    }
    private var status: String {
        if preparation.state == .checking { return "Checking bundled files, \(Int(preparation.progress * 100)) percent" }
        if !preparation.ready { return preparation.state.caption }
        if case .blocked = model.phase { return (model.issue?.title ?? CompanionIssue.unknown.title) + " · right-click" }
        if model.phase == .idle, let outcome = model.captureOutcome { return outcome }
        if stt.transcribing { return "Transcribing locally…" }
        if stt.recording, let snapshot = stt.timingSnapshot {
            switch snapshot.phase {
            case .invitation: return "Time to begin speaking: \(CompanionStatusText.seconds(snapshot.remainingSeconds)) seconds"
            case .trailingSilence: return "Waiting for uninterrupted silence: \(CompanionStatusText.seconds(snapshot.remainingSeconds)) seconds"
            case .speaking, .waitingForSpeech: return "Listening"
            }
        }
        if stt.captureState == .requestingPermission { return "Waiting for microphone permission" }
        if model.capturingScreen { return "Reading screen locally…" }
        if model.phase == .listening && !stt.recording { return "Preparing microphone…" }
        if model.phase == .listening && model.automaticReply { return "Listening for your reply" }
        if model.voiceDeliveryNotice != nil { return model.phase == .thinking ? "Generating text. Voice unavailable." : "Text-only reply. Voice unavailable." }
        return model.phase.caption
    }
    private var shortStatus: String {
        if preparation.state == .checking { return "Checking \(Int(preparation.progress * 100))%" }
        if !preparation.ready { return preparation.state == .paused ? "Paused" : "Check files" }
        if case .blocked = model.phase { return CompanionStatusText.issue(model.issue) }
        if model.phase == .idle, let outcome = model.captureOutcome { return outcome }
        if model.phase == .idle, let stage = model.taskStage { return stage }
        if stt.transcribing { return "Transcribing" }
        if stt.recording, let snapshot = stt.timingSnapshot {
            switch snapshot.phase {
            case .invitation: return "Reply \(CompanionStatusText.seconds(snapshot.remainingSeconds))s"
            case .trailingSilence: return "Wait \(CompanionStatusText.seconds(snapshot.remainingSeconds))s"
            case .speaking, .waitingForSpeech: return "Listening"
            }
        }
        if stt.captureState == .requestingPermission { return "Allow mic" }
        if model.capturingScreen { return "Reading screen" }
        switch model.phase {
        case .idle: return model.voiceDeliveryNotice != nil ? "Text only" : model.followupPending ? "Reply soon" : "Ready"
        case .listening: return stt.recording ? "Listening" : "Starting mic"
        case .thinking: return model.voiceDeliveryNotice != nil ? "Thinking · text" : "Thinking"
        case .speaking: return "Speaking"
        case .blocked: return "Try again"
        }
    }

    @ViewBuilder private var taskHaloView: some View {
        switch model.taskHalo {
        case .hidden:
            EmptyView()
        case .indeterminate:
            Circle()
                .trim(from: 0.1, to: 0.45)
                .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 116, height: 116)
        case .determinate(let fraction):
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: min(1, max(0.04, fraction)))
                    .stroke(Color.accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 116, height: 116)
        case .verifiedComplete:
            Circle()
                .stroke(Color.green.opacity(0.88), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 116, height: 116)
        }
    }

    private func openOptions() { model.dismissFirstUseHint(); model.showOptions?() }
    private func stop() { model.stopCurrentTurn(); preparation.pause() }
}

enum CompanionStatusText {
    static func seconds(_ remaining: Double?) -> String {
        guard let remaining, remaining.isFinite else { return "—" }
        return String(Int(ceil(min(60, max(0, remaining)))))
    }
    static func issue(_ issue: CompanionIssue?) -> String {
        switch issue {
        case .screenPermission: return "Allow screen"
        case .screenCapture: return "Screen failed"
        case .vision: return "Vision offline"
        case .speech: return "Check mic"
        case .voice: return "Check voice"
        case .files: return "Check files"
        case .engine: return "Engine offline"
        case .unknown, .none: return "Try again"
        }
    }
}
