import AppKit
import C2DCore
import Foundation
import Observation
import SwiftUI

struct UserMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

enum Destination: String, CaseIterable, Identifiable {
    case projects, workspace, sourceControl, agents, tasks, marketplace, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .projects: "Projects"
        case .workspace: "Workspace"
        case .sourceControl: "Git"
        case .agents: "Agents"
        case .tasks: "Tasks"
        case .marketplace: "Market"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .projects: "folder"
        case .workspace: "rectangle.3.group"
        case .sourceControl: "arrow.triangle.branch"
        case .agents: "cpu"
        case .tasks: "checklist"
        case .marketplace: "paintpalette"
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
    /// Bounded, redacted diagnostic buffer behind the "Export Diagnostics…" bundle (Bible Part 11 §18).
    let diagnosticsRecorder = DiagnosticsRecorder()
    private(set) var entitlement = Entitlement()
    private(set) var providerStatuses: [String: AgentProviderStatus] = [:]
    private(set) var providerPaths: [String: String] = [:]
    private(set) var providersRefreshedAt: Date?
    private(set) var workspace: WorkspaceController? { didSet { persistPages() } }
    /// Open "pages": one workspace per project, kept alive (sessions keep running) while another page
    /// is shown, so switching projects is a tab click — not a close/reopen through the Projects list.
    private(set) var openWorkspaces: [WorkspaceController] = [] { didSet { persistPages() } }

    /// Open pages (in tab order) and the visible one, restored on the next launch. Only the folders are
    /// remembered; shells don't survive a quit. A `-c2dOpenProject` launch neither restores nor overwrites them.
    private static let pagesKey = "openPagePaths", activePageKey = "activePagePath"
    private let persistsPages = UserDefaults.standard.string(forKey: "c2dOpenProject") == nil

    private func persistPages() {
        guard persistsPages else { return }
        UserDefaults.standard.set(openWorkspaces.map(\.projectPath), forKey: Self.pagesKey)
        UserDefaults.standard.set(workspace?.projectPath, forKey: Self.activePageKey)
    }

    /// Reopens last session's pages; missing folders are skipped and reported once. False when none were saved.
    private func restorePages() -> Bool {
        guard let paths = UserDefaults.standard.stringArray(forKey: Self.pagesKey), !paths.isEmpty else { return false }
        let active = UserDefaults.standard.string(forKey: Self.activePageKey)
        var missing: [String] = []
        for path in paths {
            if let project = registry.projects.first(where: { $0.path == path }), project.isAvailable { openWorkspace(for: project) }
            else { missing.append(path) }
        }
        if !missing.isEmpty { report("Some pages were not reopened", "Folder not found: \(missing.joined(separator: ", "))") }
        if let page = openWorkspaces.first(where: { $0.projectPath == active }) ?? openWorkspaces.last { showPage(page) }
        debugTrace("pages restored: \(openWorkspaces.map(\.projectPath)) visible=\(workspace?.projectPath ?? "none") missing=\(missing.count)")
        return !openWorkspaces.isEmpty
    }
    var destination: Destination = .projects
    var paletteVisible = false
    /// Pre-filled palette text for ⌘L (":") and ⇧⌘F ("/"); consumed when the palette appears.
    var paletteInitialQuery: String?

