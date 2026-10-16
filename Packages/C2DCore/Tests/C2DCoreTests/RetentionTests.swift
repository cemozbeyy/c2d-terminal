import Foundation
import Testing
@testable import C2DCore

// Data retention / cleanup (Bible Part 11 §12.3). Real temp-directory filesystem behavior, no mocks.
@Suite struct RetentionTests {

    private func tempStore() throws -> (JSONDocumentStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-retain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (JSONDocumentStore(directory: dir), dir)
    }

    private func write(_ dir: URL, _ name: String, age: TimeInterval = 0) throws {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path) }
    }
    private func exists(_ dir: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }

    @Test func removesStaleTempButKeepsFreshDocumentsAndRecoveryData() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(["hello"], as: "layouts")          // a real document → layouts.json
        try write(dir, "sessions.json.tmp", age: 3600)    // stale orphan from an interrupted write
        try write(dir, "agents.json.tmp", age: 0)         // fresh — may be an in-flight write
        try write(dir, "records.sqlite")                  // recovery data — must never be touched
        try write(dir, "records.sqlite-wal")
        try write(dir, "records.sqlite-shm")

        let removed = store.cleanupOrphanedTemporaries(olderThan: 60)

        #expect(removed == ["sessions.json.tmp"], "only the stale orphan should go, got \(removed)")
        #expect(!exists(dir, "sessions.json.tmp"))
        #expect(exists(dir, "agents.json.tmp"), "a fresh temp (possible in-flight write) must be kept")
        #expect(exists(dir, "layouts.json"), "real documents are never deleted")
        #expect(exists(dir, "records.sqlite") && exists(dir, "records.sqlite-wal") && exists(dir, "records.sqlite-shm"),
                "SQLite data and its WAL/SHM recovery files must never be deleted")
    }

    @Test func cleanupIsIdempotent() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, "a.json.tmp", age: 3600)
        #expect(store.cleanupOrphanedTemporaries() == ["a.json.tmp"])
        #expect(store.cleanupOrphanedTemporaries() == [], "a second run finds nothing")
    }

    @Test func toleratesMissingDirectoryAndEmptyDirectory() throws {
        let gone = JSONDocumentStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("c2d-nope-\(UUID().uuidString)"))
        #expect(gone.cleanupOrphanedTemporaries() == [], "a missing directory is not an error")
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.cleanupOrphanedTemporaries() == [])
    }

    @Test func restartStillLoadsRealDocumentAfterCleanup() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(["kept"], as: "layouts")
        try write(dir, "layouts.json.tmp", age: 3600)   // crash left a temp beside the good doc
        _ = store.cleanupOrphanedTemporaries()
        // Reopen (restart) and the real document still loads intact.
        let reopened = JSONDocumentStore(directory: dir)
        #expect(try reopened.load([String].self, named: "layouts") == ["kept"])
        #expect(!exists(dir, "layouts.json.tmp"))
    }
}
