import Foundation
import Testing
@testable import C2DCore

@Suite struct AgentDescriptorTests {
    @Test func builtInProvidersAreHonest() {
        let ids = AgentProvider.builtIn.map(\.id)
        #expect(ids == ["claude-code", "codex"])
        let claude = AgentProvider.claudeCode
        #expect(claude.capabilities.interactiveTerminal && claude.capabilities.initialPromptArgument)
        #expect(!claude.capabilities.sessionResume && !claude.capabilities.structuredEvents && !claude.capabilities.permissionPrompts && !claude.capabilities.usageReporting)
        #expect(claude.launchArguments(task: nil) == [])
        #expect(claude.launchArguments(task: "fix the bug") == ["fix the bug"])
        let codex = AgentProvider.codex
        #expect(!codex.capabilities.initialPromptArgument)
        #expect(codex.launchArguments(task: "anything") == [], "unverified capability must not change argv")
        #expect(codex.capabilities.notes.contains("UNVERIFIED"))
    }

    @Test func launchPlanValidates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notExec = dir.appendingPathComponent("tool.txt"); try Data("x".utf8).write(to: notExec)
        #expect(throws: AgentError.invalidWorkingDirectory("/no/such/dir")) {
            try AgentLaunchPlan.make(provider: .claudeCode, executablePath: "/bin/ls", projectPath: dir.path, workingDirectory: "/no/such/dir", task: nil)
        }
        #expect(throws: AgentError.executableNotFound("/no/such/exe")) {
            try AgentLaunchPlan.make(provider: .claudeCode, executablePath: "/no/such/exe", projectPath: dir.path, workingDirectory: dir.path, task: nil)
        }
        #expect(throws: AgentError.executableNotRunnable(notExec.path)) {
            try AgentLaunchPlan.make(provider: .claudeCode, executablePath: notExec.path, projectPath: dir.path, workingDirectory: dir.path, task: nil)
        }
        let plan = try AgentLaunchPlan.make(provider: .claudeCode, executablePath: "/bin/ls", projectPath: dir.path, workingDirectory: dir.path, task: "do it")
        // TS-2: Claude Code gets a fresh, valid `--session-id` before the prompt; the same id is kept on the plan.
        // Activity hooks come first (`--settings <json>`), pointing at this session's state file.
        #expect(plan.arguments.count == 5 && plan.arguments[0] == "--settings" && plan.arguments[2] == "--session-id" && plan.arguments[4] == "do it" && plan.environmentAdditions.isEmpty)
        #expect(UUID(uuidString: plan.arguments[3]) != nil && plan.providerSessionID == plan.arguments[3])
        #expect(plan.arguments[1].contains(AgentActivity.stateFile(sessionID: plan.arguments[3]).lastPathComponent))
        let again = try AgentLaunchPlan.make(provider: .claudeCode, executablePath: "/bin/ls", projectPath: dir.path, workingDirectory: dir.path, task: "do it")
        #expect(again.providerSessionID != plan.providerSessionID, "every launch gets its own id (the CLI refuses a reused one)")
        let codexPlan = try AgentLaunchPlan.make(provider: .codex, executablePath: "/bin/ls", projectPath: dir.path, workingDirectory: dir.path, task: "do it")
        #expect(codexPlan.arguments.isEmpty && codexPlan.providerSessionID == nil, "unverified provider: no session id, no argv change")
        #expect(plan.displaySummary.contains("Task: do it") && plan.displaySummary.contains("Claude Code"))
    }

    @Test func activityHookSettingsAreValidAndQuoteThePath() throws {
        let path = "/tmp/a dir/it's"
        let json = AgentActivity.hookSettings(stateFile: path)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try #require(obj["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop"])
        let stop = try #require(((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(stop == #"printf done > '/tmp/a dir/it'\''s'"#)
        // The command really writes where it says, through a shell, with spaces and a quote in the path.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("act \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("it's")
        let cmd = try #require(((((try JSONSerialization.jsonObject(with: Data(AgentActivity.hookSettings(stateFile: file.path).utf8)) as? [String: Any])?["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
        try p.run(); p.waitUntilExit()
        #expect(AgentActivity.read(file) == .waiting)
        try Data("garbage".utf8).write(to: file)
        #expect(AgentActivity.read(file) == nil, "unknown content is not guessed")
    }

    @Test func registryRoundTripRestartAndPanelLookup() throws {
        let store = JSONDocumentStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("c2d-agents-reg-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var registry = try AgentSessionRegistry(store: store)
        let panel = PanelID()
        var older = AgentSessionRecord(providerID: "claude-code", panelID: panel, projectPath: "/p", workingDirectory: "/p")
        older.startedAt = Date(timeIntervalSinceNow: -100)
        older.lifecycle = .exited
        let live = AgentSessionRecord(providerID: "claude-code", panelID: panel, projectPath: "/p", workingDirectory: "/p", taskSummary: "t")
        try registry.register(older)
        try registry.register(live)
        try registry.update(live.id) { $0.lifecycle = .running }
        #expect(registry.record(forPanel: panel)?.id == live.id)
        #expect(registry.records(forProject: "/p").count == 2 && registry.records(forProject: "/q").isEmpty)

        let reloaded = try AgentSessionRegistry(store: store)
        #expect(reloaded.record(live.id)?.lifecycle == .endedByRestart)
        #expect(reloaded.record(live.id)?.endedAt != nil)
        #expect(reloaded.record(older.id)?.lifecycle == .exited, "already-ended records are untouched")
        var r = reloaded
        try r.forget(older.id)
        #expect(r.records.count == 1)
    }
}

