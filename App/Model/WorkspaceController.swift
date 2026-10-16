import C2DCore
import Foundation
import Observation

/// Owns the live layout for one project, the panel controllers, and debounced persistence.
/// Layout state and session state stay separate (Bible Part 3 §1).
@MainActor
@Observable
final class WorkspaceController {
    private(set) var layout: WorkspaceLayout
    let projectPath: String
    let restoredFromDisk: Bool
    private(set) var terminals: [PanelID: TerminalPanelController] = [:]
    private(set) var editors: [PanelID: EditorPanelController] = [:]
    let explorer: ExplorerController
    let git: GitController
    let tasks: TaskController
    let optimizer: OptimizerController
    unowned let app: AppModel
    @ObservationIgnored private var watcher: FileWatcher?
    private(set) var lastSaveError: String?
    private(set) var lastSavedAt: Date?
    /// Panel currently being dragged; drop zones render only while this is set.
    var draggingPanel: PanelID?
    /// Panel asking for close confirmation because its session is still running.
    var closeConfirmation: PanelID?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let saveDebounce: Duration = .milliseconds(500)

    init(layout: WorkspaceLayout, projectPath: String, app: AppModel, restoredFromDisk: Bool) {
        self.layout = layout
        self.projectPath = projectPath
        self.app = app
        self.restoredFromDisk = restoredFromDisk
        self.explorer = ExplorerController(rootPath: projectPath)
        self.git = GitController(projectPath: projectPath)
        self.tasks = TaskController(projectPath: projectPath, store: app.taskStore, app: app)
        self.optimizer = OptimizerController(projectPath: projectPath, store: app.optimizationStore, app: app)
        scheduleSave()   // a freshly created layout must survive a quit before the first edit
        do {
            watcher = try FileWatcher(root: projectPath) { [weak self] paths in
                Task { @MainActor in self?.filesChanged(paths) }
            }
        } catch {
            app.report("File watching unavailable", "Explorer and editor will not notice external changes automatically. \(error)")
        }
    }

    private func filesChanged(_ paths: [String]) {
        explorer.filesChanged(paths)
        for e in editors.values { e.filesChanged(paths) }
        git.scheduleRefresh()
    }

    // MARK: Editor

    func editor(for panel: PanelID) -> EditorPanelController {
        if let e = editors[panel] { return e }
        let e = EditorPanelController(panelID: panel, projectPath: projectPath, app: app)
        editors[panel] = e
        return e
    }

    /// Opens in the active editor panel, or creates one beside the first group (Bible Part 5 §3.3).
    func openFile(path: String) {
        let target: PanelID
        if let visible = layout.visiblePanelIDs.first(where: { layout.panels[$0]?.kind == .editor }) {
            target = visible
        } else if let hiddenEditor = layout.hidden.first(where: { layout.panels[$0]?.kind == .editor }) {
            restore(hiddenEditor); target = hiddenEditor
        } else {
            let panel = Panel(kind: .editor, title: "Editor")
            mutate("new editor") { layout in
                if let g = layout.groupIDs.first { try layout.add(panel, beside: g, edge: .right) } else {
                    layout.root = .group(id: NodeID(), panels: [panel.id], active: panel.id); layout.panels[panel.id] = panel
                }
            }
            target = panel.id
        }
        activate(target)
        editor(for: target).open(path: path)
    }

    /// Opens (or reveals) the single optimizer panel for this workspace.
    func showOptimizerPanel() {
        if let visible = layout.visiblePanelIDs.first(where: { layout.panels[$0]?.kind == .tokenOptimizer }) { activate(visible); return }
        if let hidden = layout.hidden.first(where: { layout.panels[$0]?.kind == .tokenOptimizer }) { restore(hidden); return }
        let panel = Panel(kind: .tokenOptimizer, title: "Token Optimizer")
        mutate("open optimizer") { layout in
            if let g = layout.groupIDs.last { try layout.add(panel, beside: g, edge: .right) } else {
                layout.root = .group(id: NodeID(), panels: [panel.id], active: panel.id); layout.panels[panel.id] = panel
            }
        }
    }

    func fileRenamed(from old: String, to new: String) {
        for e in editors.values {
            if let tab = e.tabs.first(where: { $0.path == old }) { e.close(tab); e.open(path: new) }
        }
    }

    func saveActiveEditor() {
        editors.values.first { $0.activeTab != nil }?.saveActive()
    }

