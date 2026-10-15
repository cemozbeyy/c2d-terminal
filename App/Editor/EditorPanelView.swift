import C2DCore
import SwiftUI

struct EditorPanelView: View {
    @Bindable var editor: EditorPanelController

    var body: some View {
        VStack(spacing: 0) {
            if editor.tabs.isEmpty {
                VStack(spacing: 8) {
                    Text("No file open").foregroundStyle(.secondary)
                    Text("Select a file in the Explorer.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabStrip
                Divider()
                if let tab = editor.activeTab {
                    if tab.externalChange != .none || tab.lastError != nil { conflictBanner(tab) }
                    CodeEditorView(tab: tab).id(tab.id)
                    statusBar(tab)
                }
            }
            if let err = editor.lastError {
                HStack {
                    Text(err).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { editor.lastError = nil }.font(.caption)
                }
                .padding(6)
            }
        }
        .alert("Save changes to \(editor.closeRequest?.name ?? "")?", isPresented: Binding(get: { editor.closeRequest != nil }, set: { if !$0 { editor.closeRequest = nil } })) {
            Button("Save") { if let t = editor.closeRequest { editor.saveAndClose(t) } }
            Button("Discard Changes", role: .destructive) { if let t = editor.closeRequest { editor.close(t) } }
            Button("Cancel", role: .cancel) { editor.closeRequest = nil }
        } message: { Text("Unsaved edits will be lost if you discard.") }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(editor.tabs) { tab in
                    HStack(spacing: 4) {
                        Text(tab.name).lineLimit(1)
                        if tab.isDirty { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("unsaved") }
                        Button { editor.requestClose(tab) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(tab.id == editor.activeTabID ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture { editor.activate(tab) }
                    .help(tab.path)
                    .accessibilityLabel("\(tab.name)\(tab.isDirty ? ", unsaved" : "")\(tab.id == editor.activeTabID ? ", active" : "")")
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 26)
    }

    private func conflictBanner(_ tab: EditorTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            switch tab.externalChange {
            case .modified:
                Text(tab.isDirty ? "This file changed on disk and you have unsaved edits." : "This file changed on disk.").font(.caption)
                Spacer()
                Button("Reload") { tab.reloadFromDisk() }.font(.caption)
                if tab.isDirty { Button("Keep Mine") { tab.keepLocalOverExternal = true; tab.externalChange = .none }.font(.caption) }
            case .deleted:
                Text("This file was deleted or moved on disk. Saving will recreate it at the same path.").font(.caption)
                Spacer()
            case .none:
                Text(tab.lastError ?? "").font(.caption)
                Spacer()
                Button("Dismiss") { tab.lastError = nil }.font(.caption)
            }
        }
        .padding(6)
        .background(Color.orange.opacity(0.12))
    }

    private func statusBar(_ tab: EditorTab) -> some View {
        HStack(spacing: 12) {
            Text(tab.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("Ln \(tab.cursorLine), Col \(tab.cursorColumn)")
            Text(SyntaxHighlighter.language(for: tab.document.languageHint)?.name ?? "Plain Text")
            Text("UTF-8")
            Text(tab.document.lineEnding.rawValue)
            if tab.isDirty { Text("Unsaved").foregroundStyle(.orange) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8).frame(height: 20)
    }
}
