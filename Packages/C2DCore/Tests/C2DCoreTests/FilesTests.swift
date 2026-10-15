import Foundation
import Testing
@testable import C2DCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct DirectoryListingTests {
    @Test func sortsDirectoriesFirstAndHidesDotfilesByDefault() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try "x".write(to: d.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: d.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: d.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("zdir"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("link"), withDestinationURL: d.appendingPathComponent("zdir"))
        let names = try DirectoryListing.list(d).map(\.name)
        #expect(names == ["link", "zdir", "A.txt", "b.txt"])
        let link = try DirectoryListing.list(d).first { $0.name == "link" }!
        #expect(link.isSymlink && link.isDirectory)
        #expect(try DirectoryListing.list(d, includeHidden: true).map(\.name).contains(".hidden"))
        #expect(throws: (any Error).self) { try DirectoryListing.list(d.appendingPathComponent("missing")) }
    }
}

@Suite struct TextDocumentTests {
    @Test func loadEditSaveRoundTripPreservesCRLF() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("a.txt")
        try Data("one\r\ntwo\r\n".utf8).write(to: f)
        var doc = try TextDocument.load(path: f.path)
        #expect(doc.lineEnding == .crlf)
        #expect(doc.text == "one\ntwo\n")
        #expect(!doc.isDirty)
        doc.update(text: "one\ntwo\nthree\n")
        #expect(doc.isDirty)
        try doc.save()
        #expect(!doc.isDirty)
        #expect(try Data(contentsOf: f) == Data("one\r\ntwo\r\nthree\r\n".utf8))
        #expect(doc.externalChange() == .none)
    }

    @Test func refusesBinaryOversizedMissingAndUndecodable() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let bin = d.appendingPathComponent("x.bin"); try Data([0x41, 0x00, 0x42]).write(to: bin)
        #expect(throws: TextDocumentError.binary(bin.path)) { try TextDocument.load(path: bin.path) }
        let bad = d.appendingPathComponent("latin1.txt"); try Data([0xC3, 0x28, 0xFF]).write(to: bad)
        #expect(throws: TextDocumentError.undecodable(bad.path)) { try TextDocument.load(path: bad.path) }
        #expect(throws: TextDocumentError.notAFile(d.path)) { try TextDocument.load(path: d.path) }
        let big = d.appendingPathComponent("big.txt")
        let fh = try FileHandle(forWritingTo: { try Data().write(to: big); return big }())
        try fh.truncate(atOffset: UInt64(TextDocument.maximumEditableBytes + 1)); try fh.close()
        #expect(throws: TextDocumentError.tooLarge(bytes: TextDocument.maximumEditableBytes + 1, limit: TextDocument.maximumEditableBytes)) { try TextDocument.load(path: big.path) }
    }

    @Test func detectsExternalModificationAndDeletion() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("a.txt")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        var doc = try TextDocument.load(path: f.path)
        doc.update(text: "mine")
        // External writer changes the file while we hold unsaved edits.
        try "v2 from outside".write(to: f, atomically: true, encoding: .utf8)
        #expect(doc.externalChange() == .modified)
        #expect(doc.isDirty, "our edits are preserved, not silently replaced")
        try doc.reload()
        #expect(doc.text == "v2 from outside" && !doc.isDirty)
        try FileManager.default.removeItem(at: f)
        #expect(doc.externalChange() == .deleted)
        doc.update(text: "recovered")
        #expect(throws: Never.self) { try doc.save() }   // saving recreates the file at the same path, explicitly
        #expect(try String(contentsOf: f, encoding: .utf8) == "recovered")
    }

    @Test func saveFailureKeepsBufferAndDirtyState() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("ro.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        var doc = try TextDocument.load(path: f.path)
        doc.update(text: "changed")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: f.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.path) }
        #expect(throws: (any Error).self) { try doc.save() }
        #expect(doc.isDirty && doc.text == "changed")
    }
}

@Suite(.serialized) struct FileWatcherTests {
    @Test func reportsCreatedFileUnderRoot() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let resolved = d.resolvingSymlinksInPath().path
        let hits = Hits()
        let watcher = try FileWatcher(root: resolved, latency: 0.1) { paths in hits.add(paths) }
        defer { watcher.stop() }
        try? await Task.sleep(for: .milliseconds(200))
        try "hello".write(to: d.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        var seen = false
        for _ in 0..<40 {   // up to 4 s; FSEvents latency is not deterministic
            try? await Task.sleep(for: .milliseconds(100))
            if hits.all.contains(where: { $0.hasSuffix("new.txt") }) { seen = true; break }
        }
        #expect(seen, "saw: \(hits.all)")
    }
}

private final class Hits: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ p: [String]) { lock.lock(); paths += p; lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}
