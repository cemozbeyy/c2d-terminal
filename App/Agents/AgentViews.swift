import C2DCore
import SwiftUI

/// Agent panel: the provider's own terminal UI, plus an honest header. There is no structured
/// event stream for Claude Code, so status is the process state and nothing more (Bible Part 7 §16).
struct AgentPanelView: View {
    let controller: TerminalPanelController
    let workspace: WorkspaceController
    @State private var showLaunch = false

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.space2) {
                IconTile(symbol: "cpu", tint: Theme.accent, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(controller.agentPlan?.provider.displayName ?? controller.agentRecord.flatMap { r in AgentProvider.builtIn.first { $0.id == r.providerID }?.displayName } ?? "Agent").font(.system(size: 12.5, weight: .semibold))
                        StatusChip(text: agentChipText, color: controller.isRunning ? Theme.success : Theme.textSecondary, symbol: controller.isRunning ? "circle.fill" : "stop.fill")
                    }
                    HStack(spacing: 6) {
                        Text(controller.agentPlan?.workingDirectory ?? controller.agentRecord?.workingDirectory ?? "").font(Theme.Typography.metadata).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                        if model.developerMode, let r = controller.agentRecord { Text("session \(r.id.prefix(8))").font(Theme.Typography.monoMetadata).foregroundStyle(Theme.textMuted) }
                    }
                    if let t = controller.agentPlan?.task ?? controller.agentRecord?.taskSummary, !t.isEmpty {
                        Text("Task: \(t)").font(Theme.Typography.badge).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer()
                if controller.isRunning {
                    Button("Stop") { Task { await controller.terminate() } }.help("SIGHUP, then SIGKILL after 2 s. Files already changed stay changed.")
                } else if controller.state?.isFinished == true, controller.agentPlan != nil {
                    // The surface stays mounted so the exit output is readable; the restart lives in the header.
                    Button("New Session") { controller.startNewSession() }.help("Starts the provider again in the same directory.")
                }
            }
            .padding(.horizontal, Theme.space2).padding(.vertical, 6)
            .background(Theme.panel)
            Divider()
            if controller.isRunning || controller.state != nil {
                TerminalSurfaceView(controller: controller)
            } else {
                VStack(spacing: 8) {
                    Text(controller.agentRecord == nil && controller.agentPlan == nil ? "No agent in this panel yet" : controller.statusText).foregroundStyle(Theme.textSecondary)
                    if controller.agentPlan != nil {
                        Button("New Session") { controller.startNewSession() }
                            .help("Starts the provider again in the same directory. Previous work on disk is untouched.")
                    } else if controller.agentRecord != nil {
                        if model.providersRefreshedAt == nil {
                            Text("Checking whether the provider is installed…").font(.caption).foregroundStyle(Theme.textMuted)
                        } else {
                            Text("Provider not available on this machine; the previous session cannot be restarted here.").font(.caption).foregroundStyle(Theme.warning)
                        }
                    }
                    Button("Start Agent…") { showLaunch = true }.tint(Theme.accent).buttonStyle(.clickProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel)   // placeholder, not a terminal: readable in light themes
            }
        }
        .sheet(isPresented: $showLaunch) { AgentLaunchSheet(workspace: workspace, targetPanel: controller.panelID) }
    }

    private var agentChipText: String {
        if case .running(let pid) = controller.state { return model.developerMode ? "Running · pid \(pid)" : "Running" }
        return controller.statusText
    }
}

