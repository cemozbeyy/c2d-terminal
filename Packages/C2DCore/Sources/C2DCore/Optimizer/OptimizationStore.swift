import Foundation

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

    public init(id: String = UUID().uuidString, projectPath: String, createdAt: Date = Date(), sourceDescription: String,
                baselineTokens: Int, optimizedTokens: Int, measurementSource: MeasurementSource, actionsSummary: String, optimizerCostTokens: Int = 0) {
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
    }
}

public struct SourceTotals: Hashable, Sendable {
    public let baseline: Int
    public let optimized: Int
    public let count: Int
}

/// Optimization history (ADR-011 record store). Separate database from tasks for now.
public actor OptimizationStore {
    private let db: SQLiteDatabase

    public init(path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: path)
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
    }

    public func record(_ r: OptimizationRecord) throws {
        try db.run("""
        INSERT INTO optimization_records (id, project_path, created_at, source_description, baseline_tokens, optimized_tokens,
          measurement_source, actions_summary, optimizer_cost_tokens) VALUES (?,?,?,?,?,?,?,?,?)
        """, [.text(r.id), .text(r.projectPath), .double(r.createdAt.timeIntervalSince1970), .text(r.sourceDescription),
              .int(Int64(r.baselineTokens)), .int(Int64(r.optimizedTokens)), .text(r.measurementSource.rawValue),
              .text(r.actionsSummary), .int(Int64(r.optimizerCostTokens))])
    }

    public func records(projectPath: String, limit: Int = 100) throws -> [OptimizationRecord] {
        try db.query("""
        SELECT id, project_path, created_at, source_description, baseline_tokens, optimized_tokens, measurement_source,
          actions_summary, optimizer_cost_tokens FROM optimization_records WHERE project_path = ? ORDER BY created_at DESC LIMIT ?
        """, [.text(projectPath), .int(Int64(limit))]) { row in
            OptimizationRecord(id: row.string(0) ?? "", projectPath: row.string(1) ?? "", createdAt: Date(timeIntervalSince1970: row.double(2)),
                               sourceDescription: row.string(3) ?? "", baselineTokens: row.int(4), optimizedTokens: row.int(5),
                               measurementSource: MeasurementSource(rawValue: row.string(6) ?? "") ?? .unavailable,
                               actionsSummary: row.string(7) ?? "", optimizerCostTokens: row.int(8))
        }
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
