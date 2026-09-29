import XCTest
@testable import SchemeMCP

/// Covers the boundary where pty output enters the tool. This is the layer that let a
/// trailing CR through and wrecked the framed layout downstream.
final class ShellLineReaderTests: XCTestCase {
    private func collectLines(from command: String) throws -> [String] {
        var lines: [String] = []
        let lock = NSLock()
        let handle = try Shell.stream("/bin/sh", ["-c", command]) { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        _ = handle.waitUntilExit()
        // The reader drains on the termination handler, which lands just after exit.
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func testCarriageReturnsFromCrlfOutputAreStripped() throws {
        let lines = try collectLines(from: #"printf 'first\r\nsecond\r\n'"#)
        XCTAssertEqual(lines, ["first", "second"])
        XCTAssertFalse(lines.contains { $0.contains("\r") })
    }

    func testPlainLfOutputIsUnaffected() throws {
        let lines = try collectLines(from: #"printf 'a\nb\n'"#)
        XCTAssertEqual(lines, ["a", "b"])
    }

    func testFinalLineWithoutTrailingNewlineIsStillDelivered() throws {
        let lines = try collectLines(from: #"printf 'no newline'"#)
        XCTAssertEqual(lines, ["no newline"])
    }

    func testCarriageReturnInTheMiddleOfALineIsLeftToTheFormatter() throws {
        // Only the line terminator is the reader's business; interior control characters
        // are the display layer's problem.
        let lines = try collectLines(from: #"printf 'a\rb\n'"#)
        XCTAssertEqual(lines, ["a\rb"])
        XCTAssertEqual(LogFormatter.sanitize(lines[0]), "ab")
    }
}
