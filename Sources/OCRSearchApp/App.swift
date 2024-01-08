import SwiftUI
import AppKit
import ImageIO
import OCRSearchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)      // needed when launched via `swift run`
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct OCRSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("OCR Image Search") { ContentView().frame(minWidth: 760, minHeight: 520) }
        // Full-size viewer: one window per image, closable with the red button, Cmd+W or Esc.
        WindowGroup("Preview", id: "preview", for: PreviewRequest.self) { $req in
            if let req { PreviewView(path: req.path, query: req.query) }
        }.defaultSize(width: 620, height: 900)
        Settings { SettingsView() }
    }
}

struct PreviewRequest: Codable, Hashable {
    let path: String
    let query: String
}

/// FTS5 query -> plain words to look for on the image (drops quotes, operators, wildcards).
func searchTerms(_ q: String) -> [String] {
    let skip: Set<String> = ["AND", "OR", "NOT", "NEAR"]
    return q.components(separatedBy: CharacterSet(charactersIn: " \t\n\"()"))
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*^+-")) }
        .filter { !$0.isEmpty && !skip.contains($0) }
}

/// NSImage is not Sendable; the image is created once on a background task and only read afterwards.
struct ImageBox: @unchecked Sendable {
    let image: NSImage?
    init(_ i: NSImage?) { image = i }
}

struct Thumb: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(.quaternary) }
        }
        .frame(width: 72, height: 72)
        .task(id: path) {
            let p = path
            image = await Task.detached(priority: .utility) { () -> ImageBox in
                guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return ImageBox(nil) }
                let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 160,
                                          kCGImageSourceCreateThumbnailWithTransform: true]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, o as CFDictionary) else { return ImageBox(nil) }
                return ImageBox(NSImage(cgImage: cg, size: .zero))
            }.value.image
        }
    }
}

struct PreviewView: View {
    let path: String
    let query: String
    @State private var image: NSImage?
    @State private var matches: [TextMatch] = []
    @State private var scanning = false
    @State private var failed = false
    @AppStorage(HL.show) private var show = true
    @AppStorage(HL.mode) private var mode = "box"
    @AppStorage(HL.boxHex) private var boxHex = HL.defaultBox
    @AppStorage(HL.opacity) private var opacity = 0.35
    @AppStorage(HL.outline) private var outline = true
    @AppStorage(HL.textHex) private var textHex = HL.defaultText
    @AppStorage(HL.design) private var design = "default"
    @AppStorage(HL.weight) private var weight = "regular"

