@testable import EspalierCore
import EspalierSupport
import Foundation
import Synchronization

/// An application locator that knows only the applications it is given.
final class FakeApplicationLocator: ApplicationLocator {
    private let paths: [String: String]

    init(_ paths: [String: String] = [:]) {
        self.paths = paths
    }

    func appPath(_ bundleIdentifier: String) -> String? {
        paths[bundleIdentifier]
    }
}

/// An application locator whose applications can be installed and removed
/// while a test runs.
final class MutableApplicationLocator: ApplicationLocator {
    private let paths = Mutex<[String: String]>([:])

    func install(_ bundleIdentifier: String, at path: String) {
        paths.withLock { $0[bundleIdentifier] = path }
    }

    func remove(_ bundleIdentifier: String) {
        paths.withLock { $0[bundleIdentifier] = nil }
    }

    func appPath(_ bundleIdentifier: String) -> String? {
        paths.withLock { $0[bundleIdentifier] }
    }
}

/// A launcher that records commands instead of starting anything.
final class RecordingLauncher: IntegrationLauncher {
    private let recorded = Mutex<[(command: LaunchCommand, traced: Bool)]>([])
    private let failure: SpawnError?

    /// - Parameter failure: Thrown by every spawn, after recording it.
    init(failingWith failure: SpawnError? = nil) {
        self.failure = failure
    }

    func spawn(_ command: LaunchCommand, tracing: LaunchTracing?) throws(SpawnError) {
        recorded.withLock { $0.append((command, tracing != nil)) }
        if let failure {
            throw failure
        }
    }

    /// The commands spawned, in order.
    var commands: [LaunchCommand] {
        recorded.withLock { $0.map(\.command) }
    }

    /// Whether each spawn came with tracing, in order.
    var traced: [Bool] {
        recorded.withLock { $0.map(\.traced) }
    }
}

/// Collects the errors a launch reports to its `onError` callback.
final class ErrorCollector: Sendable {
    private let errors = Mutex<[any Error]>([])

    var onError: @Sendable (any Error) -> Void {
        { error in self.errors.withLock { $0.append(error) } }
    }

    var collected: [any Error] {
        errors.withLock { $0 }
    }
}

/// Creates a stand-in for an application bundle: a directory named `name`
/// in `directory`, with an Info.plist when `bundleIdentifier` is given and an
/// empty file at `Contents/MacOS/<executable>` when `executable` is. Nothing
/// in it can run.
@discardableResult
func makeFakeApplication(
    in directory: String,
    named name: String,
    bundleIdentifier: String? = nil,
    executable: String? = nil
) throws -> String {
    let path = "\(directory)/\(name)"
    try FileManager.default.createDirectory(atPath: "\(path)/Contents/MacOS", withIntermediateDirectories: true)
    if let bundleIdentifier {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier, "CFBundlePackageType": "APPL"],
            format: .xml,
            options: 0
        )
        try plist.write(to: URL(filePath: "\(path)/Contents/Info.plist"))
    }
    if let executable {
        try Data().write(to: URL(filePath: "\(path)/Contents/MacOS/\(executable)"))
    }
    return path
}

/// Writes a file at `path` with the given permissions.
func makeFile(_ path: String, permissions: Int) throws {
    try Data("#!/bin/sh\n".utf8).write(to: URL(filePath: path))
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
}
