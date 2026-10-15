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
        .padding(4)
        .background(Color(nsColor: .underPageBackgroundColor))
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

    private let dividerThickness: CGFloat = 6
    private let minimumSize: CGFloat = 140

    var body: some View {
        GeometryReader { geo in
            let total = (orientation == .horizontal ? geo.size.width : geo.size.height) - dividerThickness * CGFloat(children.count - 1)
            let sum = weights.reduce(0, +)
            let sizes = weights.map { max(0, total * CGFloat($0 / max(sum, 0.0001))) }
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
        }
    }

    private func divider(at index: Int, total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: orientation == .horizontal ? dividerThickness : nil,
                   height: orientation == .vertical ? dividerThickness : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (orientation == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        .clipped()
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(panels, id: \.self) { id in
                if let panel = workspace.layout.panels[id] {
                    PanelTab(panel: panel, title: tabTitle(panel), isActive: id == active, workspace: workspace)
                }
            }
            Spacer(minLength: 0)
            Button { workspace.newTerminal(in: groupID) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).help("New terminal in this group")
            if workspace.layout.maximizedGroup == groupID {
                Button { workspace.exitFocusMode() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.plain).help("Exit Focus Mode")
            } else {
                Button { workspace.maximize(groupID) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help("Focus Mode: this group fills the workspace")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
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
        case .agentSession: return workspace.agent(for: panel.id).title
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
            .fill(Color.accentColor.opacity(targetedEdge == edge ? 0.45 : 0.15))
            .overlay(Text(edge.rawValue.capitalized).font(.caption).foregroundStyle(.white))
            .dropDestination(for: String.self) { items, _ in
                guard let id = Self.panelID(from: items) else { return false }
                workspace.move(id, beside: groupID, edge: edge)
                workspace.draggingPanel = nil
                return true
            } isTargeted: { targetedEdge = $0 ? edge : nil }
    }

    private var centerZone: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(targetedCenter ? 0.45 : 0.15))
            .overlay(Text("Add as tab").font(.caption).foregroundStyle(.white))
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
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Button { workspace.requestClose(panel.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).help("Close panel")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
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
            Text("No panels").foregroundStyle(.secondary)
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
            GitPanelView(git: workspace.git)
        case .agentSession:
            AgentPanelView(controller: workspace.agent(for: panel.id))
        case .tasks:
            TasksPanelView(tasks: workspace.tasks, workspace: workspace)
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
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Remove panel") { workspace.close(panel.id) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TerminalPanelView: View {
    let controller: TerminalPanelController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(controller.isRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(controller.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if controller.isRunning {
                    Button("Stop") { Task { await controller.terminate() } }.font(.caption).help("SIGHUP, then SIGKILL after 2 s")
                }
            }
            .padding(.horizontal, 8).frame(height: 22)
            if controller.isRunning || isStartingOrLive {
                TerminalSurfaceView(controller: controller)
            } else {
                VStack(spacing: 8) {
                    Text(controller.statusText).foregroundStyle(.secondary)
                    if let r = controller.record, r.lifecycle == .endedByRestart {
                        Text("Shell: \(URL(fileURLWithPath: r.shell).lastPathComponent) · directory: \(r.initialDirectory)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Button("New Session") { controller.startNewSession() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
