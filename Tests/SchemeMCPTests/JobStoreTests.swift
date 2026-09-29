import XCTest
@testable import SchemeMCP

/// The job model exists because an MCP call cannot wait for a build. These pin down the parts
/// an agent depends on: that an id is usable the instant it is handed out, that cancelling
/// works before the job starts as well as during it, and that neither history nor the tail
/// buffer grows without limit in a server that stays up for days.
final class JobStoreTests: XCTestCase {
    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            usleep(5_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testSubmitReturnsAnIdThatIsImmediatelyQueryable() {
        let store = JobStore()
        let release = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
            release.wait()
            handle.finish(succeeded: true)
        }
        // The point of the design: the caller can report the id before the work is anywhere.
        XCTAssertNotNil(store.snapshot(id))
        XCTAssertEqual(store.snapshot(id)?.kind, .build)

        release.signal()
        waitFor { store.snapshot(id)?.state == .succeeded }
        XCTAssertEqual(store.snapshot(id)?.succeeded, true)
        XCTAssertNotNil(store.snapshot(id)?.finishedAt)
    }

    func testFailedJobCarriesItsReason() {
        let store = JobStore()
        let id = store.submit(kind: .test, device: "iPhone", scheme: "App") { handle in
            handle.finish(succeeded: false, reason: "no such scheme")
        }
        waitFor { store.snapshot(id)?.state == .failed }
        XCTAssertEqual(store.snapshot(id)?.failureReason, "no such scheme")
    }

    /// Cancelling a job that has not started must stop it from ever starting: by the time the
    /// queue reaches it the agent has already been told it was cancelled.
    func testCancellingAQueuedJobPreventsItFromRunning() {
        let store = JobStore()
        let blocker = DispatchSemaphore(value: 0)
        let first = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
            blocker.wait()
            handle.finish(succeeded: true)
        }
        var secondRan = false
        let second = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
            secondRan = true
            handle.finish(succeeded: true)
        }

        XCTAssertEqual(store.cancel(second), .cancelled)
        blocker.signal()
        waitFor { store.snapshot(first)?.state == .succeeded }
        XCTAssertFalse(secondRan, "a cancelled job must not start when the queue reaches it")
        XCTAssertEqual(store.snapshot(second)?.state, .cancelled)
    }

    func testCancellingARunningJobEndsAsCancelledNotFailed() {
        let store = JobStore()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .run, device: "iPhone", scheme: "App") { handle in
            started.signal()
            release.wait()
            // The work reports failure because it was killed; the store knows better.
            handle.finish(succeeded: false)
        }
        started.wait()
        XCTAssertEqual(store.cancel(id), .cancelled, "terminal the moment it is asked for")
        release.signal()
        waitFor { store.snapshot(id)?.state.isFinished ?? false }
        XCTAssertEqual(store.snapshot(id)?.state, .cancelled)
    }

    func testCancellingAFinishedJobLeavesItAlone() {
        let store = JobStore()
        let id = store.submit(kind: .build, device: "iPhone", scheme: "App") { $0.finish(succeeded: true) }
        waitFor { store.snapshot(id)?.state == .succeeded }
        XCTAssertEqual(store.cancel(id), .succeeded)
    }

    func testCancellingAnUnknownJobIsReportedRatherThanIgnored() {
        XCTAssertNil(JobStore().cancel("build-nope"))
    }

    func testTailIsBoundedAndKeepsTheNewestLines() {
        let store = JobStore()
        let done = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
            for index in 0..<(JobStore.tailLimit + 200) { handle.append(line: "line \(index)") }
            handle.finish(succeeded: true)
            done.signal()
        }
        done.wait()

        let tail = store.tail(id, limit: JobStore.tailLimit * 2)
        XCTAssertEqual(tail?.lines.count, JobStore.tailLimit)
        XCTAssertEqual(tail?.lines.last, "line \(JobStore.tailLimit + 199)")
    }

    func testTailLimitIsApplied() {
        let store = JobStore()
        let done = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
            for index in 0..<10 { handle.append(line: "line \(index)") }
            handle.finish(succeeded: true)
            done.signal()
        }
        done.wait()
        XCTAssertEqual(store.tail(id, limit: 3)?.lines, ["line 7", "line 8", "line 9"])
    }

    func testJobsRunOneAtATime() {
        let store = JobStore()
        let lock = NSLock()
        var concurrent = 0
        var peak = 0
        let finished = DispatchSemaphore(value: 0)

        for _ in 0..<5 {
            _ = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
                lock.lock(); concurrent += 1; peak = max(peak, concurrent); lock.unlock()
                usleep(10_000)
                lock.lock(); concurrent -= 1; lock.unlock()
                handle.finish(succeeded: true)
                finished.signal()
            }
        }
        for _ in 0..<5 { finished.wait() }
        // Two xcodebuilds against the same derived data interfere; the queue is what prevents it.
        XCTAssertEqual(peak, 1)
    }

    func testEncodedSnapshotOmitsEmptyCollections() {
        let snapshot = JobSnapshot(
            id: "build-1", kind: .build, state: .succeeded, device: "iPhone", scheme: "App",
            startedAt: Date(), finishedAt: Date(), succeeded: true, errors: [], warningCount: 3,
            failedTests: [], logPath: "/tmp/x.log", phase: nil, queuedBehind: nil,
            failureReason: nil
        )
        let fields = SchemeToolRunner.fields(snapshot)
        XCTAssertNil(fields["errors"], "an empty errors array is noise in a result that is size-capped")
        XCTAssertNil(fields["failed_tests"])
        XCTAssertNil(fields["failure_reason"])
        XCTAssertEqual(fields["warning_count"], .int(3))
        XCTAssertEqual(fields["succeeded"], .bool(true))
    }
}

