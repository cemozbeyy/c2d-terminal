import Foundation
import Testing
@testable import C2DCore

/// Real `git` in temp repositories. Identity is set per repo; global config is masked.
@Suite(.serialized) struct GitRepositoryTests {
    struct Repo {
        let root: URL
        let repo: GitRepository
        func write(_ name: String, _ content: String) throws {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        func read(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private static let maskedGlobal = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

    func makeRepo(identity: Bool = true) async throws -> Repo {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-git-\(UUID().uuidString)")
        let root = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = GitRepository(root: root.path, isLinkedWorktree: false, gitPath: GitRepository.locateGit()!)
        await probe.setExtraEnvironment(Self.maskedGlobal)
        try await probe.run(["init", "-q", "-b", "main"])
        if identity {
            try await probe.run(["config", "user.name", "C2D Test"])
            try await probe.run(["config", "user.email", "test@c2d.works"])
        }
        let repo = try await GitRepository.discover(path: root.path)!
        await repo.setExtraEnvironment(Self.maskedGlobal)
        return Repo(root: root.standardizedFileURL.resolvingSymlinksInPath(), repo: repo)
    }

    @Test func discoverFindsRootFromSubdirectoryAndNilOutside() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        try r.write("src/deep/a.txt", "x")
        let sub = try await GitRepository.discover(path: r.root.appendingPathComponent("src/deep").path)
        #expect(sub?.root == r.root.path)
        #expect(sub?.isLinkedWorktree == false)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(try await GitRepository.discover(path: outside.path) == nil)
        await #expect(throws: GitError.invalidPath) { try await GitRepository.discover(path: "/no/such/dir") }
    }

    @Test func unbornRepoStatus() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        let s = try await r.repo.status()
        #expect(s.isUnborn && s.branch == "main" && s.isClean && !s.isDetached)
        #expect(try await r.repo.log().isEmpty)
    }

    @Test func untrackedStagedCommittedTransitions() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        try r.write("a.txt", "hello\n")
        var s = try await r.repo.status()
        #expect(s.entries.map(\.path) == ["a.txt"] && s.entries[0].isUntracked)
        try await r.repo.stage(paths: ["a.txt"])
        s = try await r.repo.status()
        #expect(s.entries[0].staged == .added && !s.entries[0].isUntracked && s.entries[0].hasStagedChange)
        let hash = try await r.repo.commit(message: "first")
        #expect(hash.count == 40)
        s = try await r.repo.status()
        #expect(s.isClean && !s.isUnborn)
        let log = try await r.repo.log()
        #expect(log.count == 1 && log[0].subject == "first" && log[0].author == "C2D Test" && log[0].hash == hash)
    }

