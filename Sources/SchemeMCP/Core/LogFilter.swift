import Foundation

/// Substring filtering for `job_log`.
enum LogFilter {
    /// Case- and width-insensitive. Width matters because an agent's query and a device's
    /// output need not agree on it: a log line carrying full-width `ｅｒｒｏｒ` should still be
    /// found by a query typed in ASCII, and the reverse.
    static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]

    static func matches(_ line: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return line.range(of: query, options: options) != nil
    }
}
