import C2DCore
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            mainContent
            if model.paletteVisible {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.paletteVisible = false }
                CommandPaletteView(isPresented: $model.paletteVisible).padding(.top, 60).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var mainContent: some View {
        @Bindable var model = model
        return HStack(spacing: 0) {
            NavigationRail(destination: $model.destination, hasWorkspace: model.workspace != nil)
            Divider()
            VStack(spacing: 0) {
                TopBar()
                Divider()
                content
                if !model.messages.isEmpty { MessageBanner(messages: model.messages) }
                StatusBar()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch model.destination {
        case .projects: ProjectsView()
        case .workspace:
            if let ws = model.workspace { WorkspaceCanvas(workspace: ws) } else { ProjectsView() }
        case .agents: AgentsDestinationView()
        case .tasks:
            if let ws = model.workspace { TasksPanelView(tasks: ws.tasks, workspace: ws).padding(8) } else { Text("Open a project to see its tasks.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .settings: SettingsPlaceholderView()
        }
    }
}

struct NavigationRail: View {
    @Binding var destination: Destination
    let hasWorkspace: Bool

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Destination.allCases) { d in
                let enabled = d != .workspace || hasWorkspace
                Button {
                    destination = d
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: d.symbol).font(.system(size: 16))
                        Text(d.label).font(.system(size: 9))
                    }
                    .frame(width: 56, height: 46)
                    .background(destination == d ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                .help(enabled ? d.label : "Open a project first")
                .accessibilityLabel(d.label)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 64)
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @State private var showAgentLaunch = false

    var body: some View {
        HStack(spacing: 12) {
            if let ws = model.workspace {
                Label(ws.projectName, systemImage: "folder").font(.headline).help(ws.projectPath)
                if ws.git.isAvailable {
                    Label(ws.git.branchLabel, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                        .help(ws.git.repository?.isLinkedWorktree == true ? "Linked worktree: \(ws.git.repository?.root ?? "")" : "Repository: \(ws.git.repository?.root ?? "")")
                }
                Menu {
                    ForEach(LayoutPreset.allCases, id: \.self) { p in
                        Button(p.displayName) { ws.apply(p) }
                    }
                } label: {
                    Label(ws.layout.isBuiltIn ? ws.layout.name : "Custom layout", systemImage: "rectangle.3.group")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if !ws.layout.hidden.isEmpty {
                    Menu {
                        ForEach(ws.layout.hidden, id: \.self) { id in
                            Button(ws.layout.panels[id]?.title ?? id.rawValue) { ws.restore(id) }
                        }
                    } label: {
                        Label("Hidden panels (\(ws.layout.hidden.count))", systemImage: "eye.slash")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                Button { ws.newTerminal() } label: { Label("New Terminal", systemImage: "plus.rectangle") }
                    .help("New terminal in \(ws.projectName) (⌘T)")
                Button { ws.showOptimizerPanel() } label: { Label("Optimizer", systemImage: "gauge.with.dots.needle.33percent") }
                    .help("Token Optimizer: measure prepared context (estimates only)")
                Button { showAgentLaunch = true } label: { Label("New Agent", systemImage: "cpu") }
                    .help("Start Claude Code or another supported agent in this project")
                if ws.layout.maximizedGroup != nil {
                    Button("Exit Focus Mode") { ws.exitFocusMode() }.keyboardShortcut(.escape, modifiers: [])
                }
            } else {
                Text("C2D Terminal").font(.headline)
                Spacer()
            }
            Button { model.paletteVisible = true } label: { Label("Search / Commands", systemImage: "magnifyingglass") }
                .keyboardShortcut("k", modifiers: .command).help("Command palette (⌘K)")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .sheet(isPresented: $showAgentLaunch) { if let ws = model.workspace { AgentLaunchSheet(workspace: ws).environment(model) } }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let ws = model.workspace {
                Text("\(ws.layout.visiblePanelIDs.count) panel(s)")
                if let err = ws.lastSaveError {
                    Label("Layout not saved: \(err)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if ws.lastSavedAt != nil {
                    Label("Layout saved", systemImage: "checkmark").foregroundStyle(.secondary)
                }
            }
            if let p = model.persistenceUnavailable {
                Label("No persistence: \(p)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer()
            Text(model.diagnostics.summary).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 22)
    }
}

struct MessageBanner: View {
    @Environment(AppModel.self) private var model
    let messages: [UserMessage]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(messages) { m in
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    VStack(alignment: .leading) {
                        Text(m.title).bold()
                        Text(m.detail).font(.caption).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Dismiss") { model.dismiss(m) }
                }
                .padding(8)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.title2)
            Text("No settings are implemented yet. Appearance, shortcuts, terminal defaults and privacy controls arrive with their features.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
