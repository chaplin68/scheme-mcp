import Foundation

/// Accumulates everything learned from a build or test run.
/// Safe to feed from the process-reader queue while the UI reads it.
final class BuildReport {
    private let lock = NSLock()
    private var storedDiagnostics: [Diagnostic] = []
    private var storedTests: [TestCaseResult] = []
    private var storedOutcome: BuildOutcome?
    private var storedPhase: String?

    let logURL: URL?
    private let logHandle: FileHandle?

    init(logURL: URL? = nil) {
        self.logURL = logURL
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            self.logHandle = try? FileHandle(forWritingTo: logURL)
        } else {
            self.logHandle = nil
        }
    }

    deinit { try? logHandle?.close() }

    var diagnostics: [Diagnostic] { lock.withLock { storedDiagnostics } }
    var tests: [TestCaseResult] { lock.withLock { storedTests } }
    var outcome: BuildOutcome? { lock.withLock { storedOutcome } }
    var currentPhase: String? { lock.withLock { storedPhase } }

    var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
    var warnings: [Diagnostic] { diagnostics.filter { $0.severity == .warning } }
    var failedTests: [TestCaseResult] { tests.filter { !$0.passed } }

    /// Parses one raw line, records it, and returns the event for live rendering.
    @discardableResult
    func ingest(_ rawLine: String) -> BuildEvent? {
        appendToLog(rawLine)
        guard let event = BuildLogParser.parse(rawLine) else { return nil }

        lock.lock()
        switch event {
        case .diagnostic(let diagnostic):
            // Notes repeat for every re-emitted diagnostic; keeping them would drown the summary.
            if diagnostic.severity != .note { storedDiagnostics.append(diagnostic) }
        case .testCase(let testCase):
            storedTests.append(testCase)
        case .outcome(let outcome):
            storedOutcome = outcome
        case .phase(let action, let subject):
            storedPhase = subject.map { "\(action) \($0)" } ?? action
        }
        lock.unlock()
        return event
    }

    private func appendToLog(_ line: String) {
        guard let logHandle, let data = (line + "\n").data(using: .utf8) else { return }
        try? logHandle.write(contentsOf: data)
    }

    /// Deduplicated diagnostics — xcodebuild repeats the same warning once per target pass, so
    /// the raw count is a count of passes as much as of problems.
    func uniqueDiagnostics(severity: DiagnosticSeverity) -> [Diagnostic] {
        var seen = Set<String>()
        return diagnostics.filter { diagnostic in
            guard diagnostic.severity == severity else { return false }
            let key = "\(diagnostic.file ?? "")|\(diagnostic.line ?? 0)|\(diagnostic.message)"
            return seen.insert(key).inserted
        }
    }
}
