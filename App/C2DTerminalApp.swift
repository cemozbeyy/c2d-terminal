import SwiftUI
import C2DCore

@main
struct C2DTerminalApp: App {
    init() {
        Log.app.info("launch: \(DiagnosticsReport.current().summary, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup("C2D Terminal") {
            FoundationView()
        }
    }
}

/// Temporary foundation surface. It states plainly what does not exist yet;
/// it must not be mistaken for a terminal (Bible Part 4 §2.1, §17).
struct FoundationView: View {
    private let report = DiagnosticsReport.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("C2D Terminal").font(.title)
            Text("Foundation build. No terminal engine, PTY, editor, Git, agent or optimizer functionality is implemented yet.")
                .foregroundStyle(.secondary)
            Text(report.summary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 240, alignment: .topLeading)
    }
}
