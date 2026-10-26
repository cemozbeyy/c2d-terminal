import Foundation

/// Token Saver as a Claude Code `PostToolUse` hook (ADR-035, PROPOSED — **not wired into any launch**). The command
/// has already run under Claude Code's own permissions when this sees it, so nothing about execution or permissions
/// changes; it can only offer a smaller `updatedToolOutput`. Contract checked against the docs and CLI 2.1.307: the
/// replacement must match the tool's output shape or the CLI uses the original; failed calls go to
/// `PostToolUseFailure`, which cannot replace output; parallel rewrites are last-write-wins.
/// Activation is blocked until a real session shows the replacement reaching the model (needs a model call).
public enum TokenSaverHook {
    /// Larger stdout is passed through untouched: bounded latency and memory, and Claude Code moves very large
    /// output to a file anyway.
    public static let maximumBytes = 1 << 20

    /// PostToolUse payload → response JSON, or nil to leave the result exactly as it is. Only Bash stdout is ever
    /// changed, only by `OutputCondenser.condenseExact` (byte-reversible), and every other `tool_response` field
    /// (stderr, interrupted, isImage, returnCodeInterpretation, bashEditDiff, …) is copied verbatim.
    /// Opt-in lossy variants for the owner's quality experiment only (`c2d-token-helper --lossy <variant>`; never the
    /// default, never in a launch). Each drops content behind an explicit `[c2d: … omitted]` marker; diagnostics are kept
    /// by the condenser's classifier. `all` is the condenser's default option set.
    public enum LossyVariant: String, CaseIterable, Sendable {
        case similar, longline, truncate, all
        public var options: OutputCondenser.Options {
            switch self {
            case .similar: .init(lineBudget: nil, longLine: nil)
            case .longline: .init(lineBudget: nil, similarRunMinimum: .max)
            case .truncate: .init(similarRunMinimum: .max, longLine: nil)
            case .all: .init()
            }
        }
    }

    public static func postToolUseResponse(payload: Data, lossy: LossyVariant? = nil) -> Data? {
        evaluate(payload: payload, lossy: lossy).response
    }

    /// The response (as `postToolUseResponse`) plus the `c2d gain` ledger event for it: nil only when the payload is not a
    /// Bash `PostToolUse` with text stdout. `project` is Claude's project folder name; defaults to the payload's `cwd`.
    /// The event's `helperMilliseconds` is left for the caller, who times the whole run.
    public static func evaluate(payload: Data, lossy: LossyVariant? = nil, project: String? = nil, at date: Date = Date()) -> (response: Data?, event: GainEvent?) {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              root["hook_event_name"] as? String ?? "PostToolUse" == "PostToolUse", root["tool_name"] as? String == "Bash",
              let command = (root["tool_input"] as? [String: Any])?["command"] as? String,
              var response = root["tool_response"] as? [String: Any], let stdout = response["stdout"] as? String,
              response["isImage"] as? Bool != true else { return (nil, nil) }
        let original = stdout.utf8.count
        func event(_ reason: GainEvent.SkipReason?, result: Int) -> GainEvent {
            GainEvent(timestamp: date, source: .live,
                      project: project ?? (root["cwd"] as? String).map(ClaudeTranscriptReader.projectFolderName(for:)) ?? "unknown",
                      sessionID: root["session_id"] as? String, toolUseID: root["tool_use_id"] as? String, family: Replay.family(of: command),
                      mode: lossy.map { "lossy:\($0.rawValue)" } ?? "exact", outcome: reason == nil ? .emitted : .skipped, skipReason: reason,
                      originalStdoutBytes: original, resultStdoutBytes: result, stderrBytes: (response["stderr"] as? String)?.utf8.count)
        }
        if response["interrupted"] as? Bool == true { return (nil, event(.interrupted, result: original)) }
        if stdout.isEmpty { return (nil, event(.empty, result: 0)) }
        if original > maximumBytes { return (nil, event(.tooLarge, result: original)) }
        if let reason = skipReason(command: command, stdout: stdout) { return (nil, event(reason, result: original)) }
        let folded: String
        if let lossy {
            let c = OutputCondenser.condense(stdout, options: lossy.options)
            guard c.changed, c.steps.contains(where: \.isLossy) || c.steps.contains(.collapsedRepeats) || c.steps.contains(.groupedByFile),
                  c.text.utf8.count < original else { return (nil, event(.noGain, result: original)) }
            folded = c.text + (stdout.hasSuffix("\n") ? "\n" : "")
        } else {
            guard let exact = OutputCondenser.condenseExact(stdout) else { return (nil, event(.noGain, result: original)) }
            folded = exact
        }
        response["stdout"] = folded
        guard let data = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PostToolUse", "updatedToolOutput": response]],
                                                     options: [.sortedKeys]) else { return (nil, event(.noGain, result: original)) }
        return (data, event(nil, result: folded.utf8.count))
    }

    /// Output that must reach the agent as it is: diffs (never transformed), output RTK already filtered (one owner
    /// per output: RTK's rewrite shows as an `rtk …` command or its recall/tee hints), and output Claude Code
    /// already moved to a file.
    static func skips(command: String, stdout: String) -> Bool { skipReason(command: command, stdout: stdout) != nil }

    /// Why `skips` leaves an output alone (`c2d gain` counts skips by reason), or nil.
    static func skipReason(command: String, stdout: String) -> GainEvent.SkipReason? {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = c.split(whereSeparator: { $0.isWhitespace || ";&|()".contains($0) })
        if c.hasPrefix("rtk ") || words.contains("rtk") { return .rtk }
        if words.contains("diff") { return .diff }
        let text = "\n" + stdout
        if text.contains("\ndiff --git ") || text.contains("\n@@ ") || text.contains("\n+++ ") || text.contains("\n--- a/") { return .diff }
        if stdout.contains("rtk recall") || stdout.contains("[see remaining: tail -n +") || stdout.contains("[rtk]") { return .rtk }
        if stdout.contains("<persisted-output>") { return .persisted }
        return nil
    }
}
