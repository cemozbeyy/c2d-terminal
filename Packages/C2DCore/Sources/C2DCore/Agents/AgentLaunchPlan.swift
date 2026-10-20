import Foundation

/// Everything the app needs to spawn an agent in a PTY, plus the summary shown before launch
/// (Bible Part 7 §5). C2D never injects credentials: `environmentAdditions` carries only
/// non-secret markers, and the PTY layer passes the user's environment through as-is.
public struct AgentLaunchPlan: Hashable, Sendable {
    public let provider: AgentProvider
    public let executable: String
    public let arguments: [String]
    public let projectPath: String
    public let workingDirectory: String
    public let task: String?
    public let environmentAdditions: [String: String]
    /// The session id C2D chose for this launch (passed as `--session-id`), when the provider supports
    /// one. It is the only evidence the Token Saver uses to link a transcript to this launch.
    public let providerSessionID: String?

    public static func make(provider: AgentProvider, executablePath: String, projectPath: String, workingDirectory: String, task: String?) throws -> AgentLaunchPlan {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDir), isDir.boolValue, access(workingDirectory, X_OK) == 0 else {
            throw AgentError.invalidWorkingDirectory(workingDirectory)
        }
        guard FileManager.default.fileExists(atPath: executablePath, isDirectory: &isDir), !isDir.boolValue else {
            throw AgentError.executableNotFound(executablePath)
        }
        guard access(executablePath, X_OK) == 0 else { throw AgentError.executableNotRunnable(executablePath) }
        let sessionID = provider.capabilities.explicitSessionID ? UUID().uuidString.lowercased() : nil   // fresh per launch: the CLI refuses a reused id
        let arguments = (sessionID.map { ["--session-id", $0] } ?? []) + provider.launchArguments(task: task)
        return AgentLaunchPlan(provider: provider, executable: executablePath, arguments: arguments,
                               projectPath: projectPath, workingDirectory: workingDirectory, task: task, environmentAdditions: [:],
                               providerSessionID: sessionID)
    }

    public var displaySummary: String {
        var lines = [
            "Provider: \(provider.displayName)",
            "Project: \(URL(fileURLWithPath: projectPath).lastPathComponent) (\(projectPath))",
            "Directory: \(workingDirectory)",
        ]
        if workingDirectory != projectPath { lines.append("Note: directory differs from the project root") }
        lines.append(task.map { "Task: \($0)" } ?? "Task: none (interactive session)")
        return lines.joined(separator: "\n")
    }
}