/// `structuredContent` must be a JSON object. A tool that returned a bare array was rejected by
/// the client outright — the call was lost, not merely reshaped — so every tool's result is
/// asserted to be one, including the list-shaped ones where the mistake is tempting.
final class MCPResultShapeTests: XCTestCase {
    func testListShapedToolsWrapTheirArrayInAnObject() throws {
        let runner = SchemeToolRunner(root: URL(fileURLWithPath: NSTemporaryDirectory()))

        let devices = try runner.call(name: "list_devices", arguments: [:])
        XCTAssertNotNil(devices["devices"], "the array belongs under a key, not at the top level")
        if case .array = devices["devices"] {} else { XCTFail("devices should be an array") }

        let jobs = try runner.call(name: "job_status", arguments: [:])
        XCTAssertNotNil(jobs["jobs"])
        XCTAssertEqual(jobs["count"], .int(0))
    }

    func testUnknownToolIsReportedAsSuch() {
        let runner = SchemeToolRunner(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertThrowsError(try runner.call(name: "no_such_tool", arguments: [:]))
    }

    func testJobLogWithoutAJobIdIsRejected() {
        let runner = SchemeToolRunner(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertThrowsError(try runner.call(name: "job_log", arguments: [:]))
    }
}

/// A caller that cannot tell "waiting its turn" from "stuck" will give up on a job that was
/// going to succeed. These pin down what an unfinished job says about itself.
final class JobVisibilityTests: XCTestCase {
    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            usleep(5_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testAQueuedJobNamesTheOneHoldingTheQueue() {
        let store = JobStore()
        let release = DispatchSemaphore(value: 0)
        let first = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
            release.wait()
            handle.finish(succeeded: true)
        }
        let second = store.submit(kind: .test, device: "iPhone", scheme: "App") { $0.finish(succeeded: true) }
        waitFor { store.snapshot(first)?.state == .running }

        XCTAssertEqual(store.snapshot(second)?.queuedBehind, first)
        XCTAssertNil(store.snapshot(first)?.queuedBehind, "the one running waits for nobody")

        release.signal()
        waitFor { store.snapshot(second)?.state == .succeeded }
        XCTAssertNil(store.snapshot(second)?.queuedBehind, "and neither does a finished one")
    }

    /// The guidance is the point: it is what stops a caller reading a queue as a failure.
    func testAnUnfinishedJobSaysToKeepPolling() throws {
        let store = JobStore()
        let release = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .test, device: "iPhone", scheme: "App") { handle in
            release.wait()
            handle.finish(succeeded: true)
        }
        waitFor { store.snapshot(id)?.state == .running }

        let running = SchemeToolRunner.fields(try XCTUnwrap(store.snapshot(id)))
        guard case .string(let next)? = running["next"] else { return XCTFail("no guidance") }
        XCTAssertTrue(next.contains("keep polling"), next)

        release.signal()
        waitFor { store.snapshot(id)?.state == .succeeded }
        let done = SchemeToolRunner.fields(try XCTUnwrap(store.snapshot(id)))
        XCTAssertNil(done["next"], "a finished job has nothing to wait for")
    }
}

/// Regressions from the review of #3. Each of these was wrong in the first cut.
final class JobPredecessorTests: XCTestCase {
    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            usleep(5_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    /// With two jobs waiting, the second was told to wait for the running one — so it expected
    /// to start when that finished, and did not.
    func testEachQueuedJobNamesTheOneDirectlyAheadOfIt() {
        let store = JobStore()
        let release = DispatchSemaphore(value: 0)
        let a = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
            release.wait()
            handle.finish(succeeded: true)
        }
        let b = store.submit(kind: .test, device: "iPhone", scheme: "App") { handle in
            release.wait()
            handle.finish(succeeded: true)
        }
        let c = store.submit(kind: .test, device: "iPhone", scheme: "App") { $0.finish(succeeded: true) }
        waitFor { store.snapshot(a)?.state == .running }

        XCTAssertEqual(store.snapshot(b)?.queuedBehind, a)
        XCTAssertEqual(store.snapshot(c)?.queuedBehind, b, "c waits for b, not for the one running")

        release.signal()
        waitFor { store.snapshot(b)?.state == .running }
        XCTAssertEqual(store.snapshot(c)?.queuedBehind, b, "still b, which is now the running one")
    }

