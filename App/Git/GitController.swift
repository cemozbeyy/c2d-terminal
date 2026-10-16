import C2DCore
import Foundation
import Observation

/// Git state for one workspace. Git itself is the source of truth; this object only holds the
/// last observed snapshot and refreshes after its own operations and on filesystem hints
/// (Bible Part 6 §3, §21). Operations are serialized through `isBusy`.
@MainActor
@Observable
final class GitController {
    let projectPath: String
    private(set) var repository: GitRepository?
    private(set) var discoveryError: String?
    private(set) var status: GitStatus?
    private(set) var branches: [GitBranch] = []
    private(set) var history: [GitCommit] = []
    private(set) var worktrees: [GitWorktree] = []
    private(set) var isBusy = false
    private(set) var lastRefreshedAt: Date?
    var lastError: String?

    var selectedPath: String?
    var selectedIsStaged = false
    private(set) var selectedDiff: [FileDiff] = []
    private(set) var selectedDiffTruncated = false
    /// Set when the selected path is conflicted; drives the conflict-resolution view instead of the diff.
    private(set) var selectedConflictKind: ConflictKind?
    private(set) var selectedConflictStages: ConflictStages?
    /// A multi-step operation (merge/rebase/cherry-pick/revert) is mid-flight, so an abort is offered.
    private(set) var operation: MergeOperation?
    /// Pending abort confirmation (high-risk: resets the whole working tree).
    var abortRequest: MergeOperation?
    var commitMessage = ""
    private(set) var lastCommitHash: String?
    /// Path waiting for discard confirmation (destructive, Bible Part 6 §9).
    var discardRequest: String?
    var worktreeRemoveRequest: GitWorktree?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    static let diffLineLimit = 5000

    @ObservationIgnored private let diagnostics: DiagnosticsRecorder?

    init(projectPath: String, diagnostics: DiagnosticsRecorder? = nil) {
        self.projectPath = projectPath
        self.diagnostics = diagnostics
        Task { await discover() }
    }

    var isAvailable: Bool { repository != nil }

    var branchLabel: String {
        guard let s = status else { return repository == nil ? "no git" : "…" }
        if s.isUnborn { return "no commits yet" }
        if s.isDetached { return "detached HEAD" }
        var label = s.branch ?? "?"
        if s.ahead > 0 { label += " ↑\(s.ahead)" }
        if s.behind > 0 { label += " ↓\(s.behind)" }
        return label
    }

    /// Path → one-letter badge for the explorer (M/A/D/R/U/C). Staged and unstaged states collapse
    /// to one badge here; the Git panel keeps them separate.
    var badges: [String: String] {
        guard let s = status else { return [:] }
        var out: [String: String] = [:]
        for e in s.entries {
            let full = (projectPath as NSString).appendingPathComponent(e.path)
            if e.isConflicted { out[full] = "C" }
            else if e.isUntracked { out[full] = "U" }
            else if e.staged == .added || e.unstaged == .added { out[full] = "A" }
            else if e.staged == .deleted || e.unstaged == .deleted { out[full] = "D" }
            else if e.staged == .renamed || e.unstaged == .renamed { out[full] = "R" }
            else { out[full] = "M" }
        }
        return out
    }

    // MARK: Discovery and refresh

    func discover() async {
        do {
            repository = try await GitRepository.discover(path: projectPath)
            discoveryError = nil
            await refresh()
        } catch {
            repository = nil
            discoveryError = describe(error)
        }
    }