    var body: some View {
        let box = Color(hex: boxHex) ?? .yellow
        let txt = Color(hex: textHex) ?? .black
        let boxBinding = Binding<Color>(get: { box }, set: { boxHex = $0.hexString })
        let txtBinding = Binding<Color>(get: { txt }, set: { textHex = $0.hexString })
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .overlay(GeometryReader { geo in
                        ForEach(Array((show ? matches : []).enumerated()), id: \.offset) { _, m in
                            let w = m.rect.width * geo.size.width + 4
                            let h = m.rect.height * geo.size.height + 4
                            MatchView(text: m.text, size: CGSize(width: w, height: h), mode: mode,
                                      box: box, textColor: txt, opacity: opacity, outline: outline,
                                      design: design, weight: weight)
                                .position(x: m.rect.midX * geo.size.width,
                                          y: (1 - m.rect.midY) * geo.size.height)
                        }
                    })
                    .padding(12)
            }
            else if failed { Text("Can't open \(path)").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(minWidth: 400, minHeight: 400)
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbar {
            Text(scanning ? "Finding matches…" : (searchTerms(query).isEmpty ? "" : (show ? "\(matches.count) match(es)" : "overlay off")))
                .foregroundStyle(.secondary)
            Toggle("Overlay", isOn: $show)
                .toggleStyle(.switch).help("Show or hide the overlay (Cmd+Shift+O)")
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Picker("Show as", selection: $mode) {
                Text("Boxes").tag("box"); Text("Text").tag("text")
            }.pickerStyle(.segmented).disabled(!show)
            if mode == "text" { ColorPicker("Font", selection: txtBinding, supportsOpacity: false) }
            else { ColorPicker("Box", selection: boxBinding, supportsOpacity: false) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Close") { NSApp.keyWindow?.close() }
        }
        .onExitCommand { NSApp.keyWindow?.close() }
        .task(id: path) {
            image = NSImage(contentsOfFile: path)
            failed = image == nil
            let terms = searchTerms(query)
            guard image != nil, !terms.isEmpty else { return }
            scanning = true
            let p = path
            matches = await Task.detached(priority: .userInitiated) {
                (try? findMatches(at: URL(fileURLWithPath: p), terms: terms)) ?? []
            }.value
            scanning = false
        }
    }
}

struct ContentView: View {
    @StateObject private var m = Model()
    @Environment(\.openWindow) private var openWindow
    @State private var showMiro = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search text inside images (FTS5: foo AND \"exact phrase\" bar*)", text: $m.query)
                    .textFieldStyle(.roundedBorder).onSubmit { m.search() }
                Button("Index folder…") { pick(dir: true) { m.index(folder: $0[0]) } }
                Button("Add files…") { pick(dir: false) { m.add(files: $0) } }
                Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: {
                    Image(systemName: "gearshape")
                }.help("Settings (highlight color)")
            }.padding(10)
            Divider()
            List(m.results, selection: $m.selection) { hit in
                HStack(spacing: 10) {
                    Thumb(path: hit.path)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((hit.path as NSString).lastPathComponent).fontWeight(.medium)
                        Text(hit.snippet.isEmpty ? "(added manually)" : hit.snippet)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        Text((hit.path as NSString).deletingLastPathComponent)
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Button { openWindow(id: "preview", value: PreviewRequest(path: hit.path, query: m.query)) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("View full size")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openWindow(id: "preview", value: PreviewRequest(path: hit.path, query: m.query)) }
                .tag(hit.id)
            }
            Divider()
            HStack {
                Text(m.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if m.busy { ProgressView().controlSize(.small) }
                if let l = m.link { Button("Open board") { NSWorkspace.shared.open(l) } }
                Spacer()
                Button("Select all") { m.selection = Set(m.results.map(\.id)) }.disabled(m.results.isEmpty)
                Menu("Export to file") {
                    Button("CSV (path + OCR text)…") { m.exportToFile(.csv) }
                    Button("Markdown…") { m.exportToFile(.markdown) }
                    Button("Copy images to folder…") { m.exportToFile(.folder) }
                }.disabled(m.selection.isEmpty || m.busy).fixedSize()
                Button("Export \(m.selection.count) to Miro…") { showMiro = true }
                    .disabled(m.selection.isEmpty || m.busy).keyboardShortcut(.defaultAction)
            }.padding(10)
        }
        .sheet(isPresented: $showMiro) { MiroSheet(m: m, isPresented: $showMiro) }
    }

    private func pick(dir: Bool, _ done: @escaping ([URL]) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = dir; p.canChooseFiles = !dir; p.allowsMultipleSelection = !dir
        if p.runModal() == .OK, !p.urls.isEmpty { done(p.urls) }
    }
}

struct MiroSheet: View {
    @ObservedObject var m: Model
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export to Miro").font(.headline)
            SecureField("Miro access token (boards:read, boards:write) — saved in Keychain", text: $m.token)
            TextField("Existing board ID (leave empty to create a new board)", text: $m.boardID)
            TextField("New board name", text: $m.boardName).disabled(!m.boardID.isEmpty)
            Text("\(m.selection.count) item(s): images plus their OCR snippets as sticky notes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Export") { isPresented = false; m.exportSelection() }
                    .keyboardShortcut(.defaultAction).disabled(m.token.isEmpty)
            }
        }.padding(20).frame(width: 480)
    }
}
