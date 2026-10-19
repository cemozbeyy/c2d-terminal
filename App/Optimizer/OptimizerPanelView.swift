import C2DCore
import SwiftUI

struct OptimizerPanelView: View {
    @Bindable var optimizer: OptimizerController
    let workspace: WorkspaceController
    @State private var noteText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                usageLedger
                sources
                if let est = optimizer.payloadEstimate {
                    GroupBox("Prepared context") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(est.tokens) tokens · \(est.source.label)").font(.caption).bold()
                            Text(est.confidence).font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                            HStack {
                                Stepper("Budget \(optimizer.budgetTokens)", value: $optimizer.budgetTokens, in: 1000...200_000, step: 1000).font(.caption)
                                Button("Check budget") { optimizer.measureOnly() }.font(.caption)
                                Button("Optimize (deterministic)") { optimizer.optimize() }.font(.caption).disabled(!optimizer.entitlement.isPremium)
                                    .help(optimizer.entitlement.isPremium ? "Exact-duplicate removal and whitespace normalization only; nothing semantic." : "Premium capability; no billing provider is configured in this build.")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let verdict = optimizer.budgetVerdict { budget(verdict) }
                if let r = optimizer.result, let rep = optimizer.report { resultView(r, rep) }
                history
                if let err = optimizer.lastError {
                    HStack { Text(err).font(.caption).foregroundStyle(Theme.warning); Spacer(); Button("Dismiss") { optimizer.lastError = nil }.font(.caption) }
                }
            }
            .padding(10)
        }
        .task { await optimizer.loadLedger() }   // scan on panel open (OPEN_DECISIONS §4.4 proposal) and on "Rescan"
    }

    // MARK: Token Saver TS-1 — provider-reported usage

    private var usageLedger: some View {
        GroupBox("Provider-reported usage · Claude Code") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Read from Claude Code's local transcripts on this Mac. Only usage and metadata fields are read; nothing is stored, copied or uploaded.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if optimizer.ledgerLoading { ProgressView().controlSize(.small) }
                    Button("Rescan") { Task { await optimizer.loadLedger() } }.font(.caption).disabled(optimizer.ledgerLoading)
                }
                switch optimizer.ledger {
                case .none:
                    Text(optimizer.entitlementNoteForLedger).font(.caption).foregroundStyle(Theme.textSecondary)
                case .unavailable(let reason):
                    Label(reason, systemImage: "questionmark.circle").font(.caption).foregroundStyle(Theme.textSecondary)
                case .available(let l):
                    let t = l.total
                    Text("\(l.sessions.count) session(s) · \(t.total.formatted()) tokens — input \(t.inputTokens.formatted()) · output \(t.outputTokens.formatted()) · cache read \(t.cacheReadInputTokens.formatted()) · cache write \(t.cacheCreationInputTokens.formatted())")
                        .font(.caption).bold()
                    Text("\(l.source.label) · \(l.formatLabel)").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                    ForEach(l.sessions) { s in
                        HStack(spacing: 8) {
                            Text(s.lastTimestamp.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").frame(width: 120, alignment: .leading)
                            Text(s.models.joined(separator: ", ")).lineLimit(1).frame(width: 130, alignment: .leading).foregroundStyle(Theme.textSecondary)
                            Text("in \(s.usage.inputTokens.formatted()) · out \(s.usage.outputTokens.formatted()) · cache r \(s.usage.cacheReadInputTokens.formatted()) · w \(s.usage.cacheCreationInputTokens.formatted())").lineLimit(1)
                            Spacer()
                            Text(s.usage.total.formatted()).bold()
                            Text("\(s.messageCount) msg").foregroundStyle(Theme.textMuted)
                        }
                        .font(Theme.Typography.monoMicro)
                        .help("session \(s.id) · \(s.fileURL.lastPathComponent)\(s.gitBranch.map { " · branch \($0)" } ?? "")")
                    }
                    ForEach(l.unavailable, id: \.self) { u in
                        Label("\(u.id.prefix(8))… unavailable: \(u.reason)", systemImage: "exclamationmark.triangle").font(Theme.Typography.micro).foregroundStyle(Theme.warning)
                    }
                    Text("Top-level session files only; sub-agent transcripts in subfolders are not counted yet. \(l.skippedRecords) non-assistant record(s) skipped unread\(l.inProgressLines > 0 ? ", \(l.inProgressLines) line(s) still being written" : "").")
                        .font(Theme.Typography.micro).foregroundStyle(Theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text("Token Optimizer").font(.headline)
                Spacer()
                Text(entitlementLabel).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background((optimizer.entitlement.isPremium ? Theme.accent : Theme.textMuted).opacity(0.2), in: Capsule())
            }
            Text("Prepared-context numbers are heuristic estimates. Usage figures below marked provider-reported are read from Claude Code's own local transcripts; the two are never added together and nothing is shown as saved.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var entitlementLabel: String {
        switch optimizer.entitlement.state {
        case .premium: "Premium (\(optimizer.entitlement.source))"
        case .free: "Free"
        case .unknown: "Free · entitlement unknown"
        }
    }

    private var sources: some View {
        GroupBox("Context sources (explicit only)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Add open editor files") { optimizer.addOpenEditorFiles(workspace) }.font(.caption)
                    Button("Add unstaged Git diff") { Task { await optimizer.addGitDiff(workspace.git) } }.font(.caption).disabled(!workspace.git.isAvailable)
                    if let t = workspace.tasks.selected { Button("Add task “\(t.title.prefix(18))…”") { optimizer.addTask(t) }.font(.caption) }
                    Spacer()
                    Button("Clear") { optimizer.clear() }.font(.caption).disabled(optimizer.items.isEmpty)
                }
                HStack {
                    TextField("Add a note or instruction", text: $noteText).textFieldStyle(.roundedBorder).font(.caption)
                    Button("Add") { optimizer.add(ContextItem(kind: .note, content: noteText)); noteText = "" }.font(.caption).disabled(noteText.isEmpty)
                }
                ForEach(optimizer.items) { item in
                    HStack {
                        Text(item.kind.rawValue).font(Theme.Typography.micro).padding(.horizontal, 4).background(Theme.textMuted.opacity(0.15), in: Capsule())
                        Text(item.path.map { ($0 as NSString).lastPathComponent } ?? String(item.content.prefix(60).replacingOccurrences(of: "\n", with: " "))).font(.caption).lineLimit(1)
                        if item.mandatory { Text("mandatory").font(Theme.Typography.micro).foregroundStyle(Theme.warning) }
                        Spacer()
                        Text("~\(TokenEstimator.estimate(item.content).tokens)").font(Theme.Typography.monoMicro).foregroundStyle(Theme.textSecondary)
                        Button { optimizer.remove(item.id) } label: { Image(systemName: "xmark").font(Theme.Typography.micro) }.buttonStyle(.plain)
                    }
                }
                if optimizer.items.isEmpty { Text("Nothing selected. The optimizer never collects context on its own.").font(.caption).foregroundStyle(Theme.textSecondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func budget(_ v: BudgetVerdict) -> some View {
        switch v {
        case .fits(let tokens, let budget):
            Label("Fits: ~\(tokens) of \(budget) tokens (estimate)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.success)
        case .exceedsBy(let tokens, let candidates, let mandatory):
            VStack(alignment: .leading, spacing: 2) {
                Label("Exceeds budget by ~\(tokens) tokens; mandatory items need \(mandatory). Nothing was removed — choose what to drop:", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                ForEach(candidates, id: \.self) { id in
                    if let item = optimizer.items.first(where: { $0.id == id }) {
                        HStack { Text(item.path.map { ($0 as NSString).lastPathComponent } ?? item.kind.rawValue).font(.caption); Button("Drop") { optimizer.remove(id) }.font(.caption) }
                    }
                }
            }
        }
    }

    private func resultView(_ r: OptimizationResult, _ rep: SavingsReport) -> some View {
        GroupBox("Result") {
            VStack(alignment: .leading, spacing: 4) {
                Text(rep.label).font(.caption).bold()
                Text("Before ~\(r.before.tokens) · after ~\(r.after.tokens) · mandatory items kept: \(r.preservedMandatory)").font(.caption)
                if r.actions.isEmpty {
                    Text("No deterministic reduction applied (no exact duplicates or whitespace waste).").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(r.actions, id: \.self) { a in
                    Text("• \(a.kind.rawValue): \(a.reason) (\(a.tokensBefore) → \(a.tokensAfter)); original retained").font(Theme.Typography.metadata)
                }
                Button("Record this measurement") { Task { await optimizer.recordResult() } }.font(.caption).disabled(!optimizer.isStoreAvailable)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var history: some View {
        GroupBox("History (this project)") {
            VStack(alignment: .leading, spacing: 4) {
                if optimizer.totals.isEmpty { Text("No recorded measurements.").font(.caption).foregroundStyle(Theme.textSecondary) }
                ForEach(optimizer.totals.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
                    if let t = optimizer.totals[source] {
                        Text("\(source.label): \(t.count) run(s), baseline ~\(t.baseline) → ~\(t.optimized)").font(.caption)
                    }
                }
                ForEach(optimizer.history.prefix(10)) { rec in
                    Text("\(rec.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(rec.sourceDescription) · \(rec.baselineTokens)→\(rec.optimizedTokens) · \(rec.measurementSource.label)")
                        .font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
