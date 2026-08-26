import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OCRSearchCore

struct ContentView: View {
    @StateObject private var m = Model()
    @Environment(\.openWindow) private var openWindow
    @State private var showMiro = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search text inside images", text: $m.query)
                    .textFieldStyle(.roundedBorder).onSubmit { m.search() }
                    .help("Type any text and press Return. Phrase finds the whole text in order; Any word finds each word on its own.")
                Picker("", selection: $m.searchMode) {
                    Text("Phrase").tag(SearchMode.phrase)
                    Text("Any word").tag(SearchMode.words)
                }
                .pickerStyle(.segmented).frame(width: 150)
                .help("Phrase: match the whole search text together, in order. Any word: match each word separately, anywhere.")
                .onChange(of: m.searchMode) { _ in m.search() }
                // The folder being searched, and the only thing being searched: there is no index
                // behind this, so what is listed always comes from the folder shown here.
                Menu {
                    Button("Open folder…") { pick(dir: true) { m.open(folder: $0[0]) } }
                    if m.folder != nil {
                        Button("Reload", action: m.reload)
                            .help("Re-read the folder, picking up anything added or changed")
                        Divider()
                        Button("Reveal in Finder") {
                            if let f = m.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                        }
                    }
                    Divider()
                    Button("Add files…") { pick(dir: false) { m.add(files: $0) } }
                } label: {
                    Label(m.folder?.lastPathComponent ?? "Choose folder…", systemImage: "folder")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(m.folder?.path ?? "Pick the folder of images to search")

                Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: {
                    Image(systemName: "gearshape")
                }.help("Settings: the overlay's default look").accessibilityLabel("Settings")
            }.padding(10)
            .onAppear { m.restoreFolder() }
            Divider()
            if m.results.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(m.folder == nil ? "No folder open"
                         : m.query.isEmpty ? "Ready to search \(m.folder!.lastPathComponent)"
                         : "No matches for “\(m.query)” in \(m.folder!.lastPathComponent)")
                        .font(.title3).foregroundStyle(.secondary)
                    if m.folder == nil {
                        Text("Choose a folder of screenshots to search the text inside them.")
                            .font(.callout).foregroundStyle(.tertiary)
                        Button("Open folder…") { pick(dir: true) { m.open(folder: $0[0]) } }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                    } else if m.query.isEmpty {
                        Text("Type any text and press Return.")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(m.results, selection: $m.selection) { hit in
                    HStack(spacing: 10) {
                        // An explicit checkbox for what gets exported. The list's own selection
                        // still drives it, but selection and "included in the export" are not the
                        // same idea to look at — a highlighted row says which one you are reading,
                        // a ticked box says which ones are going out — and the export buttons
                        // count the latter.
                        Toggle("", isOn: Binding(
                            get: { m.selection.contains(hit.id) },
                            set: { on in
                                if on { m.selection.insert(hit.id) } else { m.selection.remove(hit.id) }
                            }))
                            .labelsHidden()
                            .help("Include this image in exports")
                            .accessibilityLabel("Include \((hit.path as NSString).lastPathComponent) in exports")
                        Thumb(path: hit.path)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((hit.path as NSString).lastPathComponent).fontWeight(.medium)
                            Text(hit.snippet.isEmpty ? "(added manually)" : hit.snippet)
                                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            Text((hit.path as NSString).deletingLastPathComponent)
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Button("View") { openPreview(hit) }
                            .help("Open this image full size")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { openPreview(hit) }
                    .tag(hit.id)
                }
            }
            Divider()
            HStack {
                Text(m.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let r = m.reading {
                    ProgressView(value: Double(r.done), total: Double(max(r.total, 1)))
                        .frame(width: 90).controlSize(.small)
                    Text("\(r.done)/\(r.total)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                } else if m.busy {
                    ProgressView().controlSize(.small)
                }
                if let l = m.link {
                    Button { NSWorkspace.shared.open(l) } label: { MiroBadge(size: 14); Text("Open board") }
                }
                Spacer()
                // One control rather than two: once everything is ticked the only thing left to
                // want is to untick it.
                Button(m.selection.count == m.results.count && !m.results.isEmpty ? "Select none" : "Select all") {
                    m.selection = m.selection.count == m.results.count ? [] : Set(m.results.map(\.id))
                }
                .disabled(m.results.isEmpty)
                Menu("Export to file") {
                    Button("CSV (path + OCR text)…") { m.exportToFile(.csv) }
                    Button("Markdown…") { m.exportToFile(.markdown) }
                    Divider()
                    Button("Images to directory…") { m.exportToFile(.images) }
                }.disabled(m.selection.isEmpty || m.busy).fixedSize()
                Button { showMiro = true } label: { MiroBadge(size: 14); Text("Export \(m.selection.count) to Miro…") }
                    .disabled(m.selection.isEmpty || m.busy).keyboardShortcut(.defaultAction)
            }.padding(10)
        }
        .sheet(isPresented: $showMiro) { MiroSheet(m: m, isPresented: $showMiro) }
    }

    /// Opens the preview on `hit`, but hands it the whole current result list so its toolbar can
    /// page Previous/Next through the other results without coming back here.
    private func openPreview(_ hit: Hit) {
        let paths = m.results.map(\.path)
        openWindow(id: "preview", value: PreviewRequest(path: hit.path, query: m.query, mode: m.searchMode,
                                                        allPaths: paths,
                                                        startIndex: paths.firstIndex(of: hit.path) ?? 0))
    }

    /// Shows an open panel modelessly, on the next turn of the run loop.
    ///
    /// Not runModal(): these are invoked from a Menu item, and starting a nested modal run loop
    /// while AppKit is still unwinding the menu's own tracking loop hangs the app — no crash
    /// report, because nothing crashes; the window simply stops responding. It only started
    /// happening when these moved from plain toolbar buttons into the folder menu.
    private func pick(dir: Bool, _ done: @escaping ([URL]) -> Void) {
        DispatchQueue.main.async {
            let p = Panels.openPanel(dir: dir)
            guard !p.isVisible else { return }   // one at a time; it is a shared panel now
            p.begin { response in
                guard response == .OK, !p.urls.isEmpty else { return }
                done(p.urls)
            }
        }
    }
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
            else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
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
