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

/// Token Saver: provider-reported usage read from Claude Code's local transcripts (TS-1) and attributed to
/// C2D-launched sessions (TS-2). Read-only, on demand, nothing stored. Nothing here transforms agent
/// output (ADR-034/035), so there is no "saved" figure to compute.
@MainActor
@Observable
final class OptimizerController {
    let projectPath: String
    private(set) var ledger: TranscriptLedgerResult?
    private(set) var ledgerLoading = false
    private(set) var ledgerScannedAt: Date?
    /// Transcript session id → attribution, recomputed on every scan from the agent registry (pure, deterministic).
    private(set) var attribution: [String: SessionAttribution] = [:]
    private(set) var launchesWithoutTranscript: [AgentSessionRecord] = []

    @ObservationIgnored private unowned let app: AppModel

    init(projectPath: String, app: AppModel) {
        self.projectPath = projectPath
        self.app = app
    }

    var isEnabled: Bool { app.optimizerEnabled }
    /// Provider-reported totals over every session of this project; nil until read or when unavailable. Usage, never savings.
    var usage: ProviderUsage? { if case .available(let l)? = ledger { return l.total }; return nil }
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
}
