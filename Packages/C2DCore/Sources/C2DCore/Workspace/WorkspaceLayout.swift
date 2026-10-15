import Foundation

/// Stable identity of a panel; never its index, title or position (Bible Part 3 §3.1).
public struct PanelID: Hashable, Codable, Sendable, CustomStringConvertible, CodingKeyRepresentable {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    // Dictionaries keyed by PanelID encode as JSON objects, not key/value arrays.
    public var codingKey: any CodingKey { StringKey(rawValue) }
    public init?<T: CodingKey>(codingKey: T) { rawValue = codingKey.stringValue }
}

struct StringKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public struct NodeID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// What a panel hosts. String-backed so a layout saved by a newer version decodes here as an
/// unknown kind instead of failing (Bible Part 3 §3.2).
public struct PanelKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let projectExplorer = PanelKind(rawValue: "projectExplorer")
    public static let editor = PanelKind(rawValue: "editor")
    public static let terminal = PanelKind(rawValue: "terminal")
    public static let agentSession = PanelKind(rawValue: "agentSession")
    public static let gitChanges = PanelKind(rawValue: "gitChanges")
    public static let tasks = PanelKind(rawValue: "tasks")
    public static let tokenOptimizer = PanelKind(rawValue: "tokenOptimizer")
    public static let resourceMonitor = PanelKind(rawValue: "resourceMonitor")
    public static let preview = PanelKind(rawValue: "preview")
    /// Placeholder substituted for a kind this build cannot host. Keeps the slot and the
    /// original kind so the user can remove or replace it.
    public static let unavailable = PanelKind(rawValue: "unavailable")
}

public struct Panel: Hashable, Codable, Sendable {
    public let id: PanelID
    public var kind: PanelKind
    public var title: String?
    /// Small, kind-specific restoration hints (e.g. a session id, a file path). Never process state.
    public var attributes: [String: String]

    public init(id: PanelID = PanelID(), kind: PanelKind, title: String? = nil, attributes: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.attributes = attributes
    }
}

public enum SplitOrientation: String, Codable, Sendable {
    case horizontal   // children side by side
    case vertical     // children stacked
}

public enum DockEdge: String, Codable, Sendable {
    case left, right, top, bottom
    var orientation: SplitOrientation { self == .left || self == .right ? .horizontal : .vertical }
    var insertsBefore: Bool { self == .left || self == .top }
}

/// Nested split tree. Leaves are tab groups; a group holds one or more panels with one active.
public indirect enum LayoutNode: Hashable, Codable, Sendable {
    case split(id: NodeID, orientation: SplitOrientation, children: [LayoutNode], weights: [Double])
    case group(id: NodeID, panels: [PanelID], active: PanelID?)

    public var id: NodeID {
        switch self {
        case .split(let id, _, _, _), .group(let id, _, _): id
        }
    }

    public var panelIDs: [PanelID] {
        switch self {
        case .group(_, let panels, _): panels
        case .split(_, _, let children, _): children.flatMap(\.panelIDs)
        }
    }

    public var groupIDs: [NodeID] {
        switch self {
        case .group(let id, _, _): [id]
        case .split(_, _, let children, _): children.flatMap(\.groupIDs)
        }
    }
}

public enum LayoutError: Error, Equatable, Sendable {
    case unknownPanel(PanelID)
    case unknownGroup(NodeID)
    case panelAlreadyPlaced(PanelID)
    case invalidWeights
}

