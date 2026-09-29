import Foundation

private struct SchemeListResponse: Decodable {
    let workspace: SchemeListContainer?
    let project: SchemeListContainer?
}

private struct SchemeListContainer: Decodable {
    let name: String
    let schemes: [String]?
}

private struct BuildSettingsEntry: Decodable {
    let target: String?
    let buildSettings: [String: String]
}

struct ProjectError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Raised when several schemes could be meant. Carries the candidates so an interactive
/// caller can offer them rather than dead-ending the user with a message.
struct AmbiguousSchemeError: LocalizedError {
    let schemes: [String]

    var errorDescription: String? {
        """
        Multiple schemes found: \(schemes.joined(separator: ", ")).
        Pass one as `scheme`, or record it in .scheme-mcp.json at the project root.
        """
    }
}

/// Process-wide memo for `xcodebuild -showBuildSettings`. Shared because the dashboard
/// reads settings from a worker thread while the render loop runs on the main one.
final class BuildSettingsCache {
    static let shared = BuildSettingsCache()

    private let lock = NSLock()
    private var storage: [String: [String: String]] = [:]

    func value(for key: String) -> [String: String]? {
        lock.withLock { storage[key] }
    }

    func store(_ settings: [String: String], for key: String) {
        lock.lock()
        storage[key] = settings
        lock.unlock()
    }
}

/// Same idea for `xcodebuild -list`, which the dashboard consults every time the scheme
/// chooser opens.
final class SchemeListCache {
    static let shared = SchemeListCache()

    private let lock = NSLock()
    private var storage: [String: [String]] = [:]

    func value(for key: String) -> [String]? {
        lock.withLock { storage[key] }
    }

    func store(_ schemes: [String], for key: String) {
        lock.lock()
        storage[key] = schemes
        lock.unlock()
    }
}

/// The Xcode container (workspace or project) plus the scheme/configuration to act on.
struct XcodeProject {
    enum Container: Equatable {
        case workspace(URL)
        case project(URL)

        var url: URL {
            switch self {
            case .workspace(let url), .project(let url): return url
            }
        }

        var arguments: [String] {
            switch self {
            case .workspace(let url): return ["-workspace", url.path]
            case .project(let url): return ["-project", url.path]
            }
        }
    }

    let root: URL
    let container: Container
    let scheme: String
    let configuration: String
    let derivedDataPath: URL?
    let testPlan: String?

    var name: String { container.url.deletingPathExtension().lastPathComponent }

    /// Arguments shared by every xcodebuild invocation.
    var baseArguments: [String] {
        var args = container.arguments
        args += ["-scheme", scheme, "-configuration", configuration]
        if let derivedDataPath {
            args += ["-derivedDataPath", derivedDataPath.path]
        }
        return args
    }

    // MARK: - Discovery

    /// Resolves the container and scheme from config, falling back to filesystem discovery.
    /// Throws only when the ambiguity cannot be resolved without asking the user.
    static func discover(config: Config, root: URL, remembering remembered: String? = nil) throws -> XcodeProject {
        let container = try resolveContainer(config: config, root: root)
        let schemes = try listSchemes(container: container)
        let scheme = try resolveScheme(
            config: config,
            container: container,
            schemes: schemes,
            remembered: remembered
        )

        let derivedData = config.derivedDataPath.map { resolvePath($0, against: root) }

        return XcodeProject(
            root: root,
            container: container,
            scheme: scheme,
            configuration: config.configuration ?? "Debug",
            derivedDataPath: derivedData,
            testPlan: config.testPlan
        )
    }

    /// Nearest ancestor of `directory` that holds an `.xcworkspace` or `.xcodeproj`.
    /// Lets the tool be run from anywhere inside a project, the way git and npm behave.
    /// The Xcode container sitting directly in `directory`, if any.
    ///
    /// A workspace wins over a project: with CocoaPods the .xcodeproj alone does not link
    /// the pods, so building it produces a binary missing its dependencies.
    /// Nearest ancestor of `directory` that holds an `.xcworkspace` or `.xcodeproj`.
    ///
    /// `--root` names where to start looking, not where the project must be, so an agent
    /// pointed at a package subdirectory still finds the project above it — the way git and
    /// npm behave.
    static func findContainerDirectory(startingAt directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while true {
            if containerName(in: current) != nil { return current }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { return nil }
            current = parent
        }
    }

    static func container(in directory: URL) -> Container? {
        guard let name = containerName(in: directory) else { return nil }
        let url = directory.appendingPathComponent(name)
        return name.hasSuffix(".xcworkspace") ? .workspace(url) : .project(url)
    }

