import C2DCore
import SwiftUI

struct OptimizerPanelView: View {
    @Bindable var optimizer: OptimizerController
    let workspace: WorkspaceController
    @State private var noteText = ""
    @State private var consentDirectory: URL?   // set only by "Run experiment…"; the sheet asks again every time

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                TokenSaverMetricsView(summary: optimizer.summary, usageNote: optimizer.usageNote)
                    .padding(Theme.space3)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
                sources
                if let est = optimizer.payloadEstimate {
                    GroupBox("Prepared context") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(est.tokens) tokens · \(est.source.label)").font(.caption).bold()
                            Text(est.confidence).font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                            HStack {
                                Stepper("Budget \(optimizer.budgetTokens)", value: $optimizer.budgetTokens, in: 1000...200_000, step: 1000).font(.caption)
                                Button("Check budget") { optimizer.measureOnly() }.font(.caption)
                                Toggle("Fold long output (lossy, marked)", isOn: $optimizer.lossyOutputFolding).font(.caption).toggleStyle(.checkbox)
                                    .help("Also folds lines that differ only in numbers, cuts long compiler invocations and trims the middle of very long output. Every line recognised as an error, warning or file:line (English tool output) is kept; each cut leaves a [c2d: …] marker; the original stays here.")
                                Button("Optimize (deterministic)") { optimizer.optimize() }.font(.caption)
                                    .help("Deterministic only: terminal output condensed (lines recognised as errors/warnings/file:line always kept), exact duplicates removed, whitespace normalized. Nothing semantic.")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let verdict = optimizer.budgetVerdict { budget(verdict) }
                if !optimizer.items.isEmpty {
                    GroupBox("Hand-off") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button("Copy as Markdown") { optimizer.copyHandOff() }.font(.caption)
                                Button("Write .c2d/context.md") { optimizer.writeHandOffFile() }.font(.caption)
                                    .help("Replaces the previous .c2d/context.md C2D wrote; .c2d/ is git-ignored by its own .gitignore.")
                            }
                            Text(optimizer.result == nil ? "Hands over the items as selected." : "Hands over the optimized items (originals stay in the result list).")
                                .font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                            if let note = optimizer.handOffNote { Text(note).font(.caption).foregroundStyle(Theme.textSecondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let r = optimizer.result, let rep = optimizer.report { resultView(r, rep) }
                activity
                usageLedger
                experiment
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
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                switch optimizer.ledger {
                case .none:
                    Text(optimizer.usageNote).font(.caption).foregroundStyle(Theme.textSecondary)
                case .unavailable(let reason):
                    Label(reason, systemImage: "questionmark.circle").font(.caption).foregroundStyle(Theme.textSecondary)
                case .available(let l):
                    Text("\(l.source.label) · \(l.formatLabel)").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                    ForEach(l.sessions) { s in
                        HStack(spacing: 8) {
                            Text(s.lastTimestamp.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").frame(width: 120, alignment: .leading)
                            Text(s.models.joined(separator: ", ")).lineLimit(1).frame(width: 130, alignment: .leading).foregroundStyle(Theme.textSecondary)
                            Text("in \(s.usage.inputTokens.formatted()) · out \(s.usage.outputTokens.formatted()) · cache r \(s.usage.cacheReadInputTokens.formatted()) · w \(s.usage.cacheCreationInputTokens.formatted())").lineLimit(1)
                            Text("context \(s.lastContextTokens.formatted()) · peak \(s.peakContextTokens.formatted())").lineLimit(1).foregroundStyle(Theme.textSecondary)
                                .help("Input the newest / largest request sent (uncached + cache read + cache write). Every later reply in this session re-reads at least this much.")
                            Spacer()
                            attributionChip(optimizer.attribution[s.id] ?? .unmatched)
                            Text(s.usage.total.formatted()).bold()
                            Text("\(s.messageCount) msg").foregroundStyle(Theme.textMuted)
                        }
                        .font(Theme.Typography.monoMicro)
                        .help("session \(s.id) · \(s.fileURL.lastPathComponent)\(s.gitBranch.map { " · branch \($0)" } ?? "")")
                    }
                    ForEach(l.unavailable, id: \.self) { u in
                        Label("\(u.id.prefix(8))… unavailable: \(u.reason)", systemImage: "exclamationmark.triangle").font(Theme.Typography.micro).foregroundStyle(Theme.warning)
                    }
                    if !optimizer.launchesWithoutTranscript.isEmpty {
                        Label("\(optimizer.launchesWithoutTranscript.count) C2D agent launch(es) have no transcript yet (never replied, or the file is not visible yet) — rescan later.", systemImage: "clock")
                            .font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                    }
                    Text("Usage, not savings. Only usage and metadata fields of Claude Code's local transcripts are read; nothing is stored or uploaded. Sessions link to C2D launches only by the session id C2D passed. Top-level session files only (sub-agents not counted); \(l.skippedRecords) non-assistant record(s) skipped unread\(l.inProgressLines > 0 ? ", \(l.inProgressLines) line(s) still being written" : "").")
                        .font(Theme.Typography.micro).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack {
                Text("Usage by session · provider-reported").font(.caption).fontWeight(.semibold)
                Spacer()
                if optimizer.ledgerLoading { ProgressView().controlSize(.small) }
                Button("Rescan") { Task { await optimizer.loadLedger() } }.font(.caption).disabled(optimizer.ledgerLoading)
            }
        }
    }

    // MARK: Paired experiment (TSD-03)

    private var experiment: some View {
        GroupBox("Paired experiment · exploratory") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Same fixture task, once per hand-off condition (raw / condensed lossless / condensed lossy), each a new `claude -p` session. The tasks are small single-answer fixtures: results are exploratory and say nothing about long-session productivity.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if !optimizer.experimentAvailable {
                    Label("The experiment runner is not bundled in this build.", systemImage: "questionmark.circle").font(.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    experimentModelRow
                    HStack {
                        Stepper("Repetitions \(optimizer.experimentReps)", value: $optimizer.experimentReps, in: 3...9, step: 3).font(.caption).fixedSize() .help("Multiples of the 3 conditions, so every condition runs first, second and third equally often per task.")
                        Button("Preview plan (no model calls)") { Task { await optimizer.previewExperiment() } }.font(.caption)
                            .disabled(optimizer.experimentModel == nil || optimizer.experimentPreviewing)
                        if optimizer.experimentPreviewing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Run experiment…") { consentDirectory = optimizer.nextExperimentDirectory() }.font(.caption)
                            .disabled(optimizer.experimentPlan == nil || optimizer.experimentModel == nil)
                            .help("Asks for confirmation, then opens the runner in a terminal pane. It calls the model only after you type SPEND there.")
                    }
                    if let plan = optimizer.experimentPlan {
                        Text("Plan: \(plan.runs) runs = \(plan.tasks.count) tasks × \(plan.arms.count) conditions × \(plan.reps) repetitions, up to \(plan.max_retries) retry each, order seed \(plan.seed). Conditions: \(plan.arms.joined(separator: ", ")).")
                            .font(.caption).bold()
                        if plan.controlRows > 0 {
                            Text("\(plan.controlRows) run(s) hand over a context identical to another condition of the same task: A/A controls, not treatments.")
                                .font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                        }
                        Text("Preview only: no model was called.").font(Theme.Typography.micro).foregroundStyle(Theme.textMuted)
                    }
                    if optimizer.experimentRunDirectory != nil { experimentResults }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { consentDirectory != nil }, set: { if !$0 { consentDirectory = nil } })) {
            if let dir = consentDirectory, let plan = optimizer.experimentPlan, let model = optimizer.experimentModel {
                experimentConsent(plan: plan, model: model, directory: dir)
            }
        }
    }

    @ViewBuilder private var experimentModelRow: some View {
        switch optimizer.experimentModelSource {
        case .verified(let model, _, let sid, let cli):
            Label("Model: \(model) · Claude Code \(cli) · verified from the running session's transcript (\(sid.prefix(8))…)", systemImage: "checkmark.seal")
                .font(.caption).help(ExperimentModelSource.sourceLabel)
            experimentModelNote(model)
        case .needsChoice(let observed, _, let sid, _):
            VStack(alignment: .leading, spacing: 2) {
                Picker("Model", selection: $optimizer.experimentChosenModel) {
                    Text("Choose…").tag(String?.none)
                    ForEach(observed, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .font(.caption).fixedSize()
                Text("The running session's transcript (\(sid.prefix(8))…) shows \(observed.count) models. C2D cannot tell which one is the session's main model, so it does not pick; choose the one to request.")
                    .font(Theme.Typography.micro).foregroundStyle(Theme.warning)
                if let m = optimizer.experimentModel { experimentModelNote(m) }
            }
        case .unknown(let reason):
            Label("Model unknown: \(reason) The experiment needs a model read from a running C2D Claude Code session; it is not guessed. Launch one (it shows its model after the first reply), then Rescan.", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func experimentModelNote(_ model: String) -> some View {
        Text("Every run requests `--model \(model)`; the running session itself is not touched. Whether a run used that model is read back from its own transcript afterwards — mismatches are shown, never hidden.")
            .font(Theme.Typography.micro).foregroundStyle(Theme.textMuted)
    }

    private func experimentConsent(plan: ExperimentPlan, model: String, directory: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Run a real experiment?", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(Theme.warning)
            Text("This makes real model calls through Claude Code with your own account. It may use your subscription quota or incur API charges.")
            VStack(alignment: .leading, spacing: 3) {
                Text("Provider: Claude Code (\(workspace.claudePath ?? "claude"))")
                Text("Model: \(model) (requested for every run)")
                Text("Runs: \(plan.runs) (\(plan.tasks.count) tasks × \(plan.arms.count) conditions × \(plan.reps) repetitions), each with up to \(plan.max_retries) retry — up to \(plan.runs * (plan.max_retries + 1)) `claude -p` calls, each of which can make several model requests")
                Text("Results: \(directory.path) (git-ignored)")
            }
            .font(.system(.caption, design: .monospaced))
            Text("Next, a terminal pane opens with the runner. It prints the plan and runs nothing until you type SPEND there yourself. Closing that pane stops the run; finished rows are kept.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { consentDirectory = nil }.keyboardShortcut(.cancelAction)
                Button("Open runner in a terminal") {
                    optimizer.startExperiment(in: workspace, outputDirectory: directory)
                    consentDirectory = nil
                }
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private var experimentResults: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Last run: \(optimizer.experimentRunDirectory?.path ?? "")").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Load results") { optimizer.loadExperimentResults() }.font(.caption)
            }
            if let r = optimizer.experimentResults {
                let planned = optimizer.experimentPlan?.runs
                let reported = r.rows.filter(\.isProviderReported).count
                Text("\(r.rows.count)\(planned.map { " of \($0)" } ?? "") rows · \(r.rows.filter(\.success).count) passed · \(r.rows.filter { !$0.error.isEmpty }.count) failed or timed out · usage provider-reported for \(reported), unavailable for \(r.rows.count - reported)\(r.undecodable > 0 ? " · \(r.undecodable) unreadable line(s)" : "")")
                    .font(.caption).bold()
                if let planned, r.rows.count < planned { Label("Incomplete: \(planned - r.rows.count) planned run(s) have no row (not started yet, still running, or stopped).", systemImage: "clock").font(Theme.Typography.micro).foregroundStyle(Theme.warning) }
                if !r.rows.isEmpty && !ExperimentResultRow.sameModelComparison(r.rows) {
                    Label("Not a same-model comparison: some runs did not use the requested model, or runs differ in the models their transcripts show. Do not compare conditions from this run.", systemImage: "exclamationmark.triangle")
                        .font(Theme.Typography.micro).foregroundStyle(Theme.warning)
                }
                ForEach(r.rows.sorted { $0.order < $1.order }, id: \.order) { row in
                    HStack(spacing: 8) {
                        Text("#\(row.order)").frame(width: 28, alignment: .leading).foregroundStyle(Theme.textMuted)
                        Text("\(row.task) · \(row.arm) · rep \(row.rep)").lineLimit(1).frame(width: 260, alignment: .leading)
                        Text(row.success ? "pass" : "fail").foregroundStyle(row.success ? Theme.success : Theme.warning)
                        Text("retries \(row.retries)")
                        if row.isProviderReported, let i = row.input_tokens, let o = row.output_tokens, let cr = row.cache_read_input_tokens, let cw = row.cache_creation_input_tokens {
                            Text("in \(i) · out \(o) · cache r \(cr) · w \(cw)").lineLimit(1)
                        } else {
                            Text("usage unavailable").foregroundStyle(Theme.textMuted)
                        }
                        Text("model \(row.model_match ?? "unavailable")").foregroundStyle(row.model_match == "exact" ? Theme.textSecondary : Theme.warning)
                            .help(row.models_actual.map { "Models in this run's transcript: \($0)" } ?? "No model read back")
                        Spacer()
                    }
                    .font(Theme.Typography.monoMicro)
                    .help(row.error.isEmpty ? row.usage_source : row.error)
                }
                Text("Token numbers are provider-reported from each run's own transcript; nothing here is a heuristic estimate, and no difference is shown as saved.")
                    .font(Theme.Typography.micro).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Theme.accent)
                Text("Token Saver").font(.headline)
                Text(optimizer.isEnabled ? "On" : "Off").font(Theme.Typography.badge).fontWeight(.medium)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(optimizer.isEnabled ? Theme.success : Theme.textMuted)
                    .background((optimizer.isEnabled ? Theme.success : Theme.textMuted).opacity(0.15), in: Capsule())
                Spacer()
                Text(entitlementLabel).font(Theme.Typography.badge).foregroundStyle(Theme.textSecondary)
            }
            Text("Saved, estimated and used tokens are three different numbers and are never added together.")
                .font(Theme.Typography.detail).foregroundStyle(Theme.textMuted)
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
                    Menu("Add terminal output") {
                        ForEach(workspace.terminals.values.sorted { $0.title < $1.title }, id: \.panelID) { t in
                            Button(t.title) { optimizer.addTerminalOutput(t) }
                        }
                    }
                    .font(.caption).fixedSize().disabled(workspace.terminals.isEmpty)
                    .help("Adds the terminal's scrollback as shown. Optimize condenses it: repeats and progress folded, recognised error/warning/file:line lines kept, original retained.")
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

    @ViewBuilder private func attributionChip(_ a: SessionAttribution) -> some View {
        switch a {
        case .linked(_, let taskID, let summary, let lifecycle):
            let title = (summary?.split(separator: "\n").first).map(String.init) ?? ""
            Text(taskID != nil ? "task: \(title.prefix(24))" : "C2D session" + (lifecycle == .failed ? " · failed" : ""))
                .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.accent.opacity(0.18), in: Capsule()).foregroundStyle(Theme.accent)
                .help(taskID.map { "Linked to C2D task \($0): \(summary ?? "")" } ?? "Launched from C2D without a task")
        case .unmatched:
            Text("unmatched").padding(.horizontal, 5).padding(.vertical, 1).background(Theme.textMuted.opacity(0.15), in: Capsule()).foregroundStyle(Theme.textMuted)
                .help("No C2D launch carries this session id: started outside C2D, or before C2D passed session ids.")
        case .ambiguous(let ids):
            Text("ambiguous").padding(.horizontal, 5).padding(.vertical, 1).background(Theme.warning.opacity(0.18), in: Capsule()).foregroundStyle(Theme.warning)
                .help("\(ids.count) C2D records claim this session id; not attributed.")
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
                let before = ContextPayload(items: optimizer.items).byteCount, after = r.payload.byteCount
                Text("Measured \(TokenSaverFormat.sizes(before, after)) · \(r.lossyStepsApplied ? "lossy (marked)" : "lossless")"
                     + (after < before ? (optimizer.isStoreAvailable ? " · recorded as prepared" : " · not recorded: history unavailable") : " · nothing reduced, not recorded"))
                    .font(Theme.Typography.metadata).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activity: some View {
        let events = optimizer.history.filter { $0.stage != nil && $0.originalBytes != nil }
        let legacy = optimizer.history.count - events.count
        return GroupBox("Optimization activity") {
            VStack(alignment: .leading, spacing: 3) {
                if events.isEmpty {
                    Text("No optimization recorded yet. Turning Token Saver on records nothing by itself; only Optimize and hand-offs do.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(events.prefix(12)) { e in
                    HStack(spacing: 8) {
                        Text(e.createdAt.formatted(date: .abbreviated, time: .shortened)).frame(width: 120, alignment: .leading).foregroundStyle(Theme.textSecondary)
                        Text(e.stage?.label ?? "").frame(width: 150, alignment: .leading)
                        Text(e.mode?.rawValue ?? "").frame(width: 56, alignment: .leading).foregroundStyle(e.mode == .lossy ? Theme.warning : Theme.textSecondary)
                        if let b = e.originalBytes, let a = e.resultBytes {
                            Text("\(TokenSaverFormat.sizes(b, a)) (\(TokenSaverFormat.reduction(b > 0 ? Double(b - a) / Double(b) * 100 : nil)))")
                        }
                        Text("~\((e.baselineTokens - e.optimizedTokens).formatted()) tokens est.").foregroundStyle(Theme.textMuted)
                        Spacer()
                        Text(e.sourceDescription).lineLimit(1).foregroundStyle(Theme.textMuted)
                    }
                    .font(Theme.Typography.monoMicro)
                    .help("Project \(e.projectPath) · \(e.actionsSummary). Sizes measured in bytes; tokens are a heuristic estimate. A hand-off is not confirmed as read by any agent.")
                }
                if legacy > 0 {
                    Text("\(legacy) earlier manual measurement(s) without byte sizes are kept but not counted.").font(Theme.Typography.micro).foregroundStyle(Theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
