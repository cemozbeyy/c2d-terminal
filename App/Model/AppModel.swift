import AppKit
import C2DCore
import Foundation
import Observation

struct UserMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

enum Destination: String, CaseIterable, Identifiable {
    case projects, workspace, agents, tasks, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .projects: "Projects"
        case .workspace: "Workspace"
        case .agents: "Agents"
        case .tasks: "Tasks"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .projects: "folder"
        case .workspace: "rectangle.3.group"
        case .agents: "cpu"
        case .tasks: "checklist"
        case .settings: "gearshape"
        }
    }
}

/// Root application state. Owns the stores and the active workspace.
@MainActor
@Observable
final class AppModel {
    /// Panel kinds this build can actually host. Presets and restoration degrade to these.
    static let availableKinds: Set<PanelKind> = [.terminal, .projectExplorer, .editor, .gitChanges, .agentSession, .tasks, .tokenOptimizer]

    private(set) var registry: ProjectRegistry
    let layoutStore: LayoutStore?
    private(set) var sessions: TerminalSessionRegistry
    private(set) var agentSessions: AgentSessionRegistry
    let taskStore: TaskStore?
    let optimizationStore: OptimizationStore?
    private(set) var entitlement = Entitlement()
    private(set) var providerStatuses: [String: AgentProviderStatus] = [:]
    private(set) var providerPaths: [String: String] = [:]
    private(set) var providersRefreshedAt: Date?
    private(set) var workspace: WorkspaceController?
    var destination: Destination = .projects
    var paletteVisible = false
    /// Pre-filled palette text for ⌘L (":") and ⇧⌘F ("/"); consumed when the palette appears.
    var paletteInitialQuery: String?

    func showPalette(prefill: String? = nil) { paletteInitialQuery = prefill; paletteVisible = true }
    /// Developer Mode reveals technical detail; it never changes behaviour (Bible Part 2 §11).
    var developerMode: Bool = UserDefaults.standard.bool(forKey: "developerMode") {
        didSet { UserDefaults.standard.set(developerMode, forKey: "developerMode") }
    }
    var messages: [UserMessage] = []
    let diagnostics = DiagnosticsReport.current()
    /// Set when a store could not be opened; the app then runs without persistence and says so.
    private(set) var persistenceUnavailable: String?

