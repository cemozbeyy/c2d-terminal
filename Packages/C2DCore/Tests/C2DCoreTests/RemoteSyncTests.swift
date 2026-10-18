import Foundation
import Testing
@testable import C2DCore

// Remote fetch/pull/push (Bible Part 6 §10) against LOCAL bare remotes only — never a real remote.
@Suite(.serialized) struct RemoteSyncTests {
    static let masked = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]

    struct Remotes {
        let base: URL
        let work: GitRepository
        let workURL: URL, otherURL: URL, originURL: URL
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    @discardableResult
    private func run(_ dir: URL, _ args: [String], allowFailure: Bool = false) async throws -> String {
        let r = GitRepository(root: dir.path, isLinkedWorktree: false, gitPath: GitRepository.locateGit()!)
        await r.setExtraEnvironment(Self.masked)
        return try await r.run(args, allowFailure: allowFailure).stdout
    }
    private func write(_ url: URL, _ s: String) throws { try s.write(to: url, atomically: true, encoding: .utf8) }

    /// Bare `origin.git`, a `work` clone with upstream set, and a second `other` clone to move the remote.
    private func makeRemotePair() async throws -> Remotes {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let originURL = base.appendingPathComponent("origin.git")
        try await run(base, ["init", "--bare", "-b", "main", "origin.git"])
        let workURL = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        try await run(workURL, ["init", "-q", "-b", "main"])
        try await run(workURL, ["config", "user.name", "Work"]); try await run(workURL, ["config", "user.email", "w@c2d.works"])
        try write(workURL.appendingPathComponent("f.txt"), "l1\nl2\nl3\n")
        try await run(workURL, ["add", "-A"]); try await run(workURL, ["commit", "-q", "-m", "base"])
        try await run(workURL, ["remote", "add", "origin", originURL.path])
        try await run(workURL, ["push", "-u", "origin", "main"])
        try await run(base, ["clone", "-q", originURL.path, "other"])
        let otherURL = base.appendingPathComponent("other")
        try await run(otherURL, ["config", "user.name", "Other"]); try await run(otherURL, ["config", "user.email", "o@c2d.works"])
        let work = GitRepository(root: workURL.path, isLinkedWorktree: false, gitPath: GitRepository.locateGit()!)
        await work.setExtraEnvironment(Self.masked)
        return Remotes(base: base, work: work, workURL: workURL, otherURL: otherURL, originURL: originURL)
    }

    /// `other` adds a commit and pushes, moving the remote.
    private func otherPushes(_ r: Remotes, file: String = "g.txt", content: String = "from other\n") async throws {
        try write(r.otherURL.appendingPathComponent(file), content)
        try await run(r.otherURL, ["add", "-A"]); try await run(r.otherURL, ["commit", "-q", "-m", "other change"])
        try await run(r.otherURL, ["push", "-q", "origin", "main"])
    }

    // MARK: Classifier (pure, covers auth/network/rejection/timeout without a server)

    @Test func classifierMapsStderrInPriorityOrder() {
        func kind(_ code: Int32, _ s: String) -> GitError { GitRepository.classifyRemoteFailure(code: code, stderr: s) }
        #expect(kind(15, "anything") == .operationTimedOut)
        #expect(kind(128, "remote: Permission to x denied\n[rejected] main") == .authenticationRequired)   // auth beats rejected
        #expect(kind(128, "fatal: Authentication failed for 'https://…'") == .authenticationRequired)
        #expect(kind(128, "fatal: could not read Username for 'https://…': terminal prompts disabled") == .authenticationRequired)
        #expect(kind(128, "fatal: unable to access 'https://…': Could not resolve host: invalid.invalid") == .networkUnavailable)
        #expect(kind(1, "! [rejected]  main -> main (non-fast-forward)\nUpdates were rejected") == .pushRejected(stderr: "! [rejected]  main -> main (non-fast-forward)\nUpdates were rejected"))
        #expect(kind(128, "fatal: The current branch main has no upstream branch.") == .noUpstreamConfigured)
        #expect(kind(1, "There is no tracking information for the current branch.\nPlease specify which branch you want to merge with.") == .noUpstreamConfigured)
        #expect(kind(1, "fatal: something else entirely") == .commandFailed(code: 1, stderr: "fatal: something else entirely"))
    }

    /// Titles the app shows outside the Git panel when a remote operation fails (routing is app-layer;
    /// the mapping is pure and lives here).
    @Test func remoteFailureTitlesAreSpecificAndNameTheOperation() {
        #expect(GitRepository.remoteFailureTitle(.pushRejected(stderr: "x"), operation: "Push") == "Push rejected")
        #expect(GitRepository.remoteFailureTitle(.authenticationRequired, operation: "Fetch") == "Fetch failed: authentication required")
        #expect(GitRepository.remoteFailureTitle(.networkUnavailable, operation: "Pull") == "Pull failed: remote unreachable")
        #expect(GitRepository.remoteFailureTitle(.noUpstreamConfigured, operation: "Pull") == "Pull failed: no upstream configured")
        #expect(GitRepository.remoteFailureTitle(.operationTimedOut, operation: "Push") == "Push timed out — remote state unknown")
        #expect(GitRepository.remoteFailureTitle(.dirtyWorkingTree, operation: "Pull") == "Pull refused: uncommitted changes")
        #expect(GitRepository.remoteFailureTitle(.commandFailed(code: 1, stderr: ""), operation: "Fetch") == "Fetch failed")
    }

    // MARK: Pull without upstream

    @Test func pullWithoutUpstreamThrowsBeforeTouchingAnything() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-pullnoup-\(UUID().uuidString)")
        let root = base.appendingPathComponent("solo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await run(root, ["init", "-q", "-b", "main"])
        try await run(root, ["config", "user.name", "S"]); try await run(root, ["config", "user.email", "s@c2d.works"])
        try write(root.appendingPathComponent("a.txt"), "x\n")
        try await run(root, ["add", "-A"]); try await run(root, ["commit", "-qm", "c"])
        // A remote exists but the branch does not track it: the realistic "cloned, then new branch" case.
        try await run(root, ["remote", "add", "origin", base.appendingPathComponent("nowhere.git").path])
        let repo = GitRepository(root: root.path, isLinkedWorktree: false, gitPath: GitRepository.locateGit()!)
        await repo.setExtraEnvironment(Self.masked)
        #expect(try await repo.hasUpstream() == false)
        await #expect(throws: GitError.noUpstreamConfigured) { try await repo.pull() }
        #expect(try await repo.operationInProgress() == nil)
        #expect(try await repo.status().isClean, "a refused pull changes nothing")
    }

    @Test func remoteURLIsReadOnlyAndNilWhenMissing() async throws {
        let r = try await makeRemotePair(); defer { r.cleanup() }
        #expect(try await r.work.remoteURL() == r.originURL.path)
        #expect(try await r.work.remoteURL("nope") == nil)
    }

    // MARK: Fetch

    @Test func fetchUpdatesBehindCount() async throws {
        let r = try await makeRemotePair(); defer { r.cleanup() }
        try await otherPushes(r)
        #expect(try await r.work.status().behind == 0, "behind is stale until a fetch")
        try await r.work.fetch()
        let s = try await r.work.status()
        #expect(s.behind == 1 && s.ahead == 0, "fetch must move the remote-tracking ref so behind reflects it")
        // Fetch does not touch the working tree.
        #expect(!FileManager.default.fileExists(atPath: r.workURL.appendingPathComponent("g.txt").path))
    }

    @Test func fetchNetworkFailureIsClassified() async throws {
        let r = try await makeRemotePair(); defer { r.cleanup() }
        try await run(r.workURL, ["remote", "add", "bad", "https://invalid.invalid/x.git"])
        await #expect(throws: GitError.networkUnavailable) { try await r.work.fetch(remote: "bad") }
    }

    // MARK: Pull

    @Test func pullIntegratesCleanly() async throws {
        let r = try await makeRemotePair(); defer { r.cleanup() }
        try await otherPushes(r)
        try await r.work.pull()
        #expect(FileManager.default.fileExists(atPath: r.workURL.appendingPathComponent("g.txt").path))
        #expect(try await r.work.status().behind == 0)
    }

    @Test func pullConflictLeavesMergeInProgress() async throws {
        let r = try await makeRemotePair(); defer { r.cleanup() }
        // Both sides change the same line → divergent histories.
        try write(r.otherURL.appendingPathComponent("f.txt"), "l1\nTHEIRS\nl3\n")
        try await run(r.otherURL, ["commit", "-qam", "theirs"]); try await run(r.otherURL, ["push", "-q", "origin", "main"])
        try write(r.workURL.appendingPathComponent("f.txt"), "l1\nOURS\nl3\n")
        try await run(r.workURL, ["commit", "-qam", "ours"])
        try await r.work.pull()   // must NOT throw; conflict → merge in progress
        #expect(try await r.work.operationInProgress() == .merge)
        #expect(try await r.work.status().entries.contains { $0.isConflicted })
    }

    @Test func pullRefusesDirtyTree() async throws {
        let r = try await makeRemotePair(); defer { r.cleanup() }
        try await otherPushes(r)
        try write(r.workURL.appendingPathComponent("f.txt"), "l1\nDIRTY uncommitted\nl3\n")
        await #expect(throws: GitError.dirtyWorkingTree) { try await r.work.pull() }
        #expect(try await r.work.operationInProgress() == nil, "nothing started")
        #expect(try read(r.workURL, "f.txt").contains("DIRTY uncommitted"), "local changes untouched")
    }

    // MARK: Push

    @Test func pushAdvancesLocalRemote() async throws {
        let r = try await makeRemotePair(); defer { r.cleanup() }
        try write(r.workURL.appendingPathComponent("h.txt"), "pushed\n")
        try await run(r.workURL, ["add", "-A"]); try await run(r.workURL, ["commit", "-qm", "work push"])
        #expect(try await r.work.status().ahead == 1)
        try await r.work.push()
        #expect(try await r.work.status().ahead == 0)
        // The (local) remote actually moved.
        let originLog = try await run(r.originURL, ["log", "--format=%s", "-1"])
        #expect(originLog.contains("work push"))
    }

    @Test func pushRejectedWhenRemoteHasNewerCommits() async throws {
        let r = try await makeRemotePair(); defer { r.cleanup() }
        try await otherPushes(r)   // remote advances
        try write(r.workURL.appendingPathComponent("h.txt"), "local\n")
        try await run(r.workURL, ["add", "-A"]); try await run(r.workURL, ["commit", "-qm", "local only"])
        do {
            try await r.work.push()
            Issue.record("expected the push to be rejected (non-fast-forward)")
        } catch {
            if case .pushRejected = (error as? GitError) {} else { Issue.record("expected pushRejected, got \(error)") }
        }
        #expect(try await run(r.workURL, ["log", "--format=%s", "-1"]).contains("local only"), "local commit must survive a rejected push")
    }

    @Test func pushWithoutUpstreamThrows() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-noup-\(UUID().uuidString)")
        let root = base.appendingPathComponent("solo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await run(root, ["init", "-q", "-b", "main"])
        try await run(root, ["config", "user.name", "S"]); try await run(root, ["config", "user.email", "s@c2d.works"])
        try write(root.appendingPathComponent("a.txt"), "x\n")
        try await run(root, ["add", "-A"]); try await run(root, ["commit", "-qm", "c"])
        let repo = GitRepository(root: root.path, isLinkedWorktree: false, gitPath: GitRepository.locateGit()!)
        await repo.setExtraEnvironment(Self.masked)
        await #expect(throws: GitError.noUpstreamConfigured) { try await repo.push() }
    }
}

private extension RemoteSyncTests {
    func read(_ dir: URL, _ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
}
