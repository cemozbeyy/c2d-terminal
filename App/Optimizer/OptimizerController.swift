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
    private(set) var totals: [MeasurementSource: SourceTotals] = [:]
    var budgetTokens = 8000
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
    var entitlementNoteForLedger: String { app.optimizerEnabled ? "Not scanned yet." : "Token Optimizer is off — turn it on from the top-bar switch to read usage." }

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

    func addGitDiff(_ git: GitController) async {
        guard let repo = git.repository, let status = git.status else { lastError = "No Git status available."; return }
        for entry in status.entries where entry.hasUnstagedChange || entry.isUntracked {
            if let text = try? await repo.diff(path: entry.path, staged: false), !text.isEmpty {
                add(ContextItem(kind: .diff, path: entry.path, content: text))
            }
        }
    }

    // MARK: Optimization (premium) and measurement (free)

    func measureOnly() {
        guard !items.isEmpty else { return }
        budgetVerdict = ContextOptimizer.budgetCheck(ContextPayload(items: items), budgetTokens: budgetTokens)
    }

    func optimize() {
        guard app.entitlement.isPremium else { lastError = "Optimization is a Premium capability. Measurement stays available."; return }
        guard !items.isEmpty else { return }
        let r = ContextOptimizer.deduplicate(ContextPayload(items: items))
        result = r
        report = SavingsReport.make(baseline: r.before, optimized: r.after, optimizerCost: 0)
        budgetVerdict = ContextOptimizer.budgetCheck(r.payload, budgetTokens: budgetTokens)
    }

    func recordResult() async {
        guard let store, let r = result, let rep = report else { return }
        let rec = OptimizationRecord(projectPath: projectPath, sourceDescription: "\(items.count) item(s): " + Set(items.map(\.kind.rawValue)).sorted().joined(separator: ", "),
                                     baselineTokens: r.before.tokens, optimizedTokens: r.after.tokens, measurementSource: rep.source,
                                     actionsSummary: r.actions.isEmpty ? "no deterministic reductions found" : r.actions.map { "\($0.kind.rawValue):\($0.itemID.prefix(6))" }.joined(separator: " "),
                                     optimizerCostTokens: 0)
        do { try await store.record(rec); await loadHistory() } catch { lastError = "\(error)" }
    }

    func loadHistory() async {
        guard let store else { return }
        do {
            history = try await store.records(projectPath: projectPath, limit: 50)
            totals = try await store.aggregate(projectPath: projectPath)
        } catch { lastError = "\(error)" }
    }
}
