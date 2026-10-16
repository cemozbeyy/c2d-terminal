import C2DCore
import SwiftUI

struct GitPanelView: View {
    @Bindable var git: GitController
    let workspace: WorkspaceController
    @State private var section = 0
    @State private var newBranch = ""
    @State private var newWorktreePath = ""
    @State private var newWorktreeBranch = ""
    @State private var newWorktreeCreates = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.warning)
                Text(git.branchLabel).font(.caption).bold().lineLimit(1)
                if git.isBusy { ProgressView().controlSize(.mini) }
                Spacer()
                Picker("", selection: $section) {
                    Text("Changes").tag(0); Text("Branches").tag(1); Text("Worktrees").tag(2); Text("History").tag(3)
                }
                .pickerStyle(.menu).controlSize(.small).fixedSize()
                Button { Task { await git.refresh(); await git.loadBranchesAndHistory(); await git.loadWorktrees() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh from git")
            }
            .padding(.horizontal, 8).frame(height: 30).background(Theme.panel)
            Divider()
            if git.repository == nil {
                VStack(spacing: 6) {
                    Text(git.discoveryError ?? "This folder is not inside a Git repository.").foregroundStyle(Theme.textSecondary)
                    Text("Run `git init` in the terminal to start one; C2D never initializes a repository silently.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch section {
                case 0: changes
                case 1: branchesView.task { await git.loadBranchesAndHistory() }
                case 2: worktreesView.task { await git.loadWorktrees() }
                default: historyView.task { await git.loadBranchesAndHistory() }
                }
            }
            if let err = git.lastError {
                HStack { Text(err).font(.caption).foregroundStyle(Theme.warning).lineLimit(3).textSelection(.enabled); Spacer(); Button("Dismiss") { git.lastError = nil }.font(.caption) }.padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Discard changes?", isPresented: Binding(get: { git.discardRequest != nil }, set: { if !$0 { git.discardRequest = nil } })) {
            Button("Discard", role: .destructive) { if let p = git.discardRequest { Task { await git.discard(p) } } }
            Button("Cancel", role: .cancel) { git.discardRequest = nil }
        } message: { Text("Unstaged modifications to \(git.discardRequest ?? "") are replaced with the index version. This cannot be undone.") }
        .alert("Remove worktree?", isPresented: Binding(get: { git.worktreeRemoveRequest != nil }, set: { if !$0 { git.worktreeRemoveRequest = nil } })) {
            Button("Remove", role: .destructive) { if let w = git.worktreeRemoveRequest { Task { await git.removeWorktree(w) } } }
            Button("Cancel", role: .cancel) { git.worktreeRemoveRequest = nil }
        } message: { Text("\(git.worktreeRemoveRequest?.path ?? "") is removed from disk and unregistered. The branch is kept. Git refuses if the worktree has uncommitted changes.") }
        .alert("Abort \(git.abortRequest?.rawValue ?? "operation")?", isPresented: Binding(get: { git.abortRequest != nil }, set: { if !$0 { git.abortRequest = nil } })) {
            Button("Abort", role: .destructive) { if let op = git.abortRequest { Task { await git.abort(op) } } }
            Button("Cancel", role: .cancel) { git.abortRequest = nil }
        } message: { Text("The entire \(git.abortRequest?.rawValue ?? "") is undone and the whole working tree returns to its state before it started. Uncommitted changes made after the \(git.abortRequest?.rawValue ?? "") began cannot be recovered. This affects all files, not just the selected one.") }
    }

    @ViewBuilder private var operationBanner: some View {
        if let op = git.operation {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text("A \(op.rawValue) is in progress. Resolve the conflicts below, then commit — or abort to undo it.").font(.caption)
                Spacer()
                Button("Abort \(op.rawValue)…", role: .destructive) { git.abortRequest = op }.font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 5).background(Theme.warning.opacity(0.12))
            Divider()
        }
    }

    // MARK: Changes

    private var changes: some View {
        VSplitView {
            VStack(spacing: 0) {
                operationBanner
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let s = git.status {
                            if s.isClean { Text("Working tree clean").font(.caption).foregroundStyle(Theme.textSecondary).padding(8) }
                            let conflicted = s.entries.filter(\.isConflicted)
                            let staged = s.entries.filter(\.hasStagedChange)
                            let unstaged = s.entries.filter(\.hasUnstagedChange)
                            let untracked = s.entries.filter(\.isUntracked)
                            if !conflicted.isEmpty { group("Conflicts", conflicted, staged: false, showStage: false) }
                            if !staged.isEmpty { group("Staged Changes (\(staged.count))", staged, staged: true, showStage: true) }
                            if !unstaged.isEmpty { group("Changes (\(unstaged.count))", unstaged, staged: false, showStage: true) }
                            if !untracked.isEmpty { group("Untracked (\(untracked.count))", untracked, staged: false, showStage: true) }
                        } else {
                            Text("Reading status…").font(.caption).foregroundStyle(Theme.textSecondary).padding(8)
                        }
                    }
                }
                Divider()
                composer
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            Group {
                if git.selectedIsConflicted, let path = git.selectedPath {
                    ConflictResolutionView(git: git, workspace: workspace, path: path)
                } else {
                    DiffView(files: git.selectedDiff, title: diffTitle, truncated: git.selectedDiffTruncated,
                             hunkActionTitle: git.hunkActionTitle,
                             onHunkAction: { idx, hunk in Task { await git.stageHunk(index: idx, hunk: hunk) } })
                }
            }
            .frame(maxWidth: .infinity, minHeight: 100)
        }
    }

    private var diffTitle: String {
        guard let p = git.selectedPath else { return "Select a file to see its diff" }
        return (git.selectedIsStaged ? "Index vs HEAD — " : "Working tree vs index — ") + p
    }

    private func group(_ title: String, _ entries: [GitStatusEntry], staged: Bool, showStage: Bool) -> some View {
        Section {
            ForEach(entries, id: \.self) { e in
                row(e, staged: staged, showStage: showStage)
            }
        } header: {
            HStack {
                Text(title).font(.caption).bold().foregroundStyle(Theme.textSecondary)
                Spacer()
                if showStage && !staged && entries.count > 1 {
                    Button("Stage all") { Task { await git.stageAll() } }.font(.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
        }
    }

    private func row(_ e: GitStatusEntry, staged: Bool, showStage: Bool) -> some View {
        let change = staged ? e.staged : e.unstaged
        let letter = e.isConflicted ? "C" : e.isUntracked ? "U" : String(change.rawValue)
        return HStack(spacing: 6) {
            Text(letter).font(.system(.caption, design: .monospaced)).bold().foregroundStyle(color(letter)).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text((e.path as NSString).lastPathComponent).font(.caption).lineLimit(1)
                if let o = e.originalPath { Text("← \(o)").font(.system(size: 9)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                else { Text((e.path as NSString).deletingLastPathComponent).font(.system(size: 9)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            }
            Spacer()
            if showStage {
                if staged {
                    Button("Unstage") { Task { await git.unstage([e.path]) } }.font(.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
                } else {
                    if !e.isUntracked { Button("Discard…") { git.discardRequest = e.path }.font(.caption).buttonStyle(.plain).foregroundStyle(Theme.error) }
                    Button("Stage") { Task { await git.stage([e.path]) } }.font(.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(git.selectedPath == e.path && git.selectedIsStaged == staged ? Theme.accent.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { Task { await git.select(path: e.path, staged: staged) } }
        .accessibilityLabel("\(letter) \(e.path)")
    }

    private func color(_ letter: String) -> Color {
        switch letter { case "A", "U": .green; case "D": .red; case "C": .orange; default: .yellow }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $git.commitMessage).font(.system(size: 12)).frame(height: 52)
                .overlay(alignment: .topLeading) { if git.commitMessage.isEmpty { Text("Commit message (staged changes only)").font(.caption).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) } }
            HStack {
                Text("\(git.stagedCount) staged file(s)").font(.caption).foregroundStyle(Theme.textSecondary)
                if let h = git.lastCommitHash { Text("last commit \(h.prefix(7))").font(.caption).foregroundStyle(Theme.textSecondary) }
                Spacer()
                Button("Commit") { Task { await git.commit() } }.disabled(!git.canCommit).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(8)
    }

    // MARK: Branches / worktrees / history

    private var branchesView: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("new-branch-name", text: $newBranch).textFieldStyle(.roundedBorder).font(.caption)
                Button("Create & switch") { let n = newBranch; newBranch = ""; Task { await git.createBranch(n) } }.disabled(newBranch.trimmingCharacters(in: .whitespaces).isEmpty || git.isBusy)
            }
            .padding(8)
            Divider()
            List(git.branches, id: \.self) { b in
                HStack {
                    Image(systemName: b.isCurrent ? "checkmark.circle.fill" : "circle").foregroundStyle(b.isCurrent ? Color.accentColor : .secondary)
                    Text(b.name).font(.caption)
                    if let u = b.upstream { Text("→ \(u)").font(.system(size: 9)).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                    Text(b.head.prefix(7)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    if !b.isCurrent { Button("Switch") { Task { await git.checkout(b.name) } }.font(.caption).disabled(git.isBusy) }
                }
            }
            .listStyle(.inset)
            Text("Switching refuses when the working tree is dirty; nothing is stashed automatically.").font(.system(size: 9)).foregroundStyle(Theme.textSecondary).padding(6)
        }
    }

    private var worktreesView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Destination path (must not exist)", text: $newWorktreePath).textFieldStyle(.roundedBorder).font(.caption)
                HStack {
                    TextField("branch", text: $newWorktreeBranch).textFieldStyle(.roundedBorder).font(.caption)
                    Toggle("create branch", isOn: $newWorktreeCreates).font(.caption)
                    Button("Add worktree") {
                        let p = newWorktreePath, b = newWorktreeBranch, c = newWorktreeCreates
                        newWorktreePath = ""; newWorktreeBranch = ""
                        Task { await git.addWorktree(path: p, branch: b, createBranch: c) }
                    }
                    .disabled(newWorktreePath.isEmpty || newWorktreeBranch.isEmpty || git.isBusy)
                }
            }
            .padding(8)
            Divider()
            List(git.worktrees, id: \.self) { w in
                HStack {
                    Image(systemName: w.isMain ? "house" : "arrow.triangle.branch").foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading) {
                        Text(w.branch ?? w.head?.prefix(7).description ?? "?").font(.caption).bold()
                        Text(w.path).font(.system(size: 9)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if w.isLocked { Text("locked").font(.system(size: 9)).foregroundStyle(Theme.warning) }
                    if !w.isMain { Button("Remove…") { git.worktreeRemoveRequest = w }.font(.caption).disabled(git.isBusy) }
                }
            }
            .listStyle(.inset)
            Text("Worktrees share repository data and are not a security sandbox (Bible Part 6 §14.2).").font(.system(size: 9)).foregroundStyle(Theme.textSecondary).padding(6)
        }
    }

    private var historyView: some View {
        List(git.history, id: \.self) { c in
            HStack(alignment: .top) {
                Text(c.shortHash).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading) {
                    Text(c.subject).font(.caption).lineLimit(2)
                    Text("\(c.author) · \(c.date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .listStyle(.inset)
    }
}

/// Unified diff rendering; the comparison is always named (Bible Part 6 §5).
struct DiffView: View {
    let files: [FileDiff]
    let title: String
    let truncated: Bool
    /// `nil` hides the per-hunk button (binary, new/deleted, conflicted, or nothing selected).
    var hunkActionTitle: String? = nil
    var onHunkAction: ((Int, DiffHunk) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if truncated { Text("truncated to \(GitController.diffLineLimit) lines").font(.caption).foregroundStyle(Theme.warning) }
            }
            .padding(.horizontal, 8).frame(height: 22)
            Divider()
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    // A bidirectional scroll view centers content smaller than its viewport; pin it top-leading instead.
                    diffBody.frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }
        }
    }

    private var diffBody: some View {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        if file.isBinary { Text("Binary file; no textual diff.").font(.caption).foregroundStyle(Theme.textSecondary).padding(8) }
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                            HStack(spacing: 6) {
                                Text(hunk.header).font(.system(size: 11, design: .monospaced)).foregroundStyle(.blue)
                                Spacer()
                                if let title = hunkActionTitle, let action = onHunkAction {
                                    Button(title) { action(hunkIndex, hunk) }.font(.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                HStack(spacing: 0) {
                                    Text(line.oldLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
                                    Text(line.newLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
                                    Text(prefix(line)).frame(width: 14)
                                    Text(line.text).lineLimit(1)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(line.kind == .context ? Color.primary : line.kind == .added ? Color.green : Color.red)
                                .background(line.kind == .context ? Color.clear : (line.kind == .added ? Color.green : Color.red).opacity(0.12))
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                    if files.isEmpty { Text("No diff").font(.caption).foregroundStyle(Theme.textSecondary).padding(8) }
                }
                .textSelection(.enabled)
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.kind { case .added: "+"; case .removed: "-"; case .context: " " }
    }
}

/// Conflict resolution for one file (Bible Part 6 §9). Shows ours/theirs (and base when a real
/// three-way merge) and offers: keep a side (staged immediately), open the file to merge by hand,
/// or mark the hand-edited file resolved. Resolving one file never finishes the merge.
struct ConflictResolutionView: View {
    @Bindable var git: GitController
    let workspace: WorkspaceController
    let path: String

    private var kind: ConflictKind? { git.selectedConflictKind }
    private var stages: ConflictStages? { git.selectedConflictStages }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conflict — \(path)").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let kind { Text(label(kind)).font(.caption).bold().foregroundStyle(Theme.warning) }
            }
            .padding(.horizontal, 8).frame(height: 22)
            Divider()
            HStack(spacing: 6) {
                Button("Use ours") { Task { await git.resolveConflict(path, using: .ours) } }
                Button("Use theirs") { Task { await git.resolveConflict(path, using: .theirs) } }
                Button("Open in editor") { workspace.openFile(path: (git.projectPath as NSString).appendingPathComponent(path)) }
                Button("Mark resolved") { Task { await git.markResolved(path) } }
                Spacer()
            }
            .font(.caption).controlSize(.small).padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    stage("Ours (current branch)", stages?.ours, empty: oursEmpty)
                    stage("Theirs (incoming)", stages?.theirs, empty: theirsEmpty)
                    if kind?.hasBase == true { stage("Base (common ancestor)", stages?.base, empty: "—") }
                    Text("“Use ours/theirs” keeps one side and stages it. To combine both, open the file, remove the <<<<<<< markers, then Mark resolved. Resolving a file does not finish the merge — commit once every conflict is resolved.")
                        .font(.system(size: 9)).foregroundStyle(Theme.textSecondary).padding(.top, 2)
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder private func stage(_ title: String, _ content: MergeStageContent?, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).bold().foregroundStyle(Theme.textSecondary)
            switch content {
            case .text(let t):
                Text(t.isEmpty ? "(empty)" : t).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .binary:
                Text("Binary content — resolve by choosing a side.").font(.caption).foregroundStyle(Theme.warning)
            case .absent, .none:
                Text(empty).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // Empty-side wording is derived from the conflict kind, never from stage absence alone.
    private var oursEmpty: String {
        switch kind {
        case .deletedByUs: "We deleted this file."
        case .addedByThem: "We don't have this file (added on the other side)."
        default: "—"
        }
    }
    private var theirsEmpty: String {
        switch kind {
        case .deletedByThem: "The other side deleted this file."
        case .addedByUs: "The other side doesn't have this file."
        default: "—"
        }
    }

    private func label(_ k: ConflictKind) -> String {
        switch k {
        case .bothModified: "both modified"; case .bothAdded: "both added"; case .bothDeleted: "both deleted"
        case .addedByUs: "added by us"; case .addedByThem: "added by them"
        case .deletedByUs: "deleted by us"; case .deletedByThem: "deleted by them"; case .unknown: "conflict"
        }
    }
}
