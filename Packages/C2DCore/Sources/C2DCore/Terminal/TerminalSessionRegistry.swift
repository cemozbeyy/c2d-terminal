import Foundation

/// Lifecycle as the registry reports it. Distinct from `PTYSessionState` because a record can
/// outlive its process (Bible Part 4 §2.3): `endedByRestart` is a record whose process is gone.
public enum TerminalSessionLifecycle: String, Codable, Sendable {
    case starting, running, exited, startupFailed, endedByRestart, unknown
}

/// Metadata about one terminal session. Never the process itself; never scrollback.
public struct TerminalSessionRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var panelID: PanelID?
    public var projectPath: String?
    public var initialDirectory: String
    public var shell: String
    public var lifecycle: TerminalSessionLifecycle
    public var pid: Int32?
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var signal: Int32?
    public var userTitle: String?
    public var failureDescription: String?

    public init(id: String = UUID().uuidString, panelID: PanelID?, projectPath: String?, initialDirectory: String, shell: String) {
        self.id = id
        self.panelID = panelID
        self.projectPath = projectPath
        self.initialDirectory = initialDirectory
        self.shell = shell
        self.lifecycle = .starting
        self.startedAt = Date()
    }

    public var isLive: Bool { lifecycle == .starting || lifecycle == .running }
}

public struct TerminalSessionsDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = currentSchemaVersion
    public var records: [TerminalSessionRecord] = []
    public init() {}
}

/// Owns session *records*. Process ownership stays with each `PTYSession`; the registry only
/// mirrors what the process layer reports, so the UI never invents a running state.
/// Records persist so a relaunch can show "ended" instead of pretending a shell survived (DEF-12).
public struct TerminalSessionRegistry: Sendable {
    public private(set) var document: TerminalSessionsDocument
    private let store: JSONDocumentStore?
    private static let name = "terminal-sessions"
    public static let retainedEndedRecords = 50

    public init(store: JSONDocumentStore?) throws {
        self.store = store
        var doc = try store?.load(TerminalSessionsDocument.self, named: Self.name) ?? TerminalSessionsDocument()
        // Anything that was live when the app last ran is gone now; say so.
        for i in doc.records.indices where doc.records[i].isLive {
            doc.records[i].lifecycle = .endedByRestart
            doc.records[i].endedAt = doc.records[i].endedAt ?? Date()
            doc.records[i].pid = nil
        }
        self.document = doc
        try persist()
    }

    public var records: [TerminalSessionRecord] { document.records }
    public func record(_ id: String) -> TerminalSessionRecord? { document.records.first { $0.id == id } }
    public func record(forPanel panel: PanelID) -> TerminalSessionRecord? {
        document.records.filter { $0.panelID == panel }.max { $0.startedAt < $1.startedAt }
    }

    public mutating func register(_ record: TerminalSessionRecord) throws {
        document.records.removeAll { $0.id == record.id }
        document.records.append(record)
        trim()
        try persist()
    }

    public mutating func update(_ id: String, _ change: (inout TerminalSessionRecord) -> Void) throws {
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
