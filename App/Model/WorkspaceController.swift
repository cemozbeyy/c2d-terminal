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
    private(set) var lastSaveError: String?
    private(set) var lastSavedAt: Date?
    /// Panel currently being dragged; drop zones render only while this is set.
    var draggingPanel: PanelID?
    /// Panel asking for close confirmation because its session is still running.
    var closeConfirmation: PanelID?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let saveDebounce: Duration = .milliseconds(500)

    init(layout: WorkspaceLayout, projectPath: String, app: AppModel, restoredFromDisk: Bool) {
        self.layout = layout
        self.projectPath = projectPath
        self.app = app
        self.restoredFromDisk = restoredFromDisk
        scheduleSave()   // a freshly created layout must survive a quit before the first edit
    }

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
        } else {
            close(panel)
        }
    }

    func close(_ panel: PanelID) {
        closeConfirmation = nil
        if let t = terminals.removeValue(forKey: panel) {
            Task { await t.terminateAndClose() }
        }
        mutate("close") { try $0.close(panel) }
    }

    /// Applies a preset without touching sessions: existing panels become hidden, not closed.
    func apply(_ preset: LayoutPreset) {
        var next = preset.makeLayout(available: AppModel.availableKinds)
        next.id = UUID().uuidString
        next.isBuiltIn = false
        for (id, panel) in layout.panels {
            next.panels[id] = panel
            next.hidden.append(id)
        }
        layout = next
        scheduleSave()
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

    func terminateAllSessions() async {
        flushSave()
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
