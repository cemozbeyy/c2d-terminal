import Foundation

/// TSD-02: tells whether Claude Code is configured to run RTK as a Bash hook. Read-only — the settings file is
/// never written — and RTK itself is never run, embedded or bundled (ADR-023).
public enum RTKHookDetector {
    public static let docsURL = URL(string: "https://github.com/rtk-ai/rtk")!

    /// `<claudeHome>/settings.json`; a missing or unreadable file counts as "not configured".
    public static func isConfigured(claudeHome: URL = ClaudeTranscriptReader.defaultClaudeHome()) -> Bool {
        guard let data = try? Data(contentsOf: claudeHome.appendingPathComponent("settings.json")) else { return false }
        return isConfigured(settings: data)
    }

    /// True when a `PreToolUse` hook command runs `rtk` (e.g. `rtk hook claude`). Malformed JSON → false.
    public static func isConfigured(settings: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let groups = (root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                let command = (hook["command"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                return command == "rtk" || command.hasPrefix("rtk ") || command.hasSuffix("/rtk") || command.contains("/rtk ")
            }
        }
    }
}
