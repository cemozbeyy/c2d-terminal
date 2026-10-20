import Foundation

public enum GitError: Error, Equatable, Sendable {
    case gitUnavailable
    case notARepository
    case commandFailed(code: Int32, stderr: String)
    case dirtyWorkingTree
    case nothingToCommit
    case emptyMessage
    case identityNotConfigured
    case invalidPath
    /// The selected hunk no longer matches the index; `git apply` refused it (nothing changed).
    case patchDoesNotApply(stderr: String)
    /// The diff changed between display and apply (edit or external index change); nothing staged.
    case staleDiff
    /// Mark-resolved refused: the working file still has conflict markers on these 1-based lines.
    case conflictMarkersRemain(lines: [Int])
    /// The path is not in a conflicted state (nothing to resolve).
    case notConflicted
    // Remote synchronization (Bible Part 6 §10).
    case authenticationRequired
    case networkUnavailable
    case pushRejected(stderr: String)
    case noUpstreamConfigured
    /// The operation was terminated (e.g. the 30s timeout); the remote state is unknown, not failed.
    case operationTimedOut
}

/// Which merge-conflict shape a path is in, from `git status --porcelain=v2` `u` XY codes.
public enum ConflictKind: String, Sendable, Hashable {
    case bothModified   // UU
    case bothAdded      // AA
    case bothDeleted    // DD
    case addedByUs      // AU
    case addedByThem    // UA
    case deletedByUs    // UD
    case deletedByThem  // DU
    case unknown

    static func from(xy: String) -> ConflictKind {
        switch xy {
        case "UU": .bothModified; case "AA": .bothAdded; case "DD": .bothDeleted
        // git short codes are <us><them>: UD = we modified / they deleted; DU = we deleted / they modified.
        case "AU": .addedByUs; case "UA": .addedByThem; case "UD": .deletedByThem; case "DU": .deletedByUs
        default: .unknown
        }
    }

    /// Which merge stages carry content for this shape (stage 1 = base, 2 = ours, 3 = theirs).
    public var hasBase: Bool { self == .bothModified }
    public var hasOurs: Bool { [.bothModified, .bothAdded, .addedByUs, .deletedByThem].contains(self) }
    public var hasTheirs: Bool { [.bothModified, .bothAdded, .addedByThem, .deletedByUs].contains(self) }
}

public enum ConflictSide: Sendable { case ours, theirs }

/// One side of a conflict as it exists in the index.
public enum MergeStageContent: Sendable, Hashable { case absent, binary, text(String) }

public struct ConflictStages: Sendable, Hashable {
    public let base: MergeStageContent
    public let ours: MergeStageContent
    public let theirs: MergeStageContent
}

public enum MergeOperation: String, Sendable, Hashable { case merge, rebase, cherryPick, revert }

/// One line of `git status --porcelain=v2`. Index and worktree states are kept apart (Bible Part 6 §3).
public struct GitStatusEntry: Hashable, Sendable {
    public enum Change: Character, Sendable { case unmodified = ".", modified = "M", typeChanged = "T", added = "A", deleted = "D", renamed = "R", copied = "C", unmerged = "U" }
    public let path: String
    public let originalPath: String?
    public let staged: Change
    public let unstaged: Change
    public let isUntracked: Bool
    public let isConflicted: Bool
    /// Conflict shape when `isConflicted`; `nil` otherwise.
    public var conflictKind: ConflictKind? = nil
    public var hasStagedChange: Bool { staged != .unmodified && !isUntracked && !isConflicted }
    public var hasUnstagedChange: Bool { unstaged != .unmodified && !isUntracked && !isConflicted }
}

public struct GitStatus: Hashable, Sendable {
    /// `nil` when HEAD is detached.
    public let branch: String?
    public let isDetached: Bool
    /// True before the first commit.
    public let isUnborn: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let entries: [GitStatusEntry]
    public var isClean: Bool { entries.isEmpty }
}

public struct GitBranch: Hashable, Sendable {
    public let name: String
    public let isCurrent: Bool
    public let upstream: String?
    public let head: String
    /// Tip commit, for VS Code-style branch pickers.
    public var lastCommitDate: Date? = nil
    public var lastCommitAuthor = ""
    public var lastCommitSubject = ""
}

