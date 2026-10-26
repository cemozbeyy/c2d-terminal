import Foundation

/// One Bash output the Token Saver saw (`c2d gain`, plan `C2D_GAIN_PLAN_2026-10-26.md` P0). Bytes are measured; the
/// command text is never stored, only its `Replay.family(of:)` label. `emitted` means the helper produced a smaller
/// stdout; whether Claude Code delivered it to the model is not known per event (D2), so nothing here is "saved".
public struct GainEvent: Hashable, Sendable {
    /// Live hook events and offline replay events are different measurements and are never aggregated together.
    public enum Source: String, Sendable, CaseIterable { case live, replay }
    public enum Outcome: String, Sendable { case emitted, skipped }
    public enum SkipReason: String, Sendable, CaseIterable {
        case rtk, diff, persisted, tooLarge = "too_large", interrupted, empty, failed, noGain = "no_gain"
    }

    public var timestamp: Date
    public var source: Source
    /// Claude Code's project folder name (`ClaudeTranscriptReader.projectFolderName(for:)`), the same key for both sources.
    public var project: String
    public var sessionID: String?
    public var toolUseID: String?
    public var family: String
    public var mode: String
    public var outcome: Outcome
    public var skipReason: SkipReason?
    public var originalStdoutBytes: Int
    /// Equal to `originalStdoutBytes` for a skip.
    public var resultStdoutBytes: Int
    /// Recorded, never counted as savings. nil when the source cannot separate it (replay sees the combined result text).
    public var stderrBytes: Int?
    /// Time the helper spent; nil when it did not run (replay).
    public var helperMilliseconds: Int?

    public init(timestamp: Date, source: Source, project: String, sessionID: String? = nil, toolUseID: String? = nil, family: String,
                mode: String = "exact", outcome: Outcome, skipReason: SkipReason? = nil, originalStdoutBytes: Int, resultStdoutBytes: Int,
                stderrBytes: Int? = nil, helperMilliseconds: Int? = nil) {
        self.timestamp = timestamp; self.source = source; self.project = project; self.sessionID = sessionID; self.toolUseID = toolUseID
        self.family = family; self.mode = mode; self.outcome = outcome; self.skipReason = skipReason
        self.originalStdoutBytes = originalStdoutBytes; self.resultStdoutBytes = resultStdoutBytes
        self.stderrBytes = stderrBytes; self.helperMilliseconds = helperMilliseconds
    }

    public var savedBytes: Int { outcome == .emitted ? originalStdoutBytes - resultStdoutBytes : 0 }

    /// What the exact-fold hook would have done with one transcript Bash result, by the hook's own rules. The replay
    /// output is the result text as the model saw it (stdout and stderr combined, after RTK if RTK ran).
    public static func replay(command: String, output: Data, isError: Bool, project: String, sessionID: String?, at date: Date) -> GainEvent {
        let stdout = String(decoding: output, as: UTF8.self)
        var reason: SkipReason?
        if isError { reason = .failed }   // failed calls go to PostToolUseFailure, which cannot replace output
        else if stdout.isEmpty { reason = .empty }
        else if output.count > TokenSaverHook.maximumBytes { reason = .tooLarge }
        else { reason = TokenSaverHook.skipReason(command: command, stdout: stdout) }
        var result = output.count
        if reason == nil {
            if let folded = OutputCondenser.condenseExact(stdout), folded.utf8.count < output.count { result = folded.utf8.count } else { reason = .noGain }
        }
        return GainEvent(timestamp: date, source: .replay, project: project, sessionID: sessionID, family: Replay.family(of: command),
                         outcome: reason == nil ? .emitted : .skipped, skipReason: reason, originalStdoutBytes: output.count, resultStdoutBytes: result)
    }
}

extension GainEvent {
    /// Replay events for one Claude project folder (`~/.claude/projects/<folder>`), computed in memory and never stored:
    /// what the exact-fold hook would have done to every past Bash result there. Offline; reads transcripts only.
    public static func replayEvents(projectFolder: URL) -> [GainEvent] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: projectFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        var out: [GainEvent] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let session = Replay.extract(lines: String(decoding: data, as: UTF8.self).split(separator: "\n"))
            for s in session.samples where s.tool == "Bash" {
                out.append(.replay(command: s.command, output: s.output, isError: s.isError, project: projectFolder.lastPathComponent,
                                   sessionID: file.deletingPathExtension().lastPathComponent, at: date))
            }
        }
        return out
    }
}

