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
        #expect(db.userVersion == 1)
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
