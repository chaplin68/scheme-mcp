import Foundation

enum DiagnosticSeverity: String {
    case error
    case warning
    case note
}

struct Diagnostic: Equatable {
    let severity: DiagnosticSeverity
    let file: String?
    let line: Int?
    let column: Int?
    let message: String

    /// `File.swift:12:5` — the clickable form most terminals linkify.
    var location: String? {
        guard let file else { return nil }
        var text = (file as NSString).lastPathComponent
        if let line { text += ":\(line)" }
        if let column { text += ":\(column)" }
        return text
    }
}

struct TestCaseResult: Equatable {
    let suite: String
    let name: String
    let passed: Bool
    let duration: Double?
}

enum BuildOutcome: Equatable {
    case buildSucceeded
    case buildFailed
    case testSucceeded
    case testFailed

    var isSuccess: Bool { self == .buildSucceeded || self == .testSucceeded }
}

enum BuildEvent: Equatable {
    /// A compilation step, e.g. ("Compiling", "ViewController.swift").
    case phase(action: String, subject: String?)
    case diagnostic(Diagnostic)
    case testCase(TestCaseResult)
    case outcome(BuildOutcome)
}

/// Turns raw xcodebuild output into structured events.
/// Pure and line-at-a-time so it can be unit tested without running a build.
enum BuildLogParser {
    private static let severityMarkers: [(marker: String, severity: DiagnosticSeverity)] = [
        (": error: ", .error),
        (": warning: ", .warning),
        (": note: ", .note)
    ]

    private static let phaseActions: [String: String] = [
        "CompileSwift": "Compiling",
        "SwiftCompile": "Compiling",
        "SwiftDriverJobDiscovery": "Compiling",
        "CompileC": "Compiling",
        "CompileAssetCatalog": "Assets",
        "CompileStoryboard": "Storyboard",
        "CompileXIB": "XIB",
        "Ld": "Linking",
        "CodeSign": "Signing",
        "ProcessInfoPlistFile": "Info.plist",
        "CpResource": "Resources",
        "CopySwiftLibs": "Swift runtime",
        "Touch": "Finishing",
        "CreateBuildDirectory": "Preparing",
        "PhaseScriptExecution": "Run script"
    ]

