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
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              root["hook_event_name"] as? String ?? "PostToolUse" == "PostToolUse", root["tool_name"] as? String == "Bash",
              let command = (root["tool_input"] as? [String: Any])?["command"] as? String,
              var response = root["tool_response"] as? [String: Any], let stdout = response["stdout"] as? String,
              response["interrupted"] as? Bool != true, response["isImage"] as? Bool != true,
              !stdout.isEmpty, stdout.utf8.count <= maximumBytes, !skips(command: command, stdout: stdout) else { return nil }
        let folded: String
        if let lossy {
            let c = OutputCondenser.condense(stdout, options: lossy.options)
            guard c.changed, c.steps.contains(where: \.isLossy) || c.steps.contains(.collapsedRepeats) || c.steps.contains(.groupedByFile),
                  c.text.utf8.count < stdout.utf8.count else { return nil }
            folded = c.text + (stdout.hasSuffix("\n") ? "\n" : "")
        } else {
            guard let exact = OutputCondenser.condenseExact(stdout) else { return nil }
            folded = exact
        }
        response["stdout"] = folded
        return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PostToolUse", "updatedToolOutput": response]],
                                           options: [.sortedKeys])
    }

    /// Output that must reach the agent as it is: diffs (never transformed), output RTK already filtered (one owner
    /// per output: RTK's rewrite shows as an `rtk …` command or its recall/tee hints), and output Claude Code
    /// already moved to a file.
    static func skips(command: String, stdout: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = c.split(whereSeparator: { $0.isWhitespace || ";&|()".contains($0) })
        if c.hasPrefix("rtk ") || words.contains("rtk") || words.contains("diff") { return true }
        let text = "\n" + stdout
        return text.contains("\ndiff --git ") || text.contains("\n@@ ") || text.contains("\n+++ ") || text.contains("\n--- a/")
            || stdout.contains("rtk recall") || stdout.contains("[see remaining: tail -n +") || stdout.contains("[rtk]")
            || stdout.contains("<persisted-output>")
    }
}
