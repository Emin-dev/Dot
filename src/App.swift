import SwiftUI
import AppKit

@main
struct DotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Dot", id: "main") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 680, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Never orphan the supervised engine (17 GB of RAM!) or leave the mic tap
    // running after the app quits.
    func applicationWillTerminate(_ notification: Notification) {
        EngineManager.shared.stopEngine()
        TTSManager.shared.stop()
        STTManager.shared.stop()
    }
}
