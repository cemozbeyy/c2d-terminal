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
/// C2D-launched sessions (TS-2), plus the unified savings report (`UnifiedGain`: RTK-powered + C2D fold, both
/// estimates from each engine's own count). Read-only, on demand; nothing here transforms agent output.
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
    /// Whether the user's Claude Code settings run RTK as a `PreToolUse` Bash hook (TSD-02). Read-only, user-level
    /// `settings.json` only; nil until read or while Token Saver is off. RTK's filtering is counted by `rtk gain`, never here.
    private(set) var rtkHookConfigured: Bool?
    /// The unified live report (RTK-powered + C2D fold), read with the ledger; nil while off or not read yet.
    private(set) var gain: UnifiedGain?
    /// The same unified report over every project (`c2d gain --global`), read on request.
    private(set) var globalGain: UnifiedGain?
    /// Offline replay of this project's transcripts, computed on request and kept in memory only.
    private(set) var replay: GainReport?
    private(set) var replayLoading = false

    @ObservationIgnored private unowned let app: AppModel

    init(projectPath: String, app: AppModel) {
        self.projectPath = projectPath
        self.app = app
    }

    var isEnabled: Bool { app.optimizerEnabled }
    /// Sessions launched from C2D (TS-2 link by the `--session-id` C2D chose), newest first. The popover counts only
    /// these (owner 2026-10-30); a session started in another terminal is the user's, not C2D's.
    var c2dSessions: [TranscriptSession] {
        guard case .available(let l)? = ledger else { return [] }
        return l.sessions.filter { if case .linked? = attribution[$0.id] { return true }; return false }
    }
    /// Provider-reported totals over the C2D-launched sessions; nil until read, when unavailable, or with none. Usage, never savings.
    var usage: ProviderUsage? { c2dSessions.isEmpty ? nil : c2dSessions.map(\.usage).reduce(ProviderUsage(), +) }
    /// TSD-06 boundary for the totals: "verified" when every counted session's CLI version was hand-verified, otherwise
    /// "shape-checked" (accepted by the read-time shape check only). Provider-reported either way; only the format check differs.
    var usageFormatTag: String? {
        let s = c2dSessions
        guard !s.isEmpty else { return nil }
        return s.allSatisfy { $0.formatCheck == .handVerified } ? "verified format" : "some sessions shape-checked, not hand-verified"
    }
    /// The newest C2D-launched session by last reply. Its `lastContextTokens` / `peakContextTokens` are provider-reported
    /// sizes of single requests (input + cache read + cache creation), a different measure from the summed `usage` above.
    var newestSession: (session: TranscriptSession, attribution: SessionAttribution)? {
        c2dSessions.first.map { ($0, attribution[$0.id] ?? .unmatched) }
    }
    /// The settings file the RTK check reads (`CLAUDE_CONFIG_DIR` aware), shown so the user knows what was and was not checked.
    var rtkSettingsPath: String {
        (ClaudeTranscriptReader.defaultClaudeHome().appendingPathComponent("settings.json").path as NSString).abbreviatingWithTildeInPath
    }
    /// Whether a Claude launch here would carry the C2D fold hook, and why not.
    var foldDecision: TokenSaverLaunchHook.Decision { app.tokenSaverHookDecision(projectPath: projectPath) }

    /// Reads the all-projects report (C2D ledger, every project; RTK's whole history, read-only).
    func loadGlobalGain() async {
        guard app.optimizerEnabled else { globalGain = nil; return }
        globalGain = await Task.detached(priority: .userInitiated) { () -> UnifiedGain in
            let store = (try? OptimizationStore.standardPath()).flatMap { try? OptimizationStore(path: $0) }
            let events = await (try? store?.events(source: .live)) ?? []
            return UnifiedGain(c2dEvents: events, rtk: RTKLedger.read(projectPath: nil), projectPath: nil)
        }.value
    }

    /// Replays this project's transcripts through the exact fold (offline, in memory, nothing stored or sent).
    func loadReplay() async {
        guard app.optimizerEnabled, !replayLoading else { return }
        replayLoading = true
        defer { replayLoading = false }
        let folder = ClaudeTranscriptReader.projectFolder(for: projectPath)
        let events = await Task.detached(priority: .userInitiated) { GainEvent.replayEvents(projectFolder: folder) }.value
        replay = GainReport(events: events, source: .replay, project: folder.lastPathComponent)
    }

    /// Why there is no usage figure right now.
    var usageNote: String {
        if !app.optimizerEnabled { return "Token Saver is off; transcripts are not read." }
        if ledgerLoading { return "Reading Claude Code transcripts…" }
        if case .unavailable(let reason)? = ledger { return reason }
        if ledger != nil { return "No Claude session launched from C2D in this project yet." }
        return "Not read yet."
    }

    /// Scans this project's transcript folder off the main actor (ADR-022). A no-op while the Token
    /// Optimizer switch is off (Addendum A.6.7: the whole surface can be switched off).
    func loadLedger() async {
        guard app.optimizerEnabled else { ledger = nil; rtkHookConfigured = nil; gain = nil; globalGain = nil; replay = nil; return }
        guard !ledgerLoading else { return }
        ledgerLoading = true
        defer { ledgerLoading = false }
        let path = projectPath
        let read = await Task.detached(priority: .userInitiated) { () -> (TranscriptLedgerResult, Bool?) in
            (ClaudeTranscriptReader.read(projectPath: path), RTKHookDetector.state(projectPath: path))
        }.value
        ledger = read.0
        rtkHookConfigured = read.1
        ledgerScannedAt = Date()
        let sessions: [TranscriptSession] = { if case .available(let l)? = ledger { return l.sessions }; return [] }()
        let records = app.agentSessions.records(forProject: projectPath)
        attribution = SessionAttributor.attribute(sessions: sessions, agentRecords: records)
        launchesWithoutTranscript = SessionAttributor.launchesWithoutTranscript(sessions: sessions, agentRecords: records)
        // RTK rows only while a C2D-launched session was running (approximate: RTK keeps no session id). C2D fold events
        // need no filter: the fold hook rides only on C2D launches. A store error means no C2D rows, never a guess.
        let windows = c2dSessions.compactMap { s in s.firstTimestamp.flatMap { f in s.lastTimestamp.map { f...$0 } } }
        gain = await Task.detached(priority: .userInitiated) { () -> UnifiedGain in
            let folder = ClaudeTranscriptReader.projectFolderName(for: path)
            let events = (try? OptimizationStore.standardPath()).flatMap { try? OptimizationStore(path: $0) }
            let c2d = await (try? events?.events(source: .live, project: folder)) ?? []
            return UnifiedGain(c2dEvents: c2d, rtk: RTKLedger.read(projectPath: path, windows: windows), projectPath: path)
        }.value
    }
}
