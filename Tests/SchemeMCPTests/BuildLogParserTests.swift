import XCTest
@testable import SchemeMCP

final class BuildLogParserTests: XCTestCase {
    func testParsesSwiftErrorWithLineAndColumn() {
        let line = "/Users/me/App/Sources/ViewController.swift:42:17: error: cannot find 'foo' in scope"
        guard case .diagnostic(let diagnostic)? = BuildLogParser.parse(line) else {
            return XCTFail("expected a diagnostic")
        }
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.line, 42)
        XCTAssertEqual(diagnostic.column, 17)
        XCTAssertEqual(diagnostic.message, "cannot find 'foo' in scope")
        XCTAssertEqual(diagnostic.location, "ViewController.swift:42:17")
    }

    func testParsesWarningWithoutColumn() {
        let line = "/tmp/App/Model.swift:7: warning: variable 'x' was never used"
        guard case .diagnostic(let diagnostic)? = BuildLogParser.parse(line) else {
            return XCTFail("expected a diagnostic")
        }
        XCTAssertEqual(diagnostic.severity, .warning)
        XCTAssertEqual(diagnostic.line, 7)
        XCTAssertNil(diagnostic.column)
    }

    func testParsesToolLevelErrorWithoutLocation() {
        guard case .diagnostic(let diagnostic)? = BuildLogParser.parse("error: no such module 'Alamofire'") else {
            return XCTFail("expected a diagnostic")
        }
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertNil(diagnostic.file)
        XCTAssertEqual(diagnostic.message, "no such module 'Alamofire'")
    }

    func testParsesLinkerErrorKeepingToolNameAsFile() {
        guard case .diagnostic(let diagnostic)? = BuildLogParser.parse("ld: error: framework not found Pods") else {
            return XCTFail("expected a diagnostic")
        }
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.message, "framework not found Pods")
    }

    func testParsesBuildOutcomes() {
        XCTAssertEqual(BuildLogParser.parseOutcome("** BUILD SUCCEEDED **"), .buildSucceeded)
        XCTAssertEqual(BuildLogParser.parseOutcome("** BUILD FAILED **"), .buildFailed)
        XCTAssertEqual(BuildLogParser.parseOutcome("** TEST FAILED **"), .testFailed)
        XCTAssertNil(BuildLogParser.parseOutcome("building..."))
    }

    func testParsesXCTestSuccessAndFailure() {
        let passed = "Test Case '-[MyAppTests testAddition]' passed (0.003 seconds)."
        guard case .testCase(let success)? = BuildLogParser.parse(passed) else {
            return XCTFail("expected a test case")
        }
        XCTAssertEqual(success.suite, "MyAppTests")
        XCTAssertEqual(success.name, "testAddition")
        XCTAssertTrue(success.passed)
        XCTAssertEqual(success.duration ?? 0, 0.003, accuracy: 0.0001)

        let failed = "Test Case '-[MyAppTests testSubtraction]' failed (0.010 seconds)."
        guard case .testCase(let failure)? = BuildLogParser.parse(failed) else {
            return XCTFail("expected a test case")
        }
        XCTAssertFalse(failure.passed)
    }

    func testParsesSwiftTestingLine() {
        let line = "✔ Test exampleWorks() passed after 0.01 seconds."
        guard case .testCase(let result)? = BuildLogParser.parse(line) else {
            return XCTFail("expected a test case")
        }
        XCTAssertEqual(result.name, "exampleWorks()")
        XCTAssertTrue(result.passed)
    }

    func testRecognisesCompilePhaseAndExtractsFilename() {
        let line = "SwiftCompile normal arm64 /Users/me/App/Sources/Feature/TabBar.swift (in target 'App')"
        guard case .phase(let action, let subject)? = BuildLogParser.parse(line) else {
            return XCTFail("expected a phase")
        }
        XCTAssertEqual(action, "Compiling")
        XCTAssertEqual(subject, "TabBar.swift")
    }

    func testFallsBackToTargetNameWhenNoFileInPhaseLine() {
        let line = "CodeSign /Users/me/Build/Products/Debug-iphoneos/App.app (in target 'App' from project 'App')"
        guard case .phase(let action, let subject)? = BuildLogParser.parse(line) else {
            return XCTFail("expected a phase")
        }
        XCTAssertEqual(action, "Signing")
        XCTAssertEqual(subject, "App.app")
    }

    func testIgnoresBlankAndUnstructuredLines() {
        XCTAssertNil(BuildLogParser.parse(""))
        XCTAssertNil(BuildLogParser.parse("    "))
        XCTAssertNil(BuildLogParser.parse("Build settings from command line:"))
    }

    /// Notes are recognised so they can be rendered live, but they must not survive into
    /// the report — xcodebuild emits one per re-diagnosed file and they swamp the summary.
    func testNotesAreParsedButNotRecorded() {
        guard case .diagnostic(let diagnostic)? = BuildLogParser.parse("note: Using new build system") else {
            return XCTFail("expected a note diagnostic")
        }
        XCTAssertEqual(diagnostic.severity, .note)

        let report = BuildReport()
        report.ingest("note: Using new build system")
        report.ingest("/tmp/A.swift:1:1: error: boom")
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertEqual(report.diagnostics.first?.severity, .error)
    }

    func testReportDeduplicatesRepeatedWarnings() {
        let report = BuildReport()
        let line = "/tmp/A.swift:9:2: warning: unused variable 'x'"
        report.ingest(line)
        report.ingest(line)
        XCTAssertEqual(report.warnings.count, 2, "raw ingest keeps every occurrence")
        XCTAssertEqual(report.uniqueDiagnostics(severity: .warning).count, 1)
    }

    func testLocationParsingHandlesWindowsStyleColonsInPath() {
        let parsed = BuildLogParser.parseLocation("/Users/me/My:Project/File.swift:10:3")
        XCTAssertEqual(parsed.file, "/Users/me/My:Project/File.swift")
        XCTAssertEqual(parsed.line, 10)
        XCTAssertEqual(parsed.column, 3)
    }
}

// MARK: - Destination errors

extension BuildLogParserTests {
    /// The line xcodebuild prints under "Available destinations" when the device exists but
    /// cannot be connected to. Its `error:` has no trailing space, so plain marker matching
    /// used to drop the only useful part of a destination timeout.
    func testParsesDestinationConnectionError() {
        let line = "\t\t{ platform:iOS, arch:arm64, id:00001111-2222, name:Test Phone,"
            + " error:A connection to this device could not be established. }"
        guard case .diagnostic(let diagnostic)? = BuildLogParser.parse(line) else {
            return XCTFail("expected a diagnostic, got \(String(describing: BuildLogParser.parse(line)))")
        }
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(
            diagnostic.message,
            "Test Phone is unusable as a destination: A connection to this device could not be established."
        )
    }

    func testHealthyDestinationLineIsNotADiagnostic() {
        let line = "\t\t{ platform:iOS, arch:arm64, id:00001111-2222, name:Test Phone }"
        XCTAssertNil(BuildLogParser.parse(line))
    }
}
