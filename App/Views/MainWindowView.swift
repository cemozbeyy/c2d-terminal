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
        .tooltipLayer()                // hover tooltips render here, above everything, never clipped
        .preferredColorScheme(ThemeManager.shared.isDark ? .dark : .light)   // follows the selected theme (sun/moon toggle in the top bar)
        .sheet(isPresented: Binding(get: { model.diagnosticsPreview != nil }, set: { if !$0 { model.diagnosticsPreview = nil } })) {
            DiagnosticsExportSheet(text: model.diagnosticsPreview ?? "").environment(model)
        }
    }

    private var mainContent: some View {
        @Bindable var model = model
        return HStack(spacing: 0) {
            NavigationRail(destination: $model.destination, hasWorkspace: model.workspace != nil) { d in
                // Source Control opens as a docked left panel in the workspace, not a full-screen page.
                if d == .sourceControl, let ws = model.workspace {
                    model.destination = .workspace
                    ws.toggleGitPanel()
                } else {
                    model.destination = d
                }
            }
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
        case .workspace, .sourceControl:   // Git is a docked left panel, not a full-screen view (see the rail)
            if let ws = model.workspace { WorkspaceCanvas(workspace: ws) } else { ProjectsView() }
        case .agents: AgentsDestinationView()
        case .tasks:
            if let ws = model.workspace { TasksPanelView(tasks: ws.tasks, workspace: ws).padding(Theme.space3) } else { Text("Open a project to see its tasks.").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .marketplace: MarketplaceView()
        case .settings: SettingsPlaceholderView()
        }
    }
}

struct NavigationRail: View {
    @Binding var destination: Destination
    let hasWorkspace: Bool
    var onSelect: (Destination) -> Void