    /// A launched app emits no build phases, so the last one xcodebuild reported would sit
    /// there making a healthy job look stuck on "Signing".
    func testAnExplicitStageOutranksTheLastBuildPhase() {
        let store = JobStore()
        let release = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .run, device: "iPhone", scheme: "App") { handle in
            handle.stage("app running")
            release.wait()
            handle.finish(succeeded: true)
        }
        waitFor { store.snapshot(id)?.phase == "app running" }

        release.signal()
        waitFor { store.snapshot(id)?.state == .succeeded }
        XCTAssertNil(store.snapshot(id)?.phase, "a finished job is not still doing something")
    }
}

/// `truncated` compared the returned count against the buffer's capacity, after the line limit
/// and the filter had already cut it down, so it was false in every call anyone would make. An
/// agent could never learn that output had been left out.
final class JobLogAccountingTests: XCTestCase {
    private func store(lines: Int) -> (JobStore, String) {
        let store = JobStore()
        let done = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .build, device: "iPhone", scheme: "App") { handle in
            for index in 0..<lines { handle.append(line: "line \(index)") }
            handle.finish(succeeded: true)
            done.signal()
        }
        done.wait()
        return (store, id)
    }

    func testTheTailReportsHowMuchIsHeldAsWellAsWhatItReturned() {
        let (store, id) = store(lines: 40)
        let tail = store.tail(id, limit: 10)
        XCTAssertEqual(tail?.lines.count, 10)
        XCTAssertEqual(tail?.buffered, 40, "what was left out is knowable")
    }

    func testAskingForEverythingLeavesNothingAbove() {
        let (store, id) = store(lines: 40)
        let tail = store.tail(id, limit: 1000)
        XCTAssertEqual(tail?.lines.count, 40)
        XCTAssertEqual(tail?.buffered, 40)
    }

    func testDiscardingIsReportedOnlyOnceTheBufferIsFull() {
        let (small, smallID) = store(lines: 10)
        XCTAssertFalse(small.hasDiscardedOldestLines(smallID))

        let (full, fullID) = store(lines: JobStore.tailLimit + 50)
        XCTAssertTrue(full.hasDiscardedOldestLines(fullID), "the oldest are gone from the buffer")
        XCTAssertEqual(full.tail(fullID, limit: .max)?.buffered, JobStore.tailLimit)
    }
}

/// A job is finished once and keeps its first result. That is deliberate — a cancelled job must
/// not be overwritten by the failure its own killed process reports — but it also means any step
/// that finishes a job ends it for good. `run` used to finish at the end of its build, so an
/// install that failed afterwards was reported as a success.
final class JobFinishOnceTests: XCTestCase {
    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            usleep(5_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testAJobKeepsTheFirstResultItWasGiven() {
        let store = JobStore()
        let id = store.submit(kind: .run, device: "iPhone", scheme: "App") { handle in
            handle.finish(succeeded: true)
            handle.finish(succeeded: false, reason: "the install failed")
        }
        waitFor { store.snapshot(id)?.state.isFinished ?? false }

        XCTAssertEqual(store.snapshot(id)?.state, .succeeded)
        XCTAssertNil(store.snapshot(id)?.failureReason,
                     "the later failure is discarded — which is why no step may finish early")
    }

    /// The consequence of the rule above: while a job is still working it keeps reporting what
    /// it is doing. Finishing at the end of the build threw that away too.
    func testAJobStillWorkingKeepsReportingItsStage() {
        let store = JobStore()
        let release = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .run, device: "iPhone", scheme: "App") { handle in
            handle.stage("installing MyApp.app")
            release.wait()
            handle.finish(succeeded: false, reason: "the app exited non-zero")
        }
        waitFor { store.snapshot(id)?.phase == "installing MyApp.app" }

        release.signal()
        waitFor { store.snapshot(id)?.state.isFinished ?? false }
        XCTAssertEqual(store.snapshot(id)?.state, .failed)
        XCTAssertEqual(store.snapshot(id)?.failureReason, "the app exited non-zero")
    }
}

