import XCTest
@testable import SchemeMCP

final class DeviceTests: XCTestCase {
    private func makeDevice(
        kind: DeviceKind,
        platform: Platform,
        state: DeviceState = .shutdown,
        name: String = "Test",
        os: String = "17.0"
    ) -> Device {
        Device(id: "UDID-\(name)", name: name, kind: kind, platform: platform,
               osVersion: os, state: state, modelName: nil)
    }

    func testSimulatorDestinationUsesSimulatorPlatform() {
        let device = makeDevice(kind: .simulator, platform: .iOS)
        XCTAssertEqual(device.destination, "platform=iOS Simulator,id=UDID-Test")
        XCTAssertEqual(device.sdkSuffix, "iphonesimulator")
    }

    /// Physical builds must not name the device: `id=<udid>` makes xcodebuild wait for its own
    /// connection to the hardware, which a Wi-Fi-attached device fails, while install goes
    /// through devicectl anyway.
    func testPhysicalDestinationIsGenericSoTheBuildNeverWaitsOnTheDevice() {
        let device = makeDevice(kind: .physical, platform: .iOS)
        XCTAssertEqual(device.destination, "generic/platform=iOS")
        XCTAssertFalse(device.destination.contains("id="))
        XCTAssertEqual(device.sdkSuffix, "iphoneos")
    }

    func testWatchAndVisionSdkSuffixes() {
        XCTAssertEqual(makeDevice(kind: .simulator, platform: .watchOS).sdkSuffix, "watchsimulator")
        XCTAssertEqual(makeDevice(kind: .physical, platform: .watchOS).sdkSuffix, "watchos")
        XCTAssertEqual(makeDevice(kind: .simulator, platform: .visionOS).sdkSuffix, "xrsimulator")
    }

    func testMacDestination() {
        XCTAssertEqual(Device.myMac().destination, "platform=macOS")
    }

    func testRuntimeIdentifierParsing() {
        let parsed = Simctl.parseRuntime("com.apple.CoreSimulator.SimRuntime.iOS-17-2")
        XCTAssertEqual(parsed?.platform, .iOS)
        XCTAssertEqual(parsed?.version, "17.2")

        let watch = Simctl.parseRuntime("com.apple.CoreSimulator.SimRuntime.watchOS-11-0")
        XCTAssertEqual(watch?.platform, .watchOS)
        XCTAssertEqual(watch?.version, "11.0")

        // visionOS runtimes are still published under their internal xrOS name.
        XCTAssertEqual(Simctl.parseRuntime("com.apple.CoreSimulator.SimRuntime.xrOS-2-0")?.platform, .visionOS)
        XCTAssertNil(Simctl.parseRuntime("something.else"))
    }

    func testVersionComparisonIsNumericNotLexicographic() {
        XCTAssertEqual(compareVersions("17.10", "17.9"), .orderedDescending)
        XCTAssertEqual(compareVersions("18.0", "17.9"), .orderedDescending)
        XCTAssertEqual(compareVersions("17.0", "17.0.0"), .orderedSame)
    }

    func testRankingPutsReadyDevicesAndHardwareFirst() {
        let catalog = DeviceCatalog(
            simulators: [
                makeDevice(kind: .simulator, platform: .iOS, state: .shutdown, name: "Old", os: "16.0"),
                makeDevice(kind: .simulator, platform: .iOS, state: .booted, name: "Booted", os: "17.0")
            ],
            physical: [
                makeDevice(kind: .physical, platform: .iOS, state: .connected, name: "Phone", os: "17.5")
            ]
        )
        let ranked = catalog.ranked()
        XCTAssertEqual(ranked.map(\.name), ["Phone", "Booted", "Old"])
    }

    func testAutoSelectorPrefersConnectedHardware() {
        let catalog = DeviceCatalog(
            simulators: [makeDevice(kind: .simulator, platform: .iOS, state: .booted, name: "Sim")],
            physical: [makeDevice(kind: .physical, platform: .iOS, state: .connected, name: "Phone")]
        )
        XCTAssertEqual(catalog.resolve(.auto, projectPlatform: .iOS)?.name, "Phone")
    }

    func testAutoSelectorFallsBackToBootedSimulatorWhenNoHardware() {
        let catalog = DeviceCatalog(
            simulators: [
                makeDevice(kind: .simulator, platform: .iOS, state: .shutdown, name: "Cold", os: "18.0"),
                makeDevice(kind: .simulator, platform: .iOS, state: .booted, name: "Warm", os: "17.0")
            ],
            physical: []
        )
        XCTAssertEqual(catalog.resolve(.auto, projectPlatform: .iOS)?.name, "Warm")
    }

