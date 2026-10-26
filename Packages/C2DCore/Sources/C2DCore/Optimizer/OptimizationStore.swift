import Foundation

/// Where an optimization result went. `prepared` = the user pressed Optimize and the result is shown in the panel
/// (the preview; nothing left C2D). The other two are hand-offs the user triggered — still never "read by the agent".
public enum OptimizationStage: String, Codable, Hashable, Sendable, CaseIterable {
    case prepared, copiedToClipboard, writtenToFile
    public var isHandOff: Bool { self != .prepared }
    public var label: String {
        switch self { case .prepared: "prepared"; case .copiedToClipboard: "copied"; case .writtenToFile: "written to .c2d/context.md" }
    }
}

public enum OptimizationMode: String, Codable, Hashable, Sendable { case lossless, lossy }

public struct OptimizationRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let projectPath: String
    public let createdAt: Date
    public let sourceDescription: String
    public let baselineTokens: Int
    public let optimizedTokens: Int
    public let measurementSource: MeasurementSource
    public let actionsSummary: String
    public let optimizerCostTokens: Int
    /// Measured UTF-8 bytes before/after, mode and stage. nil on records from before schema v2 (manual "Record").
    public let originalBytes: Int?
    public let resultBytes: Int?
    public let mode: OptimizationMode?
    public let stage: OptimizationStage?

    public init(id: String = UUID().uuidString, projectPath: String, createdAt: Date = Date(), sourceDescription: String,
                baselineTokens: Int, optimizedTokens: Int, measurementSource: MeasurementSource, actionsSummary: String, optimizerCostTokens: Int = 0,
                originalBytes: Int? = nil, resultBytes: Int? = nil, mode: OptimizationMode? = nil, stage: OptimizationStage? = nil) {
        self.id = id
        self.projectPath = projectPath
        // Millisecond precision so a record read back from a REAL column equals the one stored.
        self.createdAt = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.sourceDescription = sourceDescription
        self.baselineTokens = baselineTokens
        self.optimizedTokens = optimizedTokens
        self.measurementSource = measurementSource
        self.actionsSummary = actionsSummary
        self.optimizerCostTokens = optimizerCostTokens
        self.originalBytes = originalBytes; self.resultBytes = resultBytes; self.mode = mode; self.stage = stage
    }

    /// The event for one real optimization the user invoked, or nil when nothing was reduced (an unchanged or
    /// larger result is never recorded as an optimization). Bytes are measured; tokens are the heuristic estimate.
    public static func event(original: ContextPayload, result: OptimizationResult, stage: OptimizationStage,
                             projectPath: String, at date: Date = Date()) -> OptimizationRecord? {
        let before = original.byteCount, after = result.payload.byteCount
        guard after < before, !result.actions.isEmpty else { return nil }
        let kinds = Set(original.items.map(\.kind.rawValue)).sorted().joined(separator: ", ")
        return OptimizationRecord(projectPath: projectPath, createdAt: date, sourceDescription: "\(original.items.count) item(s): \(kinds)",
                                  baselineTokens: result.before.tokens, optimizedTokens: result.after.tokens, measurementSource: .heuristicEstimate,
                                  actionsSummary: Set(result.actions.map(\.kind.rawValue)).sorted().joined(separator: ", "),
                                  originalBytes: before, resultBytes: after, mode: result.lossyStepsApplied ? .lossy : .lossless, stage: stage)
    }
}

/// Sums of recorded events for one stage. Bytes are measured; tokens are heuristic estimates.
public struct EventTotals: Hashable, Sendable {
    public let count: Int
    public let originalBytes: Int
    public let resultBytes: Int
    public let originalTokens: Int
    public let resultTokens: Int
    public init(count: Int, originalBytes: Int, resultBytes: Int, originalTokens: Int, resultTokens: Int) {
        self.count = count; self.originalBytes = originalBytes; self.resultBytes = resultBytes
        self.originalTokens = originalTokens; self.resultTokens = resultTokens
    }
    public var byteReductionPercent: Double? { originalBytes > 0 ? Double(originalBytes - resultBytes) / Double(originalBytes) * 100 : nil }
    public var estimatedTokenReduction: Int { originalTokens - resultTokens }
}

public struct SourceTotals: Hashable, Sendable {
    public let baseline: Int
    public let optimized: Int
    public let count: Int
}

