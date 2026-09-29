import XCTest
@testable import SchemeMCP

/// `job_log`'s `contains` is the only filtering this tool does, and the rule it follows is the
/// one thing about it an agent can get wrong.
final class LogFilterTests: XCTestCase {
    func testAnEmptyQueryMatchesEverything() {
        XCTAssertTrue(LogFilter.matches("anything at all", query: ""))
        XCTAssertTrue(LogFilter.matches("", query: ""))
    }

    func testMatchingIsSubstringNotWholeLine() {
        XCTAssertTrue(LogFilter.matches("12:04:11 MyApp tabCount=3", query: "tabCount"))
        XCTAssertFalse(LogFilter.matches("12:04:11 MyApp tabCount=3", query: "tabIndex"))
    }

    func testCaseIsIgnored() {
        XCTAssertTrue(LogFilter.matches("fatal error: index out of range", query: "ERROR"))
        XCTAssertTrue(LogFilter.matches("FATAL ERROR", query: "fatal"))
    }

    /// An agent's query and a device's output need not agree on width. Dropping this option
    /// makes a full-width log line unsearchable by an ASCII query, with no error to explain it.
    func testWidthIsIgnoredInBothDirections() {
        XCTAssertTrue(LogFilter.matches("ログ: ｅｒｒｏｒ が出た", query: "error"))
        XCTAssertTrue(LogFilter.matches("log: error occurred", query: "ｅｒｒｏｒ"))
    }

    func testAQueryLongerThanTheLineDoesNotMatch() {
        XCTAssertFalse(LogFilter.matches("err", query: "error"))
    }
}