/// Pre-launch flow (Bible Part 7 §5): provider readiness, directory, task, and what will happen.
struct AgentLaunchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceController
    let linkedTask: TaskRecord?
    let targetPanel: PanelID?
    @State private var providerID = AgentProvider.claudeCode.id
    @State private var directory: String
    @State private var task = ""
    @State private var error: String?

    init(workspace: WorkspaceController, task: TaskRecord? = nil, targetPanel: PanelID? = nil) {
        self.workspace = workspace
        self.linkedTask = task
        self.targetPanel = targetPanel
        _directory = State(initialValue: task?.worktreePath ?? workspace.projectPath)
        _task = State(initialValue: task.map { t in t.details.isEmpty ? t.title : "\(t.title)\n\n\(t.details)" } ?? "")
    }

    private var provider: AgentProvider { AgentProvider.builtIn.first { $0.id == providerID } ?? .claudeCode }
    private var status: AgentProviderStatus? { model.providerStatuses[providerID] }
    private var plan: AgentLaunchPlan? {
        guard let path = model.providerPaths[providerID] else { return nil }
        return try? AgentLaunchPlan.make(provider: provider, executablePath: path, projectPath: workspace.projectPath, workingDirectory: directory, task: task.isEmpty ? nil : task)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(linkedTask.map { "Start an agent for “\($0.title)”" } ?? "Start an agent session").font(.headline)
            Picker("Provider", selection: $providerID) {
                ForEach(AgentProvider.builtIn) { p in Text(p.displayName).tag(p.id) }
            }.clickCursor()
            statusLine
            Picker("Directory", selection: $directory) {
                Text("Project root — \(workspace.projectName)").tag(workspace.projectPath)
                ForEach(workspace.git.worktrees, id: \.path) { w in
                    Text("Worktree \(w.branch ?? "?") — \(w.path)").tag(w.path)
                }
            }.clickCursor()
            .task { await workspace.git.loadWorktrees() }
            if provider.capabilities.initialPromptArgument {
                TextField("Task (optional, passed as the initial prompt)", text: $task, axis: .vertical).lineLimit(2...4)
            } else {
                Text("This provider starts interactively; type the task in its terminal.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let plan {
                GroupBox {
                    Text(plan.displaySummary).font(Theme.Typography.monoBody).frame(maxWidth: .infinity, alignment: .leading)
                }
                let others = workspace.liveAgents(in: directory)
                if !others.isEmpty {
                    Label("\(others.count) other agent session(s) already run in this directory. They share one mutable working tree; a worktree keeps them apart.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                Text("The agent runs with your user's full permissions and its own approval prompts inside the terminal. C2D does not sandbox it (Bible Part 7 §24).")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let t = linkedTask {
                let unmet = workspace.tasks.unmetDependencies(of: t)
                if !unmet.isEmpty {
                    Label("This task waits on \(unmet.count) unfinished task(s): \(unmet.map(\.title).joined(separator: ", ")). Launching starts it against incomplete prerequisites.", systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.warning) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Launch") {
                    guard let plan else { error = "Provider is not ready."; return }
                    workspace.launchAgent(plan, task: linkedTask, intoPanel: targetPanel)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil)
            }
        }
        .padding(16)
        .frame(width: 520)
        .task { if model.providersRefreshedAt == nil { await model.refreshProviders() } }
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .available(let path, let version):
            Label("Ready: \(path)\(version.map { " · v\($0)" } ?? "")", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.success)
        case .setupRequired(let reason):
            Label("Setup required: \(reason)", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.warning)
        case .unavailable:
            Label("Not installed (not found on PATH, login PATH, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)", systemImage: "xmark.circle").font(.caption).foregroundStyle(Theme.warning)
        case .unknown, .none:
            Label("Checking…", systemImage: "hourglass").font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Session manager (Bible Part 7 §8): every agent session the registry knows, live or ended.
struct AgentsDestinationView: View {
    @Environment(AppModel.self) private var model
    @State private var showLaunch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agents").font(.title2)
                Spacer()
                Button { Task { await model.refreshProviders() } } label: { Label("Refresh providers", systemImage: "arrow.clockwise") }
                Button { showLaunch = true } label: { Label("New Session…", systemImage: "plus") }.disabled(model.workspace == nil).help(model.workspace == nil ? "Open a project first" : "")
            }
            GroupBox("Providers") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AgentProvider.builtIn) { p in
                        HStack {
                            Text(p.displayName).bold().frame(width: 110, alignment: .leading)
                            providerStatus(p)
                            Spacer()
                        }
                        .font(.caption)
                    }
                    if let t = model.providersRefreshedAt { Text("Checked \(t.formatted(date: .omitted, time: .standard))").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Sessions").font(.headline)
            if model.agentSessions.records.isEmpty {
                Text("No agent sessions yet.").foregroundStyle(Theme.textSecondary)
            } else {
                List(model.agentSessions.records.sorted { $0.startedAt > $1.startedAt }) { r in
                    HStack {
                        Circle().fill(r.isLive ? Theme.success : Theme.textMuted).frame(width: 7, height: 7)
                        VStack(alignment: .leading) {
                            Text("\(AgentProvider.builtIn.first { $0.id == r.providerID }?.displayName ?? r.providerID) · \(r.lifecycle.rawValue)").font(.caption).bold()
                            Text(r.workingDirectory).font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                            if let t = r.taskSummary { Text(t).font(Theme.Typography.micro).lineLimit(1) }
                        }
                        Spacer()
                        Text(r.startedAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                        if let ws = model.workspace, ws.projectPath == r.projectPath, let p = r.panelID, ws.layout.panels[p] != nil {
                            Button("Show") { if ws.layout.hidden.contains(p) { ws.restore(p) }; ws.activate(p); model.destination = .workspace }.font(.caption)
                        } else {
                            Text(r.projectPath.split(separator: "/").last.map(String.init) ?? "").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .sheet(isPresented: $showLaunch) { if let ws = model.workspace { AgentLaunchSheet(workspace: ws).environment(model) } }
        .task { if model.providersRefreshedAt == nil { await model.refreshProviders() } }
    }

    @ViewBuilder private func providerStatus(_ p: AgentProvider) -> some View {
        switch model.providerStatuses[p.id] {
        case .available(let path, let v): Text("ready · \(path)\(v.map { " · v\($0)" } ?? "")").foregroundStyle(Theme.success)
        case .setupRequired(let r): Text("setup required · \(r)").foregroundStyle(Theme.warning)
        case .unavailable: Text("not installed").foregroundStyle(Theme.textSecondary)
        default: Text("checking…").foregroundStyle(Theme.textSecondary)
        }
    }
}
