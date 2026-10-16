import Foundation

/// Record store for tasks and their events (ADR-011). Owns one SQLite database.
/// It never completes a task on its own: completion is an explicit `transition` by a caller.
public actor TaskStore {
    static let schemaVersion = 2
    private let db: SQLiteDatabase

    public init(path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
    }

    public static func inMemory() throws -> TaskStore { try TaskStore(db: SQLiteDatabase(path: ":memory:")) }

    private init(db: SQLiteDatabase) throws {
        self.db = db
        try Self.migrate(db)
    }

    public static func standardPath() throws -> String {
        try JSONDocumentStore.applicationSupport().directory.appendingPathComponent("records.sqlite").path
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        if db.userVersion < 1 {
            try db.inTransaction {
                try db.exec("""
                CREATE TABLE IF NOT EXISTS tasks (
                  id TEXT PRIMARY KEY, project_path TEXT NOT NULL, title TEXT NOT NULL, details TEXT NOT NULL DEFAULT '',
                  acceptance_criteria TEXT, status TEXT NOT NULL, priority TEXT NOT NULL, labels TEXT NOT NULL DEFAULT '[]',
                  assigned_agent_session_id TEXT, worktree_path TEXT, blocked_reason TEXT,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL, completed_at REAL);
                CREATE INDEX IF NOT EXISTS tasks_project ON tasks(project_path, status);
                CREATE TABLE IF NOT EXISTS task_events (
                  id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                  at REAL NOT NULL, kind TEXT NOT NULL, detail TEXT, from_status TEXT, to_status TEXT, seq INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS task_events_task ON task_events(task_id, seq);
                """)
            }
            db.userVersion = 1
        }
        if db.userVersion < 2 {
            // Existing rows default to no dependencies; '[]' keeps the JSON-array contract uniform.
            try db.inTransaction { try db.exec("ALTER TABLE tasks ADD COLUMN depends_on TEXT NOT NULL DEFAULT '[]';") }
            db.userVersion = 2
        }
    }

    // MARK: Writes

    /// Millisecond precision so a record read back from REAL columns equals the one returned.
    private static func now() -> Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000) }

    @discardableResult
    public func create(_ task: TaskRecord) throws -> TaskRecord {
        var t = task
        t.createdAt = Self.now(); t.updatedAt = t.createdAt
        try wrap {
            try db.inTransaction {
                try insert(t)
                try append(TaskEvent(taskID: t.id, kind: .created))
            }
        }
        return t
    }

    /// Replaces mutable fields; records an `edited` event naming what changed. Status is not
    /// changed here — use `transition`.
    @discardableResult
    public func update(_ record: TaskRecord) throws -> TaskRecord {
        guard let old = try task(id: record.id) else { throw TaskError.notFound(record.id) }
        var t = record
        t.status = old.status; t.createdAt = old.createdAt; t.completedAt = old.completedAt; t.blockedReason = old.blockedReason
        t.dependsOn = old.dependsOn   // edited only via addDependency/removeDependency (cycle-checked)
        t.updatedAt = Self.now()
        var changed: [String] = []
        if old.title != t.title { changed.append("title") }
        if old.details != t.details { changed.append("details") }
        if old.acceptanceCriteria != t.acceptanceCriteria { changed.append("acceptanceCriteria") }
        if old.priority != t.priority { changed.append("priority") }
        if old.labels != t.labels { changed.append("labels") }
        if old.worktreePath != t.worktreePath { changed.append("worktreePath") }
        let assigned = old.assignedAgentSessionID != t.assignedAgentSessionID
        try wrap {
            try db.inTransaction {
                try write(t)
                if !changed.isEmpty { try append(TaskEvent(taskID: t.id, kind: .edited, detail: changed.joined(separator: ","))) }
                if assigned { try append(TaskEvent(taskID: t.id, kind: .assigned, detail: t.assignedAgentSessionID)) }
            }
        }
        return t
    }

    /// `override` bypasses the dependency gate on a start (the caller showed the blockers and the
    /// user chose to proceed). Nothing else may start a dependent against an unmet prerequisite.
    @discardableResult
    public func transition(id: String, to next: TaskStatus, note: String? = nil, override: Bool = false) throws -> TaskRecord {
        guard var t = try task(id: id) else { throw TaskError.notFound(id) }
        guard t.status.canTransition(to: next) else { throw TaskError.invalidTransition(from: t.status, to: next) }
        if next == .inProgress, !override, !t.dependsOn.isEmpty {
            let graph = try projectGraph(t.projectPath)
            let unmet = t.unmetDependencies { graph[$0]?.status }
            if !unmet.isEmpty { throw TaskError.dependenciesUnmet(unmet) }
        }
        let from = t.status
        t.status = next
        t.updatedAt = Self.now()
        t.completedAt = next == .completed ? t.updatedAt : (next == .ready ? nil : t.completedAt)
        if next != .blocked { t.blockedReason = nil }
        try wrap {
            try db.inTransaction {
                try write(t)
                try append(TaskEvent(taskID: id, kind: .statusChanged, detail: note, fromStatus: from, toStatus: next))
            }
        }
        return t
    }

    @discardableResult
    public func setBlocked(id: String, reason: String) throws -> TaskRecord {
        guard var t = try task(id: id) else { throw TaskError.notFound(id) }
        let from = t.status
        if from != .blocked { guard from.canTransition(to: .blocked) else { throw TaskError.invalidTransition(from: from, to: .blocked) } }
        t.status = .blocked; t.blockedReason = reason; t.updatedAt = Self.now()
        try wrap {
            try db.inTransaction {
                try write(t)
                try append(TaskEvent(taskID: id, kind: .blocked, detail: reason, fromStatus: from, toStatus: .blocked))
            }
        }
        return t
    }

    /// Returns the task to `ready`.
    @discardableResult
    public func clearBlocked(id: String) throws -> TaskRecord {
        guard var t = try task(id: id), t.status == .blocked else { throw TaskError.notFound(id) }
        t.status = .ready; t.blockedReason = nil; t.updatedAt = Self.now()
        try wrap {
            try db.inTransaction {
                try write(t)
                try append(TaskEvent(taskID: id, kind: .unblocked, fromStatus: .blocked, toStatus: .ready))
            }
        }
        return t
    }

    public func addNote(id: String, _ text: String) throws {
        guard try task(id: id) != nil else { throw TaskError.notFound(id) }
        try wrap { try append(TaskEvent(taskID: id, kind: .note, detail: text)) }
    }

    /// Deletes the task and its events. Files, branches and worktrees are untouched (Part 8 §25).
    /// Refuses while other tasks still depend on this one, so a dependent is never left blocked by a
    /// prerequisite the user can no longer see (Bible Part 8 §12). Remove those edges first.
    public func delete(id: String) throws {
        guard let t = try task(id: id) else { throw TaskError.notFound(id) }
        let dependents = try projectGraph(t.projectPath).values.filter { $0.dependsOn.contains(id) }.map(\.id)
        if !dependents.isEmpty { throw TaskError.hasDependents(dependents) }
        try wrap { try db.run("DELETE FROM tasks WHERE id=?", [.text(id)]) }
    }

    // MARK: Dependencies (Bible Part 8 §12)

    /// All tasks of a project keyed by id, terminal states included, for dependency resolution and
    /// cycle detection — never the status-filtered snapshot the UI shows.
    private func projectGraph(_ projectPath: String) throws -> [String: TaskRecord] {
        let all = try wrap { try db.query(Self.selectSQL + " WHERE project_path=?", [.text(projectPath)], Self.row) }
        return Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// True if `target` is reachable from `start` by following `dependsOn` edges (used for cycles).
    static func reaches(from start: String, to target: String, in graph: [String: TaskRecord]) -> Bool {
        var stack = [start], seen = Set<String>()
        while let cur = stack.popLast() {
            if cur == target { return true }
            guard seen.insert(cur).inserted, let node = graph[cur] else { continue }
            stack.append(contentsOf: node.dependsOn)
        }
        return false
    }

    /// Adds `id depends on upstreamID`. Idempotent. Rejects self-, cross-project, missing, and cyclic edges.
    @discardableResult
    public func addDependency(id: String, dependsOn upstreamID: String) throws -> TaskRecord {
        guard id != upstreamID else { throw TaskError.selfDependency }
        guard var t = try task(id: id) else { throw TaskError.notFound(id) }
        guard let upstream = try task(id: upstreamID) else { throw TaskError.notFound(upstreamID) }
        guard upstream.projectPath == t.projectPath else { throw TaskError.crossProjectDependency }
        if t.dependsOn.contains(upstreamID) { return t }
        // Adding id→upstream forms a cycle iff upstream can already reach id by its own dependencies.
        if Self.reaches(from: upstreamID, to: id, in: try projectGraph(t.projectPath)) { throw TaskError.dependencyCycle }
        t.dependsOn.append(upstreamID); t.updatedAt = Self.now()
        try wrap { try db.inTransaction {
            try write(t)
            try append(TaskEvent(taskID: id, kind: .dependencyAdded, detail: upstreamID))
        } }
        return t
    }

    @discardableResult
    public func removeDependency(id: String, dependsOn upstreamID: String) throws -> TaskRecord {
        guard var t = try task(id: id) else { throw TaskError.notFound(id) }
        guard let idx = t.dependsOn.firstIndex(of: upstreamID) else { return t }
        t.dependsOn.remove(at: idx); t.updatedAt = Self.now()
        try wrap { try db.inTransaction {
            try write(t)
            try append(TaskEvent(taskID: id, kind: .dependencyRemoved, detail: upstreamID))
        } }
        return t
    }

    // MARK: Reads

    public func task(id: String) throws -> TaskRecord? {
        try wrap { try db.query(Self.selectSQL + " WHERE id=?", [.text(id)], Self.row).first }
    }

    public func tasks(projectPath: String, includeTerminal: Bool = false) throws -> [TaskRecord] {
        let filter = includeTerminal ? "" : " AND status NOT IN ('completed','cancelled')"
        return try wrap { try db.query(Self.selectSQL + " WHERE project_path=?" + filter + " ORDER BY updated_at DESC", [.text(projectPath)], Self.row) }
    }

    public func search(text: String, projectPath: String? = nil) throws -> [TaskRecord] {
        let like = "%" + text.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        var sql = Self.selectSQL + " WHERE (title LIKE ? ESCAPE '\\' OR details LIKE ? ESCAPE '\\')"
        var params: [SQLiteValue] = [.text(like), .text(like)]
        if let projectPath { sql += " AND project_path=?"; params.append(.text(projectPath)) }
        return try wrap { try db.query(sql + " ORDER BY updated_at DESC", params, Self.row) }
    }

    public func events(taskID: String) throws -> [TaskEvent] {
        try wrap {
            try db.query("SELECT id, task_id, at, kind, detail, from_status, to_status FROM task_events WHERE task_id=? ORDER BY seq", [.text(taskID)]) { r in
                TaskEvent(id: r.string(0)!, taskID: r.string(1)!, at: Date(timeIntervalSince1970: r.double(2)),
                          kind: TaskEventKind(rawValue: r.string(3)!) ?? .note, detail: r.string(4),
                          fromStatus: r.string(5).flatMap(TaskStatus.init), toStatus: r.string(6).flatMap(TaskStatus.init))
            }
        }
    }

    public func activeCount(projectPath: String) throws -> Int {
        try wrap { try db.scalarInt("SELECT COUNT(*) FROM tasks WHERE project_path=? AND status NOT IN ('completed','cancelled')", [.text(projectPath)]) }
    }

    // MARK: SQL

    private static let selectSQL = "SELECT id, project_path, title, details, acceptance_criteria, status, priority, labels, assigned_agent_session_id, worktree_path, blocked_reason, created_at, updated_at, completed_at, depends_on FROM tasks"

    private static func row(_ r: SQLiteDatabase.Row) -> TaskRecord {
        func json(_ s: String?) -> [String] { (try? JSONDecoder().decode([String].self, from: Data((s ?? "[]").utf8))) ?? [] }
        return TaskRecord(id: r.string(0)!, projectPath: r.string(1)!, title: r.string(2)!, details: r.string(3) ?? "",
                          acceptanceCriteria: r.string(4), status: TaskStatus(rawValue: r.string(5)!) ?? .inbox,
                          priority: TaskPriority(rawValue: r.string(6)!) ?? .normal, labels: json(r.string(7)),
                          assignedAgentSessionID: r.string(8), worktreePath: r.string(9), blockedReason: r.string(10),
                          dependsOn: json(r.string(14)),
                          createdAt: Date(timeIntervalSince1970: r.double(11)), updatedAt: Date(timeIntervalSince1970: r.double(12)),
                          completedAt: r.isNull(13) ? nil : Date(timeIntervalSince1970: r.double(13)))
    }

    private func params(_ t: TaskRecord) -> [SQLiteValue] {
        func json(_ a: [String]) -> String { String(decoding: (try? JSONEncoder().encode(a)) ?? Data("[]".utf8), as: UTF8.self) }
        return [.text(t.projectPath), .text(t.title), .text(t.details), .optText(t.acceptanceCriteria), .text(t.status.rawValue),
                .text(t.priority.rawValue), .text(json(t.labels)), .optText(t.assignedAgentSessionID), .optText(t.worktreePath),
                .optText(t.blockedReason), .double(t.createdAt.timeIntervalSince1970), .double(t.updatedAt.timeIntervalSince1970),
                .optDate(t.completedAt), .text(json(t.dependsOn)), .text(t.id)]
    }

    private func insert(_ t: TaskRecord) throws {
        try db.run("INSERT INTO tasks (project_path, title, details, acceptance_criteria, status, priority, labels, assigned_agent_session_id, worktree_path, blocked_reason, created_at, updated_at, completed_at, depends_on, id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", params(t))
    }

    private func write(_ t: TaskRecord) throws {
        try db.run("UPDATE tasks SET project_path=?, title=?, details=?, acceptance_criteria=?, status=?, priority=?, labels=?, assigned_agent_session_id=?, worktree_path=?, blocked_reason=?, created_at=?, updated_at=?, completed_at=?, depends_on=? WHERE id=?", params(t))
    }

    private func append(_ e: TaskEvent) throws {
        let seq = try db.scalarInt("SELECT COALESCE(MAX(seq),0)+1 FROM task_events WHERE task_id=?", [.text(e.taskID)])
        try db.run("INSERT INTO task_events (id, task_id, at, kind, detail, from_status, to_status, seq) VALUES (?,?,?,?,?,?,?,?)",
                   [.text(e.id), .text(e.taskID), .double(e.at.timeIntervalSince1970), .text(e.kind.rawValue), .optText(e.detail),
                    .optText(e.fromStatus?.rawValue), .optText(e.toStatus?.rawValue), .int(Int64(seq))])
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as SQLiteError {
            Log.tasks.error("task store failure code=\(e.code, privacy: .public)")
            throw TaskError.storage(e)
        }
    }
}
