import Foundation
import Testing
@testable import C2DCore

private func twoGroups() -> (WorkspaceLayout, Panel, Panel, NodeID, NodeID) {
    let a = Panel(kind: .editor, title: "A"), b = Panel(kind: .terminal, title: "B")
    let ga = NodeID("ga"), gb = NodeID("gb")
    let root = LayoutNode.split(id: NodeID("root"), orientation: .horizontal,
                                children: [.group(id: ga, panels: [a.id], active: a.id), .group(id: gb, panels: [b.id], active: b.id)],
                                weights: [0.6, 0.4])
    return (WorkspaceLayout(name: "t", root: root, panels: [a, b]), a, b, ga, gb)
}

@Suite struct WorkspaceLayoutTests {

    @Test func identityIsStableAcrossMoves() throws {
        var (layout, a, b, ga, gb) = twoGroups()
        try layout.move(a.id, toGroup: gb)
        #expect(layout.group(containing: a.id) == gb)
        #expect(layout.panels[a.id]?.title == "A")
        #expect(layout.visiblePanelIDs == [b.id, a.id])
        #expect(layout.activePanel(in: gb) == a.id)
        #expect(!layout.groupIDs.contains(ga), "emptied group is pruned and the split collapses")
        if case .group = layout.root {} else { Issue.record("root should collapse to the remaining group") }
    }

    @Test func addBesideSplitsAndReusesMatchingOrientation() throws {
        var (layout, _, _, ga, _) = twoGroups()
        let c = Panel(kind: .tasks)
        try layout.add(c, beside: ga, edge: .left)
        guard case .split(_, let o, let children, let weights) = layout.root else { Issue.record("no split"); return }
        #expect(o == .horizontal)
        #expect(children.count == 3, "same orientation: inserted into the existing split")
        #expect(abs(weights.reduce(0, +) - 1.0) < 1e-9)
        #expect(children.first?.panelIDs == [c.id])

        let d = Panel(kind: .gitChanges)
        try layout.add(d, beside: ga, edge: .bottom)
        guard case .split(_, _, let children2, _) = layout.root, case .split(_, let o2, let nested, _) = children2[1] else { Issue.record("no nested split"); return }
        #expect(o2 == .vertical)
        #expect(nested.last?.panelIDs == [d.id])
    }

    @Test func hideRestoreCloseAreDistinct() throws {
        var (layout, a, b, ga, gb) = twoGroups()
        try layout.hide(a.id)
        #expect(layout.hidden == [a.id])
        #expect(layout.panels[a.id] != nil, "hidden keeps identity")
        #expect(!layout.visiblePanelIDs.contains(a.id))
        try layout.hide(a.id)   // idempotent
        #expect(layout.hidden == [a.id])

        try layout.restore(a.id, into: ga)   // ga was pruned → falls back to first group
        #expect(layout.hidden.isEmpty)
        #expect(layout.group(containing: a.id) == gb)

        try layout.close(b.id)
        #expect(layout.panels[b.id] == nil)
        #expect(layout.visiblePanelIDs == [a.id])
        #expect(throws: LayoutError.unknownPanel(b.id)) { try layout.activate(b.id) }
    }

    @Test func closingLastPanelLeavesAnEmptyRootGroup() throws {
        var (layout, a, b, _, _) = twoGroups()
        try layout.close(a.id); try layout.close(b.id)
        #expect(layout.visiblePanelIDs.isEmpty)
        #expect(layout.groupIDs.count == 1)
        let c = Panel(kind: .terminal)
        try layout.add(c, to: layout.groupIDs[0])
        #expect(layout.visiblePanelIDs == [c.id])
    }

    @Test func tabsActivatePredictablyWhenActiveCloses() throws {
        let p1 = Panel(kind: .terminal), p2 = Panel(kind: .terminal), p3 = Panel(kind: .terminal)
        let g = NodeID("g")
        var layout = WorkspaceLayout(name: "t", root: .group(id: g, panels: [p1.id, p2.id, p3.id], active: p2.id), panels: [p1, p2, p3])
        try layout.close(p2.id)
        #expect(layout.activePanel(in: g) == p1.id)
        try layout.activate(p3.id)
        #expect(layout.activePanel(in: g) == p3.id)
        try layout.move(p1.id, toGroup: g, index: 5)
        #expect(layout.visiblePanelIDs == [p3.id, p1.id])
    }

