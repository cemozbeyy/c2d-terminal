import Foundation

/// What a C2D-launched Claude Code session is doing, as reported by the CLI's own hooks.
///
/// C2D passes `--settings <json>` at launch with a few hooks that each overwrite one small file per
/// session with a single word. No model output is read; the user's own settings are not touched
/// (flag settings are an extra source the CLI merges with theirs).
public enum AgentActivity: String, Sendable, Equatable {
    /// The session started and is waiting for a first prompt.
    case idle
    /// A prompt was submitted or a tool just finished: the agent is working.
    case working
    /// The CLI asked for the user (a permission prompt, or idle waiting for input).
    case waiting
    /// The agent finished its turn.
    case done

    /// Hook event → word written. `PostToolUse` flips back to working after a permission was granted.
    static let events: [(event: String, activity: AgentActivity)] = [
        ("SessionStart", .idle), ("UserPromptSubmit", .working), ("PostToolUse", .working),
        ("Notification", .waiting), ("Stop", .done),
    ]

    /// The `--settings` JSON that makes the CLI report into `stateFile`. Activity hooks only: no `PreToolUse`
    /// hook and no `permissions` (ADR-034 retired the Token Saver command rewrite and its allow rule).
    public static func hookSettings(stateFile: String) -> String {
        let quoted = "'" + stateFile.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var hooks: [String: Any] = [:]
        for (event, activity) in events {
            hooks[event] = [["hooks": [["type": "command", "command": "printf \(activity.rawValue) > \(quoted)"]]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a state file; unknown content (or none) is `nil`, never a guess.
    public static func read(_ url: URL) -> AgentActivity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return AgentActivity(rawValue: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Where state files live: Application Support/C2D Terminal/agent-activity (or the debug override).
    public static func directory() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["C2D_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("agent-activity")
        }
        #endif
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("C2D Terminal").appendingPathComponent("agent-activity")
    }

    public static func stateFile(sessionID: String) -> URL { directory().appendingPathComponent(sessionID) }
}
