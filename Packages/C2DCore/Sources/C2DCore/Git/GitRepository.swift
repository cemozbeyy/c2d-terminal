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
}

/// One line of `git status --porcelain=v2`. Index and worktree states are kept apart (Bible Part 6 §3).
public struct GitStatusEntry: Hashable, Sendable {
    public enum Change: Character, Sendable { case unmodified = ".", modified = "M", typeChanged = "T", added = "A", deleted = "D", renamed = "R", copied = "C", unmerged = "U" }
    public let path: String
    public let originalPath: String?
    public let staged: Change
    public let unstaged: Change
    public let isUntracked: Bool
    public let isConflicted: Bool
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
                                              isUntracked: false, isConflicted: conflicted))
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

    // MARK: Branches and history

    public func branches() async throws -> [GitBranch] {
        let out = try await run(["for-each-ref", "refs/heads", "--format=%(refname:short)\u{1f}%(HEAD)\u{1f}%(upstream:short)\u{1f}%(objectname:short)"]).stdout
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard p.count == 4 else { return nil }
            return GitBranch(name: String(p[0]), isCurrent: p[1] == "*", upstream: p[2].isEmpty ? nil : String(p[2]), head: String(p[3]))
        }
    }

    public func createBranch(_ name: String, checkout: Bool) async throws {
        _ = try await run(checkout ? ["checkout", "-b", name] : ["branch", name])
    }

    /// Refuses on a dirty tree unless forced; never stashes silently (Bible Part 6 §10).
    public func checkout(branch: String, force: Bool = false) async throws {
        if !force {
            let s = try await status()
            if s.entries.contains(where: { !$0.isUntracked }) { throw GitError.dirtyWorkingTree }
        }
        _ = try await run(force ? ["checkout", "-f", branch] : ["checkout", branch])
    }

    public func log(limit: Int = 50) async throws -> [GitCommit] {
        let r = try await run(["log", "-n", "\(max(limit, 1))", "--format=%H\u{1f}%h\u{1f}%an\u{1f}%at\u{1f}%s"], allowFailure: true)
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
    func run(_ args: [String], allowFailure: Bool = false) async throws -> Result {
        let data = try await execute(args)
        let result = Result(stdout: String(decoding: data.stdout, as: UTF8.self), stderr: String(decoding: data.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), code: data.code)
        if !allowFailure && result.code != 0 { throw GitError.commandFailed(code: result.code, stderr: result.stderr) }
        return result
    }

    func runData(_ args: [String]) async throws -> Data {
        let d = try await execute(args)
        guard d.code == 0 else { throw GitError.commandFailed(code: d.code, stderr: String(decoding: d.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return d.stdout
    }

    private func execute(_ args: [String]) async throws -> (stdout: Data, stderr: Data, code: Int32) {
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
        process.standardInput = FileHandle.nullDevice
        Log.git.debug("git \(args.first ?? "", privacy: .public)")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try process.run() } catch { continuation.resume(throwing: GitError.gitUnavailable); return }
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
