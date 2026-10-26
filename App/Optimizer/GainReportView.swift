import C2DCore
import SwiftUI

/// The `c2d gain` report in the app: the unified live report (RTK-powered + C2D fold) and, on a separate tab, the
/// offline replay. The two are never shown as one number. Same data and labels as `c2d-token-helper gain`.
struct GainReportView: View {
    @Environment(\.dismiss) private var dismiss
    let optimizer: OptimizerController
    @State private var tab: Int
    @State private var global = false
    /// false only for the Debug snapshot check: `ImageRenderer` does not draw scroll view content.
    private let scrolls: Bool

    init(optimizer: OptimizerController, tab: Int = 0, global: Bool = false, scrolls: Bool = true) {
        self.optimizer = optimizer
        _tab = State(initialValue: tab)
        _global = State(initialValue: global)
        self.scrolls = scrolls
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Token Saver report").font(Theme.Typography.title2).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                Spacer()
                Picker("", selection: $tab) { Text("Live").tag(0); Text("Replay (offline)").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().clickCursor()
                Button("Done") { dismiss() }.buttonStyle(.clickDefault).keyboardShortcut(.defaultAction)
            }
            Divider()
            if scrolls { ScrollView { content } } else { content; Spacer(minLength: 0) }
        }
        .padding(Theme.space4)
        .frame(width: 640, height: scrolls ? 520 : 760)
        .background(Theme.panel)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            if tab == 0 { live } else { replay }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Live

    @ViewBuilder private var live: some View {
        Picker("", selection: $global) { Text("This project").tag(false); Text("All projects").tag(true) }
            .pickerStyle(.segmented).labelsHidden().fixedSize().clickCursor()
        if global && optimizer.globalGain == nil {
            Text("Reading all projects…").font(Theme.Typography.detail).foregroundStyle(Theme.textMuted)
                .task { await optimizer.loadGlobalGain() }
        } else if let g = global ? optimizer.globalGain : optimizer.gain {
            Text("Live, \(global ? "all projects" : (optimizer.projectPath as NSString).abbreviatingWithTildeInPath). Estimated tokens (bytes/4) from each engine's own count; not provider-reported.")
                .font(Theme.Typography.detail).foregroundStyle(Theme.textSecondary)
            summary([
                ("Est. tokens saved", TokenSaverFormat.count(g.estimatedTokensSaved) + (g.savingsPercent.map { String(format: "  (%.1f %% of filtered output)", $0) } ?? ""),
                 "estimated, bytes/4, not provider-reported"),
                ("RTK-powered", rtkValue(g), rtkDetail(g)),
                ("C2D fold", TokenSaverFormat.count(g.c2dSavedTokens),
                 "\(g.c2d.total.transformed) transformed of \(g.c2d.total.commands) seen · \(GainReport.bytes(g.c2d.total.originalBytes)) → \(GainReport.bytes(g.c2d.total.resultBytes)) measured · "
                 + (g.c2d.total.timedEvents > 0 ? "helper \(g.c2d.total.helperMilliseconds / g.c2d.total.timedEvents) ms avg · " : "") + "emitted, delivery to the model not proven"),
                ("Provider-verified", "Not measured", "Needs a controlled comparison of provider-reported usage; no figure is claimed."),
                ("C2D fold hook", foldValue, foldDetail),
            ])
            table(header: ["Command", "Count", "Engine", "Saved (est.)", "Saved %", "RTK ms", "C2D ms"],
                  rows: g.byFamily.prefix(15).map { r in
                      [r.family, "\(r.commands)", r.engines, TokenSaverFormat.count(r.savedTokens), GainReport.pct(r.savingsPercent),
                       r.rtkAverageMilliseconds.map(String.init) ?? "—", r.c2dAverageMilliseconds.map(String.init) ?? "—"]
                  }, emptyText: "No filtered commands yet.", textColumn: 2)
            Text("RTK ms: RTK's recorded run time per command (command + filter). C2D ms: the C2D helper's own time per Bash result.")
                .font(Theme.Typography.metadata).foregroundStyle(Theme.textMuted)
        } else {
            Text(optimizer.usageNote).font(Theme.Typography.detail).foregroundStyle(Theme.textMuted)
        }
    }

