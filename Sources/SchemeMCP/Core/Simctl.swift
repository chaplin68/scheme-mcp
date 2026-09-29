import Foundation

/// Wrapper around `xcrun simctl` for simulator discovery and lifecycle.
enum Simctl {
    private struct DeviceList: Decodable {
        let devices: [String: [Entry]]
    }

    private struct Entry: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool
        /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`. The only place the family
        /// survives a rename — `name` is whatever the user called it.
        let deviceTypeIdentifier: String?
    }

    static func listDevices() throws -> [Device] {
        let result = try Shell.run("xcrun", ["simctl", "list", "devices", "available", "--json"])
        guard result.succeeded, let data = result.standardOutput.data(using: .utf8) else {
            throw ShellError(
                command: "xcrun simctl list devices",
                exitCode: result.exitCode,
                message: "CoreSimulator is unreachable. Is Xcode installed and its license accepted?"
            )
        }
        let list = try JSONDecoder().decode(DeviceList.self, from: data)

        return list.devices.flatMap { runtimeIdentifier, entries -> [Device] in
            guard let runtime = parseRuntime(runtimeIdentifier) else { return [] }
            return entries.filter(\.isAvailable).map { entry in
                Device(
                    id: entry.udid,
                    name: entry.name,
                    kind: .simulator,
                    platform: runtime.platform,
                    osVersion: runtime.version,
                    state: entry.state.lowercased() == "booted" ? .booted : .shutdown,
                    modelName: parseDeviceType(entry.deviceTypeIdentifier)
                )
            }
        }
    }

    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro` -> "iPhone 17 Pro".
    ///
    /// A simulator's name is editable and `simctl create` takes any string, so matching
    /// `sim-iphone` against the name alone misses `simctl create "CI-Sim" …iPhone-17`.
    /// The device type is assigned at creation and never changes.
    static func parseDeviceType(_ identifier: String?) -> String? {
        let prefix = "com.apple.CoreSimulator.SimDeviceType."
        guard let identifier, identifier.hasPrefix(prefix) else { return nil }
        let token = identifier.dropFirst(prefix.count)
        guard !token.isEmpty else { return nil }
        return token.replacingOccurrences(of: "-", with: " ")
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-2` -> (.iOS, "17.2")
    static func parseRuntime(_ identifier: String) -> (platform: Platform, version: String)? {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else { return nil }
        let token = String(identifier.dropFirst(prefix.count))
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard let platformToken = parts.first,
              let platform = Platform.fromRuntimeToken(String(platformToken)) else { return nil }
        let version = parts.count > 1 ? parts[1].replacingOccurrences(of: "-", with: ".") : "unknown"
        return (platform, version)
    }

    /// Boots the device if needed and blocks until it is genuinely usable.
    ///
    /// `simctl boot` alone is not enough: it returns as soon as the state flips to Booted
    /// — measured at 1s — while the device needed 11s more before an install or launch
    /// would succeed. `bootstatus -b` performs the boot and waits for readiness.
    static func bootAndWait(_ udid: String) throws {
        let result = try Shell.run("xcrun", ["simctl", "bootstatus", udid, "-b"])
        guard result.succeeded else {
            let message = result.standardError.isEmpty ? result.standardOutput : result.standardError
            throw ShellError(
                command: "simctl bootstatus",
                exitCode: result.exitCode,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func openSimulatorApp() throws {
        // The exit status is deliberately ignored: the app may already be running, and the
        // install and launch in `AppRunner.prepare` do not depend on its window being up.
        // `devices boot` is the caller this does not cover — it exists to open the window and
        // reports success either way.
        _ = try Shell.run("open", ["-a", "Simulator"])
    }

    static func install(app: URL, to udid: String) throws {
        try Shell.runChecked("xcrun", ["simctl", "install", udid, app.path])
    }

    static func launch(bundleIdentifier: String, on udid: String, arguments: [String] = []) throws {
        try Shell.runChecked("xcrun", ["simctl", "launch", udid, bundleIdentifier] + arguments)
    }

    static func terminate(bundleIdentifier: String, on udid: String) {
        _ = try? Shell.run("xcrun", ["simctl", "terminate", udid, bundleIdentifier])
    }
}
