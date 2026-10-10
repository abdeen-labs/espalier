// Ported from desktop/app/src/lib/custom-integration.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "integrations")

/// The string that will be replaced by the target path in the custom
/// integration arguments
public let TargetPathArgument = "%TARGET_PATH%"

/// The interface representing a custom integration (external editor or
/// shell)
///
/// It is stored under `custom-editor` and `custom-shell` as
/// `{"path": …, "arguments": …, "bundleID": …}`, without `bundleID` when
/// there is none.
public struct CustomIntegration: Codable, Sendable, Hashable {
    /// The path to the custom integration
    public var path: String
    /// The arguments to pass to the custom integration
    public var arguments: String
    /// The bundle ID of the custom integration (macOS only)
    public var bundleID: String?

    public init(path: String, arguments: String, bundleID: String? = nil) {
        self.path = path
        self.arguments = arguments
        self.bundleID = bundleID
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case arguments
        case bundleID
    }

    /// Decodes either stored format: the arguments as a string, or as an
    /// array of strings, which is joined with spaces. Encoding always writes
    /// the string: parsing the arguments into an array removes their quotes,
    /// so the string the user entered is kept and parsed right before
    /// launching.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        if let arguments = try? container.decode(String.self, forKey: .arguments) {
            self.arguments = arguments
        } else {
            arguments = try container.decode([String].self, forKey: .arguments).joined(separator: " ")
        }
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
    }
}

/// Parse the arguments string of a custom integration into an array of
/// strings, as the `string-argv` package does (see `stringArgv`).
///
/// - Parameter args: The arguments string to parse
public func parseCustomIntegrationArguments(_ args: String) -> [String] {
    stringArgv(args)
}

/// Retrieves the bundle ID of the application at `path`.
///
/// Reads the `CFBundleIdentifier` of the bundle's Info.plist directly, so
/// an application Spotlight hasn't indexed (or a Mac with Spotlight turned
/// off) still has its bundle ID.
func getAppBundleID(_ path: String) -> String? {
    // Ensure the path ends with `.app` for applications
    guard JSCompat.endsWith(path, ".app") else {
        logger.error("Failed to retrieve bundle ID: The provided path does not point to a macOS application.")
        return nil
    }

    let url = URL(filePath: path, directoryHint: .isDirectory)
    guard let info = CFBundleCopyInfoDictionaryInDirectory(url as CFURL) as? [String: Any],
          let identifier = info["CFBundleIdentifier"] as? String
    else {
        return nil
    }

    let bundleId = JSCompat.trim(identifier)

    // Check for valid output
    if bundleId.isEmpty || JSCompat.strictEquals(bundleId, "(null)") {
        return nil
    }

    return bundleId
}

/// Replace the target path placeholder in the custom integration arguments
/// with the actual target path.
///
/// The path is inserted literally, so `$&`, `$$`, `` $` ``, and `$'` in it
/// stay as they are.
///
/// - Parameters:
///   - args: The custom integration arguments
///   - repoPath: The target path to replace the placeholder with
public func expandTargetPathArgument(_ args: [String], _ repoPath: String) -> [String] {
    // Only strip quotes when the entire argument is the quoted placeholder.
    // Otherwise preserve any user-provided quoting and replace the placeholder
    // in place.
    args.map { arg in
        if JSCompat.strictEquals(arg, "'\(TargetPathArgument)'")
            || JSCompat.strictEquals(arg, "\"\(TargetPathArgument)\"") {
            return repoPath
        }

        return arg.replacingOccurrences(of: TargetPathArgument, with: repoPath, options: .literal)
    }
}

/// Check if the custom integration arguments contain the target path
/// placeholder.
///
/// - Parameter args: The custom integration arguments
public func checkTargetPathArgument(_ args: [String]) -> Bool {
    args.contains { JSCompat.includes($0, TargetPathArgument) }
}

/// The result of `validateCustomIntegrationPath`.
public struct CustomIntegrationPathValidation: Sendable, Hashable {
    /// Whether the path can be launched as a custom integration.
    public var isValid: Bool
    /// The bundle ID of the application at the path, if it is a macOS app.
    public var bundleID: String?

    public init(isValid: Bool, bundleID: String? = nil) {
        self.isValid = isValid
        self.bundleID = bundleID
    }
}

/// Validate the path of a custom integration.
///
/// A valid path is an executable file, or an application: a directory whose
/// name ends with `.app` and which has a bundle ID.
///
/// A symbolic link is judged by what it points to: a link to an
/// application is an application, and a link to a folder isn't valid.
///
/// - Parameter path: The path to the custom integration
/// - Returns: Whether the path is valid and, if the path is a macOS app, the
///   bundle ID of the app.
@concurrent
public func validateCustomIntegrationPath(_ path: String) async -> CustomIntegrationPathValidation {
    if path.isEmpty {
        return CustomIntegrationPathValidation(isValid: false)
    }

    var pathStat = stat()
    guard stat(path, &pathStat) == 0 else {
        let code = errno
        if code != ENOENT {
            logger.error("Failed to validate path: \(path, privacy: .private): \(String(cString: strerror(code)), privacy: .public)")
        }
        return CustomIntegrationPathValidation(isValid: false)
    }

    let fileType = pathStat.st_mode & S_IFMT
    let canBeExecuted = access(path, X_OK) == 0
    let isExecutableFile = fileType == S_IFREG && canBeExecuted

    // On macOS, not only executable files are valid, but also apps (which are
    // directories with a `.app` extension and from which we can retrieve the
    // app bundle ID)
    var bundleID: String?
    if !isExecutableFile, fileType == S_IFDIR {
        bundleID = getAppBundleID(path)
    }

    return CustomIntegrationPathValidation(isValid: isExecutableFile || bundleID != nil, bundleID: bundleID)
}

/// Check if a custom integration is valid (meaning both the path and the
/// arguments are valid).
///
/// - Parameter customIntegration: The custom integration to validate
@concurrent
public func isValidCustomIntegration(_ customIntegration: CustomIntegration) async -> Bool {
    let pathResult = await validateCustomIntegrationPath(customIntegration.path)
    let argv = parseCustomIntegrationArguments(customIntegration.arguments)
    let targetPathPresent = checkTargetPathArgument(argv)
    return pathResult.isValid && targetPathPresent
}

/// Launches an integration (editor or shell): detached, with its output
/// ignored.
///
/// - Parameters:
///   - cmd: Command to spawn
///   - args: Arguments to pass to the command
func spawnCustomIntegration(
    _ cmd: String,
    _ args: [String],
    tracing: LaunchTracing?,
    launcher: any IntegrationLauncher
) throws(SpawnError) {
    try launcher.spawn(LaunchCommand(executable: cmd, arguments: args, isDetached: true), tracing: tracing)
}
