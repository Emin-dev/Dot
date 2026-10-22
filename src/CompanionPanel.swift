import AppKit
import SwiftUI

/// R19 (owner answer 2026-10-22): a failure never changes how Dot looks or lives.
/// Its words float above Dot in large text instead: a click-through child panel
/// that moves with Dot and flips below it near the top of the screen.
@MainActor
final class IssueBanner {
    static let size = NSSize(width: 320, height: 112)
    private var window: NSPanel?
    private var host: NSHostingView<IssueBannerView>?
    private var moveObserver: NSObjectProtocol?
    private var text = ""

    func update(text: String?, above parent: NSWindow) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { hide(); return }
        let banner = window ?? make()
        self.text = text
        if banner.parent !== parent {
            banner.parent?.removeChildWindow(banner)
            parent.addChildWindow(banner, ordered: .above)
            if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
            moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: parent, queue: .main) { [weak self, weak parent] _ in
                MainActor.assumeIsolated {
                    guard let self, let parent, let window = self.window, window.isVisible else { return }
                    self.position(window, around: parent)
                }
            }
        }
        position(banner, around: parent)
        if parent.isVisible { banner.orderFront(nil) }
    }

    func hide() { window?.orderOut(nil) }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("dot.issue")
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSHostingView(rootView: IssueBannerView(text: "", above: true))
        panel.contentView = view
        window = panel; host = view
        return panel
    }

    private func position(_ banner: NSWindow, around parent: NSWindow) {
        let pet = parent.frame
        let visible = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? pet
        var origin = CGPoint(x: pet.midX - Self.size.width / 2, y: pet.maxY - 8)
        let above = origin.y + Self.size.height <= visible.maxY
        if !above { origin.y = pet.minY - Self.size.height + 8 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.size.width)
        host?.rootView = IssueBannerView(text: text, above: above)
        banner.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }
}

struct IssueBannerView: View {
    let text: String
    /// Above Dot the text sits on Dot's head; below it, under Dot's feet.
    let above: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.88)))
            .frame(width: IssueBanner.size.width, height: IssueBanner.size.height, alignment: above ? .bottom : .top)
            .accessibilityHidden(true)
    }
}

/// The application owns one reusable surface. Menus and OS permission prompts are separate system UI.
@MainActor
final class CompanionPanel: NSPanel, NSDraggingDestination {
    var stopAction: (() -> Void)?
    var optionsAction: (() -> Void)?
    var primaryAction: (() -> Void)?
    var secondaryAction: (() -> Void)?
    var onFileDropped: ((URL) -> Void)?
    var primaryHitTest: ((NSPoint) -> Bool)?
    var controlHitTest: ((NSPoint) -> Bool)?
    var pointerInteraction: ((Bool) -> Void)?
    /// Native controls track without cancelling the turn and replacing their own button mid-click.
    var controlInteraction: ((Bool) -> Void)?
    var constrainDrag: ((NSPoint, NSPoint) -> NSPoint)?
    var visibilityChanged: ((Bool) -> Void)?
    private var pointer = CompanionDragState()
    private var nativeControlPressed = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        registerForDraggedTypes([.fileURL])
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pboard = sender.draggingPasteboard
        if let types = pboard.types, types.contains(.fileURL) {
            return .copy
        }
        return []
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pasteboard = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let firstURL = pasteboard.first else { return false }
        onFileDropped?(firstURL)
        return true
    }

    func cancelPointerGesture() {
        let wasPressed = pointer.isPressed, wasControl = nativeControlPressed
        pointer.cancel(); nativeControlPressed = false
        if wasPressed { pointerInteraction?(false) }
        if wasControl { controlInteraction?(false) }
    }
    private func openOptions() { cancelPointerGesture(); optionsAction?() }
    override func cancelOperation(_ sender: Any?) { cancelPointerGesture(); stopAction?() }
    override func resignKey() { cancelPointerGesture(); super.resignKey() }
    override func close() { cancelPointerGesture(); visibilityChanged?(false); super.close() }
    override func orderOut(_ sender: Any?) { visibilityChanged?(false); super.orderOut(sender) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        if event.keyCode == 109, event.modifierFlags.contains(.shift) { openOptions(); return }
        super.keyDown(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 || (event.keyCode == 109 && event.modifierFlags.contains(.shift)) {
            keyDown(with: event); return
        }
        if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            cancelPointerGesture(); makeKey(); openOptions(); return
        }
        if event.type == .leftMouseDown {
            cancelPointerGesture()
            if controlHitTest?(event.locationInWindow) == true {
                nativeControlPressed = true; makeKey(); controlInteraction?(true)
                super.sendEvent(event); return
            }
            guard primaryHitTest?(event.locationInWindow) == true else { return }
            makeKey()
            pointer.begin(point: convertPoint(toScreen: event.locationInWindow), origin: frame.origin)
            pointerInteraction?(true); return
        }
        if event.type == .leftMouseDragged {
            if nativeControlPressed { super.sendEvent(event); return }
            let point = convertPoint(toScreen: event.locationInWindow)
            if let origin = pointer.update(point: point) {
                setFrameOrigin(constrainDrag?(origin, point) ?? origin)
            }
            return
        }
        if event.type == .leftMouseUp {
            if nativeControlPressed {
                nativeControlPressed = false; controlInteraction?(false)
                super.sendEvent(event); return
            }
            let wasPressed = pointer.isPressed
            let click = pointer.release(point: convertPoint(toScreen: event.locationInWindow),
                                        inside: primaryHitTest?(event.locationInWindow) == true)
            if wasPressed { pointerInteraction?(false) }
            if click {
                if event.clickCount == 2 {
                    secondaryAction?()
                } else {
                    primaryAction?()
                }
            }
            return
        }
        super.sendEvent(event)
    }
    override func rightMouseDown(with event: NSEvent) { openOptions() }
}