/// Optimization history (ADR-011 record store). Separate database from tasks for now.
public actor OptimizationStore {
    private let db: SQLiteDatabase

    /// A hook process passes a short `busyTimeoutMilliseconds`: it drops its event rather than hold up a tool call.
    public init(path: String, busyTimeoutMilliseconds: Int32 = 2000) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        try Self.migrate(db)
    }

    public static func inMemory() throws -> OptimizationStore { try OptimizationStore(db: SQLiteDatabase(path: ":memory:")) }

    private init(db: SQLiteDatabase) throws {
        self.db = db
        try Self.migrate(db)
    }

    public static func standardPath() throws -> String {
        try JSONDocumentStore.applicationSupport().directory.appendingPathComponent("optimizer.sqlite").path
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        if db.userVersion < 1 {
            try db.inTransaction {
                try db.exec("""
                CREATE TABLE IF NOT EXISTS optimization_records (
                  id TEXT PRIMARY KEY, project_path TEXT NOT NULL, created_at REAL NOT NULL, source_description TEXT NOT NULL,
                  baseline_tokens INTEGER NOT NULL, optimized_tokens INTEGER NOT NULL, measurement_source TEXT NOT NULL,
                  actions_summary TEXT NOT NULL, optimizer_cost_tokens INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS optimization_records_project ON optimization_records(project_path, created_at);
                """)
            }
            db.userVersion = 1
        }
        if db.userVersion < 2 {   // optimization events: measured bytes, mode and stage (older rows keep NULL)
            try db.inTransaction {
                try db.exec("""
                ALTER TABLE optimization_records ADD COLUMN original_bytes INTEGER;
                ALTER TABLE optimization_records ADD COLUMN result_bytes INTEGER;
                ALTER TABLE optimization_records ADD COLUMN mode TEXT;
                ALTER TABLE optimization_records ADD COLUMN stage TEXT;
                """)
            }
            db.userVersion = 2
        }
        if db.userVersion < 3 {   // `c2d gain` events (plan C2D_GAIN_PLAN_2026-10-26 P0); live and replay rows are never mixed
            try db.inTransaction {
                try db.exec("""
                CREATE TABLE IF NOT EXISTS token_saver_events (
                  id INTEGER PRIMARY KEY, ts REAL NOT NULL, source TEXT NOT NULL CHECK (source IN ('live', 'replay')),
                  project TEXT NOT NULL, session_id TEXT, tool_use_id TEXT, family TEXT NOT NULL, mode TEXT NOT NULL,
                  outcome TEXT NOT NULL CHECK (outcome IN ('emitted', 'skipped')), skip_reason TEXT,
                  original_stdout_bytes INTEGER NOT NULL, result_stdout_bytes INTEGER NOT NULL, stderr_bytes INTEGER, helper_ms INTEGER);
                CREATE INDEX IF NOT EXISTS token_saver_events_scope ON token_saver_events(source, project, ts);
                """)
            }
            db.userVersion = 3
        }
    }

    // MARK: Token Saver events (`c2d gain`)

    public func record(events: [GainEvent]) throws {
        try db.inTransaction { try insert(events) }
    }

    private func insert(_ events: [GainEvent]) throws {
        for e in events {
            try db.run("""
            INSERT INTO token_saver_events (ts, source, project, session_id, tool_use_id, family, mode, outcome, skip_reason,
              original_stdout_bytes, result_stdout_bytes, stderr_bytes, helper_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.double(e.timestamp.timeIntervalSince1970), .text(e.source.rawValue), .text(e.project),
                  e.sessionID.map { .text($0) } ?? .null, e.toolUseID.map { .text($0) } ?? .null, .text(e.family), .text(e.mode),
                  .text(e.outcome.rawValue), e.skipReason.map { .text($0.rawValue) } ?? .null,
                  .int(Int64(e.originalStdoutBytes)), .int(Int64(e.resultStdoutBytes)),
                  e.stderrBytes.map { .int(Int64($0)) } ?? .null, e.helperMilliseconds.map { .int(Int64($0)) } ?? .null])
        }
    }

    /// Events of one source only (a query can never return both), newest first; `project` nil = every project.
    public func events(source: GainEvent.Source, project: String? = nil, limit: Int? = nil) throws -> [GainEvent] {
        var params: [SQLiteValue] = [.text(source.rawValue)]
        if let project { params.append(.text(project)) }
        if let limit { params.append(.int(Int64(limit))) }
        return try db.query("""
        SELECT ts, source, project, session_id, tool_use_id, family, mode, outcome, skip_reason, original_stdout_bytes,
          result_stdout_bytes, stderr_bytes, helper_ms FROM token_saver_events
          WHERE source = ?\(project == nil ? "" : " AND project = ?") ORDER BY ts DESC, id DESC\(limit == nil ? "" : " LIMIT ?")
        """, params) { row in
            GainEvent(timestamp: Date(timeIntervalSince1970: row.double(0)), source: GainEvent.Source(rawValue: row.string(1) ?? "") ?? source,
                      project: row.string(2) ?? "", sessionID: row.string(3), toolUseID: row.string(4), family: row.string(5) ?? "other",
                      mode: row.string(6) ?? "", outcome: GainEvent.Outcome(rawValue: row.string(7) ?? "") ?? .skipped,
                      skipReason: row.string(8).flatMap(GainEvent.SkipReason.init(rawValue:)),
                      originalStdoutBytes: row.int(9), resultStdoutBytes: row.int(10),
                      stderrBytes: row.isNull(11) ? nil : row.int(11), helperMilliseconds: row.isNull(12) ? nil : row.int(12))
        }
    }

    /// A replay export replaces the previous one instead of piling up duplicates. Live rows are never deleted here.
    public func replaceReplayEvents(with events: [GainEvent]) throws {
        try db.inTransaction {
            try db.run("DELETE FROM token_saver_events WHERE source = 'replay'")
            try insert(events.filter { $0.source == .replay })
        }
    }

    public func record(_ r: OptimizationRecord) throws {
        try db.run("""
        INSERT INTO optimization_records (id, project_path, created_at, source_description, baseline_tokens, optimized_tokens,
          measurement_source, actions_summary, optimizer_cost_tokens, original_bytes, result_bytes, mode, stage) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.text(r.id), .text(r.projectPath), .double(r.createdAt.timeIntervalSince1970), .text(r.sourceDescription),
              .int(Int64(r.baselineTokens)), .int(Int64(r.optimizedTokens)), .text(r.measurementSource.rawValue),
              .text(r.actionsSummary), .int(Int64(r.optimizerCostTokens)),
              r.originalBytes.map { .int(Int64($0)) } ?? .null, r.resultBytes.map { .int(Int64($0)) } ?? .null,
              r.mode.map { .text($0.rawValue) } ?? .null, r.stage.map { .text($0.rawValue) } ?? .null])
    }

    public func records(projectPath: String, limit: Int = 100) throws -> [OptimizationRecord] {
        try db.query("""
        SELECT id, project_path, created_at, source_description, baseline_tokens, optimized_tokens, measurement_source,
          actions_summary, optimizer_cost_tokens, original_bytes, result_bytes, mode, stage FROM optimization_records
          WHERE project_path = ? ORDER BY created_at DESC LIMIT ?
        """, [.text(projectPath), .int(Int64(limit))]) { row in
            OptimizationRecord(id: row.string(0) ?? "", projectPath: row.string(1) ?? "", createdAt: Date(timeIntervalSince1970: row.double(2)),
                               sourceDescription: row.string(3) ?? "", baselineTokens: row.int(4), optimizedTokens: row.int(5),
                               measurementSource: MeasurementSource(rawValue: row.string(6) ?? "") ?? .unavailable,
                               actionsSummary: row.string(7) ?? "", optimizerCostTokens: row.int(8),
                               originalBytes: row.isNull(9) ? nil : row.int(9), resultBytes: row.isNull(10) ? nil : row.int(10),
                               mode: row.string(11).flatMap(OptimizationMode.init(rawValue:)), stage: row.string(12).flatMap(OptimizationStage.init(rawValue:)))
        }
    }

    /// Per-stage sums over every recorded event of the project (not just the newest page of history).
    public func eventTotals(projectPath: String) throws -> [OptimizationStage: EventTotals] {
        let rows = try db.query("""
        SELECT stage, COUNT(*), SUM(original_bytes), SUM(result_bytes), SUM(baseline_tokens), SUM(optimized_tokens) FROM optimization_records
          WHERE project_path = ? AND stage IS NOT NULL AND original_bytes IS NOT NULL AND result_bytes IS NOT NULL GROUP BY stage
        """, [.text(projectPath)]) { row in
            (row.string(0) ?? "", EventTotals(count: row.int(1), originalBytes: row.int(2), resultBytes: row.int(3), originalTokens: row.int(4), resultTokens: row.int(5)))
        }
        var out: [OptimizationStage: EventTotals] = [:]
        for (key, t) in rows { if let s = OptimizationStage(rawValue: key) { out[s] = t } }
        return out
    }

    /// Per-source totals; sources are never summed together (Bible Part 10 §13).
    public func aggregate(projectPath: String) throws -> [MeasurementSource: SourceTotals] {
        let rows = try db.query("""
        SELECT measurement_source, SUM(baseline_tokens), SUM(optimized_tokens), COUNT(*) FROM optimization_records
          WHERE project_path = ? GROUP BY measurement_source
        """, [.text(projectPath)]) { row in (row.string(0) ?? "", SourceTotals(baseline: row.int(1), optimized: row.int(2), count: row.int(3))) }
        var out: [MeasurementSource: SourceTotals] = [:]
        for (key, totals) in rows { if let s = MeasurementSource(rawValue: key) { out[s] = totals } }
        return out
    }
}
