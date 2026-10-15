import Foundation

/// Persists layouts as JSON documents (ADR-011): one global default plus one per project,
/// keyed by a stable hash of the project path. Layout state never contains session state.
public struct LayoutStore: Sendable {
    public let documents: JSONDocumentStore

    public init(documents: JSONDocumentStore) { self.documents = documents }

    public static func standard() throws -> LayoutStore {
        LayoutStore(documents: try JSONDocumentStore.applicationSupport(subdirectory: "layouts"))
    }

    public static func documentName(forProjectPath path: String) -> String {
        "project-" + ProjectID(path: path).rawValue
    }

    public func loadGlobalDefault() throws -> WorkspaceLayout? {
        try migrate(documents.load(WorkspaceLayout.self, named: "global-default"))
    }

    public func saveGlobalDefault(_ layout: WorkspaceLayout) throws {
        try documents.save(layout, as: "global-default")
    }

    public func load(forProjectPath path: String) throws -> WorkspaceLayout? {
        try migrate(documents.load(WorkspaceLayout.self, named: Self.documentName(forProjectPath: path)))
    }

    public func save(_ layout: WorkspaceLayout, forProjectPath path: String) throws {
        try documents.save(layout, as: Self.documentName(forProjectPath: path))
    }

    /// Forward migration hook. Schema 1 is current; an unknown newer schema is an error, not a reset.
    func migrate(_ layout: WorkspaceLayout?) throws -> WorkspaceLayout? {
        guard let layout else { return nil }
        guard layout.schemaVersion <= WorkspaceLayout.currentSchemaVersion else {
            throw LayoutStoreError.unsupportedSchema(layout.schemaVersion)
        }
        return layout
    }
}

public enum LayoutStoreError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
}
