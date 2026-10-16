import Darwin
import Foundation
import Testing
@testable import C2DCore

// MARK: - Helpers

private let testEnv = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory(), "LANG": "C"]

private func sh(_ script: String, size: TerminalSize = TerminalSize(rows: 24, columns: 80)) -> PTYSessionConfiguration {
    PTYSessionConfiguration(executable: "/bin/sh", arguments: ["-c", script], environment: testEnv,
                            workingDirectory: NSTemporaryDirectory(), initialSize: size)
}

private func program(_ path: String, _ args: [String] = []) -> PTYSessionConfiguration {
    PTYSessionConfiguration(executable: path, arguments: args, environment: testEnv, workingDirectory: NSTemporaryDirectory())
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ limit: Duration = .seconds(15), _ body: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask { try await Task.sleep(for: limit); throw TimeoutError() }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Runs `body`, then terminates and closes the session on every exit path.
func withSession<T: Sendable>(_ configuration: PTYSessionConfiguration, limit: Duration = .seconds(15),
                              _ body: @Sendable @escaping (PTYSession) async throws -> T) async throws -> T {
    let session = PTYSession(configuration: configuration)
    do {
        let result = try await withTimeout(limit) { try await body(session) }
        await session.terminate(gracePeriod: .milliseconds(500))
        await session.close()
        return result
    } catch {
        await session.terminate(gracePeriod: .milliseconds(500))
        await session.close()
        throw error
    }
}

/// Owns the single output iterator and accumulates decoded text across calls.
/// Not thread-safe by design: tests use one collector from one task at a time.
final class OutputCollector: @unchecked Sendable {
    private var iterator: AsyncStream<Data>.Iterator
    private(set) var text = ""
    private(set) var bytes = 0
    private(set) var chunks = 0
    private(set) var largestChunk = 0

    init(_ session: PTYSession) { iterator = session.output.makeAsyncIterator() }

    private func next() async -> Data? { await iterator.next() }

    /// Reads until `predicate` matches the accumulated text or the stream ends.

    @discardableResult
    func read(until predicate: @Sendable (String) -> Bool) async -> String {
        while !predicate(text), let chunk = await next() {
            text += String(decoding: chunk, as: UTF8.self)
            account(chunk.count)
        }
        return text
    }

    func contains(_ s: String) async -> String { await read { $0.contains(s) } }

    /// Drains to EOF counting bytes only; `pause` throttles the consumer to exercise backpressure.
    func drain(pause: Duration? = nil) async {
        while let chunk = await next() {
            account(chunk.count)
            if let pause { try? await Task.sleep(for: pause) }
        }
    }

    private func account(_ n: Int) { bytes += n; chunks += 1; largestChunk = max(largestChunk, n) }
}

/// Counts only PTY-related descriptors (master `/dev/ptmx`, slave `/dev/ttys*`), so suites that
/// run in parallel and open ordinary files or pipes cannot perturb the leak checks.
func openDescriptorCount() -> Int {
    var count = 0
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    for fd in 0..<getdtablesize() where fcntl(fd, F_GETFD) >= 0 {
        if fcntl(fd, F_GETPATH, &buffer) == 0 {
            let path = String(cString: buffer)
            if path.hasPrefix("/dev/ptmx") || path.hasPrefix("/dev/ttys") { count += 1 }
        }
    }
    return count
}

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

func processExists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

// MARK: - Integration tests (real /bin/sh and /bin/cat through a real PTY)

@Suite(.serialized) struct PTYSessionTests {

    @Test func shellStartsWithControllingTerminalAndRunsCommand() async throws {
        try await withSession(sh("echo hello-c2d; tty; [ -t 0 ] && echo isatty; pwd; echo END")) { session in
            try await session.start()
            guard case .running(let pid) = await session.state else { Issue.record("not running"); return }
            #expect(pid > 0)
            let out = await OutputCollector(session).contains("END")
            #expect(out.contains("hello-c2d"))
            #expect(out.contains("/dev/ttys"))
            #expect(out.contains("isatty"))
            let tmpLeaf = NSTemporaryDirectory().split(separator: "/").last.map(String.init) ?? "T"
            #expect(out.contains("/\(tmpLeaf)\r\n"))
            #expect(try await session.waitForExit() == .exited(code: 0))
        }
    }

    // Uses `sh` (not `zsh -i`): under a pty without job control, zsh's ZLE flushes typed-ahead input, so
    // `cd` is dropped non-deterministically in the harness. The interactive-zsh path is covered at runtime
    // (docs/evidence/terminal-process-context.png shows "./src" and "Running · sleep" from a real zsh -l).
    @Test func processContextTracksDirectoryAndForegroundCommand() async throws {
        try await withSession(program("/bin/sh", ["-i"])) { session in
            try await session.start()
            let collector = OutputCollector(session)
            await collector.read { $0.contains("$ ") }
            try await session.write(Data("cd /private/tmp\n".utf8))
            var cwd: String?
            for _ in 0..<50 { cwd = await session.processContext()?.currentDirectory; if cwd == "/private/tmp" { break }; try await Task.sleep(for: .milliseconds(100)) }
            #expect(cwd == "/private/tmp")
            #expect(await session.processContext()?.foregroundCommand == nil, "idle shell has no foreground command")
            try await session.write(Data("sleep 30\n".utf8))
            var fg: String?
            for _ in 0..<50 { fg = await session.processContext()?.foregroundCommand; if fg == "sleep" { break }; try await Task.sleep(for: .milliseconds(100)) }
            #expect(fg == "sleep")
            _ = await session.terminate(gracePeriod: .milliseconds(200))
            #expect(await session.processContext() == nil, "no context once the session ended")
        }
    }

    @Test func inputReachesChildAndIsEchoedBack() async throws {
        try await withSession(program("/bin/cat")) { session in
            try await session.start()
            try await session.write(Data())   // empty write is a no-op, not a crash
            try await session.write(Data("ping-from-test\n".utf8))
            let collector = OutputCollector(session)
            // tty echo gives one copy, cat gives the second
            let out = await collector.read { $0.components(separatedBy: "ping-from-test").count >= 3 }
            #expect(out.contains("ping-from-test\r\n"))
            try await session.write(Data([0x04]))   // ^D → EOF for cat
            #expect(try await session.waitForExit() == .exited(code: 0))
        }
    }

    @Test func outputIsCompleteAndOrdered() async throws {
        try await withSession(sh("seq 1 500")) { session in
            try await session.start()
            let out = await OutputCollector(session).contains("\r\n500\r\n")
            let numbers = out.split(whereSeparator: \.isNewline).compactMap { Int($0) }
            #expect(numbers == Array(1...500))
        }
    }

    @Test func exitCodeAndSignalAreReported() async throws {
        try await withSession(sh("exit 7")) { session in
            try await session.start()
            #expect(try await session.waitForExit() == .exited(code: 7))
            #expect(await session.state == .exited(.exited(code: 7)))
        }
        try await withSession(sh("kill -TERM $$")) { session in
            try await session.start()
            #expect(try await session.waitForExit() == .signaled(signal: SIGTERM))
        }
    }

    @Test func initialSizeIsAppliedAndResizePropagates() async throws {
        try await withSession(program("/bin/sh", [], ).withSize(rows: 31, columns: 97)) { session in
            try await session.start()
            let collector = OutputCollector(session)
            try await session.write(Data("stty size\n".utf8))
            let first = await collector.contains("31 97")
            #expect(first.contains("31 97"))
            try await session.resize(TerminalSize(rows: 44, columns: 123))
            try await session.write(Data("stty size\n".utf8))
            let second = await collector.contains("44 123")
            #expect(second.contains("44 123"))
            try await session.write(Data("exit\n".utf8))
            #expect(try await session.waitForExit() == .exited(code: 0))
            await #expect(throws: PTYError.notRunning) { try await session.resize(TerminalSize(rows: 1, columns: 1)) }
        }
    }

    @Test func invalidConfigurationFailsWithoutSpawning() async throws {
        let before = openDescriptorCount()
        let session = PTYSession(configuration: sh("true").withWorkingDirectory("/no/such/dir"))
        await #expect(throws: PTYError.invalidWorkingDirectory(path: "/no/such/dir")) { try await session.start() }
        #expect(await session.state == .failed(.invalidWorkingDirectory(path: "/no/such/dir")))
        #expect(await session.pid == nil)
        await #expect(throws: PTYError.alreadyStarted) { try await session.start() }
        await #expect(throws: PTYError.notRunning) { try await session.write(Data([0x0a])) }
        #expect(await session.terminate() == nil)
        await session.close()
        #expect(openDescriptorCount() == before)
    }

    @Test func spawnFailureLeaksNothing() async throws {
        let before = openDescriptorCount()
        // A directory passes the X_OK pre-check but cannot be exec'd, so posix_spawn itself fails
        // after the PTY pair has been allocated — the path that must release both descriptors.
        let session = PTYSession(configuration: program("/usr/bin"))
        await #expect(throws: PTYError.spawnFailed(errno: EACCES)) { try await session.start() }
        #expect(await session.state == .failed(.spawnFailed(errno: EACCES)))
        #expect(await session.pid == nil)
        #expect(openDescriptorCount() == before)
        await session.close()
        #expect(openDescriptorCount() == before)
    }

    @Test func terminateEscalatesToKillAndCleansUp() async throws {
        let before = openDescriptorCount()
        // bash execs a lone final command and resets traps first, so keep the shell alive as the
        // signal target and make each child short-lived (nothing outlives the test by more than 1 s).
        let session = PTYSession(configuration: sh("trap '' HUP; echo ready; while :; do sleep 1; done"))
        try await session.start()
        let pid = await session.pid!
        _ = await OutputCollector(session).contains("ready")   // the trap must be installed before SIGHUP arrives
        let started = ContinuousClock.now
        let status = try await withTimeout { await session.terminate(gracePeriod: .milliseconds(300)) }
        #expect(status == .signaled(signal: SIGKILL))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await session.state == .exited(.signaled(signal: SIGKILL)))
        #expect(!processExists(pid))
        await session.close()
        #expect(openDescriptorCount() == before)

        // A cooperative child goes on SIGHUP alone.
        try await withSession(sh("sleep 30")) { session in
            try await session.start()
            #expect(await session.terminate(gracePeriod: .seconds(2)) == .signaled(signal: SIGHUP))
        }
    }

    @Test func repeatedTerminateAndCloseAreSafe() async throws {
        let before = openDescriptorCount()
        let session = PTYSession(configuration: sh("sleep 30"))
        try await session.start()
        let first = await session.terminate(gracePeriod: .seconds(2))
        let second = await session.terminate()
        #expect(first == second)
        await session.close()
        await session.close()
        #expect(await session.terminate() == first)
        var states: [PTYSessionState] = []
        for await s in session.stateChanges { states.append(s) }   // finished by close()
        #expect(states.filter { if case .exited = $0 { true } else { false } }.count == 1)
        #expect(openDescriptorCount() == before)
    }

    @Test func outputDeliveryDoesNotBlockMainThread() async throws {
        try await withSession(sh("head -c 20000000 /dev/zero | tr '\\0' x")) { session in
            try await session.start()
            let collector = OutputCollector(session)
            let drain = Task { await collector.drain() }
            var worstHop: Duration = .zero
            for _ in 0..<30 {
                let t0 = ContinuousClock.now
                await MainActor.run { _ = 1 }
                worstHop = max(worstHop, ContinuousClock.now - t0)
                try await Task.sleep(for: .milliseconds(5))
            }
            await drain.value
            // Timing-sensitive: a heavily loaded shared CI runner could exceed this.
            #expect(worstHop < .milliseconds(100), "worst main-actor hop \(worstHop)")
            #expect(collector.bytes == 20_000_000)
        }
    }

    @Test func largeOutputWithSlowConsumerIsBoundedAndLossless() async throws {
        let total = 8_000_000   // the pty hands out ~1 KiB chunks, so this is ~8k consumer wake-ups
        // ~10 s locally; timing-sensitive on slower CI runners, hence the larger budget.
        try await withSession(sh("head -c \(total) /dev/zero | tr '\\0' y"), limit: .seconds(60)) { session in
            try await session.start()
            let collector = OutputCollector(session)
            let rssBefore = residentBytes()
            await collector.drain(pause: .microseconds(100))
            let rssAfter = residentBytes()
            #expect(collector.bytes == total)
            #expect(collector.largestChunk <= PTYSession.readChunkSize)
            let growth = Int64(rssAfter) - Int64(rssBefore)
            #expect(growth < 16_000_000, "resident growth \(growth) bytes")
            #expect(try await session.waitForExit() == .exited(code: 0))
        }
    }

    @Test func concurrentLifecycleOperationsConverge() async throws {
        let before = openDescriptorCount()
        let session = PTYSession(configuration: sh("sleep 30"))
        try await session.start()
        let pid = await session.pid!
        let results = try await withTimeout { () -> [PTYExitStatus?] in
            await withTaskGroup(of: PTYExitStatus?.self) { group in
                for _ in 0..<5 { group.addTask { await session.terminate(gracePeriod: .seconds(2)) } }
                group.addTask { try? await session.waitForExit() }
                group.addTask { try? await Task.sleep(for: .milliseconds(50)); await session.close(); return nil }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        let statuses = Set(results.compactMap { $0 })
        #expect(statuses.count == 1)
        #expect(!processExists(pid))
        var exits = 0
        for await s in session.stateChanges { if case .exited = s { exits += 1 } }
        #expect(exits == 1)
        await session.close()
        #expect(openDescriptorCount() == before)
    }

    @Test func closeDoesNotStopTheChildButTerminateStillWorks() async throws {
        // close() only releases the master; with no foreground process group set by the child,
        // the kernel does not hang it up. Stopping the child is terminate()'s job, before or after close().
        let session = PTYSession(configuration: sh("sleep 30"))
        try await session.start()
        let pid = await session.pid!
        await session.close()
        try await Task.sleep(for: .milliseconds(200))
        #expect(processExists(pid))
        #expect(await session.state == .running(pid: pid))
        let status = try await withTimeout(.seconds(5)) { await session.terminate(gracePeriod: .seconds(2)) }
        #expect(status == .signaled(signal: SIGHUP))
        #expect(!processExists(pid))
    }
}

private extension PTYSessionConfiguration {
    func withSize(rows: UInt16, columns: UInt16) -> Self {
        var c = self; c.initialSize = TerminalSize(rows: rows, columns: columns); return c
    }
    func withWorkingDirectory(_ path: String) -> Self {
        var c = self; c.workingDirectory = path; return c
    }
}
