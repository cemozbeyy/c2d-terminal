import AppKit
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
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.warning)
                Text(git.branchLabel).font(.caption).bold().lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if git.isBusy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 4)
                Picker("", selection: $section) {
                    Text("Changes").tag(0); Text("Branches").tag(1); Text("Worktrees").tag(2); Text("History").tag(3)
                }
                .pickerStyle(.menu).controlSize(.small).fixedSize().labelsHidden()
                Button { Task { await git.refresh(); await git.loadBranchesAndHistory(); await git.loadWorktrees() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).clickCursor().help("Refresh from git")
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
        } message: {
            let paths = git.discardRequest ?? []
            Text("Unstaged modifications to \(paths.count == 1 ? paths[0] : "\(paths.count) files") are replaced with the index version. This cannot be undone.")
        }
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
        VStack(spacing: 0) {
            operationBanner
            composer
            if git.selectedPath == nil {
                changeList
            } else {
                VSplitView {
                    changeList
                    Group {
                        if git.selectedIsConflicted, let path = git.selectedPath {
                            ConflictResolutionView(git: git, workspace: workspace, path: path)
                        } else {
                            DiffView(files: git.selectedDiff, title: diffTitle, truncated: git.selectedDiffTruncated,
                                     hunkActionTitle: git.hunkActionTitle,
                                     onHunkAction: { idx, hunk in Task { await git.stageHunk(index: idx, hunk: hunk) } },
                                     onClose: { git.selectedPath = nil })
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                }
            }
        }
    }

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let s = git.status {
                    if s.isClean { Text("No changes").font(.caption).foregroundStyle(Theme.textSecondary).padding(10) }
                    let conflicted = s.entries.filter(\.isConflicted)
                    let staged = s.entries.filter(\.hasStagedChange)
                    let unstaged = s.entries.filter(\.hasUnstagedChange)
                    let untracked = s.entries.filter(\.isUntracked)
                    if !conflicted.isEmpty { group("Merge Changes", conflicted, kind: .conflicted) }
                    if !staged.isEmpty { group("Staged Changes", staged, kind: .staged) }
                    if !unstaged.isEmpty { group("Changes", unstaged, kind: .unstaged) }
                    if !untracked.isEmpty { group("Untracked", untracked, kind: .untracked) }
                } else {
                    Text("Reading status…").font(.caption).foregroundStyle(Theme.textSecondary).padding(10)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var diffTitle: String {
        guard let p = git.selectedPath else { return "" }
        return (git.selectedIsStaged ? "Index vs HEAD — " : "Working tree vs index — ") + p
    }

    @ViewBuilder private func group(_ title: String, _ entries: [GitStatusEntry], kind: GitChangeGroup) -> some View {
        let open = !collapsed.contains(title)
        GitGroupHeader(title: title, count: entries.count, open: open, kind: kind, paths: entries.map(\.path), git: git, workspace: workspace) {
            if open { collapsed.insert(title) } else { collapsed.remove(title) }
        }
        if open {
            ForEach(entries, id: \.self) { e in
                GitChangeRow(entry: e, kind: kind, git: git, workspace: workspace, onHistory: { showHistory(for: e.path) })
            }
        }
    }

    private func showHistory(for path: String) {
        git.historyPath = path
        section = 3
        Task { await git.loadBranchesAndHistory() }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                TextField("Message (⌘⏎ to commit on \"\(git.status?.branch ?? "HEAD")\")", text: $git.commitMessage, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...8)
                // ✨ Generate commit message — only when a Claude provider is connected (VS Code's sparkle).
                if let claude = workspace.claudePath {
                    Button { Task { await git.generateCommitMessage(claudePath: claude) } } label: {
                        Group {
                            if git.generatingMessage { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)) }
                        }
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).clickCursor()
                    .disabled(git.generatingMessage || git.isBusy)
                    .help("Generate a commit message with Claude Code")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.borderSubtle))
            // VS Code's split commit button: primary action + a chevron menu, one 28pt bar.
            HStack(spacing: 0) {
                Button { Task { await git.commit() } } label: {
                    Label(git.stagedCount > 0 ? "Commit (\(git.stagedCount))" : "Commit", systemImage: "checkmark")
                        .font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                Rectangle().fill(Theme.onAccent.opacity(0.35)).frame(width: 1, height: 16)
                Menu {
                    Button("Commit & Push") { Task { await git.commit(); if git.lastError == nil { await git.push() } } }
                } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .foregroundStyle(Theme.onAccent).frame(height: 28)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
            .opacity(git.canCommit ? 1 : 0.5).clickCursor()
            .disabled(!git.canCommit)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
        .task { await workspace.ensureProvidersLoaded() }
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
                    Image(systemName: b.isCurrent ? "checkmark.circle.fill" : "circle").foregroundStyle(b.isCurrent ? Theme.accent : .secondary)
                    Text(b.name).font(.caption)
                    if let u = b.upstream { Text("→ \(u)").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                    Text(b.head.prefix(7)).font(Theme.Typography.monoMicro).foregroundStyle(Theme.textSecondary)
                    if !b.isCurrent { Button("Switch") { Task { await git.checkout(b.name) } }.font(.caption).disabled(git.isBusy) }
                }
            }
            .listStyle(.inset)
            Text("Switching refuses when the working tree is dirty; nothing is stashed automatically.").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).padding(6)
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
                        Text(w.path).font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if w.isLocked { Text("locked").font(Theme.Typography.micro).foregroundStyle(Theme.warning) }
                    if !w.isMain { Button("Remove…") { git.worktreeRemoveRequest = w }.font(.caption).disabled(git.isBusy) }
                }
            }
            .listStyle(.inset)
            Text("Worktrees share repository data and are not a security sandbox (Bible Part 6 §14.2).").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).padding(6)
        }
    }

    private var historyView: some View {
        VStack(spacing: 0) {
            if let p = git.historyPath {
                HStack {
                    Text("History of \(p)").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { git.historyPath = nil; Task { await git.loadBranchesAndHistory() } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).clickCursor().help("Show all history")
                }
                .padding(.horizontal, 8).frame(height: 24)
                Divider()
            }
            historyList
        }
    }

    private var historyList: some View {
        List(git.history, id: \.self) { c in
            HStack(alignment: .top) {
                Text(c.shortHash).font(Theme.Typography.monoMetadata).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading) {
                    Text(c.subject).font(.caption).lineLimit(2)
                    Text("\(c.author) · \(c.date.formatted(date: .abbreviated, time: .shortened))").font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .listStyle(.inset)
    }
}

enum GitChangeGroup { case conflicted, staged, unstaged, untracked }

/// Collapsible group header ("⌄ Changes … 7") with VS Code's hover actions and context menu.
private struct GitGroupHeader: View {
    let title: String
    let count: Int
    let open: Bool
    let kind: GitChangeGroup
    let paths: [String]
    @Bindable var git: GitController
    let workspace: WorkspaceController
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary).frame(width: 14)
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                GitIconButton(symbol: "doc.on.doc", help: "Open Changed Files") { for p in paths { workspace.openFile(path: git.absolutePath(p)) } }
                switch kind {
                case .staged: GitIconButton(symbol: "minus", help: "Unstage All Changes") { Task { await git.unstage(paths) } }
                case .unstaged:
                    GitIconButton(symbol: "arrow.uturn.backward", help: "Discard All Changes") { git.discardRequest = paths }
                    GitIconButton(symbol: "plus", help: "Stage All Changes") { Task { await git.stage(paths) } }
                case .untracked: GitIconButton(symbol: "plus", help: "Stage All Changes") { Task { await git.stage(paths) } }
                case .conflicted: EmptyView()
                }
            }
            Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.accent, in: Capsule())
        }
        .padding(.leading, 4).padding(.trailing, 10).frame(height: 24)
        .background(hovering ? Theme.elevated.opacity(0.6) : .clear)
        .contentShape(Rectangle()).clickCursor()
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu {
            switch kind {
            case .staged: Button("Unstage All Changes") { Task { await git.unstage(paths) } }
            case .unstaged:
                Button("Discard All Changes") { git.discardRequest = paths }
                Button("Stage All Changes") { Task { await git.stage(paths) } }
            case .untracked: Button("Stage All Changes") { Task { await git.stage(paths) } }
            case .conflicted: EmptyView()
            }
        }
    }
}

