import CryptoKit
import Foundation

/// Identity derived from the canonical path, stable across launches and renames of the display name.
public struct ProjectID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(path: String) {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        rawValue = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// A recent-project entry. Not ownership of the directory (Bible §3.1): removing an entry
/// never touches the filesystem.
public struct Project: Hashable, Codable, Sendable, Identifiable {
    public var id: ProjectID { ProjectID(path: path) }
    public var name: String
    public var path: String
    public var lastOpened: Date
    public var pinned: Bool

    public init(name: String? = nil, path: String, lastOpened: Date = Date(), pinned: Bool = false) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        self.path = url.path
        self.name = name ?? url.lastPathComponent
        self.lastOpened = lastOpened
        self.pinned = pinned
    }

    /// True when the directory currently exists and is readable. Evaluated live, never cached.
    public var isAvailable: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue && access(path, R_OK | X_OK) == 0
    }
}

public struct ProjectRegistryDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = currentSchemaVersion
    public var projects: [Project] = []
    public var activeProjectPath: String?
    public init() {}
}

public enum ProjectError: Error, Equatable, Sendable {
    case notADirectory(String)
    case notReadable(String)
}

/// Recent projects and the active project, persisted as one JSON document.
public struct ProjectRegistry: Sendable {
    public private(set) var document: ProjectRegistryDocument
    private let store: JSONDocumentStore?
    private static let name = "projects"

    public init(store: JSONDocumentStore?) throws {
        self.store = store
        self.document = try store?.load(ProjectRegistryDocument.self, named: Self.name) ?? ProjectRegistryDocument()
    }

    public static func standard() throws -> ProjectRegistry {
        try ProjectRegistry(store: try JSONDocumentStore.applicationSupport())
    }

    public var projects: [Project] {
        document.projects.sorted { ($0.pinned ? 0 : 1, $1.lastOpened) < ($1.pinned ? 0 : 1, $0.lastOpened) }
    }

    public var activeProject: Project? {
        document.activeProjectPath.flatMap { p in document.projects.first { $0.path == p } }
    }

    /// Validates the directory, records it (or bumps its timestamp) and makes it active.
    @discardableResult
    public mutating func open(path: String) throws -> Project {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectError.notADirectory(url.path)
        }
        guard access(url.path, R_OK | X_OK) == 0 else { throw ProjectError.notReadable(url.path) }
        var project = document.projects.first { $0.path == url.path } ?? Project(path: url.path)
        project.lastOpened = Date()
        document.projects.removeAll { $0.path == url.path }
        document.projects.append(project)
        document.activeProjectPath = project.path
        try persist()
        return project
    }

    /// Re-points an entry whose directory moved. Keeps pin state; drops the stale entry.
    public mutating func relocate(_ project: Project, to newPath: String) throws -> Project {
        let pinned = project.pinned
        document.projects.removeAll { $0.path == project.path }
        var moved = try open(path: newPath)
        moved.pinned = pinned
        document.projects.removeAll { $0.path == moved.path }
        document.projects.append(moved)
        try persist()
        return moved
    }

    public mutating func remove(_ project: Project) throws {
        document.projects.removeAll { $0.path == project.path }
        if document.activeProjectPath == project.path { document.activeProjectPath = nil }
        try persist()
    }

    public mutating func setPinned(_ pinned: Bool, _ project: Project) throws {
        guard let i = document.projects.firstIndex(where: { $0.path == project.path }) else { return }
        document.projects[i].pinned = pinned
        try persist()
    }

    private func persist() throws {
        try store?.save(document, as: Self.name)
    }
}