    func showPalette(prefill: String? = nil) { paletteInitialQuery = prefill; paletteVisible = true }
    /// Developer Mode reveals technical detail; it never changes behaviour (Bible Part 2 §11).
    /// Token Optimizer on/off (top-bar dropdown). On by default. The flag is the switch the owner asked
    /// for; what "on" triggers beyond the explicit-context panel is still an open decision (OPEN_DECISIONS).
    var optimizerEnabled: Bool = (UserDefaults.standard.object(forKey: "optimizerEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(optimizerEnabled, forKey: "optimizerEnabled") }
    }
    var developerMode: Bool = UserDefaults.standard.bool(forKey: "developerMode") {
        didSet { UserDefaults.standard.set(developerMode, forKey: "developerMode") }
    }
    var messages: [UserMessage] = []
    let diagnostics = DiagnosticsReport.current()
    /// Set when a store could not be opened; the app then runs without persistence and says so.
    private(set) var persistenceUnavailable: String?

    init() {
        let initClock = ContinuousClock.now
        var unavailable: String?
        var store: JSONDocumentStore?
        do { store = try JSONDocumentStore.applicationSupport() } catch { unavailable = "\(error)" }
        // Retention (Bible Part 11 §12.3): sweep orphaned atomic-write temporaries left by an
        // interrupted save/crash. Safe + idempotent; never touches documents or SQLite recovery data.
        if let store {
            let removed = store.cleanupOrphanedTemporaries()
            if !removed.isEmpty { Log.app.info("retention: removed \(removed.count, privacy: .public) orphaned temp file(s)") }
        }
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
        } else if !restorePages(), let active = registry.activeProject, active.isAvailable {
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
                // `-c2dGitStageHunk <index>` stages that unstaged hunk, then reports the resulting split.
                if UserDefaults.standard.object(forKey: "c2dGitStageHunk") != nil {
                    let idx = UserDefaults.standard.integer(forKey: "c2dGitStageHunk")
                    let hunks = git.selectedDiff.first?.hunks ?? []
                    if idx >= 0, idx < hunks.count {
                        await git.stageHunk(index: idx, hunk: hunks[idx])
                        await git.select(path: rel, staged: true)
                        let stagedHunks = git.selectedDiff.reduce(0) { $0 + $1.hunks.count }
                        await git.select(path: rel, staged: false)
                        let unstagedHunks = git.selectedDiff.reduce(0) { $0 + $1.hunks.count }
                        debugTrace("c2dGitStageHunk: idx=\(idx) staged=\(stagedHunks) unstaged=\(unstagedHunks) error=\(git.lastError ?? "none")")
                    } else {
                        debugTrace("c2dGitStageHunk: idx=\(idx) out of range (hunks=\(hunks.count))")
                    }
                }
                if let msg = UserDefaults.standard.string(forKey: "c2dGitStageAllAndCommit") {
                    await git.stageAll()
                    git.commitMessage = msg
                    await git.commit()
                    debugTrace("c2dGitStageAllAndCommit: hash=\(git.lastCommitHash ?? "none") error=\(git.lastError ?? "none")")
                }
            }
        }
        // `-c2dOptimizerDemo YES` builds a payload from the open editor files twice (to create an exact
        // duplicate), optimizes, and records.
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
                try? await Task.sleep(for: .seconds(1))   // the event is recorded asynchronously
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
        // `-c2dFocusCheck YES`: a freshly shown terminal must take keyboard focus (its view becomes the
        // window's first responder) so the user can type without clicking first.
        if UserDefaults.standard.bool(forKey: "c2dFocusCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace else { return }
                ws.newTerminal()
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(200)); if ws.terminals.values.contains(where: { $0.isRunning }) { break } }
                try? await Task.sleep(for: .milliseconds(600))
                let fr = (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.firstResponder != nil && !($0.firstResponder is NSWindow) })?.firstResponder
                let cls = fr.map { String(describing: type(of: $0)) } ?? "nil"
                let anyTerm = NSApp.windows.contains { ($0.firstResponder.map { String(describing: type(of: $0)) } ?? "").contains("TerminalView") }
                debugTrace("focusCheck: firstResponder=\(cls) isTerminalView=\(cls.contains("TerminalView")) anyWindowTerminalFR=\(anyTerm)")
            }
        }
        // `-c2dAddPanelCheck YES`: the group "+" menu adds a panel of any kind into the group as a tab.
        if UserDefaults.standard.bool(forKey: "c2dAddPanelCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace, let g = ws.layout.groupIDs.first else { debugTrace("addPanelCheck: no group"); return }
                let before = ws.layout.activePanel(in: g).flatMap { _ in ws.layout.panels.count } ?? ws.layout.panels.count
                ws.newPanel(.editor, in: g)
                ws.newPanel(.agentSession, in: g)
                ws.newPanel(.tasks, in: g)
                try? await Task.sleep(for: .milliseconds(400))
                let kinds = ws.layout.panels.values.map { $0.kind.rawValue }.sorted()
                debugTrace("addPanelCheck: panelsBefore=\(before) panelsAfter=\(ws.layout.panels.count) kinds=\(kinds)")
            }
        }
        // `-c2dGitPanelCheck YES`: the Source-Control rail entry docks a VS-Code-style changes panel on
        // the left of the workspace (file groups + per-file diff), instead of a full-screen view.
        if UserDefaults.standard.bool(forKey: "c2dGitPanelCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace else { return }
                ws.toggleGitPanel()   // docks the Source Control panel on the left of the workspace
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(250)); if ws.git.status != nil { break } }
                let docked = ws.layout.visiblePanelIDs.contains { ws.layout.panels[$0]?.kind == .gitChanges }
                let s = ws.git.status
                debugTrace("gitPanelCheck: gitPanelDocked=\(docked) available=\(ws.git.isAvailable) branch=\(s?.branch ?? "?") changed=\(s?.entries.count ?? -1) clean=\(s?.isClean ?? true)")
                // Clicking a changed file opens its diff as an editor tab (not inside the Git panel); file tabs stay.
                if let e = s?.entries.first(where: \.hasUnstagedChange) {
                    // With no editor in the layout, the first one opens as a tab beside the terminal, not a new column.
                    for id in ws.layout.visiblePanelIDs where ws.layout.panels[id]?.kind == .editor { ws.close(id) }
                    let groupsBefore = ws.layout.groupIDs.count
                    ws.openDiff()
                    let edID = ws.layout.visiblePanelIDs.first { ws.layout.panels[$0]?.kind == .editor }
                    let withTerminal = edID.flatMap { ws.layout.group(containing: $0) }.map { g in ws.layout.visiblePanelIDs.contains { ws.layout.panels[$0]?.kind == .terminal && ws.layout.group(containing: $0) == g } } ?? false
                    debugTrace("gitPanelCheck: newEditor groupsBefore=\(groupsBefore) groupsAfter=\(ws.layout.groupIDs.count) tabbedWithTerminal=\(withTerminal)")
                    ws.openFile(path: ws.git.absolutePath(e.path))
                    await ws.git.select(path: e.path, staged: false)
                    ws.openDiff()
                    let ed = ws.layout.visiblePanelIDs.first { ws.layout.panels[$0]?.kind == .editor }.map { ws.editor(for: $0) }
                    debugTrace("gitPanelCheck: diffInEditor=\(ed?.isDiffActive ?? false) hunks=\(ws.git.selectedDiff.reduce(0) { $0 + $1.hunks.count }) fileTabs=\(ed?.tabs.map(\.name) ?? [])")
                    ed?.closeDiff()
                    debugTrace("gitPanelCheck: afterClose diffTab=\(ed?.diffTabID != nil) selection=\(ws.git.selectedPath ?? "nil") active=\(ed?.activeTab?.name ?? "nil")")
                }
            }
        }
        // `-c2dGenCommitCheck <path>`: the ✨ button's pipeline (diff → agent CLI on stdin → message box)
        // against a stub executable at <path>, so the check never spends tokens on the real CLI.
        if let stub = UserDefaults.standard.string(forKey: "c2dGenCommitCheck"), !stub.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace else { return }
                await ws.git.generateCommitMessage(claudePath: stub)
                debugTrace("genCommitCheck: message=\(ws.git.commitMessage.debugDescription) error=\(ws.git.lastError ?? "nil") generating=\(ws.git.generatingMessage)")
            }
        }
        // `-c2dPagesCheck <dir>`: opening a second project adds a page instead of replacing the first;
        // switching back shows the *same* workspace object (its sessions were never torn down).
        if let other = UserDefaults.standard.string(forKey: "c2dPagesCheck"), !other.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let first = self.workspace else { return }
                first.newTerminal()   // a live shell that must survive the page switch
                try? await Task.sleep(for: .milliseconds(1500))
                let firstTerminals = first.terminals.values.filter(\.isRunning).count
                self.openProject(at: URL(fileURLWithPath: other))
                try? await Task.sleep(for: .seconds(3))   // long enough for -c2dSnapshot to show both chips
                let second = self.workspace
                let pagesAfterOpen = self.openWorkspaces.count
                self.cyclePage(by: 1)
                let backToFirst = self.workspace === first
                let stillRunning = first.terminals.values.filter(\.isRunning).count
                if let second, !UserDefaults.standard.bool(forKey: "c2dPagesKeep") { self.closePage(second) }   // keep both → quit path must cover the hidden page
                debugTrace("pagesCheck: pagesAfterOpen=\(pagesAfterOpen) secondIsNew=\(second !== first) backToFirst=\(backToFirst) terminalsBefore=\(firstTerminals) terminalsAfter=\(stillRunning) pagesAfterClose=\(self.openWorkspaces.count) current=\(self.workspace?.projectName ?? "nil")")
            }
        }
        // `-c2dLedgerCheck YES`: TS-1 usage ledger for the open project — per-session provider-reported
        // totals (deduplicated by message id), format status, unavailable files, elapsed time.
        if UserDefaults.standard.bool(forKey: "c2dLedgerCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace else { return }
                let t0 = ContinuousClock.now
                await ws.optimizer.loadLedger()
                let ms = (ContinuousClock.now - t0).components.attoseconds / 1_000_000_000_000_000 + (ContinuousClock.now - t0).components.seconds * 1000
                switch ws.optimizer.ledger {
                case .available(let l):
                    let t = l.total
                    debugTrace("ledgerCheck: sessions=\(l.sessions.count) unavailable=\(l.unavailable.count) in=\(t.inputTokens) out=\(t.outputTokens) cacheRead=\(t.cacheReadInputTokens) cacheCreate=\(t.cacheCreationInputTokens) total=\(t.total) format='\(l.formatLabel)' skipped=\(l.skippedRecords) inProgress=\(l.inProgressLines) elapsedMs=\(ms)")
                    for s in l.sessions { debugTrace("ledgerCheck: session \(s.id) msgs=\(s.messageCount) in=\(s.usage.inputTokens) out=\(s.usage.outputTokens) cacheRead=\(s.usage.cacheReadInputTokens) cacheCreate=\(s.usage.cacheCreationInputTokens) model=\(s.models.joined(separator: "|")) attribution=\(ws.optimizer.attribution[s.id].map { a -> String in switch a { case .linked(let r, let t, _, let lc): "linked(record=\(r) task=\(t ?? "none") lifecycle=\(lc.rawValue))"; case .unmatched: "unmatched"; case .ambiguous(let ids): "ambiguous(\(ids.count))" } } ?? "none")") }
                    debugTrace("ledgerCheck: launchesWithoutTranscript=\(ws.optimizer.launchesWithoutTranscript.count) agentRecordsWithSessionID=\(self.agentSessions.records(forProject: ws.projectPath).filter { $0.providerSessionID != nil }.count)")
                    for u in l.unavailable { debugTrace("ledgerCheck: unavailable \(u.id): \(u.reason)") }
                case .unavailable(let reason): debugTrace("ledgerCheck: unavailable: \(reason) elapsedMs=\(ms)")
                case .none: debugTrace("ledgerCheck: no result (optimizer off?) elapsedMs=\(ms)")
                }
            }
        }
        // `-c2dTabReuseCheck YES`: two terminal tabs in one group keep their own surface across tab
        // switches (so a terminal is never blanked when you switch to it or close its sibling).
        if UserDefaults.standard.bool(forKey: "c2dTabReuseCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace, let g = ws.layout.groupIDs.first else { debugTrace("tabReuse: no group"); return }
                ws.newPanel(.terminal, in: g); try? await Task.sleep(for: .milliseconds(500))
                guard let t1 = ws.layout.activePanel(in: g) else { debugTrace("tabReuse: no t1"); return }
                ws.newPanel(.terminal, in: g); try? await Task.sleep(for: .milliseconds(500))
                guard let t2 = ws.layout.activePanel(in: g), t2 != t1 else { debugTrace("tabReuse: no distinct t2"); return }
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(200)); if [t1, t2].allSatisfy({ ws.terminals[$0]?.isRunning == true }) { break } }
                @MainActor func idOf(_ panel: PanelID) -> String { ws.terminals[panel]?.hostedView.map { "\(ObjectIdentifier($0))" } ?? "nil" }
                ws.activate(t2); try? await Task.sleep(for: .milliseconds(700)); let id2a = idOf(t2)
                ws.activate(t1); try? await Task.sleep(for: .milliseconds(700)); let id1 = idOf(t1)
                ws.activate(t2); try? await Task.sleep(for: .milliseconds(700)); let id2b = idOf(t2)
                let reused = id2a != "nil" && id2a == id2b
                ws.close(t1); try? await Task.sleep(for: .milliseconds(700))
                let id2c = idOf(t2)
                debugTrace("tabReuse: t1Surface=\(id1 != "nil") t2a=\(id2a.suffix(8)) t2b=\(id2b.suffix(8)) reusedOnSwitch=\(reused) t2SurvivesSiblingClose=\(id2c != "nil" && id2c == id2a)")
            }
        }
        // `-c2dExplorerToggleCheck YES`: the sidebar toggle docks a file explorer when none exists and
        // hides it when visible.
        if UserDefaults.standard.bool(forKey: "c2dExplorerToggleCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace else { return }
                @MainActor func visExplorers() -> Int { ws.layout.visiblePanelIDs.filter { ws.layout.panels[$0]?.kind == .projectExplorer }.count }
                // Start from none: hide any existing explorer first.
                while visExplorers() > 0 { if let v = ws.layout.visiblePanelIDs.first(where: { ws.layout.panels[$0]?.kind == .projectExplorer }) { ws.hide(v) }; try? await Task.sleep(for: .milliseconds(200)) }
                let before = visExplorers()
                ws.toggleExplorer(); try? await Task.sleep(for: .milliseconds(300))
                let afterShow = visExplorers()
                ws.toggleExplorer(); try? await Task.sleep(for: .milliseconds(300))
                let afterHide = visExplorers()
                debugTrace("explorerToggle: before=\(before) afterShow=\(afterShow) afterHide=\(afterHide)")
            }
        }
        // `-c2dCtrlCCheck YES`: double Ctrl-C ends an idle shell but never one with a foreground command.
        if UserDefaults.standard.bool(forKey: "c2dCtrlCCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let ws = self.workspace else { return }
                ws.newTerminal(); ws.newTerminal()
                for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(200)); if ws.terminals.values.filter({ $0.isRunning }).count >= 2 { break } }
                let live = ws.terminals.values.filter { $0.isRunning && $0.agentPlan == nil }
                guard live.count >= 2 else { debugTrace("ctrlCCheck: shells never ran (\(live.count))"); return }
                let idle = live[0], busy = live[1]
                // A login shell spends its first seconds in dotfiles (child processes = "busy"); wait for the prompt.
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(250)); if live.allSatisfy({ $0.context != nil && $0.context?.foregroundCommand == nil }) { break } }
                try? await Task.sleep(for: .seconds(1))
                busy.write(Data("sleep 30\n".utf8))
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(250)); if busy.context?.foregroundCommand == "sleep" { break } }
                debugTrace("ctrlCCheck busy fg=\(busy.context?.foregroundCommand ?? "nil") idle fg=\(idle.context?.foregroundCommand ?? "nil")")
                // While a command runs, two ^C must NOT close the shell (the exit arming is busy-gated).
                _ = busy.interrupt(); try? await Task.sleep(for: .milliseconds(300)); _ = busy.interrupt()
                try? await Task.sleep(for: .seconds(1))
                let busyShellStillRunning = busy.isRunning
                let busyArmed = busy.interruptArmedUntil != nil
                // At an idle prompt the first ^C clears the line and arms; a second within the window closes.
                _ = idle.interrupt(); try? await Task.sleep(for: .milliseconds(300))
                let hintShown = idle.interruptArmedUntil != nil
                _ = idle.interrupt()
                for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(200)); if !idle.isRunning { break } }
                try? await Task.sleep(for: .seconds(1))
                debugTrace("ctrlCCheck verdict: busyShellStillRunning=\(busyShellStillRunning) busyArmed=\(busyArmed) idleEnded=\(idle.state.map { "\($0)" } ?? "nil") hintShown=\(hintShown)")
            }
        }
        // `-c2dTaskDepCheck YES` exercises the task dependency gate end to end through the controller:
        // B depends on A, B can't start while A is open, starts once A completes, and A can't be deleted
        // while B depends on it. Creates and then deletes its own probe tasks.
        if UserDefaults.standard.bool(forKey: "c2dTaskDepCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let tc = self?.workspace?.tasks, tc.isAvailable else { debugTrace("taskDepCheck: no task store"); return }
                guard let a = await tc.create(title: "DepCheck A"), let b = await tc.create(title: "DepCheck B") else { debugTrace("taskDepCheck: create failed"); return }
                @MainActor func b0() -> TaskRecord { tc.byID[b.id] ?? b }
                @MainActor func a0() -> TaskRecord { tc.byID[a.id] ?? a }
                await tc.addDependency(b0(), on: a0())
                let blockedWhileOpen = !tc.isEligible(b0())
                await tc.transition(b0(), to: .ready)
                tc.lastError = nil
                await tc.transition(b0(), to: .inProgress)   // no override → gated
                let startRefused = tc.lastError != nil && tc.byID[b.id]?.status != .inProgress
                await tc.transition(a0(), to: .ready); await tc.transition(a0(), to: .inProgress); await tc.transition(a0(), to: .completed)
                let eligibleAfter = tc.isEligible(b0())
                tc.lastError = nil
                await tc.transition(b0(), to: .inProgress)   // now allowed
                let startedAfter = tc.byID[b.id]?.status == .inProgress && tc.lastError == nil
                // Plan container: group A under a plan, confirm membership, delete the plan (A survives, unassigned).
                var planOK = false
                if let p = await tc.createPlan(goal: "DepCheck plan") {
                    await tc.assign(a0(), toPlan: p.id)
                    let assigned = tc.byID[a.id]?.planID == p.id && tc.tasks(inPlan: p.id).contains { $0.id == a.id }
                    await tc.deletePlan(p)
                    planOK = assigned && tc.byID[a.id] != nil && tc.byID[a.id]?.planID == nil && tc.plans.isEmpty
                }
                tc.lastError = nil
                await tc.delete(a0())   // A still has dependent B → refused
                let deleteRefused = tc.lastError != nil && tc.byID[a.id] != nil
                await tc.removeDependency(b0(), on: a.id)
                await tc.delete(b0()); await tc.delete(a0())
                let cleaned = tc.byID[a.id] == nil && tc.byID[b.id] == nil
                debugTrace("taskDepCheck: blockedWhileOpen=\(blockedWhileOpen) startRefused=\(startRefused) eligibleAfter=\(eligibleAfter) startedAfter=\(startedAfter) deleteRefused=\(deleteRefused) planOK=\(planOK) cleaned=\(cleaned)")
            }
        }
        // `-c2dDockCheck YES` exercises the drag-to-dock path the canvas drop handler calls
        // (WorkspaceController.move(_:beside:edge:)) and verifies the resulting layout tree. It does
        // not drive the SwiftUI drag gesture itself (that delivers the panel id; SwiftUI's own code).
        if UserDefaults.standard.bool(forKey: "c2dDockCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let ws = self?.workspace else { debugTrace("dockCheck: no workspace"); return }
                ws.apply(.development)
                try? await Task.sleep(for: .milliseconds(300))
                let before = ws.layout.visiblePanelIDs
                guard before.count >= 2, let p = before.first, let src = ws.layout.group(containing: p),
                      let target = ws.layout.groupIDs.first(where: { $0 != src }) else {
                    debugTrace("dockCheck: need two groups (panels=\(before.count), groups=\(ws.layout.groupIDs.count))"); return
                }
                ws.move(p, beside: target, edge: .bottom)
                try? await Task.sleep(for: .milliseconds(300))
                let after = ws.layout.visiblePanelIDs
                let newGroup = ws.layout.group(containing: p)
                let movedToNewGroup = newGroup != nil && newGroup != src && newGroup != target
                let noneLost = Set(after) == Set(before)
                debugTrace("dockCheck: before=\(before.count) after=\(after.count) movedToNewGroup=\(movedToNewGroup) noneLost=\(noneLost)")
            }
        }
        // `-c2dStressSession <file>` churns the actual app (editor open/close, panel hide/restore) for
        // a bounded number of iterations and reports resident memory + child-process count at start/end
        // — the app-layer leak dimension the core StabilityTests do not cover. Needs -c2dOpenProject.
        if let file = UserDefaults.standard.string(forKey: "c2dStressSession") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let ws = self?.workspace else { debugTrace("stressSession: no workspace"); return }
                let rss0 = currentResidentMB(), kids0 = childProcessCount()
                let iterations = 40
                for _ in 0..<iterations {
                    ws.openFile(path: file)
                    if let editorPanel = ws.editors.first(where: { !$0.value.tabs.isEmpty })?.key { ws.close(editorPanel) }
                    if let term = ws.terminals.keys.first { ws.hide(term); ws.restore(term) }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                try? await Task.sleep(for: .milliseconds(300))
                let rss1 = currentResidentMB(), kids1 = childProcessCount()
                debugTrace("stressSession: iterations=\(iterations) rss \(rss0)->\(rss1)MB children \(kids0)->\(kids1) editors=\(ws.editors.count) terminals=\(ws.terminals.count)")
            }
        }
        // `-c2dDividerCheck YES` exercises the divider-drag outcome (WorkspaceController.setWeights →
        // WorkspaceLayout.setWeights) and verifies the split's weights actually change. The SwiftUI
        // DragGesture itself stays manual (like the dock drop); its effect is what this checks.
        if UserDefaults.standard.bool(forKey: "c2dDividerCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let ws = self?.workspace else { debugTrace("dividerCheck: no workspace"); return }
                ws.apply(.development)
                try? await Task.sleep(for: .milliseconds(300))
                guard case .split(let id, _, let children, let before) = ws.layout.root, children.count >= 2 else {
                    debugTrace("dividerCheck: root is not a split"); return
                }
                var next = Array(repeating: 1.0 / Double(children.count), count: children.count)
                next[0] = 0.5; next[1] = max(0.05, next[1] - (0.5 - next[0]))   // shift weight onto the first pane
                ws.setWeights(next, of: id)
                try? await Task.sleep(for: .milliseconds(100))
                guard case .split(_, _, _, let after) = ws.layout.root else { debugTrace("dividerCheck: split gone"); return }
                debugTrace("dividerCheck: changed=\(after != before) before=\(before.map { String(format: "%.2f", $0) }) after=\(after.map { String(format: "%.2f", $0) })")
            }
        }
        // `-c2dEditorUndoCheck YES` drives the live NSTextView (requires -c2dOpenProject + -c2dOpenFile):
        // type text, undo, and verify the tab's model text actually reverts — a real state change,
        // not click delivery. Find/undo are AppKit features we enable (usesFindBar/allowsUndo).
        if UserDefaults.standard.bool(forKey: "c2dEditorUndoCheck") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, let tab = self.workspace?.editors.values.compactMap({ $0.activeTab ?? $0.tabs.first }).first else {
                    debugTrace("editorUndoCheck: no editor tab (editors=\(self?.workspace?.editors.count ?? -1))"); return
                }
                guard let tv = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(firstTextView) }).first else {
                    debugTrace("editorUndoCheck: no NSTextView in hierarchy"); return
                }
                tv.window?.makeFirstResponder(tv)
                let before = tab.text
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.insertText("ZZZMARKER\n", replacementRange: NSRange(location: 0, length: 0))
                let inserted = tab.text.contains("ZZZMARKER")
                tv.undoManager?.undo()
                let reverted = tab.text == before
                let findAvailable = tv.responds(to: #selector(NSTextView.performFindPanelAction(_:)))
                debugTrace("editorUndoCheck: inserted=\(inserted) undoReverted=\(reverted) findAvailable=\(findAvailable) usesFindBar=\(tv.usesFindBar) allowsUndo=\(tv.allowsUndo)")
            }
        }
        // `-c2dLaunchBench <projectPath>` records launch/restoration timing and memory (e2e, Bible
        // Part 15 §14.1). forkToReady uses the kernel process start time (true cold-ish, incl. dyld);
        // modelInit is from the first line of this init; restore is the openWorkspace build.
        if let projectPath = UserDefaults.standard.string(forKey: "c2dLaunchBench") {
            let modelInit = ContinuousClock.now - initClock
            let fork = forkAgeSeconds()
            debugTrace("launchBench: forkToReady=\(fork < 0 ? "n/a" : String(format: "%.0f", fork * 1000) + "ms") modelInit=\(perfMS(modelInit)) maxRSS=\(maxRSSMB())MB")
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                let t = ContinuousClock.now
                self.openProject(at: URL(fileURLWithPath: projectPath))
                let restore = ContinuousClock.now - t
                debugTrace("launchBench: restore(openWorkspace)=\(perfMS(restore)) panels=\(self.workspace?.layout.panels.count ?? 0) maxRSS=\(maxRSSMB())MB")
            }
        }
        // `-c2dThemeCheck YES` resolves the design tokens under dark appearance and verifies the
        // invariants that matter: surfaces are pairwise distinct, text luminance is ordered
        // primary>secondary>muted, and every state color has ≥3:1 contrast on the panel surface.
        if UserDefaults.standard.bool(forKey: "c2dThemeCheck") {
            let appearance = NSAppearance(named: .darkAqua)!
            func srgb(_ c: Color) -> (Double, Double, Double) {
                var out = (0.0, 0.0, 0.0)
                appearance.performAsCurrentDrawingAppearance {
                    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
                    out = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
                }
                return out
            }
            func lum(_ c: Color) -> Double {
                let (r, g, b) = srgb(c)
                func f(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
            }
            func contrast(_ a: Color, _ b: Color) -> Double {
                let la = lum(a), lb = lum(b); return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
            }
            let surfaces: [(String, Color)] = [("window", Theme.window), ("rail", Theme.rail), ("panel", Theme.panel),
                                               ("panelHeader", Theme.panelHeader), ("elevated", Theme.elevated), ("field", Theme.field)]
            var distinct = true
            for i in 0..<surfaces.count { for j in (i + 1)..<surfaces.count where srgb(surfaces[i].1) == srgb(surfaces[j].1) { distinct = false } }
            let ordered = lum(Theme.textPrimary) > lum(Theme.textSecondary) && lum(Theme.textSecondary) > lum(Theme.textMuted)
            let states: [(String, Color)] = [("accent", Theme.accent), ("success", Theme.success), ("warning", Theme.warning), ("error", Theme.error), ("info", Theme.info)]
            var report = "", allPass = true
            for (n, c) in states { let r = contrast(c, Theme.panel); report += " \(n)=\(String(format: "%.2f", r))"; if r < 3.0 { allPass = false } }
            debugTrace("themeCheck: surfacesDistinct=\(distinct) textLumOrdered=\(ordered) stateContrast>=3:\(allPass)\(report)")
        }
        // `-c2dDiagnosticsExport <path>` seeds events carrying secrets, writes the bundle, and reports
        // whether the seeded secrets survive into the file (they must not).
        if let path = UserDefaults.standard.string(forKey: "c2dDiagnosticsExport") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let token = "ghp_SEED0123456789abcdefghijklmnopqrstuv"
                await self.diagnosticsRecorder.record(module: "git", operation: "push", error: GitError.commandFailed(code: 128, stderr: "fatal: auth failed token=\(token)"))
                // Awaited directly (not via report's fire-and-forget) so both secret sources are in the file.
                await self.diagnosticsRecorder.record(module: "app", operation: "seed", detail: "message with \(token) and AKIAZZZZZZZZZZZZZZZZ key")
                let text = (try? await self.diagnosticsRecorder.makeBundle(report: DiagnosticsReport.current()).serialized()) ?? "ERR"
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
                debugTrace("diagnosticsExport: bytes=\(text.count) containsToken=\(text.contains(token)) containsAKIA=\(text.contains("AKIAZZZZZZZZZZZZZZZZ")) events=\(await self.diagnosticsRecorder.snapshot().count)")
            }
        }
        // `-c2dDestination <raw>` opens a specific nav destination at launch (debug/screenshots).
        if let raw = UserDefaults.standard.string(forKey: "c2dDestination"), let d = Destination(rawValue: raw) {
            Task { @MainActor [weak self] in try? await Task.sleep(for: .milliseconds(400)); self?.destination = d }
        }
        // `-c2dGitSync YES` exercises fetch/pull/push through the controller against a LOCAL remote
        // (prepared by the caller): fetch should surface behind>0, pull clear it, commit make ahead>0,
        // push clear it. Makes a local commit + pushes to a local bare remote only.
        // `-c2dTokenSaverCheck YES`: types a noisy command into the first live terminal,
        // adds that terminal's output to the optimizer, optimizes, and writes the hand-off file — the path the
        // panel's buttons take. Writes only `<project>/.c2d/` (git-ignored by its own .gitignore).
        if UserDefaults.standard.bool(forKey: "c2dTokenSaverCheck") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let ws = self?.workspace else { return }
                if !ws.terminals.values.contains(where: \.isRunning) { ws.newTerminal(); try? await Task.sleep(for: .seconds(3)) }
                guard let t = ws.terminals.values.first(where: \.isRunning) else { debugTrace("tokenSaverCheck: no live terminal"); return }
                t.write(Data("clear; for i in $(seq 1 120); do echo \"Compiling module $i/120\"; done; for i in 1 2 3 4 5; do echo 'retrying connection to build server'; done; echo 'Sources/App/main.swift:3:1: error: boom'; echo done\n".utf8))
                try? await Task.sleep(for: .seconds(2))
                let o = ws.optimizer
                o.clear(); o.addTerminalOutput(t); o.lossyOutputFolding = true
                let raw = o.items.first?.content ?? ""
                o.optimize(); o.writeHandOffFile()
                let file = (try? String(contentsOfFile: (ws.projectPath as NSString).appendingPathComponent(".c2d/context.md"), encoding: .utf8)) ?? ""
                debugTrace("tokenSaverCheck: rawLines=\(raw.split(separator: "\n").count) actions=\(o.result?.actions.map(\.kind.rawValue) ?? []) before=\(o.result?.before.tokens ?? -1) after=\(o.result?.after.tokens ?? -1) errorKept=\(file.contains("main.swift:3:1: error: boom")) folded=\(file.contains("similar lines omitted")) repeat=\(file.contains("repeated")) note=\(o.handOffNote ?? o.lastError ?? "nil")")
            }
        }
        // `-c2dGitFetchOnly YES` — fetch through the controller against whatever origin the project has
        // (the real remote included). Read-only on purpose: no pull, commit or push.
        if UserDefaults.standard.bool(forKey: "c2dGitFetchOnly") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let git = self?.workspace?.git, git.isAvailable else { debugTrace("gitFetchOnly: no git"); return }
                await git.refresh(); let b0 = git.behindCount, a0 = git.aheadCount
                await git.fetch(); await git.refresh()
                debugTrace("gitFetchOnly: hasUpstream=\(git.hasUpstream) before=\(b0)↓\(a0)↑ after=\(git.behindCount)↓\(git.aheadCount)↑ err=\(git.lastError ?? "none")")
            }
        }
        if UserDefaults.standard.bool(forKey: "c2dGitSync") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let git = self?.workspace?.git, git.isAvailable else { debugTrace("gitSync: no git"); return }
                // Hard guard: this hook commits and pushes, so it refuses anything but a local-path remote.
                guard let origin = try? await git.repository?.remoteURL(), origin.hasPrefix("/") else { debugTrace("gitSync: refused — origin is not a local filesystem path"); return }
                await git.refresh(); let behind0 = git.behindCount
                await git.fetch(); await git.refresh(); let afterFetch = git.behindCount
                await git.pull(); let afterPull = git.behindCount
                let p = (git.projectPath as NSString).appendingPathComponent("sync-\(Int(Date().timeIntervalSince1970)).txt")
                try? "local\n".write(toFile: p, atomically: true, encoding: .utf8)
                await git.stageAll(); git.commitMessage = "git sync hook commit"; await git.commit()
                let aheadAfterCommit = git.aheadCount
                await git.push(); await git.refresh(); let aheadAfterPush = git.aheadCount
                debugTrace("gitSync: behind0=\(behind0) afterFetch=\(afterFetch) afterPull=\(afterPull) aheadAfterCommit=\(aheadAfterCommit) aheadAfterPush=\(aheadAfterPush) err=\(git.lastError ?? "none")")
            }
        }
        // `-c2dGitSyncRejected YES` — on a work clone whose LOCAL bare remote has advanced (prepared by the
        // caller) and which has its own local commit: hides the Git panel, pushes, and reports whether the
        // rejection reached the window-level banner, and that the local commit and a dirty file survived.
        if UserDefaults.standard.bool(forKey: "c2dGitSyncRejected") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let ws = self.workspace, ws.git.isAvailable else { debugTrace("gitSyncRejected: no git"); return }
                guard let origin = try? await ws.git.repository?.remoteURL(), origin.hasPrefix("/") else { debugTrace("gitSyncRejected: refused — origin is not a local filesystem path"); return }
                if let gitPanel = ws.layout.panels.first(where: { $0.value.kind == .gitChanges })?.key, !ws.layout.hidden.contains(gitPanel) { ws.hide(gitPanel) }
                let gitPanelVisible = ws.layout.panels.contains { $0.value.kind == .gitChanges && !ws.layout.hidden.contains($0.key) }
                let dirty = (ws.projectPath as NSString).appendingPathComponent("dirty-untracked.txt")
                try? "unsaved work\n".write(toFile: dirty, atomically: true, encoding: .utf8)
                let head0 = try? await ws.git.repository?.log(limit: 1).first?.hash
                let before = self.messages.count
                await ws.git.push()
                await ws.git.push()   // same failure twice → still one banner
                let titles = self.messages.dropFirst(before).map(\.title)
                let head1 = try? await ws.git.repository?.log(limit: 1).first?.hash
                let detailHasHome = self.messages.dropFirst(before).contains { $0.detail.contains(NSHomeDirectory()) }
                debugTrace("gitSyncRejected: gitPanelVisible=\(gitPanelVisible) banners=\(titles) lastError=\(ws.git.lastError ?? "none") headUnchanged=\(head0 != nil && head0 == head1) dirtyFileKept=\(FileManager.default.fileExists(atPath: dirty)) detailLeaksHome=\(detailHasHome)")
            }
        }
        // `-c2dScrollbackCheck <n>` — types `seq 1 n` into the first live terminal, waits for the last
        // number, then reports whether line "1" is still in the buffer and the scroll-to-top position.
        // Pair with `-c2dScrollbackLines 500` to show the probe fails at SwiftTerm's default.
        if UserDefaults.standard.object(forKey: "c2dScrollbackCheck") != nil {
            let n = max(UserDefaults.standard.integer(forKey: "c2dScrollbackCheck"), 1)
            Task { @MainActor [weak self] in
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let ws = self.workspace else { return }
                    guard let t = ws.terminals.values.first(where: { $0.isRunning }) else { continue }
                    try? await Task.sleep(for: .seconds(1))   // let the prompt settle
                    let rss0 = currentResidentMB()
                    t.write(Data("seq 1 \(n)\n".utf8))
                    var settled = false
                    for _ in 0..<100 where !settled {
                        try? await Task.sleep(for: .milliseconds(100))
                        settled = t.screenText().split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "\(n)" }
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    let probe = t.scrollbackProbe(marker: "1")
                    debugTrace("scrollbackCheck n=\(n) cap=\(TerminalSurfaceView.effectiveScrollbackLines) outputSettled=\(settled) bufferLines=\(probe?.lines ?? -1) retainsLine1=\(probe?.retainsMarker ?? false) scrollTopPosition=\(probe?.topPositionAfterScroll ?? -1) rssMB=\(rss0)→\(currentResidentMB())")
                    return
                }
                debugTrace("scrollbackCheck: no running terminal within 10 s (a restored layout needs -c2dNewTerminal YES)")
            }
        }
        // `-c2dConflictCheck YES` — on a repo already left mid-merge with a conflict, selects the
        // conflicted file, confirms detection/stages/operation, resolves it with "ours", and verifies.
        if UserDefaults.standard.bool(forKey: "c2dConflictCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let git = self?.workspace?.git else { debugTrace("conflictCheck: no git"); return }
                await git.refresh()
                guard let e = git.status?.entries.first(where: { $0.isConflicted }) else {
                    debugTrace("conflictCheck: no conflicted entry (op=\(git.operation.map { $0.rawValue } ?? "nil"))"); return
                }
                let path = e.path
                await git.select(path: path, staged: false)
                let detected = git.selectedIsConflicted
                let kind = git.selectedConflictKind.map { "\($0)" } ?? "nil"
                let stages = git.selectedConflictStages != nil
                let op = git.operation.map { $0.rawValue } ?? "nil"
                await git.resolveConflict(path, using: .ours)
                let resolved = !(git.status?.entries.contains { $0.path == path && $0.isConflicted } ?? true)
                let opStillThere = git.operation != nil
                debugTrace("conflictCheck: detected=\(detected) kind=\(kind) stages=\(stages) op=\(op) resolvedOurs=\(resolved) opStillInProgress=\(opStillThere) err=\(git.lastError ?? "none")")
            }
        }
        // `-c2dExplorerCheck YES` exercises the explorer file operations on disk under a scratch folder
        // and verifies each result, including the safety guards (no overwrite, no "/" in names, trash not delete).
        if UserDefaults.standard.bool(forKey: "c2dExplorerCheck") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let ws = self?.workspace else { return }
                let ex = ws.explorer
                let root = ws.projectPath
                let fm = FileManager.default
                func exists(_ rel: String) -> Bool { fm.fileExists(atPath: root + "/" + rel) }
                ex.createFolder(in: root, name: "c2d_probe")
                let folderOK = exists("c2d_probe") && ex.entries(in: root).contains { $0.name == "c2d_probe" && $0.isDirectory }
                guard let dir = ex.entries(in: root).first(where: { $0.name == "c2d_probe" })?.path else { debugTrace("explorerCheck: probe folder not listed at root"); return }
                let filePath = ex.createFile(in: dir, name: "note.txt")
                let fileOK = filePath != nil && exists("c2d_probe/note.txt") && ex.entries(in: dir).contains { $0.name == "note.txt" }
                guard let entry = ex.entries(in: dir).first(where: { $0.name == "note.txt" }) else { debugTrace("explorerCheck: created file not listed"); return }
                let renamed = ex.rename(entry, to: "renamed.md")
                let renameOK = renamed != nil && exists("c2d_probe/renamed.md") && !exists("c2d_probe/note.txt")
                // Guards: duplicate name and a path-separator name must both be refused.
                ex.createFolder(in: dir, name: "renamed.md"); let dupRefused = ex.lastError != nil
                let badName = ex.createFile(in: dir, name: "../escape"); let slashRefused = badName == nil && !exists("escape")
                // Trash the renamed file, then the probe folder; both leave disk and the listing.
                guard let r = ex.entries(in: dir).first(where: { $0.name == "renamed.md" }) else { debugTrace("explorerCheck: renamed file not listed"); return }
                ex.trash(r); let fileTrashed = !exists("c2d_probe/renamed.md")
                if let probe = ex.entries(in: root).first(where: { $0.name == "c2d_probe" }) { ex.trash(probe) }
                let folderTrashed = !exists("c2d_probe")
                debugTrace("explorerCheck: folder=\(folderOK) file=\(fileOK) rename=\(renameOK) dupRefused=\(dupRefused) slashRefused=\(slashRefused) fileTrashed=\(fileTrashed) folderTrashed=\(folderTrashed)")
            }
        }
        // `-c2dOpenLink "<link>"` simulates a terminal Cmd-click on a detected path/URL and reports the
        // outcome and the resulting editor caret. Verifies the controller + resolver wiring end-to-end
        // (SwiftTerm's own detection is its tested responsibility and is not exercised here).
        if let link = UserDefaults.standard.string(forKey: "c2dOpenLink") {
            Task { [weak self] in
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let ws = self.workspace else { continue }
                    guard let t = ws.terminals.values.first(where: { $0.isRunning }) else { continue }
                    let outcome = t.handleOpenLink(link)
                    try? await Task.sleep(for: .milliseconds(600))
                    let tab = ws.editors.values.compactMap(\.activeTab).first
                    debugTrace("c2dOpenLink '\(link)': \(outcome) → tab=\(tab?.name ?? "none") line=\(tab?.cursorLine ?? 0) col=\(tab?.cursorColumn ?? 0)")
                    return
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

    /// Non-nil presents the diagnostics export preview sheet (the exact text that would be saved).
    var diagnosticsPreview: String?

    /// Builds the redacted, allowlisted bundle and shows it for preview before any save (Bible §12.4).
    func prepareDiagnosticsExport() {
        Task {
            let bundle = await diagnosticsRecorder.makeBundle(report: DiagnosticsReport.current())
            diagnosticsPreview = (try? bundle.serialized()) ?? "{\n  \"error\": \"failed to serialize diagnostics\"\n}"
        }
    }

    func saveDiagnostics(_ text: String, to url: URL) {
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { report("Diagnostics export failed", "Could not write the file: \(error.localizedDescription)") }
    }

    func report(_ title: String, _ detail: String) {
        // The detail may carry git stderr etc.; redact before it reaches os_log (Bible: never log secrets).
        Log.app.error("\(title, privacy: .public): \(SecretRedactor.redact(detail), privacy: .public)")
        // The same failure reported twice in a row (e.g. a retried push) shows one banner, not a stack.
        if let last = messages.last, last.title == title, last.detail == detail { return }
        messages.append(UserMessage(title: title, detail: detail))
        Task { await diagnosticsRecorder.record(module: "app", operation: title, detail: detail) }
    }

    func dismiss(_ message: UserMessage) {
        messages.removeAll { $0.id == message.id }
    }

    // MARK: Projects

    /// Shows a folder chooser and opens the selection as a project. Model-owned so every entry point
    /// (top-bar menu, ⌘O, palette, Projects view) opens the panel directly — no cross-view notification
    /// that can race view instantiation. Activates first so the panel reliably comes to the front.
    func promptOpenProject() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    /// Folder chooser for relocating a project whose folder moved.
    func promptRelocate(_ project: Project) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Locate \(project.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocateProject(project, to: url)
    }

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
            if let stale = openWorkspaces.first(where: { $0.projectPath == project.path }) { closePage(stale) }
            openWorkspace(for: moved)
        } catch {
            report("Could not relocate project", "\(error)")
        }
    }

    func removeProject(_ project: Project) {
        do {
            try registry.remove(project)
            if let page = openWorkspaces.first(where: { $0.projectPath == project.path }) { closePage(page) }
        } catch {
            report("Could not update recent projects", "\(error)")
        }
    }

    func setPinned(_ pinned: Bool, _ project: Project) {
        do { try registry.setPinned(pinned, project) } catch { report("Could not update recent projects", "\(error)") }
    }

    // MARK: Workspace

    private func openWorkspace(for project: Project) {
        if let page = openWorkspaces.first(where: { $0.projectPath == project.path }) {
            showPage(page)
            return
        }
        // Switching projects must not kill sessions of the previous workspace silently (Bible §2.3):
        // the previous workspace stays open as a page; its sessions keep running and its terminal
        // surfaces are re-parented when the page is shown again.
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
        let page = WorkspaceController(layout: layout, projectPath: project.path, app: self, restoredFromDisk: restored)
        // The optimizer is a dropdown switch now, not a workspace panel; drop panels older layouts still carry.
        for id in page.layout.panels.filter({ $0.value.kind == .tokenOptimizer }).keys { page.close(id) }
        openWorkspaces.append(page)
        showPage(page)
    }

    /// Brings an already-open page to the front.
    func showPage(_ page: WorkspaceController) {
        if workspace !== page { workspace?.flushSave(); workspace = page }
        destination = .workspace
    }

    /// Shows the page after/before the current one (wraps around).
    func cyclePage(by step: Int) {
        guard openWorkspaces.count > 1, let ws = workspace, let i = openWorkspaces.firstIndex(where: { $0 === ws }) else { return }
        showPage(openWorkspaces[(i + step + openWorkspaces.count) % openWorkspaces.count])
    }

    /// Closes one page; the neighbouring page (or the Projects list when none is left) takes its place.
    func closePage(_ page: WorkspaceController) {
        page.flushSave()
        let idx = openWorkspaces.firstIndex(where: { $0 === page })
        openWorkspaces.removeAll { $0 === page }
        if workspace === page {
            if let i = idx, !openWorkspaces.isEmpty { showPage(openWorkspaces[min(i, openWorkspaces.count - 1)]) }
            else { workspace = nil; destination = .projects }
        }
    }

    func closeWorkspace() { if let ws = workspace { closePage(ws) } }

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
    /// Across every open page, not just the visible one — hidden pages keep live shells too.
    var hasUnsavedEditors: Bool { openWorkspaces.contains(where: \.hasUnsavedEditors) }
    var hasRunningSessions: Bool { openWorkspaces.contains(where: \.hasRunningSessions) || standaloneTerminals.values.contains(where: \.isRunning) }

    func shutdown() async {
        debugTrace("shutdown: terminating \(openWorkspaces.map { $0.terminals.count }.reduce(0, +)) terminal(s) across \(openWorkspaces.count) page(s) + \(standaloneTerminals.count) window terminal(s)")
        for page in openWorkspaces { await page.terminateAllSessions() }
        for t in standaloneTerminals.values { await t.terminateAndClose() }
        debugTrace("shutdown: all sessions ended")
    }

    // MARK: Terminal windows (plain shells in their own macOS windows / native tabs, outside any page)

    private(set) var standaloneTerminals: [PanelID: TerminalPanelController] = [:]

    /// The directory a new terminal window starts in: the visible page's project, else home.
    var terminalWindowDirectory: String { workspace?.projectPath ?? NSHomeDirectory() }

    func makeStandaloneTerminal(projectPath: String) -> TerminalPanelController {
        let t = TerminalPanelController(panelID: PanelID(), projectPath: projectPath, app: self, previousRecord: nil)
        standaloneTerminals[t.panelID] = t
        t.startNewSession()
        return t
    }

    /// Window closed: the shell ends with it so nothing outlives the app (ADR-013 / DEF-12).
    func closeStandaloneTerminal(_ id: PanelID) async {
        guard let t = standaloneTerminals.removeValue(forKey: id) else { return }
        await t.terminateAndClose()
    }

    /// Split layout of each terminal window (iTerm-style: right ⌘D, down ⌘⇧D, nestable). Native macOS
    /// tabs are the window's tabs; this is the split inside one tab.
    private(set) var standaloneWindowLayouts: [UUID: PaneTree] = [:]
    /// Panes of each window in reading order.
    var standaloneWindowPanes: [UUID: [PanelID]] { standaloneWindowLayouts.mapValues(\.panes) }

    /// First pane of a window, created when the window appears (idempotent).
    func openStandaloneWindow(_ window: UUID, directory: String) {
        guard standaloneWindowLayouts[window] == nil else { return }
        standaloneWindowLayouts[window] = .pane(makeStandaloneTerminal(projectPath: directory).panelID)
    }

    /// Adds a shell right of (or below) `pane`, starting in that pane's current directory, and focuses it.
    func splitStandalone(window: UUID, after pane: PanelID, down: Bool = false) {
        guard let tree = standaloneWindowLayouts[window], tree.panes.contains(pane) else { return }
        let dir = standaloneTerminals[pane]?.resolutionDirectory ?? terminalWindowDirectory
        let new = makeStandaloneTerminal(projectPath: dir)
        standaloneWindowLayouts[window] = tree.inserting(new.panelID, beside: pane, down: down)
        Task { @MainActor in   // once SwiftUI has hosted the new surface
            try? await Task.sleep(for: .milliseconds(150))
            if let v = new.hostedView { v.window?.makeFirstResponder(v) }
        }
    }

    /// The key terminal window and its focused pane (the one holding keyboard focus, else its first pane).
    var focusedStandalonePane: (window: UUID, pane: PanelID)? {
        guard let key = NSApp.keyWindow, let (window, tree) = standaloneWindowLayouts.first(where: { key.identifier == Self.terminalWindowIdentifier($0.key) }) else { return nil }
        let focused = tree.panes.first { standaloneTerminals[$0]?.hostedView.map { key.firstResponder === $0 } == true }
        return (focused ?? tree.panes.first).map { (window, $0) }
    }

    /// Ends one pane's shell; returns whether the window still has panes.
    @discardableResult
    func closeStandalonePane(window: UUID, _ pane: PanelID) async -> Bool {
        standaloneWindowLayouts[window] = standaloneWindowLayouts[window]?.removing(pane)
        await closeStandaloneTerminal(pane)
        return standaloneWindowLayouts[window] != nil
    }

    /// Open terminal windows for menus, sorted by title: (window id, "folder · 2 panes").
    var standaloneWindowTitles: [(id: UUID, title: String)] {
        standaloneWindowPanes.compactMap { id, panes in
            guard let first = panes.first, let t = standaloneTerminals[first] else { return nil }
            let name = URL(fileURLWithPath: t.projectPath).lastPathComponent
            return (id, panes.count > 1 ? "\(name) · \(panes.count) panes" : name)
        }.sorted { $0.title < $1.title }
    }

    static func terminalWindowIdentifier(_ window: UUID) -> NSUserInterfaceItemIdentifier { .init("c2d.terminal.\(window.uuidString)") }

    /// Brings a terminal window (possibly a background tab, possibly behind other apps) to the front.
    func revealStandaloneWindow(_ window: UUID) {
        guard let w = NSApp.windows.first(where: { $0.identifier == Self.terminalWindowIdentifier(window) }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Window closed: every pane's shell ends with it.
    func closeStandaloneWindow(_ window: UUID) async {
        for pane in standaloneWindowLayouts.removeValue(forKey: window)?.panes ?? [] { await closeStandaloneTerminal(pane) }
    }
}

// MARK: - Launch benchmark helpers (Bible Part 15 §14.1)

private func perfMS(_ d: Duration) -> String {
    String(format: "%.0fms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

/// Peak resident set size in whole MB (getrusage ru_maxrss is bytes on Darwin).
private func maxRSSMB() -> Int {
    var ru = rusage()
    guard getrusage(RUSAGE_SELF, &ru) == 0 else { return -1 }
    return Int(ru.ru_maxrss) / 1_000_000
}

/// Seconds since this process was forked, from the kernel's recorded start time; `-1` if unavailable.
private func forkAgeSeconds() -> Double {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, u_int($0.count), &kp, &size, nil, 0) }
    guard rc == 0 else { return -1 }
    let start = kp.kp_proc.p_un.__p_starttime
    let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
    return Date().timeIntervalSince1970 - started
}

/// First NSTextView found in a view subtree (for the editor interaction debug check).
private func firstTextView(_ v: NSView) -> NSTextView? {
    if let tv = v as? NSTextView { return tv }
    for sub in v.subviews { if let f = firstTextView(sub) { return f } }
    return nil
}

/// Current resident set size in whole MB (mach_task_basic_info), for e2e leak observation.
private func currentResidentMB() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.resident_size) / 1_000_000 : -1
}

/// Number of direct child processes of this process.
private func childProcessCount() -> Int {
    let bytes = proc_listchildpids(getpid(), nil, 0)
    return bytes <= 0 ? 0 : Int(bytes) / MemoryLayout<pid_t>.stride
}
