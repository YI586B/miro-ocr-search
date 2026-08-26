import SwiftUI

/// The watermark switch, in the menu bar. Turning it on is free; turning it off asks first.
struct WatermarkCommands: Commands {
    @AppStorage(Watermark.key) private var on = Watermark.defaultOn

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Watermark", isOn: Binding(
                get: { on },
                set: { wanted in
                    guard !wanted else { on = true; return }
                    // Deferred off the menu action: the switch only moves once the sheet comes
                    // back, and running a modal while the menu is still unwinding is the shape of
                    // trouble this app has already had once, with the file panels.
                    DispatchQueue.main.async {
                        if Watermark.confirmTurnOff() { on = false }
                    }
                }))
            .help("Stamp the miro badge on previews and exports. A password is needed to turn it off.")
        }
    }
}

/// What the frontmost preview window offers the menu bar. Published with focusedSceneValue, so
/// these menu items act on whichever preview is in front and are disabled when none is.
struct PreviewActions {
    var zoomIn: () -> Void, zoomOut: () -> Void, actualSize: () -> Void, zoomToFit: () -> Void
    var canZoomIn: Bool, canZoomOut: Bool
    var previous: () -> Void, next: () -> Void
    var hasPrevious: Bool, hasNext: Bool
    var previousMatch: () -> Void, nextMatch: () -> Void
    var hasMatches: Bool
    var recalculate: () -> Void
    var canRecalculate: Bool
    var export: () -> Void, reveal: () -> Void
    var toggleInspector: () -> Void
    var inspectorShown: Bool
}

private struct PreviewActionsKey: FocusedValueKey { typealias Value = PreviewActions }

extension FocusedValues {
    var preview: PreviewActions? {
        get { self[PreviewActionsKey.self] }
        set { self[PreviewActionsKey.self] = newValue }
    }
}

/// The preview window's commands, in the menu bar. They live here rather than only on toolbar
/// buttons so the shortcuts keep working when a button is in the toolbar's overflow menu or the
/// toolbar is hidden. The overlay switches are app-wide settings, so they work from any window.
struct PreviewCommands: Commands {
    @AppStorage(HL.show) private var overlayOn = OverlayStyle.defaults.show
    @AppStorage(HL.showBoxes) private var showBoxes = OverlayStyle.defaults.showBoxes
    @AppStorage(HL.showText) private var showText = OverlayStyle.defaults.showText
    @FocusedValue(\.preview) private var preview

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export as PNG…") { preview?.export() }
                .keyboardShortcut("s").disabled(preview == nil)
            Button("Reveal in Finder") { preview?.reveal() }.disabled(preview == nil)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Overlay", isOn: $overlayOn).keyboardShortcut("o", modifiers: [.command, .shift])
            Toggle("Show Boxes", isOn: $showBoxes).disabled(!overlayOn)
            Toggle("Show Text", isOn: $showText).disabled(!overlayOn)
            Divider()
            Button("Zoom In") { preview?.zoomIn() }
                .keyboardShortcut("+").disabled(!(preview?.canZoomIn ?? false))
            Button("Zoom Out") { preview?.zoomOut() }
                .keyboardShortcut("-").disabled(!(preview?.canZoomOut ?? false))
            Button("Actual Size") { preview?.actualSize() }
                .keyboardShortcut("0").disabled(preview == nil)
            Button("Zoom to Fit") { preview?.zoomToFit() }
                .keyboardShortcut("9").disabled(preview == nil)
            Divider()
            Button(preview?.inspectorShown == true ? "Hide Style Inspector" : "Show Style Inspector") {
                preview?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option]).disabled(preview == nil)
            Button("Recalculate Overlay") { preview?.recalculate() }
                .keyboardShortcut("r").disabled(!(preview?.canRecalculate ?? false))
        }
        CommandMenu("Go") {
            Button("Previous Image") { preview?.previous() }
                .keyboardShortcut("[").disabled(!(preview?.hasPrevious ?? false))
            Button("Next Image") { preview?.next() }
                .keyboardShortcut("]").disabled(!(preview?.hasNext ?? false))
            Divider()
            Button("Previous Match") { preview?.previousMatch() }
                .keyboardShortcut("[", modifiers: [.command, .option]).disabled(!(preview?.hasMatches ?? false))
            Button("Next Match") { preview?.nextMatch() }
                .keyboardShortcut("]", modifiers: [.command, .option]).disabled(!(preview?.hasMatches ?? false))
        }
    }
}
