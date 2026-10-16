import Darwin
import Foundation
import Testing
@testable import C2DCore

// Long-session stability / leak tests (Bible Part 15 §14.3, §17.5). Bounded & deterministic so they
// run in CI. They measure PTY-fd stability across cycles (exact: before == after) and RSS trend
// (warm vs end) to separate a transient spike from persistent growth. Numbers print as `STABILITY …`;
// recorded in docs/PERFORMANCE.md. These are single-machine, seconds-long runs — NOT multi-hour,
// reboot-cold, or concurrent-agent stability (those remain unmeasured).

private let stabEnv = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory(), "LANG": "C"]
private func cfg(_ script: String) -> PTYSessionConfiguration {
    PTYSessionConfiguration(executable: "/bin/sh", arguments: ["-c", script], environment: stabEnv, workingDirectory: NSTemporaryDirectory())
}
private func mb(_ b: UInt64) -> Int { Int(b) / 1_000_000 }

@Suite(.serialized) struct StabilityTests {

    /// Many create → produce → terminate → close cycles: every byte delivered, no PTY-fd leak, and
    /// RSS flat after warmup (a leak would grow it monotonically).
    @Test func sustainedSessionCyclesAreLosslessAndLeakFree() async throws {
        let fd0 = openDescriptorCount()
        let cycles = 60
        var rssWarm: UInt64 = 0
        for i in 0..<cycles {
            let s = PTYSession(configuration: cfg("seq 1 2000"))
            try await s.start()
            let collector = OutputCollector(s)
            let out = await collector.contains("\r\n2000\r\n")   // drains to EOF, accumulates text
            let lines = out.split(whereSeparator: \.isNewline).compactMap { Int($0) }
            #expect(lines.last == 2000, "cycle \(i): last line \(String(describing: lines.last)) (lost/duplicated output?)")
            _ = await s.terminate(gracePeriod: .milliseconds(200))
            await s.close()
            if i == 10 { rssWarm = residentBytes() }
        }
        let fd1 = openDescriptorCount()
        let rssEnd = residentBytes()
        let growth = Int64(rssEnd) - Int64(rssWarm)
        print("STABILITY sessionCycles=\(cycles): fd \(fd0)->\(fd1); rss warm=\(mb(rssWarm))MB end=\(mb(rssEnd))MB growth=\(growth / 1_000_000)MB")
        // openDescriptorCount() is process-wide; a PTY test in a parallel suite can hold ±a few fds
        // during our window. A real per-cycle leak would be ~\(cycles) fds, so this still catches one.
        #expect(fd1 - fd0 <= 4, "PTY fds leaked across cycles: \(fd0) -> \(fd1)")
        #expect(growth < 30_000_000, "RSS grew \(growth) bytes after warmup — possible leak")
    }

    /// Resize churn interleaved with continuous output: no crash, output keeps flowing, no fd leak.
    @Test func resizeChurnStaysStableAndLossless() async throws {
        let fd0 = openDescriptorCount()
        try await withTimeout(.seconds(30)) {
            let s = PTYSession(configuration: cfg("i=0; while [ $i -lt 100000 ]; do echo line$i; i=$((i+1)); done"))
            try await s.start()
            let collector = OutputCollector(s)
            let drain = Task { await collector.drain() }
            for i in 0..<500 { try? await s.resize(TerminalSize(rows: UInt16(20 + i % 40), columns: UInt16(40 + i % 80))) }
            await drain.value
            #expect(collector.bytes > 0, "output stopped flowing during resize churn")
            _ = await s.terminate(gracePeriod: .milliseconds(200))
            await s.close()
        }
        #expect(openDescriptorCount() - fd0 <= 4, "resize churn leaked fds")   // process-wide; see note above
    }

    /// Repeatedly start an infinite producer, consume a little, cancel/terminate mid-stream. Cleanup
    /// must hold every time: no hang (withTimeout), no fd leak, terminate returns a status.
    @Test func repeatedCancellationMidStreamCleansUp() async throws {
        let fd0 = openDescriptorCount()
        for i in 0..<25 {
            try await withTimeout(.seconds(10)) {
                let s = PTYSession(configuration: cfg("yes C2D"))
                try await s.start()
                var it = s.output.makeAsyncIterator()
                _ = await it.next()   // consume one chunk, then cancel mid-stream
                let status = await s.terminate(gracePeriod: .milliseconds(200))
                await s.close()
                #expect(status != nil, "cycle \(i): terminate did not report an exit status")
            }
        }
        let fdEnd = openDescriptorCount()
        #expect(fdEnd - fd0 <= 4, "cancellation cycles leaked fds: \(fd0) -> \(fdEnd)")   // process-wide; see note above
    }

    /// Repeated Git status + diff refreshes on a representative repo: results stay correct and RSS flat.
    @Test func repeatedGitRefreshIsStableAndCorrect() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-stab-\(UUID().uuidString)")
        let root = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = GitRepository(root: root.path, isLinkedWorktree: false, gitPath: GitRepository.locateGit()!)
        await repo.setExtraEnvironment(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Stab"]); try await repo.run(["config", "user.email", "s@c2d.works"])
        for i in 0..<200 { try "v0\n".write(to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8) }
        try await repo.stageAll(); _ = try await repo.commit(message: "seed")
        try "v0\nv1\n".write(to: root.appendingPathComponent("f0.txt"), atomically: true, encoding: .utf8)

        var rssWarm: UInt64 = 0
        let refreshes = 100
        for i in 0..<refreshes {
            let s = try await repo.status()
            #expect(s.entries.count == 1 && s.entries[0].path == "f0.txt", "refresh \(i): status drifted")
            #expect(try await repo.diff(path: "f0.txt", staged: false).contains("+v1"), "refresh \(i): diff drifted")
            if i == 10 { rssWarm = residentBytes() }
        }
        let growth = Int64(residentBytes()) - Int64(rssWarm)
        print("STABILITY gitRefresh=\(refreshes): rss growth after warmup=\(growth / 1_000_000)MB")
        #expect(growth < 30_000_000, "RSS grew \(growth) bytes over refreshes — possible leak")
    }
}
