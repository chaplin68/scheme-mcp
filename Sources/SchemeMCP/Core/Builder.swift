import Foundation

/// Runs xcodebuild and streams structured events back to the caller.
struct Builder {
    let project: XcodeProject

    enum Action: String {
        case build
        case test
        case clean

        var xcodebuildArgument: String { rawValue }
    }

    /// Where the unabridged xcodebuild output lands so failures can be inspected later.
    static func makeLogURL(projectName: String, action: Action) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("scheme-mcp/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return directory.appendingPathComponent("\(projectName)-\(action.rawValue)-\(stamp).log")
    }

    func arguments(
        action: Action,
        device: Device?,
        extraArguments: [String] = []
    ) -> [String] {
        var args = [action.xcodebuildArgument] + project.baseArguments
        if let device {
            args += ["-destination", device.destination]
            // Provisioning updates only make sense for real hardware.
            if device.kind == .physical { args.append("-allowProvisioningUpdates") }
        }
        if action == .test, let testPlan = project.testPlan {
            args += ["-testPlan", testPlan]
        }
        return args + extraArguments
    }

    /// Executes the action, feeding each output line to `report` and notifying `onEvent`.
    /// Returns the process exit status; the report holds the parsed detail.
    @discardableResult
    func run(
        action: Action,
        device: Device?,
        extraArguments: [String] = [],
        report: BuildReport,
        onStart: ((ProcessHandle) -> Void)? = nil,
        onEvent: @escaping (BuildEvent) -> Void,
        onLine: ((String) -> Void)? = nil
    ) throws -> Int32 {
        let handle = try Shell.stream(
            "xcodebuild",
            arguments(action: action, device: device, extraArguments: extraArguments),
            currentDirectory: project.root,
            onLine: { line in
                // The raw line is offered as well as the parsed event: the MCP server keeps a
                // tail of unparsed output, which is the only way to see a phase the parser has
                // no rule for.
                onLine?(line)
                if let event = report.ingest(line) { onEvent(event) }
            }
        )
        // Registered by whoever spawned it, so a signal reaches the build no matter which
        // command started it — the CLI used to rely on Ctrl-C reaching xcodebuild through the
        // terminal's process group, and nothing covered `kill <scheme-mcp>` at all.
        Interrupt.register(handle)
        defer { Interrupt.forget(handle) }
        // Handed over before the wait: without it the caller has no way to stop a build, and
        // nothing to kill when the process it started outlives it.
        onStart?(handle)
        return handle.waitUntilExit()
    }
}
