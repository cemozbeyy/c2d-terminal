import AppKit
import C2DCore
import Foundation
import Observation

/// Premium entitlement state kept apart from every core feature (Bible §3.13, Part 11 §21).
/// There is no billing provider yet (DEF-15): the state is `unknown` unless a developer override
/// says otherwise, and `unknown` is treated as free. Nothing here can disable the terminal.
struct Entitlement: Codable, Equatable {
    enum State: String, Codable { case unknown, free, premium }
    var state: State = .unknown
    var source: String = "no billing provider configured"
    var isPremium: Bool { state == .premium }
}

/// One optimizer run over context the user selected explicitly (Bible Part 10 §6: never "all context").
@MainActor
@Observable
final class OptimizerController {
    let projectPath: String
    private(set) var items: [ContextItem] = []
    private(set) var result: OptimizationResult?
    private(set) var report: SavingsReport?
    private(set) var budgetVerdict: BudgetVerdict?
    private(set) var history: [OptimizationRecord] = []
    private(set) var eventTotals: [OptimizationStage: EventTotals] = [:]
    var budgetTokens = 8000
    /// Off by default: only lossless output steps (escapes, counted repeats, file grouping). On adds the marked,
    /// lossy steps — similar-line folding, long-invocation elision, middle truncation — never touching diagnostics.
    var lossyOutputFolding = false
    var lastError: String?

    // Token Saver TS-1: provider-reported usage read from Claude Code's local transcripts (read-only, on demand, nothing stored).
    private(set) var ledger: TranscriptLedgerResult?
    private(set) var ledgerLoading = false
    private(set) var ledgerScannedAt: Date?
    // TS-2: transcript session id → attribution, recomputed on every scan from the agent registry (pure, deterministic).
    private(set) var attribution: [String: SessionAttribution] = [:]
    private(set) var launchesWithoutTranscript: [AgentSessionRecord] = []

    @ObservationIgnored private let store: OptimizationStore?
    @ObservationIgnored private unowned let app: AppModel

    init(projectPath: String, store: OptimizationStore?, app: AppModel) {
        self.projectPath = projectPath
        self.store = store
        self.app = app
        Task { await loadHistory() }
    }

    var isStoreAvailable: Bool { store != nil }
    var isEnabled: Bool { app.optimizerEnabled }
    /// Why there is no usage figure right now.
    var usageNote: String {
        if !app.optimizerEnabled { return "Token Saver is off; transcripts are not read." }
        if ledgerLoading { return "Reading Claude Code transcripts…" }
        if case .unavailable(let reason)? = ledger { return reason }
        return "Not read yet."
    }

    /// Scans this project's transcript folder off the main actor (ADR-022). A no-op while the Token
    /// Optimizer switch is off (Addendum A.6.7: the whole surface can be switched off).
    func loadLedger() async {
        guard app.optimizerEnabled else { ledger = nil; return }
        guard !ledgerLoading else { return }
        ledgerLoading = true
        defer { ledgerLoading = false }
        let path = projectPath
        ledger = await Task.detached(priority: .userInitiated) { ClaudeTranscriptReader.read(projectPath: path) }.value
        ledgerScannedAt = Date()
        let sessions: [TranscriptSession] = { if case .available(let l)? = ledger { return l.sessions }; return [] }()
        let records = app.agentSessions.records(forProject: projectPath)
        attribution = SessionAttributor.attribute(sessions: sessions, agentRecords: records)
        launchesWithoutTranscript = SessionAttributor.launchesWithoutTranscript(sessions: sessions, agentRecords: records)
    }
    var entitlement: Entitlement { app.entitlement }

    /// What the free tier always gets: a labeled estimate of the prepared context (Part 10 §21).
    var payloadEstimate: TokenEstimate? { items.isEmpty ? nil : ContextPayload(items: items).estimate }

    // MARK: Building the payload from explicit sources

    func clear() { items = []; result = nil; report = nil; budgetVerdict = nil }

    func add(_ item: ContextItem) { items.append(item); result = nil; report = nil; budgetVerdict = nil }

    func remove(_ id: String) { items.removeAll { $0.id == id }; result = nil; report = nil; budgetVerdict = nil }

    func addOpenEditorFiles(_ workspace: WorkspaceController) {
        for e in workspace.editors.values { for tab in e.tabs { add(ContextItem(kind: .file, path: tab.path, content: tab.text)) } }
    }

