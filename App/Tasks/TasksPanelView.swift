import C2DCore
import SwiftUI

struct TasksPanelView: View {
    @Bindable var tasks: TaskController
    let workspace: WorkspaceController
    @State private var newTitle = ""
    @State private var noteText = ""
    @State private var blockReason = ""
    @State private var launchFor: TaskRecord?
    @State private var newPlanGoal = ""
    @State private var creatingPlan = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("New task title…", text: $newTitle).textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit { let t = newTitle; newTitle = ""; Task { await tasks.create(title: t) } }
                Button("Add") { let t = newTitle; newTitle = ""; Task { await tasks.create(title: t) } }.disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                Toggle("Done", isOn: $tasks.showTerminal).toggleStyle(.checkbox).clickCursor().font(.caption).onChange(of: tasks.showTerminal) { Task { await tasks.reload() } }
            }
            .padding(8)
            TextField("Filter", text: $tasks.filterText).textFieldStyle(.roundedBorder).font(.caption).padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            if !tasks.isAvailable {
                Text("Task storage is unavailable; tasks cannot be saved this session.").font(.caption).foregroundStyle(Theme.warning).padding()
            }
            HSplitView {
                list.frame(minWidth: 180)
                detail.frame(minWidth: 220)
            }
            if let err = tasks.lastError {
                HStack { Text(err).font(.caption).foregroundStyle(Theme.warning).lineLimit(2); Spacer(); Button("Dismiss") { tasks.lastError = nil }.font(.caption) }.padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Delete task?", isPresented: Binding(get: { tasks.deleteRequest != nil }, set: { if !$0 { tasks.deleteRequest = nil } })) {
            Button("Delete", role: .destructive) { if let t = tasks.deleteRequest { Task { await tasks.delete(t) } } }
            Button("Cancel", role: .cancel) { tasks.deleteRequest = nil }
        } message: { Text("Deletes the task record and its history. Files, branches, worktrees and agent sessions are not touched.") }
        .sheet(item: $launchFor) { t in AgentLaunchSheet(workspace: workspace, task: t) }
    }

    private var list: some View {
        List(selection: Binding(get: { tasks.selected?.id }, set: { id in Task { await tasks.select(tasks.tasks.first { $0.id == id }) } })) {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                let group = tasks.visibleTasks.filter { $0.status == status }
                if !group.isEmpty {
                    Section(statusLabel(status)) {
                        ForEach(group) { t in
                            HStack {
                                priorityDot(t.priority)
                                Text(t.title).font(.caption).lineLimit(1)
                                Spacer()
                                if t.assignedAgentSessionID != nil { Image(systemName: "cpu").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary) }
                                if t.blockedReason != nil { Image(systemName: "hand.raised").font(Theme.Typography.micro).foregroundStyle(Theme.warning) }
                                if !t.status.isTerminal && !t.dependsOn.isEmpty && !tasks.isEligible(t) { Image(systemName: "clock").font(Theme.Typography.micro).foregroundStyle(Theme.warning).help("Waiting on dependencies") }
                            }
                            .tag(t.id)
                        }
                    }
                }
            }
            if tasks.visibleTasks.isEmpty { Text(tasks.tasks.isEmpty ? "No tasks. Add one above." : "No match.").font(.caption).foregroundStyle(Theme.textSecondary) }
        }
        .listStyle(.inset)
    }

    @ViewBuilder private var detail: some View {
        if let t = tasks.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Title", text: Binding(get: { t.title }, set: { v in var r = t; r.title = v; Task { await tasks.update(r) } })).font(.headline).textFieldStyle(.plain)
                    HStack {
                        Text(statusLabel(t.status)).font(.caption).bold().padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent.opacity(0.2), in: Capsule())
                        Picker("", selection: Binding(get: { t.priority }, set: { v in var r = t; r.priority = v; Task { await tasks.update(r) } })) {
                            ForEach(TaskPriority.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu).fixedSize().controlSize(.small).clickCursor()
                        Spacer()
                    }
                    transitions(t)
                    labeled("Details") {
                        TextEditor(text: Binding(get: { t.details }, set: { v in var r = t; r.details = v; Task { await tasks.update(r) } })).font(Theme.Typography.body).frame(height: 70)
                    }
                    labeled("Acceptance criteria") {
                        TextEditor(text: Binding(get: { t.acceptanceCriteria ?? "" }, set: { v in var r = t; r.acceptanceCriteria = v.isEmpty ? nil : v; Task { await tasks.update(r) } })).font(Theme.Typography.body).frame(height: 50)
                    }
                    if let b = t.blockedReason {
                        Label("Blocked: \(b)", systemImage: "hand.raised").font(.caption).foregroundStyle(Theme.warning)
                        Button("Unblock → Ready") { Task { await tasks.unblock(t) } }.font(.caption)
                    } else if t.status.canTransition(to: .blocked) {
                        HStack {
                            TextField("Block reason", text: $blockReason).textFieldStyle(.roundedBorder).font(.caption)
                            Button("Block") { let r = blockReason; blockReason = ""; Task { await tasks.block(t, reason: r) } }.disabled(blockReason.isEmpty).font(.caption)
                        }
                    }
                    planSection(t)
                    dependencySection(t)
                    agentSection(t)
                    labeled("Activity") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(tasks.events) { e in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(e.at.formatted(date: .abbreviated, time: .shortened)).font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                                    Text(eventText(e)).font(Theme.Typography.metadata)
                                }
                            }
                            HStack {
                                TextField("Add a note", text: $noteText).textFieldStyle(.roundedBorder).font(.caption)
                                Button("Note") { let n = noteText; noteText = ""; Task { await tasks.addNote(t, n) } }.disabled(noteText.isEmpty).font(.caption)
                            }
                        }
                    }
                    HStack { Spacer(); Button("Delete…", role: .destructive) { tasks.deleteRequest = t }.font(.caption) }
                }
                .padding(10)
            }
        } else {
            Text("Select a task").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transitions(_ t: TaskRecord) -> some View {
        HStack(spacing: 6) {
            ForEach(TaskStatus.allCases.filter { t.status.canTransition(to: $0) && $0 != .blocked }, id: \.self) { next in
                let gated = next == .inProgress && !tasks.isEligible(t)
                Button(gated ? "Start anyway" : statusLabel(next)) { Task { await tasks.transition(t, to: next, override: gated) } }
                    .font(.caption).controlSize(.small).tint(gated ? Theme.warning : nil)
                    .help(gated ? "Blocked by unfinished dependencies; starting now runs against incomplete prerequisites." :
                          next == .completed ? "Completion is your decision; nothing marks a task done automatically." : "")
            }
        }
    }

    @ViewBuilder private func agentSection(_ t: TaskRecord) -> some View {
        labeled("Agent") {
            if let id = t.assignedAgentSessionID, let r = workspace.app.agentSessions.record(id) {
                HStack {
                    Circle().fill(r.isLive ? Theme.success : Theme.textMuted).frame(width: 7, height: 7)
                    Text("\(AgentProvider.builtIn.first { $0.id == r.providerID }?.displayName ?? r.providerID) · \(r.lifecycle.rawValue)").font(.caption)
                    Spacer()
                    if let p = r.panelID, workspace.layout.panels[p] != nil { Button("Show") { if workspace.layout.hidden.contains(p) { workspace.restore(p) }; workspace.activate(p) }.font(.caption) }
                    Button("Unlink") { Task { await tasks.assign(t, agentSessionID: nil) } }.font(.caption)
                }
                Text("An agent exiting does not complete the task; review its changes in Git first.").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
            } else {
                Button("Start agent for this task…") { launchFor = t }.font(.caption).disabled(t.status.isTerminal)
            }
        }
    }

    @ViewBuilder private func planSection(_ t: TaskRecord) -> some View {
        labeled("Plan") {
            HStack {
                Menu(tasks.plan(for: t)?.goal ?? "No plan") {
                    Button("No plan") { Task { await tasks.assign(t, toPlan: nil) } }
                    if !tasks.plans.isEmpty { Divider() }
                    ForEach(tasks.plans) { p in Button(p.goal) { Task { await tasks.assign(t, toPlan: p.id) } } }
                    Divider()
                    Button("New plan…") { creatingPlan = true }
                }.font(.caption).fixedSize().clickCursor()
                Spacer()
                if let p = tasks.plan(for: t) {
                    Text("\(tasks.tasks(inPlan: p.id).count) task(s), \(tasks.eligibleCount(inPlan: p.id)) ready")
                        .font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                }
            }
            if creatingPlan {
                HStack {
                    TextField("Plan goal", text: $newPlanGoal).textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit { commitNewPlan(for: t) }
                    Button("Create") { commitNewPlan(for: t) }.font(.caption).disabled(newPlanGoal.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { creatingPlan = false; newPlanGoal = "" }.font(.caption)
                }
            }
            if let p = tasks.plan(for: t), let v = p.verification, !v.isEmpty {
                Text("Verify: \(v)").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
        }
    }

    private func commitNewPlan(for t: TaskRecord) {
        let goal = newPlanGoal; newPlanGoal = ""; creatingPlan = false
        Task { if let p = await tasks.createPlan(goal: goal) { await tasks.assign(t, toPlan: p.id) } }
    }

    @ViewBuilder private func dependencySection(_ t: TaskRecord) -> some View {
        let deps = tasks.dependencies(of: t)
        let dependents = tasks.dependents(of: t)
        let candidates = tasks.dependencyCandidates(for: t)
        labeled("Dependencies") {
            if deps.isEmpty {
                Text("No dependencies — can start whenever you are ready.").font(Theme.Typography.metadata).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(deps) { d in
                    HStack(spacing: 6) {
                        Image(systemName: d.status == .completed ? "checkmark.circle.fill" : "clock")
                            .font(Theme.Typography.metadata).foregroundStyle(d.status == .completed ? Theme.success : Theme.warning)
                        Text(d.title).font(.caption).lineLimit(1)
                        Text("(\(statusLabel(d.status)))").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button { Task { await tasks.removeDependency(t, on: d.id) } } label: { Image(systemName: "xmark.circle").font(Theme.Typography.metadata) }
                            .buttonStyle(.clickPlain).help("Remove this dependency")
                    }
                }
                if !tasks.isEligible(t) {
                    Label("Waiting on \(tasks.unmetDependencies(of: t).count) unfinished task(s).", systemImage: "hand.raised").font(Theme.Typography.metadata).foregroundStyle(Theme.warning)
                }
            }
            if !candidates.isEmpty {
                Menu("Add dependency…") {
                    ForEach(candidates) { c in Button(c.title) { Task { await tasks.addDependency(t, on: c) } } }
                }.font(.caption).fixedSize().clickCursor()
            }
            if !dependents.isEmpty {
                Text("Blocks: \(dependents.map(\.title).joined(separator: ", "))").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
        }
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).bold().foregroundStyle(Theme.textSecondary); content() }
    }

    private func priorityDot(_ p: TaskPriority) -> some View {
        Circle().fill(p == .critical ? Theme.error : p == .high ? Theme.warning : p == .low ? Theme.textMuted : p == .unprioritized ? Color.clear : Theme.info)
            .frame(width: 7, height: 7).overlay(Circle().stroke(Theme.textMuted.opacity(0.4)))
            .accessibilityLabel("priority \(p.rawValue)")
    }

    private func statusLabel(_ s: TaskStatus) -> String {
        switch s {
        case .inbox: "Inbox"; case .ready: "Ready"; case .inProgress: "In progress"; case .blocked: "Blocked"
        case .awaitingReview: "Awaiting review"; case .completed: "Completed"; case .cancelled: "Cancelled"
        }
    }

    private func eventText(_ e: TaskEvent) -> String {
        switch e.kind {
        case .created: "Created"
        case .statusChanged: "\(e.fromStatus?.rawValue ?? "?") → \(e.toStatus?.rawValue ?? "?")\(e.detail.map { " — \($0)" } ?? "")"
        case .edited: "Edited \(e.detail ?? "")"
        case .assigned: "Agent \(e.detail ?? "")"
        case .blocked: "Blocked: \(e.detail ?? "")"
        case .unblocked: "Unblocked"
        case .note: e.detail ?? ""
        case .dependencyAdded: "Now depends on \(tasks.byID[e.detail ?? ""]?.title ?? e.detail ?? "?")"
        case .dependencyRemoved: "No longer depends on \(tasks.byID[e.detail ?? ""]?.title ?? e.detail ?? "?")"
        }
    }
}
