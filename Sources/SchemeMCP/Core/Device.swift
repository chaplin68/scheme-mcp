import Foundation

enum Platform: String, Codable, CaseIterable {
    case iOS
    case watchOS
    case tvOS
    case visionOS
    case macOS

    /// The name xcodebuild expects in a `-destination platform=` value.
    var destinationName: String { rawValue }

    /// Simulator runtimes report visionOS under its internal name.
    static func fromRuntimeToken(_ token: String) -> Platform? {
        switch token.lowercased() {
        case "ios": return .iOS
        case "watchos": return .watchOS
        case "tvos": return .tvOS
        case "xros", "visionos": return .visionOS
        case "macos": return .macOS
        default: return nil
        }
    }
}

enum DeviceKind: String, Codable {
    case simulator
    case physical
    case mac
}

enum DeviceState: String, Codable {
    case booted
    case shutdown
    case connected
    case unavailable

    var isReady: Bool { self == .booted || self == .connected }
}

struct Device: Identifiable, Codable, Equatable {
    /// The UDID passed to `xcodebuild -destination id=` and to simctl/devicectl.
    let id: String
    let name: String
    let kind: DeviceKind
    let platform: Platform
    let osVersion: String
    let state: DeviceState
    /// The hardware the device *is*, independent of what it is called: the marketing name for
    /// a physical device ("iPhone 15 Pro"), the simulator device type for a simulator
    /// ("iPhone 17 Pro"). `name` is editable on both, so the family is read from here.
    let modelName: String?
    /// Raw state devicectl reported for a physical device, verbatim. Carried so a refusal to
    /// install can say *what* the tool actually saw instead of guessing on the user's behalf.
    var statusDetail: String?

    /// Whether this device is the kind the selector named ("iPhone", "iPad"), or true when the
    /// selector named no family at all. The model is checked first and the name second: a
    /// renamed simulator no longer says what it is, and a device someone named "iPad-rig" is
    /// still the iPhone it was created as.
    func isFamily(_ needle: String?) -> Bool {
        guard let needle else { return true }
        if let modelName { return modelName.localizedCaseInsensitiveContains(needle) }
        return name.localizedCaseInsensitiveContains(needle)
    }

    var destination: String {
        switch kind {
        case .mac:
            return "platform=macOS"
        case .simulator:
            return "platform=\(platform.destinationName) Simulator,id=\(id)"
        case .physical:
            // Deliberately generic rather than `id=<udid>`. Install and launch go through
            // devicectl, so xcodebuild is only being asked which SDK and arch to build for — it
            // never needs to reach the device. Naming the device makes xcodebuild block until it
            // can open its own connection (30s per attempt, `man xcodebuild`), which fails outright
            // for a Wi-Fi-attached device even though devicectl talks to it fine; the products it
            // writes are byte-for-byte the same Debug-iphoneos bundle either way.
            return "generic/platform=\(platform.destinationName)"
        }
    }

    /// Xcode's build-products subdirectory for this device, e.g. `Debug-iphonesimulator`.
    var sdkSuffix: String {
        switch (platform, kind) {
        case (.macOS, _), (_, .mac): return "maccatalyst"
        case (.iOS, .simulator): return "iphonesimulator"
        case (.iOS, .physical): return "iphoneos"
        case (.watchOS, .simulator): return "watchsimulator"
        case (.watchOS, .physical): return "watchos"
        case (.tvOS, .simulator): return "appletvsimulator"
        case (.tvOS, .physical): return "appletvos"
        case (.visionOS, .simulator): return "xrsimulator"
        case (.visionOS, .physical): return "xros"
        }
    }

    var displayName: String {
        let suffix: String
        switch kind {
        case .simulator: suffix = "Simulator, \(platform.rawValue) \(osVersion)"
        case .physical: suffix = "Device, \(platform.rawValue) \(osVersion)"
        case .mac: suffix = "My Mac"
        }
        return "\(name) (\(suffix))"
    }

    static func myMac() -> Device {
        Device(
            id: "macos",
            name: "My Mac",
            kind: .mac,
            platform: .macOS,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            state: .connected,
            modelName: nil
        )
    }
}