public struct GitCommit: Hashable, Sendable {
    public let hash: String
    public let shortHash: String
    public let author: String
    public let date: Date
    public let subject: String
}

public struct GitWorktree: Hashable, Sendable {
    public let path: String
    public let head: String?
    public let branch: String?
    public let isMain: Bool
    public let isLocked: Bool
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case context, added, removed }
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
}

public struct DiffHunk: Hashable, Sendable {
    public let header: String
    public let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    public let lines: [DiffLine]
}

public struct FileDiff: Hashable, Sendable {
    public let oldPath: String?
    public let newPath: String?
    public let isBinary: Bool
    public let hunks: [DiffHunk]

    public init(oldPath: String?, newPath: String?, isBinary: Bool, hunks: [DiffHunk]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.isBinary = isBinary
        self.hunks = hunks
    }
}

/// Thin, uncached wrapper around the `git` executable for one repository. Git owns the truth;
/// every call asks it again (Bible Part 6 §21). Arguments are always arrays, never shell text.
public actor GitRepository {
    public nonisolated let root: String
    public nonisolated let isLinkedWorktree: Bool
    nonisolated let gitPath: String
    /// Test hook: extra environment for every git invocation (e.g. `GIT_CONFIG_GLOBAL=/dev/null`).
    var extraEnvironment: [String: String] = [:]
    static let timeout: TimeInterval = 30

    init(root: String, isLinkedWorktree: Bool, gitPath: String) {
        self.root = root
        self.isLinkedWorktree = isLinkedWorktree
        self.gitPath = gitPath
    }

    func setExtraEnvironment(_ env: [String: String]) { extraEnvironment = env }

    // MARK: Discovery

    /// Symlink-free absolute path, so `/var/...` and `/private/var/...` compare equal.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func locateGit() -> String? {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/git" } + ["/usr/bin/git"]
        return candidates.first { access($0, X_OK) == 0 }
    }

    /// `nil` when `path` is not inside a work tree. Resolves subdirectories to the root.
    public static func discover(path: String) async throws -> GitRepository? {
        guard let git = locateGit() else { throw GitError.gitUnavailable }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { throw GitError.invalidPath }
        let probe = GitRepository(root: path, isLinkedWorktree: false, gitPath: git)
        let result = try await probe.run(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"], allowFailure: true)
        guard result.code == 0 else {
            if result.stderr.contains("not a git repository") { return nil }
            throw GitError.commandFailed(code: result.code, stderr: result.stderr)
        }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return nil }
        // git prints resolved paths; relative ones are relative to the cwd it ran in (`path`).
        let top = Self.canonical(lines[0])
        let gitDir = Self.canonical(lines[1])
        let common = Self.canonical(URL(fileURLWithPath: lines[2], relativeTo: URL(fileURLWithPath: path)).path)
        return GitRepository(root: top, isLinkedWorktree: gitDir != common, gitPath: git)
    }

    // MARK: Status

    public func status() async throws -> GitStatus {
        let out = try await runData(["status", "--porcelain=v2", "--branch", "-z"])
        return Self.parseStatus(out)
    }

    static func parseStatus(_ data: Data) -> GitStatus {
        var fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var branch: String?, detached = false, unborn = false, upstream: String?, ahead = 0, behind = 0
        var entries: [GitStatusEntry] = []
        var i = 0
        func change(_ c: Character) -> GitStatusEntry.Change { GitStatusEntry.Change(rawValue: c) ?? .unmodified }
        while i < fields.count {
            let f = fields[i]; i += 1
            if f.hasPrefix("# branch.head ") {
                let v = String(f.dropFirst("# branch.head ".count))
                if v == "(detached)" { detached = true } else { branch = v }
            } else if f.hasPrefix("# branch.oid ") {
                unborn = f.hasSuffix("(initial)")
            } else if f.hasPrefix("# branch.upstream ") {
                upstream = String(f.dropFirst("# branch.upstream ".count))
            } else if f.hasPrefix("# branch.ab ") {
                let parts = f.dropFirst("# branch.ab ".count).split(separator: " ")
                ahead = Int(parts.first?.dropFirst() ?? "") ?? 0
                behind = Int(parts.last?.dropFirst() ?? "") ?? 0
            } else if f.hasPrefix("1 ") || f.hasPrefix("2 ") || f.hasPrefix("u ") {
                let parts = f.split(separator: " ", omittingEmptySubsequences: false)
                let xy = Array(parts[1])
                let renamed = f.hasPrefix("2 ")
                let pathIndex = f.hasPrefix("1 ") ? 8 : (renamed ? 9 : 10)
                let path = parts[pathIndex...].joined(separator: " ")
                var original: String?
                if renamed, i < fields.count { original = fields[i]; i += 1 }
                let conflicted = f.hasPrefix("u ")
                entries.append(GitStatusEntry(path: path, originalPath: original,
                                              staged: conflicted ? .unmerged : change(xy[0]),
                                              unstaged: conflicted ? .unmerged : change(xy[1]),
                                              isUntracked: false, isConflicted: conflicted,
                                              conflictKind: conflicted ? ConflictKind.from(xy: String(xy)) : nil))
            } else if f.hasPrefix("? ") {
                entries.append(GitStatusEntry(path: String(f.dropFirst(2)), originalPath: nil, staged: .unmodified, unstaged: .unmodified, isUntracked: true, isConflicted: false))
            }
            // "! " ignored entries are not requested; "#" other headers skipped.
        }
        fields.removeAll()
        return GitStatus(branch: branch, isDetached: detached, isUnborn: unborn, upstream: upstream, ahead: ahead, behind: behind, entries: entries)
    }

    // MARK: Diff

    /// Unified diff for one path. Untracked files diff against nothing so they show as additions.
    public func diff(path: String, staged: Bool) async throws -> String {
        let tracked = try await run(["ls-files", "--error-unmatch", "--", path], allowFailure: true).code == 0
        if !tracked && !staged {
            let r = try await run(["diff", "--no-index", "--", "/dev/null", path], allowFailure: true)
            guard r.code == 0 || r.code == 1 else { throw GitError.commandFailed(code: r.code, stderr: r.stderr) }
            return r.stdout
        }
        return try await run(staged ? ["diff", "--cached", "--", path] : ["diff", "--", path]).stdout
    }

    public static func parseUnifiedDiff(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var oldPath: String?, newPath: String?, binary = false
        var hunks: [DiffHunk] = []
        var current: (header: String, os: Int, oc: Int, ns: Int, nc: Int, lines: [DiffLine])?
        var oldLine = 0, newLine = 0
        func flushHunk() {
            if let c = current { hunks.append(DiffHunk(header: c.header, oldStart: c.os, oldCount: c.oc, newStart: c.ns, newCount: c.nc, lines: c.lines)) }
            current = nil
        }
        func flushFile() {
            flushHunk()
            if oldPath != nil || newPath != nil || binary { files.append(FileDiff(oldPath: oldPath, newPath: newPath, isBinary: binary, hunks: hunks)) }
            oldPath = nil; newPath = nil; binary = false; hunks = []
        }
        func strip(_ p: Substring) -> String? {
            let s = String(p)
            if s == "/dev/null" { return nil }
            return s.hasPrefix("a/") || s.hasPrefix("b/") ? String(s.dropFirst(2)) : s
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") { flushFile(); continue }
            if line.hasPrefix("--- ") { flushHunk(); oldPath = strip(line.dropFirst(4)); continue }
            if line.hasPrefix("+++ ") { newPath = strip(line.dropFirst(4)); continue }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { binary = true; continue }
            if line.hasPrefix("@@") {
                flushHunk()
                let range = line.split(separator: "@@", omittingEmptySubsequences: true).first.map(String.init) ?? ""
                func parse(_ s: Substring) -> (Int, Int) {
                    let p = s.dropFirst().split(separator: ",")
                    return (Int(p.first ?? "0") ?? 0, p.count > 1 ? Int(p[1]) ?? 0 : 1)
                }
                let parts = range.split(separator: " ")
                let o = parts.count > 0 ? parse(parts[0]) : (0, 0)
                let n = parts.count > 1 ? parse(parts[1]) : (0, 0)
                current = (line, o.0, o.1, n.0, n.1, [])
                oldLine = o.0; newLine = n.0
                continue
            }
            guard current != nil, let first = line.first else { continue }
            switch first {
            case "+": current!.lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldLine: nil, newLine: newLine)); newLine += 1
            case "-": current!.lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldLine: oldLine, newLine: nil)); oldLine += 1
            case " ": current!.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldLine: oldLine, newLine: newLine)); oldLine += 1; newLine += 1
            case "\\": break   // "\ No newline at end of file"
            default: break
            }
        }
        flushFile()
        return files
    }

    // MARK: Partial (hunk) staging

    /// A minimal patch containing only hunk `index` of a single-file unified diff: the file header
    /// (everything before the first `@@`) plus that one hunk. Pure text slicing on `@@` boundaries,
    /// so `\ No newline at end of file` markers and `-`-prefixed line content survive intact.
    static func extractHunkPatch(from diffText: String, at index: Int) -> String? {
        var lines = diffText.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // trailing-newline artifact of the split
        let hunkStarts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        guard index >= 0, index < hunkStarts.count, let first = hunkStarts.first, first > 0 else { return nil }
        let start = hunkStarts[index]
        let end = index + 1 < hunkStarts.count ? hunkStarts[index + 1] : lines.count
        let patch = Array(lines[0..<first]) + Array(lines[start..<end])
        return patch.joined(separator: "\n") + "\n"   // git apply requires a trailing newline
    }

    /// Stages exactly hunk `index` of `path` without touching other changes (Bible Part 6 §7, §21).
    public func stageHunk(path: String, index: Int, expected: DiffHunk) async throws {
        try await applyHunk(path: path, index: index, expected: expected, staged: false, reverse: false)
    }

    /// Unstages exactly hunk `index` of `path`'s staged diff by reverse-applying it to the index.
    public func unstageHunk(path: String, index: Int, expected: DiffHunk) async throws {
        try await applyHunk(path: path, index: index, expected: expected, staged: true, reverse: true)
    }

    private func applyHunk(path: String, index: Int, expected: DiffHunk, staged: Bool, reverse: Bool) async throws {
        // Re-read the diff now; never trust the UI's copy. If the hunk differs (edited in place,
        // external index change, reordered), refuse rather than stage the wrong text.
        let fresh = try await diff(path: path, staged: staged)
        let files = Self.parseUnifiedDiff(fresh)
        guard let file = files.first, index < file.hunks.count, file.hunks[index] == expected,
              let patch = Self.extractHunkPatch(from: fresh, at: index) else { throw GitError.staleDiff }
        var args = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { args.append("--reverse") }
        args.append("-")
        // ponytail: a small window remains between this read and apply; `isBusy` serializes in-app
        // ops and `apply --cached` re-validates against the index, so a concurrent external change
        // surfaces as patchDoesNotApply rather than a silent wrong stage.
        let r = try await run(args, allowFailure: true, input: Data(patch.utf8))
        guard r.code == 0 else {
            if r.stderr.contains("does not apply") || r.stderr.contains("does not match index") || r.stderr.contains("patch failed") {
                throw GitError.patchDoesNotApply(stderr: r.stderr)
            }
            throw GitError.commandFailed(code: r.code, stderr: r.stderr)
        }
    }

    // MARK: Conflicts (Bible Part 6 §9 "Resolving or replacing conflicted files")

    /// The three merge stages of a conflicted path, read raw from the index so textconv/smudge
    /// filters never run and binary content is detected rather than corrupted into UTF-8.
    public func conflictStages(path: String) async throws -> ConflictStages {
        func stage(_ n: Int) async throws -> MergeStageContent {
            let r = try await executeRaw(["cat-file", "blob", ":\(n):\(path)"])
            guard r.code == 0 else { return .absent }
            if r.stdout.prefix(8192).contains(0) { return .binary }
            return .text(String(decoding: r.stdout, as: UTF8.self))
        }
        return try await ConflictStages(base: stage(1), ours: stage(2), theirs: stage(3))
    }

    /// Pure action table: the git commands that resolve a conflict of `kind` by keeping `side`.
    /// No fallback branching — each shape maps to exactly one command sequence (unit-testable).
    public static func resolutionCommands(kind: ConflictKind, side: ConflictSide, path: String) -> [[String]] {
        let keep: [[String]] = [["checkout", side == .ours ? "--ours" : "--theirs", "--", path], ["add", "--", path]]
        let remove: [[String]] = [["rm", "--", path]]
        switch (kind, side) {
        case (.bothModified, _), (.bothAdded, _): return keep
        case (.deletedByUs, .ours), (.addedByThem, .ours): return remove      // our side has no content
        case (.deletedByUs, .theirs), (.addedByThem, .theirs): return keep
        case (.deletedByThem, .theirs), (.addedByUs, .theirs): return remove  // their side has no content
        case (.deletedByThem, .ours), (.addedByUs, .ours): return keep
        case (.bothDeleted, _): return remove
        case (.unknown, _): return keep   // best effort; checkout fails loudly if the side is absent
        }
    }

    /// Resolves one conflicted path by keeping `side`. Path-scoped, so unrelated changes are untouched.
    public func resolveConflict(path: String, using side: ConflictSide) async throws {
        guard let kind = try await conflictKind(of: path) else { throw GitError.notConflicted }
        for cmd in Self.resolutionCommands(kind: kind, side: side, path: path) { _ = try await run(cmd) }
    }

    /// Marks a hand-edited conflicted file resolved by staging it — but refuses while conflict markers
    /// remain, so a half-merged file is never staged silently. `=======` is matched exactly to avoid
    /// eating unrelated content; a Markdown setext rule is an accepted false positive (documented).
    public func markResolved(path: String) async throws {
        guard try await conflictKind(of: path) != nil else { throw GitError.notConflicted }
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            var bad: [Int] = []
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.hasPrefix("<<<<<<< ") || line.hasPrefix(">>>>>>> ") || line.hasPrefix("||||||| ") || line == "=======" { bad.append(i + 1) }
            }
            if !bad.isEmpty { throw GitError.conflictMarkersRemain(lines: bad) }
        }
        _ = try await run(["add", "--", path])
    }

    /// The conflict shape of `path` from live status, or `nil` when it is not conflicted.
    private func conflictKind(of path: String) async throws -> ConflictKind? {
        try await status().entries.first { $0.path == path && $0.isConflicted }?.conflictKind
    }

    /// Which multi-step operation (if any) is mid-flight, so the right abort is offered.
    public func operationInProgress() async throws -> MergeOperation? {
        if try await gitPathExists("MERGE_HEAD") { return .merge }
        if try await gitPathExists("rebase-merge") { return .rebase }
        if try await gitPathExists("rebase-apply") { return .rebase }
        if try await gitPathExists("CHERRY_PICK_HEAD") { return .cherryPick }
        if try await gitPathExists("REVERT_HEAD") { return .revert }
        return nil
    }

    /// Aborts the whole operation (not one file): the working tree returns to its pre-operation state.
    public func abortOperation(_ op: MergeOperation) async throws {
        let verb: [String]
        switch op {
        case .merge: verb = ["merge", "--abort"]
        case .rebase: verb = ["rebase", "--abort"]
        case .cherryPick: verb = ["cherry-pick", "--abort"]
        case .revert: verb = ["revert", "--abort"]
        }
        _ = try await run(verb)
    }

    private func gitPathExists(_ name: String) async throws -> Bool {
        let p = try await run(["rev-parse", "--git-path", name]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = p.hasPrefix("/") ? p : (root as NSString).appendingPathComponent(p)
        return FileManager.default.fileExists(atPath: full)
    }

    // MARK: Index and commits

    public func stage(paths: [String]) async throws { guard !paths.isEmpty else { return }; _ = try await run(["add", "--"] + paths) }
    public func stageAll() async throws { _ = try await run(["add", "--all"]) }
    public func unstage(paths: [String]) async throws { guard !paths.isEmpty else { return }; _ = try await run(["restore", "--staged", "--"] + paths) }

    /// Reverts tracked files to the index. Untracked files are left alone (Bible Part 6 §9).
    public func discardChanges(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["checkout", "--"] + paths)
    }

    public func commit(message: String) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitError.emptyMessage }
        let staged = try await run(["diff", "--cached", "--quiet"], allowFailure: true)
        guard staged.code == 1 else {
            if staged.code == 0 { throw GitError.nothingToCommit }
            throw GitError.commandFailed(code: staged.code, stderr: staged.stderr)
        }
        // Never let git invent "user@host" (Bible Part 6 §8: identity errors must surface).
        let r = try await run(["-c", "user.useConfigOnly=true", "commit", "-m", message], allowFailure: true)
        guard r.code == 0 else {
            if r.stderr.contains("Please tell me who you are") || r.stderr.contains("empty ident") || r.stderr.contains("auto-detection is disabled") {
                throw GitError.identityNotConfigured
            }
            throw GitError.commandFailed(code: r.code, stderr: r.stderr)
        }
        return try await run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Remote synchronization (Bible Part 6 §10) — fetch, pull, push as distinct operations.

    /// Short user-facing title for the outcome of a failed remote operation (`operation` is "Fetch",
    /// "Pull" or "Push"). Pure, so the app's routing of remote failures to a window-level banner can
    /// be tested here without the UI.
    public static func remoteFailureTitle(_ error: GitError, operation: String) -> String {
        switch error {
        case .authenticationRequired: "\(operation) failed: authentication required"
        case .networkUnavailable: "\(operation) failed: remote unreachable"
        case .pushRejected: "Push rejected"
        case .noUpstreamConfigured: "\(operation) failed: no upstream configured"
        case .operationTimedOut: "\(operation) timed out — remote state unknown"
        case .dirtyWorkingTree: "\(operation) refused: uncommitted changes"
        default: "\(operation) failed"
        }
    }

    /// Maps a failed remote command to a specific error. Order matters: "rejected" also appears in auth
    /// failures, so auth is checked first. A terminated process (timeout) is `operationTimedOut`.
    static func classifyRemoteFailure(code: Int32, stderr: String) -> GitError {
        if code == 15 || code == 143 || code < 0 { return .operationTimedOut }
        let s = stderr.lowercased()
        if s.contains("authentication failed") || s.contains("could not read username") || s.contains("could not read password")
            || s.contains("permission denied") || s.contains("permission to") || s.contains("403 forbidden")
            || s.contains("terminal prompts disabled") || s.contains("invalid username or password") {
            return .authenticationRequired
        }
        if s.contains("could not resolve host") || s.contains("unable to access") || s.contains("connection refused")
            || s.contains("connection timed out") || s.contains("could not connect") || s.contains("network is unreachable")
            || s.contains("failed to connect") {
            return .networkUnavailable
        }
        if s.contains("[rejected]") || s.contains("non-fast-forward") || s.contains("fetch first")
            || s.contains("updates were rejected") || s.contains("failed to push") {
            return .pushRejected(stderr: stderr)
        }
        if s.contains("no upstream") || s.contains("has no upstream branch") || s.contains("no configured push destination")
            || s.contains("no tracking information") {
            return .noUpstreamConfigured
        }
        return .commandFailed(code: code, stderr: stderr)
    }

    /// Updates remote-tracking refs from `remote`. Never changes the working tree; ahead/behind in a
    /// later `status()` reflect the fetched refs.
    public func fetch(remote: String = "origin") async throws {
        let r = try await run(["fetch", remote], allowFailure: true)
        guard r.code == 0 else { throw Self.classifyRemoteFailure(code: r.code, stderr: r.stderr) }
    }

    /// Fetches and merges the current branch's upstream (no rebase). Refuses on a dirty tree so a merge
    /// can never leave an ambiguous half-merged state (§10, "never silently discard local changes"). A
    /// merge conflict is NOT an error: it leaves a merge in progress that the conflict UI resolves.
    public func pull() async throws {
        if try await status().entries.contains(where: { !$0.isUntracked }) { throw GitError.dirtyWorkingTree }
        // Resolve the upstream explicitly (same signal `push` uses) instead of relying on git's localized
        // "There is no tracking information" text; the classifier keeps that text as a fallback.
        guard try await hasUpstream() else { throw GitError.noUpstreamConfigured }
        let r = try await run(["pull", "--no-rebase"], allowFailure: true)
        if r.code == 0 { return }
        if try await operationInProgress() == .merge { return }   // conflicts → handled by the conflict view
        throw Self.classifyRemoteFailure(code: r.code, stderr: r.stderr)
    }

    /// Pushes the current branch to its configured upstream. Requires an upstream (never sets one
    /// implicitly, §10) and never force-pushes from the UI.
    /// VS Code's "Publish Branch": pushes the current branch to `remote` and sets it as upstream.
    public func publish(remote: String = "origin") async throws {
        let r = try await run(["push", "-u", remote, "HEAD"], allowFailure: true)
        guard r.code == 0 else { throw Self.classifyRemoteFailure(code: r.code, stderr: r.stderr) }
    }

    public func push(force: Bool = false) async throws {
        guard try await hasUpstream() else { throw GitError.noUpstreamConfigured }
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        let r = try await run(args, allowFailure: true)
        guard r.code == 0 else { throw Self.classifyRemoteFailure(code: r.code, stderr: r.stderr) }
    }

    /// URL of a configured remote, or nil when it does not exist. Read-only; used by Debug hooks to
    /// refuse running against anything that is not a local filesystem path.
    public func remoteURL(_ name: String = "origin") async throws -> String? {
        let r = try await run(["remote", "get-url", name], allowFailure: true)
        guard r.code == 0 else { return nil }
        let url = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// True when the current branch has a configured upstream (`@{upstream}` resolves). Never sets one.
    public func hasUpstream() async throws -> Bool {
        let up = try await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], allowFailure: true)
        return up.code == 0 && !up.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Branches and history

    public func branches() async throws -> [GitBranch] {
        // Most recently committed first, like VS Code's branch picker.
        let out = try await run(["for-each-ref", "refs/heads", "--sort=-committerdate", "--format=%(refname:short)\u{1f}%(HEAD)\u{1f}%(upstream:short)\u{1f}%(objectname:short)\u{1f}%(committerdate:unix)\u{1f}%(authorname)\u{1f}%(subject)"]).stdout
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard p.count == 7 else { return nil }
            return GitBranch(name: String(p[0]), isCurrent: p[1] == "*", upstream: p[2].isEmpty ? nil : String(p[2]), head: String(p[3]),
                             lastCommitDate: TimeInterval(p[4]).map(Date.init(timeIntervalSince1970:)), lastCommitAuthor: String(p[5]), lastCommitSubject: String(p[6]))
        }
    }

    /// `from` is the start point (branch, tag or commit); nil means HEAD.
    public func createBranch(_ name: String, checkout: Bool, from: String? = nil) async throws {
        _ = try await run((checkout ? ["checkout", "-b", name] : ["branch", name]) + (from.map { [$0] } ?? []))
    }

    /// Refuses on a dirty tree unless forced; never stashes silently (Bible Part 6 §10).
    public func checkout(branch: String, force: Bool = false) async throws {
        if !force {
            let s = try await status()
            if s.entries.contains(where: { !$0.isUntracked }) { throw GitError.dirtyWorkingTree }
        }
        _ = try await run(force ? ["checkout", "-f", branch] : ["checkout", branch])
    }

    /// `path` limits the log to commits touching that file (following renames).
    public func log(limit: Int = 50, path: String? = nil) async throws -> [GitCommit] {
        let r = try await run(["log", "-n", "\(max(limit, 1))", "--format=%H\u{1f}%h\u{1f}%an\u{1f}%at\u{1f}%s"] + (path.map { ["--follow", "--", $0] } ?? []), allowFailure: true)
        guard r.code == 0 else {
            if r.stderr.contains("does not have any commits") || r.stderr.contains("bad default revision") { return [] }
            throw GitError.commandFailed(code: r.code, stderr: r.stderr)
        }
        return r.stdout.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard p.count == 5, let t = TimeInterval(p[3]) else { return nil }
            return GitCommit(hash: String(p[0]), shortHash: String(p[1]), author: String(p[2]), date: Date(timeIntervalSince1970: t), subject: String(p[4]))
        }
    }

    /// The file's content at HEAD (`git show HEAD:<path>`); throws when HEAD doesn't have it.
    public func contentAtHEAD(path: String) async throws -> Data {
        let d = try await execute(["show", "HEAD:\(path)"], input: nil)   // raw bytes: binary files survive
        guard d.code == 0 else { throw GitError.commandFailed(code: d.code, stderr: String(decoding: d.stderr, as: UTF8.self)) }
        return d.stdout
    }

    // MARK: Worktrees

    public func worktrees() async throws -> [GitWorktree] {
        let out = try await run(["worktree", "list", "--porcelain"]).stdout
        var result: [GitWorktree] = []
        var path: String?, head: String?, branch: String?, locked = false
        func flush() {
            if let p = path { result.append(GitWorktree(path: Self.canonical(p), head: head, branch: branch, isMain: result.isEmpty, isLocked: locked)) }
            path = nil; head = nil; branch = nil; locked = false
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
            else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if line.hasPrefix("locked") { locked = true }
        }
        flush()
        return result
    }

    public func addWorktree(path: String, branch: String, createBranch: Bool) async throws {
        guard !path.isEmpty, !FileManager.default.fileExists(atPath: path) else { throw GitError.invalidPath }
        _ = try await run(createBranch ? ["worktree", "add", "-b", branch, path] : ["worktree", "add", path, branch])
    }

    /// Removes the worktree directory and registration only; the branch stays (Bible Part 6 §14.3).
    public func removeWorktree(path: String, force: Bool = false) async throws {
        if !force {
            let other = GitRepository(root: path, isLinkedWorktree: true, gitPath: gitPath)
            await other.setExtraEnvironment(extraEnvironment)
            if try await !other.status().isClean { throw GitError.dirtyWorkingTree }
        }
        _ = try await run(force ? ["worktree", "remove", "--force", path] : ["worktree", "remove", path])
    }

    // MARK: Process runner

    struct Result: Sendable { let stdout: String; let stderr: String; let code: Int32 }

    @discardableResult
    func run(_ args: [String], allowFailure: Bool = false, input: Data? = nil) async throws -> Result {
        let data = try await execute(args, input: input)
        let result = Result(stdout: String(decoding: data.stdout, as: UTF8.self), stderr: String(decoding: data.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), code: data.code)
        if !allowFailure && result.code != 0 { throw GitError.commandFailed(code: result.code, stderr: result.stderr) }
        return result
    }

    /// Raw stdout bytes plus exit code, never throwing on a non-zero exit — for binary-safe reads
    /// (e.g. `cat-file blob`) where an absent object is an expected outcome, not an error.
    func executeRaw(_ args: [String]) async throws -> (stdout: Data, code: Int32) {
        let d = try await execute(args)
        return (d.stdout, d.code)
    }

    func runData(_ args: [String]) async throws -> Data {
        let d = try await execute(args)
        guard d.code == 0 else { throw GitError.commandFailed(code: d.code, stderr: String(decoding: d.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return d.stdout
    }

    private func execute(_ args: [String], input: Data? = nil) async throws -> (stdout: Data, stderr: Data, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        for key in ["PATH", "HOME"] { env[key] = ProcessInfo.processInfo.environment[key] }
        env.merge(extraEnvironment) { $1 }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe: Pipe? = input != nil ? Pipe() : nil
        process.standardInput = inPipe ?? FileHandle.nullDevice
        Log.git.debug("git \(args.first ?? "", privacy: .public)")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try process.run() } catch { continuation.resume(throwing: GitError.gitUnavailable); return }
                // Feed stdin off this thread so a patch larger than the pipe buffer can't wedge the read below.
                if let inPipe, let input {
                    DispatchQueue.global(qos: .utility).async {
                        inPipe.fileHandleForWriting.write(input)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                // Drain stderr concurrently with stdout so neither pipe can fill and deadlock the child.
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                Log.git.debug("git \(args.first ?? "", privacy: .public) exit=\(process.terminationStatus, privacy: .public)")
                continuation.resume(returning: (outData, errBox.data, process.terminationStatus))
            }
            // ponytail: timeout kills the process; a hung credential helper or hook surfaces as commandFailed.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { if process.isRunning { process.terminate() } }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
