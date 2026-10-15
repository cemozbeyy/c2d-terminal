import C2DCore
import Foundation
import Observation

/// Task state for one workspace. The SQLite store is authoritative; this holds the last read
/// snapshot. Status never changes because a process exited (Bible Part 8 §5).
@MainActor
@Observable
final class TaskController {
    let projectPath: String
    private(set) var tasks: [TaskRecord] = []
    private(set) var selected: TaskRecord?
    private(set) var events: [TaskEvent] = []
    var showTerminal = false
    var filterText = ""
    var lastError: String?
    var deleteRequest: TaskRecord?

    @ObservationIgnored private let store: TaskStore?
    @ObservationIgnored private unowned let app: AppModel

    init(projectPath: String, store: TaskStore?, app: AppModel) {
        self.projectPath = projectPath
        self.store = store
        self.app = app
        Task { await reload() }
    }

    var isAvailable: Bool { store != nil }

    var visibleTasks: [TaskRecord] {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return tasks.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.details.lowercased().contains(q) || $0.labels.contains { $0.lowercased().contains(q) } }
    }

    func reload() async {
        guard let store else { return }
        do {
            tasks = try await store.tasks(projectPath: projectPath, includeTerminal: showTerminal)
            if let s = selected {
                if let fresh = tasks.first(where: { $0.id == s.id }) { selected = fresh } else { selected = try await store.task(id: s.id) }
                await loadEvents()
            }
        } catch { lastError = "\(error)" }
    }

    func select(_ task: TaskRecord?) async {
        selected = task
        await loadEvents()
    }

    private func loadEvents() async {
        guard let store, let s = selected else { events = []; return }
        events = (try? await store.events(taskID: s.id)) ?? []
    }

    @discardableResult
    func create(title: String, details: String = "", priority: TaskPriority = .normal) async -> TaskRecord? {
        guard let store else { return nil }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        do {
            let rec = try await store.create(TaskRecord(projectPath: projectPath, title: t, details: details, priority: priority))
            await reload()
            await select(rec)
            return rec
        } catch { lastError = "\(error)"; return nil }
    }

    func update(_ record: TaskRecord) async {
        guard let store else { return }
        do { _ = try await store.update(record); await reload() } catch { lastError = "\(error)" }
    }

    func transition(_ task: TaskRecord, to status: TaskStatus, note: String? = nil) async {
        guard let store else { return }
        do { _ = try await store.transition(id: task.id, to: status, note: note); await reload() } catch { lastError = describe(error) }
    }

    func block(_ task: TaskRecord, reason: String) async {
        guard let store else { return }
        do { _ = try await store.setBlocked(id: task.id, reason: reason); await reload() } catch { lastError = describe(error) }
    }

    func unblock(_ task: TaskRecord) async {
        guard let store else { return }
        do { _ = try await store.clearBlocked(id: task.id); await reload() } catch { lastError = describe(error) }
    }

    func addNote(_ task: TaskRecord, _ text: String) async {
        guard let store, !text.isEmpty else { return }
        do { try await store.addNote(id: task.id, text); await loadEvents() } catch { lastError = "\(error)" }
    }

    func assign(_ task: TaskRecord, agentSessionID: String?) async {
        var r = task
        r.assignedAgentSessionID = agentSessionID
        await update(r)
    }

    func delete(_ task: TaskRecord) async {
        guard let store else { return }
        deleteRequest = nil
        do { try await store.delete(id: task.id); if selected?.id == task.id { selected = nil; events = [] }; await reload() } catch { lastError = "\(error)" }
    }

    private func describe(_ error: Error) -> String {
        if case TaskError.invalidTransition(let from, let to)? = error as? TaskError { return "Cannot move a \(from.rawValue) task to \(to.rawValue)." }
        return "\(error)"
    }
}
