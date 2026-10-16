import Foundation
import Testing
@testable import C2DCore

private let project = "/tmp/proj-a"

@Suite struct TasksTests {

    @Test func schemaCreatesAndReopenPersistsWithWAL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-tasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("records.sqlite").path
        let store = try TaskStore(path: path)
        let t = try await store.create(TaskRecord(projectPath: project, title: "persisted"))
        let reopened = try TaskStore(path: path)   // migration must be idempotent
        #expect(try await reopened.task(id: t.id)?.title == "persisted")
        let db = try SQLiteDatabase(path: path)
        #expect(db.journalMode == "wal")
        #expect(db.userVersion == TaskStore.schemaVersion)
    }

    @Test func createAndReadRoundTrip() async throws {
        let store = try TaskStore.inMemory()
        let t = try await store.create(TaskRecord(projectPath: project, title: "Fix login", details: "500 on POST",
                                                  acceptanceCriteria: "tests pass", priority: .high, labels: ["bug", "auth"], worktreePath: "/wt"))
        let back = try await store.task(id: t.id)
        #expect(back == t)
        #expect(back?.labels == ["bug", "auth"] && back?.status == .inbox && back?.completedAt == nil)
        #expect(try await store.task(id: "nope") == nil)
        #expect(try await store.tasks(projectPath: project).map(\.id) == [t.id])
        #expect(try await store.activeCount(projectPath: project) == 1)
        #expect(try await store.events(taskID: t.id).map(\.kind) == [.created])
    }

    @Test func transitionTable() throws {
        let allowed: [(TaskStatus, TaskStatus)] = [(.inbox, .ready), (.inbox, .cancelled), (.ready, .inProgress), (.ready, .blocked), (.ready, .inbox),
            (.inProgress, .awaitingReview), (.inProgress, .completed), (.inProgress, .blocked), (.inProgress, .ready),
            (.blocked, .ready), (.blocked, .inProgress), (.awaitingReview, .inProgress), (.awaitingReview, .completed),
            (.completed, .ready), (.cancelled, .ready)]
        for (a, b) in allowed { #expect(a.canTransition(to: b), "\(a)→\(b)") }
        let forbidden: [(TaskStatus, TaskStatus)] = [(.completed, .inProgress), (.completed, .completed), (.inbox, .completed), (.inbox, .inProgress),
            (.cancelled, .completed), (.ready, .awaitingReview), (.blocked, .completed), (.ready, .ready)]
        for (a, b) in forbidden { #expect(!a.canTransition(to: b), "\(a)→\(b)") }
        for s in TaskStatus.allCases { #expect(!s.canTransition(to: s)) }
    }

    @Test func lifecycleWithEventsInOrder() async throws {
        let store = try TaskStore.inMemory()
        let t = try await store.create(TaskRecord(projectPath: project, title: "t"))
        try await store.transition(id: t.id, to: .ready)
        try await store.transition(id: t.id, to: .inProgress, note: "started")
        try await store.transition(id: t.id, to: .awaitingReview)
        let done = try await store.transition(id: t.id, to: .completed)
        #expect(done.status == .completed && done.completedAt != nil)
        await #expect(throws: TaskError.invalidTransition(from: .completed, to: .inProgress)) { try await store.transition(id: t.id, to: .inProgress) }
        let reopened = try await store.transition(id: t.id, to: .ready)
        #expect(reopened.completedAt == nil)
        let ev = try await store.events(taskID: t.id)
        #expect(ev.map(\.kind) == [.created, .statusChanged, .statusChanged, .statusChanged, .statusChanged, .statusChanged])
        #expect(ev[2].detail == "started" && ev[2].fromStatus == .ready && ev[2].toStatus == .inProgress)
        #expect(ev.map(\.at) == ev.map(\.at).sorted())
        #expect(try await store.tasks(projectPath: project).count == 1)
        try await store.transition(id: t.id, to: .cancelled)
        #expect(try await store.tasks(projectPath: project).isEmpty)
        #expect(try await store.tasks(projectPath: project, includeTerminal: true).count == 1)
        await #expect(throws: TaskError.notFound("ghost")) { try await store.transition(id: "ghost", to: .ready) }
    }

    @Test func updateRecordsChangedFieldsAndKeepsStatus() async throws {
        let store = try TaskStore.inMemory()
        var t = try await store.create(TaskRecord(projectPath: project, title: "a"))
        try await store.transition(id: t.id, to: .ready)
        t.title = "b"; t.priority = .critical; t.status = .completed /* ignored */; t.assignedAgentSessionID = "sess-1"
        let u = try await store.update(t)
        #expect(u.status == .ready && u.title == "b" && u.priority == .critical)
        #expect(u.updatedAt >= u.createdAt)
        let ev = try await store.events(taskID: t.id)
        #expect(ev.map(\.kind) == [.created, .statusChanged, .edited, .assigned])
        #expect(ev[2].detail == "title,priority" && ev[3].detail == "sess-1")
        #expect(try await store.update(u).id == u.id)   // no-op update adds no event
        #expect(try await store.events(taskID: t.id).count == 4)
    }

    @Test func blockedAndUnblocked() async throws {
        let store = try TaskStore.inMemory()
        let t = try await store.create(TaskRecord(projectPath: project, title: "t"))
        try await store.transition(id: t.id, to: .ready)
        let b = try await store.setBlocked(id: t.id, reason: "needs decision")
        #expect(b.status == .blocked && b.blockedReason == "needs decision")
        let b2 = try await store.setBlocked(id: t.id, reason: "changed reason")   // re-block updates the reason
        #expect(b2.blockedReason == "changed reason")
        let c = try await store.clearBlocked(id: t.id)
        #expect(c.status == .ready && c.blockedReason == nil)
        #expect(try await store.events(taskID: t.id).map(\.kind) == [.created, .statusChanged, .blocked, .blocked, .unblocked])
        let fresh = try await store.create(TaskRecord(projectPath: project, title: "inbox"))
        await #expect(throws: TaskError.invalidTransition(from: .inbox, to: .blocked)) { try await store.setBlocked(id: fresh.id, reason: "x") }
    }

    @Test func searchIsCaseInsensitiveAndEscaped() async throws {
        let store = try TaskStore.inMemory()
        try await store.create(TaskRecord(projectPath: project, title: "Rate Limiter", details: "100% coverage"))
        try await store.create(TaskRecord(projectPath: "/tmp/other", title: "rate card"))
        try await store.create(TaskRecord(projectPath: project, title: "unrelated"))
        #expect(try await store.search(text: "RATE").count == 2)
        #expect(try await store.search(text: "rate", projectPath: project).map(\.title) == ["Rate Limiter"])
        #expect(try await store.search(text: "100%").map(\.title) == ["Rate Limiter"])
        #expect(try await store.search(text: "zzz").isEmpty)
    }

    @Test func deleteRemovesEventsOnly() async throws {
        let store = try TaskStore.inMemory()
        let t = try await store.create(TaskRecord(projectPath: project, title: "t", worktreePath: NSTemporaryDirectory()))
        try await store.addNote(id: t.id, "a note")
        try await store.delete(id: t.id)
        #expect(try await store.task(id: t.id) == nil)
        #expect(try await store.events(taskID: t.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: NSTemporaryDirectory()), "store never touches the filesystem")
        await #expect(throws: TaskError.notFound(t.id)) { try await store.delete(id: t.id) }
    }

    @Test func transactionRollsBackOnThrow() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.inTransaction {
                try db.run("INSERT INTO t (v) VALUES (?)", [.text("partial")])
                throw Boom()
            }
        }
        #expect(try db.scalarInt("SELECT COUNT(*) FROM t") == 0)
        try db.inTransaction { try db.run("INSERT INTO t (v) VALUES (?)", [.text("kept")]) }
        #expect(try db.query("SELECT v FROM t", []) { $0.string(0) } == ["kept"])
        #expect(throws: SQLiteError.self) { try db.exec("NOT SQL") }
    }

    // MARK: Dependencies (Bible Part 8 §12)

    @Test func dependencyGatesStartUntilUpstreamCompletes() async throws {
        let store = try TaskStore.inMemory()
        let a = try await store.create(TaskRecord(projectPath: project, title: "A upstream"))
        let b = try await store.create(TaskRecord(projectPath: project, title: "B dependent"))
        _ = try await store.addDependency(id: b.id, dependsOn: a.id)
        // Resolve B through the store graph (terminal tasks included), not a filtered snapshot.
        func unmet(_ id: String) async throws -> [String] {
            let all = try await store.tasks(projectPath: project, includeTerminal: true)
            let map = Dictionary(all.map { ($0.id, $0.status) }, uniquingKeysWith: { x, _ in x })
            return try await store.task(id: id)!.unmetDependencies { map[$0] }
        }
        #expect(try await unmet(b.id) == [a.id])
        // B cannot start while A is open.
        _ = try await store.transition(id: b.id, to: .ready)
        await #expect(throws: TaskError.dependenciesUnmet([a.id])) { try await store.transition(id: b.id, to: .inProgress) }
        // override starts it anyway (informed consent).
        _ = try await store.transition(id: b.id, to: .inProgress, override: true)
        #expect(try await store.task(id: b.id)?.status == .inProgress)
        _ = try await store.transition(id: b.id, to: .ready)
        // Complete A → B is eligible and starts without override.
        _ = try await store.transition(id: a.id, to: .ready)
        _ = try await store.transition(id: a.id, to: .inProgress)
        _ = try await store.transition(id: a.id, to: .completed)
        #expect(try await unmet(b.id).isEmpty)
        _ = try await store.transition(id: b.id, to: .inProgress)
        #expect(try await store.task(id: b.id)?.status == .inProgress)
    }

    @Test func cancelledUpstreamKeepsDependentBlocked() async throws {
        let store = try TaskStore.inMemory()
        let a = try await store.create(TaskRecord(projectPath: project, title: "A"))
        let b = try await store.create(TaskRecord(projectPath: project, title: "B"))
        _ = try await store.addDependency(id: b.id, dependsOn: a.id)
        _ = try await store.transition(id: a.id, to: .cancelled)   // upstream dropped, not completed
        _ = try await store.transition(id: b.id, to: .ready)
        // A cancelled prerequisite is not "satisfied": B must not run against a dropped assumption.
        await #expect(throws: TaskError.dependenciesUnmet([a.id])) { try await store.transition(id: b.id, to: .inProgress) }
    }

    @Test func rejectsSelfCrossProjectMissingAndCyclicEdges() async throws {
        let store = try TaskStore.inMemory()
        let a = try await store.create(TaskRecord(projectPath: project, title: "A"))
        let b = try await store.create(TaskRecord(projectPath: project, title: "B"))
        let other = try await store.create(TaskRecord(projectPath: "/tmp/proj-b", title: "X"))
        await #expect(throws: TaskError.selfDependency) { try await store.addDependency(id: a.id, dependsOn: a.id) }
        await #expect(throws: TaskError.crossProject) { try await store.addDependency(id: a.id, dependsOn: other.id) }
        await #expect(throws: TaskError.notFound("nope")) { try await store.addDependency(id: a.id, dependsOn: "nope") }
        // A→B, then B→A would close a cycle.
        _ = try await store.addDependency(id: a.id, dependsOn: b.id)
        await #expect(throws: TaskError.dependencyCycle) { try await store.addDependency(id: b.id, dependsOn: a.id) }
        // Three-node cycle: A→B→C, then C→A.
        let c = try await store.create(TaskRecord(projectPath: project, title: "C"))
        _ = try await store.addDependency(id: b.id, dependsOn: c.id)
        await #expect(throws: TaskError.dependencyCycle) { try await store.addDependency(id: c.id, dependsOn: a.id) }
    }

    @Test func addIsIdempotentAndRemoveClearsTheEdge() async throws {
        let store = try TaskStore.inMemory()
        let a = try await store.create(TaskRecord(projectPath: project, title: "A"))
        let b = try await store.create(TaskRecord(projectPath: project, title: "B"))
        _ = try await store.addDependency(id: b.id, dependsOn: a.id)
        _ = try await store.addDependency(id: b.id, dependsOn: a.id)   // idempotent
        #expect(try await store.task(id: b.id)?.dependsOn == [a.id])
        #expect(try await store.events(taskID: b.id).filter { $0.kind == .dependencyAdded }.count == 1)
        _ = try await store.removeDependency(id: b.id, dependsOn: a.id)
        #expect(try await store.task(id: b.id)?.dependsOn.isEmpty == true)
        #expect(try await store.events(taskID: b.id).contains { $0.kind == .dependencyRemoved })
    }

    @Test func deleteRefusesWhileDependentsExist() async throws {
        let store = try TaskStore.inMemory()
        let a = try await store.create(TaskRecord(projectPath: project, title: "A"))
        let b = try await store.create(TaskRecord(projectPath: project, title: "B"))
        _ = try await store.addDependency(id: b.id, dependsOn: a.id)
        await #expect(throws: TaskError.hasDependents([b.id])) { try await store.delete(id: a.id) }
        #expect(try await store.task(id: a.id) != nil, "nothing deleted on refusal")
        _ = try await store.removeDependency(id: b.id, dependsOn: a.id)
        try await store.delete(id: a.id)   // now allowed
        #expect(try await store.task(id: a.id) == nil)
    }

    @Test func migratesV1DatabaseAddingDependsOnColumn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-tasks-v1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("records.sqlite").path
        // Build the v1 schema by hand (no depends_on column) and insert a row.
        do {
            let db = try SQLiteDatabase(path: path)
            try db.exec("""
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY, project_path TEXT NOT NULL, title TEXT NOT NULL, details TEXT NOT NULL DEFAULT '',
              acceptance_criteria TEXT, status TEXT NOT NULL, priority TEXT NOT NULL, labels TEXT NOT NULL DEFAULT '[]',
              assigned_agent_session_id TEXT, worktree_path TEXT, blocked_reason TEXT,
              created_at REAL NOT NULL, updated_at REAL NOT NULL, completed_at REAL);
            """)
            try db.run("INSERT INTO tasks (id, project_path, title, status, priority, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
                       [.text("old-1"), .text(project), .text("legacy"), .text("inbox"), .text("normal"), .double(1), .double(1)])
            db.userVersion = 1
        }
        // Opening through TaskStore must migrate to v2 and read the row back with an empty dependsOn.
        let store = try TaskStore(path: path)
        let back = try await store.task(id: "old-1")
        #expect(back?.title == "legacy" && back?.dependsOn == [] && back?.planID == nil)
        #expect(try SQLiteDatabase(path: path).userVersion == TaskStore.schemaVersion)
        // The v3 plan machinery works on the migrated db.
        let p = try await store.createPlan(TaskPlan(projectPath: project, goal: "ship"))
        _ = try await store.assign(taskID: "old-1", toPlan: p.id)
        #expect(try await store.task(id: "old-1")?.planID == p.id)
    }

    @Test func planCrudAssignAndDeleteKeepsTasks() async throws {
        let store = try TaskStore.inMemory()
        let p = try await store.createPlan(TaskPlan(projectPath: project, goal: "Ship auth", verification: "e2e green"))
        #expect(try await store.plans(projectPath: project).map(\.id) == [p.id])
        var edited = p; edited.goal = "Ship auth v2"
        _ = try await store.updatePlan(edited)
        #expect(try await store.plan(id: p.id)?.goal == "Ship auth v2")
        let t = try await store.create(TaskRecord(projectPath: project, title: "login"))
        _ = try await store.assign(taskID: t.id, toPlan: p.id)
        #expect(try await store.task(id: t.id)?.planID == p.id)
        // Cross-project assignment is refused.
        let other = try await store.createPlan(TaskPlan(projectPath: "/tmp/proj-b", goal: "x"))
        await #expect(throws: TaskError.crossProject) { try await store.assign(taskID: t.id, toPlan: other.id) }
        // Deleting the plan unassigns but keeps the task.
        try await store.deletePlan(id: p.id)
        #expect(try await store.plan(id: p.id) == nil)
        #expect(try await store.task(id: t.id)?.planID == nil, "deleting a plan never deletes its tasks")
        // Unassign via nil.
        _ = try await store.assign(taskID: t.id, toPlan: nil)
        #expect(try await store.task(id: t.id)?.planID == nil)
    }

    @Test func twoHundredTasksSearchUnderASecond() async throws {
        let store = try TaskStore.inMemory()
        for i in 0..<200 { try await store.create(TaskRecord(projectPath: project, title: "task \(i)", details: i % 7 == 0 ? "needle" : "hay")) }
        let t0 = ContinuousClock.now
        let hits = try await store.search(text: "needle", projectPath: project)
        #expect(hits.count == 29)
        #expect(ContinuousClock.now - t0 < .seconds(1))
        #expect(try await store.activeCount(projectPath: project) == 200)
    }
}