/// One file in the changes list: icon, name + dimmed folder, status letter on the right; inline
/// actions on hover and the full VS Code context menu on right-click.
private struct GitChangeRow: View {
    let entry: GitStatusEntry
    let kind: GitChangeGroup
    @Bindable var git: GitController
    let workspace: WorkspaceController
    let onHistory: () -> Void
    @State private var hovering = false

    private var staged: Bool { kind == .staged }

    var body: some View {
        let change = staged ? entry.staged : entry.unstaged
        let letter = entry.isConflicted ? "C" : entry.isUntracked ? "U" : String(change.rawValue)
        let folder = entry.originalPath.map { "← \($0)" } ?? (entry.path as NSString).deletingLastPathComponent
        let name = (entry.path as NSString).lastPathComponent
        let icon = FileIcon.style(for: name)
        let selected = git.selectedPath == entry.path && git.selectedIsStaged == staged
        return HStack(spacing: 5) {
            Image(systemName: icon.0).font(.system(size: 12)).foregroundStyle(icon.1).frame(width: 16)
            Text(name).font(.system(size: 13)).strikethrough(change == .deleted).lineLimit(1).layoutPriority(1)
            if !folder.isEmpty { Text(folder).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle) }
            Spacer(minLength: 4)
            if hovering {
                GitIconButton(symbol: "doc", help: "Open File") { openFile() }
                switch kind {
                case .staged: GitIconButton(symbol: "minus", help: "Unstage Changes") { Task { await git.unstage([entry.path]) } }
                case .unstaged:
                    GitIconButton(symbol: "arrow.uturn.backward", help: "Discard Changes") { git.discardRequest = [entry.path] }
                    GitIconButton(symbol: "plus", help: "Stage Changes") { Task { await git.stage([entry.path]) } }
                case .untracked: GitIconButton(symbol: "plus", help: "Stage Changes") { Task { await git.stage([entry.path]) } }
                case .conflicted: EmptyView()
                }
            }
            Text(letter).font(.system(size: 13, weight: .semibold)).foregroundStyle(color(letter)).frame(width: 14)
        }
        .padding(.leading, 22).padding(.trailing, 10).frame(height: 22)
        .background(selected ? Theme.accent.opacity(0.18) : (hovering ? Theme.elevated.opacity(0.6) : .clear))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.borderSubtle).frame(width: 1).padding(.leading, 10) }   // tree guide
        .contentShape(Rectangle()).clickCursor()
        .onTapGesture { openChanges() }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityLabel("\(letter) \(entry.path)")
    }

    @ViewBuilder private var menu: some View {
        Button("Open Changes") { openChanges() }
        Button("Open File") { openFile() }
        Button("Open File (HEAD)") { Task { if let p = await git.headCopy(of: entry.path) { workspace.openFile(path: p) } } }
            .disabled(entry.isUntracked || entry.staged == .added)
        Divider()
        switch kind {
        case .staged: Button("Unstage Changes") { Task { await git.unstage([entry.path]) } }
        case .unstaged:
            Button("Discard Changes") { git.discardRequest = [entry.path] }
            Button("Stage Changes") { Task { await git.stage([entry.path]) } }
        case .untracked: Button("Stage Changes") { Task { await git.stage([entry.path]) } }
        case .conflicted: EmptyView()
        }
        Button("Add to .gitignore") { Task { await git.addToGitignore(entry.path) } }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: git.absolutePath(entry.path))]) }
        Button("Reveal in Explorer View") { workspace.revealInExplorer(git.absolutePath(entry.path)) }
        Divider()
        Button("View File History") { onHistory() }.disabled(entry.isUntracked)
    }

    private func openChanges() { Task { await git.select(path: entry.path, staged: staged) } }
    private func openFile() { workspace.openFile(path: git.absolutePath(entry.path)) }

    private func color(_ letter: String) -> Color {
        switch letter { case "A", "U": .green; case "D": .red; case "C": .orange; default: .yellow }
    }
}

private struct GitIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).frame(width: 18, height: 18).contentShape(Rectangle()) }
            .buttonStyle(.plain).clickCursor().help(help)
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
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if truncated { Text("truncated to \(GitController.diffLineLimit) lines").font(.caption).foregroundStyle(Theme.warning) }
                if let onClose { Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).clickCursor().help("Close diff") }
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
                                Text(hunk.header).font(Theme.Typography.monoDetail).foregroundStyle(Theme.info)
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
                                .font(Theme.Typography.monoDetail)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(line.kind == .context ? Theme.textPrimary : line.kind == .added ? Theme.success : Theme.error)
                                .background(line.kind == .context ? Color.clear : (line.kind == .added ? Theme.success : Theme.error).opacity(0.12))
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
                        .font(Theme.Typography.micro).foregroundStyle(Theme.textSecondary).padding(.top, 2)
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
                Text(t.isEmpty ? "(empty)" : t).font(Theme.Typography.monoDetail).textSelection(.enabled)
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