    @Test func focusModeKeepsTreeIntact() throws {
        var (layout, a, _, ga, _) = twoGroups()
        let before = layout.root
        try layout.maximize(ga)
        #expect(layout.maximizedGroup == ga)
        #expect(layout.root == before)
        try layout.hide(a.id)
        #expect(layout.maximizedGroup == nil, "maximized group vanished → focus exits")
        layout.exitFocusMode()
        #expect(layout.maximizedGroup == nil)
    }

    @Test func weightsValidated() throws {
        var (layout, _, _, _, _) = twoGroups()
        #expect(throws: LayoutError.invalidWeights) { try layout.setWeights([0, 1], of: NodeID("root")) }
        try layout.setWeights([0.3, 0.7], of: NodeID("root"))
        guard case .split(_, _, _, let w) = layout.root else { Issue.record("no split"); return }
        #expect(w == [0.3, 0.7])
        #expect(throws: LayoutError.unknownGroup(NodeID("nope"))) { try layout.setWeights([1], of: NodeID("nope")) }
    }

    @Test func invalidOperationsDoNotMutate() throws {
        var (layout, a, _, _, _) = twoGroups()
        let before = layout
        #expect(throws: LayoutError.unknownGroup(NodeID("x"))) { try layout.add(Panel(kind: .editor), to: NodeID("x")) }
        #expect(throws: LayoutError.panelAlreadyPlaced(a.id)) { try layout.add(a, to: NodeID("gb")) }
        #expect(throws: LayoutError.unknownPanel(PanelID("ghost"))) { try layout.move(PanelID("ghost"), toGroup: NodeID("gb")) }
        #expect(layout == before)
    }

    @Test func recoveryReplacesUnavailableKindsAndPrunesDanglingReferences() throws {
        var (layout, a, b, _, _) = twoGroups()
        var bogus = layout
        bogus.root = .split(id: NodeID(), orientation: .vertical, children: [layout.root, .group(id: NodeID(), panels: [PanelID("dangling")], active: nil)], weights: [1, 1])
        bogus.panels[b.id]?.kind = PanelKind(rawValue: "hologram")
        let affected = bogus.recover(availableKinds: [.editor, .terminal])
        #expect(affected == [b.id])
        #expect(bogus.panels[b.id]?.kind == .unavailable)
        #expect(bogus.panels[b.id]?.attributes["originalKind"] == "hologram")
        #expect(Set(bogus.visiblePanelIDs) == [a.id, b.id], "slot kept, dangling reference dropped")
        _ = layout
    }

    @Test func roundTripsThroughJSON() throws {
        var (layout, a, _, _, gb) = twoGroups()
        try layout.hide(a.id)
        try layout.maximize(gb)
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        #expect(back == layout)
        #expect(back.schemaVersion == WorkspaceLayout.currentSchemaVersion)
    }

    @Test func presetsDegradeToAvailableKinds() {
        let full = LayoutPreset.development.makeLayout(available: [.projectExplorer, .editor, .terminal, .agentSession])
        #expect(full.panels.count == 4)
        #expect(full.isBuiltIn)
        let partial = LayoutPreset.development.makeLayout(available: [.terminal])
        #expect(partial.panels.count == 1)
        if case .group = partial.root {} else { Issue.record("single available panel should collapse to one group") }
        let none = LayoutPreset.codeReview.makeLayout(available: [])
        #expect(none.visiblePanelIDs.isEmpty && none.groupIDs.count == 1)
        for p in LayoutPreset.allCases { #expect(!p.makeLayout(available: [.terminal, .editor]).id.isEmpty) }
    }
}

@Suite struct PersistenceTests {
    private func tempStore() throws -> JSONDocumentStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-tests-\(UUID().uuidString)")
        return JSONDocumentStore(directory: dir)
    }

