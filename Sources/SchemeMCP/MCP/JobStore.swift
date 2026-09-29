import Foundation

/// What a job is doing, from the caller's point of view.
///
/// An MCP tool call cannot wait for a build: Claude Code moves a call that runs past two
/// minutes into a background task, and a cold build routinely takes longer than that. So the
/// tools start work and return an id, and the agent polls this state.
enum JobState: String, Codable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    var isFinished: Bool {
        switch self {
        case .queued, .running: return false
        case .succeeded, .failed, .cancelled: return true
        }
    }
}

enum JobKind: String, Codable {
    case build
    case test
    case run
}

/// A snapshot of one job. Deliberately a value type: the store hands these out under its lock
/// so a caller can never read a half-updated job.
struct JobSnapshot: Codable {
    let id: String
    let kind: JobKind
    let state: JobState
    let device: String
    let scheme: String
    let startedAt: Date
    let finishedAt: Date?
    /// Populated once the job finishes.
    let succeeded: Bool?
    let errors: [String]
    let warningCount: Int
    let failedTests: [String]
    let logPath: String?
    /// What xcodebuild is doing right now, when it has said. Absent early on — which is
    /// exactly the stretch a cold simulator boot occupies, with no output at all.
    let phase: String?
    /// The job holding the queue, when this one has not started. Without it, `queued` looks
    /// indistinguishable from stuck.
    let queuedBehind: String?
    /// Set when the job could not even be started, e.g. no matching device.
    let failureReason: String?

