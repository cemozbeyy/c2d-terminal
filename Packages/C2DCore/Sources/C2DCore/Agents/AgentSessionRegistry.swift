import Foundation

/// `awaitingUser` is only set by the app when the provider gives evidence; Claude Code's TUI gives
/// no structured signal, so its sessions stay `running` until the process exits.
public enum AgentSessionLifecycle: String, Codable, Sendable {
    case starting, running, awaitingUser, exited, failed, endedByRestart, unknown
}

/// Metadata about one managed agent session. The process lives in a `PTYSession` owned by the app;
/// `terminalSessionID` links to its `TerminalSessionRecord`.
public struct AgentSessionRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let providerID: String
    public var panelID: PanelID?
    public var terminalSessionID: String?
    public var projectPath: String
    public var workingDirectory: String
    public var worktreePath: String?
    public var taskID: String?
    public var taskSummary: String?
    public var userTitle: String?
    public var lifecycle: AgentSessionLifecycle
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var failureDescription: String?

    public init(id: String = UUID().uuidString, providerID: String, panelID: PanelID?, terminalSessionID: String? = nil,
                projectPath: String, workingDirectory: String, worktreePath: String? = nil, taskID: String? = nil, taskSummary: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.panelID = panelID
        self.terminalSessionID = terminalSessionID
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory
        self.worktreePath = worktreePath
        self.taskID = taskID
        self.taskSummary = taskSummary
        self.lifecycle = .starting
        self.startedAt = Date()
    }

    public var isLive: Bool { lifecycle == .starting || lifecycle == .running || lifecycle == .awaitingUser }
}

public struct AgentSessionsDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = currentSchemaVersion
    public var records: [AgentSessionRecord] = []
    public init() {}
}

/// Session *records*, persisted as one JSON document. Mirrors `TerminalSessionRegistry`: anything
/// live at the last run is marked `endedByRestart` on load; the process is never assumed alive.
public struct AgentSessionRegistry: Sendable {
    public private(set) var document: AgentSessionsDocument
    private let store: JSONDocumentStore?
    private static let name = "agent-sessions"
    public static let retainedEndedRecords = 50

    public init(store: JSONDocumentStore?) throws {
        self.store = store
        var doc = try store?.load(AgentSessionsDocument.self, named: Self.name) ?? AgentSessionsDocument()
        for i in doc.records.indices where doc.records[i].isLive {
            doc.records[i].lifecycle = .endedByRestart
            doc.records[i].endedAt = doc.records[i].endedAt ?? Date()
        }
        self.document = doc
        try persist()
    }

    public var records: [AgentSessionRecord] { document.records }
    public func record(_ id: String) -> AgentSessionRecord? { document.records.first { $0.id == id } }
    public func records(forProject path: String) -> [AgentSessionRecord] { document.records.filter { $0.projectPath == path } }
    public func record(forPanel panel: PanelID) -> AgentSessionRecord? {
        document.records.filter { $0.panelID == panel }.max { $0.startedAt < $1.startedAt }
    }

    public mutating func register(_ record: AgentSessionRecord) throws {
        document.records.removeAll { $0.id == record.id }
        document.records.append(record)
        trim()
        try persist()
    }

    public mutating func update(_ id: String, _ change: (inout AgentSessionRecord) -> Void) throws {
        guard let i = document.records.firstIndex(where: { $0.id == id }) else { return }
        change(&document.records[i])
        try persist()
    }

    public mutating func forget(_ id: String) throws {
        document.records.removeAll { $0.id == id }
        try persist()
    }

    private mutating func trim() {
        let ended = document.records.filter { !$0.isLive }.sorted { $0.startedAt > $1.startedAt }
        if ended.count > Self.retainedEndedRecords {
            let drop = Set(ended.dropFirst(Self.retainedEndedRecords).map(\.id))
            document.records.removeAll { drop.contains($0.id) }
        }
    }

    private func persist() throws { try store?.save(document, as: Self.name) }
}
