import Foundation
import Testing
@testable import C2DCore

// Performance benchmarks (Bible Part 15 §17 / testing §14). Timing tests are OPT-IN via the env var
// C2D_PERF=1 and are meaningful only in Release (`swift test -c release`); Debug (-Onone) numbers are
// not a baseline. Correctness-under-load tests run always. Numbers print as `PERF …` lines; see
// docs/PERFORMANCE.md for the recorded baselines, environment, and provisional budgets.
private let perfEnabled = ProcessInfo.processInfo.environment["C2D_PERF"] == "1"

private func ms(_ d: Duration) -> String { String(format: "%.1f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }

/// Median wall time over `samples` runs after `warmup` untimed runs.
private func medianSync(_ samples: Int = 5, warmup: Int = 2, _ body: () -> Void) -> Duration {
    for _ in 0..<warmup { body() }
    var t: [Duration] = []
    for _ in 0..<samples { let s = ContinuousClock.now; body(); t.append(ContinuousClock.now - s) }
    t.sort(); return t[t.count / 2]
}
private func medianAsync(_ samples: Int = 5, warmup: Int = 1, _ body: () async throws -> Void) async rethrows -> Duration {
    for _ in 0..<warmup { try await body() }
    var t: [Duration] = []
    for _ in 0..<samples { let s = ContinuousClock.now; try await body(); t.append(ContinuousClock.now - s) }
    t.sort(); return t[t.count / 2]
}

/// A synthetic but valid single-file unified diff with `lines` body lines (context/added/removed mix).
private func bigDiff(lines: Int) -> String {
    var s = "diff --git a/f.txt b/f.txt\nindex 1111111..2222222 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1,\(lines) +1,\(lines) @@\n"
    for i in 0..<lines {
        switch i % 3 {
        case 0: s += " context line \(i)\n"
        case 1: s += "-old line \(i)\n"
        default: s += "+new line \(i)\n"
        }
    }
    return s
}

private func makePerfRepo() async throws -> (root: URL, repo: GitRepository) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-perf-\(UUID().uuidString)")
    let root = base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = GitRepository(root: root.path, isLinkedWorktree: false, gitPath: GitRepository.locateGit()!)
    await repo.setExtraEnvironment(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    try await repo.run(["init", "-q", "-b", "main"])
    try await repo.run(["config", "user.name", "Perf"]); try await repo.run(["config", "user.email", "perf@c2d.works"])
    return (root, repo)
}

@Suite(.serialized) struct PerformanceTests {

    // MARK: Correctness under load (always runs)

    @Test func parsesLargeDiffWithoutLosingLines() {
        let n = 30_000
        let files = GitRepository.parseUnifiedDiff(bigDiff(lines: n))
        #expect(files.count == 1)
        let parsed = files[0].hunks.reduce(0) { $0 + $1.lines.count }
        #expect(parsed == n, "every diff line must be parsed, none silently dropped (got \(parsed)/\(n))")
    }

    @Test func largeRepoStatusAndDiffAreCorrect() async throws {
        let (root, repo) = try await makePerfRepo()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // 400 committed files; modify 20 → status must report exactly those 20 (no drops, no invention).
        for i in 0..<400 { try "v0\n".write(to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8) }
        try await repo.stageAll(); _ = try await repo.commit(message: "seed")
        for i in 0..<20 { try "v1\n".write(to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8) }
        let s = try await repo.status()
        #expect(s.entries.count == 20 && s.entries.allSatisfy { $0.unstaged == .modified })
    }

    // MARK: Timing benchmarks (opt-in: C2D_PERF=1, Release)

    @Test(.enabled(if: perfEnabled)) func benchDiffParsing() {
        for n in [10_000, 50_000] {
            let diff = bigDiff(lines: n)
            let m = medianSync { _ = GitRepository.parseUnifiedDiff(diff) }
            print("PERF parseUnifiedDiff \(n) lines: median \(ms(m)) ms")
        }
    }

    @Test(.enabled(if: perfEnabled)) func benchTokenEstimate() {
        let text = String(repeating: "the quick brown fox jumps over the lazy dog 1234567890\n", count: 20_000)  // ~1 MB
        let m = medianSync { _ = TokenEstimator.estimate(text) }
        print("PERF TokenEstimator.estimate ~1MB: median \(ms(m)) ms")
    }

    @Test(.enabled(if: perfEnabled)) func benchGitDiffGeneration() async throws {
        let (root, repo) = try await makePerfRepo()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let base = (0..<20_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try base.write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try await repo.stageAll(); _ = try await repo.commit(message: "base")
        let edited = (0..<20_000).map { $0 % 5 == 0 ? "CHANGED \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"
        try edited.write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let m = try await medianAsync(5) { _ = try await repo.diff(path: "big.txt", staged: false) }
        print("PERF git diff generation 20k-line file (4k changes): median \(ms(m)) ms")
    }

    @Test(.enabled(if: perfEnabled)) func benchLargeRepoStatus() async throws {
        let (root, repo) = try await makePerfRepo()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for i in 0..<5_000 { try "v0\n".write(to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8) }
        try await repo.stageAll(); _ = try await repo.commit(message: "seed")
        for i in 0..<20 { try "v1\n".write(to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8) }
        // Cold (first) then warm (cached index + fs) — report both.
        let cold = ContinuousClock.now; _ = try await repo.status(); let coldD = ContinuousClock.now - cold
        let warm = try await medianAsync(5, warmup: 0) { _ = try await repo.status() }
        print("PERF git status 5000 tracked / 20 modified: cold \(ms(coldD)) ms, warm-median \(ms(warm)) ms")
    }
}
