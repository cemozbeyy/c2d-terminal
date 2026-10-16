import Foundation

/// Versioned JSON documents written atomically (temp file + rename). One file per document.
/// This is the "documents" half of ADR-011; record-shaped data goes to SQLite later.
public struct JSONDocumentStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/C2D Terminal/<subdirectory>`
    public static func applicationSupport(subdirectory: String = "") throws -> JSONDocumentStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return JSONDocumentStore(directory: base.appendingPathComponent("C2D Terminal").appendingPathComponent(subdirectory))
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    /// Writes to `<name>.json.tmp` then renames over the target, so a crash mid-write leaves
    /// either the old document or the new one, never a torn file.
    public func save<T: Encodable>(_ value: T, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let target = url(for: name)
        let temp = target.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
    }

    /// `nil` when the document does not exist. Corrupt or incompatible documents throw;
    /// callers decide whether to fall back, and must tell the user (Bible Part 3 §10.5).
    public func load<T: Decodable>(_ type: T.Type, named name: String) throws -> T? {
        let target = url(for: name)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let data = try Data(contentsOf: target)
        return try JSONDecoder().decode(type, from: data)
    }

    public func delete(_ name: String) throws {
        let target = url(for: name)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    public func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    /// Removes orphaned atomic-write temporaries (`*.json.tmp`) left by an interrupted save or crash
    /// (Bible Part 11 §12.3, "Failed operation artifacts"). Safe by construction: it touches ONLY our
    /// own `.json.tmp` artifacts in THIS directory — never `.json` documents, `.sqlite`/`-wal`/`-shm`
    /// recovery data, or anything else — and never files younger than `grace`, so an in-flight write is
    /// not removed. Idempotent; per-file errors are swallowed so a vanished/locked file can't abort the
    /// sweep. Returns the file names removed (observable). Non-destructive to user content by design.
    @discardableResult
    public func cleanupOrphanedTemporaries(olderThan grace: TimeInterval = 60, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var removed: [String] = []
        for name in names where name.hasSuffix(".json.tmp") {
            let fileURL = directory.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
            if let modified, now.timeIntervalSince(modified) < grace { continue }   // too fresh — may be in flight
            if (try? fm.removeItem(at: fileURL)) != nil { removed.append(name) }
        }
        return removed.sorted()
    }
}
