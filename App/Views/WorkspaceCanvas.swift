import C2DCore
import SwiftUI
import UniformTypeIdentifiers

private let dragPrefix = "c2d-panel:"

/// Renders the layout tree. Focus Mode shows one group but the tree stays intact (Bible Part 3 §8).
struct WorkspaceCanvas: View {
    @Bindable var workspace: WorkspaceController

    var body: some View {
        Group {
            if let g = workspace.layout.maximizedGroup, let node = WorkspaceLayout.node(g, in: workspace.layout.root) {
                LayoutNodeView(node: node, workspace: workspace)
            } else {
                LayoutNodeView(node: workspace.layout.root, workspace: workspace)
            }
        }
        .padding(Theme.space2)
        .background(Theme.window)
        .onAppear { DragMonitor.shared.install(workspace: workspace) }
        .alert("Stop this terminal?", isPresented: Binding(get: { workspace.closeConfirmation != nil }, set: { if !$0 { workspace.closeConfirmation = nil } })) {
            Button("Stop and Close", role: .destructive) { if let p = workspace.closeConfirmation { workspace.close(p) } }
            Button("Cancel", role: .cancel) { workspace.closeConfirmation = nil }
        } message: {
            Text("The shell is still running. Closing the panel sends SIGHUP, then SIGKILL after 2 seconds. Hide the panel instead to keep it running.")
        }
    }
}

/// Clears the drag state on mouse-up so drop zones never linger over a terminal.
@MainActor
final class DragMonitor {
    static let shared = DragMonitor()
    private var monitor: Any?
    private weak var workspace: WorkspaceController?

    func install(workspace: WorkspaceController) {
        self.workspace = workspace
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self?.workspace?.draggingPanel = nil
            }
            return event
        }
    }
}

struct LayoutNodeView: View {
    let node: LayoutNode
    let workspace: WorkspaceController

    var body: some View {
        switch node {
        case .group(let id, let panels, let active):
            PanelGroupView(groupID: id, panels: panels, active: active, workspace: workspace)
        case .split(let id, let orientation, let children, let weights):
            SplitView(splitID: id, orientation: orientation, children: children, weights: weights, workspace: workspace)
        }
    }
}

/// Resizable split with draggable dividers; neighbours absorb movement, minimum sizes hold.
struct SplitView: View {
    let splitID: NodeID
    let orientation: SplitOrientation
    let children: [LayoutNode]
    let weights: [Double]
    let workspace: WorkspaceController
    @State private var dragStart: [Double]?
    @State private var hoveredDivider: Int?

    private let dividerThickness: CGFloat = 6
    private let minimumSize: CGFloat = 220   // a docked sidebar (Git / Explorer) stays usable; below this its content breaks

