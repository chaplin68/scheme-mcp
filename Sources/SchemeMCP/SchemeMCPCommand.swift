import ArgumentParser
import Foundation
import MCP

/// The project the tools act on.
///
/// Smaller than the CLI's equivalent on purpose: there is no prompting here, so nothing needs
/// to know whether a person is watching. A tool call that cannot resolve a device answers with
/// the list it does have instead of asking.
struct ProjectContext {
    let project: XcodeProject
    let config: Config
    let root: URL
}

@main
struct SchemeMCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scheme-mcp",
        abstract: "Build, run and test an Xcode project over the Model Context Protocol.",
        discussion: """
            Speaks MCP on stdin and stdout, so a client starts it as a child process rather \
            than connecting to it. Nothing is printed to stdout but protocol traffic.

            Point it at the project with --root. Without it the working directory is used, \
            which is whatever directory the client happened to launch from.
            """,
        version: "0.1.0"
    )

    @Option(name: .long, help: "Project directory the tools operate on. Defaults to the working directory.")
    var root: String?

    /// Synchronous on purpose. An `AsyncParsableCommand` requires an async entry point, and
    /// ArgumentParser then dispatches through its synchronous one anyway and aborts. Blocking
    /// one thread costs nothing here: serving is all this process does.
    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        let failure = ThrownError()
        Task {
            do { try await serve() } catch { failure.value = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = failure.value { throw error }
    }

    private func serve() async throws {
        let directory = root ?? FileManager.default.currentDirectoryPath
        let runner = SchemeToolRunner(root: URL(fileURLWithPath: directory).standardizedFileURL)

        let server = Server(
            name: "scheme-mcp",
            version: Self.configuration.version,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: SchemeTools.definitions())
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            do {
                let value = Value.object(
                    try runner.call(name: parameters.name, arguments: parameters.arguments ?? [:])
                )
                // Returned as JSON text as well as structured content: clients differ in which
                // one they surface, and a result the agent cannot read is a result it ignores.
                return try CallTool.Result(
                    content: [.text(text: Self.json(value), annotations: nil, _meta: nil)],
                    structuredContent: value
                )
            } catch let error as MCPError {
                throw error
            } catch {
                // Reported as a failed tool call rather than a protocol error: the agent can act
                // on "this project has no such scheme", but not on a dead connection.
                return CallTool.Result(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    private static func json(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// Carries an error out of the detached task the synchronous entry point waits on.
private final class ThrownError {
    var value: Error?
}
