import AppKit
import C2DCore
import Foundation
import Observation

/// One open file inside an editor panel.
@MainActor
@Observable
final class EditorTab: Identifiable {
    let id = UUID()
    private(set) var document: TextDocument
    var externalChange: ExternalChange = .none
    var lastError: String?
    var cursorLine = 1
    var cursorColumn = 1
    /// Set by go-to-line; the text view consumes it (positions the caret, scrolls) and clears it.
    var pendingLine: Int?
    var pendingColumn: Int?
    /// Stays true after the user chose to keep local edits over an external change; cleared on save.
    var keepLocalOverExternal = false

    init(document: TextDocument) { self.document = document }

    var path: String { document.path }
    var name: String { document.name }
    var isDirty: Bool { document.isDirty }
    var text: String { document.text }

    func update(text: String) { document.update(text: text) }

    func checkDisk() {
        externalChange = document.externalChange()
    }

    /// Saves unless the file changed underneath us and the user has not decided yet (Bible Part 5 §6.2).
    func save() -> Bool {
        checkDisk()
        if externalChange == .modified && !keepLocalOverExternal {
            lastError = "File changed on disk since it was opened. Choose Reload or Keep Mine first."
            return false
        }
        do {
            try document.save()
            externalChange = .none
            keepLocalOverExternal = false
            lastError = nil
            return true
        } catch {
            lastError = "Save failed: \(error)"
            return false
        }
    }

    func reloadFromDisk() {
        do {
            try document.reload()
            externalChange = .none
            keepLocalOverExternal = false
            lastError = nil
        } catch {
            lastError = "Reload failed: \(error)"
        }
    }
}

/// Owns the editor tabs for one editor panel and persists which files were open (Bible Part 5 §5.5).
@MainActor
@Observable
final class EditorPanelController {
    let panelID: PanelID
    let projectPath: String
    private(set) var tabs: [EditorTab] = []
    var activeTabID: UUID?
    /// Tab waiting for a save/discard/cancel decision.
    var closeRequest: EditorTab?
    var lastError: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let store: JSONDocumentStore?
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    struct State: Codable {
        var schemaVersion = 1
        var openPaths: [String]
        var activePath: String?
    }

    init(panelID: PanelID, projectPath: String, app: AppModel) {
        self.panelID = panelID
        self.projectPath = projectPath
        self.app = app
        self.store = try? JSONDocumentStore.applicationSupport(subdirectory: "editor")
        restore()
    }

    var activeTab: EditorTab? { tabs.first { $0.id == activeTabID } }

    // MARK: Diff tab

    /// At most one diff tab per panel, VS Code style: it shows whatever file the Source Control panel has
    /// selected (live), and closing it clears that selection. Not persisted.
    private(set) var diffTabID: UUID?
    private(set) var diffSource: GitController?
    var isDiffActive: Bool { diffTabID != nil && activeTabID == diffTabID }

    func showDiff(from git: GitController) {
        diffSource = git
        if diffTabID == nil { diffTabID = UUID() }
        activeTabID = diffTabID
    }

    func activateDiff() { activeTabID = diffTabID }

    func closeDiff() {
        let wasActive = isDiffActive
        diffSource?.selectedPath = nil
        diffSource = nil
        diffTabID = nil
        if wasActive { activeTabID = tabs.last?.id }
    }

    /// Go to a 1-based line (and optional 1-based column) in the active tab (Bible Part 5 §7.3).
    /// Out-of-range values clamp.
    func goTo(line: Int, column: Int? = nil) {
        guard let tab = activeTab else { return }
        tab.pendingLine = max(1, line)
        tab.pendingColumn = column.map { max(1, $0) }
    }
    var hasUnsavedChanges: Bool { tabs.contains { $0.isDirty } }
    private var stateName: String { "panel-\(panelID.rawValue)" }

    // MARK: Open / close

    /// Opens or activates. Never duplicates a tab for the same path (Bible Part 5 §5.2).
    @discardableResult
    func open(path: String) -> EditorTab? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = tabs.first(where: { $0.path == standardized }) {
            activeTabID = existing.id
            existing.checkDisk()
            return existing
        }
        do {
            let tab = EditorTab(document: try TextDocument.load(path: standardized))
            tabs.append(tab)
            activeTabID = tab.id
            persistSoon()
            return tab
        } catch {
            lastError = describe(error, path: standardized)
            return nil
        }
    }

    /// Asks when the tab is dirty; closes immediately otherwise.
    func requestClose(_ tab: EditorTab) {
        if tab.isDirty { closeRequest = tab } else { close(tab) }
    }

    func close(_ tab: EditorTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        if activeTabID == tab.id { activeTabID = tabs[min(i, max(tabs.count - 1, 0))...].first?.id ?? tabs.last?.id }
        if tabs.isEmpty { activeTabID = diffTabID }
        closeRequest = nil
        persistSoon()
    }

    func saveAndClose(_ tab: EditorTab) {
        if tab.save() { close(tab) } else { lastError = tab.lastError }
    }

    func activate(_ tab: EditorTab) {
        activeTabID = tab.id
        tab.checkDisk()
        persistSoon()
    }

    func saveActive() {
        guard let tab = activeTab else { return }
        if !tab.save() { lastError = tab.lastError }
    }

    func saveAll() {
        for tab in tabs where tab.isDirty { if !tab.save() { lastError = tab.lastError } }
    }

    /// Called by the file watcher: re-checks every open file against disk. Clean tabs reload
    /// automatically; dirty tabs surface the conflict for the user to resolve.
    func filesChanged(_ paths: [String]) {
        let changed = Set(paths)
        for tab in tabs where changed.contains(tab.path) || changed.contains(where: { tab.path.hasPrefix($0 + "/") || $0 == URL(fileURLWithPath: tab.path).deletingLastPathComponent().path }) {
            tab.checkDisk()
            if tab.externalChange == .modified && !tab.isDirty { tab.reloadFromDisk() }
        }
    }

    // MARK: Persistence

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            let state = State(openPaths: self.tabs.map(\.path), activePath: self.activeTab?.path)
            try? store.save(state, as: self.stateName)
        }
    }

    private func restore() {
        guard let store, let state = try? store.load(State.self, named: stateName) else { return }
        for path in state.openPaths where FileManager.default.fileExists(atPath: path) {
            if let tab = try? EditorTab(document: TextDocument.load(path: path)) { tabs.append(tab) }
        }
        activeTabID = tabs.first { $0.path == state.activePath }?.id ?? tabs.first?.id
    }

    func describe(_ error: Error, path: String) -> String {
        switch error as? TextDocumentError {
        case .binary: "\(URL(fileURLWithPath: path).lastPathComponent) looks like a binary file and cannot be edited here."
        case .tooLarge(let bytes, let limit): "\(URL(fileURLWithPath: path).lastPathComponent) is \(bytes / 1024) KB; the editor handles files up to \(limit / 1024) KB."
        case .undecodable: "\(URL(fileURLWithPath: path).lastPathComponent) is not UTF-8 text."
        case .notAFile: "\(path) is not a file."
        default: "\(error)"
        }
    }
}
