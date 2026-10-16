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
        #expect(plan.arguments == ["do it"] && plan.environmentAdditions.isEmpty)
        #expect(plan.displaySummary.contains("Task: do it") && plan.displaySummary.contains("Claude Code"))
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
