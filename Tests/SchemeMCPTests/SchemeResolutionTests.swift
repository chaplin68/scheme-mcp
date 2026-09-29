import XCTest
@testable import SchemeMCP

/// Scheme selection decides what every other command acts on, so the precedence between
/// config, memory and convention needs pinning down.
final class SchemeResolutionTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-mcp-scheme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testAmbiguousSchemeErrorCarriesTheCandidates() {
        let error = AmbiguousSchemeError(schemes: ["App", "Widget", "Tests"])
        XCTAssertEqual(error.schemes.count, 3)
        // The message has to name them, and name the way out. There is no one to prompt here:
        // whatever it says is what the agent gets, so it has to be actionable on its own.
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("App"))
        XCTAssertTrue(description.contains("Widget"))
        XCTAssertTrue(description.contains("Tests"))
        XCTAssertTrue(description.contains("scheme"), "says which argument settles it")
        XCTAssertTrue(description.contains(".scheme-mcp.json"), "and the durable alternative")
    }

    /// Regression for a real CocoaPods workspace: 15 schemes, 12 of them vendored, with the
    /// app's own scheme sorting near the bottom alphabetically.
    func testRankingSurfacesTheAppSchemeAheadOfDependencies() throws {
        let container = XcodeProject.Container.workspace(
            sandbox.appendingPathComponent("MyApp.xcworkspace")
        )
        let schemes = [
            "Ads-Global",
            "Google-Mobile-Ads-SDK",
            "Pods-MyApp",
            "Pods-MyAppTests",
            "MyApp",
            "MyAppWidgetExtension"
        ]
        let ranked = XcodeProject.rankSchemes(schemes, container: container, root: sandbox)

        XCTAssertEqual(ranked.first, "MyApp", "the app's own scheme must come first")
        XCTAssertTrue(
            ranked.suffix(2).allSatisfy { $0.hasPrefix("Pods-") },
            "Pods schemes belong last, got \(ranked)"
        )
    }

    func testRankingPromotesSchemesSharedByTheProjectItself() throws {
        // A shared scheme file next to the workspace marks a first-party scheme; vendored
        // ones live under Pods/ and are not scanned.
        let schemeDirectory = sandbox
            .appendingPathComponent("MyApp.xcodeproj/xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemeDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: schemeDirectory.appendingPathComponent("Staging.xcscheme").path,
            contents: Data()
        )

        let container = XcodeProject.Container.workspace(
            sandbox.appendingPathComponent("MyApp.xcworkspace")
        )
        let ranked = XcodeProject.rankSchemes(
            ["Google-Mobile-Ads-SDK", "Staging", "Pods-MyApp"],
            container: container,
            root: sandbox
        )
        XCTAssertEqual(ranked, ["Staging", "Google-Mobile-Ads-SDK", "Pods-MyApp"])
    }

    func testRankingIsStableWithinATier() {
        let container = XcodeProject.Container.project(
            sandbox.appendingPathComponent("Other.xcodeproj")
        )
        let schemes = ["Zebra", "Alpha", "Middle"]
        // No tier distinguishes them, so xcodebuild's original order is preserved.
        XCTAssertEqual(
            XcodeProject.rankSchemes(schemes, container: container, root: sandbox),
            schemes
        )
    }

}