    private func rtkValue(_ g: UnifiedGain) -> String {
        g.rtk.ledger.map { "\(TokenSaverFormat.count(g.rtkSavedTokens))  ·  \($0.total.commands) commands" } ?? "Not included"
    }

    private func rtkDetail(_ g: UnifiedGain) -> String {
        switch g.rtk {
        case .available(let l):
            let span = [l.firstDay, l.lastDay].compactMap { $0 }.joined(separator: " … ")
            return "RTK's own count of the commands it filtered \(g.projectPath == nil ? "in every directory" : "in this project") (any agent\(span.isEmpty ? "" : ", \(span)")); read-only from RTK's history, never changed."
        case .unavailable(let reason): return reason + " Nothing is estimated in its place."
        }
    }

    private var foldValue: String { optimizer.foldDecision.hook == nil ? "Off" : "On (Debug)" }
    private var foldDetail: String {
        switch optimizer.foldDecision {
        case .on: "New Claude launches from C2D carry the byte-exact fold; events land in the ledger above."
        case .off(let reason): reason
        }
    }

    // MARK: Replay

    @ViewBuilder private var replay: some View {
        Text("Offline replay: what the byte-exact fold would have done to this project's past Bash results, by the hook's own skip rules. Nothing here ran in a session, and it is never added to Live.")
            .font(Theme.Typography.detail).foregroundStyle(Theme.textSecondary)
        if let r = optimizer.replay {
            let skips = GainEvent.SkipReason.allCases.compactMap { k in r.skips[k].map { "\(k.rawValue) \($0)" } }.joined(separator: ", ")
            summary([
                ("Commands", "\(r.total.commands)", "\(r.total.transformed) would be transformed" + (skips.isEmpty ? "" : "; skipped: \(skips)")),
                ("Saved (bytes)", "\(GainReport.bytes(r.total.savedBytes))  ·  \(GainReport.pct(r.shareOfAllStdout))",
                 "Share of all stdout seen (measured). Over transformed commands only: \(GainReport.pct(r.total.savingsPercent))."),
                ("Est. tokens", TokenSaverFormat.count(r.total.estimatedTokensSaved), GainReport.tokenLabel),
            ])
            table(header: ["Command", "Count", "Transformed", "Saved", "Saved %", "Est. tokens"],
                  rows: r.byFamily.prefix(15).map { x in
                      [x.family, "\(x.commands)", "\(x.transformed)", GainReport.bytes(x.savedBytes), GainReport.pct(x.savingsPercent), TokenSaverFormat.count(x.estimatedTokensSaved)]
                  }, emptyText: "No Bash results in this project's transcripts.")
        } else {
            HStack {
                if optimizer.replayLoading { ProgressView().controlSize(.small); Text("Replaying transcripts…").foregroundStyle(Theme.textSecondary) }
                else { Text("Not run yet.").foregroundStyle(Theme.textSecondary) }
            }
            .font(Theme.Typography.detail)
            .task { await optimizer.loadReplay() }
        }
    }

    // MARK: Pieces

    private func summary(_ items: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            ForEach(items, id: \.0) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.0).font(Theme.Typography.body).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1).font(Theme.Typography.body).fontWeight(.semibold).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                        Text(item.2).font(Theme.Typography.metadata).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Column 0 (and `textColumn`) is text and left-aligned; the rest are numbers, right-aligned.
    private func table(header: [String], rows: [[String]], emptyText: String, textColumn: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By command").font(Theme.Typography.body).fontWeight(.semibold).foregroundStyle(Theme.textPrimary).padding(.top, Theme.space2)
            if rows.isEmpty {
                Text(emptyText).font(Theme.Typography.detail).foregroundStyle(Theme.textMuted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { ForEach(header, id: \.self) { Text($0).font(Theme.Typography.metadata).foregroundStyle(Theme.textMuted) } }
                    Divider()
                    ForEach(rows.indices, id: \.self) { i in
                        GridRow {
                            ForEach(rows[i].indices, id: \.self) { j in
                                Text(rows[i][j]).font(j == 0 ? Theme.Typography.monoMetadata : Theme.Typography.metadata)
                                    .foregroundStyle(Theme.textPrimary).gridColumnAlignment(j == 0 || j == textColumn ? .leading : .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}