    var body: some View {
        VStack(spacing: 4) {
            IconTile(symbol: "terminal.fill", tint: Theme.accent, size: 30).padding(.vertical, 10).accessibilityLabel("C2D Terminal")
            ForEach(Destination.allCases) { d in
                let enabled = (d != .workspace && d != .sourceControl) || hasWorkspace
                let selected = destination == d
                Button { onSelect(d) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: d.symbol).font(.system(size: 17, weight: .medium))
                        Text(d.label).font(.system(size: 9.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 72, height: 52)
                    .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
                }
                .buttonStyle(.plain).clickCursor()
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
    #if DEBUG
    @State private var showOptimizerPopover = UserDefaults.standard.bool(forKey: "c2dOptimizerPopoverCheck")   // `-c2dOptimizerPopoverCheck YES`: start with the card open (screenshot checks)
    #else
    @State private var showOptimizerPopover = false
    #endif

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Theme.space2) {
            if let ws = model.workspace {
                // Pages: a single segmented strip — one quiet segment per open project, the active one lifted.
                HStack(spacing: 2) {
                    ForEach(model.openWorkspaces, id: \.projectPath) { page in
                        let active = page === ws
                        HStack(spacing: 5) {
                            Text(page.projectName).font(Theme.Typography.body).fontWeight(active ? .semibold : .regular).lineLimit(1)
                                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                            if active && model.openWorkspaces.count > 1 {
                                Button { model.closePage(page) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textMuted)
                                        .frame(width: 14, height: 14).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help("Close this page")
                            }
                        }
                        .padding(.leading, 9).padding(.trailing, active && model.openWorkspaces.count > 1 ? 4 : 9).frame(height: 24)
                        .background(active ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius - 2))
                        .shadow(color: active ? .black.opacity(0.12) : .clear, radius: 1, y: 0.5)
                        .contentShape(Rectangle()).clickCursor()
                        .onTapGesture { model.showPage(page) }
                        .help(page.projectPath)
                    }
                Menu {
                    ForEach(model.registry.projects.filter(\.isAvailable)) { p in
                        Button(p.name) { model.openProject(p) }
                    }
                    Divider()
                    Button("Open Folder…") { model.promptOpenProject() }
                    Divider()
                    Button("New Terminal Window") { (NSApp.delegate as? AppDelegate)?.newWindowForTab(nil) }.keyboardShortcut("n", modifiers: .command)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().clickCursor()
                    .help("New page (another project, ⌘⇧N) or a new terminal window (⌘N)")
                }
                .padding(3)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))

                if ws.git.isAvailable {
                    Menu {
                        Button { model.destination = .workspace; ws.toggleGitPanel() } label: { Label("Show Changes", systemImage: "arrow.triangle.branch") }
                        Divider()
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
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().clickCursor()
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
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Theme.textSecondary).clickCursor()

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
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().clickCursor()
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
            .buttonStyle(.plain).clickCursor().keyboardShortcut("k", modifiers: .command).accessibilityLabel("Search and commands")

            Button { ThemeManager.shared.toggleLightDark() } label: {
                Image(systemName: ThemeManager.shared.isDark ? "sun.max" : "moon")
                    .font(Theme.Typography.title2).fontWeight(.medium).foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 30)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).clickCursor()
            .help(ThemeManager.shared.isDark ? "Switch to light mode" : "Switch to dark mode")

            Toggle(isOn: $model.developerMode) {
                Label("Dev Mode", systemImage: "wrench.and.screwdriver").font(Theme.Typography.detail).fontWeight(.semibold)
            }
            .toggleStyle(.button).controlSize(.small)
            .tint(Theme.accent)
            .help("Show process ids, session ids and paths in panel headers (Bible Part 2 §11)")

            if let ws = model.workspace {
                barButton("sidebar.left", "Toggle the file explorer sidebar (⌘B)") { ws.toggleExplorer() }
                barButton("plus.rectangle", "New terminal — opens a shell in this project (⌘T)") { ws.newTerminal() }
                barButton("cpu", "New agent — launch a Claude Code session for this project") { showAgentLaunch = true }
                Button { showOptimizerPopover.toggle() } label: {
                    Image(systemName: "gauge.with.dots.needle.33percent").font(Theme.Typography.title2).fontWeight(.medium)
                        .foregroundStyle(model.optimizerEnabled ? Theme.accent : Theme.textSecondary)
                        .frame(width: 34, height: 30)
                        .background(model.optimizerEnabled ? Theme.accent.opacity(0.18) : Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(model.optimizerEnabled ? Theme.accent.opacity(0.6) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).clickCursor()
                .help(model.optimizerEnabled ? "Token Optimizer: on" : "Token Optimizer: off")
                .popover(isPresented: $showOptimizerPopover, arrowEdge: .bottom) {
                    OptimizerPopover(workspace: ws)
                }
                Button("") { ws.toggleExplorer() }.keyboardShortcut("b", modifiers: .command).opacity(0).frame(width: 0).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: 46)
        .background(Theme.window)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
        .sheet(isPresented: $showAgentLaunch) { if let ws = model.workspace { AgentLaunchSheet(workspace: ws).environment(model) } }
    }

    private func barButton(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.Typography.title2).fontWeight(.medium).foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .frame(width: 34, height: 30)
                .background(active ? Theme.accent.opacity(0.15) : Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickCursor().tooltip(help).accessibilityLabel(help)
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

/// Token Optimizer switch as a small card (top-bar gauge button), not a bare system menu.
struct OptimizerPopover: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceController

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack(spacing: 10) {
                IconTile(symbol: "gauge.with.dots.needle.33percent", tint: model.optimizerEnabled ? Theme.accent : Theme.textMuted, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Optimizer").font(Theme.Typography.title2).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                    Text(model.optimizerEnabled ? "On" : "Off").font(Theme.Typography.detail)
                        .foregroundStyle(model.optimizerEnabled ? Theme.success : Theme.textMuted)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $model.optimizerEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                row("chart.bar.doc.horizontal", "Measures the context you hand to an agent and flags what is oversized.")
                row("lock.shield", "Estimates only — nothing is billed or sent anywhere.")
                row("sparkles", "Premium trimming comes later; the switch is ready for it.", muted: true)
            }
            if model.developerMode {
                Divider()
                Button {
                    workspace.toggleOptimizerPanel()
                } label: {
                    Label(workspace.isOptimizerVisible ? "Hide optimizer panel" : "Show optimizer panel", systemImage: "rectangle.bottomhalf.inset.filled")
                        .font(Theme.Typography.detail)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).clickCursor()
            }
        }
        .padding(Theme.space4)
        .frame(width: 300)
        .background(Theme.panel)
    }

    private func row(_ symbol: String, _ text: String, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(Theme.Typography.detail).foregroundStyle(muted ? Theme.textMuted : Theme.accent).frame(width: 14)
            Text(text).font(Theme.Typography.detail).foregroundStyle(muted ? Theme.textMuted : Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