@MainActor
final class CompanionSurface {
    private(set) var panel: CompanionPanel?
    @discardableResult
    func present(content: NSView, size: NSSize) -> CompanionPanel {
        let window: CompanionPanel
        if let panel { window = panel }
        else {
            window = CompanionPanel(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("dot.companion")
            window.title = "Dot companion"
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.level = .floating; window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false; window.becomesKeyOnlyIfNeeded = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = window
        }
        window.contentView = content; window.orderFrontRegardless()
        return window
    }
    func recall(visibleFrames: [CGRect]? = nil) {
        guard let panel else { return }
        let frames = visibleFrames ?? NSScreen.screens.map { $0.visibleFrame }
        // Explicit recall is a user-requested visibility recovery, never a claim of sensed empty content.
        if !frames.contains(where: { $0.contains(panel.frame) }), let visible = frames.first {
            if let bounds = RoamingCore.originBounds(window: panel.frame.size, visible: visible) {
                panel.setFrameOrigin(RoamingCore.clamp(panel.frame.origin, to: bounds))
            } else if PlacementSnapshot.validRect(visible) {
                panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2))
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }
}

/// One utility-surface lifecycle for the app's native panels: the same titled, closable, resizable
/// window, delegate wiring, centring and show order. Panels keep their own size, title, content and
/// window class, so no existing surface changes.
@MainActor
final class UtilityPanelHost {
    private let size: NSSize, minSize: NSSize
    private let title: String
    private let makeWindow: ((NSRect) -> NSPanel)?
    private(set) var panel: NSPanel?
    init(size: NSSize, minSize: NSSize, title: String, makeWindow: ((NSRect) -> NSPanel)? = nil) {
        self.size = size; self.minSize = minSize; self.title = title; self.makeWindow = makeWindow
    }
    /// Creates the window once; later calls return the same surface.
    @discardableResult
    func window(delegate: NSWindowDelegate, configure: (NSPanel) -> Void = { _ in }, content: () -> NSView) -> NSPanel {
        if let panel { return panel }
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let window = makeWindow?(rect) ?? NSPanel(contentRect: rect, styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                                  backing: .buffered, defer: false)
        window.title = title; window.minSize = minSize
        window.isReleasedWhenClosed = false; window.delegate = delegate
        configure(window); window.contentView = content(); window.center()
        panel = window
        return window
    }
    /// Reports visibility, then shows key and front, then activates: the order every panel used.
    func present(_ onVisibility: ((Bool) -> Void)?) {
        onVisibility?(true)
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
    func endAttachedSheet() {
        if let panel, let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .cancel) }
    }
}