    var body: some View {
        GeometryReader { geo in
            let total = (orientation == .horizontal ? geo.size.width : geo.size.height) - dividerThickness * CGFloat(children.count - 1)
            let sizes = distribute(total: max(0, total))
            let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    LayoutNodeView(node: child, workspace: workspace)
                        .frame(width: orientation == .horizontal ? sizes[index] : nil,
                               height: orientation == .vertical ? sizes[index] : nil)
                        .clipped()   // a panel whose content wants more room must not spill over its neighbours
                    if index < children.count - 1 {
                        divider(at: index, total: total)
                    }
                }
            }
            .coordinateSpace(name: "split")
        }
    }

    /// Distribute `total` across the children by weight, but never below each child's usable floor —
    /// so shrinking the window can't squeeze an agent/terminal column down to a few columns (it reflows
    /// to garbage there). Children below their floor are pinned to it and the rest share what's left by
    /// weight. Only when even the floors don't fit do they scale down together, so nothing overflows.
    private func distribute(total: CGFloat) -> [CGFloat] {
        let sum = weights.reduce(0, +)
        guard total > 0, sum > 0 else { return weights.map { _ in 0 } }
        let mins = children.map(minSize)
        let minTotal = mins.reduce(0, +)
        if total <= minTotal { return minTotal > 0 ? mins.map { total * ($0 / minTotal) } : weights.map { _ in total / CGFloat(weights.count) } }
        var sizes = weights.map { total * CGFloat($0 / sum) }
        var pinned = Set<Int>()
        for _ in sizes.indices {
            let below = sizes.indices.filter { !pinned.contains($0) && sizes[$0] < mins[$0] }
            if below.isEmpty { break }
            pinned.formUnion(below)
            let remaining = total - pinned.reduce(0) { $0 + mins[$1] }
            let freeWeight = sizes.indices.filter { !pinned.contains($0) }.reduce(0.0) { $0 + weights[$1] }
            for i in sizes.indices {
                if pinned.contains(i) { sizes[i] = mins[i] }
                else if freeWeight > 0 { sizes[i] = max(0, remaining) * CGFloat(weights[i] / freeWeight) }
            }
        }
        return sizes
    }

    /// A child's floor along the split axis. Horizontal: the widest floor among the kinds it hosts —
    /// an agent needs ~75 columns to render its TUI, a terminal/editor less, a sidebar least. Vertical
    /// splits only need a modest height floor so a stacked panel keeps a few rows.
    private func minSize(_ node: LayoutNode) -> CGFloat {
        guard orientation == .horizontal else { return 120 }
        let floors = node.panelIDs.map { id -> CGFloat in
            switch workspace.layout.panels[id]?.kind {
            case .some(.agentSession): return 560
            case .some(.terminal), .some(.editor): return 360
            default: return 200
            }
        }
        return floors.max() ?? 200
    }

    private func divider(at index: Int, total: CGFloat) -> some View {
        // A visible, subtle line normally; it brightens to the accent on hover so it's clearly a
        // draggable boundary, and the pointer becomes a column/row-resize cursor.
        Rectangle()
            .fill(hoveredDivider == index || dragStart != nil ? Theme.accent : Theme.borderSubtle)
            .frame(width: orientation == .horizontal ? dividerThickness : nil,
                   height: orientation == .vertical ? dividerThickness : nil)
            .contentShape(Rectangle())
            .pointerStyle(orientation == .horizontal ? .columnResize : .rowResize)
            .onHover { inside in hoveredDivider = inside ? index : (hoveredDivider == index ? nil : hoveredDivider) }
            .gesture(
                // Measured in the split's own space: in the divider's local space the origin moves with
                // every weight update, so the translation oscillated and the divider trembled.
                DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                    .onChanged { value in
                        if dragStart == nil { dragStart = weights }
                        guard let start = dragStart, total > 0 else { return }
                        let delta = Double((orientation == .horizontal ? value.translation.width : value.translation.height) / total) * start.reduce(0, +)
                        var next = start
                        let minWeight = Double(minimumSize / total) * start.reduce(0, +)
                        let pair = start[index] + start[index + 1]
                        var left = start[index] + delta
                        left = min(max(left, minWeight), pair - minWeight)
                        guard pair >= 2 * minWeight else { return }
                        next[index] = left
                        next[index + 1] = pair - left
                        workspace.setWeights(next, of: splitID)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityLabel("Resize divider")
    }
}

struct PanelGroupView: View {
    let groupID: NodeID
    let panels: [PanelID]
    let active: PanelID?
    let workspace: WorkspaceController
    @State private var targetedEdge: DockEdge?
    @State private var targetedCenter = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ZStack {
                if let active, let panel = workspace.layout.panels[active] {
                    PanelContentView(panel: panel, groupID: groupID, workspace: workspace)
                } else {
                    EmptyGroupView(groupID: groupID, workspace: workspace)
                }
                if workspace.draggingPanel != nil { dropZones }
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .panelCard()
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(panels, id: \.self) { id in
                if let panel = workspace.layout.panels[id] {
                    PanelTab(panel: panel, title: tabTitle(panel), isActive: id == active, workspace: workspace)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button { workspace.newPanel(.terminal, in: groupID) } label: { Label("Terminal", systemImage: "terminal") }
                Button { workspace.newPanel(.agentSession, in: groupID) } label: { Label("Agent (Claude Code)", systemImage: "cpu") }
                Button { workspace.newPanel(.editor, in: groupID) } label: { Label("Code Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
                Divider()
                Button { workspace.newPanel(.projectExplorer, in: groupID) } label: { Label("Explorer", systemImage: "folder") }
                Button { workspace.newPanel(.gitChanges, in: groupID) } label: { Label("Git Changes", systemImage: "arrow.triangle.branch") }
                Button { workspace.newPanel(.tasks, in: groupID) } label: { Label("Tasks", systemImage: "checklist") }
                Button { workspace.newPanel(.tokenOptimizer, in: groupID) } label: { Label("Token Optimizer", systemImage: "gauge.with.dots.needle.33percent") }
            } label: {
                Image(systemName: "plus").font(Theme.Typography.detail).fontWeight(.semibold)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tapTarget().clickCursor().foregroundStyle(Theme.textMuted).help("Add a panel to this group")
            if workspace.layout.maximizedGroup == groupID {
                Button { workspace.exitFocusMode() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left").font(Theme.Typography.detail).fontWeight(.semibold) }
                    .buttonStyle(.plain).tapTarget().clickCursor().foregroundStyle(Theme.textMuted).help("Exit Focus Mode")
            } else {
                Button { workspace.maximize(groupID) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(Theme.Typography.detail).fontWeight(.semibold) }
                    .buttonStyle(.plain).tapTarget().clickCursor().foregroundStyle(Theme.textMuted).help("Focus Mode: this group fills the workspace")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Theme.panelHeader)
        .dropDestination(for: String.self) { items, _ in
            guard let id = Self.panelID(from: items) else { return false }
            workspace.move(id, toGroup: groupID)
            workspace.draggingPanel = nil
            return true
        }
    }

    private func tabTitle(_ panel: Panel) -> String {
        switch panel.kind {
        case .terminal: return workspace.terminal(for: panel.id).title
        case .agentSession:
            let a = workspace.agent(for: panel.id)
            return a.agentPlan == nil && a.agentRecord == nil ? "Agent" : a.title
        case .editor:
            // Panel tabs and file tabs are different levels (Bible Part 3 §6.1); the panel stays "Editor".
            return workspace.editor(for: panel.id).hasUnsavedChanges ? "Editor ●" : "Editor"
        default: return panel.title ?? panel.kind.rawValue
        }
    }

    private var dropZones: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                zone(edge: .left).frame(width: w * 0.25).position(x: w * 0.125, y: h / 2)
                zone(edge: .right).frame(width: w * 0.25).position(x: w * 0.875, y: h / 2)
                zone(edge: .top).frame(width: w * 0.5, height: h * 0.25).position(x: w / 2, y: h * 0.125)
                zone(edge: .bottom).frame(width: w * 0.5, height: h * 0.25).position(x: w / 2, y: h * 0.875)
                centerZone.frame(width: w * 0.5, height: h * 0.5).position(x: w / 2, y: h / 2)
            }
        }
    }

    private func zone(edge: DockEdge) -> some View {
        Rectangle()
            .fill(Theme.accent.opacity(targetedEdge == edge ? 0.5 : 0.18))
            .overlay(Text(edge.rawValue.capitalized).font(.caption).foregroundStyle(Theme.onAccent))
            .dropDestination(for: String.self) { items, _ in
                guard let id = Self.panelID(from: items) else { return false }
                workspace.move(id, beside: groupID, edge: edge)
                workspace.draggingPanel = nil
                return true
            } isTargeted: { targetedEdge = $0 ? edge : nil }
    }

    private var centerZone: some View {
        Rectangle()
            .fill(Theme.accent.opacity(targetedCenter ? 0.5 : 0.18))
            .overlay(Text("Add as tab").font(.caption).foregroundStyle(Theme.onAccent))
            .dropDestination(for: String.self) { items, _ in
                guard let id = Self.panelID(from: items) else { return false }
                workspace.move(id, toGroup: groupID)
                workspace.draggingPanel = nil
                return true
            } isTargeted: { targetedCenter = $0 }
    }

    static func panelID(from items: [String]) -> PanelID? {
        items.first { $0.hasPrefix(dragPrefix) }.map { PanelID(String($0.dropFirst(dragPrefix.count))) }
    }
}

struct PanelTab: View {
    let panel: Panel
    let title: String
    let isActive: Bool
    let workspace: WorkspaceController

    var body: some View {
        let style = PanelKindStyle.style(for: panel.kind.rawValue)
        HStack(spacing: 5) {
            Image(systemName: style.symbol).font(Theme.Typography.metadata).fontWeight(.semibold).foregroundStyle(isActive ? style.tint : Theme.textMuted)
            Text(title).lineLimit(1).font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
            Button { workspace.requestClose(panel.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).tapTarget(22).clickCursor().foregroundStyle(Theme.textMuted).help("Close panel")
        }
        .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(isActive ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(panel.id) }
        .onDrag {
            workspace.draggingPanel = panel.id
            return NSItemProvider(object: (dragPrefix + panel.id.rawValue) as NSString)
        }
        .contextMenu {
            Button("Hide (keeps session running)") { workspace.hide(panel.id) }
            Button("Close…") { workspace.requestClose(panel.id) }
        }
        .accessibilityLabel("\(title) tab\(isActive ? ", active" : "")")
    }
}

struct EmptyGroupView: View {
    let groupID: NodeID
    let workspace: WorkspaceController
    var body: some View {
        VStack(spacing: 8) {
            Text("No panels").foregroundStyle(Theme.textSecondary)
            Button("New Terminal") { workspace.newTerminal(in: groupID) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelContentView: View {
    let panel: Panel
    let groupID: NodeID
    let workspace: WorkspaceController

    var body: some View {
        switch panel.kind {
        case .terminal:
            TerminalPanelView(controller: workspace.terminal(for: panel.id))
        case .projectExplorer:
            ExplorerPanelView(explorer: workspace.explorer, workspace: workspace)
        case .editor:
            EditorPanelView(editor: workspace.editor(for: panel.id))
        case .gitChanges:
            GitPanelView(git: workspace.git, workspace: workspace)
        case .agentSession:
            AgentPanelView(controller: workspace.agent(for: panel.id), workspace: workspace)
        case .tasks:
            TasksPanelView(tasks: workspace.tasks, workspace: workspace)
        case .tokenOptimizer:
            OptimizerPanelView(optimizer: workspace.optimizer, workspace: workspace)
        default:
            UnavailablePanelView(panel: panel, workspace: workspace)
        }
    }
}

/// A slot whose kind this build cannot host (Bible Part 3 §3.2). Never pretends to be content.
struct UnavailablePanelView: View {
    let panel: Panel
    let workspace: WorkspaceController
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed").font(.largeTitle)
            Text("Panel type “\(panel.attributes["originalKind"] ?? panel.kind.rawValue)” is not available in this build.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.textSecondary)
            Button("Remove panel") { workspace.close(panel.id) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TerminalPanelView: View {
    @Environment(AppModel.self) private var model
    let controller: TerminalPanelController
    /// Terminal-window panes only: split this pane to the right / close this pane. Workspace panels
    /// split by drag-and-drop and close from their group tab, so they pass nothing.
    var onSplit: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.space2) {
                Image(systemName: "terminal").font(Theme.Typography.detail).fontWeight(.semibold).foregroundStyle(Theme.success)
                Text(controller.title).font(Theme.Typography.body).fontWeight(.semibold)
                StatusChip(text: chipText, color: chipColor, symbol: controller.isRunning ? "circle.fill" : "stop.fill").layoutPriority(1)
                if controller.interruptArmedUntil != nil {
                    Text("Ctrl-C again to end the shell").font(Theme.Typography.monoMetadata).foregroundStyle(Theme.warning).lineLimit(1)
                }
                if let dir = controller.displayDirectory {
                    Text(dir).font(Theme.Typography.monoMetadata).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                        .help("Current directory (from the kernel): \(controller.context?.currentDirectory ?? "")")
                }
                if model.developerMode, let r = controller.record {
                    Text("session \(r.id.prefix(8)) · started in \(r.initialDirectory)").font(Theme.Typography.monoMetadata).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if controller.isRunning {
                    Button("Stop") { Task { await controller.terminate() } }.help("SIGHUP, then SIGKILL after 2 s")
                } else if controller.state?.isFinished == true {
                    Button("New Session") { controller.startNewSession() }.help("Starts a fresh shell here; the exit output above is replaced.")
                }
                if let onSplit {
                    Button(action: onSplit) { Image(systemName: "rectangle.split.2x1").font(Theme.Typography.detail).fontWeight(.semibold) }
                        .buttonStyle(.plain).tapTarget().clickCursor().foregroundStyle(Theme.textMuted).help("Split right: a new shell beside this one")
                }
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).tapTarget().clickCursor().foregroundStyle(Theme.textMuted).help("Close this pane (ends its shell)")
                }
            }
            .padding(.horizontal, Theme.space2).frame(height: 28)
            .background(Theme.panel)
            if controller.isRunning || isStartingOrLive {
                TerminalSurfaceView(controller: controller)
            } else {
                VStack(spacing: 8) {
                    Text(controller.statusText).foregroundStyle(Theme.textSecondary)
                    if let r = controller.record, r.lifecycle == .endedByRestart {
                        Text("Shell: \(URL(fileURLWithPath: r.shell).lastPathComponent) · directory: \(r.initialDirectory)")
                            .font(.caption).foregroundStyle(Theme.textMuted).lineLimit(2).truncationMode(.middle)
                    }
                    Button("New Session") { controller.startNewSession() }.tint(Theme.accent).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel)   // placeholder, not a terminal: readable in light themes
            }
        }
    }

    private var chipText: String {
        switch controller.state {
        case .running(let pid):
            let fg = controller.context?.foregroundCommand.map { " · \($0)" } ?? ""
            return model.developerMode ? "Running · pid \(pid)\(fg)" : "Running\(fg)"
        default: return controller.statusText
        }
    }

    private var chipColor: Color {
        switch controller.state {
        case .running, .terminating: Theme.success
        case .failed: Theme.error
        case .exited(.exited(let code)): code == 0 ? Theme.textSecondary : Theme.warning
        default: Theme.textSecondary
        }
    }

    /// Keep the surface mounted while the session exists so exit output stays readable until the user restarts.
    private var isStartingOrLive: Bool {
        switch controller.state {
        case .created, .exited: true
        default: false
        }
    }
}
