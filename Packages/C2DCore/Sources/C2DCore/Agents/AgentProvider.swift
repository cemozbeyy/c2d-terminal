import Foundation

/// What a provider integration has been *verified* to support (Bible Part 7 §2). A false value
/// means "not verified or not supported"; the UI must not offer the control.
public struct AgentCapabilities: Codable, Hashable, Sendable {
    public var interactiveTerminal = false
    public var initialPromptArgument = false
    public var sessionResume = false
    public var structuredEvents = false
    public var permissionPrompts = false
    public var usageReporting = false
    public var notes = ""

    public init(interactiveTerminal: Bool = false, initialPromptArgument: Bool = false, sessionResume: Bool = false,
                structuredEvents: Bool = false, permissionPrompts: Bool = false, usageReporting: Bool = false, notes: String = "") {
        self.interactiveTerminal = interactiveTerminal
        self.initialPromptArgument = initialPromptArgument
        self.sessionResume = sessionResume
        self.structuredEvents = structuredEvents
        self.permissionPrompts = permissionPrompts
        self.usageReporting = usageReporting
        self.notes = notes
    }
}

/// A CLI coding agent C2D can launch inside one of its own PTYs. Descriptors only; discovery and
/// readiness are separate (`AgentDiscovery`), sessions are separate (`AgentSessionRegistry`).
public struct AgentProvider: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let executableNames: [String]
    public let versionArguments: [String]
    public let capabilities: AgentCapabilities

    public init(id: String, displayName: String, executableNames: [String], versionArguments: [String] = ["--version"], capabilities: AgentCapabilities) {
        self.id = id
        self.displayName = displayName
        self.executableNames = executableNames
        self.versionArguments = versionArguments
        self.capabilities = capabilities
    }

    /// Interactive session by default; the task, when given, becomes the single positional prompt
    /// argument. Passed as a separate argv element — never interpolated into a shell string.
    public func launchArguments(task: String?) -> [String] {
        guard capabilities.initialPromptArgument, let task, !task.isEmpty else { return [] }
        return [task]
    }

    /// Verified 2026-10-16 against Claude Code 2.1.301: `claude --help` prints
    /// `Usage: claude [options] [command] [prompt]`, "starts an interactive session by default",
    /// and `prompt  Your prompt` as the positional argument.
    public static let claudeCode = AgentProvider(
        id: "claude-code", displayName: "Claude Code", executableNames: ["claude"],
        capabilities: AgentCapabilities(
            interactiveTerminal: true, initialPromptArgument: true,
            notes: "Interactive TUI through the PTY only. `--resume`, `--print`, structured events, permission prompts and usage reporting exist in `claude --help` but are UNVERIFIED by C2D and not exposed; awaitingUser is never inferred because the CLI gives no structured signal."))

    /// UNVERIFIED: Codex is not installed on the development machine; the prompt argument is an
    /// assumption and must be checked before `initialPromptArgument` is turned on.
    public static let codex = AgentProvider(
        id: "codex", displayName: "Codex", executableNames: ["codex"],
        capabilities: AgentCapabilities(
            interactiveTerminal: true,
            notes: "UNVERIFIED: CLI not available on the development machine. Only a plain interactive launch is offered; prompt argument, resume, events, permissions and usage are unknown."))

    public static let builtIn: [AgentProvider] = [claudeCode, codex]
}

/// Readiness as last observed. "Executable exists" is not "ready" (Bible Part 7 §4).
public enum AgentProviderStatus: Codable, Hashable, Sendable {
    case available(path: String, version: String?)
    case setupRequired(reason: String)
    case unavailable
    case unknown
}

public enum AgentError: Error, Equatable, Sendable {
    case executableNotFound(String)
    case executableNotRunnable(String)
    case invalidWorkingDirectory(String)
}
