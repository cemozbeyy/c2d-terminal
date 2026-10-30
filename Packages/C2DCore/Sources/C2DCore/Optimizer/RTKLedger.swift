import Foundation

/// RTK's own record of the commands it filtered (`history.db`, table `commands`), read strictly read-only. RTK counts
/// `ceil(bytes/4)` of the raw and the shown output per command — the same heuristic as `GainReport.estimatedTokens` —
/// so its count can sit in the unified Token Saver report as the RTK-powered contribution, labelled as RTK's measure.
/// Never written, never estimated: when the file or its schema is not what this reader knows, the result is
/// `.unavailable(reason)` and the report leaves RTK out instead of guessing.
public struct RTKLedger: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public var family: String
        public var commands = 0
        public var inputTokens = 0
        public var outputTokens = 0
        /// Signed, as RTK stores it.
        public var savedTokens = 0
        public var execMilliseconds = 0
    }

    public enum Result: Hashable, Sendable {
        case available(RTKLedger)
        case unavailable(String)
        public var ledger: RTKLedger? { if case .available(let l) = self { return l }; return nil }
    }

    public let total: Row
    public let byFamily: [Row]
    /// First and last record dates (`yyyy-MM-dd`, as RTK stored them), nil when there are none.
    public let firstDay: String?
    public let lastDay: String?

    public static let requiredColumns: Set<String> = ["original_cmd", "input_tokens", "output_tokens", "saved_tokens", "timestamp"]

    /// RTK's data directory on macOS (`dirs::data_dir()` = Application Support).
    public static func defaultPath() -> String {
        #if DEBUG
        // Runtime checks point the reader elsewhere (e.g. a missing file for the empty state); never in Release.
        if let override = ProcessInfo.processInfo.environment["C2D_RTK_HISTORY"], !override.isEmpty { return override }
        #endif
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/rtk/history.db").path
    }

    /// `projectPath` nil = every project; otherwise rows whose `project_path` is that directory or below it.
    /// `windows` non-nil = only rows whose timestamp falls inside one of them (e.g. while a C2D-launched session ran).
    /// RTK records no session id, so a window match is approximate: another agent in the same folder at the same time counts too.
    public static func read(path: String = defaultPath(), projectPath: String?, windows: [ClosedRange<Date>]? = nil) -> Result {
        guard FileManager.default.fileExists(atPath: path) else { return .unavailable("No RTK history at \(abbreviated(path)).") }
        let db: SQLiteDatabase
        do { db = try SQLiteDatabase(readOnly: path) } catch { return .unavailable("RTK history could not be opened read-only (\(error)).") }
        defer { db.close() }
        do {
            let columns = Set(try db.query("PRAGMA table_info(commands)") { $0.string(1) ?? "" })
            guard requiredColumns.isSubset(of: columns) else {
                return .unavailable("RTK history has an unknown layout (missing \(requiredColumns.subtracting(columns).sorted().joined(separator: ", "))); not read.")
            }
            if projectPath != nil, !columns.contains("project_path") {
                return .unavailable("This RTK version does not record a project per command; use --global.")
            }
            let time = columns.contains("exec_time_ms") ? "exec_time_ms" : "0"
            var sql = "SELECT original_cmd, input_tokens, output_tokens, saved_tokens, \(time), substr(timestamp, 1, 10), timestamp FROM commands"
            var params: [SQLiteValue] = []
            if let projectPath {
                let root = URL(fileURLWithPath: projectPath).standardizedFileURL.path
                let escaped = root.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                sql += " WHERE project_path = ? OR project_path LIKE ? ESCAPE '\\'"
                params = [.text(root), .text(escaped + "/%")]
            }
            var total = Row(family: "total"), rows: [String: Row] = [:], first: String?, last: String?, unparsed = 0
            // The command text is read only to derive its family and is not kept.
            _ = try db.query(sql, params) { r -> Void in
                if let windows {
                    guard let at = r.string(6).flatMap(parseTimestamp) else { unparsed += 1; return }
                    guard windows.contains(where: { $0.contains(at) }) else { return }
                }
                let family = Replay.family(of: r.string(0) ?? "")
                var row = rows[family] ?? Row(family: family)
                for i in 0..<2 {
                    var x = i == 0 ? total : row
                    x.commands += 1; x.inputTokens += r.int(1); x.outputTokens += r.int(2); x.savedTokens += r.int(3); x.execMilliseconds += r.int(4)
                    if i == 0 { total = x } else { row = x }
                }
                rows[family] = row
                if let day = r.string(5) { first = min(first ?? day, day); last = max(last ?? day, day) }
            }
            // A time filter that cannot read a timestamp would silently drop rows: leave RTK out instead.
            if unparsed > 0 { return .unavailable("\(unparsed) RTK timestamp(s) in an unknown format; not matched to C2D sessions.") }
            return .available(RTKLedger(total: total, byFamily: rows.values.sorted { ($0.savedTokens, $1.family) > ($1.savedTokens, $0.family) },
                                        firstDay: first, lastDay: last))
        } catch {
            return .unavailable("RTK history could not be read (\(error)).")
        }
    }

    /// RFC 3339 with any number of fractional digits (`…T10:12:13.123456789+00:00`), or SQLite's `2026-10-26 10:12:13` (UTC).
    static func parseTimestamp(_ s: String) -> Date? {
        var t = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression).replacingOccurrences(of: " ", with: "T")
        if !t.contains("Z"), !t.contains("+"), t.range(of: #"-\d\d:?\d\d$"#, options: .regularExpression) == nil { t += "Z" }
        return ISO8601DateFormatter().date(from: t)
    }

    static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
