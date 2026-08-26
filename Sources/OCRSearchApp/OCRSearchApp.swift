import SwiftUI
import AppKit
import OCRSearchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)      // needed when launched via `swift run`
        Panels.warmUp()   // see Panels: never build one under a click
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct OCRSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() { SelfTest.runIfRequested() }
    var body: some Scene {
        WindowGroup("Miro-ocr-search") { ContentView().frame(minWidth: 760, minHeight: 520) }
            .commands { WatermarkCommands(); PreviewCommands() }
        // Full-size viewer: one window per image, closable with the red button, Cmd+W or Esc.
        WindowGroup("Preview", id: "preview", for: PreviewRequest.self) { $req in
            if let req { PreviewView(allPaths: req.allPaths, startIndex: req.startIndex, query: req.query, searchMode: req.mode) }
        }.defaultSize(width: 620, height: 900)
        Settings { SettingsView() }
    }
}
