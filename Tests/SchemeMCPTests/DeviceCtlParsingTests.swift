import XCTest
@testable import SchemeMCP

/// Shapes taken verbatim from `xcrun devicectl list devices --json-output` (Xcode 26).
final class DeviceCtlParsingTests: XCTestCase {
    private func json(connection: String, deviceExtras: String = "") -> Data {
        """
        {"result":{"devices":[{
          "hardwareProperties":{"udid":"00001111-2222","platform":"iOS",
            "deviceType":"iPhone","marketingName":"iPhone 15 Pro"},
          "deviceProperties":{"name":"Test Phone","osVersionNumber":"26.6.1"\(deviceExtras)},
          "connectionProperties":{\(connection)}
        }]}}
        """.data(using: .utf8)!
    }

    /// The regression this file exists for: a device that is attached but has no tunnel up
    /// right now — the normal state after an OS update reboots it — must stay usable.
    func testAttachedDeviceWithoutTunnelIsConnected() throws {
        let devices = try DeviceCtl.parse(json(
            connection: #""pairingState":"paired","transportType":"wired","tunnelState":"unavailable""#,
            deviceExtras: #","bootState":"booted","ddiServicesAvailable":false"#
        ))
        XCTAssertEqual(devices.first?.state, .connected)
    }

    func testAttachedDeviceWithTunnelIsConnected() throws {
        let devices = try DeviceCtl.parse(json(
            connection: #""pairingState":"paired","transportType":"wired","tunnelState":"connected""#
        ))
        XCTAssertEqual(devices.first?.state, .connected)
    }

    func testDetachedDeviceIsUnavailable() throws {
        let devices = try DeviceCtl.parse(json(
            connection: #""pairingState":"paired","tunnelState":"unavailable""#
        ))
        XCTAssertEqual(devices.first?.state, .unavailable)
    }

    func testUnpairedDeviceIsUnavailable() throws {
        let devices = try DeviceCtl.parse(json(
            connection: #""pairingState":"unpaired","transportType":"wired","tunnelState":"connected""#
        ))
        XCTAssertEqual(devices.first?.state, .unavailable)
    }

    func testStatusDetailCarriesRawDevicectlState() throws {
        let device = try DeviceCtl.parse(json(
            connection: #""pairingState":"paired","tunnelState":"unavailable""#,
            deviceExtras: #","ddiServicesAvailable":false"#
        )).first
        let detail = try XCTUnwrap(device?.statusDetail)
        XCTAssertTrue(detail.contains("pairingState=paired"), detail)
        XCTAssertTrue(detail.contains("transportType=none"), detail)
        XCTAssertTrue(detail.contains("tunnelState=unavailable"), detail)
        XCTAssertTrue(detail.contains("ddiServicesAvailable=false"), detail)
    }
}
