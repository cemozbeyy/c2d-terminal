import Foundation

public enum TaskPriority: String, Codable, Sendable, CaseIterable {
    case critical, high, normal, low, unprioritized
}

/// Small authoritative state model (Bible Part 8 §5). Queue/attempt/verification live as
/// separate attributes or later records, never folded into this status.
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case inbox, ready, inProgress, blocked, awaitingReview, completed, cancelled

    public var isTerminal: Bool { self == .completed || self == .cancelled }

    /// Allowed transitions. Terminal states only reopen to `ready`. Nothing here is automatic:
    /// a caller (never an agent exit) decides.
    public func canTransition(to next: TaskStatus) -> Bool {
        guard next != self else { return false }
        switch self {
        case .inbox: return [.ready, .cancelled].contains(next)
        case .ready: return [.inbox, .inProgress, .blocked, .cancelled].contains(next)
        case .inProgress: return [.ready, .blocked, .awaitingReview, .completed, .cancelled].contains(next)
        case .blocked: return [.ready, .inProgress, .cancelled].contains(next)
        case .awaitingReview: return [.inProgress, .completed, .cancelled].contains(next)
        case .completed, .cancelled: return next == .ready
        }
    }
}

public struct TaskRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectPath: String
    public var title: String
    public var details: String
    public var acceptanceCriteria: String?
    public var status: TaskStatus
    public var priority: TaskPriority
    public var labels: [String]
    public var assignedAgentSessionID: String?
    public var worktreePath: String?
    public var blockedReason: String?
    /// IDs of tasks (same project) that must complete before this one may start (Bible Part 8 §12).
    public var dependsOn: [String]
    /// Optional plan (task group) this belongs to; organizational only (Bible Part 8 §12).
    public var planID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(id: String = UUID().uuidString, projectPath: String, title: String, details: String = "",
                acceptanceCriteria: String? = nil, status: TaskStatus = .inbox, priority: TaskPriority = .normal,
                labels: [String] = [], assignedAgentSessionID: String? = nil, worktreePath: String? = nil,
                blockedReason: String? = nil, dependsOn: [String] = [], planID: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id; self.projectPath = projectPath; self.title = title; self.details = details
        self.acceptanceCriteria = acceptanceCriteria; self.status = status; self.priority = priority
        self.labels = labels; self.assignedAgentSessionID = assignedAgentSessionID; self.worktreePath = worktreePath
        self.blockedReason = blockedReason; self.dependsOn = dependsOn; self.planID = planID; self.createdAt = createdAt; self.updatedAt = updatedAt; self.completedAt = completedAt
    }

    /// IDs of this task's dependencies that are not yet satisfied. A dependency is satisfied only when
    /// the upstream task is `.completed`; a cancelled, deleted (absent from `statusOf`) or still-running
    /// upstream stays a blocker, so a dependent never proceeds against a dropped or outdated
    /// prerequisite (Bible Part 8 §12: "do not silently run dependent tasks against missing or
    /// outdated assumptions").
    public func unmetDependencies(statusOf: (String) -> TaskStatus?) -> [String] {
        dependsOn.filter { statusOf($0) != .completed }
    }
}

/// A named group of tasks working toward one outcome (Bible Part 8 §12). Organizational only:
/// a plan never executes anything; tasks keep their own status and dependencies.
public struct TaskPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectPath: String
    public var goal: String
    public var verification: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, projectPath: String, goal: String, verification: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.projectPath = projectPath; self.goal = goal; self.verification = verification
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum TaskEventKind: String, Codable, Sendable {
    case created, statusChanged, edited, assigned, blocked, unblocked, note, dependencyAdded, dependencyRemoved
}

/// Append-only history (Part 8 §22). Editing a task never rewrites past events.
public struct TaskEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskID: String
    public var at: Date
    public var kind: TaskEventKind
    public var detail: String?
    public var fromStatus: TaskStatus?
    public var toStatus: TaskStatus?

    public init(id: String = UUID().uuidString, taskID: String, at: Date = Date(), kind: TaskEventKind,
                detail: String? = nil, fromStatus: TaskStatus? = nil, toStatus: TaskStatus? = nil) {
        self.id = id; self.taskID = taskID; self.at = at; self.kind = kind
        self.detail = detail; self.fromStatus = fromStatus; self.toStatus = toStatus
    }
}

public enum TaskError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidTransition(from: TaskStatus, to: TaskStatus)
    case storage(SQLiteError)
    case selfDependency
    case crossProjectDependency
    case dependencyCycle
    /// Starting is gated: these upstream task IDs are not yet complete (pass `override` to start anyway).
    case dependenciesUnmet([String])
    /// Deleting is refused: these task IDs still depend on the target (remove the edges first).
    case hasDependents([String])
}