    init() {
        var unavailable: String?
        var store: JSONDocumentStore?
        do { store = try JSONDocumentStore.applicationSupport() } catch { unavailable = "\(error)" }
        registry = (try? ProjectRegistry(store: store)) ?? (try! ProjectRegistry(store: nil))
        layoutStore = (try? LayoutStore.standard())
        sessions = (try? TerminalSessionRegistry(store: store)) ?? (try! TerminalSessionRegistry(store: nil))
        agentSessions = (try? AgentSessionRegistry(store: store)) ?? (try! AgentSessionRegistry(store: nil))
        taskStore = (try? TaskStore(path: TaskStore.standardPath())) ?? (try? TaskStore.inMemory())
        optimizationStore = (try? OptimizationStore(path: OptimizationStore.standardPath())) ?? (try? OptimizationStore.inMemory())
        // No entitlement document is read: until a billing provider exists (DEF-15) there is no
        // trustworthy source, and a hand-edited file must not unlock Premium (ADR-016).
        #if DEBUG
        // `-c2dPremium YES` simulates a premium entitlement for development only; no billing exists.
        if UserDefaults.standard.bool(forKey: "c2dPremium") { entitlement = Entitlement(state: .premium, source: "developer override (Debug build)") }
        #endif
        persistenceUnavailable = unavailable
        if unavailable != nil {
            messages.append(UserMessage(title: "Persistence unavailable", detail: "Settings and layouts will not be saved this session."))
        }
        Log.app.info("app model ready, projects=\(self.registry.projects.count, privacy: .public)")
        // `-c2dOpenProject <path>` (launch argument / defaults) opens a project at startup; used by
        // automated runtime checks and handy for development. Only directories are accepted.
        if let launchPath = UserDefaults.standard.string(forKey: "c2dOpenProject") {
            openProject(at: URL(fileURLWithPath: launchPath))
        } else if let active = registry.activeProject, active.isAvailable {
            openWorkspace(for: active)
        }
        #if DEBUG
        // `-c2dQuitAfter <seconds>` quits through the normal NSApplication path after a delay (runtime checks).
        let secs = UserDefaults.standard.double(forKey: "c2dQuitAfter"); if secs > 0 {
            Task { try? await Task.sleep(for: .seconds(secs)); debugTrace("c2dQuitAfter firing"); await MainActor.run { NSApplication.shared.terminate(nil) } }
        }
        // `-c2dApplyPreset <development|multiAgent|terminalFocus|codeReview>`; `-c2dGitSelect <relative path>`
        // selects a changed file in the Git panel; `-c2dGitStageAllAndCommit "<msg>"` exercises the commit path.
        if let presetName = UserDefaults.standard.string(forKey: "c2dApplyPreset"), let preset = LayoutPreset(rawValue: presetName) {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.workspace?.apply(preset)
            }
        }
        if let rel = UserDefaults.standard.string(forKey: "c2dGitSelect") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let git = self?.workspace?.git else { return }
                await git.refresh()
                await git.select(path: rel, staged: false)
                debugTrace("c2dGitSelect: \(rel) hunks=\(git.selectedDiff.reduce(0) { $0 + $1.hunks.count })")
                if let msg = UserDefaults.standard.string(forKey: "c2dGitStageAllAndCommit") {
                    await git.stageAll()
                    git.commitMessage = msg
                    await git.commit()
                    debugTrace("c2dGitStageAllAndCommit: hash=\(git.lastCommitHash ?? "none") error=\(git.lastError ?? "none")")
                }
            }
        }
        // `-c2dOptimizerDemo YES` builds a payload from the open editor files twice (to create an exact
        // duplicate), optimizes, and records — exercising the premium path under the developer override.
        if UserDefaults.standard.bool(forKey: "c2dOptimizerDemo") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let ws = self?.workspace else { return }
                ws.showOptimizerPanel()
                let o = ws.optimizer
                o.addOpenEditorFiles(ws); o.addOpenEditorFiles(ws)
                o.add(ContextItem(kind: .instructions, content: "Keep the public API unchanged.", mandatory: true))
                o.measureOnly()
                o.optimize()
                await o.recordResult()
                debugTrace("c2dOptimizerDemo: items=\(o.items.count) before=\(o.result?.before.tokens ?? -1) after=\(o.result?.after.tokens ?? -1) label=\(o.report?.label ?? "none") history=\(o.history.count) error=\(o.lastError ?? "none")")
            }
        }
        // `-c2dPaletteQuery "<text>"` opens the palette with a query and prints the matching commands.
        if let q = UserDefaults.standard.string(forKey: "c2dPaletteQuery") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.showPalette(prefill: q)
                var cmds = CommandCatalog.commands(model: self, query: q)
                if q.hasPrefix("/"), let root = self.workspace?.projectPath {
                    cmds = CommandCatalog.matchCommands(CommandCatalog.searchContent(root: root, query: String(q.dropFirst())), model: self)
                } else if !CommandCatalog.isPrefixed(q) {
                    cmds = cmds.filter { $0.title.lowercased().contains(q.lowercased()) || ($0.subtitle?.lowercased().contains(q.lowercased()) ?? false) }
                }
                debugTrace("c2dPaletteQuery '\(q)': \(cmds.map { "[\($0.kind.rawValue)] \($0.title)" }.joined(separator: " | "))")
                // `-c2dPaletteRunFirst YES` executes the first result and reports the editor caret afterwards.
                if UserDefaults.standard.bool(forKey: "c2dPaletteRunFirst"), let first = cmds.first {
                    self.paletteVisible = false
                    first.run()
                    try? await Task.sleep(for: .milliseconds(800))
                    let tab = self.workspace?.editors.values.compactMap(\.activeTab).first
                    debugTrace("c2dPaletteRunFirst: ran '\(first.title)' → tab=\(tab?.name ?? "none") line=\(tab?.cursorLine ?? 0) pending=\(String(describing: tab?.pendingLine))")
                }
            }
        }
        // `-c2dCreateTask "<title>"` creates a task and moves it to Ready (runtime checks).
        if let title = UserDefaults.standard.string(forKey: "c2dCreateTask") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let ws = self?.workspace else { return }
                if let t = await ws.tasks.create(title: title) {
                    await ws.tasks.transition(t, to: .ready)
                    debugTrace("c2dCreateTask: id=\(t.id) tasks=\(ws.tasks.tasks.count) events=\(ws.tasks.events.count) error=\(ws.tasks.lastError ?? "none")")
                }
            }
        }
        // `-c2dLaunchAgent <provider-id>` starts the provider interactively (no prompt, so no model call)
        // in the project root; runtime checks use it to prove the managed-session path.
        if let providerID = UserDefaults.standard.string(forKey: "c2dLaunchAgent") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, let ws = self.workspace else { return }
                await self.refreshProviders()
                guard let provider = AgentProvider.builtIn.first(where: { $0.id == providerID }), let path = self.providerPaths[providerID] else {
                    debugTrace("c2dLaunchAgent: provider not ready \(String(describing: self.providerStatuses[providerID]))"); return
                }
                do {
                    let plan = try AgentLaunchPlan.make(provider: provider, executablePath: path, projectPath: ws.projectPath, workingDirectory: ws.projectPath, task: nil)
                    ws.launchAgent(plan)
                    debugTrace("c2dLaunchAgent: launched \(plan.executable) \(plan.arguments)")
                } catch { debugTrace("c2dLaunchAgent: \(error)") }
            }
        }
        // `-c2dOpenFile <path>` opens a file in the editor; `-c2dEditorAppendAndSave "<text>"` appends to the
        // active tab and saves — the controller path that a keyboard edit + ⌘S takes.
        if let file = UserDefaults.standard.string(forKey: "c2dOpenFile") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                self?.workspace?.openFile(path: file)
                if let text = UserDefaults.standard.string(forKey: "c2dEditorAppendAndSave") {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let ws = self?.workspace, let e = ws.editors.values.first(where: { $0.activeTab != nil }), let tab = e.activeTab else { return }
                    tab.update(text: tab.text + text)
                    e.saveActive()
                    debugTrace("c2dEditorAppendAndSave: dirty=\(tab.isDirty) error=\(e.lastError ?? "none")")
                }
            }
        }
        // `-c2dHiddenPanelCheck setup|cleanup` exercises "Remove empty and ended hidden panels".
        // setup: hides a running terminal, an exited terminal, an editor with a tab, an empty editor and a
        // Git panel, then cleans up. cleanup (next launch): cleans the restored hidden list, where the editor
        // with a tab has no controller yet and the terminal ended with the previous run.
        if let mode = UserDefaults.standard.string(forKey: "c2dHiddenPanelCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace else { return }
                @MainActor func describe(_ tag: String) {
                    let items = ws.layout.hidden.map { id -> String in
                        let kind = ws.layout.panels[id]?.kind.rawValue ?? "?"
                        var st = ""
                        if let t = ws.terminals[id] { st = t.isRunning ? "running" : "ended" }
                        else if let r = self.sessions.record(forPanel: id) { st = "record:\(r.lifecycle)" }
                        if let e = ws.editors[id] { st = "tabs=\(e.tabs.count)" }
                        return "\(id.rawValue.prefix(6)):\(kind)[\(st)]"
                    }
                    debugTrace("hiddenPanelCheck \(tag): hidden=\(items) visible=\(ws.layout.visiblePanelIDs.count) panels=\(ws.layout.panels.count)")
                }
                if mode == "setup" {
                    // A restored layout shows last run's ended shell instead of respawning, so start two fresh ones.
                    ws.newTerminal(); ws.newTerminal()
                    for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(200)); if ws.terminals.values.filter({ $0.isRunning }).count >= 2 { break } }
                    let live = ws.terminals.values.filter { $0.isRunning }
                    guard live.count >= 2 else { debugTrace("hiddenPanelCheck: shells never ran (\(live.count))"); return }
                    let running = live[0], ended = live[1]
                    ended.write(Data("exit\n".utf8))
                    for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(200)); if !ended.isRunning { break } }
                    ws.openFile(path: ws.projectPath + "/src/a.swift")
                    let withTab = ws.layout.visiblePanelIDs.first { ws.layout.panels[$0]?.kind == .editor }!
                    let emptyEditor = ws.addPanel(.editor, title: "Editor")
                    let git = ws.addPanel(.gitChanges, title: "Changes")
                    for id in [running.panelID, ended.panelID, withTab, emptyEditor, git] { ws.hide(id) }
                    describe("before")
                    ws.cleanUpHiddenPanels()
                    try? await Task.sleep(for: .milliseconds(300))
                    describe("after")
                    let pid = running.record?.pid ?? -1
                    let gone = [ended.panelID, emptyEditor, git].allSatisfy { ws.layout.panels[$0] == nil && ws.terminals[$0] == nil && ws.editors[$0] == nil }
                    debugTrace("hiddenPanelCheck verdict: runningKept=\(ws.layout.hidden.contains(running.panelID) && running.isRunning && kill(pid, 0) == 0) tabKept=\(ws.layout.hidden.contains(withTab) && ws.editors[withTab]?.tabs.count == 1) removed=\(gone)")
                } else {
                    describe("before")
                    let editorsBefore = ws.editors.count
                    ws.cleanUpHiddenPanels()
                    try? await Task.sleep(for: .milliseconds(300))
                    describe("after")
                    let survivors = ws.layout.hidden.compactMap { ws.layout.panels[$0]?.kind.rawValue }
                    debugTrace("hiddenPanelCheck verdict: editorsBefore=\(editorsBefore) survivors=\(survivors) tabs=\(ws.layout.hidden.compactMap { ws.editors[$0]?.tabs.count })")
                }
            }
        }
        // `-c2dNewTerminal YES` starts a fresh shell (a restored layout shows last run's ended one).
        if UserDefaults.standard.bool(forKey: "c2dNewTerminal") {
            Task { [weak self] in try? await Task.sleep(for: .milliseconds(500)); self?.workspace?.newTerminal() }
        }
        // `-c2dRunCommand "<line>"` types one line into the first terminal once its shell is running.
        // Debug builds only; exists so runtime checks can exercise the input path without a keyboard.
        if let line = UserDefaults.standard.string(forKey: "c2dRunCommand") {
            Task { [weak self] in
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let ws = self.workspace else { return }
                    if let t = ws.terminals.values.first(where: { $0.isRunning }) {
                        t.write(Data((line + "\n").utf8))
                        Log.app.info("c2dRunCommand delivered")
                        try? await Task.sleep(for: .seconds(4))
                        debugTrace("c2dRunCommand context: dir=\(t.displayDirectory ?? "nil") fg=\(t.context?.foregroundCommand ?? "nil")")
                        return
                    }
                }
            }
        }
        #endif
    }

    func report(_ title: String, _ detail: String) {
        Log.app.error("\(title, privacy: .public): \(detail, privacy: .public)")
        messages.append(UserMessage(title: title, detail: detail))
    }

    func dismiss(_ message: UserMessage) {
        messages.removeAll { $0.id == message.id }
    }

    // MARK: Projects

    func openProject(at url: URL) {
        do {
            let project = try registry.open(path: url.path)
            openWorkspace(for: project)
        } catch {
            report("Could not open project", "\(url.path): \(error)")
        }
    }

    func openProject(_ project: Project) {
        guard project.isAvailable else {
            report("Project folder not found", "\(project.path) is missing or unreadable. Locate it again or remove the entry.")
            return
        }
        openProject(at: URL(fileURLWithPath: project.path))
    }

    func relocateProject(_ project: Project, to url: URL) {
        do {
            let moved = try registry.relocate(project, to: url.path)
            openWorkspace(for: moved)
        } catch {
            report("Could not relocate project", "\(error)")
        }
    }

    func removeProject(_ project: Project) {
        do {
            try registry.remove(project)
            if workspace?.projectPath == project.path { closeWorkspace() }
        } catch {
            report("Could not update recent projects", "\(error)")
        }
    }

    func setPinned(_ pinned: Bool, _ project: Project) {
        do { try registry.setPinned(pinned, project) } catch { report("Could not update recent projects", "\(error)") }
    }

    // MARK: Workspace

    private func openWorkspace(for project: Project) {
        if let current = workspace, current.projectPath == project.path {
            destination = .workspace
            return
        }
        // Switching projects must not kill sessions of the previous workspace silently (Bible §2.3).
        // Interim policy: previous workspace is detached and its sessions keep running until the
        // panel is closed or the app quits; its panels are no longer visible. Recorded in PROGRESS.md.
        workspace?.flushSave()
        var layout: WorkspaceLayout
        var restored = false
        do {
            if let saved = try layoutStore?.load(forProjectPath: project.path) {
                layout = saved; restored = true
            } else if let global = try layoutStore?.loadGlobalDefault() {
                layout = global; layout.id = UUID().uuidString; layout.isBuiltIn = false; restored = true
            } else {
                layout = LayoutPreset.development.makeLayout(available: Self.availableKinds)
            }
        } catch {
            report("Saved layout could not be read", "Using the default layout. \(error)")
            layout = LayoutPreset.development.makeLayout(available: Self.availableKinds)
        }
        let affected = layout.recover(availableKinds: Self.availableKinds)
        if !affected.isEmpty {
            report("Layout contained unavailable panels", "\(affected.count) panel(s) kept as placeholders; remove or replace them.")
        }
        workspace = WorkspaceController(layout: layout, projectPath: project.path, app: self, restoredFromDisk: restored)
        destination = .workspace
    }

    func closeWorkspace() {
        workspace?.flushSave()
        workspace = nil
        destination = .projects
    }

    // MARK: Sessions registry (called by terminal controllers)

    func registerSession(_ record: TerminalSessionRecord) {
        do { try sessions.register(record) } catch { Log.pty.error("session registry write failed: \(error, privacy: .public)") }
    }

    func updateSession(_ id: String, _ change: (inout TerminalSessionRecord) -> Void) {
        do { try sessions.update(id, change) } catch { Log.pty.error("session registry write failed: \(error, privacy: .public)") }
    }

    // MARK: Agents

    func registerAgentSession(_ record: AgentSessionRecord) {
        do { try agentSessions.register(record) } catch { Log.agents.error("agent registry write failed: \(error, privacy: .public)") }
    }

    func updateAgentSession(_ id: String, _ change: (inout AgentSessionRecord) -> Void) {
        do { try agentSessions.update(id, change) } catch { Log.agents.error("agent registry write failed: \(error, privacy: .public)") }
    }

    /// Probes each built-in provider (`--version`); "exists" and "ready" stay distinct (Bible Part 7 §4).
    func refreshProviders() async {
        for provider in AgentProvider.builtIn {
            let status = await AgentDiscovery.status(of: provider)
            providerStatuses[provider.id] = status
            if case .available(let path, _) = status { providerPaths[provider.id] = path } else { providerPaths[provider.id] = nil }
        }
        providersRefreshedAt = Date()
    }

    /// Terminates every live session; called on quit. Returns once all exits were observed or the timeout passed.
    func shutdown() async {
        debugTrace("shutdown: terminating \(workspace?.terminals.count ?? 0) terminal(s)")
        await workspace?.terminateAllSessions()
        debugTrace("shutdown: all sessions ended")
    }
}
