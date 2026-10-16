import C2DCore
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            mainContent
            if model.paletteVisible {
                Theme.scrim.opacity(0.35).ignoresSafeArea().onTapGesture { model.paletteVisible = false }
                CommandPaletteView(isPresented: $model.paletteVisible).padding(.top, 60).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .preferredColorScheme(.dark)   // dark-first product (Bible §5.1); light tokens exist but are unverified
        .sheet(isPresented: Binding(get: { model.diagnosticsPreview != nil }, set: { if !$0 { model.diagnosticsPreview = nil } })) {
            DiagnosticsExportSheet(text: model.diagnosticsPreview ?? "").environment(model)
        }
    }

    private var mainContent: some View {
        @Bindable var model = model
        return HStack(spacing: 0) {
            NavigationRail(destination: $model.destination, hasWorkspace: model.workspace != nil)
            VStack(spacing: 0) {
                TopBar()
                content
                if !model.messages.isEmpty { MessageBanner(messages: model.messages) }
                StatusBar()
            }
        }
        .background(Theme.window)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var content: some View {
        switch model.destination {
        case .projects: ProjectsView()
        case .workspace:
            if let ws = model.workspace { WorkspaceCanvas(workspace: ws) } else { ProjectsView() }
        case .agents: AgentsDestinationView()
        case .tasks:
            if let ws = model.workspace { TasksPanelView(tasks: ws.tasks, workspace: ws).padding(Theme.space3) } else { Text("Open a project to see its tasks.").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .settings: SettingsPlaceholderView()
        }
    }
}

struct NavigationRail: View {
    @Binding var destination: Destination
    let hasWorkspace: Bool

    var body: some View {
        VStack(spacing: 4) {
            IconTile(symbol: "terminal.fill", tint: Theme.accent, size: 30).padding(.vertical, 10).accessibilityLabel("C2D Terminal")
            ForEach(Destination.allCases) { d in
                let enabled = d != .workspace || hasWorkspace
                let selected = destination == d
                Button { destination = d } label: {
                    VStack(spacing: 4) {
                        Image(systemName: d.symbol).font(.system(size: 17, weight: .medium))
                        Text(d.label).font(.system(size: 9.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 72, height: 52)
                    .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                .help(enabled ? d.label : "Open a project first")
                .accessibilityLabel(d.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(width: 84)
        .background(Theme.rail)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.borderSubtle).frame(width: 1) }
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @State private var showAgentLaunch = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Theme.space2) {
            if let ws = model.workspace {
                Menu {
                    ForEach(model.registry.projects.filter(\.isAvailable)) { p in
                        Button(p.name) { model.openProject(p) }
                    }
                    Divider()
                    Button("Open Folder…") { model.promptOpenProject() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.warning)
                        Text(ws.projectName).font(Theme.Typography.title2).fontWeight(.semibold).lineLimit(1).foregroundStyle(Theme.textPrimary)
                        Image(systemName: "chevron.down").font(Theme.Typography.micro).fontWeight(.bold).foregroundStyle(Theme.textMuted)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .help(ws.projectPath)

                if ws.git.isAvailable {
                    Menu {
                        Button("Fetch") { Task { await ws.git.fetch() } }
                        Button(ws.git.behindCount > 0 ? "Pull (↓\(ws.git.behindCount))" : "Pull") { Task { await ws.git.pull() } }
                        Button(ws.git.aheadCount > 0 ? "Push (↑\(ws.git.aheadCount))" : "Push") { Task { await ws.git.push() } }
                        if !ws.git.hasUpstream {
                            Divider()
                            Text("No upstream — set one from the terminal: git push -u origin \(ws.git.status?.branch ?? "")")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch").font(Theme.Typography.detail).foregroundStyle(Theme.textSecondary)
                            Text(ws.git.branchLabel).font(Theme.Typography.body).fontWeight(.medium).lineLimit(1).foregroundStyle(Theme.textPrimary)
                            if ws.git.isBusy {
                                ProgressView().controlSize(.mini).scaleEffect(0.7)
                            } else {
                                Circle().fill(ws.git.status?.isClean == true ? Theme.success : Theme.warning).frame(width: 7, height: 7)
                                    .accessibilityLabel(ws.git.status?.isClean == true ? "clean" : "changes")
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(ws.git.isBusy)
                    .help(ws.git.repository?.isLinkedWorktree == true ? "Linked worktree: \(ws.git.repository?.root ?? "")" : "Fetch / Pull / Push · \(ws.git.repository?.root ?? "")")
                }

                Menu {
                    ForEach(LayoutPreset.allCases, id: \.self) { p in Button(p.displayName) { ws.apply(p) } }
                    Divider()
                    Button("Save as Default Layout") { ws.saveAsGlobalDefault() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.3.group").foregroundStyle(Theme.textSecondary)
                        Text(ws.layout.isBuiltIn ? ws.layout.name : "Custom layout").font(Theme.Typography.body).fontWeight(.medium).foregroundStyle(Theme.textSecondary)
                        Image(systemName: "chevron.down").font(Theme.Typography.micro).fontWeight(.bold).foregroundStyle(Theme.textMuted)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Theme.textSecondary)

                if !ws.layout.hidden.isEmpty {
                    Menu {
                        ForEach(ws.layout.hidden, id: \.self) { id in Button(ws.layout.panels[id]?.title ?? id.rawValue) { ws.restore(id) } }
                        Divider()
                        Button("Remove empty and ended hidden panels") { ws.cleanUpHiddenPanels() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "eye.slash").foregroundStyle(Theme.textSecondary)
                            Text("\(ws.layout.hidden.count) hidden").font(Theme.Typography.body).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            } else {
                Text("C2D Terminal").font(Theme.Typography.title2).fontWeight(.semibold)
            }

            Spacer(minLength: Theme.space2)

            // Search / commands (⌘K) rendered as a field, opens the palette.
            Button { model.paletteVisible = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                    Text("Search files, commands, agents…").font(Theme.Typography.body).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("⌘K").font(Theme.Typography.metadata).fontWeight(.medium).foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .frame(minWidth: 110, maxWidth: 260)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.borderSubtle))
            }
            .buttonStyle(.plain).keyboardShortcut("k", modifiers: .command).accessibilityLabel("Search and commands")

            Toggle(isOn: $model.developerMode) {
                Label("Dev Mode", systemImage: "wrench.and.screwdriver").font(Theme.Typography.detail).fontWeight(.semibold)
            }
            .toggleStyle(.button).controlSize(.small)
            .tint(Theme.accent)
            .help("Show process ids, session ids and paths in panel headers (Bible Part 2 §11)")

            if let ws = model.workspace {
                barButton("plus.rectangle", "New Terminal (⌘T)") { ws.newTerminal() }
                barButton("cpu", "New Agent…") { showAgentLaunch = true }
                barButton("gauge.with.dots.needle.33percent", "Token Optimizer (estimates only)") { ws.showOptimizerPanel() }
            }
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: 46)
        .background(Theme.window)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
        .sheet(isPresented: $showAgentLaunch) { if let ws = model.workspace { AgentLaunchSheet(workspace: ws).environment(model) } }
    }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.Typography.title2).fontWeight(.medium).foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 28)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.space3) {
            if let ws = model.workspace {
                Text("\(ws.layout.visiblePanelIDs.count) panel(s)")
                if let err = ws.lastSaveError {
                    Label("Layout not saved: \(err)", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                } else if ws.lastSavedAt != nil {
                    Label("Layout saved", systemImage: "checkmark").foregroundStyle(Theme.textMuted)
                }
                if model.developerMode {
                    Text("sessions: \(ws.terminals.values.filter(\.isRunning).count) live · editors: \(ws.editors.count)").foregroundStyle(Theme.textMuted)
                }
            }
            if let p = model.persistenceUnavailable {
                Label("No persistence: \(p)", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            }
            Spacer()
            Text(model.diagnostics.summary).foregroundStyle(Theme.textMuted)
        }
        .font(Theme.Typography.badge)
        .padding(.horizontal, Theme.space3)
        .frame(height: 24)
        .background(Theme.rail)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
    }
}

struct MessageBanner: View {
    @Environment(AppModel.self) private var model
    let messages: [UserMessage]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(messages) { m in
                HStack {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning)
                    VStack(alignment: .leading) {
                        Text(m.title).bold()
                        Text(m.detail).font(.caption).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Dismiss") { model.dismiss(m) }
                }
                .padding(Theme.space2)
                .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            }
        }
        .padding(Theme.space2)
    }
}

struct SettingsPlaceholderView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.title2)
            Toggle("Developer Mode — show process ids, session ids and paths", isOn: $model.developerMode)
            Text("Appearance, shortcuts, terminal defaults and privacy controls arrive with their features. Only working settings are listed here (Bible §3.12).")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
