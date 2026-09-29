import XCTest
@testable import SchemeMCP

/// Regression cover for a garbled log pane. The inputs here are verbatim captures from
/// `simctl launch --console-pty`, which is where the damage came from.
final class LogFormatterTests: XCTestCase {
    func testStripsCarriageReturnLeftByAPseudoTerminal() {
        // A surviving CR sends the cursor to column 0 mid-render and shreds the frame.
        let line = "app started\r"
        XCTAssertEqual(LogFormatter.sanitize(line), "app started")
        XCTAssertFalse(LogFormatter.plainLine(line).contains("\r"))
    }

    func testStripsEscapeSequencesSoAppsCannotRestyleTheDashboard() {
        let line = "\u{1B}[31mred text\u{1B}[0m and \u{1B}[2Jcleared"
        XCTAssertEqual(LogFormatter.sanitize(line), "red text and cleared")
    }

    func testExpandsTabsAndDropsOtherControlCharacters() {
        XCTAssertEqual(LogFormatter.sanitize("a\tb"), "a    b")
        XCTAssertEqual(LogFormatter.sanitize("bell\u{07}end"), "bellend")
    }

    func testRemovesTheQuotesSimctlWrapsAroundEveryLine() {
        XCTAssertEqual(LogFormatter.unquote("\"hello\""), "hello")
        XCTAssertEqual(LogFormatter.unquote("no quotes"), "no quotes")
        XCTAssertEqual(LogFormatter.unquote("\"unbalanced"), "\"unbalanced")
    }

    func testShortensFullTimestampToTimeOfDay() {
        let line = ">>🐙 2026-07-27 23:59:58 +0000 >> didFinishLaunching - App Launch"
        XCTAssertEqual(
            LogFormatter.shortenTimestamp(line),
            ">>🐙 23:59:58 >> didFinishLaunching - App Launch"
        )
    }

    func testShortensOsLogStyleTimestampWithMilliseconds() {
        let line = "2026-07-25 16:20:45.347 Df MyApp[123:456] message"
        XCTAssertEqual(LogFormatter.shortenTimestamp(line), "16:20:45 Df MyApp[123:456] message")
    }

    func testLeavesLinesWithoutATimestampAlone() {
        let line = "screen size: (390.0, 844.0)"
        XCTAssertEqual(LogFormatter.shortenTimestamp(line), line)
    }

    func testDoesNotMistakeAVersionNumberForATimestamp() {
        let line = "resolved dependency 1.2.3 for target"
        XCTAssertEqual(LogFormatter.shortenTimestamp(line), line)
    }

    /// End-to-end on the exact shape captured from the simulator.
    func testFullPipelineOnRealConsoleOutput() {
        let raw = "\">>🐙 2026-07-27 23:59:58 +0000 >> initialize(with:) - 🚀 App initialization started\"\r"
        let result = LogFormatter.plainLine(raw)
        XCTAssertFalse(result.contains("\r"))
        XCTAssertFalse(result.hasPrefix("\""))
        XCTAssertTrue(result.contains("23:59:58"))
        XCTAssertFalse(result.contains("2026-07-27"))
        XCTAssertTrue(result.contains("App initialization started"))
    }
}