    func testUnreachableHardwareIsNotChosenAutomatically() {
        let catalog = DeviceCatalog(
            simulators: [makeDevice(kind: .simulator, platform: .iOS, state: .shutdown, name: "Sim")],
            physical: [makeDevice(kind: .physical, platform: .iOS, state: .unavailable, name: "Unplugged")]
        )
        XCTAssertEqual(catalog.resolve(.auto, projectPlatform: .iOS)?.name, "Sim")
    }

    func testIpadSelectorPrefersIpadSimulator() {
        let catalog = DeviceCatalog(
            simulators: [
                makeDevice(kind: .simulator, platform: .iOS, name: "iPhone 16"),
                makeDevice(kind: .simulator, platform: .iOS, name: "iPad Pro 13-inch")
            ],
            physical: []
        )
        XCTAssertEqual(catalog.resolve(.simIpad, projectPlatform: .iOS)?.name, "iPad Pro 13-inch")
    }
}

/// A selector names a kind of device. Answering with a different kind is worse than answering
/// with nothing: `run sim-ipad` on a machine with no iPad simulator used to launch on an
/// iPhone, and `run iphone` with only an iPad attached installed to the iPad, both in silence.
final class SelectorHonestyTests: XCTestCase {
    private func device(_ name: String, _ kind: DeviceKind, _ platform: Platform = .iOS) -> Device {
        Device(id: "UDID-\(name)", name: name, kind: kind, platform: platform,
               osVersion: "26.0", state: .shutdown, modelName: nil)
    }

    private func catalog(_ devices: [Device]) -> DeviceCatalog {
        DeviceCatalog(simulators: devices.filter { $0.kind == .simulator },
                      physical: devices.filter { $0.kind == .physical })
    }

    func testAnIpadSelectorDoesNotSettleForAnIphone() {
        let only = catalog([device("iPhone 17 Pro", .simulator)])
        XCTAssertNil(only.resolve(.simIpad, projectPlatform: .iOS))
        XCTAssertTrue(only.candidates(for: .simIpad, projectPlatform: .iOS).isEmpty,
                      "an iPhone is not a candidate for an iPad selector")
    }

    func testAPhysicalIphoneSelectorDoesNotSettleForAnIpad() {
        let only = catalog([device("iPad Pro", .physical)])
        XCTAssertNil(only.resolve(.iphone, projectPlatform: .iOS))
        XCTAssertTrue(only.candidates(for: .iphone, projectPlatform: .iOS).isEmpty)
    }

    /// A watch selector names a platform, not a name, and the project's platform must not
    /// override it — that is how every iOS simulator became a candidate for `sim-watch`.
    func testAWatchSelectorLooksAtWatchOSRegardlessOfTheProject() {
        let mixed = catalog([device("iPhone 17 Pro", .simulator),
                             device("Apple Watch Series 10", .simulator, .watchOS)])
        XCTAssertEqual(mixed.resolve(.simWatch, projectPlatform: .iOS)?.platform, .watchOS)
        XCTAssertEqual(mixed.candidates(for: .simWatch, projectPlatform: .iOS).count, 1)
    }

    func testAMatchingSelectorStillFindsItsDevice() {
        let both = catalog([device("iPhone 17 Pro", .simulator), device("iPad Air", .simulator)])
        XCTAssertEqual(both.resolve(.simIpad, projectPlatform: .iOS)?.name, "iPad Air")
        XCTAssertEqual(both.resolve(.simIphone, projectPlatform: .iOS)?.name, "iPhone 17 Pro")
    }

    /// `sim` used to add an "Apple Watch" needle on top of an already-watchOS pool. The needle
    /// was matched against the name, so renaming the simulator made `run sim` on a watchOS
    /// project find nothing at all.
    func testSimOnAWatchProjectDoesNotAlsoRequireTheWordWatchInTheName() {
        let renamed = catalog([device("CI-Watch", .simulator, .watchOS)])
        XCTAssertEqual(renamed.resolve(.sim, projectPlatform: .watchOS)?.name, "CI-Watch")
        XCTAssertEqual(renamed.candidates(for: .sim, projectPlatform: .watchOS).count, 1)
    }

