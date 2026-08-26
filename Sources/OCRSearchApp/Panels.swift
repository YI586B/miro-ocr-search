import AppKit

/// The app's file panels, built once at launch and reused.
///
/// -[NSSavePanel init] is not a cheap constructor. It opens a connection to an out-of-process
/// ViewBridge service and blocks the main thread on a nested run loop until that service answers.
/// Sampled during a hang, the app sat in exactly that frame — _initBridgeAndStuff waiting on an
/// NSCFRunLoopSemaphore — for 2380 of 2380 samples, with no panel service process ever having
/// started for it.
///
/// Why that stall happens is still unknown: it did not reproduce here with stale services present,
/// launched directly or through LaunchServices, in full screen, on repeated opening and
/// dismissing, or from a menu item's action — every one of those built a panel in about a third of
/// a second. What is known is where it blocks, and that building a panel at launch has been fast
/// in every run. So the construction happens once, at launch, and opening a file afterwards only
/// calls begin(), which does not touch the bridge.
///
/// A reused panel keeps its settings between uses, so every caller sets the ones it cares about.
@MainActor enum Panels {
    static let open = NSOpenPanel()
    static let save = NSSavePanel()

    /// Builds both now, so neither is built in response to a click.
    static func warmUp() { _ = open; _ = save }

    /// An open panel reset to a known state. `dir` picks folders, otherwise files.
    static func openPanel(dir: Bool) -> NSOpenPanel {
        let p = open
        p.canChooseDirectories = dir
        p.canChooseFiles = !dir
        p.allowsMultipleSelection = !dir
        p.prompt = nil
        p.message = nil
        return p
    }
}
