import Darwin
import Foundation

/// Terminal grid dimensions in character cells. Both must be non-zero to be applied.
public struct TerminalSize: Sendable, Hashable {
    public var rows: UInt16
    public var columns: UInt16

    public init(rows: UInt16, columns: UInt16) {
        self.rows = rows
        self.columns = columns
    }
}

/// How a child process ended, as reported by `waitpid`.
public enum PTYExitStatus: Sendable, Hashable {
    case exited(code: Int32)
    case signaled(signal: Int32)
}

/// Errors raised by `PTYSession`. Carries paths and errno values only — never
/// environment values or command arguments (Bible Part 13 §9.3).
public enum PTYError: Error, Sendable, Hashable {
    case invalidExecutable(path: String)
    case invalidWorkingDirectory(path: String)
    case invalidSize
    case invalidEnvironmentKey(String)
    case ptyAllocationFailed(step: String, errno: Int32)
    case spawnFailed(errno: Int32)
    case alreadyStarted
    case notRunning
    case writeFailed(errno: Int32)
    case resizeFailed(errno: Int32)
    case loginShellUnavailable
}

/// Everything needed to start one PTY-backed process. The executable is always
/// explicit: this type never guesses a shell (Bible Part 4 §4.1).
public struct PTYSessionConfiguration: Sendable {
    /// Absolute path of the program to exec. Use `loginShell()` for the user's shell.
    public var executable: String
    /// Arguments after argv[0]. Passed as separate strings, never joined into a shell command.
    public var arguments: [String]
    /// Exact environment for the child. Nothing is inherited implicitly.
    public var environment: [String: String]
    /// Must be an existing directory. The child starts here.
    public var workingDirectory: String
    public var initialSize: TerminalSize

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectory: String,
        initialSize: TerminalSize = TerminalSize(rows: 24, columns: 80)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.initialSize = initialSize
    }

    /// The current user's login shell from the passwd database (`pw_shell`).
    public static func loginShell() throws(PTYError) -> String {
        var pw = passwd()
        var result: UnsafeMutablePointer<passwd>? = nil
        var buffer = [CChar](repeating: 0, count: 4096)
        let rc = getpwuid_r(getuid(), &pw, &buffer, buffer.count, &result)
        guard rc == 0, result != nil, let shell = pw.pw_shell, shell.pointee != 0 else {
            throw PTYError.loginShellUnavailable
        }
        return String(cString: shell)
    }

    /// This process's environment plus `TERM`, for callers that want to pass it through.
    ///
    /// Caveat (Bible Part 4 §4.3): an app launched from Finder or the Dock does **not**
    /// have the user's login-shell environment (PATH, exports from dotfiles). The
    /// child shell builds that itself when started as a login/interactive shell.
    /// Never log the result; it may contain credentials.
    public static func inheritedEnvironment(term: String = "xterm-256color") -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = term
        return env
    }

    /// Checks everything that can be checked without spawning. Deterministic; no side effects.
    public func validate() throws(PTYError) {
        guard initialSize.rows > 0, initialSize.columns > 0 else { throw PTYError.invalidSize }
        guard executable.hasPrefix("/"), access(executable, X_OK) == 0 else {
            throw PTYError.invalidExecutable(path: executable)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDir), isDir.boolValue,
              access(workingDirectory, X_OK) == 0 else {
            throw PTYError.invalidWorkingDirectory(path: workingDirectory)
        }
        for key in environment.keys where key.isEmpty || key.contains("=") || key.contains("\0") {
            throw PTYError.invalidEnvironmentKey(key)
        }
    }
}
