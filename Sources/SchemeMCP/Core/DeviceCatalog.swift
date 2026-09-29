import Foundation

/// Accepted in a tool call's `device` argument in place of a UDID: `sim`, `iphone`, …
enum DeviceSelector: String, CaseIterable {
    case auto
    case sim
    case simIphone = "sim-iphone"
    case simIpad = "sim-ipad"
    case simWatch = "sim-watch"
    case iphone
    case ipad
    case watch
    case device
    case mac

    var wantsSimulator: Bool {
        switch self {
        case .sim, .simIphone, .simIpad, .simWatch: return true
        default: return false
        }
    }

    /// The platform the selector names, when it names one. Only `auto`, `sim` and `device`
    /// take the project's — every other selector names a platform outright, and letting a
    /// watchOS project narrow `sim-iphone` to watchOS leaves it with nothing to offer while
    /// `resolve` happily returns an iPhone.
    var platformConstraint: Platform? {
        switch self {
        case .simWatch, .watch: return .watchOS
        case .simIphone, .simIpad, .iphone, .ipad: return .iOS
        default: return nil
        }
    }

    /// The kind of hardware the selector names, matched against the device's name.
    var nameConstraint: String? {
        switch self {
        case .simIphone, .iphone: return "iPhone"
        case .simIpad, .ipad: return "iPad"
        default: return nil
        }
    }

    var wantsPhysical: Bool {
        switch self {
        case .iphone, .ipad, .watch, .device: return true
        default: return false
        }
    }
}

/// Unified view over simulators, physical devices and the Mac, with the
/// selection rules that decide what to target when the caller names no device.
struct DeviceCatalog {
    let simulators: [Device]
    let physical: [Device]

    static func load(includeSimulators: Bool = true, includePhysical: Bool = true) -> DeviceCatalog {
        // Either source can fail independently (no Xcode simulators, no paired devices);
        // a failure in one must not hide the other.
        let sims = includeSimulators ? ((try? Simctl.listDevices()) ?? []) : []
        let devices = includePhysical ? ((try? DeviceCtl.listDevices()) ?? []) : []
        return DeviceCatalog(simulators: sims, physical: devices)
    }

    var all: [Device] { physical + simulators }

    /// Devices worth showing: connected hardware first, then booted simulators,
    /// then the rest sorted newest-OS-first.
    func ranked(for platform: Platform? = nil) -> [Device] {
        all
            .filter { platform == nil || $0.platform == platform }
            .sorted { lhs, rhs in
                if lhs.state.isReady != rhs.state.isReady { return lhs.state.isReady }
                if (lhs.kind == .physical) != (rhs.kind == .physical) { return lhs.kind == .physical }
                if lhs.osVersion != rhs.osVersion {
                    return compareVersions(lhs.osVersion, rhs.osVersion) == .orderedDescending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Resolves a selector to a concrete device, or nil when the caller should prompt.
    func resolve(_ selector: DeviceSelector, projectPlatform: Platform?) -> Device? {
        switch selector {
        case .mac:
            return .myMac()

        case .auto:
            // Prefer connected hardware, then a booted simulator, then the newest simulator.
            let candidates = ranked(for: projectPlatform)
            return candidates.first { $0.kind == .physical && $0.state == .connected }
                ?? candidates.first { $0.kind == .simulator && $0.state == .booted }
                ?? candidates.first { $0.kind == .simulator }

        // The platform filter already excludes everything of the wrong kind, so no selector
        // needs a family needle on top of it except the two that split iOS into iPhone/iPad.
        // `sim` used to add "Apple Watch" over an already-watchOS pool, which found nothing
        // once the simulator had been renamed.
        case .sim, .simIphone, .simIpad, .simWatch:
            return bestSimulator(
                platform: selector.platformConstraint ?? projectPlatform ?? .iOS,
                familyContains: selector.nameConstraint
            )

        case .iphone, .ipad, .watch:
            return bestPhysical(
                platform: selector.platformConstraint ?? .iOS,
                familyContains: selector.nameConstraint
            )

        case .device:
            return ranked(for: projectPlatform).first { $0.kind == .physical && $0.state == .connected }
        }
    }

    /// All devices a selector could plausibly mean — used to prompt when it is ambiguous.
    func candidates(for selector: DeviceSelector, projectPlatform: Platform?) -> [Device] {
        switch selector {
        case .mac: return [.myMac()]
        case .auto: return ranked(for: projectPlatform)
        default:
            // Constrained the same way `resolve` is. Listing every iOS simulator as a candidate
            // for `sim-watch` is how the caller ended up picking an iPhone for it: the selector
            // named a kind of device, and the list it was offered ignored that.
            let platform = selector.platformConstraint ?? projectPlatform
            return ranked(for: platform).filter { device in
                guard device.isFamily(selector.nameConstraint) else { return false }
                if selector.wantsSimulator { return device.kind == .simulator }
                if selector.wantsPhysical { return device.kind == .physical }
                return true
            }
        }
    }

    // No fallback to the wider pool in either of these. `sim-ipad` on a machine with no iPad
    // simulator used to launch on an iPhone without a word: the selector said which kind of
    // device, and answering with a different kind is worse than answering with nothing. Both
    // narrow with `isFamily`, the same predicate `candidates` uses, so the device `resolve`
    // picks is always one the picker would have offered.
    private func bestSimulator(platform: Platform, familyContains needle: String?) -> Device? {
        let pool = ranked(for: platform).filter { $0.kind == .simulator && $0.isFamily(needle) }
        return pool.first { $0.state == .booted } ?? pool.first
    }

    private func bestPhysical(platform: Platform, familyContains needle: String?) -> Device? {
        ranked(for: platform).first { $0.kind == .physical && $0.isFamily(needle) }
    }
}

/// Numeric-aware comparison so "17.10" sorts above "17.9".
func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
        let lhsPart = index < left.count ? left[index] : 0
        let rhsPart = index < right.count ? right[index] : 0
        if lhsPart != rhsPart { return lhsPart < rhsPart ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
}