    /// `simctl create` takes any name, so the family has to come from the device type. Before
    /// this, a CI simulator created from an iPhone device type was unreachable by `sim-iphone`
    /// *and* absent from the candidate list, so no picker was offered either.
    func testARenamedSimulatorIsStillFoundByItsDeviceType() {
        let ci = Device(id: "UDID-CI", name: "CI-Sim", kind: .simulator, platform: .iOS,
                        osVersion: "26.0", state: .shutdown, modelName: "iPhone 17 Pro")
        let only = catalog([ci])
        XCTAssertEqual(only.resolve(.simIphone, projectPlatform: .iOS)?.id, "UDID-CI")
        XCTAssertEqual(only.candidates(for: .simIphone, projectPlatform: .iOS).count, 1)
        XCTAssertNil(only.resolve(.simIpad, projectPlatform: .iOS), "and it is still not an iPad")
    }

    /// The device type wins over the name outright. A simulator someone called "iPad-rig" is
    /// the iPhone it was created as, and answering `sim-ipad` with it is the silent wrong
    /// answer this whole class exists to prevent.
    func testTheNameDoesNotOverrideTheDeviceType() {
        let misnamed = Device(id: "UDID-X", name: "iPad-rig", kind: .simulator, platform: .iOS,
                              osVersion: "26.0", state: .shutdown, modelName: "iPhone 17 Pro")
        let only = catalog([misnamed])
        XCTAssertNil(only.resolve(.simIpad, projectPlatform: .iOS))
        XCTAssertEqual(only.resolve(.simIphone, projectPlatform: .iOS)?.id, "UDID-X")
    }

    /// `resolve` hard-codes iOS for the iPhone/iPad selectors while `candidates` narrowed by
    /// the project's platform, so on a watchOS project `run sim-iphone` picked a device that
    /// the picker would have said did not exist.
    func testAnIphoneSelectorIgnoresANonIosProjectInBothHalves() {
        let mixed = catalog([device("iPhone 17 Pro", .simulator),
                             device("Apple Watch Series 10", .simulator, .watchOS)])
        for platform in [Platform.watchOS, .macOS, nil] {
            XCTAssertEqual(mixed.resolve(.simIphone, projectPlatform: platform)?.name, "iPhone 17 Pro",
                           "\(String(describing: platform))")
            XCTAssertEqual(mixed.candidates(for: .simIphone, projectPlatform: platform).map(\.name),
                           ["iPhone 17 Pro"], "\(String(describing: platform))")
        }
    }

    /// The two halves must not drift again: whatever `resolve` settles on has to be something
    /// the picker would have offered, for every selector over the same catalog.
    func testResolveNeverPicksSomethingCandidatesWouldNotOffer() {
        let everything = catalog([device("iPhone 17 Pro", .simulator),
                                  device("iPad Air", .simulator),
                                  device("Apple Watch Series 10", .simulator, .watchOS),
                                  device("Test iPhone", .physical),
                                  device("Studio iPad", .physical)])
        for selector in DeviceSelector.allCases where selector != .mac {
            for platform in [Platform.iOS, .watchOS, nil] {
                guard let picked = everything.resolve(selector, projectPlatform: platform) else { continue }
                XCTAssertTrue(everything.candidates(for: selector, projectPlatform: platform).contains(picked),
                              "\(selector.rawValue) on \(String(describing: platform)) picked \(picked.name)")
            }
        }
    }
}

/// The family of a simulator comes from its device type identifier, which `simctl create`
/// assigns and nothing afterwards changes.
final class SimulatorDeviceTypeTests: XCTestCase {
    func testDeviceTypeIdentifierBecomesAReadableModelName() {
        XCTAssertEqual(Simctl.parseDeviceType("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"),
                       "iPhone 17 Pro")
        XCTAssertEqual(Simctl.parseDeviceType("com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3"),
                       "iPad Air 11 inch M3")
    }

    /// Older `simctl` output, or an entry without one, must leave the name to speak for itself
    /// rather than becoming an empty model that matches nothing.
    func testAnAbsentOrUnexpectedIdentifierIsNil() {
        XCTAssertNil(Simctl.parseDeviceType(nil))
        XCTAssertNil(Simctl.parseDeviceType(""))
        XCTAssertNil(Simctl.parseDeviceType("com.apple.CoreSimulator.SimDeviceType."))
        XCTAssertNil(Simctl.parseDeviceType("iPhone-17-Pro"))
    }
}