    @Test func stagedAndUnstagedChangesToSameFileAreDistinct() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        try r.write("f.txt", "1\n"); try await r.repo.stageAll(); _ = try await r.repo.commit(message: "c1")
        try r.write("f.txt", "1\n2\n"); try await r.repo.stage(paths: ["f.txt"])
        try r.write("f.txt", "1\n2\n3\n")
        let e = try await r.repo.status().entries[0]
        #expect(e.staged == .modified && e.unstaged == .modified && e.hasStagedChange && e.hasUnstagedChange)
        #expect(try await r.repo.diff(path: "f.txt", staged: true).contains("+2"))
        let unstaged = try await r.repo.diff(path: "f.txt", staged: false)
        #expect(unstaged.contains("+3") && !unstaged.contains("+2"))
        try await r.repo.unstage(paths: ["f.txt"])
        let e2 = try await r.repo.status().entries[0]
        #expect(e2.staged == .unmodified && e2.unstaged == .modified)
    }

    @Test func renameIsReportedWithOriginalPath() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        try r.write("old.txt", String(repeating: "line\n", count: 20)); try await r.repo.stageAll(); _ = try await r.repo.commit(message: "c1")
        try await r.repo.run(["mv", "old.txt", "new.txt"])
        let e = try await r.repo.status().entries[0]
        #expect(e.staged == .renamed && e.path == "new.txt" && e.originalPath == "old.txt")
    }

    @Test func untrackedDiffShowsAdditionsAndParserWorks() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        try r.write("n.txt", "a\nb\n")
        let text = try await r.repo.diff(path: "n.txt", staged: false)
        let files = GitRepository.parseUnifiedDiff(text)
        #expect(files.count == 1 && files[0].oldPath == nil && files[0].newPath == "n.txt" && !files[0].isBinary)
        #expect(files[0].hunks[0].lines.map(\.kind) == [.added, .added])
        #expect(files[0].hunks[0].lines.map(\.newLine) == [1, 2])

        try await r.repo.stageAll(); _ = try await r.repo.commit(message: "c1")
        try r.write("n.txt", "a\nB\nc\n")
        let modified = GitRepository.parseUnifiedDiff(try await r.repo.diff(path: "n.txt", staged: false))
        let hunk = modified[0].hunks[0]
        #expect(hunk.oldStart == 1 && hunk.newStart == 1 && hunk.oldCount == 2 && hunk.newCount == 3)
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added, .added])
        #expect(hunk.lines[1].oldLine == 2 && hunk.lines[2].newLine == 2 && hunk.lines[3].newLine == 3)
    }

    @Test func parserHandlesBinaryAndMultipleFiles() {
        let text = """
        diff --git a/x.bin b/x.bin
        Binary files a/x.bin and b/x.bin differ
        diff --git a/y.txt b/y.txt
        --- a/y.txt
        +++ b/y.txt
        @@ -10,2 +10,3 @@ func f()
         ctx
        -gone
        +new1
        +new2
        \\ No newline at end of file
        """
        let files = GitRepository.parseUnifiedDiff(text)
        #expect(files.count == 2)
        #expect(files[0].isBinary && files[0].hunks.isEmpty)
        #expect(files[1].hunks.count == 1 && files[1].hunks[0].header.hasPrefix("@@ -10,2 +10,3 @@"))
        #expect(files[1].hunks[0].lines.count == 4 && files[1].hunks[0].lines.last?.newLine == 12)
    }

    @Test func commitErrors() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        await #expect(throws: GitError.emptyMessage) { try await r.repo.commit(message: "  \n") }
        await #expect(throws: GitError.nothingToCommit) { try await r.repo.commit(message: "x") }
        let noId = try await makeRepo(identity: false); defer { noId.cleanup() }
        try noId.write("a", "1"); try await noId.repo.stageAll()
        await #expect(throws: GitError.identityNotConfigured) { try await noId.repo.commit(message: "x") }
    }

    @Test func branchesCheckoutAndDirtyRefusal() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        try r.write("a", "1"); try await r.repo.stageAll(); _ = try await r.repo.commit(message: "c1")
        try await r.repo.createBranch("feature", checkout: true)
        var b = try await r.repo.branches()
        #expect(b.map(\.name).sorted() == ["feature", "main"] && b.first { $0.isCurrent }?.name == "feature")
        try r.write("a", "2")
        await #expect(throws: GitError.dirtyWorkingTree) { try await r.repo.checkout(branch: "main") }
        #expect(try r.read("a") == "2", "refusal left the change alone")
        try await r.repo.discardChanges(paths: ["a"])
        #expect(try r.read("a") == "1")
        try await r.repo.checkout(branch: "main")
        b = try await r.repo.branches()
        #expect(b.first { $0.isCurrent }?.name == "main")
        #expect(try await r.repo.status().branch == "main")
    }

    @Test func logIsNewestFirstAndBounded() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        for i in 1...3 { try r.write("f", "\(i)"); try await r.repo.stageAll(); _ = try await r.repo.commit(message: "commit \(i)") }
        let log = try await r.repo.log(limit: 2)
        #expect(log.map(\.subject) == ["commit 3", "commit 2"])
        #expect(log[0].shortHash.count >= 7 && log[0].date <= Date())
    }

    @Test func worktreeLifecycleAndDirtyRefusal() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        try r.write("a", "1"); try await r.repo.stageAll(); _ = try await r.repo.commit(message: "c1")
        let wtPath = r.root.deletingLastPathComponent().appendingPathComponent("wt").path
        try await r.repo.addWorktree(path: wtPath, branch: "wt-branch", createBranch: true)
        let list = try await r.repo.worktrees()
        #expect(list.count == 2 && list[0].isMain && list[0].path == r.root.path)
        #expect(list[1].branch == "wt-branch" && !list[1].isMain && list[1].path == URL(fileURLWithPath: wtPath).resolvingSymlinksInPath().path)
        let linked = try await GitRepository.discover(path: wtPath)
        #expect(linked?.isLinkedWorktree == true)
        await #expect(throws: GitError.invalidPath) { try await r.repo.addWorktree(path: wtPath, branch: "x", createBranch: true) }

        try "dirty".write(toFile: wtPath + "/a", atomically: true, encoding: .utf8)
        await #expect(throws: GitError.dirtyWorkingTree) { try await r.repo.removeWorktree(path: wtPath) }
        #expect(FileManager.default.fileExists(atPath: wtPath))
        try await r.repo.removeWorktree(path: wtPath, force: true)
        #expect(!FileManager.default.fileExists(atPath: wtPath))
        #expect(try await r.repo.worktrees().count == 1)
        #expect(try await r.repo.branches().map(\.name).contains("wt-branch"), "removing a worktree never deletes its branch")
    }

    // MARK: Partial (hunk) staging

    /// Two edits separated by ≥8 unchanged lines so git keeps them as distinct hunks (7 lines of
    /// context would otherwise merge them). Stage only the first; the second must stay unstaged.
    private func makeTwoHunkRepo() async throws -> Repo {
        let r = try await makeRepo()
        let base = (1...20).map { "line \($0)\n" }.joined()
        try r.write("f.txt", base); try await r.repo.stageAll(); _ = try await r.repo.commit(message: "base")
        var edited = (1...20).map { "line \($0)" }
        edited[1] = "line 2 CHANGED"       // hunk around line 2
        edited[17] = "line 18 CHANGED"     // hunk around line 18 (≥8 lines away)
        try r.write("f.txt", edited.joined(separator: "\n") + "\n")
        return r
    }

    @Test func extractHunkPatchSlicesOneHunkLosslessly() async throws {
        let r = try await makeTwoHunkRepo(); defer { r.cleanup() }
        let diff = try await r.repo.diff(path: "f.txt", staged: false)
        #expect(GitRepository.parseUnifiedDiff(diff).first?.hunks.count == 2)
        let p0 = GitRepository.extractHunkPatch(from: diff, at: 0)
        let p1 = GitRepository.extractHunkPatch(from: diff, at: 1)
        #expect(p0 != nil && p0!.contains("line 2 CHANGED") && !p0!.contains("line 18 CHANGED"))
        #expect(p1 != nil && p1!.contains("line 18 CHANGED") && !p1!.contains("line 2 CHANGED"))
        #expect(p0!.hasPrefix("diff --git") && p0!.hasSuffix("\n"))
        #expect(GitRepository.extractHunkPatch(from: diff, at: 2) == nil)   // out of range
        #expect(GitRepository.extractHunkPatch(from: "no hunks here", at: 0) == nil)
    }

    @Test func stageOneHunkLeavesOthersUnstaged() async throws {
        let r = try await makeTwoHunkRepo(); defer { r.cleanup() }
        let hunks = try await GitRepository.parseUnifiedDiff(r.repo.diff(path: "f.txt", staged: false)).first!.hunks
        try await r.repo.stageHunk(path: "f.txt", index: 0, expected: hunks[0])

        // Working file is untouched by staging; both edits are still on disk.
        let onDisk = try r.read("f.txt")
        #expect(onDisk.contains("line 2 CHANGED") && onDisk.contains("line 18 CHANGED"))
        // Index now holds only the first edit; the second is still unstaged.
        let staged = try await r.repo.diff(path: "f.txt", staged: true)
        #expect(staged.contains("line 2 CHANGED") && !staged.contains("line 18 CHANGED"))
        let unstaged = try await r.repo.diff(path: "f.txt", staged: false)
        #expect(unstaged.contains("line 18 CHANGED") && !unstaged.contains("line 2 CHANGED"))
        let e = try await r.repo.status().entries.first { $0.path == "f.txt" }!
        #expect(e.hasStagedChange && e.hasUnstagedChange)
    }

    @Test func unstageHunkReversesTheStage() async throws {
        let r = try await makeTwoHunkRepo(); defer { r.cleanup() }
        try await r.repo.stageAll()
        let stagedHunks = try await GitRepository.parseUnifiedDiff(r.repo.diff(path: "f.txt", staged: true)).first!.hunks
        #expect(stagedHunks.count == 2)
        try await r.repo.unstageHunk(path: "f.txt", index: 0, expected: stagedHunks[0])
        let staged = try await r.repo.diff(path: "f.txt", staged: true)
        #expect(!staged.contains("line 2 CHANGED") && staged.contains("line 18 CHANGED"))
    }

    @Test func stageAdditionAndDeletionHunks() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        let base = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try r.write("f.txt", base); try await r.repo.stageAll(); _ = try await r.repo.commit(message: "base")
        // Pure deletion near the top, pure addition near the bottom.
        var lines = (1...20).map { "line \($0)" }
        lines.remove(at: 1)                  // delete "line 2"
        lines.insert("inserted", at: 18)     // add a line far below
        try r.write("f.txt", lines.joined(separator: "\n") + "\n")
        let hunks = try await GitRepository.parseUnifiedDiff(r.repo.diff(path: "f.txt", staged: false)).first!.hunks
        #expect(hunks.count == 2)
        try await r.repo.stageHunk(path: "f.txt", index: 0, expected: hunks[0])   // the deletion
        let staged = try await r.repo.diff(path: "f.txt", staged: true)
        #expect(staged.contains("-line 2") && !staged.contains("+inserted"))
    }

    @Test func stageHunkWithoutTrailingNewline() async throws {
        // The case where raw text slicing (vs regenerating from a parsed hunk) earns its keep:
        // the "\ No newline at end of file" marker must survive into the patch so apply accepts it.
        let r = try await makeRepo(); defer { r.cleanup() }
        try r.write("f.txt", "alpha\n"); try await r.repo.stageAll(); _ = try await r.repo.commit(message: "base")
        try "alpha\nbeta".write(toFile: r.root.appendingPathComponent("f.txt").path, atomically: true, encoding: .utf8)  // no final newline
        let diff = try await r.repo.diff(path: "f.txt", staged: false)
        #expect(diff.contains("No newline at end of file"))
        let hunks = GitRepository.parseUnifiedDiff(diff).first!.hunks
        try await r.repo.stageHunk(path: "f.txt", index: 0, expected: hunks[0])
        #expect(try await r.repo.diff(path: "f.txt", staged: true).contains("+beta"))
        #expect(try await r.repo.status().entries.first { $0.path == "f.txt" }!.hasStagedChange)
    }

    @Test func staleHunkIsRefusedNothingStaged() async throws {
        let r = try await makeTwoHunkRepo(); defer { r.cleanup() }
        let hunks = try await GitRepository.parseUnifiedDiff(r.repo.diff(path: "f.txt", staged: false)).first!.hunks
        // Edit the file after capturing the diff so the first hunk no longer matches.
        var edited = (1...20).map { "line \($0)" }
        edited[1] = "line 2 TOTALLY DIFFERENT"; edited[17] = "line 18 CHANGED"
        try r.write("f.txt", edited.joined(separator: "\n") + "\n")
        await #expect(throws: GitError.staleDiff) { try await r.repo.stageHunk(path: "f.txt", index: 0, expected: hunks[0]) }
        #expect(try await r.repo.diff(path: "f.txt", staged: true).isEmpty, "a stale hunk must stage nothing")
    }

    // MARK: Conflicts (Bible Part 6 §9)

    /// Leaves the repo mid-merge with `f.txt` conflicted in the requested shape, plus a clean tracked
    /// `unrelated.txt` so a test can dirty it and check it survives resolution.
    private func makeConflictRepo(_ kind: ConflictKind) async throws -> Repo {
        let r = try await makeRepo()
        try r.write("f.txt", "alpha\nbeta\ngamma\n"); try r.write("unrelated.txt", "untouched\n")
        try await r.repo.stageAll(); _ = try await r.repo.commit(message: "base")
        try await r.repo.createBranch("other", checkout: true)   // "theirs"
        switch kind {
        case .deletedByThem: try FileManager.default.removeItem(at: r.root.appendingPathComponent("f.txt"))
        default: try r.write("f.txt", "alpha\nTHEIRS\ngamma\n")
        }
        try await r.repo.stageAll(); _ = try await r.repo.commit(message: "theirs")
        try await r.repo.checkout(branch: "main")                // "ours"
        switch kind {
        case .deletedByUs: try FileManager.default.removeItem(at: r.root.appendingPathComponent("f.txt"))
        default: try r.write("f.txt", "alpha\nOURS\ngamma\n")
        }
        try await r.repo.stageAll(); _ = try await r.repo.commit(message: "ours")
        _ = try await r.repo.run(["merge", "other"], allowFailure: true)   // exits 1 on conflict
        return r
    }

    @Test func resolutionCommandTableIsCorrectForEveryShape() {
        let keepOurs = [["checkout", "--ours", "--", "f"], ["add", "--", "f"]]
        let keepTheirs = [["checkout", "--theirs", "--", "f"], ["add", "--", "f"]]
        let remove = [["rm", "--", "f"]]
        #expect(GitRepository.resolutionCommands(kind: .bothModified, side: .ours, path: "f") == keepOurs)
        #expect(GitRepository.resolutionCommands(kind: .bothModified, side: .theirs, path: "f") == keepTheirs)
        #expect(GitRepository.resolutionCommands(kind: .deletedByThem, side: .ours, path: "f") == keepOurs)
        #expect(GitRepository.resolutionCommands(kind: .deletedByThem, side: .theirs, path: "f") == remove)
        #expect(GitRepository.resolutionCommands(kind: .deletedByUs, side: .ours, path: "f") == remove)
        #expect(GitRepository.resolutionCommands(kind: .deletedByUs, side: .theirs, path: "f") == keepTheirs)
        #expect(GitRepository.resolutionCommands(kind: .addedByUs, side: .theirs, path: "f") == remove)
        #expect(GitRepository.resolutionCommands(kind: .addedByThem, side: .ours, path: "f") == remove)
        #expect(GitRepository.resolutionCommands(kind: .bothDeleted, side: .ours, path: "f") == remove)
    }

    @Test func detectsBothModifiedConflictWithStagesAndOperation() async throws {
        let r = try await makeConflictRepo(.bothModified); defer { r.cleanup() }
        let e = try await r.repo.status().entries.first { $0.path == "f.txt" }
        #expect(e?.isConflicted == true && e?.conflictKind == .bothModified)
        #expect(try await r.repo.operationInProgress() == .merge)
        let stages = try await r.repo.conflictStages(path: "f.txt")
        guard case .text(let base) = stages.base, case .text(let ours) = stages.ours, case .text(let theirs) = stages.theirs else {
            Issue.record("expected all three text stages for both-modified"); return
        }
        #expect(base.contains("beta") && ours.contains("OURS") && theirs.contains("THEIRS"))
    }

    @Test func resolveBothModifiedKeepsSideAndPreservesUnrelatedChange() async throws {
        let r = try await makeConflictRepo(.bothModified); defer { r.cleanup() }
        try r.write("unrelated.txt", "DIRTY EDIT\n")   // uncommitted, must survive
        try await r.repo.resolveConflict(path: "f.txt", using: .ours)
        #expect(try await !r.repo.status().entries.contains { $0.path == "f.txt" && $0.isConflicted })
        #expect(try r.read("f.txt").contains("OURS") && !(try r.read("f.txt")).contains("THEIRS"))
        #expect(try r.read("unrelated.txt") == "DIRTY EDIT\n", "resolving one file never touches unrelated changes")
        #expect(try await r.repo.operationInProgress() == .merge, "resolving a file does not finish the merge")
    }

    @Test func resolveModifyDeleteBothDirections() async throws {
        let keep = try await makeConflictRepo(.deletedByThem); defer { keep.cleanup() }
        #expect(try await keep.repo.status().entries.first { $0.path == "f.txt" }?.conflictKind == .deletedByThem)
        try await keep.repo.resolveConflict(path: "f.txt", using: .ours)   // keep our modified file
        #expect(try await !keep.repo.status().entries.contains { $0.path == "f.txt" && $0.isConflicted })
        #expect(FileManager.default.fileExists(atPath: keep.root.appendingPathComponent("f.txt").path))

        let drop = try await makeConflictRepo(.deletedByThem); defer { drop.cleanup() }
        try await drop.repo.resolveConflict(path: "f.txt", using: .theirs)  // accept the deletion
        #expect(try await !drop.repo.status().entries.contains { $0.path == "f.txt" && $0.isConflicted })
        #expect(!FileManager.default.fileExists(atPath: drop.root.appendingPathComponent("f.txt").path))
    }

    @Test func markResolvedRefusesWhileMarkersRemainThenStages() async throws {
        let r = try await makeConflictRepo(.bothModified); defer { r.cleanup() }
        do {
            try await r.repo.markResolved(path: "f.txt")   // git wrote conflict markers
            Issue.record("expected refusal while markers remain")
        } catch let GitError.conflictMarkersRemain(lines) { #expect(!lines.isEmpty) }
        try r.write("f.txt", "alpha\nMERGED\ngamma\n")
        try await r.repo.markResolved(path: "f.txt")
        let e = try await r.repo.status().entries.first { $0.path == "f.txt" }
        #expect(e?.isConflicted != true)
        #expect(try r.read("f.txt").contains("MERGED"))
    }

    @Test func abortMergeRestoresPreMergeState() async throws {
        let r = try await makeConflictRepo(.bothModified); defer { r.cleanup() }
        #expect(try await r.repo.operationInProgress() == .merge)
        try await r.repo.abortOperation(.merge)
        #expect(try await r.repo.operationInProgress() == nil)
        #expect(try await r.repo.status().isClean && (try r.read("f.txt")).contains("OURS"))
    }

    @Test func commandFailureCarriesStderr() async throws {
        let r = try await makeRepo(); defer { r.cleanup() }
        do {
            try await r.repo.checkout(branch: "no-such-branch")
            Issue.record("expected failure")
        } catch let GitError.commandFailed(code, stderr) {
            #expect(code != 0 && stderr.contains("no-such-branch"))
        }
    }
}
