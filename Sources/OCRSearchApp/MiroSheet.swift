import SwiftUI
import AppKit
import OCRSearchCore

struct MiroSheet: View {
    @ObservedObject var m: Model
    @Binding var isPresented: Bool
    /// "Create a new board" vs "add to an existing one" — previously both fields were always
    /// visible with the board-name one conditionally disabled, which left the user to infer the
    /// relationship between them.
    @State private var useExistingBoard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                MiroBadge(size: 28)
                Text("Export to Miro").font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Access token").font(.subheadline)
                    Spacer()
                    Link("Where do I get one?", destination: URL(string: "https://miro.com/app/settings/user-profile/apps")!)
                        .font(.caption)
                }
                SecureField("Miro access token", text: $m.token)
                Text("Needs the boards:read and boards:write scopes. Saved in your Keychain, not in the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("", selection: $useExistingBoard) {
                Text("Create a new board").tag(false)
                Text("Add to an existing board").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: useExistingBoard) { existing in if !existing { m.boardID = "" } }

            if useExistingBoard {
                TextField("Board ID", text: $m.boardID)
            } else {
                TextField("New board name", text: $m.boardName)
            }

            Text("\(plural(m.selection.count, "item")): images plus their OCR snippets as sticky notes.")
                .font(.caption).foregroundStyle(.secondary)

            if let err = m.exportError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if m.busy { ProgressView().controlSize(.small); Text("Exporting…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { isPresented = false }
                // Stays open while exporting, so progress and any failure land here rather than
                // in a status line behind the sheet; dismisses itself once a board link arrives.
                Button("Export") { m.exportSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.token.isEmpty || m.busy)
            }
        }
        .padding(20).frame(width: 480)
        .onChange(of: m.link) { link in if link != nil { isPresented = false } }
    }
}