    @Test func saveLoadDeleteAndList() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(try store.load(WorkspaceLayout.self, named: "missing") == nil)
        let layout = LayoutPreset.terminalFocus.makeLayout(available: [.terminal])
        try store.save(layout, as: "one")
        #expect(try store.load(WorkspaceLayout.self, named: "one") == layout)
        #expect(store.list() == ["one"])
        #expect(!FileManager.default.fileExists(atPath: store.url(for: "one").appendingPathExtension("tmp").path), "temp file renamed away")
        try store.delete("one")
        #expect(store.list().isEmpty)
    }

    @Test func tornWriteCannotCorruptExistingDocument() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let good = LayoutPreset.terminalFocus.makeLayout(available: [.terminal])
        try store.save(good, as: "doc")
        // Simulate a crash after the temp file was partially written and before the rename.
        try Data("{\"schemaVersion\": 1, \"id\": \"half".utf8).write(to: store.url(for: "doc").appendingPathExtension("tmp"))
        #expect(try store.load(WorkspaceLayout.self, named: "doc") == good)
    }

    @Test func corruptAndNewerDocumentsFailLoudly() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url(for: "bad"))
        #expect(throws: (any Error).self) { try store.load(WorkspaceLayout.self, named: "bad") }

        var future = LayoutPreset.terminalFocus.makeLayout(available: [.terminal])
        future.schemaVersion = 99
        try store.save(future, as: "global-default")
        let layouts = LayoutStore(documents: store)
        #expect(throws: LayoutStoreError.unsupportedSchema(99)) { try layouts.loadGlobalDefault() }
    }

    @Test func layoutStoreKeysProjectsByPath() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let layouts = LayoutStore(documents: store)
        let layout = LayoutPreset.terminalFocus.makeLayout(available: [.terminal])
        try layouts.save(layout, forProjectPath: "/tmp/proj-a/")
        #expect(try layouts.load(forProjectPath: "/tmp/proj-a") == layout, "trailing slash normalized")
        #expect(try layouts.load(forProjectPath: "/tmp/proj-b") == nil)
        #expect(try layouts.loadGlobalDefault() == nil)
    }
}

@Suite struct ProjectRegistryTests {
    private func tempDirs() throws -> (JSONDocumentStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-proj-\(UUID().uuidString)")
        let project = base.appendingPathComponent("MyApp")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (JSONDocumentStore(directory: base.appendingPathComponent("store")), project)
    }

    @Test func openRecordsActivatesAndPersists() throws {
        let (store, dir) = try tempDirs()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        var registry = try ProjectRegistry(store: store)
        let p = try registry.open(path: dir.path + "/")
        #expect(p.name == "MyApp")
        #expect(p.path == dir.standardizedFileURL.path)
        #expect(registry.activeProject == p)
        #expect(p.isAvailable)

        let reloaded = try ProjectRegistry(store: store)
        #expect(reloaded.projects.map(\.path) == [p.path])
        #expect(reloaded.activeProject?.path == p.path)
    }

    @Test func invalidPathsAreRejected() throws {
        let (store, dir) = try tempDirs()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        var registry = try ProjectRegistry(store: store)
        #expect(throws: ProjectError.notADirectory("/no/such/project")) { try registry.open(path: "/no/such/project") }
        let file = dir.appendingPathComponent("f.txt"); try Data().write(to: file)
        #expect(throws: ProjectError.notADirectory(file.path)) { try registry.open(path: file.path) }
        #expect(registry.projects.isEmpty)
    }

    @Test func missingProjectIsFlaggedNotDeletedAndCanBeRelocated() throws {
        let (store, dir) = try tempDirs()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        var registry = try ProjectRegistry(store: store)
        let p = try registry.open(path: dir.path)
        let moved = dir.deletingLastPathComponent().appendingPathComponent("MyAppMoved")
        try FileManager.default.moveItem(at: dir, to: moved)
        #expect(!registry.projects[0].isAvailable)
        let r = try registry.relocate(p, to: moved.path)
        #expect(r.isAvailable && r.name == "MyAppMoved")
        #expect(registry.projects.count == 1)
        try registry.remove(r)
        #expect(registry.projects.isEmpty && registry.activeProject == nil)
        #expect(FileManager.default.fileExists(atPath: moved.path), "removing an entry never deletes the directory")
    }

    @Test func pinnedProjectsSortFirstThenMostRecent() throws {
        let (store, dir) = try tempDirs()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let second = dir.deletingLastPathComponent().appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var registry = try ProjectRegistry(store: store)
        let a = try registry.open(path: dir.path)
        let b = try registry.open(path: second.path)
        #expect(registry.projects.map(\.name) == [b.name, a.name])
        try registry.setPinned(true, a)
        #expect(registry.projects.map(\.name) == [a.name, b.name])
    }
}
