import Foundation

/// Installs and launches a built product on a simulator, a physical device, or the Mac.
enum AppRunner {
    /// Brings the target to a state where an install can succeed.
    static func prepare(_ device: Device) throws {
        switch device.kind {
        case .simulator:
            // Must finish before install/launch: a device reports Booted well before it can
            // actually accept either.
            try Simctl.bootAndWait(device.id)
            try Simctl.openSimulatorApp()
        case .physical:
            guard device.state == .connected else {
                let reported = device.statusDetail.map { "\n  devicectl reports: \($0)" } ?? ""
                throw ProjectError(
                    message: """
                    \(device.name) is not reachable. Connect it over USB or Wi-Fi, unlock it, \
                    and make sure Developer Mode is enabled. Right after an OS update the device \
                    stays unusable until its Developer Disk Image finishes mounting — \
                    `xcrun devicectl list devices` shows when it is ready.\(reported)
                    """
                )
            }
        case .mac:
            break
        }
    }

    static func install(app: URL, on device: Device) throws {
        switch device.kind {
        case .simulator: try Simctl.install(app: app, to: device.id)
        case .physical: try DeviceCtl.install(app: app, to: device.id)
        case .mac: break
        }
    }

    /// Launches without attaching to output. Returns immediately.
    static func launch(bundleIdentifier: String, on device: Device) throws {
        switch device.kind {
        case .simulator:
            try Simctl.launch(bundleIdentifier: bundleIdentifier, on: device.id)
        case .physical:
            try DeviceCtl.launch(bundleIdentifier: bundleIdentifier, on: device.id)
        case .mac:
            throw ProjectError(message: "Use launchStreaming for macOS targets.")
        }
    }

    /// Launches and streams the app's console output. The returned handle stops the stream.
    static func launchStreaming(
        bundleIdentifier: String,
        app: URL,
        on device: Device,
        onLine: @escaping (String) -> Void
    ) throws -> ProcessHandle {
        switch device.kind {
        case .simulator:
            Simctl.terminate(bundleIdentifier: bundleIdentifier, on: device.id)
            return try Shell.stream(
                "xcrun",
                ["simctl", "launch", "--console-pty", "--terminate-running-process",
                 device.id, bundleIdentifier],
                onLine: onLine
            )
        case .physical:
            return try DeviceCtl.launchWithConsole(
                bundleIdentifier: bundleIdentifier,
                on: device.id,
                onLine: onLine
            )
        case .mac:
            let executable = macExecutable(in: app)
            return try Shell.stream(executable.path, [], onLine: onLine)
        }
    }

    /// `Foo.app/Contents/MacOS/Foo` — running the binary directly keeps stdout attached,
    /// which `open` would detach.
    private static func macExecutable(in app: URL) -> URL {
        let name = app.deletingPathExtension().lastPathComponent
        return app.appendingPathComponent("Contents/MacOS/\(name)")
    }
}
