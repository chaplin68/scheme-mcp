import Foundation

private struct DeviceCtlResponse: Decodable {
    let result: DeviceCtlResult
}

private struct DeviceCtlResult: Decodable {
    let devices: [DeviceCtlEntry]
}

private struct DeviceCtlEntry: Decodable {
    let hardwareProperties: DeviceCtlHardware
    let deviceProperties: DeviceCtlProperties
    let connectionProperties: DeviceCtlConnection
}

private struct DeviceCtlHardware: Decodable {
    let udid: String
    let platform: String
    let deviceType: String?
    let marketingName: String?
}

private struct DeviceCtlProperties: Decodable {
    let name: String?
    let osVersionNumber: String?
    /// Present only while the device is attached; also gone while a freshly updated
    /// device is still booting.
    let bootState: String?
    /// False while the Developer Disk Image for this OS build is still being mounted —
    /// the usual state for the first minutes after an OS update.
    let ddiServicesAvailable: Bool?
}

private struct DeviceCtlConnection: Decodable {
    let tunnelState: String?
    let pairingState: String?
    /// "wired" | "localNetwork". Present only while the device is actually reachable.
    let transportType: String?
}

/// Wrapper around `xcrun devicectl` (Xcode 15+) for physical devices.
enum DeviceCtl {
    static func listDevices() throws -> [Device] {
        // devicectl only writes JSON to a file; it has no stdout JSON mode.
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-mcp-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try Shell.run(
            "xcrun",
            ["devicectl", "list", "devices", "--quiet", "--json-output", output.path]
        )
        // A machine with no paired devices is a normal state, not a failure.
        guard result.succeeded, let data = try? Data(contentsOf: output) else { return [] }

        return try parse(data)
    }

    /// Split out from `listDevices` so the state mapping is testable without a device attached.
    static func parse(_ data: Data) throws -> [Device] {
        let response = try JSONDecoder().decode(DeviceCtlResponse.self, from: data)
        return response.result.devices.compactMap { entry -> Device? in
            guard let platform = Platform.fromRuntimeToken(entry.hardwareProperties.platform) else { return nil }
            let paired = entry.connectionProperties.pairingState?.lowercased() == "paired"
            // Reachability is attachment, not tunnel state. The tunnel is a transient resource
            // that devicectl brings up on demand — install/launch establish one themselves — and
            // it reads "unavailable" whenever none is up right now, which is the normal state of
            // an attached device that has just rebooted (every OS update does exactly that).
            // transportType is only reported while the device is actually reachable.
            let attached = entry.connectionProperties.transportType != nil
                || entry.connectionProperties.tunnelState?.lowercased() == "connected"
            return Device(
                id: entry.hardwareProperties.udid,
                name: entry.deviceProperties.name ?? entry.hardwareProperties.marketingName ?? "Unknown device",
                kind: .physical,
                platform: platform,
                osVersion: entry.deviceProperties.osVersionNumber ?? "unknown",
                state: (paired && attached) ? .connected : .unavailable,
                modelName: entry.hardwareProperties.marketingName ?? entry.hardwareProperties.deviceType,
                statusDetail: describe(entry)
            )
        }
    }

    /// Verbatim devicectl state, for error messages: guessing why a device is unusable is
    /// what made the old failure undiagnosable.
    private static func describe(_ entry: DeviceCtlEntry) -> String {
        var parts = [
            "pairingState=\(entry.connectionProperties.pairingState ?? "?")",
            "transportType=\(entry.connectionProperties.transportType ?? "none")",
            "tunnelState=\(entry.connectionProperties.tunnelState ?? "none")",
        ]
        if let boot = entry.deviceProperties.bootState { parts.append("bootState=\(boot)") }
        if let ddi = entry.deviceProperties.ddiServicesAvailable { parts.append("ddiServicesAvailable=\(ddi)") }
        return parts.joined(separator: ", ")
    }

    static func install(app: URL, to udid: String) throws {
        try Shell.runChecked("xcrun", ["devicectl", "device", "install", "app", "--device", udid, app.path])
    }

    static func launch(bundleIdentifier: String, on udid: String) throws {
        try Shell.runChecked(
            "xcrun",
            ["devicectl", "device", "process", "launch",
             "--device", udid, "--terminate-existing", bundleIdentifier]
        )
    }

    /// Launches the app and streams its stdout/stderr. This is the reliable way to read
    /// device output — `log stream --device` needs a tunnel that is often unavailable.
    static func launchWithConsole(
        bundleIdentifier: String,
        on udid: String,
        onLine: @escaping (String) -> Void
    ) throws -> ProcessHandle {
        try Shell.stream(
            "xcrun",
            ["devicectl", "device", "process", "launch",
             "--device", udid, "--terminate-existing", "--console", bundleIdentifier],
            onLine: onLine
        )
    }
}