    /// Debounced refresh for watcher hints; `.git` churn during our own commands is coalesced.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let repo = repository else { return }
        do {
            let s = try await repo.status()
            status = s
            operation = try? await repo.operationInProgress()
            lastRefreshedAt = Date()
            await reloadSelection()
        } catch {
            lastError = describe(error)
        }
    }

    /// Loads whatever the selected path needs: a conflict view when it is conflicted, otherwise its
    /// diff. Keyed on the live entry's conflicted state, so a file flipping resolved clears the view.
    private func reloadSelection() async {
        guard let repo = repository, let p = selectedPath, let entry = status?.entries.first(where: { $0.path == p }) else {
            if selectedPath != nil, status?.entries.contains(where: { $0.path == selectedPath }) == false { selectedPath = nil }
            selectedDiff = []; selectedConflictKind = nil; selectedConflictStages = nil
            return
        }
        if entry.isConflicted {
            selectedConflictKind = entry.conflictKind
            selectedDiff = []; selectedDiffTruncated = false
            do { selectedConflictStages = try await repo.conflictStages(path: p) }
            catch { lastError = describe(error); selectedConflictStages = nil }
        } else {
            selectedConflictKind = nil; selectedConflictStages = nil
            await loadDiff(path: p, staged: selectedIsStaged)
        }
    }

    func loadBranchesAndHistory() async {
        guard let repo = repository else { return }
        do {
            branches = try await repo.branches()
            history = try await repo.log(limit: 50)
        } catch { lastError = describe(error) }
    }

    func loadWorktrees() async {
        guard let repo = repository else { return }
        do { worktrees = try await repo.worktrees() } catch { lastError = describe(error) }
    }

    // MARK: Diff

    func select(path: String, staged: Bool) async {
        selectedPath = path
        selectedIsStaged = staged
        await reloadSelection()
    }

    var selectedIsConflicted: Bool { selectedConflictKind != nil }

    func resolveConflict(_ path: String, using side: ConflictSide) async {
        await perform("Resolve conflict") { try await $0.resolveConflict(path: path, using: side) }
    }

    func markResolved(_ path: String) async {
        await perform("Mark resolved") { try await $0.markResolved(path: path) }
    }

    func abort(_ op: MergeOperation) async {
        abortRequest = nil
        await perform("Abort \(op.rawValue)") { try await $0.abortOperation(op) }
        await loadBranchesAndHistory()
    }

    private func loadDiff(path: String, staged: Bool) async {
        guard let repo = repository else { return }
        do {
            let text = try await repo.diff(path: path, staged: staged)
            var files = GitRepository.parseUnifiedDiff(text)
            let total = files.reduce(0) { $0 + $1.hunks.reduce(0) { $0 + $1.lines.count } }
            selectedDiffTruncated = total > Self.diffLineLimit
            if selectedDiffTruncated {
                // Keep the first hunks only and say so; never pretend the diff is complete (Part 6 §6).
                var budget = Self.diffLineLimit
                files = files.map { f in
                    var hunks: [DiffHunk] = []
                    for h in f.hunks where budget > 0 { hunks.append(h); budget -= h.lines.count }
                    return FileDiff(oldPath: f.oldPath, newPath: f.newPath, isBinary: f.isBinary, hunks: hunks)
                }
            }
            selectedDiff = files
        } catch { lastError = describe(error); selectedDiff = [] }
    }

    // MARK: Operations (each refreshes afterwards; Git state is re-read, never assumed)

    private func perform(_ what: String, _ body: (GitRepository) async throws -> Void) async {
        guard let repo = repository, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await body(repo)
            lastError = nil
        } catch {
            lastError = "\(what): \(describe(error))"
            if let diagnostics { Task { await diagnostics.record(module: "git", operation: what, error: error) } }
        }
        await refresh()
    }

    /// `nil` when the selected file can't do per-hunk staging: binary, or a whole new/deleted file
    /// (one hunk whose reverse is a whole-file unstage), or conflicted. Otherwise the button label.
    var hunkActionTitle: String? {
        guard selectedPath != nil, let f = selectedDiff.first, f.oldPath != nil, f.newPath != nil, !f.isBinary else { return nil }
        if let e = status?.entries.first(where: { $0.path == selectedPath }), e.isConflicted { return nil }
        return selectedIsStaged ? "Unstage hunk" : "Stage hunk"
    }

    func stageHunk(index: Int, hunk: DiffHunk) async {
        guard let p = selectedPath else { return }
        let staged = selectedIsStaged
        await perform(staged ? "Unstage hunk" : "Stage hunk") { repo in
            if staged { try await repo.unstageHunk(path: p, index: index, expected: hunk) }
            else { try await repo.stageHunk(path: p, index: index, expected: hunk) }
        }
    }

    func stage(_ paths: [String]) async { await perform("Stage") { try await $0.stage(paths: paths) } }
    func unstage(_ paths: [String]) async { await perform("Unstage") { try await $0.unstage(paths: paths) } }
    func stageAll() async { await perform("Stage all") { try await $0.stageAll() } }

    func discard(_ path: String) async {
        discardRequest = nil
        await perform("Discard") { try await $0.discardChanges(paths: [path]) }
    }

    var stagedCount: Int { status?.entries.filter(\.hasStagedChange).count ?? 0 }
    var canCommit: Bool { stagedCount > 0 && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy }

    func commit() async {
        let message = commitMessage
        await perform("Commit") { repo in
            let hash = try await repo.commit(message: message)
            self.lastCommitHash = hash
            self.commitMessage = ""
        }
        await loadBranchesAndHistory()
    }

    func checkout(_ branch: String) async {
        await perform("Checkout \(branch)") { try await $0.checkout(branch: branch) }
        await loadBranchesAndHistory()
    }

    func createBranch(_ name: String) async {
        await perform("Create branch") { try await $0.createBranch(name, checkout: true) }
        await loadBranchesAndHistory()
    }

    func addWorktree(path: String, branch: String, createBranch: Bool) async {
        await perform("Add worktree") { try await $0.addWorktree(path: path, branch: branch, createBranch: createBranch) }
        await loadWorktrees()
    }

    func removeWorktree(_ wt: GitWorktree) async {
        worktreeRemoveRequest = nil
        await perform("Remove worktree") { try await $0.removeWorktree(path: wt.path, force: false) }
        await loadWorktrees()
    }

    func describe(_ error: Error) -> String {
        switch error as? GitError {
        case .gitUnavailable: "git executable not found"
        case .notARepository: "not a Git repository"
        case .commandFailed(let code, let stderr): "git exited \(code): \(stderr.isEmpty ? "no details" : stderr)"
        case .dirtyWorkingTree: "working tree has uncommitted changes; commit, stash or discard them first (nothing was changed)"
        case .nothingToCommit: "nothing is staged"
        case .emptyMessage: "commit message is empty"
        case .identityNotConfigured: "git user.name / user.email are not configured"
        case .invalidPath: "invalid path"
        case .staleDiff: "this diff changed since it was shown; nothing was staged — refresh and retry"
        case .patchDoesNotApply(let stderr): "the hunk no longer applies to the index (nothing changed): \(stderr.isEmpty ? "refresh and retry" : stderr)"
        case .conflictMarkersRemain(let lines): "conflict markers are still present (lines \(lines.prefix(5).map(String.init).joined(separator: ", "))\(lines.count > 5 ? "…" : "")); remove them before marking resolved"
        case .notConflicted: "this file is no longer in a conflicted state"
        case .none: "\(error)"
        }
    }
}