/// The complete, restorable arrangement of a workspace (Bible Part 3 §13). Structured state,
/// never a screenshot. Carries no process or session state.
public struct WorkspaceLayout: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
    public var root: LayoutNode
    public var panels: [PanelID: Panel]
    /// Panels that exist but are not in the tree. Hiding keeps identity and content state.
    public var hidden: [PanelID]
    /// Focus Mode: the group that currently fills the workspace; the tree is untouched.
    public var maximizedGroup: NodeID?

    public init(id: String = UUID().uuidString, name: String, isBuiltIn: Bool = false, root: LayoutNode, panels: [Panel]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.root = root
        self.panels = Dictionary(uniqueKeysWithValues: panels.map { ($0.id, $0) })
        self.hidden = []
        self.maximizedGroup = nil
    }

    // MARK: Queries

    public var visiblePanelIDs: [PanelID] { root.panelIDs }
    public var groupIDs: [NodeID] { root.groupIDs }

    public func group(containing panel: PanelID) -> NodeID? {
        func find(_ node: LayoutNode) -> NodeID? {
            switch node {
            case .group(let id, let panels, _): panels.contains(panel) ? id : nil
            case .split(_, _, let children, _): children.lazy.compactMap(find).first
            }
        }
        return find(root)
    }

    public func activePanel(in group: NodeID) -> PanelID? {
        func find(_ node: LayoutNode) -> PanelID?? {
            switch node {
            case .group(let id, _, let active): id == group ? .some(active) : nil
            case .split(_, _, let children, _): children.lazy.compactMap(find).first
            }
        }
        return find(root) ?? nil
    }

    /// Every panel kind in this layout that the host cannot provide becomes `.unavailable`,
    /// keeping its slot and recording the original kind. Returns the affected panel ids.
    @discardableResult
    public mutating func recover(availableKinds: Set<PanelKind>) -> [PanelID] {
        var affected: [PanelID] = []
        for (id, var panel) in panels where !availableKinds.contains(panel.kind) && panel.kind != .unavailable {
            panel.attributes["originalKind"] = panel.kind.rawValue
            panel.kind = .unavailable
            panels[id] = panel
            affected.append(id)
        }
        // Drop tree references to panels that do not exist at all.
        let known = Set(panels.keys)
        root = Self.pruned(root, keeping: known)
        hidden.removeAll { !known.contains($0) }
        if let m = maximizedGroup, !root.groupIDs.contains(m) { maximizedGroup = nil }
        return affected
    }

    // MARK: Mutations

    /// Adds a new panel to a group (default: as the last tab, activated).
    public mutating func add(_ panel: Panel, to group: NodeID, activate: Bool = true) throws(LayoutError) {
        guard panels[panel.id] == nil else { throw LayoutError.panelAlreadyPlaced(panel.id) }
        guard root.groupIDs.contains(group) else { throw LayoutError.unknownGroup(group) }
        panels[panel.id] = panel
        root = Self.mapGroup(root, group) { panels, active in (panels + [panel.id], activate ? panel.id : active ?? panel.id) }
    }

    /// Adds a new panel in its own group beside `group` on `edge`, splitting if needed.
    public mutating func add(_ panel: Panel, beside group: NodeID, edge: DockEdge) throws(LayoutError) {
        guard panels[panel.id] == nil else { throw LayoutError.panelAlreadyPlaced(panel.id) }
        guard root.groupIDs.contains(group) else { throw LayoutError.unknownGroup(group) }
        panels[panel.id] = panel
        let newGroup = LayoutNode.group(id: NodeID(), panels: [panel.id], active: panel.id)
        root = Self.insert(newGroup, beside: group, edge: edge, in: root)
    }

    /// Moves an existing (visible or hidden) panel into a group as a tab.
    public mutating func move(_ panel: PanelID, toGroup group: NodeID, index: Int? = nil) throws(LayoutError) {
        guard panels[panel] != nil else { throw LayoutError.unknownPanel(panel) }
        guard root.groupIDs.contains(group) else { throw LayoutError.unknownGroup(group) }
        detach(panel)
        guard root.groupIDs.contains(group) else {
            // The source group was the only one and got pruned; put the panel back in a fresh root.
            root = .group(id: NodeID(), panels: [panel], active: panel)
            return
        }
        root = Self.mapGroup(root, group) { panels, _ in
            var p = panels
            p.insert(panel, at: min(index ?? p.count, p.count))
            return (p, panel)
        }
    }

    /// Moves an existing panel into a new group docked beside `group`.
    public mutating func move(_ panel: PanelID, beside group: NodeID, edge: DockEdge) throws(LayoutError) {
        guard panels[panel] != nil else { throw LayoutError.unknownPanel(panel) }
        guard root.groupIDs.contains(group) else { throw LayoutError.unknownGroup(group) }
        // Moving a lone panel beside its own group is a no-op.
        if case .group(let gid, let ps, _) = Self.node(group, in: root), gid == group, ps == [panel] { return }
        detach(panel)
        let newGroup = LayoutNode.group(id: NodeID(), panels: [panel], active: panel)
        if root.groupIDs.contains(group) {
            root = Self.insert(newGroup, beside: group, edge: edge, in: root)
        } else {
            root = newGroup
        }
    }

    /// Removes the panel from the tree but keeps it (and its content state) as hidden.
    public mutating func hide(_ panel: PanelID) throws(LayoutError) {
        guard panels[panel] != nil else { throw LayoutError.unknownPanel(panel) }
        guard !hidden.contains(panel) else { return }
        detach(panel)
        hidden.append(panel)
    }

    /// Returns a hidden panel to `group`, or to the first group when its old home is gone.
    public mutating func restore(_ panel: PanelID, into group: NodeID? = nil) throws(LayoutError) {
        guard panels[panel] != nil else { throw LayoutError.unknownPanel(panel) }
        guard hidden.contains(panel) else { return }
        hidden.removeAll { $0 == panel }
        if let group, root.groupIDs.contains(group) {
            try move(panel, toGroup: group)
        } else if let first = root.groupIDs.first {
            try move(panel, toGroup: first)
        } else {
            root = .group(id: NodeID(), panels: [panel], active: panel)
        }
    }

    /// Removes the panel from the layout entirely. Closing is a layout operation; the caller
    /// decides what happens to the underlying session (Bible Part 3 §7.3).
    public mutating func close(_ panel: PanelID) throws(LayoutError) {
        guard panels[panel] != nil else { throw LayoutError.unknownPanel(panel) }
        detach(panel)
        hidden.removeAll { $0 == panel }
        panels[panel] = nil
    }

    public mutating func activate(_ panel: PanelID) throws(LayoutError) {
        guard let group = group(containing: panel) else { throw LayoutError.unknownPanel(panel) }
        root = Self.mapGroup(root, group) { panels, _ in (panels, panel) }
    }

    /// Sets the relative weights of a split's children. Count must match; all positive.
    public mutating func setWeights(_ weights: [Double], of split: NodeID) throws(LayoutError) {
        guard weights.allSatisfy({ $0 > 0 }) else { throw LayoutError.invalidWeights }
        var found = false
        root = Self.mapSplit(root, split) { orientation, children, _ in
            found = true
            return (orientation, children, weights.count == children.count ? weights : nil)
        }
        guard found else { throw LayoutError.unknownGroup(split) }
    }

    public mutating func maximize(_ group: NodeID) throws(LayoutError) {
        guard root.groupIDs.contains(group) else { throw LayoutError.unknownGroup(group) }
        maximizedGroup = group
    }

    public mutating func exitFocusMode() {
        maximizedGroup = nil
    }

    // MARK: Tree helpers

    private mutating func detach(_ panel: PanelID) {
        guard group(containing: panel) != nil else { return }
        root = Self.removing(panel, from: root) ?? .group(id: NodeID(), panels: [], active: nil)
        if let m = maximizedGroup, !root.groupIDs.contains(m) { maximizedGroup = nil }
    }

    public static func node(_ id: NodeID, in node: LayoutNode) -> LayoutNode? {
        if node.id == id { return node }
        if case .split(_, _, let children, _) = node { return children.lazy.compactMap { Self.node(id, in: $0) }.first }
        return nil
    }

    static func mapGroup(_ node: LayoutNode, _ target: NodeID, _ f: ([PanelID], PanelID?) -> ([PanelID], PanelID?)) -> LayoutNode {
        switch node {
        case .group(let id, let panels, let active) where id == target:
            let (p, a) = f(panels, active)
            return .group(id: id, panels: p, active: a.flatMap { p.contains($0) ? $0 : nil } ?? p.first)
        case .group: return node
        case .split(let id, let o, let children, let w):
            return .split(id: id, orientation: o, children: children.map { mapGroup($0, target, f) }, weights: w)
        }
    }

    static func mapSplit(_ node: LayoutNode, _ target: NodeID, _ f: (SplitOrientation, [LayoutNode], [Double]) -> (SplitOrientation, [LayoutNode], [Double]?)) -> LayoutNode {
        switch node {
        case .group: return node
        case .split(let id, let o, let children, let w) where id == target:
            let (no, nc, nw) = f(o, children, w)
            return .split(id: id, orientation: no, children: nc, weights: nw ?? w)
        case .split(let id, let o, let children, let w):
            return .split(id: id, orientation: o, children: children.map { mapSplit($0, target, f) }, weights: w)
        }
    }

    /// Removes a panel; empty groups vanish and single-child splits collapse. `nil` = tree became empty.
    static func removing(_ panel: PanelID, from node: LayoutNode) -> LayoutNode? {
        switch node {
        case .group(let id, let panels, let active):
            let rest = panels.filter { $0 != panel }
            if rest.isEmpty { return nil }
            let newActive = active == panel ? rest.first : active
            return .group(id: id, panels: rest, active: newActive)
        case .split(let id, let o, let children, let weights):
            var newChildren: [LayoutNode] = []
            var newWeights: [Double] = []
            for (child, weight) in zip(children, weights) {
                if let kept = removing(panel, from: child) {
                    newChildren.append(kept)
                    newWeights.append(weight)
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }
            return .split(id: id, orientation: o, children: newChildren, weights: newWeights)
        }
    }

    static func pruned(_ node: LayoutNode, keeping known: Set<PanelID>) -> LayoutNode {
        var result = node
        for id in node.panelIDs where !known.contains(id) {
            result = removing(id, from: result) ?? .group(id: NodeID(), panels: [], active: nil)
        }
        return result
    }

    /// Puts `newNode` next to `target` on `edge`. Reuses the parent split when its orientation matches.
    static func insert(_ newNode: LayoutNode, beside target: NodeID, edge: DockEdge, in node: LayoutNode) -> LayoutNode {
        if node.id == target {
            let children = edge.insertsBefore ? [newNode, node] : [node, newNode]
            return .split(id: NodeID(), orientation: edge.orientation, children: children, weights: [0.5, 0.5])
        }
        guard case .split(let id, let o, let children, let weights) = node else { return node }
        if o == edge.orientation, let i = children.firstIndex(where: { $0.id == target }) {
            var c = children, w = weights
            let share = w[i] / 2
            w[i] = share
            c.insert(newNode, at: edge.insertsBefore ? i : i + 1)
            w.insert(share, at: edge.insertsBefore ? i : i + 1)
            return .split(id: id, orientation: o, children: c, weights: w)
        }
        return .split(id: id, orientation: o, children: children.map { insert(newNode, beside: target, edge: edge, in: $0) }, weights: weights)
    }
}
