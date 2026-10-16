import Foundation

/// A file path plus an optional source location, as found in terminal or agent output
/// ("App/Foo.swift:12:4"). Parsing and resolution are pure so they can be unit-tested and
/// run off the main actor; the terminal engine does the detection (Bible Part 4 §5.4, Part 5 §7.3).
public struct FileReference: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    /// A file that exists on disk, with the location carried through.
    public struct Resolved: Equatable, Sendable {
        public let path: String
        public let line: Int?
        public let column: Int?
    }

    /// Splits a detected token into a path and an optional `:line` / `:line:col` suffix.
    /// Returns nil for an empty token or one that is only digits/colons. The token is taken as
    /// given (it may contain spaces); this never scans arbitrary text for a path.
    public static func parse(_ raw: String) -> FileReference? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip one layer of wrapping quotes/backticks and surrounding angle brackets.
        for (open, close) in [("\"", "\""), ("'", "'"), ("`", "`"), ("<", ">"), ("(", ")"), ("[", "]")] {
            if s.count >= 2, s.hasPrefix(open), s.hasSuffix(close) { s = String(s.dropFirst().dropLast()) }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Peel up to two trailing ":<digits>" groups. Last peeled is the leftmost number (the line).
        var numbers: [Int] = []
        while numbers.count < 2, let r = s.range(of: #":[0-9]+$"#, options: .regularExpression) {
            numbers.append(Int(s[r].dropFirst())!)
            s = String(s[..<r.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }   // was only digits/colons

        let line = numbers.last          // first number after the path
        let column = numbers.count == 2 ? numbers.first : nil
        return FileReference(path: s, line: line, column: column)
    }

    /// Resolves the path against `workingDirectory` (absolute paths and `~` are honoured) and
    /// confirms it is an existing regular file, never a directory. Returns nil otherwise so the
    /// caller can fail gracefully instead of opening the wrong thing.
    public func resolve(relativeTo workingDirectory: String, fileManager: FileManager = .default) -> Resolved? {
        let expanded = NSString(string: path).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = URL(fileURLWithPath: workingDirectory).appendingPathComponent(expanded).path
        }
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return Resolved(path: standardized, line: line, column: column)
    }

    /// Convenience: parse then resolve in one step.
    public static func resolve(_ raw: String, relativeTo workingDirectory: String, fileManager: FileManager = .default) -> Resolved? {
        parse(raw)?.resolve(relativeTo: workingDirectory, fileManager: fileManager)
    }
}