    func addTask(_ task: TaskRecord) {
        var text = task.title
        if !task.details.isEmpty { text += "\n\n" + task.details }
        if let ac = task.acceptanceCriteria, !ac.isEmpty { text += "\n\nAcceptance criteria:\n" + ac }
        add(ContextItem(kind: .instructions, content: text, mandatory: true))
    }

    /// TS-4 source: the terminal's text as rendered (escapes already interpreted by the emulator) — the user's
    /// selection when there is one, else scrollback + screen. The user picks the terminal; nothing is collected on its own.
    func addTerminalOutput(_ terminal: TerminalPanelController) {
        guard let view = terminal.hostedView else { lastError = "That terminal has no visible output yet."; return }
        let selected = view.getSelection()
        if selected == nil { view.selectAll() }
        var text = selected ?? view.getSelection() ?? ""
        if selected == nil { view.selectNone() }
        while text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }
        guard !text.isEmpty else { lastError = "That terminal is empty."; return }
        add(ContextItem(kind: .terminalOutput, path: terminal.title, content: text))
    }

    func addGitDiff(_ git: GitController) async {
        guard let repo = git.repository, let status = git.status else { lastError = "No Git status available."; return }
        for entry in status.entries where entry.hasUnstagedChange || entry.isUntracked {
            if let text = try? await repo.diff(path: entry.path, staged: false), !text.isEmpty {
                add(ContextItem(kind: .diff, path: entry.path, content: text))
            }
        }
    }

    // MARK: Optimization and measurement — both free: deterministic, local, lossless unless the user opts in (TSD-04)

    func measureOnly() {
        guard !items.isEmpty else { return }
        budgetVerdict = ContextOptimizer.budgetCheck(ContextPayload(items: items), budgetTokens: budgetTokens)
    }

    func optimize() {
        guard !items.isEmpty else { return }
        let r = ContextOptimizer.optimize(ContextPayload(items: items), output: lossyOutputFolding ? .init() : .lossless)
        result = r
        report = SavingsReport.make(baseline: r.before, optimized: r.after, optimizerCost: 0)
        budgetVerdict = ContextOptimizer.budgetCheck(r.payload, budgetTokens: budgetTokens)
        recordEvent(.prepared)
    }

    /// Three separate kinds — usage, estimated reduction, verified savings — for the popover and the panel.
    var summary: TokenSaverSummary { TokenSaverSummary(eventTotals: eventTotals, history: history, ledger: ledger) }

    /// Records the current result as an event at the point the user acted. No result (nothing optimized) or no
    /// reduction → nothing recorded. A failed store write is reported; it never blocks the hand-off itself.
    private func recordEvent(_ stage: OptimizationStage) {
        guard app.optimizerEnabled, let store, let r = result,   // off means nothing is recorded
              let event = OptimizationRecord.event(original: ContextPayload(items: items), result: r, stage: stage, projectPath: projectPath) else { return }
        Task {
            do { try await store.record(event); await loadHistory() } catch { lastError = "Could not record the optimization: \(error)" }
        }
    }

    // MARK: Hand-off (TS-3): what was prepared and where it went — never "sent to the model" (ADR-023)

    private(set) var handOffNote: String?
    private var handOffPayload: ContextPayload { result?.payload ?? ContextPayload(items: items) }
    private var handOffMarkdown: String { ContextOptimizer.handOffMarkdown(handOffPayload, title: "Context prepared in C2D — \(Date().formatted(date: .abbreviated, time: .shortened))") }

    func copyHandOff() {
        let text = handOffMarkdown
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        recordEvent(.copiedToClipboard)
        handOffNote = "Copied ~\(TokenEstimator.estimate(text).tokens) tokens (heuristic) to the clipboard. Prepared, not confirmed as read by any agent."
    }

    /// Writes `<project>/.c2d/context.md`, replacing the previous hand-off file C2D wrote there. The folder gets
    /// its own `.gitignore` (`*`) so the hand-off never shows up as a change in the user's repository.
    func writeHandOffFile() {
        do {
            let dir = try c2dFolder()
            let text = handOffMarkdown
            try text.write(to: dir.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
            recordEvent(.writtenToFile)
            handOffNote = "Wrote .c2d/context.md (~\(TokenEstimator.estimate(text).tokens) tokens, heuristic). Ask the agent to read it; C2D cannot confirm that it did."
        } catch { lastError = "Could not write .c2d/context.md: \(error.localizedDescription)" }
    }

    /// `<project>/.c2d/`, created with its own `.gitignore` (`*`) so nothing C2D writes there shows up in Git (TSD-07).
    private func c2dFolder() throws -> URL {
        let dir = URL(fileURLWithPath: projectPath).appendingPathComponent(".c2d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ignore = dir.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) { try "*\n".write(to: ignore, atomically: true, encoding: .utf8) }
        return dir
    }

    // MARK: Paired experiment (TSD-03): preview here, real run only in a terminal pane where the user types SPEND

    /// The runner and its fixture tasks, bundled from `Tools/experiment` (see project.yml).
    private static let experimentFolder = Bundle.main.url(forResource: "experiment", withExtension: nil)
    var experimentAvailable: Bool { Self.experimentFolder != nil }
    var experimentReps = 3 { didSet { experimentPlan = nil } }
    /// The user's explicit pick when the transcript shows several models; honoured only while it is still one of them.
    var experimentChosenModel: String? { didSet { experimentPlan = nil } }
    private(set) var experimentPlan: ExperimentPlan?
    private(set) var experimentPreviewing = false
    private(set) var experimentRunDirectory: URL?
    private(set) var experimentResults: (rows: [ExperimentResultRow], undecodable: Int)?

    var experimentModelSource: ExperimentModelSource {
        let sessions: [TranscriptSession] = { if case .available(let l)? = ledger { return l.sessions }; return [] }()
        return ExperimentModelResolver.resolve(agentRecords: app.agentSessions.records(forProject: projectPath), sessions: sessions)
    }

    /// The model every run will request, or nil when none is established (then nothing can run).
    var experimentModel: String? {
        switch experimentModelSource {
        case .verified(let model, _, _, _): model
        case .needsChoice(let observed, _, _, _): experimentChosenModel.flatMap { observed.contains($0) ? $0 : nil }
        case .unknown: nil
        }
    }

    private func experimentCommand() -> PairedExperimentCommand? {
        guard let folder = Self.experimentFolder, let model = experimentModel, let claude = app.providerPaths[AgentProvider.claudeCode.id] else { return nil }
        return PairedExperimentCommand(script: folder.appendingPathComponent("paired_experiment.py").path,
                                       tasks: folder.appendingPathComponent("tasks.example.json").path,
                                       model: model, claudeExecutable: claude, reps: experimentReps)
    }

    /// Plan only: the runner gets no `--run`, so it never starts `claude` (no model call, no usage).
    func previewExperiment() async {
        if app.providersRefreshedAt == nil { await app.refreshProviders() }
        guard let command = experimentCommand() else { lastError = "No model or Claude Code executable established; nothing to preview."; return }
        experimentPreviewing = true
        defer { experimentPreviewing = false }
        switch await AgentDiscovery.run("/usr/bin/python3", command.previewArguments, timeout: 30) {
        case .success(let out):
            do { experimentPlan = try JSONDecoder().decode(ExperimentPlan.self, from: Data(out.utf8)) } catch { lastError = "Unexpected plan output from the runner." }
        case .failure(let why): lastError = "Experiment preview failed: \(why)"
        }
    }

    /// Where the next real run writes (shown in the confirmation before anything starts).
    func nextExperimentDirectory() -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        return URL(fileURLWithPath: projectPath).appendingPathComponent(".c2d/experiments/\(stamp)")
    }

    /// After the user confirmed the sheet: opens the runner in a terminal pane. The runner prints the plan and waits
    /// for the user to type SPEND there; C2D never types it and never answers on the user's behalf.
    func startExperiment(in workspace: WorkspaceController, outputDirectory: URL) {
        guard let command = experimentCommand(), experimentPlan?.model == command.model, experimentPlan?.reps == command.reps else {
            lastError = "Preview the plan again before running."; return
        }
        do { _ = try c2dFolder() } catch { lastError = "Could not create .c2d/: \(error.localizedDescription)"; return }
        experimentRunDirectory = outputDirectory
        experimentResults = nil
        workspace.runInNewTerminal(["/usr/bin/python3"] + command.runArguments(outputDirectory: outputDirectory.path), title: "Token Saver experiment")
    }

    func loadExperimentResults() {
        guard let dir = experimentRunDirectory else { return }
        experimentResults = ExperimentResultRow.load(dir.appendingPathComponent("results.jsonl")) ?? ([], 0)
    }

    func loadHistory() async {
        guard let store else { return }
        do {
            history = try await store.records(projectPath: projectPath, limit: 50)
            eventTotals = try await store.eventTotals(projectPath: projectPath)
        } catch { lastError = "\(error)" }
    }
}
