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
    case projects, workspace, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .projects: "Projects"
        case .workspace: "Workspace"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .projects: "folder"
        case .workspace: "rectangle.3.group"
        case .settings: "gearshape"
        }
    }
}

/// Root application state. Owns the stores and the active workspace.
@MainActor
@Observable
final class AppModel {
    /// Panel kinds this build can actually host. Presets and restoration degrade to these.
    static let availableKinds: Set<PanelKind> = [.terminal, .projectExplorer, .editor]

    private(set) var registry: ProjectRegistry
    let layoutStore: LayoutStore?
    private(set) var sessions: TerminalSessionRegistry
    private(set) var workspace: WorkspaceController?
    var destination: Destination = .projects
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

    /// Terminates every live session; called on quit. Returns once all exits were observed or the timeout passed.
    func shutdown() async {
        debugTrace("shutdown: terminating \(workspace?.terminals.count ?? 0) terminal(s)")
        await workspace?.terminateAllSessions()
        debugTrace("shutdown: all sessions ended")
    }
}