@MainActor
enum CompanionStatusMenu {
    static func make(target: AnyObject, show: Selector, quit: Selector, options: Selector? = nil, type: Selector? = nil,
                     readiness: CompanionReadiness? = nil, pauseAction: Selector? = nil, retryAction: Selector? = nil) -> NSMenu {
        let menu = NSMenu()
        let recall = NSMenuItem(title: "Show Dot", action: show, keyEquivalent: "")
        recall.target = target; menu.addItem(recall)
        if let options {
            let item = NSMenuItem(title: "Options…", action: options, keyEquivalent: ",")
            item.target = target; menu.addItem(item)
        }
        if let type {
            let item = NSMenuItem(title: "Type to Dot…", action: type, keyEquivalent: "t")
            item.target = target; menu.addItem(item)
        }
        if let readiness {
            // The same pause/retry actions as the options menu, for the readiness
            // the menu was built for, so "retry from the menu" is a real action.
            if readiness.canPause, let pauseAction {
                let item = NSMenuItem(title: CompanionMenuAction.pause.title(busy: false, pinned: false, issue: nil),
                                      action: pauseAction, keyEquivalent: "")
                item.target = target; menu.addItem(item)
            }
            if readiness.canRetry, let retryAction {
                let item = NSMenuItem(title: CompanionMenuAction.retry.title(busy: false, pinned: false, issue: nil),
                                      action: retryAction, keyEquivalent: "")
                item.target = target; menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let exit = NSMenuItem(title: "Quit Dot", action: quit, keyEquivalent: "q")
        exit.target = target; menu.addItem(exit)
        return menu
    }
}

/// Native menu controls keep the companion's single-surface design.
@MainActor
enum VoiceOptionsMenu {
    static func make(settings: VoiceTimingSettings, target: AnyObject, silence: Selector, invitation: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "Voice settings", action: nil, keyEquivalent: "")
        let menu = NSMenu(); item.submenu = menu
        for (title, choices, selected, action) in [
            ("Silence before responding", VoiceTimingSettings.silenceChoices, settings.silenceSeconds, silence),
            ("Time to begin a reply", VoiceTimingSettings.invitationChoices, settings.invitationSeconds, invitation)
        ] {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""), options = NSMenu()
            parent.submenu = options
            for seconds in choices {
                let choice = NSMenuItem(title: "\(Int(seconds)) seconds", action: action, keyEquivalent: "")
                choice.tag = Int(seconds); choice.target = target; choice.state = seconds == selected ? .on : .off
                options.addItem(choice)
            }
            menu.addItem(parent)
        }
        let hint = NSMenuItem(title: "Reply time limits when speech starts, not its length", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        return item
    }
}


@MainActor
enum AppearanceOptionsMenu {
    static func make(settings: SkinPreferences, target: AnyObject, skin: Selector, motion: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: ""), menu = NSMenu()
        for value in DotSkin.allCases {
            let item = NSMenuItem(title: value.displayName, action: skin, keyEquivalent: "")
            item.target = target; item.representedObject = value.rawValue
            item.state = settings.selected == value ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let detail = NSMenuItem(title: "Animation detail", action: nil, keyEquivalent: ""), choices = NSMenu()
        for value in SkinMotionDetail.allCases {
            let item = NSMenuItem(title: value.displayName, action: motion, keyEquivalent: "")
            item.target = target; item.representedObject = value.rawValue
            item.state = settings.motionDetail == value ? .on : .off; choices.addItem(item)
        }
        detail.submenu = choices; menu.addItem(detail); root.submenu = menu; return root
    }
}

@MainActor
enum TrustedAppsMenu {
    static func make(store: TrustedAppStore, frontmost: String?, target: AnyObject,
                     trust: Selector, removeAll: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: "Trusted apps", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let hint = NSMenuItem(title: "App actions for trusted apps skip the card", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint); menu.addItem(.separator())
        if let frontmost, !frontmost.isEmpty {
            let item = NSMenuItem(title: frontmost, action: trust, keyEquivalent: "")
            item.target = target; item.representedObject = frontmost
            item.state = store.isTrusted(frontmost) ? .on : .off
            menu.addItem(item)
        }
        if !store.names.isEmpty {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Remove all trusted apps", action: removeAll, keyEquivalent: "")
            clear.target = target; menu.addItem(clear)
        }
        root.submenu = menu
        return root
    }
}

@MainActor
enum BatteryOptionsMenu {
    static func make(settings: BatteryAlertSettings, target: AnyObject, toggle: Selector,
                     threshold: Selector, charging: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: "Battery alerts", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let enable = NSMenuItem(title: "Low-battery and charging alerts", action: toggle, keyEquivalent: "")
        enable.target = target; enable.state = settings.enabled ? .on : .off; menu.addItem(enable)
        menu.addItem(.separator())
        let lowParent = NSMenuItem(title: "Low-battery threshold", action: nil, keyEquivalent: "")
        let lowMenu = NSMenu(); lowParent.submenu = lowMenu
        for value in BatteryAlertSettings.thresholds {
            let item = NSMenuItem(title: "\(value)%", action: threshold, keyEquivalent: "")
            item.target = target; item.tag = value
            item.state = settings.lowThreshold == value ? .on : .off
            lowMenu.addItem(item)
        }
        menu.addItem(lowParent)
        let chargingItem = NSMenuItem(title: "Charging started alert", action: charging, keyEquivalent: "")
        chargingItem.target = target; chargingItem.state = settings.chargingAlerts ? .on : .off
        menu.addItem(chargingItem)
        let hint = NSMenuItem(title: "Off by default; each event is spoken once", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        root.submenu = menu
        return root
    }
}

@MainActor
enum ProactivityOptionsMenu {
    static func make(proactive: ProactiveBehavior, target: AnyObject, action: Selector, pauseAction: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: "Proactivity", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let pauseItem = NSMenuItem(title: "Pause suggestions", action: pauseAction, keyEquivalent: "")
        pauseItem.target = target
        pauseItem.state = proactive.paused ? .on : .off
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        for freq in ProactiveFrequency.allCases {
            let item = NSMenuItem(title: freq.displayName, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = freq.rawValue
            item.state = (!proactive.paused && proactive.frequency == freq) ? .on : .off
            menu.addItem(item)
        }
        root.submenu = menu
        return root
    }
}