    var hasUnsavedEditors: Bool { editors.values.contains { $0.hasUnsavedChanges } }

    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }

    // MARK: Layout mutations

    private func mutate(_ what: String, _ body: (inout WorkspaceLayout) throws -> Void) {
        do {
            try body(&layout)
            scheduleSave()
        } catch {
            app.report("Layout operation failed", "\(what): \(error)")
        }
    }

    func newTerminal(in group: NodeID? = nil, beside: NodeID? = nil, edge: DockEdge = .right) {
        let panel = Panel(kind: .terminal, title: "Terminal")
        mutate("new terminal") { layout in
            if let beside {
                try layout.add(panel, beside: beside, edge: edge)
            } else if let group = group ?? layout.groupIDs.first {
                try layout.add(panel, to: group)
            } else {
                layout.root = .group(id: NodeID(), panels: [panel.id], active: panel.id)
                layout.panels[panel.id] = panel
            }
        }
        _ = terminal(for: panel.id, autoStart: true)
    }

    func activate(_ panel: PanelID) { mutate("activate") { try $0.activate(panel) } }
    func hide(_ panel: PanelID) { mutate("hide") { try $0.hide(panel) } }
    func restore(_ panel: PanelID) { mutate("restore") { try $0.restore(panel) } }
    func maximize(_ group: NodeID) { mutate("focus mode") { try $0.maximize(group) } }
    func exitFocusMode() { mutate("exit focus mode") { $0.exitFocusMode() } }
    func setWeights(_ weights: [Double], of split: NodeID) { mutate("resize") { try $0.setWeights(weights, of: split) } }

    func move(_ panel: PanelID, toGroup group: NodeID, index: Int? = nil) {
        mutate("move") { try $0.move(panel, toGroup: group, index: index) }
    }

    func move(_ panel: PanelID, beside group: NodeID, edge: DockEdge) {
        mutate("dock") { try $0.move(panel, beside: group, edge: edge) }
    }

    /// Closing a panel whose session is running asks first; closing never silently kills (Bible Part 3 §7.3).
    func requestClose(_ panel: PanelID) {
        if let t = terminals[panel], t.isRunning {
            closeConfirmation = panel
        } else if let e = editors[panel], e.hasUnsavedChanges {
            app.report("Unsaved changes", "Save or discard the open files in this editor before closing the panel.")
        } else {
            close(panel)
        }
    }

    func close(_ panel: PanelID) {
        closeConfirmation = nil
        if let t = terminals.removeValue(forKey: panel) {
            Task { await t.terminateAndClose() }
        }
        editors.removeValue(forKey: panel)
        mutate("close") { try $0.close(panel) }
    }

    /// Applies a preset without touching sessions: panels that hold state (a live or ended session,
    /// open files) become hidden; empty ones are closed so the hidden list does not pile up.
    func apply(_ preset: LayoutPreset) {
        var next = preset.makeLayout(available: AppModel.availableKinds)
        next.id = UUID().uuidString
        next.isBuiltIn = false
        for (id, panel) in layout.panels {
            if hasState(id, panel) {
                next.panels[id] = panel
                next.hidden.append(id)
            } else {
                terminals.removeValue(forKey: id)
                editors.removeValue(forKey: id)
            }
        }
        layout = next
        scheduleSave()
    }

    /// True when closing the panel would lose something the user may want (Bible Part 3 §7).
    private func hasState(_ id: PanelID, _ panel: Panel) -> Bool {
        switch panel.kind {
        case .terminal, .agentSession:
            if let t = terminals[id] { return t.isRunning || t.record != nil }
            return app.sessions.record(forPanel: id) != nil || app.agentSessions.record(forPanel: id) != nil
        case .editor:
            return !(editors[id]?.tabs.isEmpty ?? true)
        default:
            return false   // explorer, git, tasks, optimizer are stateless views over shared state
        }
    }

    /// Removes hidden panels that no longer hold state (ended sessions, empty editors, stateless views).
    func cleanUpHiddenPanels() {
        for id in layout.hidden {
            guard let panel = layout.panels[id] else { continue }
            let keep: Bool
            switch panel.kind {
            case .terminal, .agentSession: keep = terminals[id]?.isRunning ?? false
            case .editor: keep = !(editors[id]?.tabs.isEmpty ?? true)
            default: keep = false
            }
            if !keep { close(id) }
        }
    }

    // MARK: Panel content

    /// The controller for a terminal panel. A panel that never had a session starts one; a panel
    /// whose previous session ended with the last app run shows that instead of silently
    /// substituting a new shell (Bible Part 4 §11.2).
    func terminal(for panel: PanelID, autoStart: Bool = false) -> TerminalPanelController {
        if let existing = terminals[panel] { return existing }
        let previous = app.sessions.record(forPanel: panel)
        let controller = TerminalPanelController(panelID: panel, projectPath: projectPath, app: app, previousRecord: previous)
        terminals[panel] = controller
        if autoStart || previous == nil { controller.startNewSession() }
        return controller
    }

    /// Agent panel: a terminal panel bound to a launch plan. A restored agent panel never relaunches
    /// the agent by itself (re-running could duplicate work, Bible Part 7 §7).
    func agent(for panel: PanelID) -> TerminalPanelController {
        if let existing = terminals[panel] { return existing }
        let previousAgent = app.agentSessions.record(forPanel: panel)
        let previous = app.sessions.record(forPanel: panel)
        let plan = pendingAgentPlans.removeValue(forKey: panel)
        let controller = TerminalPanelController(panelID: panel, projectPath: projectPath, app: app, previousRecord: previous,
                                                 agentPlan: plan ?? previousAgent.flatMap { restoredPlan(from: $0) }, previousAgentRecord: previousAgent)
        terminals[panel] = controller
        if plan != nil { controller.startNewSession() }
        return controller
    }

    @ObservationIgnored private var pendingAgentPlans: [PanelID: AgentLaunchPlan] = [:]

    /// Creates the panel and starts the agent. The caller has already shown the pre-launch summary.
    func launchAgent(_ plan: AgentLaunchPlan, in group: NodeID? = nil, task: TaskRecord? = nil, intoPanel: PanelID? = nil) {
        let panelID: PanelID
        if let intoPanel, layout.panels[intoPanel]?.kind == .agentSession, terminals[intoPanel]?.isRunning != true {
            // Reuse an empty/ended agent panel: same panel identity, new session identity.
            terminals[intoPanel] = nil
            panelID = intoPanel
            activate(intoPanel)
        } else {
            let panel = Panel(kind: .agentSession, title: plan.provider.displayName, attributes: ["provider": plan.provider.id])
            mutate("new agent session") { layout in
                if let g = group ?? layout.groupIDs.last { try layout.add(panel, to: g) } else {
                    layout.root = .group(id: NodeID(), panels: [panel.id], active: panel.id); layout.panels[panel.id] = panel
                }
            }
            panelID = panel.id
        }
        pendingAgentPlans[panelID] = plan
        let controller = agent(for: panelID)
        // Linking is explicit user intent (the sheet was confirmed); status moves to In progress
        // because the user started work, never because the agent did something (Bible Part 8 §5).
        if let task, let agentID = controller.agentRecord?.id {
            app.updateAgentSession(agentID) { $0.taskID = task.id; $0.taskSummary = task.title }
            Task {
                await tasks.assign(task, agentSessionID: agentID)
                if task.status.canTransition(to: .inProgress) { await tasks.transition(task, to: .inProgress, note: "agent session started") }
            }
        }
    }

    /// Rebuilds a plan for "New Session" on a restored agent panel; validation happens again at launch.
    private func restoredPlan(from record: AgentSessionRecord) -> AgentLaunchPlan? {
        guard let provider = AgentProvider.builtIn.first(where: { $0.id == record.providerID }),
              let path = app.providerPaths[provider.id] ?? AgentDiscovery.locate(provider) else { return nil }
        return try? AgentLaunchPlan.make(provider: provider, executablePath: path, projectPath: projectPath, workingDirectory: record.workingDirectory, task: nil)
    }

    /// Agents currently running in a given directory, for the pre-launch warning (Bible Part 7 §5).
    func liveAgents(in directory: String) -> [TerminalPanelController] {
        terminals.values.filter { $0.agentPlan?.workingDirectory == directory && $0.isRunning }
    }

    func terminateAllSessions() async {
        flushSave()
        watcher?.stop()
        for t in terminals.values { await t.terminateAndClose() }
    }

    var hasRunningSessions: Bool { terminals.values.contains { $0.isRunning } }

    // MARK: Persistence (Bible Part 3 §10.2: debounced, honest about failure)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func flushSave() {
        saveTask?.cancel()
        saveNow()
    }

    private func saveNow() {
        guard let store = app.layoutStore else { return }
        do {
            try store.save(layout, forProjectPath: projectPath)
            lastSaveError = nil
            lastSavedAt = Date()
        } catch {
            lastSaveError = "\(error)"
            Log.app.error("layout save failed: \(error, privacy: .public)")
        }
    }

    func saveAsGlobalDefault() {
        guard let store = app.layoutStore else { return }
        do { try store.saveGlobalDefault(layout) } catch { app.report("Could not save default layout", "\(error)") }
    }
}
