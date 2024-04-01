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
            if let req { PreviewView(path: req.path, query: req.query, searchMode: req.mode) }
        }.defaultSize(width: 620, height: 900)
        Settings { SettingsView() }
    }
}

struct PreviewRequest: Codable, Hashable {
    let path: String
    let query: String
    var mode: SearchMode = .phrase
}

/// Approximate the image's background color immediately around each match box, so text-overlay
/// mode can paint the redrawn word over a same-colored patch instead of just floating on top of
/// the original characters. Samples just outside the box on all four sides — at the midpoint of
/// each edge, offset outward by a small margin so it lands past any anti-aliased glyph pixel,
/// never inside the box itself — and averages them; falls back to `nil` (caller uses its own
/// default) if the image can't be read as a bitmap.
/// An image's pixel dimensions, read from its metadata without decoding the full bitmap.
func imagePixelSize(at path: String) -> CGSize? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
          let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
    return CGSize(width: w, height: h)
}

func sampledBackgroundColors(at path: String, rects: [CGRect]) -> [Color?] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return Array(repeating: nil, count: rects.count) }
    let rep = NSBitmapImageRep(cgImage: cg)
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return Array(repeating: nil, count: rects.count) }
    func sample(_ rect: CGRect) -> Color? {
        // Vision rects are normalised with origin bottom-left; bitmap pixel rows run top-down.
        let x0 = rect.minX, x1 = rect.maxX
        let yTop = 1 - rect.maxY, yBottom = 1 - rect.minY
        let midX = (x0 + x1) / 2, midY = (yTop + yBottom) / 2
        let marginX = max((x1 - x0) * 0.15, 2 / CGFloat(w)), marginY = max((yBottom - yTop) * 0.15, 2 / CGFloat(h))
        let points: [(CGFloat, CGFloat)] = [
            (midX, yTop - marginY), (midX, yBottom + marginY),   // just above, just below
            (x0 - marginX, midY), (x1 + marginX, midY)           // just left, just right
        ]
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for (nx, ny) in points {
            let px = min(max(Int(nx * CGFloat(w)), 0), w - 1)
            let py = min(max(Int(ny * CGFloat(h)), 0), h - 1)
            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        }
        guard n > 0 else { return nil }
        return Color(.sRGB, red: r / n, green: g / n, blue: b / n, opacity: 1)
    }
    return rects.map(sample)
}

