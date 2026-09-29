import Foundation

/// Turns a raw line from an app or the system log into something safe and readable to draw
/// inside a pane.
///
/// Deliberately forgiving: log output arrives from several sources (os_log compact style,
/// raw stdout over a pty, devicectl) with different shapes, so anything unrecognised is
/// passed through rather than mangled.
enum LogFormatter {
    /// Sanitised, timestamp-shortened text with no escape sequences. Filters match against
    /// this, and it is what `job_log` returns: an escape sequence is noise to an agent.
    static func plainLine(_ raw: String) -> String {
        shortenTimestamp(unquote(sanitize(raw)))
    }

    /// Strips anything that would move the cursor or inject styling of its own. A stray
    /// escape sequence from an app can otherwise repaint half the dashboard.
    static func sanitize(_ line: String) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        var inEscape = false

        for character in line {
            if inEscape {
                // CSI sequences end on a letter; this also covers short ESC-letter forms.
                if character.isLetter { inEscape = false }
                continue
            }
            guard let scalar = character.unicodeScalars.first else { continue }
            switch scalar.value {
            case 0x1B:
                inEscape = true
            case 0x09:
                result.append("    ")  // tabs render at unpredictable widths inside a pane
            case 0..<0x20, 0x7F:
                continue               // CR, BEL, backspace and friends
            default:
                result.append(character)
            }
        }
        return result
    }

    /// `simctl launch --console` wraps every line of app output in double quotes.
    static func unquote(_ line: String) -> String {
        guard line.count > 1, line.hasPrefix("\""), line.hasSuffix("\"") else { return line }
        return String(line.dropFirst().dropLast())
    }

    /// Collapses `2026-07-27 23:59:58 +0000` to `23:59:58`. The date repeats on every line
    /// of a session and costs a third of a narrow pane.
    static func shortenTimestamp(_ line: String) -> String {
        guard let stamp = findTimestamp(in: line) else { return line }
        return line.replacingCharacters(in: stamp.range, with: stamp.time)
    }

    /// Finds `YYYY-MM-DD HH:MM:SS[.fff][ ±ZZZZ]` and reports its range plus the time part.
    private static func findTimestamp(in line: String) -> (range: Range<String.Index>, time: String)? {
        let characters = Array(line)
        // Only the head is searched: a date further in is payload, not a stamp.
        let limit = min(characters.count, 64)
        var index = 0

        while index + 19 <= limit {
            defer { index += 1 }
            guard isDigits(characters, index, 4), characters[index + 4] == "-",
                  isDigits(characters, index + 5, 2), characters[index + 7] == "-",
                  isDigits(characters, index + 8, 2), characters[index + 10] == " ",
                  isDigits(characters, index + 11, 2), characters[index + 13] == ":",
                  isDigits(characters, index + 14, 2), characters[index + 16] == ":",
                  isDigits(characters, index + 17, 2) else { continue }

            var end = index + 19
            if end < characters.count, characters[end] == "." {
                var fraction = end + 1
                while fraction < characters.count, characters[fraction].isNumber { fraction += 1 }
                end = fraction
            }
            if end + 5 < characters.count, characters[end] == " ",
               characters[end + 1] == "+" || characters[end + 1] == "-",
               isDigits(characters, end + 2, 4) {
                end += 6
            }

            let start = line.index(line.startIndex, offsetBy: index)
            let finish = line.index(line.startIndex, offsetBy: end)
            let time = String(characters[(index + 11)..<(index + 19)])
            return (start..<finish, time)
        }
        return nil
    }

    private static func isDigits(_ characters: [Character], _ start: Int, _ count: Int) -> Bool {
        guard start + count <= characters.count else { return false }
        return (start..<(start + count)).allSatisfy { characters[$0].isNumber }
    }
}
