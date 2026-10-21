/// Split layout of one terminal window, iTerm-style: a pane, or a row/column of subtrees.
/// `down == true` stacks children top-to-bottom; false lays them out left-to-right.
public indirect enum PaneTree: Hashable, Sendable {
    case pane(PanelID)
    case split(down: Bool, [PaneTree])

    /// Panes in reading order (left-to-right, top-to-bottom).
    public var panes: [PanelID] {
        switch self {
        case .pane(let p): [p]
        case .split(_, let kids): kids.flatMap(\.panes)
        }
    }

    /// Adds `new` right of (or below) `target`. Joins the parent split when it already runs that way,
    /// otherwise wraps `target` in a new split — so repeated ⌘D gives even columns, not a staircase.
    public func inserting(_ new: PanelID, beside target: PanelID, down: Bool) -> PaneTree {
        switch self {
        case .pane(let p):
            return p == target ? .split(down: down, [self, .pane(new)]) : self
        case .split(let d, var kids):
            if d == down, let i = kids.firstIndex(of: .pane(target)) {
                kids.insert(.pane(new), at: i + 1)
                return .split(down: d, kids)
            }
            return .split(down: d, kids.map { $0.inserting(new, beside: target, down: down) })
        }
    }

    /// The tree without `target`; nil when nothing is left. A split left with one child collapses into it.
    public func removing(_ target: PanelID) -> PaneTree? {
        switch self {
        case .pane(let p):
            return p == target ? nil : self
        case .split(let d, let kids):
            let rest = kids.compactMap { $0.removing(target) }
            if rest.isEmpty { return nil }
            return rest.count == 1 ? rest[0] : .split(down: d, rest)
        }
    }
}
