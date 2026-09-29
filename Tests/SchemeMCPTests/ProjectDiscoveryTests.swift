import XCTest
@testable import SchemeMCP

/// Discovery has to work from anywhere inside a project, the way git and npm do.
/// Requiring the repository root is the kind of limitation nobody reports — they just
/// assume the tool is broken.
final class ProjectDiscoveryTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-mcp-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = sandbox.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFindsContainerInTheStartingDirectory() throws {
        _ = try makeDirectory("MyApp.xcodeproj")
        XCTAssertEqual(
            XcodeProject.findContainerDirectory(startingAt: sandbox)?.standardizedFileURL,
            sandbox.standardizedFileURL
        )
    }

    func testFindsContainerFromANestedSubdirectory() throws {
        _ = try makeDirectory("MyApp.xcworkspace")
        let nested = try makeDirectory("MyApp/Sources/Feature")
        XCTAssertEqual(
            XcodeProject.findContainerDirectory(startingAt: nested)?.standardizedFileURL,
            sandbox.standardizedFileURL
        )
    }

    func testReturnsNilWhenThereIsNoProjectAnywhereAbove() throws {
        let orphan = try makeDirectory("just/some/folders")
        // The sandbox itself holds no container, so the walk reaches the filesystem root.
        let found = XcodeProject.findContainerDirectory(startingAt: orphan)
        XCTAssertNil(found, "unexpectedly matched \(found?.path ?? "")")
    }

    func testWorkspaceWinsOverProjectInTheSameDirectory() throws {
        _ = try makeDirectory("MyApp.xcodeproj")
        _ = try makeDirectory("MyApp.xcworkspace")
        // With CocoaPods the bare .xcodeproj does not link the pods.
        guard case .workspace(let url)? = XcodeProject.container(in: sandbox) else {
            return XCTFail("expected the workspace to win")
        }
        XCTAssertEqual(url.lastPathComponent, "MyApp.xcworkspace")
    }

    func testNearestAncestorWinsForNestedProjects() throws {
        _ = try makeDirectory("Outer.xcworkspace")
        let inner = try makeDirectory("Packages/Inner")
        _ = try makeDirectory("Packages/Inner/Inner.xcodeproj")
        XCTAssertEqual(
            XcodeProject.findContainerDirectory(startingAt: inner)?.standardizedFileURL,
            inner.standardizedFileURL
        )
    }

    func testConfigLoadReportsNoRootWhenThereIsNoConfigFile() throws {
        let nested = try makeDirectory("a/b")
        XCTAssertNil(try Config.load(startingAt: nested).root)
    }

    func testConfigLoadWalksUpToFindTheConfigFile() throws {
        // Written as JSON rather than through Config: this tool only ever reads the file, and
        // a test that needs a writer to exist would be pinning an API nothing else wants.
        try #"{"scheme":"FromConfig"}"#
            .write(to: sandbox.appendingPathComponent(".scheme-mcp.json"), atomically: true, encoding: .utf8)
        let nested = try makeDirectory("a/b/c")

        let loaded = try Config.load(startingAt: nested)
        XCTAssertEqual(loaded.root?.standardizedFileURL, sandbox.standardizedFileURL)
        XCTAssertEqual(loaded.config.scheme, "FromConfig")
    }
}

/// `derivedDataPath` handled an absolute path and the container paths did not, four lines
/// apart. `--workspace /Users/me/App.xcworkspace` was appended to the working directory, so
/// xcodebuild was asked for a path that could not exist.
final class ConfiguredPathResolutionTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/project")

    func testARelativePathIsResolvedAgainstTheRoot() {
        XCTAssertEqual(
            XcodeProject.resolvePath("App.xcworkspace", against: root).path,
            "/tmp/project/App.xcworkspace"
        )
    }

    func testAnAbsolutePathStandsOnItsOwn() {
        XCTAssertEqual(
            XcodeProject.resolvePath("/Users/me/App.xcworkspace", against: root).path,
            "/Users/me/App.xcworkspace"
        )
    }

    /// A shell expands a tilde, but not when the argument was quoted.
    func testATildeIsExpanded() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            XcodeProject.resolvePath("~/App.xcworkspace", against: root).path,
            "\(home)/App.xcworkspace"
        )
    }

    func testANestedRelativePathStillWorks() {
        XCTAssertEqual(
            XcodeProject.resolvePath("nested/App.xcodeproj", against: root).path,
            "/tmp/project/nested/App.xcodeproj"
        )
    }
}

/// A config file that is there but cannot be read used to be indistinguishable from one that is
/// not there: the walk carried on to the parent directory and could adopt an unrelated
/// project's settings, so a misplaced comma built the wrong scheme and said nothing.
final class BrokenConfigTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scheme-mcp-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAMalformedConfigIsReportedRatherThanSkipped() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"{ "scheme": "App",, }"#.write(
            to: directory.appendingPathComponent(Config.fileName), atomically: true, encoding: .utf8
        )

        XCTAssertThrowsError(try Config.load(startingAt: directory)) { error in
            XCTAssertTrue("\(error)".contains(Config.fileName), "the message names the file")
        }
    }

    func testAnAbsentConfigIsStillNotAnError() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (config, root) = try Config.load(startingAt: directory)
        XCTAssertNil(root)
        XCTAssertEqual(config, .empty)
    }

    func testAValidConfigIsFoundWithItsDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"{"scheme":"App"}"#.write(
            to: directory.appendingPathComponent(Config.fileName), atomically: true, encoding: .utf8
        )

        let (config, root) = try Config.load(startingAt: directory)
        XCTAssertEqual(config.scheme, "App")
        XCTAssertEqual(root?.standardizedFileURL, directory.standardizedFileURL)
    }
}