/// A cancellation used to wait for the work to call `finish` before the job became terminal.
/// Any step that returns early on `isCancelled` — which is what a cancellation check is for —
/// then left the job `running` for good: never reaped, never reportable, and named as the
/// predecessor of every job queued after it.
final class JobCancellationIsTerminalTests: XCTestCase {
    func testAJobCancelledWhileRunningIsTerminalEvenIfTheWorkNeverFinishesIt() {
        let store = JobStore()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let id = store.submit(kind: .run, device: "iPhone", scheme: "App") { handle in
            started.signal()
            release.wait()
            guard !handle.isCancelled else { return }   // returns without finishing
            handle.finish(succeeded: true)
        }
        started.wait()

        XCTAssertEqual(store.cancel(id), .cancelled)
        release.signal()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !(store.snapshot(id)?.state.isFinished ?? false) { usleep(5_000) }
        XCTAssertEqual(store.snapshot(id)?.state, .cancelled, "not stuck in running")
    }

    /// A cancelled job whose work has not returned is still the reason the next one cannot
    /// start, so it must still be named. The first version of this test only looked after the
    /// second job had finished, by which point `queuedBehind` is nil for any job — it passed
    /// without the change it was meant to protect.
    func testAJobStillHoldingTheQueueIsNamedEvenOnceCancelled() {
        let store = JobStore()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = store.submit(kind: .run, device: "iPhone", scheme: "App") { handle in
            started.signal()
            release.wait()                       // still on the queue after the cancel
            guard !handle.isCancelled else { return }
            handle.finish(succeeded: true)
        }
        let second = store.submit(kind: .build, device: "iPhone", scheme: "App") { $0.finish(succeeded: true) }
        started.wait()

        XCTAssertEqual(store.cancel(first), .cancelled)
        XCTAssertEqual(store.snapshot(second)?.state, .queued, "still waiting its turn")
        XCTAssertEqual(store.snapshot(second)?.queuedBehind, first,
                       "the cancelled job is still holding the queue")

        release.signal()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !(store.snapshot(second)?.state.isFinished ?? false) { usleep(5_000) }
        XCTAssertEqual(store.snapshot(second)?.state, .succeeded)
    }

    /// Eviction used to key off the state. A cancelled job is terminal at once, so it became
    /// evictable while its work was still running — and losing the entry loses the cancelled
    /// flag the work is about to check.
    func testACancelledJobIsNotEvictedWhileItsWorkIsStillRunning() {
        let store = JobStore()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let long = store.submit(kind: .run, device: "iPhone", scheme: "App") { handle in
            started.signal()
            release.wait()
            handle.finish(succeeded: true)
        }
        started.wait()
        _ = store.cancel(long)

        for _ in 0..<80 {
            _ = store.submit(kind: .build, device: "iPhone", scheme: "App") { $0.finish(succeeded: true) }
        }
        XCTAssertNotNil(store.snapshot(long), "still running, so still known")

        release.signal()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && store.snapshot(long) != nil { usleep(5_000) }
    }
}

/// `warning_count` and `errors` are what an agent acts on, so a number inflated by xcodebuild's
/// repeated passes is worse than no number: three reports of one warning read as three warnings.
final class DiagnosticDeduplicationTests: XCTestCase {
    func testTheSameWarningEmittedOncePerPassIsCountedOnce() {
        let report = BuildReport(logURL: nil)
        let line = "/App/Sources/View.swift:12:5: warning: unused variable 'x'"
        for _ in 0..<3 { report.ingest(line) }

        XCTAssertEqual(report.warnings.count, 3, "the raw list keeps every pass")
        XCTAssertEqual(report.uniqueDiagnostics(severity: .warning).count, 1, "the count does not")
    }

    func testTwoDifferentWarningsOnTheSameLineAreBothKept() {
        let report = BuildReport(logURL: nil)
        report.ingest("/App/Sources/View.swift:12:5: warning: unused variable 'x'")
        report.ingest("/App/Sources/View.swift:12:5: warning: unused variable 'y'")

        XCTAssertEqual(report.uniqueDiagnostics(severity: .warning).count, 2)
    }

    func testErrorsAreDeduplicatedTooAndSeveritiesDoNotMix() {
        let report = BuildReport(logURL: nil)
        let error = "/App/Sources/View.swift:9:1: error: cannot find 'foo' in scope"
        for _ in 0..<2 { report.ingest(error) }
        report.ingest("/App/Sources/View.swift:12:5: warning: unused variable 'x'")

        XCTAssertEqual(report.uniqueDiagnostics(severity: .error).count, 1)
        XCTAssertEqual(report.uniqueDiagnostics(severity: .warning).count, 1)
    }
}
