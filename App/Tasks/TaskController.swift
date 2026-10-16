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
    /// Every task in the project (terminal included), keyed by id, for dependency resolution and display.
    private(set) var byID: [String: TaskRecord] = [:]
    private(set) var plans: [TaskPlan] = []
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
            let all = try await store.tasks(projectPath: projectPath, includeTerminal: true)
            byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            plans = try await store.plans(projectPath: projectPath)
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

    func transition(_ task: TaskRecord, to status: TaskStatus, note: String? = nil, override: Bool = false) async {
        guard let store else { return }
        do { _ = try await store.transition(id: task.id, to: status, note: note, override: override); await reload() } catch { lastError = describe(error) }
    }

    // MARK: Dependencies (Bible Part 8 §12)

    /// Upstream tasks this one waits on; `completed` ones resolve, others still block.
    func dependencies(of t: TaskRecord) -> [TaskRecord] { t.dependsOn.compactMap { byID[$0] } }
    /// Tasks that depend on this one (why it can't be deleted yet).
    func dependents(of t: TaskRecord) -> [TaskRecord] { byID.values.filter { $0.dependsOn.contains(t.id) }.sorted { $0.title < $1.title } }
    func unmetDependencies(of t: TaskRecord) -> [TaskRecord] { t.unmetDependencies { byID[$0]?.status }.compactMap { byID[$0] } }
    func isEligible(_ t: TaskRecord) -> Bool { t.unmetDependencies { byID[$0]?.status }.isEmpty }
    /// Candidate upstreams for a new edge: same project, not self, not already a dependency. Cycles are
    /// rejected by the store on add, so they are not pre-filtered here.
    func dependencyCandidates(for t: TaskRecord) -> [TaskRecord] {
        byID.values.filter { $0.id != t.id && !t.dependsOn.contains($0.id) }.sorted { $0.title < $1.title }
    }

    func addDependency(_ task: TaskRecord, on upstream: TaskRecord) async {
        guard let store else { return }
        do { _ = try await store.addDependency(id: task.id, dependsOn: upstream.id); await reload() } catch { lastError = describe(error) }
    }

    func removeDependency(_ task: TaskRecord, on upstreamID: String) async {
        guard let store else { return }
        do { _ = try await store.removeDependency(id: task.id, dependsOn: upstreamID); await reload() } catch { lastError = describe(error) }
    }

    // MARK: Plans (task groups, Bible Part 8 §12)

    func plan(for t: TaskRecord) -> TaskPlan? { t.planID.flatMap { id in plans.first { $0.id == id } } }
    func tasks(inPlan id: String) -> [TaskRecord] { byID.values.filter { $0.planID == id }.sorted { $0.title < $1.title } }
    func eligibleCount(inPlan id: String) -> Int { tasks(inPlan: id).filter { !$0.status.isTerminal && isEligible($0) }.count }

    @discardableResult
    func createPlan(goal: String) async -> TaskPlan? {
        guard let store else { return nil }
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return nil }
        do { let p = try await store.createPlan(TaskPlan(projectPath: projectPath, goal: g)); await reload(); return p }
        catch { lastError = describe(error); return nil }
    }

    func updatePlan(_ plan: TaskPlan) async {
        guard let store else { return }
        do { _ = try await store.updatePlan(plan); await reload() } catch { lastError = describe(error) }
    }

    func deletePlan(_ plan: TaskPlan) async {
        guard let store else { return }
        do { try await store.deletePlan(id: plan.id); await reload() } catch { lastError = describe(error) }
    }

    func assign(_ task: TaskRecord, toPlan planID: String?) async {
        guard let store else { return }
        do { _ = try await store.assign(taskID: task.id, toPlan: planID); await reload() } catch { lastError = describe(error) }
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
        switch error as? TaskError {
        case .invalidTransition(let from, let to): return "Cannot move a \(from.rawValue) task to \(to.rawValue)."
        case .dependenciesUnmet(let ids): return "Blocked by \(ids.count) unfinished task(s): \(names(ids)). Finish them, or start anyway."
        case .hasDependents(let ids): return "\(names(ids)) still depend(s) on this task. Remove the dependency first."
        case .dependencyCycle: return "That would create a dependency cycle."
        case .selfDependency: return "A task cannot depend on itself."
        case .crossProject: return "A task and its dependency or plan must be in the same project."
        default: return "\(error)"
        }
    }

    private func names(_ ids: [String]) -> String {
        ids.map { byID[$0]?.title ?? $0 }.joined(separator: ", ")
    }
}
