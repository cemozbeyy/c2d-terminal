import Foundation

/// C2D's own Token Saver engine (ADR-033). For Claude Code sessions launched from C2D, a `PreToolUse` hook
/// rewrites a few read-only, output-heavy Bash commands to run through C2D's own binary, which hands the agent
/// the losslessly condensed output (`OutputCondenser.Options.lossless`) and appends the measured sizes to a
/// ledger. Anything else is left untouched. Not injected when Token Saver is off or RTK's hook is configured.
public enum TokenSaverEngine {
    public static let hookFlag = "--c2d-token-hook"
    public static let runFlag = "--c2d-token-run"

    /// The runner to inject into a Claude launch, or nil: Token Saver off (same UserDefaults key as
    /// `AppModel.optimizerEnabled`, default on), RTK's hook configured (two rewrites of one call would race),
    /// or no executable path.
    public static func launchRunner() -> String? {
        guard (UserDefaults.standard.object(forKey: "optimizerEnabled") as? Bool) ?? true, !RTKHookDetector.isConfigured() else { return nil }
        return Bundle.main.executablePath
    }

    /// One simple command, no shell operators, from a read-only program whose output is worth condensing.
    /// Diff-shaped output (`git diff/show`, `git log -p`) is excluded: whitespace normalization would change it.
    /// The runner re-checks this, so a hand-written runner call can never run anything else.
    public static func isEligible(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, c.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>$`\\\n\r(){}")) == nil else { return false }
        // Split on spaces only to spot flags; /bin/sh does the real parsing. A quoted "-exec" just refuses.
        let words = c.split(separator: " ").map(String.init)
        let args = words.dropFirst()
        func has(_ flags: [String]) -> Bool { args.contains { w in flags.contains { w == $0 || w.hasPrefix($0 + "=") } } }
        switch words[0] {
        case "git":
            switch args.first {
            case "status": return !has(["--output"])
            case "log": return !has(["-p", "-u", "--patch", "--output", "--ext-diff", "--cc"]) && !args.contains { $0.hasPrefix("-p") && !$0.hasPrefix("--") }
            default: return false
            }
        case "ls", "grep": return true
        case "rg": return !has(["--pre", "--pre-glob"])
        case "find": return !has(["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"])
        case "tree": return !has(["-o"])
        default: return false
        }
    }

    // MARK: Hook mode

    /// Claude Code `PreToolUse` payload → response JSON, or nil to leave the call alone. No `permissionDecision`:
    /// Claude Code's own permission flow still decides (as RTK does for calls without an explicit allow rule).
    public static func hookResponse(payload: Data, runner: String) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], root["tool_name"] as? String == "Bash",
              var input = root["tool_input"] as? [String: Any], let command = input["command"] as? String, isEligible(command) else { return nil }
        input["command"] = "\(shellQuote(runner)) \(runFlag) \(shellQuote(command))"
        return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PreToolUse", "updatedInput": input]], options: [.sortedKeys])
    }

    /// The `--settings` hook entry plus an allow rule for the runner prefix. The rule can only ever admit
    /// `isEligible` commands, because the runner refuses everything else.
    static func settings(runner: String) -> (hook: [String: Any], allow: String) {
        (["matcher": "Bash", "hooks": [["type": "command", "command": "\(shellQuote(runner)) \(hookFlag)"]]],
         "Bash(\(shellQuote(runner)) \(runFlag):*)")
    }

    // MARK: Run mode

    /// Runs `command` with `/bin/sh -c` (cwd and environment inherited), writes its stdout to `out` — condensed
    /// when that is smaller, byte-for-byte otherwise — leaves stderr to the child, appends one ledger row and
    /// returns the child's exit status (128 + signal when killed).
    public static func run(command: String, ledger: URL? = ledgerURL(), out: FileHandle = .standardOutput) -> Int32 {
        guard isEligible(command) else {
            FileHandle.standardError.write(Data("c2d: Token Saver only runs its read-only allowlist; refused: \(command)\n".utf8))
            return 126
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch {
            FileHandle.standardError.write(Data("c2d: could not start /bin/sh: \(error.localizedDescription)\n".utf8))
            return 127
        }
        // ponytail: buffers the whole output (no streaming); fine for the allowlisted commands, which end on their own.
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var shown = raw
        // Diff-shaped output (`git log -U3`, `--patch-with-stat`, …) slips past any flag list; it stays byte-for-byte.
        if let text = String(data: raw, encoding: .utf8), !("\n" + text).contains("\ndiff --git "), !("\n" + text).contains("\n@@ ") {
            let condensed = OutputCondenser.condense(text, options: .lossless)
            let candidate = Data((condensed.text + (text.hasSuffix("\n") ? "\n" : "")).utf8)
            if condensed.changed, candidate.count < raw.count { shown = candidate }
        }
        out.write(shown)
        if let ledger { record(LedgerRow(rawBytes: raw.count, shownBytes: shown.count, rawTokens: tokens(raw), shownTokens: tokens(shown)), to: ledger) }
        return p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
    }

    private static func tokens(_ d: Data) -> Int { TokenEstimator.estimate(String(decoding: d, as: UTF8.self)).tokens }

    // MARK: Ledger

    /// `Application Support/C2D Terminal/token-saver/engine.tsv` (or the debug override).
    public static func ledgerURL() -> URL? {
        try? JSONDocumentStore.applicationSupport(subdirectory: "token-saver").directory.appendingPathComponent("engine.tsv")
    }

    struct LedgerRow: Equatable { var rawBytes, shownBytes, rawTokens, shownTokens: Int }

    /// One `O_APPEND` write per row, so concurrent runners never interleave inside a line.
    static func record(_ r: LedgerRow, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(Int(Date().timeIntervalSince1970))\t\(r.rawBytes)\t\(r.shownBytes)\t\(r.rawTokens)\t\(r.shownTokens)\n"
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    public struct Totals: Hashable, Sendable {
        public var commands = 0, rawBytes = 0, shownBytes = 0, rawTokens = 0, shownTokens = 0
        public var savedTokens: Int { rawTokens - shownTokens }
        public init() {}
    }

    /// Sum of every ledger row; malformed lines are skipped.
    public static func totals(ledger: URL? = ledgerURL()) -> Totals {
        var t = Totals()
        guard let ledger, let text = try? String(contentsOf: ledger, encoding: .utf8) else { return t }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t").compactMap { Int($0) }
            guard f.count == 5 else { continue }
            t.commands += 1; t.rawBytes += f[1]; t.shownBytes += f[2]; t.rawTokens += f[3]; t.shownTokens += f[4]
        }
        return t
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
