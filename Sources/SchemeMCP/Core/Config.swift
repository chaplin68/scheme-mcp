import Foundation

/// Per-project settings read from `.scheme-mcp.json` at the project root.
/// Every field is optional: with no config file at all, everything is discovered.
struct Config: Codable, Equatable {
    var workspace: String?
    var project: String?
    var scheme: String?
    var configuration: String?
    var derivedDataPath: String?
    var testPlan: String?

    static let fileName = ".scheme-mcp.json"
    static let empty = Config()

    /// Walks up from `directory` looking for `.scheme-mcp.json`, stopping at the filesystem root.
    /// Returns the config and the directory that contained it, or nil when there is none —
    /// the caller then has to locate the project some other way.
    /// Walks up from `directory` looking for `.scheme-mcp.json`.
    ///
    /// A file that is there but cannot be read is an error, not an absence. Swallowing it sent
    /// the walk on to the parent directory, where it could adopt an unrelated project's config
    /// — so a misplaced comma built the wrong scheme and said nothing about why.
    static func load(startingAt directory: URL) throws -> (config: Config, root: URL?) {
        var current = directory.standardizedFileURL
        while true {
            let candidate = current.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                do {
                    return (try JSONDecoder().decode(Config.self, from: try Data(contentsOf: candidate)), current)
                } catch {
                    throw ProjectError(
                        message: "\(candidate.path) could not be read: \(error.localizedDescription)"
                    )
                }
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }
            current = parent
        }
        return (.empty, nil)
    }
}
