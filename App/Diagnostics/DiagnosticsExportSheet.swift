import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Preview-before-share for the diagnostic bundle (Bible Part 11 §12.4, §18). The user sees exactly
/// what would leave the machine, then copies or saves it explicitly. Nothing is shared automatically.
struct DiagnosticsExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Diagnostics").font(.headline)
            Text("This is exactly what will be saved. Secrets are redacted and only diagnostic fields are included — no file contents, environment values, command arguments, or terminal output.")
                .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .frame(minHeight: 240).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save…") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 560, height: 440)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "c2d-diagnostics-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).json"
        if panel.runModal() == .OK, let url = panel.url { model.saveDiagnostics(text, to: url) }
        dismiss()
    }
}
