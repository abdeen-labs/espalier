// Where git comes from: a Debug build of the app takes ESPALIER_GIT_DIR, a
// release takes its bundled git whatever its launch environment says.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("GitLocation")
struct GitLocationTests {
    private static let overridePath = "/opt/somewhere/else/git"

    /// Where git is when it comes from `overridePath`.
    private static var overrideGit: String {
        URL(filePath: overridePath, directoryHint: .isDirectory).standardizedFileURL.path(percentEncoded: false)
    }

    /// `Espalier.app`, with its Info.plist and a Resources folder, in a new
    /// folder.
    private static func makeAppBundle() throws -> Bundle {
        let app = POSIXPath.join(try createTempDirectory(), "Espalier.app")
        try FileManager.default.createDirectory(atPath: POSIXPath.join(app, "Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "dev.abdeen.espalier.tests.location",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Espalier",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(filePath: POSIXPath.join(app, "Contents/Info.plist")))
        return try #require(Bundle(path: app))
    }

    /// Where `bundle`'s own git is.
    private static func bundledGit(_ bundle: Bundle) throws -> String {
        try #require(bundle.resourceURL).appending(path: "git", directoryHint: .isDirectory).path(percentEncoded: false)
    }

    @Test("the app takes ESPALIER_GIT_DIR only when it honors the override", arguments: [
        NamedCase("a Debug build takes git from ESPALIER_GIT_DIR", (isSet: true, honorsOverride: true, takesOverride: true)),
        NamedCase("a release ignores ESPALIER_GIT_DIR", (isSet: true, honorsOverride: false, takesOverride: false)),
        NamedCase("without ESPALIER_GIT_DIR, a Debug build takes its own git", (isSet: false, honorsOverride: true, takesOverride: false)),
    ])
    func app(_ testCase: NamedCase<(isSet: Bool, honorsOverride: Bool, takesOverride: Bool)>) throws {
        let (isSet, honorsOverride, takesOverride) = testCase.value
        let bundle = try Self.makeAppBundle()
        let environment = isSet ? [GitLocation.overrideVariable: Self.overridePath] : [:]

        let resolved = GitLocation.resolveDefault(
            environment: environment,
            bundle: bundle,
            currentDirectory: URL(filePath: try createTempDirectory(), directoryHint: .isDirectory),
            honorsOverride: honorsOverride
        )

        let expected = try takesOverride ? Self.overrideGit : Self.bundledGit(bundle)
        #expect(resolved?.path(percentEncoded: false) == expected)
    }

    @Test("outside an app, a release ignores ESPALIER_GIT_DIR and finds the vendored git")
    func outsideAnApp() throws {
        let folder = try createTempDirectory()
        let bin = POSIXPath.join(folder, "Vendor/git/bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: POSIXPath.join(bin, "git"), contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
        let currentDirectory = URL(filePath: folder, directoryHint: .isDirectory)

        let resolved = GitLocation.resolveDefault(
            environment: [GitLocation.overrideVariable: Self.overridePath],
            bundle: try #require(Bundle(path: folder)),
            currentDirectory: currentDirectory,
            honorsOverride: false
        )

        // The search starts from the standardized folder (/var, not /private/var).
        #expect(resolved?.path(percentEncoded: false) == currentDirectory.standardizedFileURL.appending(path: "Vendor/git", directoryHint: .isDirectory).path(percentEncoded: false))
    }

    @Test("by default, only a Debug build honors ESPALIER_GIT_DIR")
    func defaultsToTheBuild() throws {
        let bundle = try Self.makeAppBundle()

        let resolved = GitLocation.resolveDefault(
            environment: [GitLocation.overrideVariable: Self.overridePath],
            bundle: bundle,
            currentDirectory: URL(filePath: try createTempDirectory(), directoryHint: .isDirectory)
        )

        let expected = try BuildConfiguration.isDebug ? Self.overrideGit : Self.bundledGit(bundle)
        #expect(resolved?.path(percentEncoded: false) == expected)
    }
}
