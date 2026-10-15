import Foundation

public enum TextDocumentError: Error, Equatable, Sendable {
    case notAFile(String)
    case binary(String)
    case tooLarge(bytes: Int64, limit: Int64)
    case undecodable(String)
    case writeFailed(String)
}

public enum LineEnding: String, Sendable { case lf = "LF", crlf = "CRLF", cr = "CR" }

/// What the file on disk did since we last read or wrote it.
public enum ExternalChange: Equatable, Sendable {
    case none
    case modified
    case deleted
}

/// A text file loaded for editing. Pure model: no UI, no timers. Tracks what was loaded so
/// external modifications can be detected before a save overwrites them (Bible Part 5 §6.2).
public struct TextDocument: Sendable, Equatable {
    public static let maximumEditableBytes: Int64 = 4 * 1024 * 1024

    public let path: String
    public private(set) var text: String
    public private(set) var savedText: String
    public let lineEnding: LineEnding
    public private(set) var loadedModificationDate: Date?
    public private(set) var loadedSize: Int64

    public var isDirty: Bool { text != savedText }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var languageHint: String { URL(fileURLWithPath: path).pathExtension.lowercased() }

    /// Reads the file. Refuses binaries, oversized files and non-UTF-8 content with typed errors.
    public static func load(path: String) throws -> TextDocument {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw TextDocumentError.notAFile(path)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maximumEditableBytes else { throw TextDocumentError.tooLarge(bytes: size, limit: maximumEditableBytes) }
        let data = try Data(contentsOf: url)
        if looksBinary(data) { throw TextDocumentError.binary(path) }
        guard let raw = String(data: data, encoding: .utf8) else { throw TextDocumentError.undecodable(path) }
        let ending = detectLineEnding(raw)
        let normalized = ending == .lf ? raw : raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return TextDocument(path: path, text: normalized, savedText: normalized, lineEnding: ending,
                            loadedModificationDate: attrs[.modificationDate] as? Date, loadedSize: size)
    }

    public mutating func update(text: String) { self.text = text }

    /// Writes the buffer with the original line endings; atomic replace so a crash never leaves a torn file.
    /// Returns the new modification date. Does not check for external changes — call `externalChange()` first.
    public mutating func save() throws {
        let out = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding == .crlf ? "\r\n" : "\r")
        do {
            try Data(out.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw TextDocumentError.writeFailed("\(error.localizedDescription)")
        }
        savedText = text
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        loadedModificationDate = attrs[.modificationDate] as? Date
        loadedSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Compares the file on disk with what was last loaded or saved.
    public func externalChange() -> ExternalChange {
        guard FileManager.default.fileExists(atPath: path) else { return .deleted }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return .modified }
        let date = attrs[.modificationDate] as? Date
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        if date != loadedModificationDate || size != loadedSize { return .modified }
        return .none
    }

    /// Re-reads from disk, replacing the buffer. Used when the user chooses the on-disk version.
    public mutating func reload() throws {
        let fresh = try TextDocument.load(path: path)
        self = fresh
    }

    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    static func detectLineEnding(_ s: String) -> LineEnding {
        if s.contains("\r\n") { return .crlf }
        if s.contains("\r") { return .cr }
        return .lf
    }
}
