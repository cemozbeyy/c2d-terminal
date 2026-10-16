import Foundation
import Testing
@testable import C2DCore

@Suite struct FileReferenceTests {
    @Test func parsesPlainPath() {
        let r = FileReference.parse("App/Foo.swift")
        #expect(r == FileReference(path: "App/Foo.swift", line: nil, column: nil))
    }

    @Test func parsesLineSuffix() {
        #expect(FileReference.parse("App/Foo.swift:12") == FileReference(path: "App/Foo.swift", line: 12, column: nil))
    }

    @Test func parsesLineAndColumn() {
        #expect(FileReference.parse("App/Foo.swift:12:4") == FileReference(path: "App/Foo.swift", line: 12, column: 4))
    }

    @Test func keepsPathWithSpaces() {
        #expect(FileReference.parse("My Project/a b.swift:3") == FileReference(path: "My Project/a b.swift", line: 3, column: nil))
    }

    @Test func stripsWrappingQuotes() {
        #expect(FileReference.parse("\"a.swift:9\"") == FileReference(path: "a.swift", line: 9, column: nil))
    }

    @Test func rejectsEmptyAndNumericOnly() {
        #expect(FileReference.parse("") == nil)
        #expect(FileReference.parse("   ") == nil)
        #expect(FileReference.parse("42") == FileReference(path: "42", line: nil, column: nil)) // bare "42" is a filename, not a location
        #expect(FileReference.parse(":12:4") == nil)   // only a location, no path
    }

    @Test func resolvesRelativeAgainstWorkingDirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/sub/a.swift"
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))

        let resolved = FileReference.resolve("sub/a.swift:7:2", relativeTo: dir)
        #expect(resolved?.path == URL(fileURLWithPath: file).standardizedFileURL.path)
        #expect(resolved?.line == 7)
        #expect(resolved?.column == 2)
    }

    @Test func resolvesAbsoluteIgnoringWorkingDirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/a.swift"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        #expect(FileReference.resolve(file + ":3", relativeTo: "/nonexistent")?.path == URL(fileURLWithPath: file).standardizedFileURL.path)
    }

    @Test func failsForMissingFileDirectoryAndEscape() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/folder", withIntermediateDirectories: true)
        #expect(FileReference.resolve("nope.swift", relativeTo: dir) == nil)        // missing
        #expect(FileReference.resolve("folder", relativeTo: dir) == nil)            // a directory, not a file
        #expect(FileReference.resolve("folder:3", relativeTo: dir) == nil)          // directory with a location
    }

    @Test func resolvesDotParentSegments() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        let file = dir + "/a.swift"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        // From dir/sub, "../a.swift" is dir/a.swift
        #expect(FileReference.resolve("../a.swift:1", relativeTo: dir + "/sub")?.path == URL(fileURLWithPath: file).standardizedFileURL.path)
    }

    private func tempDir() throws -> String {
        let d = NSTemporaryDirectory() + "c2d-fileref-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
}
