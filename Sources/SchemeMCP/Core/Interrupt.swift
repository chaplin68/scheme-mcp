import Foundation

/// Pids of the children this process started, read by the signal handler.
///
/// File-scope `var`s with trivial initial values, not `static let`s. A `static let` is
/// initialised lazily, so the first read from inside a handler would run `swift_once` and
/// `malloc` — the two things a handler must not do, and the reason this rewrite exists.
private let interruptCapacity = 8
nonisolated(unsafe) private var interruptPids = [sig_atomic_t](repeating: 0, count: interruptCapacity)
/// Set when a full-screen interface is up, so the handler also puts the terminal back.
nonisolated(unsafe) private var interruptRestoresScreen: sig_atomic_t = 0

/// Kills the child processes this server started when it is itself told to stop, so it never leaves
/// an orphaned xcodebuild or log stream behind, and hands the terminal back as it goes.
///
/// A signal handler may not allocate, take a lock, or call into the Swift runtime. It may call
/// `kill`, `write` and `_exit`, and read a `sig_atomic_t`. So the handler does only that; the
/// `ProcessHandle`s are kept alongside for the ordinary paths.
///
/// One owner for every signal. The dashboard used to install its own SIGTERM and SIGHUP
/// handlers to restore the screen, and whichever of the two was installed second silently
/// replaced the other — leaving either an orphaned build or a shell stranded on the alternate
/// buffer in raw mode.
enum Interrupt {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handles: [(slot: Int, handle: ProcessHandle)] = []
    nonisolated(unsafe) private static var installed = false

    /// Everything the handler writes, pre-rendered: show the cursor, and leave the alternate
    /// screen when one is up.
    private static let restoreCursor: [UInt8] = Array("\u{1B}[?25h\n".utf8)
    private static let restoreScreen: [UInt8] = Array("\u{1B}[?1049l\u{1B}[?25h".utf8)

    /// Called by the dashboard instead of installing handlers of its own.
    static func register(_ handle: ProcessHandle) {
        install()
        lock.lock()
        // Slots are tracked by index, not by pid: clearing by value would zero a new child that
        // had been handed the old one's number, and leave a reaped pid armed until then.
        if let slot = (0..<interruptCapacity).first(where: { index in
            !handles.contains { $0.slot == index }
        }) {
            handles.append((slot, handle))
            interruptPids[slot] = sig_atomic_t(handle.processIdentifier)
        }
        lock.unlock()
    }

    /// Drops a process that has exited, so its number is not signalled after being reused.
    static func forget(_ handle: ProcessHandle) {
        lock.lock()
        if let index = handles.firstIndex(where: { $0.handle === handle }) {
            interruptPids[handles[index].slot] = 0
            handles.remove(at: index)
        }
        lock.unlock()
    }

    private static func install() {
        lock.lock()
        let needsInstall = !installed
        lock.unlock()
        guard needsInstall else { return }

        // Warm every global the handler reads, before a signal can reach it.
        _ = interruptPids.count
        _ = restoreCursor.count
        _ = restoreScreen.count

        // SIGTERM and SIGHUP as well as SIGINT. Ctrl-C reaches the child through the terminal's
        // process group anyway; a `kill` of this process and a closed pipe did not.
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber) { received in
                for slot in 0..<interruptCapacity where interruptPids[slot] > 0 {
                    kill(pid_t(interruptPids[slot]), SIGTERM)
                }
                let bytes = interruptRestoresScreen == 1 ? Interrupt.restoreScreen : Interrupt.restoreCursor
                _ = bytes.withUnsafeBufferPointer { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
                _exit(128 + received)
            }
        }

        // Published last: a concurrent register must not skip installing because a handler it
        // cannot see yet was announced.
        lock.lock()
        installed = true
        lock.unlock()
    }
}