    var elapsedSeconds: Double {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// Registry of background jobs, and the queue that runs them one at a time.
///
/// Serialised on purpose. Two xcodebuilds against the same derived data, or two installs to the
/// same device, interfere with each other, and an agent that fires build and test together would
/// otherwise get results that depend on timing.
final class JobStore {
    /// Guards this object's own state. Every read and write of `jobs` goes through it, so the
    /// store would stay correct even if the queue below ran jobs concurrently.
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    /// Serialises the *work*, which is a separate concern from the lock: what cannot overlap is
    /// not this dictionary but the things outside the process — derived data and the device.
    private let queue = DispatchQueue(label: "scheme-mcp.jobs")
    /// Bounded so a chatty build cannot grow the process without limit; the full log is always
    /// on disk, and `logPath` says where.
    static let tailLimit = 500
    private static let historyLimit = 50

    private final class Job {
        let id: String
        let kind: JobKind
        let device: String
        let scheme: String
        let startedAt = Date()
        var state: JobState = .queued
        var finishedAt: Date?
        var report: BuildReport?
        var failureReason: String?
        var tail: [String] = []
        var handle: ProcessHandle?
        var cancelled = false
        /// Set by the work itself for the stretches xcodebuild knows nothing about — an app
        /// that has been launched and is simply running produces no build phases, and the last
        /// one it did emit would otherwise sit there looking like a job stuck on "Signing".
        var stage: String?
        /// Whether the work closure has returned. Distinct from the state: a cancelled job is
        /// over as far as the caller is concerned, but it may still be holding the serial queue
        /// while the step it was in runs to completion.
        var workFinished = false

        init(id: String, kind: JobKind, device: String, scheme: String) {
            self.id = id
            self.kind = kind
            self.device = device
            self.scheme = scheme
        }
    }

    /// Registers a job and queues `work`. Returns the id immediately — the point of the whole
    /// design is that the caller never blocks here.
    func submit(
        kind: JobKind,
        device: String,
        scheme: String,
        work: @escaping (JobHandle) -> Void
    ) -> String {
        let id = "\(kind.rawValue)-\(UUID().uuidString.prefix(8))"
        let job = Job(id: id, kind: kind, device: device, scheme: scheme)

        lock.lock()
        jobs[id] = job
        order.append(id)
        trimHistoryLocked()
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            // A job cancelled while still queued must not start: by the time the queue reaches
            // it the caller may already have been told it was cancelled.
            self.lock.lock()
            let skip = job.cancelled
            if !skip { job.state = .running }
            self.lock.unlock()
            guard !skip else {
                self.lock.lock(); job.workFinished = true; self.lock.unlock()
                return
            }

            work(JobHandle(store: self, id: id))
            self.lock.lock()
            job.workFinished = true
            self.lock.unlock()
        }
        return id
    }

    /// The half of the store a running job is allowed to touch.
    struct JobHandle {
        let store: JobStore
        let id: String

        func attach(report: BuildReport) { store.attach(report: report, to: id) }
        func attach(process: ProcessHandle) { store.attach(process: process, to: id) }
        func append(line: String) { store.append(line: line, to: id) }
        func stage(_ stage: String) { store.setStage(stage, on: id) }
        func finish(succeeded: Bool, reason: String? = nil) {
            store.finish(id: id, succeeded: succeeded, reason: reason)
        }
        var isCancelled: Bool { store.isCancelled(id) }
    }

    // MARK: - Reads

    func snapshot(_ id: String) -> JobSnapshot? {
        lock.withLock { jobs[id].map(snapshotLocked) }
    }

    func all() -> [JobSnapshot] {
        lock.withLock { order.compactMap { jobs[$0] }.map(snapshotLocked) }
    }

    /// The last `limit` lines of raw output, newest last, and how many the buffer holds in
    /// total, so a caller can tell whether it is looking at everything there is.
    func tail(_ id: String, limit: Int) -> (lines: [String], buffered: Int)? {
        lock.withLock {
            jobs[id].map { (Array($0.tail.suffix(max(0, limit))), $0.tail.count) }
        }
    }

    /// Whether the buffer has started discarding its oldest lines. The full log is on disk.
    func hasDiscardedOldestLines(_ id: String) -> Bool {
        lock.withLock { (jobs[id]?.tail.count ?? 0) >= Self.tailLimit }
    }

    private func snapshotLocked(_ job: Job) -> JobSnapshot {
        return Self.snapshot(job, queuedBehind: predecessorLocked(of: job))
    }

    /// The job whose finishing lets this one start: the nearest unfinished one ahead of it in
    /// the queue, not merely whichever is running. With two jobs waiting, naming the running
    /// one tells the second that it is next when it is not, and it is still waiting after that
    /// job finishes.
    private func predecessorLocked(of job: Job) -> String? {
        guard job.state == .queued, let index = order.firstIndex(of: job.id) else { return nil }
        // Whoever still holds the queue, terminal or not. A cancelled job whose work has not
        // returned is still the reason this one cannot start, and saying nothing puts the
        // caller back in front of a `queued` it cannot tell from stuck.
        return order[..<index].reversed()
            .compactMap { jobs[$0] }
            .first { !$0.workFinished }?
            .id
    }

    private static func snapshot(_ job: Job, queuedBehind: String? = nil) -> JobSnapshot {
        let report = job.report
        return JobSnapshot(
            id: job.id,
            kind: job.kind,
            state: job.state,
            device: job.device,
            scheme: job.scheme,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            succeeded: job.state.isFinished ? (job.state == .succeeded) : nil,
            // Errors are the whole point of the call, so they are returned in full; warnings
            // are counted, exactly as the CLI reports them.
            // Deduplicated. xcodebuild re-emits the same diagnostic once per target pass, so a
            // raw count answers "how many passes saw a problem", which is not the question, and
            // the same error arriving three times reads as three errors.
            errors: report?.uniqueDiagnostics(severity: .error)
                .map { [$0.location, $0.message].compactMap { $0 }.joined(separator: ": ") } ?? [],
            warningCount: report?.uniqueDiagnostics(severity: .warning).count ?? 0,
            failedTests: report?.failedTests.map { "\($0.suite).\($0.name)" } ?? [],
            logPath: report?.logURL?.path,
            phase: job.state == .running ? (job.stage ?? report?.currentPhase) : nil,
            queuedBehind: queuedBehind,
            failureReason: job.failureReason
        )
    }

    // MARK: - Writes

    private func attach(report: BuildReport, to id: String) {
        lock.withLock { jobs[id]?.report = report }
    }

    private func attach(process: ProcessHandle, to id: String) {
        lock.lock()
        jobs[id]?.handle = process
        let alreadyCancelled = jobs[id]?.cancelled ?? false
        lock.unlock()
        // Cancelling races with launching. Terminating here covers the case where the cancel
        // arrived after the check but before the process existed to kill.
        if alreadyCancelled { process.terminate() }
    }

    private func setStage(_ stage: String, on id: String) {
        lock.lock()
        jobs[id]?.stage = stage
        lock.unlock()
    }

    private func append(line: String, to id: String) {
        lock.lock()
        if let job = jobs[id] {
            job.tail.append(line)
            if job.tail.count > Self.tailLimit {
                job.tail.removeFirst(job.tail.count - Self.tailLimit)
            }
        }
        lock.unlock()
    }

    private func isCancelled(_ id: String) -> Bool {
        lock.withLock { jobs[id]?.cancelled ?? false }
    }

    private func finish(id: String, succeeded: Bool, reason: String?) {
        lock.lock()
        if let job = jobs[id], !job.state.isFinished {
            // `cancel` already set the terminal state, and this guard has bailed by then, so
            // there is no cancelled case to consider here.
            job.state = succeeded ? .succeeded : .failed
            job.finishedAt = Date()
            job.failureReason = reason ?? job.failureReason
        }
        lock.unlock()
    }

    /// Marks a job cancelled and kills its process if one is running. Returns the new state,
    /// or nil when there is no such job.
    @discardableResult
    func cancel(_ id: String) -> JobState? {
        lock.lock()
        guard let job = jobs[id] else { lock.unlock(); return nil }
        guard !job.state.isFinished else {
            let state = job.state
            lock.unlock()
            return state
        }
        job.cancelled = true
        let handle = job.handle
        // Terminal immediately, for a running job as much as a queued one. Waiting for the
        // work to call `finish` leaves the job running for good whenever the work returns
        // without finishing — which is what a cancellation check at the top of a step does.
        // The process is still being killed, but the answer to "is this job over" is yes.
        job.state = .cancelled
        job.finishedAt = Date()
        let state = job.state
        lock.unlock()
        handle?.terminate()
        return state
    }

    /// Keeps the newest jobs only. Without this a long-lived server accumulates every build it
    /// has ever run, along with its tail buffer.
    private func trimHistoryLocked() {
        guard order.count > Self.historyLimit else { return }
        let excess = order.count - Self.historyLimit
        // Gated on the work having returned, not on the state. A cancelled job is terminal at
        // once but may still be running: evicting it there loses the cancelled flag, so the
        // step that checks it carries on, launches the app, and blocks the queue for good.
        for id in order.prefix(excess) where jobs[id]?.workFinished ?? false {
            jobs.removeValue(forKey: id)
        }
        order = order.filter { jobs[$0] != nil }
    }
}
