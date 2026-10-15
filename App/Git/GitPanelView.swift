import C2DCore
import SwiftUI

struct GitPanelView: View {
    @Bindable var git: GitController
    @State private var section = 0
    @State private var newBranch = ""
    @State private var newWorktreePath = ""
    @State private var newWorktreeBranch = ""
    @State private var newWorktreeCreates = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                Text(git.branchLabel).font(.caption).bold().lineLimit(1)
                if git.isBusy { ProgressView().controlSize(.mini) }
                Spacer()
                Picker("", selection: $section) {
                    Text("Changes").tag(0); Text("Branches").tag(1); Text("Worktrees").tag(2); Text("History").tag(3)
                }
                .pickerStyle(.segmented).controlSize(.small).frame(maxWidth: 300)
                Button { Task { await git.refresh(); await git.loadBranchesAndHistory(); await git.loadWorktrees() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh from git")
            }
            .padding(.horizontal, 8).frame(height: 26)
            Divider()
            if git.repository == nil {
                VStack(spacing: 6) {
                    Text(git.discoveryError ?? "This folder is not inside a Git repository.").foregroundStyle(.secondary)
                    Text("Run `git init` in the terminal to start one; C2D never initializes a repository silently.").font(.caption).foregroundStyle(.secondary)
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
                HStack { Text(err).font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled); Spacer(); Button("Dismiss") { git.lastError = nil }.font(.caption) }.padding(6)
            }
        }
        .alert("Discard changes?", isPresented: Binding(get: { git.discardRequest != nil }, set: { if !$0 { git.discardRequest = nil } })) {
            Button("Discard", role: .destructive) { if let p = git.discardRequest { Task { await git.discard(p) } } }
            Button("Cancel", role: .cancel) { git.discardRequest = nil }
        } message: { Text("Unstaged modifications to \(git.discardRequest ?? "") are replaced with the index version. This cannot be undone.") }
        .alert("Remove worktree?", isPresented: Binding(get: { git.worktreeRemoveRequest != nil }, set: { if !$0 { git.worktreeRemoveRequest = nil } })) {
            Button("Remove", role: .destructive) { if let w = git.worktreeRemoveRequest { Task { await git.removeWorktree(w) } } }
            Button("Cancel", role: .cancel) { git.worktreeRemoveRequest = nil }
        } message: { Text("\(git.worktreeRemoveRequest?.path ?? "") is removed from disk and unregistered. The branch is kept. Git refuses if the worktree has uncommitted changes.") }
    }

    // MARK: Changes

    private var changes: some View {
        VSplitView {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let s = git.status {
                            if s.isClean { Text("Working tree clean").font(.caption).foregroundStyle(.secondary).padding(8) }
                            let conflicted = s.entries.filter(\.isConflicted)
                            let staged = s.entries.filter(\.hasStagedChange)
                            let unstaged = s.entries.filter(\.hasUnstagedChange)
                            let untracked = s.entries.filter(\.isUntracked)
                            if !conflicted.isEmpty { group("Conflicts", conflicted, staged: false, showStage: false) }
                            if !staged.isEmpty { group("Staged Changes (\(staged.count))", staged, staged: true, showStage: true) }
                            if !unstaged.isEmpty { group("Changes (\(unstaged.count))", unstaged, staged: false, showStage: true) }
                            if !untracked.isEmpty { group("Untracked (\(untracked.count))", untracked, staged: false, showStage: true) }
                        } else {
                            Text("Reading status…").font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                Divider()
                composer
            }
            .frame(minHeight: 160)
            DiffView(files: git.selectedDiff, title: diffTitle, truncated: git.selectedDiffTruncated)
                .frame(minHeight: 100)
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
                Text(title).font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                if showStage && !staged && entries.count > 1 {
                    Button("Stage all") { Task { await git.stageAll() } }.font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
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
                if let o = e.originalPath { Text("← \(o)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                else { Text((e.path as NSString).deletingLastPathComponent).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if showStage {
                if staged {
                    Button("Unstage") { Task { await git.unstage([e.path]) } }.font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                } else {
                    if !e.isUntracked { Button("Discard…") { git.discardRequest = e.path }.font(.caption).buttonStyle(.plain).foregroundStyle(.red) }
                    Button("Stage") { Task { await git.stage([e.path]) } }.font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(git.selectedPath == e.path && git.selectedIsStaged == staged ? Color.accentColor.opacity(0.18) : .clear)
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
                Text("\(git.stagedCount) staged file(s)").font(.caption).foregroundStyle(.secondary)
                if let h = git.lastCommitHash { Text("last commit \(h.prefix(7))").font(.caption).foregroundStyle(.secondary) }
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
                    if let u = b.upstream { Text("→ \(u)").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Spacer()
                    Text(b.head.prefix(7)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    if !b.isCurrent { Button("Switch") { Task { await git.checkout(b.name) } }.font(.caption).disabled(git.isBusy) }
                }
            }
            .listStyle(.inset)
            Text("Switching refuses when the working tree is dirty; nothing is stashed automatically.").font(.system(size: 9)).foregroundStyle(.secondary).padding(6)
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
                    Image(systemName: w.isMain ? "house" : "arrow.triangle.branch").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(w.branch ?? w.head?.prefix(7).description ?? "?").font(.caption).bold()
                        Text(w.path).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if w.isLocked { Text("locked").font(.system(size: 9)).foregroundStyle(.orange) }
                    if !w.isMain { Button("Remove…") { git.worktreeRemoveRequest = w }.font(.caption).disabled(git.isBusy) }
                }
            }
            .listStyle(.inset)
            Text("Worktrees share repository data and are not a security sandbox (Bible Part 6 §14.2).").font(.system(size: 9)).foregroundStyle(.secondary).padding(6)
        }
    }

    private var historyView: some View {
        List(git.history, id: \.self) { c in
            HStack(alignment: .top) {
                Text(c.shortHash).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(c.subject).font(.caption).lineLimit(2)
                    Text("\(c.author) · \(c.date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 9)).foregroundStyle(.secondary)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if truncated { Text("truncated to \(GitController.diffLineLimit) lines").font(.caption).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 8).frame(height: 22)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        if file.isBinary { Text("Binary file; no textual diff.").font(.caption).foregroundStyle(.secondary).padding(8) }
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                            Text(hunk.header).font(.system(size: 11, design: .monospaced)).foregroundStyle(.blue).padding(.horizontal, 8).padding(.vertical, 2)
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
                    if files.isEmpty { Text("No diff").font(.caption).foregroundStyle(.secondary).padding(8) }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.kind { case .added: "+"; case .removed: "-"; case .context: " " }
    }
}
