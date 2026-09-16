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

/// Picks the app for this macOS. SceneBuilder cannot branch on the OS version before macOS 13,
/// so the two differ as whole App types, only in how the preview window is declared.
@main
enum Launcher {
    static func main() {
        // Before anything can detect or draw a font: Noto Sans stands in for SF (see
        // systemFontReplacement) and has to exist on Macs that never installed it.
        registerBundledFonts()
        SelfTest.runIfRequested()
        Probe.runIfRequested()
        if #available(macOS 13, *) { OCRSearchApp.main() } else { LegacyOCRSearchApp.main() }
    }
}

/// The search window: the same on every macOS.
private func searchWindow() -> some Scene {
    WindowGroup("Miro-ocr-search") { ContentView().frame(minWidth: 760, minHeight: 520) }
        .commands { WatermarkCommands(); PreviewCommands() }
        .handlesExternalEvents(matching: ["main"])   // the macOS 12 preview links are not for it
}

/// macOS 13 and later. Full-size viewer: one window per image, closable with the red button,
/// Cmd+W or Esc, opened for a value — see PreviewOpening.
@available(macOS 13, *)
struct OCRSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        searchWindow()
        WindowGroup("Preview", id: "preview", for: PreviewRequest.self) { $req in
            if let req { PreviewView(allPaths: req.allPaths, startIndex: req.startIndex, query: req.query, searchMode: req.mode) }
        }.defaultSize(width: 620, height: 900)
        Settings { SettingsView() }
    }
}

/// macOS 12: the same, with the preview window opened through a link — see PreviewOpening.
struct LegacyOCRSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        searchWindow()
        WindowGroup("Preview") { LegacyPreviewWindow() }
            .handlesExternalEvents(matching: ["preview"])
        Settings { SettingsView() }
    }
}
