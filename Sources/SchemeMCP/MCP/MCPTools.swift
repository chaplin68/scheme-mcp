import Foundation
import MCP

/// The tool surface exposed to an agent.
///
/// Shaped around two constraints that come from the protocol rather than from the build:
/// results are capped (25k tokens by default), and a call that runs past two minutes is moved
/// to a background task. So nothing here streams a raw log or waits for a build: work is
/// started, an id comes back, and the distilled result is fetched when it is ready.
enum SchemeTools {
    static func definitions() -> [Tool] {
        [
            Tool(
                name: "list_devices",
                description: """
                List every destination that can be targeted: simulators, paired hardware and the \
                Mac. Use this before build/run to get a device id.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "platform": .object([
                            "type": .string("string"),
                            "description": .string("Filter by platform, e.g. iOS, watchOS, macOS."),
                        ]),
                        "ready_only": .object([
                            "type": .string("boolean"),
                            "description": .string("Only booted simulators and connected hardware."),
                        ]),
                    ]),
                ])
            ),
            Tool(
                name: "list_schemes",
                description: "List the schemes in the project, best guess first.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "build",
                description: """
                Start a build. Returns a job id immediately — builds take minutes, so poll \
                job_status rather than waiting. Errors come back in full; warnings are counted.
                """,
                inputSchema: actionSchema(extra: [
                    "clean": .object([
                        "type": .string("boolean"),
                        "description": .string("Clean before building."),
                    ])
                ])
            ),
            Tool(
                name: "test",
                description: "Start a test run. Returns a job id; poll job_status for failures.",
                inputSchema: actionSchema()
            ),
            Tool(
                name: "run",
                description: """
                Build, install and launch the app, capturing its console output. Returns a job \
                id; read the app's output with job_log while the job is running.
                """,
                inputSchema: actionSchema()
            ),
            Tool(
                name: "job_status",
                description: """
                The state of a job started by build/test/run, with its errors, warning count \
                and the path to the unabridged xcodebuild log.

                `queued` and `running` both mean the work is fine and you should keep polling. \
                Jobs run one at a time, so a job waits while another holds the queue, and \
                `queued_behind` names the one it is waiting for. A job against a simulator that \
                is not booted spends its first minutes with no output at all while xcodebuild \
                boots one. Neither is a failure: only `failed` is.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "job_id": .object([
                            "type": .string("string"),
                            "description": .string("Omit to list every job this server has run."),
                        ])
                    ]),
                ])
            ),
            Tool(
                name: "job_log",
                description: """
                The tail of a job's raw output, newest last.

                `returned` and `buffered` say how much you got and how much is held; \
                `more_above` means older lines are buffered but were not returned, and \
                `oldest_lines_discarded` means the buffer has passed \(JobStore.tailLimit) \
                lines and the oldest are gone from it. The unabridged log is always on disk at \
                the path job_status reports.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "job_id": .object(["type": .string("string")]),
                        "lines": .object([
                            "type": .string("integer"),
                            "description": .string("How many trailing lines to return (default 50)."),
                        ]),
                        "contains": .object([
                            "type": .string("string"),
                            "description": .string("Only lines containing this text, case-insensitive."),
                        ]),
                    ]),
                    "required": .array([.string("job_id")]),
                ])
            ),
            Tool(
                name: "cancel_job",
                description: "Stop a running job, or drop it from the queue if it has not started.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["job_id": .object(["type": .string("string")])]),
                    "required": .array([.string("job_id")]),
                ])
            ),
        ]
    }

    private static func actionSchema(extra: [String: Value] = [:]) -> Value {
        var properties: [String: Value] = [
            "device": .object([
                "type": .string("string"),
                "description": .string(
                    "A UDID from list_devices, or a selector: auto, sim, iphone, ipad, device, mac."
                ),
            ]),
            "scheme": .object([
                "type": .string("string"),
                "description": .string("Overrides the project's default scheme."),
            ]),
        ]
        properties.merge(extra) { current, _ in current }
        return .object(["type": .string("object"), "properties": .object(properties)])
    }
}

/// Turns tool calls into work against the existing Core types.
///
/// Holds no MCP concepts beyond the argument decoding: everything it calls is the same code
/// the CLI subcommands use, which is what keeps the two from drifting apart.
final class SchemeToolRunner {
    private let root: URL
    private let jobs = JobStore()

    init(root: URL) {
        self.root = root
    }

    /// Returns the result's fields rather than a `Value`.
    ///
    /// The protocol requires `structuredContent` to be an object, and returning a bare array
    /// from one tool is a schema violation the client rejects — with the whole call lost, not
    /// just the shape. A dictionary return type makes that mistake unrepresentable.
    func call(name: String, arguments: [String: Value]) throws -> [String: Value] {
        switch name {
        case "list_devices": return listDevices(arguments)
        case "list_schemes": return try listSchemes()
        case "build": return try start(.build, arguments)
        case "test": return try start(.test, arguments)
        case "run": return try start(.run, arguments)
        case "job_status": return jobStatus(arguments)
        case "job_log": return try jobLog(arguments)
        case "cancel_job": return try cancelJob(arguments)
        default: throw MCPError.methodNotFound("no such tool: \(name)")
        }
    }

    // MARK: - Queries

    private func listDevices(_ arguments: [String: Value]) -> [String: Value] {
        let platform = arguments["platform"]?.stringValue.flatMap(Platform.fromRuntimeToken)
        let readyOnly = arguments["ready_only"]?.boolValue ?? false
        var devices = DeviceCatalog.load().ranked(for: platform)
        // Appended after the filter, so a request for iOS used to come back with the Mac in it
        // and an agent that trusted the filter could pick a macOS destination for an iOS build.
        if platform == nil || platform == .macOS { devices.append(.myMac()) }
        if readyOnly { devices = devices.filter { $0.state.isReady } }

        let entries: [Value] = devices.map { device in
            .object([
                "id": .string(device.id),
                "name": .string(device.name),
                "kind": .string(device.kind.rawValue),
                "platform": .string(device.platform.rawValue),
                "os_version": .string(device.osVersion),
                "state": .string(device.state.rawValue),
                "ready": .bool(device.state.isReady),
            ])
        }
        return ["devices": .array(entries), "count": .int(entries.count)]
    }

    private func listSchemes() throws -> [String: Value] {
        let context = try resolveContext(scheme: nil)
        let schemes = XcodeProject.rankSchemes(
            (try? XcodeProject.listSchemes(container: context.project.container)) ?? [],
            container: context.project.container,
            root: context.root
        )
        return [
            "active": .string(context.project.scheme),
            "schemes": .array(schemes.map { .string($0) }),
        ]
    }

    // MARK: - Jobs

    private func start(_ kind: JobKind, _ arguments: [String: Value]) throws -> [String: Value] {
        let context = try resolveContext(scheme: arguments["scheme"]?.stringValue)
        let device = try resolveDevice(arguments["device"]?.stringValue, in: context)
        let clean = arguments["clean"]?.boolValue ?? false

        let id = jobs.submit(kind: kind, device: device.name, scheme: context.project.scheme) { handle in
            switch kind {
            case .build, .test:
                let action: Builder.Action = kind == .test ? .test : .build
                do { handle.finish(succeeded: try Self.build(action, context, device, clean: clean, handle: handle)) }
                catch { handle.finish(succeeded: false, reason: error.localizedDescription) }
            case .run:
                Self.runAndLaunch(context, device, clean: clean, handle: handle)
            }
        }
        // The job may still be queued behind another build, so the state is reported rather
        // than assumed to be running.
        return [
            "job_id": .string(id),
            "state": .string(jobs.snapshot(id)?.state.rawValue ?? JobState.queued.rawValue),
            "device": .string(device.displayName),
            "scheme": .string(context.project.scheme),
            "next": .string("poll job_status with this job_id"),
        ]
    }

    /// Runs xcodebuild and reports whether it passed.
    ///
    /// Deliberately does not finish the job. A job is finished once and keeps its first result,
    /// so a `run` that finished here would report success the moment the *build* passed and
    /// silently discard whatever the install and the launch went on to do.
    private static func build(
        _ action: Builder.Action,
        _ context: ProjectContext,
        _ device: Device,
        clean: Bool,
        handle: JobStore.JobHandle
    ) throws -> Bool {
        let builder = Builder(project: context.project)
        if clean {
            _ = try? builder.run(action: .clean, device: device, report: BuildReport()) { _ in }
        }
        let logURL = Builder.makeLogURL(projectName: context.project.name, action: action)
        let report = BuildReport(logURL: logURL)
        handle.attach(report: report)

        let status = try builder.run(
            action: action,
            device: device,
            report: report,
            onEvent: { _ in }
        ) { line in handle.append(line: line) }
        return status == 0 && (report.outcome?.isSuccess ?? false)
    }

    private static func runAndLaunch(
        _ context: ProjectContext,
        _ device: Device,
        clean: Bool,
        handle: JobStore.JobHandle
    ) {
        do {
            guard try build(.build, context, device, clean: clean, handle: handle) else {
                handle.finish(succeeded: false, reason: "the build failed; see log_path")
                return
            }
            guard !handle.isCancelled else { return }

            let identity = try context.project.appIdentity(for: device)
            let app = try context.project.productBundle(for: device)
            handle.stage("preparing \(device.name)")
            try AppRunner.prepare(device)
            handle.stage("installing \(app.lastPathComponent)")
            try AppRunner.install(app: app, on: device)
            handle.stage("launching \(identity.bundleIdentifier)")
            let process = try AppRunner.launchStreaming(
                bundleIdentifier: identity.bundleIdentifier,
                app: app,
                on: device
            ) { line in handle.append(line: LogFormatter.plainLine(line)) }
            handle.attach(process: process)
            handle.stage("app running — job_log follows its console output")
            // The app keeps running; the job stays in `running` until it exits or is cancelled,
            // which is what makes job_log a live view of the app's console.
            let status = process.waitUntilExit()
            handle.finish(succeeded: status == 0)
        } catch {
            handle.finish(succeeded: false, reason: error.localizedDescription)
        }
    }

    private func jobStatus(_ arguments: [String: Value]) -> [String: Value] {
        guard let id = arguments["job_id"]?.stringValue else {
            let all = jobs.all()
            return ["jobs": .array(all.map { .object(Self.fields($0)) }), "count": .int(all.count)]
        }
        guard let snapshot = jobs.snapshot(id) else {
            return ["error": .string("no such job: \(id)")]
        }
        return Self.fields(snapshot)
    }

    private func jobLog(_ arguments: [String: Value]) throws -> [String: Value] {
        guard let id = arguments["job_id"]?.stringValue else {
            throw MCPError.invalidParams("job_log needs a job_id")
        }
        let limit = arguments["lines"]?.intValue ?? 50
        guard let tail = jobs.tail(id, limit: limit) else {
            return ["error": .string("no such job: \(id)")]
        }
        var lines = tail.lines
        if let needle = arguments["contains"]?.stringValue, !needle.isEmpty {
            lines = lines.filter { LogFilter.matches($0, query: needle) }
        }
        // Said plainly, because the caller cannot see what it did not receive. The flag used to
        // compare the returned count against the buffer's capacity, after the limit and the
        // filter had already cut it down, so it was false in every call anyone would make.
        return [
            "job_id": .string(id),
            "lines": .array(lines.map { .string($0) }),
            "returned": .int(lines.count),
            "buffered": .int(tail.buffered),
            "more_above": .bool(tail.buffered > tail.lines.count),
            "oldest_lines_discarded": .bool(jobs.hasDiscardedOldestLines(id)),
        ]
    }

    private func cancelJob(_ arguments: [String: Value]) throws -> [String: Value] {
        guard let id = arguments["job_id"]?.stringValue else {
            throw MCPError.invalidParams("cancel_job needs a job_id")
        }
        guard let state = jobs.cancel(id) else {
            return ["error": .string("no such job: \(id)")]
        }
        return ["job_id": .string(id), "state": .string(state.rawValue)]
    }

    static func fields(_ snapshot: JobSnapshot) -> [String: Value] {
        var object: [String: Value] = [
            "job_id": .string(snapshot.id),
            "kind": .string(snapshot.kind.rawValue),
            "state": .string(snapshot.state.rawValue),
            "device": .string(snapshot.device),
            "scheme": .string(snapshot.scheme),
            "elapsed_seconds": .double((snapshot.elapsedSeconds * 10).rounded() / 10),
            "warning_count": .int(snapshot.warningCount),
        ]
        if let succeeded = snapshot.succeeded { object["succeeded"] = .bool(succeeded) }
        if !snapshot.errors.isEmpty {
            object["errors"] = .array(snapshot.errors.map { .string($0) })
        }
        if !snapshot.failedTests.isEmpty {
            object["failed_tests"] = .array(snapshot.failedTests.map { .string($0) })
        }
        if let logPath = snapshot.logPath { object["log_path"] = .string(logPath) }
        if let reason = snapshot.failureReason { object["failure_reason"] = .string(reason) }
        if let phase = snapshot.phase { object["phase"] = .string(phase) }
        // An unfinished job needs to say that waiting is the right thing to do. Without it a
        // caller polling a queue sees a job that never starts and concludes the tool is stuck.
        if let behind = snapshot.queuedBehind { object["queued_behind"] = .string(behind) }
        switch snapshot.state {
        case .queued:
            object["next"] = .string(
                snapshot.queuedBehind.map { "waiting for \($0) to finish — jobs run one at a time; keep polling" }
                    ?? "waiting its turn — jobs run one at a time; keep polling"
            )
        case .running:
            // Silence is the state worth explaining: xcodebuild says nothing at all while it
            // boots a simulator, which is the stretch that reads as a hang.
            object["next"] = .string(
                snapshot.phase == nil
                    ? "no output yet — a cold simulator boot can take minutes; keep polling"
                    : "still working; keep polling"
            )
        case .succeeded, .failed, .cancelled:
            break
        }
        return object
    }

    // MARK: - Resolution

    private func resolveContext(scheme: String?) throws -> ProjectContext {
        var (config, configRoot) = try Config.load(startingAt: root)
        if let scheme { config.scheme = scheme }
        // Walk up for the project the same way the config lookup above already does. Without
        // it, `--root` had to name the exact directory holding the .xcodeproj while the error
        // for getting it wrong claimed the parents had been searched too.
        let projectRoot = configRoot ?? XcodeProject.findContainerDirectory(startingAt: root) ?? root
        let project = try XcodeProject.discover(config: config, root: projectRoot)
        return ProjectContext(project: project, config: config, root: projectRoot)
    }

    private func resolveDevice(_ requested: String?, in context: ProjectContext) throws -> Device {
        let catalog = DeviceCatalog.load()
        guard let requested, !requested.isEmpty else {
            return try resolve(.auto, catalog: catalog, context: context)
        }
        // A UDID is the unambiguous form and takes precedence; anything else is a selector.
        if let match = (catalog.all + [.myMac()]).first(where: { $0.id == requested }) {
            return match
        }
        guard let selector = DeviceSelector(rawValue: requested.lowercased()) else {
            throw MCPError.invalidParams(
                "unknown device '\(requested)'. Pass a UDID from list_devices, or one of: "
                    + DeviceSelector.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        return try resolve(selector, catalog: catalog, context: context)
    }

    private func resolve(
        _ selector: DeviceSelector,
        catalog: DeviceCatalog,
        context: ProjectContext
    ) throws -> Device {
        let platform = context.project.inferredPlatform()
        guard let device = catalog.resolve(selector, projectPlatform: platform) else {
            // Named rather than deferred to list_devices. The selector says what kind of device
            // was wanted, so the useful answer is what exists of that kind — and when nothing
            // does, saying so outright saves the caller a round trip that cannot succeed.
            let candidates = catalog.candidates(for: selector, projectPlatform: platform)
            let detail = candidates.isEmpty
                ? "nothing of that kind is available"
                : "available: " + candidates.map(\.displayName).joined(separator: ", ")
            throw MCPError.invalidParams("no device matches '\(selector.rawValue)'. \(detail)")
        }
        return device
    }
}
