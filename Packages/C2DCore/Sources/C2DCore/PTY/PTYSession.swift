import Darwin
import Dispatch
import Foundation
import Synchronization
import os

/// Lifecycle of a `PTYSession`. Transitions:
/// `created → running | failed`, `running → terminating | exited`, `terminating → exited`.
/// `exited` and `failed` are terminal.
public enum PTYSessionState: Sendable, Hashable {
    case created
    case running(pid: pid_t)
    case terminating(pid: pid_t)
    case exited(PTYExitStatus)
    case failed(PTYError)

    public var isFinished: Bool {
        switch self {
        case .exited, .failed: true
        default: false
        }
    }
}

/// One real shell/process behind a pseudo-terminal. Owns the PTY master, the
/// child pid and the exit watcher. Knows nothing about escape sequences or rendering.
///
/// Ownership and cleanup:
/// - `start()` allocates the PTY, spawns the child, and arms exit detection.
/// - `output` is a pull-based stream: a chunk is read from the kernel only when the
///   consumer asks for the next element, so the kernel's PTY buffer provides
///   backpressure to the child and nothing accumulates in this process. One consumer only.
/// - `terminate()` sends SIGHUP to the child, waits `gracePeriod`, then SIGKILL.
///   Only the direct child pid is ever signalled.
/// - `close()` releases the master descriptor (idempotent). If the child is still
///   running, losing its controlling terminal makes the kernel deliver SIGHUP to its
///   foreground process group; the exit watcher still observes the exit.
/// - The exit watcher is pid-based (`DispatchSource` + `waitpid`), not EOF-based, so a
///   grandchild that keeps the slave open cannot hide the shell's exit.
public actor PTYSession {
    public static let readChunkSize = 64 * 1024

    public let configuration: PTYSessionConfiguration
    public private(set) var state: PTYSessionState = .created
    public private(set) var pid: pid_t?

    /// Raw bytes from the child. Ends when the master reaches EOF or `close()` is called.
    public nonisolated let output: AsyncStream<Data>
    /// Every state transition, in order. Ends on `close()`.
    public nonisolated let stateChanges: AsyncStream<PTYSessionState>

    private let master = MasterHandle()
    private let stateContinuation: AsyncStream<PTYSessionState>.Continuation
    private var exitSource: DispatchSourceProcess?
    private var exitWaiters: [UUID: CheckedContinuation<PTYExitStatus?, Never>] = [:]
    private var reaped = false

    public init(configuration: PTYSessionConfiguration) {
        self.configuration = configuration
        let (states, cont) = AsyncStream<PTYSessionState>.makeStream(bufferingPolicy: .unbounded)
        self.stateChanges = states
        self.stateContinuation = cont
        let handle = master
        self.output = AsyncStream(unfolding: { await handle.read() })
    }

    deinit {
        master.close()
        exitSource?.cancel()
        stateContinuation.finish()
    }

    // MARK: Lifecycle

    /// Validates the configuration, allocates a PTY and spawns the child.
    /// On failure the session moves to `.failed` and every descriptor opened here is closed.
    public func start() throws(PTYError) {
        guard case .created = state else { throw PTYError.alreadyStarted }
        do {
            try configuration.validate()
        } catch {
            transition(to: .failed(error))
            throw error
        }

        var slaveFD: Int32 = -1
        var masterFD: Int32 = -1
        func fail(_ error: PTYError) -> PTYError {
            if slaveFD >= 0 { Darwin.close(slaveFD) }
            if masterFD >= 0 { Darwin.close(masterFD) }
            transition(to: .failed(error))
            return error
        }

        masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else { throw fail(.ptyAllocationFailed(step: "posix_openpt", errno: errno)) }
        guard grantpt(masterFD) == 0 else { throw fail(.ptyAllocationFailed(step: "grantpt", errno: errno)) }
        guard unlockpt(masterFD) == 0 else { throw fail(.ptyAllocationFailed(step: "unlockpt", errno: errno)) }
        guard let slaveCString = ptsname(masterFD) else { throw fail(.ptyAllocationFailed(step: "ptsname", errno: errno)) }
        let slavePath = String(cString: slaveCString)

        // The initial size must be set on the slave; the master rejects TIOCSWINSZ until the slave exists.
        slaveFD = open(slavePath, O_RDWR | O_NOCTTY)
        guard slaveFD >= 0 else { throw fail(.ptyAllocationFailed(step: "open-slave", errno: errno)) }
        var ws = winsize(ws_row: configuration.initialSize.rows, ws_col: configuration.initialSize.columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(slaveFD, TIOCSWINSZ, &ws) == 0 else { throw fail(.ptyAllocationFailed(step: "TIOCSWINSZ", errno: errno)) }

        // Child: new session, slave opened by path so it becomes the controlling tty,
        // stdin/stdout/stderr on the slave, cwd set, every other descriptor closed.
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, configuration.workingDirectory)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var allSignals = sigset_t(); sigfillset(&allSignals)
        var noSignals = sigset_t(); sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [configuration.executable] + configuration.arguments
        let envp = configuration.environment.map { "\($0.key)=\($0.value)" }
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnvp.forEach { free($0) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, configuration.executable, &actions, &attr, &cArgv, &cEnvp)
        Darwin.close(slaveFD)   // the parent must not keep the slave open, or the master never sees EOF
        slaveFD = -1
        guard rc == 0 else { throw fail(.spawnFailed(errno: rc)) }

        master.adopt(masterFD)
        pid = childPID
        transition(to: .running(pid: childPID))
        Log.pty.info("started pid=\(childPID, privacy: .public) exe=\(self.configuration.executable, privacy: .public)")
        armExitWatcher(pid: childPID)
    }

    /// Writes bytes to the child's terminal input. Blocks the actor only while the
    /// kernel input buffer is full (keystroke-sized writes never block).
    public func write(_ data: Data) throws(PTYError) {
        guard case .running = state, let fd = master.descriptor else { throw PTYError.notRunning }
        guard !data.isEmpty else { return }
        // Plain closure (no typed throw) so this compiles on the Swift 6.0/6.1 SDKs CI uses.
        let failure: Int32 = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += n
            }
            return 0
        }
        if failure != 0 { throw PTYError.writeFailed(errno: failure) }
    }

    /// Applies new dimensions to the PTY. The kernel delivers SIGWINCH to the foreground group.
    public func resize(_ size: TerminalSize) throws(PTYError) {
        guard size.rows > 0, size.columns > 0 else { throw PTYError.invalidSize }
        guard case .running = state, let fd = master.descriptor else { throw PTYError.notRunning }
        var ws = winsize(ws_row: size.rows, ws_col: size.columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(fd, TIOCSWINSZ, &ws) == 0 else { throw PTYError.resizeFailed(errno: errno) }
    }

    /// SIGHUP, then SIGKILL after `gracePeriod` if the child is still alive. Returns once the
    /// exit has been observed. Safe to call repeatedly or concurrently; later callers just wait.
    @discardableResult
    public func terminate(gracePeriod: Duration = .seconds(2)) async -> PTYExitStatus? {
        switch state {
        case .running(let pid):
            transition(to: .terminating(pid: pid))
            Log.pty.info("terminate pid=\(pid, privacy: .public) SIGHUP")
            kill(pid, SIGHUP)
            if let status = await waitForExit(timeout: gracePeriod) { return status }
            if case .terminating = state {
                Log.pty.notice("terminate pid=\(pid, privacy: .public) escalating to SIGKILL")
                kill(pid, SIGKILL)
            }
            return try? await waitForExit()
        case .terminating:
            return try? await waitForExit()
        case .exited(let status):
            return status
        case .created, .failed:
            return nil
        }
    }

    /// Suspends until the child has exited. Returns immediately if it already has.
    /// Throws `CancellationError` if the waiting task is cancelled; the child is unaffected.
    public func waitForExit() async throws -> PTYExitStatus {
        if case .exited(let status) = state { return status }
        let id = UUID()
        let result: PTYExitStatus? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if case .exited(let status) = state {
                    continuation.resume(returning: status)
                } else if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    exitWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelExitWaiter(id) }
        }
        guard let result else { throw CancellationError() }
        return result
    }

    private func cancelExitWaiter(_ id: UUID) {
        exitWaiters.removeValue(forKey: id)?.resume(returning: nil)
    }

    /// Releases the master descriptor and ends the `output` and `stateChanges` streams.
    /// Does not reap or wait for the child; use `terminate()` first if it must be stopped.
    public func close() {
        master.close()
        stateContinuation.finish()
        if state.isFinished { exitSource?.cancel(); exitSource = nil }
    }

    // MARK: Internals

    private func transition(to new: PTYSessionState) {
        state = new
        stateContinuation.yield(new)
    }

    private func armExitWatcher(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            // Bind strongly before spawning: Swift 6.1 (Xcode 16.4, the macOS 15 CI floor) rejects the weak
            // box capture inside the `sending` Task closure; a `let` of actor type is Sendable.
            guard let self else { return }
            Task { await self.reapIfExited() }
        }
        exitSource = source
        source.resume()
        // The source misses exits that happened before `resume()`; cover that window.
        reapIfExited()
    }

    private func reapIfExited() {
        guard !reaped, let pid else { return }
        var raw: Int32 = 0
        let r = waitpid(pid, &raw, WNOHANG)
        guard r == pid else { return }
        reaped = true
        let status: PTYExitStatus = (raw & 0x7f) == 0
            ? .exited(code: (raw >> 8) & 0xff)
            : .signaled(signal: raw & 0x7f)
        Log.pty.info("exit pid=\(pid, privacy: .public) status=\(String(describing: status), privacy: .public)")
        exitSource?.cancel()
        exitSource = nil
        transition(to: .exited(status))
        let waiters = exitWaiters.values
        exitWaiters.removeAll()
        waiters.forEach { $0.resume(returning: status) }
    }

    private func waitForExit(timeout: Duration) async -> PTYExitStatus? {
        await withTaskGroup(of: PTYExitStatus?.self) { group in
            group.addTask { try? await self.waitForExit() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Owns the PTY master descriptor. Guarantees the descriptor is closed only when no
/// read is in flight, so a blocking read can never touch a recycled fd number.
private final class MasterHandle: Sendable {
    private struct Guarded {
        var fd: Int32 = -1
        var closed = false
        var readInFlight = false
    }
    private let guarded = Mutex(Guarded())

    var descriptor: Int32? {
        guarded.withLock { $0.closed || $0.fd < 0 ? nil : $0.fd }
    }

    func adopt(_ fd: Int32) {
        guarded.withLock { $0.fd = fd }
    }

    /// Marks the handle closed. If a read is in flight the reader closes the fd on its way out.
    func close() {
        let fdToClose: Int32? = guarded.withLock { g in
            guard !g.closed else { return nil }
            g.closed = true
            return g.readInFlight ? nil : g.fd
        }
        if let fd = fdToClose, fd >= 0 { Darwin.close(fd) }
    }

    /// Reads one chunk off the actor on a global queue. `nil` means EOF, closed, or the
    /// consuming task was cancelled (the stream then ends; a cancelled consumer cannot resume).
    func read() async -> Data? {
        let cancelled = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: self.blockingRead(cancelled: cancelled))
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private func blockingRead(cancelled: CancelFlag) -> Data? {
        let fd: Int32? = guarded.withLock { g in
            guard !g.closed, g.fd >= 0, !g.readInFlight else { return nil }
            g.readInFlight = true
            return g.fd
        }
        guard let fd else { return nil }
        defer {
            let fdToClose: Int32? = guarded.withLock { g in
                g.readInFlight = false
                return g.closed ? g.fd : nil
            }
            if let fdToClose, fdToClose >= 0 { Darwin.close(fdToClose) }
        }

        var buffer = [UInt8](repeating: 0, count: PTYSession.readChunkSize)
        while true {
            // ponytail: 100 ms poll so close() is noticed promptly; swap for DispatchIO if wake-ups ever matter.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if guarded.withLock({ $0.closed }) || cancelled.isSet { return nil }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { return Data(buffer[0..<n]) }
            if n < 0 && errno == EINTR { continue }
            return nil   // 0 = EOF; EIO after the slave side is gone
        }
    }
}

private final class CancelFlag: Sendable {
    private let flag = Mutex(false)
    var isSet: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}