/// `c2d gain`: totals over events of exactly one source. Savings % is Σsaved / Σoriginal over transformed events (skips
/// are counted but never dilute it, as in `rtk gain`); tokens are `ceil(bytes/4)` estimates, shown beside the bytes.
public struct GainReport: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public var family: String
        public var commands = 0
        public var transformed = 0
        public var originalBytes = 0   // transformed events only
        public var resultBytes = 0
        public var estimatedTokensSaved = 0
        public var estimatedOriginalTokens = 0   // transformed events only
        public var helperMilliseconds = 0
        public var timedEvents = 0
        public var savedBytes: Int { originalBytes - resultBytes }
        public var savingsPercent: Double? { GainReport.percent(savedBytes, of: originalBytes) }
    }

    public let source: GainEvent.Source
    /// nil = every project (`--global`).
    public let project: String?
    public let total: Row
    /// stdout bytes of every event, transformed or not: the base for "share of all stdout seen".
    public let stdoutSeenBytes: Int
    public let skips: [GainEvent.SkipReason: Int]
    public let byFamily: [Row]
    /// Saved bytes over every stdout byte seen, skips included: the honest headline next to the transformed-only rate.
    public var shareOfAllStdout: Double? { Self.percent(total.savedBytes, of: stdoutSeenBytes) }

    public static let tokenLabel = "estimated, bytes/4, not provider-reported"

    public static func estimatedTokens(_ bytes: Int) -> Int { (bytes + 3) / 4 }
    public static func percent(_ part: Int, of whole: Int) -> Double? { whole > 0 ? Double(part) / Double(whole) * 100 : nil }

    /// Events of any other source are ignored, so live and replay can never be summed.
    public init(events: [GainEvent], source: GainEvent.Source, project: String?) {
        self.source = source
        self.project = project
        let mine = events.filter { $0.source == source && (project == nil || $0.project == project) }
        var total = Row(family: "total"), rows: [String: Row] = [:], skips: [GainEvent.SkipReason: Int] = [:], seen = 0
        for e in mine {
            seen += e.originalStdoutBytes
            var row = rows[e.family] ?? Row(family: e.family)
            for i in 0..<2 {
                var r = i == 0 ? total : row
                r.commands += 1
                if e.outcome == .emitted {
                    r.transformed += 1
                    r.originalBytes += e.originalStdoutBytes
                    r.resultBytes += e.resultStdoutBytes
                    r.estimatedTokensSaved += Self.estimatedTokens(e.originalStdoutBytes) - Self.estimatedTokens(e.resultStdoutBytes)
                    r.estimatedOriginalTokens += Self.estimatedTokens(e.originalStdoutBytes)
                }
                if let ms = e.helperMilliseconds { r.helperMilliseconds += ms; r.timedEvents += 1 }
                if i == 0 { total = r } else { row = r }
            }
            rows[e.family] = row
            if let reason = e.skipReason { skips[reason, default: 0] += 1 }
        }
        self.total = total
        self.stdoutSeenBytes = seen
        self.skips = skips
        self.byFamily = rows.values.sorted { ($0.savedBytes, $0.commands, $1.family) > ($1.savedBytes, $1.commands, $0.family) }
    }

    public func render(limit: Int = 12) -> String {
        let scope = project.map { "project \($0)" } ?? "all projects"
        let header: String
        switch source {
        case .live: header = "C2D Token Saver — live hook events, \(scope)\nTransformed = the helper emitted a smaller stdout; delivery to the model is not proven (D2 pending)."
        case .replay: header = "C2D Token Saver — REPLAY (offline, not live), \(scope)\nWhat exact-fold would have done to past transcript Bash results; nothing here ran in a session."
        }
        let skipText = GainEvent.SkipReason.allCases.compactMap { r in skips[r].map { "\(r.rawValue) \($0)" } }.joined(separator: ", ")
        var lines = [header, "",
            "Commands            \(total.commands)   transformed \(total.transformed)   skipped \(total.commands - total.transformed)" + (skipText.isEmpty ? "" : " (\(skipText))"),
            "Original stdout     \(Self.bytes(total.originalBytes))   (transformed commands; measured)",
            "Optimized stdout    \(Self.bytes(total.resultBytes))",
            "Saved               \(Self.bytes(total.savedBytes)) (\(Self.pct(total.savingsPercent)))   share of all stdout seen: \(Self.pct(Self.percent(total.savedBytes, of: stdoutSeenBytes)))",
            "Est. tokens saved   \(total.estimatedTokensSaved)   (\(Self.tokenLabel))",
            "C2D overhead        " + (total.timedEvents > 0 ? "\(total.helperMilliseconds) ms total, \(total.helperMilliseconds / total.timedEvents) ms avg (helper only; command run time is not visible to the hook)" : "— (not measured for this source)"),
            "stderr              never counted as savings"]
        let shown = byFamily.prefix(limit)
        if shown.isEmpty {
            lines += ["", "By command: (none)"]
        } else {
            lines += ["", "By command (family; saved % = Σsaved / Σoriginal of transformed)",
                      "  " + "family".padding(toLength: 16, withPad: " ", startingAt: 0) + "  count  transf.        saved   saved %   est.tok  impact"]
            let top = max(1, shown.map(\.savedBytes).max() ?? 1)
            for r in shown {
                let bar = String(repeating: "█", count: r.savedBytes > 0 ? max(1, r.savedBytes * 10 / top) : 0)
                lines.append("  " + r.family.prefix(16).padding(toLength: 16, withPad: " ", startingAt: 0)
                             + Self.pad(r.commands, 7) + Self.pad(r.transformed, 9) + Self.padText(Self.bytes(r.savedBytes), 13)
                             + Self.padText(Self.pct(r.savingsPercent), 10) + Self.pad(r.estimatedTokensSaved, 10) + "  " + bar)
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1024 / 1024)
    }
    public static func pct(_ p: Double?) -> String { p.map { String(format: "%.2f %%", $0) } ?? "—" }
    static func pad(_ n: Int, _ width: Int) -> String { padText("\(n)", width) }
    static func padText(_ s: String, _ width: Int) -> String { String(repeating: " ", count: max(0, width - s.count)) + s }
}

