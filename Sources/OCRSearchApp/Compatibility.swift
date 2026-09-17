import SwiftUI
import AppKit
import OCRSearchCore

// MARK: - macOS 12 support
//
// The app targets macOS 12. A few things it uses arrived in macOS 13; each has its macOS 13 form
// here and what macOS 12 gets instead, so the rest of the code does not have to check versions.

// MARK: opening a preview window

/// Opens a preview window for a request.
///
/// macOS 13 opens a window for a value (WindowGroup(for:) and openWindow), and OpenWindowBridge
/// hands that over once the search window is up. macOS 12 has no such call, so there the request
/// is parked under an id and the app opens a link to itself, miro-ocr-search://preview/<id>, which
/// the macOS 12 preview scene (LegacyPreviewWindow) answers with a new window. Both keep the
/// preview a SwiftUI window, so its toolbar and the menu-bar commands work the same.
@MainActor enum PreviewOpening {
    static var openWindow: ((PreviewRequest) -> Void)?

    static func open(_ request: PreviewRequest) {
        if let openWindow { openWindow(request); return }
        let id = PreviewRequests.park(request)
        if let url = URL(string: "\(previewURLScheme)://preview/\(id)") { NSWorkspace.shared.open(url) }
    }
}

let previewURLScheme = "miro-ocr-search"

/// Requests waiting for their macOS 12 preview window, by id. Taken, not read: each opens once.
@MainActor enum PreviewRequests {
    private static var waiting: [String: PreviewRequest] = [:]

    static func park(_ request: PreviewRequest) -> String {
        let id = UUID().uuidString
        waiting[id] = request
        return id
    }

    static func take(_ url: URL) -> PreviewRequest? {
        guard url.scheme == previewURLScheme, url.host == "preview" else { return nil }
        return waiting.removeValue(forKey: url.lastPathComponent)
    }
}

/// Puts macOS 13's openWindow where PreviewOpening can use it. Invisible; lives in the search window.
@available(macOS 13, *)
struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { PreviewOpening.openWindow = { openWindow(id: "preview", value: $0) } }
    }
}

/// A macOS 12 preview window: empty until its link arrives, then the preview for that request.
///
/// Once it has a request it stops accepting links, so the next one opens a new window rather than
/// replacing this one's image.
struct LegacyPreviewWindow: View {
    @State private var request: PreviewRequest?

    var body: some View {
        Group {
            if let request {
                PreviewView(allPaths: request.allPaths, startIndex: request.startIndex,
                            query: request.query, searchMode: request.mode)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 400, idealWidth: 830, minHeight: 400, idealHeight: 900)
        .onOpenURL { url in
            if request == nil { request = PreviewRequests.take(url) }
        }
        .handlesExternalEvents(preferring: request == nil ? ["preview"] : [],
                               allowing: request == nil ? ["preview"] : [])
    }
}

// MARK: view modifiers

extension View {
    /// The title bar's document icon for `url`: navigationDocument on macOS 13, the window's own
    /// represented file on macOS 12 — the same icon, ⌘-click for the folder, drag for the file.
    @ViewBuilder func documentProxy(_ url: URL) -> some View {
        if #available(macOS 13, *) {
            navigationDocument(url)
        } else {
            background(RepresentedURLSetter(url: url))
        }
    }

    /// Phrase / Any Word for the preview's search field: as search scopes under the field on macOS
    /// 13, as a small menu beside it on macOS 12, which has no search scopes.
    @ViewBuilder func searchModeChoice(_ mode: Binding<SearchMode>) -> some View {
        if #available(macOS 13, *) {
            searchScopes(mode) {
                Text("Phrase").tag(SearchMode.phrase)
                Text("Any Word").tag(SearchMode.words)
            }
        } else {
            toolbar {
                ToolbarItem {
                    Picker("Search as", selection: mode) {
                        Text("Phrase").tag(SearchMode.phrase)
                        Text("Any Word").tag(SearchMode.words)
                    }
                    .pickerStyle(.menu).fixedSize()
                    .help("Phrase finds the whole search text in order; Any Word finds each word on its own")
                }
            }
        }
    }

    /// Follows the pointer over a match, for the hover card: onContinuousHover on macOS 13. macOS
    /// 12 cannot report where the pointer is, so there is no hover card there; Go ▸ Next Match
    /// still shows the card for each match.
    @ViewBuilder func matchHover(in space: String, moved: @escaping (CGPoint) -> Void,
                                 ended: @escaping () -> Void) -> some View {
        if #available(macOS 13, *) {
            onContinuousHover(coordinateSpace: .named(space)) { phase in
                switch phase {
                case .active(let p): moved(p)
                case .ended: ended()
                }
            }
        } else {
            self
        }
    }
}

/// Sets its window's represented file (the title bar's document icon) on macOS 12.
private struct RepresentedURLSetter: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.representedURL = url }
    }
}