/// Query -> the term(s) to look for on the image (drops quotes, operators, wildcards). In
/// `.phrase` mode the whole query is kept together as one term, so only that contiguous phrase
/// gets highlighted; in `.words` mode each word is highlighted separately, wherever it appears.
func searchTerms(_ q: String, mode: SearchMode) -> [String] {
    if mode == .phrase {
        let t = q.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"()*^+-"))
        return t.isEmpty ? [] : [t]
    }
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
    let searchMode: SearchMode
    @State private var image: NSImage?
    @State private var matches: [TextMatch] = []
    @State private var bgColors: [Color?] = []
    @State private var matchedFonts: [String?] = []
    @State private var scanning = false
    @State private var failed = false
    @State private var hoverIndex: Int?
    @State private var hoverPoint: CGPoint = .zero
    @AppStorage(HL.show) private var show = true
    @AppStorage(HL.mode) private var mode = "box"
    @AppStorage(HL.boxHex) private var boxHex = HL.defaultBox
    @AppStorage(HL.opacity) private var opacity = 0.35
    @AppStorage(HL.outline) private var outline = true
    @AppStorage(HL.textHex) private var textHex = HL.defaultText
    @AppStorage(HL.bgHex) private var bgHex = HL.defaultBg
    @AppStorage(HL.autoBg) private var autoBg = true
    @AppStorage(HL.design) private var design = "default"
    @AppStorage(HL.weight) private var weight = "regular"
    @AppStorage(HL.autoFont) private var autoFont = false

    var body: some View {
        let box = Color(hex: boxHex) ?? .yellow
        let txt = Color(hex: textHex) ?? .black
        let bg = Color(hex: bgHex) ?? .white
        let boxBinding = Binding<Color>(get: { box }, set: { boxHex = $0.hexString })
        let txtBinding = Binding<Color>(get: { txt }, set: { textHex = $0.hexString })
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .overlay(GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            ForEach(Array((show ? matches : []).enumerated()), id: \.offset) { i, m in
                                let w = m.rect.width * geo.size.width + 4
                                let h = m.rect.height * geo.size.height + 4
                                MatchView(text: m.text, size: CGSize(width: w, height: h), mode: mode,
                                          box: box, textColor: txt, opacity: opacity, outline: outline,
                                          design: design, weight: weight,
                                          sampled: bgColors.indices.contains(i) ? bgColors[i] : nil, background: bg,
                                          autoBackground: autoBg,
                                          matchedFont: matchedFonts.indices.contains(i) ? matchedFonts[i] : nil,
                                          autoFont: autoFont)
                                    .position(x: m.rect.midX * geo.size.width,
                                              y: (1 - m.rect.midY) * geo.size.height)
                                    .onContinuousHover(coordinateSpace: .named("preview")) { phase in
                                        switch phase {
                                        case .active(let p): hoverIndex = i; hoverPoint = p
                                        case .ended: if hoverIndex == i { hoverIndex = nil }
                                        }
                                    }
                            }
                            if let i = hoverIndex, matches.indices.contains(i) {
                                let m = matches[i]
                                let w = m.rect.width * geo.size.width + 4
                                let h = m.rect.height * geo.size.height + 4
                                let mf = matchedFonts.indices.contains(i) ? matchedFonts[i] : nil
                                MatchInfoPopup(text: m.text, mode: mode,
                                               count: matches.filter { $0.text.caseInsensitiveCompare(m.text) == .orderedSame }.count,
                                               boxSize: CGSize(width: w, height: h),
                                               fontSize: effectiveFontSize(for: m.text, weight: HL.fontWeight(weight), design: HL.fontDesign(design),
                                                                            matchedFamily: mf, autoFont: autoFont, fitting: CGSize(width: w, height: h)),
                                               design: design, weight: weight,
                                               boxColor: box, textColor: txt,
                                               bgColor: (autoBg ? (bgColors.indices.contains(i) ? bgColors[i] : nil) : nil) ?? bg,
                                               opacity: opacity, matchedFont: mf, autoFont: autoFont)
                                    .allowsHitTesting(false)   // never steals hover from the match it describes
                                    .position(x: min(hoverPoint.x + 110, geo.size.width - 100),
                                              y: min(hoverPoint.y + 70, geo.size.height - 60))
                            }
                        }
                        .coordinateSpace(name: "preview")
                    })
                    .padding(12)
            }
            else if failed { Text("Can't open \(path)").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(minWidth: 400, minHeight: 400)
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbar {
            Text(scanning ? "Finding matches…" : (searchTerms(query, mode: searchMode).isEmpty ? "" : (show ? "\(matches.count) match(es)" : "overlay off")))
                .foregroundStyle(.secondary)
            Toggle("Overlay", isOn: $show)
                .toggleStyle(.switch).help("Show or hide the overlay (Cmd+Shift+O)")
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Picker("Show as", selection: $mode) {
                Text("Boxes").tag("box"); Text("Text").tag("text")
            }.pickerStyle(.segmented).disabled(!show)
            if mode == "text" {
                ColorPicker("Font", selection: txtBinding, supportsOpacity: false)
                // While Auto is on, show (read-only) whatever color is actually behind the
                // hovered match right now, instead of the unrelated stored fallback — so the
                // swatch never shows something different from what's on the image.
                let liveBg: Color = autoBg
                    ? ((hoverIndex.flatMap { bgColors.indices.contains($0) ? bgColors[$0] : nil }) ?? bg)
                    : bg
                ColorPicker("Background", selection: Binding<Color>(get: { liveBg }, set: { bgHex = $0.hexString }),
                             supportsOpacity: false).disabled(autoBg)
                    .help(autoBg ? "Showing the color currently sampled from the image (hover a match). Turn off \"Auto\" to pick one yourself."
                                 : "Used behind every redrawn word")
                Toggle("Auto", isOn: $autoBg)
                    .help("Pick up the color immediately around each match and use it as its background")
                Toggle("Auto font", isOn: $autoFont)
                    .help("Redraw each match in whichever installed font (excluding system/SF fonts) best matches it, instead of the Font chosen in Settings")
            }
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
            bgColors = []
            matchedFonts = []
            let terms = searchTerms(query, mode: searchMode)
            guard image != nil, !terms.isEmpty else { return }
            scanning = true
            let p = path
            matches = await Task.detached(priority: .userInitiated) {
                (try? findMatches(at: URL(fileURLWithPath: p), terms: terms)) ?? []
            }.value
            let rects = matches.map(\.rect)
            bgColors = await Task.detached(priority: .userInitiated) {
                sampledBackgroundColors(at: p, rects: rects)
            }.value
            if autoFont { await detectFonts() }
            scanning = false
        }
        .onChange(of: autoFont) { on in
            if on && matchedFonts.isEmpty { Task { await detectFonts() } }
        }
    }

    /// Auto-matches each found match's text to the closest-looking installed font (see
    /// bestMatchingFont), excluding Apple's system/SF fonts. Skipped unless auto-font is on, or
    /// asked for explicitly, since scanning every installed family is real work — only worth
    /// paying for when the feature is actually in use.
    private func detectFonts() async {
        guard !matches.isEmpty else { return }
        let p = path
        let items = matches.map { (text: $0.text, rect: $0.rect) }
        let families = candidateFontFamilies()
        let bold = weight == "bold"
        matchedFonts = await Task.detached(priority: .userInitiated) {
            guard let px = imagePixelSize(at: p) else { return Array(repeating: nil, count: items.count) }
            return items.map {
                bestMatchingFont(for: $0.text, bold: bold,
                                  fitting: CGSize(width: $0.rect.width * px.width, height: $0.rect.height * px.height),
                                  from: families)
            }
        }.value
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
                Picker("", selection: $m.searchMode) {
                    Text("Phrase").tag(SearchMode.phrase)
                    Text("Any word").tag(SearchMode.words)
                }
                .pickerStyle(.segmented).frame(width: 150)
                .help("Phrase: match the whole search text together, in order. Any word: match each word separately, anywhere.")
                .onChange(of: m.searchMode) { _ in m.search() }
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
                    Button { openWindow(id: "preview", value: PreviewRequest(path: hit.path, query: m.query, mode: m.searchMode)) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("View full size")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openWindow(id: "preview", value: PreviewRequest(path: hit.path, query: m.query, mode: m.searchMode)) }
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
