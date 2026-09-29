import Foundation

struct CommandResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
}

struct ShellError: LocalizedError {
    let command: String
    let exitCode: Int32
    let message: String

    var errorDescription: String? {
        "`\(command)` failed (exit \(exitCode)): \(message)"
    }
}

/// A running child process whose output is delivered line by line.
/// Terminating it is safe to call repeatedly and from any thread.
final class ProcessHandle {
    private let process: Process
    private let lock = NSLock()
    private var hasTerminated = false

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    /// Exposed for signal handlers, which may not allocate or take locks but may call `kill`.
    var processIdentifier: Int32 { process.processIdentifier }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasTerminated, process.isRunning else { return }
        hasTerminated = true
        process.terminate()
    }

    func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum Shell {
    /// Runs a command to completion and buffers its output.
    /// Use for short commands whose output is parsed as a whole (JSON queries, build settings).
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = resolve(executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Read both pipes concurrently: a full pipe buffer on either stream would
        // deadlock a sequential read while the child waits to write.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "scheme-mcp.shell.read", attributes: .concurrent)
        let dataLock = NSLock()

        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            queue.async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                dataLock.lock()
                if isStdout { outData = data } else { errData = data }
                dataLock.unlock()
                group.leave()
            }
        }
        group.wait()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: Text.decode(outData),
            standardError: Text.decode(errData)
        )
    }

    /// Same as `run` but throws when the command exits non-zero.
    @discardableResult
    static func runChecked(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> CommandResult {
        let result = try run(executable, arguments, currentDirectory: currentDirectory)
        guard result.succeeded else {
            let message = result.standardError.isEmpty ? result.standardOutput : result.standardError
            throw ShellError(
                command: ([executable] + arguments).joined(separator: " "),
                exitCode: result.exitCode,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    /// Starts a command and delivers stdout/stderr line by line as they arrive.
    /// `onLine` is called on a background queue. `onExit` fires once the process ends.
    @discardableResult
    static func stream(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        onLine: @escaping (String) -> Void,
        onExit: ((Int32) -> Void)? = nil
    ) throws -> ProcessHandle {
        let process = Process()
        process.executableURL = resolve(executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = ProcessHandle(process: process)
        let reader = LineReader(onLine: onLine)

        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                reader.flush()
            } else {
                reader.consume(data)
            }
        }

        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            reader.flush()
            onExit?(proc.terminationStatus)
        }

        try process.run()
        return handle
    }

    /// Resolves a bare command name against PATH so callers can write `xcrun` instead of a full path.
    private static func resolve(_ executable: String) -> URL {
        if executable.contains("/") { return URL(fileURLWithPath: executable) }
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        for path in searchPaths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: "/usr/bin/\(executable)")
    }
}

/// Accumulates streamed bytes and emits complete lines. Chunk boundaries from a pipe
/// land mid-line constantly, so buffering here is what keeps parsers from seeing fragments.
private final class LineReader {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newlineIndex]
            // Anything launched on a pty (simctl --console-pty, devicectl --console) emits
            // CRLF. A surviving CR sends the cursor to column 0 mid-render and shreds any
            // framed layout, so it is stripped at the boundary rather than downstream.
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            lines.append(Text.decode(lineData))
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let remaining = buffer
        buffer.removeAll()
        lock.unlock()
        guard !remaining.isEmpty else { return }
        onLine(Text.decode(remaining))
    }
}

enum Text {
    // Compiler and device logs occasionally carry invalid UTF-8. Decoding with replacement
    // keeps the rest of the line, whereas a failable initializer would drop the whole payload.
    // swiftlint:disable:next optional_data_string_conversion
    static func decode(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}