@Suite(.serialized) struct AgentDiscoveryTests {
    @Test func loginShellPathLooksLikeAPath() {
        let path = AgentDiscovery.loginShellPath()
        #expect(path.contains("/bin"), "login PATH: \(path.prefix(80))")
    }

    @Test func locateRejectsNonsense() {
        let bogus = AgentProvider(id: "x", displayName: "x", executableNames: ["c2d-no-such-agent-\(UUID().uuidString)"], capabilities: .init())
        #expect(AgentDiscovery.locate(bogus) == nil)
    }

    // Skipped (visibly) where Claude Code is not installed, e.g. CI runners.
    @Test(.enabled(if: AgentDiscovery.locate(.claudeCode) != nil, "claude not installed on this machine"))
    func locateFindsClaude() {
        let path = AgentDiscovery.locate(.claudeCode)!
        #expect(path.hasSuffix("/claude") && access(path, X_OK) == 0)
    }

    /// `runSync` must wait without spinning the caller's run loop. SwiftUI re-enters its view update from
    /// run-loop observers, and a view body that reached `waitUntilExit` recursed until the launch hung
    /// (P0, 2026-10-19). A block queued on the main run loop must still be pending afterwards.
    @Test @MainActor func runSyncDoesNotSpinTheCallersRunLoop() {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        RunLoop.main.perform { flag.fired = true }
        let result = AgentDiscovery.runSync("/bin/sh", ["-c", "exit 0"], timeout: 5)
        guard case .success = result else { Issue.record("expected success, got \(result)"); return }
        #expect(!flag.fired, "a run-loop block ran inside runSync")
        let timedOut = AgentDiscovery.runSync("/bin/sleep", ["30"], timeout: 0.3)
        guard case .failure(let reason) = timedOut, reason.hasPrefix("timed out") else { Issue.record("expected timeout, got \(timedOut)"); return }
        #expect(!flag.fired, "a run-loop block ran inside the timeout path")
    }

    @Test func statusReportsVersionAndAbsence() async {
        if case .unavailable = await AgentDiscovery.status(of: .codex) {} else {
            // Codex is not installed on the dev machine; if it ever is, this just stops being an absence check.
        }
        guard AgentDiscovery.locate(.claudeCode) != nil else { return }
        let status = await AgentDiscovery.status(of: .claudeCode)
        guard case .available(let path, let version) = status else { Issue.record("expected available, got \(status)"); return }
        #expect(path.hasSuffix("/claude"))
        #expect(version?.range(of: #"^\d+\.\d+"#, options: .regularExpression) != nil, "version: \(version ?? "nil")")
    }
}
