import Foundation

/// Built-in starting arrangements (Bible §4.3, Part 3 §9). Presets are data: applying one
/// creates fresh panel identities; it never touches sessions.
public enum LayoutPreset: String, CaseIterable, Sendable {
    case development, multiAgent, terminalFocus, codeReview

    public var displayName: String {
        switch self {
        case .development: "Development"
        case .multiAgent: "Multi-Agent"
        case .terminalFocus: "Terminal Focus"
        case .codeReview: "Code Review"
        }
    }

    public var summary: String {
        switch self {
        case .development: "Explorer beside the editor, terminal underneath."
        case .multiAgent: "Several agent sessions with the task overview."
        case .terminalFocus: "A large terminal and little else."
        case .codeReview: "Changed files, diff and editor side by side."
        }
    }

    /// Only kinds in `available` are instantiated; a preset degrades to what this build can host.
    public func makeLayout(available: Set<PanelKind>) -> WorkspaceLayout {
        func panel(_ kind: PanelKind, _ title: String) -> Panel? {
            available.contains(kind) ? Panel(kind: kind, title: title) : nil
        }
        func group(_ ps: [Panel?]) -> LayoutNode? {
            let real = ps.compactMap { $0 }
            return real.isEmpty ? nil : .group(id: NodeID(), panels: real.map(\.id), active: real.first?.id)
        }
        func split(_ o: SplitOrientation, _ nodes: [(LayoutNode?, Double)]) -> LayoutNode? {
            let real = nodes.compactMap { n, w in n.map { ($0, w) } }
            if real.isEmpty { return nil }
            if real.count == 1 { return real[0].0 }
            return .split(id: NodeID(), orientation: o, children: real.map(\.0), weights: real.map(\.1))
        }

        var all: [Panel] = []
        func keep(_ p: Panel?) -> Panel? { if let p { all.append(p) }; return p }

        let root: LayoutNode?
        switch self {
        case .development:
            // VS-Code shape (owner request 2026-10-20, ADR-024): explorer docked left of the editor,
            // terminal full-width underneath. No agent column; agents open on demand.
            let explorer = keep(panel(.projectExplorer, "Explorer"))
            let editor = keep(panel(.editor, "Editor"))
            let terminal = keep(panel(.terminal, "Terminal"))
            root = split(.vertical, [
                (split(.horizontal, [(group([explorer]), 0.18), (group([editor]), 0.82)]), 0.7),
                (group([terminal]), 0.3),
            ])
        case .multiAgent:
            let a1 = keep(panel(.agentSession, "Agent 1"))
            let a2 = keep(panel(.agentSession, "Agent 2"))
            let tasks = keep(panel(.tasks, "Tasks"))
            let terminal = keep(panel(.terminal, "Terminal"))
            root = split(.vertical, [
                (split(.horizontal, [(group([a1]), 0.5), (group([a2]), 0.5)]), 0.65),
                (split(.horizontal, [(group([tasks]), 0.5), (group([terminal]), 0.5)]), 0.35),
            ])
        case .terminalFocus:
            let terminal = keep(panel(.terminal, "Terminal"))
            root = group([terminal])
        case .codeReview:
            let git = keep(panel(.gitChanges, "Changes"))
            let editor = keep(panel(.editor, "Editor"))
            let terminal = keep(panel(.terminal, "Terminal"))
            root = split(.horizontal, [
                (group([git]), 0.3),
                (split(.vertical, [(group([editor]), 0.7), (group([terminal]), 0.3)]), 0.7),
            ])
        }
        return WorkspaceLayout(id: "preset.\(rawValue)", name: displayName, isBuiltIn: true,
                               root: root ?? .group(id: NodeID(), panels: [], active: nil), panels: all)
    }
}