    private static func containerName(in directory: URL) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.first { $0.hasSuffix(".xcworkspace") }
            ?? entries.first { $0.hasSuffix(".xcodeproj") }
    }

    /// Exposed so a caller recovering from an ambiguous scheme can rank the candidates
    /// without repeating discovery.
    /// Resolves a configured path against the project root, unless it already stands on its own.
    ///
    /// `derivedDataPath` did this and the container paths did not, so an absolute
    /// `--workspace /Users/me/App.xcworkspace` was appended to the working directory and
    /// xcodebuild was asked for `<cwd>/Users/me/App.xcworkspace`. A tilde is expanded too: a
    /// shell usually does it, but not when the argument was quoted.
    static func resolvePath(_ path: String, against root: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : root.appendingPathComponent(expanded)
    }

    private static func resolveContainer(config: Config, root: URL) throws -> Container {
        if let workspace = config.workspace {
            return .workspace(resolvePath(workspace, against: root))
        }
        if let project = config.project {
            return .project(resolvePath(project, against: root))
        }

        guard let container = container(in: root) else {
            throw ProjectError(
                message: """
                No .xcworkspace or .xcodeproj found in \(root.path) or any parent directory.
                Point --root at the project, or set "workspace"/"project" in .scheme-mcp.json.
                """
            )
        }
        return container
    }

    /// Resolution order: explicit config, the scheme used last time, the only scheme, then
    /// one named after the container. Anything left over is genuinely ambiguous and is
    /// reported with the candidates so the caller can ask.
    private static func resolveScheme(
        config: Config,
        container: Container,
        schemes: [String],
        remembered: String?
    ) throws -> String {
        if let scheme = config.scheme { return scheme }
        // Only trust the remembered name if it still exists; schemes get renamed and deleted.
        if let remembered, schemes.contains(remembered) { return remembered }
        if schemes.count == 1, let only = schemes.first { return only }

        // A scheme named after the container is the conventional app scheme.
        let containerName = container.url.deletingPathExtension().lastPathComponent
        if let match = schemes.first(where: { $0 == containerName }) { return match }

        throw AmbiguousSchemeError(schemes: schemes)
    }

    /// Orders schemes so the ones a person means come first.
    ///
    /// A CocoaPods workspace exposes every dependency's scheme, so most of the list is vendored
    /// names and the app's own sits wherever the alphabet puts it. Presenting that raw makes the
    /// list unusable.
    static func rankSchemes(_ schemes: [String], container: Container, root: URL) -> [String] {
        let containerName = container.url.deletingPathExtension().lastPathComponent
        let ownSchemes = sharedSchemeNames(in: root)

        return schemes.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element, containerName: containerName, ownSchemes: ownSchemes)
                let right = rank(rhs.element, containerName: containerName, ownSchemes: ownSchemes)
                if left != right { return left < right }
                return lhs.offset < rhs.offset  // stable: keep xcodebuild's order within a tier
            }
            .map(\.element)
    }

    private static func rank(_ scheme: String, containerName: String, ownSchemes: Set<String>) -> Int {
        if scheme == containerName { return 0 }
        if ownSchemes.contains(scheme) { return 1 }
        if scheme.hasPrefix("Pods-") { return 3 }
        return 2
    }

    /// Scheme names shared by the projects sitting beside the workspace. Vendored
    /// dependencies live in subdirectories (`Pods/Pods.xcodeproj`), so scanning only the
    /// root separates a project's own schemes from its dependencies' without guesswork.
    private static func sharedSchemeNames(in root: URL) -> Set<String> {
        let projects = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".xcodeproj") }

        var names: Set<String> = []
        for project in projects {
            let directory = root
                .appendingPathComponent(project)
                .appendingPathComponent("xcshareddata/xcschemes")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            names.formUnion(
                files.filter { $0.hasSuffix(".xcscheme") }
                    .map { ($0 as NSString).deletingPathExtension }
            )
        }
        return names
    }

    /// Memoised for the process lifetime. Discovery already pays for this at startup, so a
    /// later `s` in the dashboard should be instant rather than another `xcodebuild -list`.
    /// A scheme added in Xcode mid-session needs a restart to appear — an acceptable trade
    /// for a list that is otherwise re-fetched on every glance.
    static func listSchemes(container: Container) throws -> [String] {
        let key = container.url.path
        if let cached = SchemeListCache.shared.value(for: key) { return cached }

        let schemes = try fetchSchemes(container: container)
        SchemeListCache.shared.store(schemes, for: key)
        return schemes
    }

    private static func fetchSchemes(container: Container) throws -> [String] {
        let result = try Shell.run("xcodebuild", ["-list", "-json"] + container.arguments)
        guard result.succeeded, let data = result.standardOutput.data(using: .utf8) else {
            throw ProjectError(
                message: "xcodebuild -list failed: \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        let response = try JSONDecoder().decode(SchemeListResponse.self, from: data)
        return response.workspace?.schemes ?? response.project?.schemes ?? []
    }

    // MARK: - Build settings

    /// Reads resolved build settings. Passing a destination matters: the product directory
    /// and supported platform differ between simulator and device builds.
    ///
    /// Memoised for the lifetime of the process. Each call costs an `xcodebuild
    /// -showBuildSettings` — around 20s on a large workspace — and a single `run` needs the
    /// same answer two or three times.
    func buildSettings(destination: String? = nil) throws -> [String: String] {
        let key = "\(container.url.path)|\(scheme)|\(configuration)|\(destination ?? "-")"
        if let cached = BuildSettingsCache.shared.value(for: key) { return cached }

        var args = ["-showBuildSettings", "-json"] + baseArguments
        if let destination { args += ["-destination", destination] }
        let result = try Shell.run("xcodebuild", args)
        guard result.succeeded, let data = result.standardOutput.data(using: .utf8) else {
            throw ProjectError(
                message: "Could not read build settings: "
                    + result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let entries = try JSONDecoder().decode([BuildSettingsEntry].self, from: data)
        // The first entry is the scheme's primary target.
        guard let settings = entries.first?.buildSettings else {
            throw ProjectError(message: "xcodebuild returned no build settings for scheme \(scheme).")
        }
        BuildSettingsCache.shared.store(settings, for: key)
        return settings
    }

    /// The platform the scheme targets, used to pick a sensible default device.
    func inferredPlatform() -> Platform? {
        guard let settings = try? buildSettings(),
              let supported = settings["SUPPORTED_PLATFORMS"] else { return nil }
        let tokens = supported.split(separator: " ").map(String.init)
        if tokens.contains(where: { $0.hasPrefix("iphone") }) { return .iOS }
        if tokens.contains(where: { $0.hasPrefix("watch") }) { return .watchOS }
        if tokens.contains(where: { $0.hasPrefix("appletv") }) { return .tvOS }
        if tokens.contains(where: { $0.hasPrefix("xr") }) { return .visionOS }
        if tokens.contains("macosx") { return .macOS }
        return nil
    }

    /// Bundle identifier and executable name for the scheme's app. Both come from one
    /// build-settings query because each call shells out to xcodebuild.
    func appIdentity(for device: Device) throws -> (bundleIdentifier: String, executableName: String) {
        let settings = try buildSettings(destination: device.destination)
        guard let bundleIdentifier = settings["PRODUCT_BUNDLE_IDENTIFIER"] else {
            throw ProjectError(message: "PRODUCT_BUNDLE_IDENTIFIER is not set for scheme \(scheme).")
        }
        let executable = settings["EXECUTABLE_NAME"] ?? settings["PRODUCT_NAME"] ?? scheme
        return (bundleIdentifier, executable)
    }

    /// Locates the built .app for a device, preferring the exact path xcodebuild reports
    /// and falling back to a search under DerivedData.
    func productBundle(for device: Device) throws -> URL {
        let settings = try buildSettings(destination: device.destination)
        if let buildDir = settings["TARGET_BUILD_DIR"], let wrapper = settings["WRAPPER_NAME"] {
            let candidate = URL(fileURLWithPath: buildDir).appendingPathComponent(wrapper)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }

        let productName = settings["FULL_PRODUCT_NAME"]
            ?? (settings["PRODUCT_NAME"].map { "\($0).app" })
            ?? "\(scheme).app"
        if let found = searchDerivedData(productName: productName, sdkSuffix: device.sdkSuffix) {
            return found
        }

        throw ProjectError(
            message: "Built product \(productName) not found. Run build before run."
        )
    }

    private func searchDerivedData(productName: String, sdkSuffix: String) -> URL? {
        let searchRoots: [URL] = [
            derivedDataPath,
            root.appendingPathComponent("DerivedData"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        ].compactMap { $0 }

        let wanted = "\(configuration)-\(sdkSuffix)"
        for searchRoot in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == productName {
                if url.deletingLastPathComponent().lastPathComponent == wanted { return url }
            }
        }
        return nil
    }
}
