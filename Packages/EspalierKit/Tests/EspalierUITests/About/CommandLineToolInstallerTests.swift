// Install Command Line Tool replaces Espalier's own tool, asks before
// replacing anything else, and leaves a folder alone. A temporary folder
// stands in for /usr/local/bin, and the administrator is never asked.

import EspalierCore
import EspalierSupport
import Foundation
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Install Command Line Tool") @MainActor
struct CommandLineToolInstallerTests {
    /// What's at the tool's path before installing.
    enum Existing: Sendable {
        case nothing, otherEspalier, otherLink, file, folder
    }

    /// What installing over it does.
    enum Expected: Sendable {
        case installs, asks, fails
    }

    @Test("installing over what's at the tool's path", arguments: [
        NamedCase("nothing installs", (Existing.nothing, Expected.installs)),
        NamedCase("another copy of Espalier's tool is replaced", (.otherEspalier, .installs)),
        NamedCase("a link elsewhere is replaced once confirmed", (.otherLink, .asks)),
        NamedCase("a file is replaced once confirmed", (.file, .asks)),
        NamedCase("a folder is left alone", (.folder, .fails)),
    ])
    func install(_ testCase: NamedCase<(Existing, Expected)>) async throws {
        let (existing, expected) = testCase.value
        let base = try createTempDirectory()
        let script = POSIXPath.join(base, "Espalier.app/Contents/Resources/espalier.sh")
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(script), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\n".utf8)))
        let link = POSIXPath.join(base, "bin", "espalier")
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(link), withIntermediateDirectories: true)

        let otherLink = "/opt/tools/bin/espalier"
        switch existing {
        case .nothing:
            break
        case .otherEspalier:
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/Applications/Espalier Old.app/Contents/Resources/espalier.sh")
        case .otherLink:
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: otherLink)
        case .file:
            #expect(FileManager.default.createFile(atPath: link, contents: Data("someone else's\n".utf8)))
        case .folder:
            try FileManager.default.createDirectory(atPath: link, withIntermediateDirectories: false)
        }
        let before = CommandLineToolSystem.live.item(link)

        let system = CommandLineToolSystem(
            scriptPath: { script },
            item: CommandLineToolSystem.live.item,
            linkAsUser: CommandLineToolSystem.live.linkAsUser,
            runAsAdministrator: { _ throws(AdministratorCommandError) in
                Issue.record("Installing asked for an administrator")
                throw .failed("No administrator in tests.")
            }
        )

        switch expected {
        case .installs:
            #expect(try await CommandLineToolInstaller.install(system: system, at: link) == .installed)
        case .asks:
            do {
                _ = try await CommandLineToolInstaller.install(system: system, at: link)
                Issue.record("Installing replaced \(existing) without asking")
            } catch {
                let replaced: ExistingCommandLineTool = existing == .otherLink ? .link(otherLink) : .file
                #expect(error.reason == .confirmationRequired(.replaceCommandLineTool(path: link, existing: replaced)))
            }
            #expect(CommandLineToolSystem.live.item(link) == before)
            let outcome = try await CommandLineToolInstaller.install(system: system, at: link, confirmed: [.replaceCommandLineTool])
            #expect(outcome == .installed)
        case .fails:
            guard case .failed(_, nil) = try await CommandLineToolInstaller.install(system: system, at: link) else {
                Issue.record("Installing over a folder didn't fail")
                return
            }
            #expect(CommandLineToolSystem.live.item(link) == .folder)
            return
        }
        #expect(CommandLineToolSystem.live.item(link) == .link(script))
    }

    @Test("something at the tool's path that can't be looked at asks as such before it's replaced")
    func unexamined() async throws {
        let folder = POSIXPath.join(try createTempDirectory(), "bin")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let link = POSIXPath.join(folder, "espalier")
        #expect(FileManager.default.createFile(atPath: link, contents: Data("someone else's\n".utf8)))
        // Nothing in a folder that can't be searched can be looked at.
        #expect(chmod(folder, 0o600) == 0)
        defer { chmod(folder, 0o755) }
        #expect(CommandLineToolSystem.live.item(link) == .unexamined)

        let system = CommandLineToolSystem(
            scriptPath: { "/Applications/Espalier.app/Contents/Resources/espalier.sh" },
            item: CommandLineToolSystem.live.item,
            linkAsUser: { _, _ in Issue.record("Installing linked the tool") },
            runAsAdministrator: { _ throws(AdministratorCommandError) in
                Issue.record("Installing asked for an administrator")
                throw .failed("No administrator in tests.")
            }
        )
        do {
            _ = try await CommandLineToolInstaller.install(system: system, at: link)
            Issue.record("Installing replaced it without asking")
        } catch {
            #expect(error.reason == .confirmationRequired(.replaceCommandLineTool(path: link, existing: .unexamined)))
        }
    }
}