/// The one Token Saver report the user sees (owner decision 2026-10-26): every engine's live contribution in one total,
/// each labelled by who measured it. RTK-powered = RTK's own count of the commands it filtered, read from its history;
/// C2D fold = this ledger's live `emitted` events. Both count `ceil(bytes/4)`, so the estimates add up; neither is
/// provider-reported, and nothing here is provider-verified. Replay is never part of it.
///
/// No double count: a C2D event on output RTK already owns is a skip (`SkipReason.rtk`) and adds nothing; C2D folds
/// only what reached it after RTK, so the two reductions are disjoint by construction (C2D never sees RTK's raw output).
public struct UnifiedGain: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public var family: String
        public var rtkCommands = 0
        public var c2dCommands = 0
        public var rtkSavedTokens = 0
        public var c2dSavedTokens = 0
        public var inputTokens = 0
        /// RTK's own run time of the commands it filtered (command + filter), as RTK recorded it.
        public var rtkRunMilliseconds = 0
        /// Time the C2D helper itself took (overhead), over the events that were timed.
        public var c2dHelperMilliseconds = 0
        public var c2dTimedEvents = 0
        public var commands: Int { rtkCommands + c2dCommands }
        public var savedTokens: Int { rtkSavedTokens + c2dSavedTokens }
        public var savingsPercent: Double? { GainReport.percent(savedTokens, of: inputTokens) }
        public var rtkAverageMilliseconds: Int? { rtkCommands > 0 ? rtkRunMilliseconds / rtkCommands : nil }
        public var c2dAverageMilliseconds: Int? { c2dTimedEvents > 0 ? c2dHelperMilliseconds / c2dTimedEvents : nil }
        public var engines: String {
            switch (rtkCommands > 0, c2dSavedTokens != 0) {
            case (true, true): "RTK + C2D"
            case (true, false): "RTK"
            case (false, true): "C2D"
            case (false, false): "—"
            }
        }
    }

    /// Every live C2D event (its own lines: skips, bytes, overhead).
    public let c2d: GainReport
    /// C2D events minus the ones on RTK-owned output: those commands are RTK's and already counted from RTK's history,
    /// so the unified rows and totals count each command once.
    public let c2dOwn: GainReport
    public let rtk: RTKLedger.Result
    public let projectPath: String?
    public let byFamily: [Row]

    /// `projectPath` nil = every project. C2D events are keyed by Claude's project folder, RTK rows by directory.
    public init(c2dEvents: [GainEvent], rtk: RTKLedger.Result, projectPath: String?) {
        self.projectPath = projectPath
        let folder = projectPath.map(ClaudeTranscriptReader.projectFolderName(for:))
        c2d = GainReport(events: c2dEvents, source: .live, project: folder)
        c2dOwn = GainReport(events: c2dEvents.filter { $0.skipReason != .rtk }, source: .live, project: folder)
        self.rtk = rtk
        var rows: [String: Row] = [:]
        for r in rtk.ledger?.byFamily ?? [] {
            var row = rows[r.family] ?? Row(family: r.family)
            row.rtkCommands += r.commands; row.rtkSavedTokens += r.savedTokens
            row.inputTokens += r.inputTokens; row.rtkRunMilliseconds += r.execMilliseconds
            rows[r.family] = row
        }
        for r in c2dOwn.byFamily {
            var row = rows[r.family] ?? Row(family: r.family)
            row.c2dCommands += r.commands; row.c2dSavedTokens += r.estimatedTokensSaved; row.inputTokens += r.estimatedOriginalTokens
            row.c2dHelperMilliseconds += r.helperMilliseconds; row.c2dTimedEvents += r.timedEvents
            rows[r.family] = row
        }
        byFamily = rows.values.sorted { ($0.savedTokens, $0.commands, $1.family) > ($1.savedTokens, $1.commands, $0.family) }
    }

    public var rtkSavedTokens: Int { rtk.ledger?.total.savedTokens ?? 0 }
    public var c2dSavedTokens: Int { c2d.total.estimatedTokensSaved }
    public var estimatedTokensSaved: Int { rtkSavedTokens + c2dSavedTokens }
    public var estimatedInputTokens: Int { (rtk.ledger?.total.inputTokens ?? 0) + c2d.total.estimatedOriginalTokens }
    public var savingsPercent: Double? { GainReport.percent(estimatedTokensSaved, of: estimatedInputTokens) }
    public var commands: Int { (rtk.ledger?.total.commands ?? 0) + c2dOwn.total.commands }

    public func render(limit: Int = 12) -> String {
        let scope = projectPath.map { "project \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "all projects"
        let rtkLine: String
        switch rtk {
        case .available(let l):
            let span = [l.firstDay, l.lastDay].compactMap { $0 }.joined(separator: " … ")
            rtkLine = "  RTK-powered       \(Self.n(rtkSavedTokens).padding(toLength: 10, withPad: " ", startingAt: 0))  \(l.total.commands) commands RTK filtered (RTK's own count, read-only from its history; any agent\(span.isEmpty ? "" : ", \(span)"))"
        case .unavailable(let reason):
            rtkLine = "  RTK-powered       not included — \(reason)"
        }
        var lines = [
            "C2D Token Saver — live, \(scope)",
            "",
            "Est. tokens saved   \(Self.n(estimatedTokensSaved)) (\(GainReport.pct(savingsPercent)) of filtered output)   \(GainReport.tokenLabel)",
            rtkLine,
            "  C2D fold          \(Self.n(c2dSavedTokens).padding(toLength: 10, withPad: " ", startingAt: 0))  \(c2d.total.transformed) transformed of \(c2d.total.commands) seen; emitted, delivery to the model not proven",
            "Provider-verified   not measured (needs a controlled comparison; no figure is claimed)",
            "C2D fold bytes      \(GainReport.bytes(c2d.total.originalBytes)) → \(GainReport.bytes(c2d.total.resultBytes)) (measured); stderr never counted",
            "C2D overhead        " + (c2d.total.timedEvents > 0 ? "\(c2d.total.helperMilliseconds / c2d.total.timedEvents) ms avg per Bash result (helper only)" : "— (no C2D events)"),
        ]
        if !c2d.skips.isEmpty {
            lines.append("C2D skips           " + GainEvent.SkipReason.allCases.compactMap { r in c2d.skips[r].map { "\(r.rawValue) \($0)" } }.joined(separator: ", "))
        }
        let shown = byFamily.prefix(limit)
        if shown.isEmpty {
            lines += ["", "By command: (none)"]
        } else {
            lines += ["", "By command (family; est. tokens; saved % = saved / input of filtered commands)",
                      "  " + "family".padding(toLength: 16, withPad: " ", startingAt: 0) + "  count  engine       saved   saved %   RTK ms   C2D ms  impact"]
            let top = max(1, shown.map(\.savedTokens).max() ?? 1)
            for r in shown {
                let bar = String(repeating: "█", count: r.savedTokens > 0 ? max(1, r.savedTokens * 10 / top) : 0)
                lines.append("  " + r.family.prefix(16).padding(toLength: 16, withPad: " ", startingAt: 0) + GainReport.pad(r.commands, 7)
                             + "  " + r.engines.padding(toLength: 9, withPad: " ", startingAt: 0) + GainReport.padText(Self.n(r.savedTokens), 10)
                             + GainReport.padText(GainReport.pct(r.savingsPercent), 10) + GainReport.padText(r.rtkAverageMilliseconds.map(String.init) ?? "—", 8)
                             + GainReport.padText(r.c2dAverageMilliseconds.map(String.init) ?? "—", 9) + "  " + bar)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func n(_ v: Int) -> String { v.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
}