    static func parse(_ rawLine: String) -> BuildEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        if let outcome = parseOutcome(line) { return .outcome(outcome) }
        if let testCase = parseTestCase(line) { return .testCase(testCase) }
        if let destination = parseDestinationError(line) { return .diagnostic(destination) }
        if let diagnostic = parseDiagnostic(line) { return .diagnostic(diagnostic) }
        if let phase = parsePhase(line) { return phase }
        return nil
    }

    static func parseOutcome(_ line: String) -> BuildOutcome? {
        switch true {
        case line.contains("** BUILD SUCCEEDED **"): return .buildSucceeded
        case line.contains("** BUILD FAILED **"): return .buildFailed
        case line.contains("** TEST SUCCEEDED **"): return .testSucceeded
        case line.contains("** TEST FAILED **"): return .testFailed
        case line.contains("** CLEAN SUCCEEDED **"): return .buildSucceeded
        default: return nil
        }
    }

    /// `{ platform:iOS, arch:arm64, id:0000…, name:MyPhone, error:A connection to this device
    /// could not be established. }` — printed under "Available destinations" when a destination
    /// exists but cannot be used. It carries the only real reason for
    /// "Timed out waiting for all destinations…", and its `error:` has no space after the colon,
    /// so the ordinary `: error: ` matching drops it on the floor.
    static func parseDestinationError(_ line: String) -> Diagnostic? {
        guard line.hasPrefix("{"), line.hasSuffix("}"), line.contains("error:") else { return nil }
        let body = line.dropFirst().dropLast()
        var fields: [String: String] = [:]
        for field in body.components(separatedBy: ", ") {
            guard let separator = field.firstIndex(of: ":") else { continue }
            fields[String(field[field.startIndex..<separator]).trimmingCharacters(in: .whitespaces)] =
                String(field[field.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let reason = fields["error"] else { return nil }
        let target = fields["name"] ?? fields["id"] ?? "destination"
        return Diagnostic(
            severity: .error,
            file: nil,
            line: nil,
            column: nil,
            message: "\(target) is unusable as a destination: \(reason)"
        )
    }

    static func parseDiagnostic(_ line: String) -> Diagnostic? {
        for (marker, severity) in severityMarkers {
            guard let range = line.range(of: marker) else { continue }
            let location = String(line[line.startIndex..<range.lowerBound])
            let message = String(line[range.upperBound...])
            let parsed = parseLocation(location)
            return Diagnostic(
                severity: severity,
                file: parsed.file,
                line: parsed.line,
                column: parsed.column,
                message: message.trimmingCharacters(in: .whitespaces)
            )
        }
        // Tool-level diagnostics have no location prefix, e.g. "error: no such module".
        for (marker, severity) in severityMarkers {
            let bare = marker.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            guard line.hasPrefix("\(bare): ") else { continue }
            return Diagnostic(
                severity: severity,
                file: nil,
                line: nil,
                column: nil,
                message: String(line.dropFirst(bare.count + 2))
            )
        }
        return nil
    }

    /// Splits `/path/File.swift:12:5` into its parts. Locations without a line number
    /// (`ld`, `clang`) come back with only the file set.
    static func parseLocation(_ text: String) -> (file: String?, line: Int?, column: Int?) {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return (text.isEmpty ? nil : text, nil, nil) }

        var column: Int?
        var lineNumber: Int?
        if let last = parts.last, let value = Int(last) {
            column = value
            parts.removeLast()
        }
        if let last = parts.last, let value = Int(last) {
            lineNumber = value
            parts.removeLast()
        }
        // When only one number was present it is the line, not the column.
        if lineNumber == nil, let onlyNumber = column {
            lineNumber = onlyNumber
            column = nil
        }
        let file = parts.joined(separator: ":")
        return (file.isEmpty ? nil : file, lineNumber, column)
    }

    static func parseTestCase(_ line: String) -> TestCaseResult? {
        if let xcTest = parseXCTestCase(line) { return xcTest }
        return parseSwiftTestingCase(line)
    }

    /// `Test Case '-[SuiteName testMethod]' passed (0.003 seconds).`
    private static func parseXCTestCase(_ line: String) -> TestCaseResult? {
        guard line.hasPrefix("Test Case '") else { return nil }
        let passed = line.contains("' passed")
        let failed = line.contains("' failed")
        guard passed || failed else { return nil }

        guard let open = line.firstIndex(of: "'"),
              let close = line[line.index(after: open)...].firstIndex(of: "'") else { return nil }
        let identifier = String(line[line.index(after: open)..<close])
            .trimmingCharacters(in: CharacterSet(charactersIn: "-[]+"))
        let components = identifier.split(separator: " ").map(String.init)
        let suite = components.first ?? "Unknown"
        let name = components.count > 1 ? components[1] : identifier

        return TestCaseResult(suite: suite, name: name, passed: passed, duration: parseDuration(line))
    }

    /// swift-testing (Xcode 16+): `✔ Test example() passed after 0.01 seconds.`
    private static func parseSwiftTestingCase(_ line: String) -> TestCaseResult? {
        let passed = line.hasPrefix("✔") || line.contains("✔ Test ")
        let failed = line.hasPrefix("✘") || line.contains("✘ Test ")
        guard passed || failed, let range = line.range(of: "Test ") else { return nil }

        let remainder = line[range.upperBound...]
        guard let nameEnd = remainder.firstIndex(of: " ") else { return nil }
        let name = String(remainder[remainder.startIndex..<nameEnd])
        guard !name.isEmpty else { return nil }

        return TestCaseResult(suite: "swift-testing", name: name, passed: passed, duration: parseDuration(line))
    }

    private static func parseDuration(_ line: String) -> Double? {
        guard let open = line.lastIndex(of: "("),
              let close = line.lastIndex(of: ")"),
              open < close else {
            // swift-testing writes "after 0.01 seconds." with no parentheses.
            guard let range = line.range(of: "after ") else { return nil }
            let token = line[range.upperBound...].split(separator: " ").first ?? ""
            return Double(token)
        }
        let inner = line[line.index(after: open)..<close]
        return Double(inner.split(separator: " ").first ?? "")
    }

    private static func parsePhase(_ line: String) -> BuildEvent? {
        guard let action = line.split(separator: " ").first.map(String.init),
              let label = phaseActions[action] else { return nil }
        return .phase(action: label, subject: phaseSubject(line, action: action))
    }

    /// Pulls the interesting filename out of a phase line, skipping the object-file
    /// paths and architecture tokens that make raw xcodebuild output unreadable.
    private static func phaseSubject(_ line: String, action: String) -> String? {
        let tokens = line.split(separator: " ").map(String.init).dropFirst()
        let interestingSuffixes = [".swift", ".m", ".mm", ".c", ".cpp", ".xib", ".storyboard", ".app"]
        if let match = tokens.first(where: { token in
            interestingSuffixes.contains { token.hasSuffix($0) }
        }) {
            return (match as NSString).lastPathComponent
        }
        if action == "Ld", let product = tokens.first {
            return (product as NSString).lastPathComponent
        }
        if let range = line.range(of: "in target '"),
           let end = line[range.upperBound...].firstIndex(of: "'") {
            return String(line[range.upperBound..<end])
        }
        return nil
    }
}
