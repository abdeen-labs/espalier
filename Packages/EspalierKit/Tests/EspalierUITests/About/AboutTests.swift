// About, Acknowledgements, and the command line tool. The acknowledgements
// are checked against what Espalier is built from (Package.resolved, the
// vendored grammars, the bundled git's release, and the license files on
// disk), so an update that changes one is noticed. The installer runs on a
// fake system (and, for the plain file operations, in a temporary folder);
// the command line script runs with a stand-in for `open`.

import EspalierCore
import EspalierSupport
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import EspalierUI

/// The repository's root, from this file's place in it.
private let repositoryRoot = (0..<6).reduce(#filePath) { path, _ in POSIXPath.dirname(path) }
private let packageRoot = POSIXPath.join(repositoryRoot, "Packages/EspalierKit")

private func read(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// A license text as the acknowledgements compare it: without the final
/// line break.
private func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
}

@Suite("About", .hangGuard(minutes: 5)) @MainActor
struct AboutTests {
    // MARK: Acknowledgements

    @Test("every package Espalier builds with is acknowledged at its pinned version")
    func packages() throws {
        let data = try #require(FileManager.default.contents(atPath: POSIXPath.join(packageRoot, "Package.resolved")))
        let resolved = try JSONDecoder().decode(Resolved.self, from: data)
        let syntax = Dictionary(uniqueKeysWithValues: Acknowledgement.syntax.map { ($0.id, $0) })
        for pin in resolved.pins {
            let acknowledgement = try #require(syntax[pin.identity], "\(pin.identity) isn't acknowledged")
            #expect(acknowledgement.version == pin.state.version, "\(pin.identity) is at \(pin.state.version ?? "?")")
            let location = pin.location.hasSuffix(".git") ? String(pin.location.dropLast(4)) : pin.location
            #expect(acknowledgement.url.absoluteString == location)

            // The checkout's license, when SwiftPM has checked it out here.
            let license = POSIXPath.join(packageRoot, ".build/checkouts/\(pin.identity)/LICENSE")
            if let text = read(license) {
                #expect(normalized(acknowledgement.text) == normalized(text), "\(pin.identity)'s license changed")
            }
        }
    }

    @Test("every vendored grammar is acknowledged with its license")
    func vendoredGrammars() throws {
        let directory = POSIXPath.join(packageRoot, "Vendor/Grammars")
        let modules = try FileManager.default.contentsOfDirectory(atPath: directory).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".md") }
        #expect(Set(modules) == Set(Acknowledgement.vendoredGrammars.values))
        for (identity, module) in Acknowledgement.vendoredGrammars {
            let acknowledgement = try #require(Acknowledgement.syntax.first { $0.id == identity })
            let text = try #require(read(POSIXPath.join(directory, "\(module)/LICENSE")))
            #expect(normalized(acknowledgement.text) == normalized(text), "\(identity)'s license changed")
        }
    }

    @Test("Git's release is the bundled one, and the bundled notices match")
    func bundledGit() throws {
        let pinned = try #require(read(POSIXPath.join(repositoryRoot, "scripts/git-version"))).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pinned == Acknowledgement.dugiteNativeTag)
        #expect(pinned.hasPrefix("v\(Acknowledgement.gitVersion)-"))
        if let notice = read(POSIXPath.join(repositoryRoot, "Vendor/git/libexec/git-core/NOTICE")) {
            #expect(normalized(AcknowledgementTexts.gitCredentialManagerNotice) == normalized(notice))
        }
        // Its release ships only the notice; the entry shows the license
        // first.
        let manager = try #require(Acknowledgement.all.first { $0.id == "git-credential-manager" })
        #expect(manager.text.hasPrefix(AcknowledgementTexts.gitCredentialManager + "\n\n"))
        #expect(manager.text.hasSuffix(AcknowledgementTexts.gitCredentialManagerNotice))
        #expect(AcknowledgementTexts.gitCredentialManager.contains("MIT License"))
    }

    // MARK: The command line tool

    private func system(
        script: String? = "/Applications/Espalier.app/Contents/Resources/espalier.sh",
        link: String? = nil,
        userFails: Bool = false,
        administrator: AdministratorCommandError? = nil,
        calls: InstallerCalls
    ) -> CommandLineToolSystem {
        CommandLineToolSystem(
            scriptPath: { script },
            readLink: { _ in link },
            linkAsUser: { script, link in
                calls.record("user \(script) \(link)")
                if userFails {
                    throw CocoaError(.fileWriteNoPermission)
                }
            },
            runAsAdministrator: { command throws(AdministratorCommandError) in
                calls.record("admin \(command)")
                if let administrator {
                    throw administrator
                }
            }
        )
    }

    @Test("installs as the user, or after the administrator prompt; nothing when it's linked already")
    func install() async {
        let script = "/Applications/Espalier.app/Contents/Resources/espalier.sh"
        let link = CommandLineToolInstaller.installedPath
        #expect(link == "/usr/local/bin/espalier")

        var calls = InstallerCalls()
        #expect(await CommandLineToolInstaller.install(system: system(link: script, calls: calls)) == .installed)
        #expect(calls.all.isEmpty)

        calls = InstallerCalls()
        #expect(await CommandLineToolInstaller.install(system: system(calls: calls)) == .installed)
        #expect(calls.all == ["user \(script) \(link)"])

        calls = InstallerCalls()
        #expect(await CommandLineToolInstaller.install(system: system(userFails: true, calls: calls)) == .installed)
        let command = "mkdir -p /usr/local/bin && ln -sfn \(script) \(link)"
        #expect(calls.all == ["user \(script) \(link)", "admin \(command)"])

        calls = InstallerCalls()
        #expect(await CommandLineToolInstaller.install(system: system(userFails: true, administrator: .cancelled, calls: calls)) == .cancelled)

        calls = InstallerCalls()
        let failed = await CommandLineToolInstaller.install(system: system(userFails: true, administrator: .failed("Not allowed."), calls: calls))
        #expect(failed == .failed(message: "Not allowed.", command: "sudo mkdir -p /usr/local/bin && sudo ln -sfn \(script) \(link)"))

        calls = InstallerCalls()
        let missing = await CommandLineToolInstaller.install(system: system(script: nil, calls: calls))
        #expect(missing == .failed(message: "The command line tool is missing from Espalier's application bundle.", command: nil))
        #expect(calls.all.isEmpty)
    }

    @Test("the user's link replaces what's there and makes its folder")
    func liveLink() async throws {
        let directory = try createTempDirectory()
        let script = POSIXPath.join(directory, "Espalier.app/Contents/Resources/espalier.sh")
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(script), withIntermediateDirectories: true)
        try Data("#!/bin/zsh\n".utf8).write(to: URL(filePath: script))
        let link = POSIXPath.join(directory, "usr/local/bin/espalier")

        try await CommandLineToolSystem.live.linkAsUser(script, link)
        #expect(CommandLineToolSystem.live.readLink(link) == script)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/nowhere")
        try await CommandLineToolSystem.live.linkAsUser(script, link)
        #expect(CommandLineToolSystem.live.readLink(link) == script)
    }

    @Test("commands are quoted for the shell and for AppleScript")
    func quoting() {
        #expect(AdministratorCommand.shellQuoted("/Users/joe/it's here") == "'/Users/joe/it'\\''s here'")
        #expect(AdministratorCommand.appleScriptString(#"echo "a\b""#) == #""echo \"a\\b\"""#)
        #expect(
            CommandLineToolInstaller.installCommand(script: "/Volumes/My Disk/Espalier.app/Contents/Resources/espalier.sh", link: "/usr/local/bin/espalier")
                == "mkdir -p /usr/local/bin && ln -sfn '/Volumes/My Disk/Espalier.app/Contents/Resources/espalier.sh' /usr/local/bin/espalier"
        )
        #expect(AdministratorCommand.shellWord("/usr/local/bin") == "/usr/local/bin")
        #expect(AdministratorCommand.shellWord("/Users/joe/it's here") == "'/Users/joe/it'\\''s here'")
        #expect(AdministratorCommand.shellWord("/Users/jos\u{e9}/x") == "'/Users/jos\u{e9}/x'")
    }

    @Test("the outcomes' alerts")
    func alerts() {
        let installed = CommandLineToolInstaller.installedAlert()
        #expect(installed.title == "Command Line Tool Installed")
        #expect(installed.message == "The command line tool has been installed at /usr/local/bin/espalier.")
        let failed = CommandLineToolInstaller.failedAlert(message: "Not allowed.", command: "sudo /bin/ln -sfn a b")
        #expect(failed.buttons.map(\.title) == ["Copy Command", "Close"])
        #expect(failed.message == "Not allowed.\n\nTo install it yourself, run this command in Terminal:\n\nsudo /bin/ln -sfn a b")
        #expect(CommandLineToolInstaller.failedAlert(message: "Missing.", command: nil).buttons.map(\.title) == ["Close"])
    }

    // MARK: The script

    /// Runs the app's espalier.sh through a link, as the installed tool,
    /// with `open` recording its arguments; returns the exit status, what
    /// `open` got, and standard error.
    private func runTool(_ arguments: [String], in directory: String? = nil) async throws -> (status: ChildProcess.Termination, open: String, errors: String) {
        let root = try createTempDirectory()
        let app = POSIXPath.join(root, "Espalier.app")
        let script = POSIXPath.join(app, "Contents/Resources/espalier.sh")
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(script), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: POSIXPath.join(repositoryRoot, "Espalier/espalier.sh"), toPath: script)
        let bin = POSIXPath.join(root, "bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(bin, "espalier"), withDestinationPath: script)
        let fakeOpen = POSIXPath.join(bin, "open")
        try Data("#!/bin/sh\nfor argument in \"$@\"; do printf '[%s]' \"$argument\"; done\n".utf8).write(to: URL(filePath: fakeOpen))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen)

        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: POSIXPath.join(bin, "espalier"),
            arguments: arguments,
            environment: ["PATH": "\(bin):/usr/bin:/bin"],
            currentDirectoryPath: directory ?? root
        ))
        let output = Mutex(Data())
        let errors = Mutex(Data())
        child.observeStandardOutput { data in output.withLock { $0.append(data) } }
        child.observeStandardError { data in errors.withLock { $0.append(data) } }
        let status = await child.waitUntilExit()
        let opened = String(decoding: output.withLock { $0 }, as: UTF8.self).replacingOccurrences(of: realPath(app), with: "<app>")
        return (status, opened.replacingOccurrences(of: app, with: "<app>"), String(decoding: errors.withLock { $0 }, as: UTF8.self))
    }

    private func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test("the script opens folders and clone links in the Espalier it's part of")
    func script() async throws {
        let folder = try createTempDirectory()
        let real = realPath(folder)

        var result = try await runTool([], in: folder)
        #expect(result.status == .exit(0))
        #expect(result.open == "[-a][<app>][\(real)]")

        result = try await runTool(["open", folder])
        #expect(result.open == "[-a][<app>][\(real)]")
        result = try await runTool([folder])
        #expect(result.open == "[-a][<app>][\(real)]")

        result = try await runTool(["clone", "desktop/desktop"])
        #expect(result.status == .exit(0))
        #expect(result.open == "[-a][<app>][espalier://openRepo/https://github.com/desktop/desktop]")
        result = try await runTool(["clone", "-b", "feature/a&b+c", "https://example.com/team/app.git"])
        #expect(result.open == "[-a][<app>][espalier://openRepo/https://example.com/team/app.git?branch=feature%2Fa%26b%2Bc]")

        // The links parse as Espalier's URL actions.
        #expect(parseAppURL("espalier://openRepo/https://example.com/team/app.git?branch=feature%2Fa%26b%2Bc")
            == .openRepositoryFromURL(OpenRepositoryFromURLAction(url: "https://example.com/team/app.git", branch: "feature/a&b+c")))

        result = try await runTool(["clone"])
        #expect(result.status == .exit(1))
        #expect(result.open.isEmpty)
        #expect(result.errors.contains("Usage:"))
        result = try await runTool([POSIXPath.join(folder, "missing")])
        #expect(result.status == .exit(1))
        #expect(result.errors.contains("is not a folder"))
        result = try await runTool(["--help"])
        #expect(result.status == .exit(0))
        #expect(result.errors.contains("espalier clone [-b branch] <url>"))
    }
}

/// What the fake installer system was asked to do.
final class InstallerCalls: Sendable {
    private let calls = Mutex<[String]>([])

    func record(_ call: String) {
        calls.withLock { $0.append(call) }
    }

    var all: [String] {
        calls.withLock { $0 }
    }
}

/// Package.resolved's pins.
private struct Resolved: Decodable {
    struct Pin: Decodable {
        struct State: Decodable {
            let version: String?
        }

        let identity: String
        let location: String
        let state: State
    }

    let pins: [Pin]
}
