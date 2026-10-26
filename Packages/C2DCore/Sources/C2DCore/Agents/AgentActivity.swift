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
    /// hook and no `permissions` (ADR-034 retired the Token Saver command rewrite and its allow rule). With a
    /// `tokenSaverHook` (Debug, opt-in, see `TokenSaverLaunchHook.decide`), one more `PostToolUse` group for Bash runs
    /// the fold helper; without one the JSON is exactly what it always was.
    public static func hookSettings(stateFile: String, tokenSaverHook: TokenSaverLaunchHook? = nil) -> String {
        let quoted = shellQuoted(stateFile)
        var hooks: [String: Any] = [:]
        for (event, activity) in events {
            hooks[event] = [["hooks": [["type": "command", "command": "printf \(activity.rawValue) > \(quoted)"]]]]
        }
        if let tokenSaverHook {
            hooks["PostToolUse"] = (hooks["PostToolUse"] as? [[String: Any]] ?? [])
                + [["matcher": "Bash", "hooks": [["type": "command", "command": tokenSaverHook.command, "timeout": 10]]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

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

/// The Token Saver fold helper as a Claude Code `PostToolUse` hook on C2D launches (ADR-035, plan P2). Only
/// `decide` builds one, and only when every gate is open; anything uncertain leaves the launch exactly as before.
public struct TokenSaverLaunchHook: Hashable, Sendable {
    public let helperPath: String
    public let ledgerPath: String
    /// Claude's project folder name, so the ledger groups events by project.
    public let projectFolder: String

    public var command: String {
        "\(AgentActivity.shellQuoted(helperPath)) --ledger \(AgentActivity.shellQuoted(ledgerPath)) --project \(AgentActivity.shellQuoted(projectFolder))"
    }

    public enum Decision: Hashable, Sendable {
        case on(TokenSaverLaunchHook)
        case off(String)
        public var hook: TokenSaverLaunchHook? { if case .on(let h) = self { return h }; return nil }
    }

    /// Release builds, Token Saver off, the fold switch off (the default), an RTK hook (configured or unknown: one owner
    /// per output is not yet proven — fail-closed), or a missing helper each keep the fold out of the launch.
    public static func decide(isDebugBuild: Bool, tokenSaverOn: Bool, foldOn: Bool, rtkHookConfigured: Bool?,
                              helperPath: String?, ledgerPath: String?, projectPath: String) -> Decision {
        guard isDebugBuild else { return .off("Release builds never add the fold hook.") }
        guard tokenSaverOn else { return .off("Token Saver is off.") }
        guard foldOn else { return .off("Off (default).") }
        switch rtkHookConfigured {
        case nil: return .off("RTK hook state unknown; the fold stays off (fail-closed).")
        case true?: return .off("RTK hook is active, so the C2D fold stays off until a combined run proves it never reprocesses RTK output (fail-closed).")
        case false?: break
        }
        guard let helperPath, FileManager.default.isExecutableFile(atPath: helperPath) else { return .off("Fold helper is not in this build.") }
        guard let ledgerPath else { return .off("No ledger path.") }
        return .on(TokenSaverLaunchHook(helperPath: helperPath, ledgerPath: ledgerPath, projectFolder: ClaudeTranscriptReader.projectFolderName(for: projectPath)))
    }
}
