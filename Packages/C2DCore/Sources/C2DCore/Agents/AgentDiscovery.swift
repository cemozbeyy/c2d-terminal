import Foundation

/// Finds provider executables and checks they answer `--version`. A GUI app's PATH is not the
/// user's shell PATH, so the login shell's PATH is consulted too (Bible Part 7 §4).
public enum AgentDiscovery {
    private static let loginPathCache = LoginPathCache()

    public static let defaultExtraSearchPaths = [
        NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
    ]

    /// Absolute path of the first runnable executable, or nil.
    public static func locate(_ provider: AgentProvider, extraSearchPaths: [String] = defaultExtraSearchPaths) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += loginShellPath().split(separator: ":").map(String.init)
        dirs += extraSearchPaths
        var seen = Set<String>()
        for dir in dirs where seen.insert(dir).inserted {
            for name in provider.executableNames {
                let candidate = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue, access(candidate, X_OK) == 0 {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Runs `<exe> --version` (10 s timeout). Exit 0 → available; nonzero → setup required;
    /// missing executable → unavailable.
    public static func status(of provider: AgentProvider, extraSearchPaths: [String] = defaultExtraSearchPaths) async -> AgentProviderStatus {
        // `locate` may run the login shell once; keep that off the caller's (main) thread.
        let located = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: locate(provider, extraSearchPaths: extraSearchPaths)) }
        }
        guard let path = located else { return .unavailable }
        let result = await run(path, provider.versionArguments, timeout: 10)
        switch result {
        case .success(let output):
            let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let version = line.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map { String(line[$0]) }
            Log.agents.info("provider \(provider.id, privacy: .public) available version=\(version ?? "?", privacy: .public)")
            return .available(path: path, version: version)
        case .failure(let reason):
            Log.agents.notice("provider \(provider.id, privacy: .public) setup required")
            return .setupRequired(reason: reason)
        }
    }

    /// PATH as the user's login shell sees it. Computed once per process; empty on failure.
    public static func loginShellPath() -> String {
        loginPathCache.value {
            guard let shell = try? PTYSessionConfiguration.loginShell() else { return "" }
            // Non-interactive login shell: dotfiles run, no prompt, no TTY needed.
            let result = runSync(shell, ["-l", "-c", "printf %s \"$PATH\""], timeout: 8)
            if case .success(let out) = result { return out.trimmingCharacters(in: .whitespacesAndNewlines) }
            return ""
        }
    }

    enum RunResult { case success(String), failure(String) }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> RunResult {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: runSync(executable, arguments, timeout: timeout)) }
        }
    }

    /// Argument arrays only, PATH/HOME environment, stdin from /dev/null, hard kill on timeout.
    /// Waits by polling, never via `waitUntilExit`: that spins the caller's run loop, and on the main
    /// thread a spun run loop re-enters SwiftUI mid-update (the 2026-10-19 launch hang).
    static func runSync(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var env: [String: String] = [:]
        env["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        env["HOME"] = NSHomeDirectory()
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure("launch failed: \(error.localizedDescription)") }
        let outData = out.fileHandleForReading.readToEndInBackground()
        let errData = err.fileHandleForReading.readToEndInBackground()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning {
            p.terminate()
            let killAt = Date().addingTimeInterval(1)
            while p.isRunning { if Date() > killAt { kill(p.processIdentifier, SIGKILL) }; Thread.sleep(forTimeInterval: 0.02) }
            return .failure("timed out after \(Int(timeout)) s")
        }
        let stdout = String(decoding: outData.wait(), as: UTF8.self)
        let stderr = String(decoding: errData.wait(), as: UTF8.self)
        if p.terminationStatus == 0 { return .success(stdout.isEmpty ? stderr : stdout) }
        let reason = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure("exit \(p.terminationStatus)\(reason.isEmpty ? "" : ": " + reason.prefix(300))")
    }
}

/// Process-lifetime cache for one string.
private final class LoginPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: String?
    func value(_ compute: () -> String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let v = compute(); cached = v; return v
    }
}

/// Drains a pipe on a background thread so a chatty child cannot deadlock the parent.
private extension FileHandle {
    final class Drain: @unchecked Sendable {
        private let group = DispatchGroup()
        private var data = Data()
        init(_ fh: FileHandle) {
            group.enter()
            DispatchQueue.global(qos: .utility).async { self.data = fh.readDataToEndOfFile(); self.group.leave() }
        }
        func wait() -> Data { group.wait(); return data }
    }
    func readToEndInBackground() -> Drain { Drain(self) }
}
