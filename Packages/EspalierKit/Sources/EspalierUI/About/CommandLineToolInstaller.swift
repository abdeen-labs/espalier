// Ported from desktop/app/src/ui/lib/install-cli.ts
//
// Espalier ▸ Install Command Line Tool… links /usr/local/bin/espalier to
// the script in Espalier's bundle (`Contents/Resources/espalier.sh`, from
// the app target's espalier.sh), as the user, or after an administrator
// prompt when that fails. Nothing happens when the link is already there.
// A link to another copy of Espalier is replaced; anything else there
// (another link, a file, something that can't be looked at) is replaced
// once the user confirms, and a folder isn't. Success says where the tool
// is; a failure shows the command to run instead, with Copy Command.
// Cancelling the confirmation or the administrator prompt shows nothing.
//
// The system calls go through `CommandLineToolSystem`, so tests never
// install anything.

import AppKit
import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import os

private let logger = Log.logger(category: "command-line-tool")

/// What's at the command line tool's path.
enum CommandLineToolItem: Equatable {
    /// Nothing.
    case none
    /// A symbolic link, to where it points (as written in the link).
    case link(String)
    /// A folder.
    case folder
    /// A file, or anything else that isn't a link or a folder.
    case file
    /// Something that couldn't be looked at.
    case unexamined
}

/// What installing the command line tool does to the system.
struct CommandLineToolSystem: Sendable {
    /// The script in the bundle, if it's there.
    var scriptPath: @Sendable () -> String?
    /// What's at a path, not following a link there.
    var item: @Sendable (String) -> CommandLineToolItem
    /// Links `link` to `script` as the user: removes what's at `link`,
    /// makes its folder, and makes the link.
    var linkAsUser: @Sendable (_ script: String, _ link: String) async throws -> Void
    /// Runs a shell command as an administrator, after the system's prompt.
    var runAsAdministrator: @Sendable (_ command: String) async throws(AdministratorCommandError) -> Void

    /// The real system.
    static let live = CommandLineToolSystem(
        scriptPath: {
            Bundle.main.path(forResource: "espalier", ofType: "sh")
        },
        item: { path in
            var info = stat()
            guard lstat(path, &info) == 0 else {
                // Nothing there, or something that can't be looked at.
                return errno == ENOENT || errno == ENOTDIR ? .none : .unexamined
            }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map { .link($0) } ?? .unexamined
            case S_IFDIR:
                return .folder
            default:
                return .file
            }
        },
        linkAsUser: { script, link in
            try await Task.detached {
                let fileManager = FileManager.default
                var info = stat()
                // Unlinks what's there. `unlink` never removes a folder
                // (`removeItem` would, with everything in it).
                if lstat(link, &info) == 0, unlink(link) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
                }
                try fileManager.createDirectory(atPath: POSIXPath.dirname(link), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: link, withDestinationPath: script)
            }.value
        },
        runAsAdministrator: { command throws(AdministratorCommandError) in
            try await AdministratorCommand.run(command)
        }
    )
}

/// Why a command run as an administrator didn't succeed.
enum AdministratorCommandError: Error, Equatable {
    /// The user cancelled the system's prompt.
    case cancelled
    /// The command failed, or couldn't run; the message says why.
    case failed(String)
}

/// Runs shell commands as an administrator, after the system's
/// authorization prompt (`do shell script … with administrator privileges`,
/// through osascript, so Espalier's main thread never waits on the
/// prompt).
enum AdministratorCommand {
    /// Runs `command` (a `/bin/sh` command line) as an administrator.
    static func run(_ command: String) async throws(AdministratorCommandError) {
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        let configuration = ChildProcess.Configuration(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        let child: ChildProcess
        do {
            child = try ChildProcess(configuration)
        } catch {
            throw .failed(error.description)
        }
        let errors = Mutex(Data())
        child.observeStandardError { data in
            errors.withLock { $0.append(data) }
        }
        let termination = await child.waitUntilExit()
        guard termination != .exit(0) else {
            return
        }
        let message = String(decoding: errors.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // osascript reports the cancelled prompt as error -128.
        if message.contains("(-128)") {
            throw .cancelled
        }
        throw .failed(message.isEmpty ? "The command failed." : message)
    }

    /// `text` as an AppleScript string literal.
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `text` quoted for `/bin/sh`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `text` as one `/bin/sh` word: as it is when it's safe, else quoted.
    static func shellWord(_ text: String) -> String {
        let safe = !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "/._-+@%:,=".unicodeScalars.contains(scalar))
        }
        return safe ? text : shellQuoted(text)
    }
}

/// Installs the `espalier` command line tool.
@MainActor
enum CommandLineToolInstaller {
    /// Where the tool is installed.
    static let installedPath = "/usr/local/bin/espalier"

    /// What installing did.
    enum Outcome: Equatable {
        /// The link is in place (it may have been already).
        case installed
        /// The user cancelled the administrator prompt.
        case cancelled
        /// It failed; `command` installs it from Terminal, when the script
        /// is there.
        case failed(message: String, command: String?)
    }

    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.installCommandLineTool) { [weak context] _ in
            guard let context else {
                return
            }
            let outcome = await context.presenter.perform { answers throws(OperationError) in
                try await install(system: .live, confirmed: answers.confirmed)
            }
            if let outcome {
                await present(outcome, in: context)
            }
        }
    }

    /// Links the tool: nothing when it's linked already, else as the user,
    /// else as an administrator. A link to another copy of Espalier's tool
    /// is replaced; a folder is left alone.
    ///
    /// - Throws: `.confirmationRequired(.replaceCommandLineTool)` when a link
    ///   elsewhere, a file, or something that couldn't be looked at is at
    ///   `link` and replacing it isn't confirmed.
    static func install(
        system: CommandLineToolSystem,
        at link: String = installedPath,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> Outcome {
        guard let script = system.scriptPath() else {
            return .failed(message: "The command line tool is missing from Espalier's application bundle.", command: nil)
        }
        let existing = system.item(link)
        switch existing {
        case .link(let destination) where destination == script:
            return .installed
        case .none:
            break
        case .link(let destination) where isEspaliersTool(destination):
            break
        case .folder:
            return .failed(message: "\(link) is a folder. Move or rename it, then try again.", command: nil)
        case .link, .file, .unexamined:
            guard confirmed.contains(.replaceCommandLineTool) else {
                let replaced: ExistingCommandLineTool = switch existing {
                case .link(let destination): .link(destination)
                case .unexamined: .unexamined
                default: .file
                }
                throw OperationError(
                    .confirmationRequired(.replaceCommandLineTool(path: link, existing: replaced)),
                    operation: .installCommandLineTool
                )
            }
        }
        do {
            try await system.linkAsUser(script, link)
            logger.info("Installed the command line tool")
            return .installed
        } catch {
            logger.info("Linking the command line tool needs an administrator: \(error.localizedDescription, privacy: .public)")
        }
        let command = installCommand(script: script, link: link)
        do throws(AdministratorCommandError) {
            try await system.runAsAdministrator(command)
            logger.info("Installed the command line tool as an administrator")
            return .installed
        } catch {
            switch error {
            case .cancelled:
                return .cancelled
            case .failed(let message):
                logger.error("Could not install the command line tool: \(message, privacy: .public)")
                return .failed(message: message, command: installCommand(script: script, link: link, sudo: true))
            }
        }
    }

    /// Whether a link to `destination` is the tool of a copy of Espalier: the
    /// script in an app's resources, there or not.
    static func isEspaliersTool(_ destination: String) -> Bool {
        destination.hasSuffix(".app/Contents/Resources/espalier.sh")
    }

    /// The shell command that installs the tool (unlink, mkdir -p, and
    /// symlink); with `sudo`, as the user runs it in Terminal.
    static func installCommand(script: String, link: String, sudo: Bool = false) -> String {
        let prefix = sudo ? "sudo " : ""
        let folder = AdministratorCommand.shellWord(POSIXPath.dirname(link))
        let source = AdministratorCommand.shellWord(script)
        let destination = AdministratorCommand.shellWord(link)
        return "\(prefix)mkdir -p \(folder) && \(prefix)ln -sfn \(source) \(destination)"
    }

    // MARK: Showing the outcome

    /// The success alert.
    static func installedAlert(at link: String = installedPath) -> AlertContent {
        AlertContent(
            title: "Command Line Tool Installed",
            message: "The command line tool has been installed at \(link).",
            buttons: [AlertContent.Button("OK", role: .primary)]
        )
    }

    /// The failure alert: why, and the command to run instead.
    static func failedAlert(message: String, command: String?) -> AlertContent {
        guard let command else {
            return AlertContent(
                title: "Couldn't Install the Command Line Tool",
                message: message,
                buttons: [AlertContent.Button("Close", role: .primary)]
            )
        }
        return AlertContent(
            title: "Couldn't Install the Command Line Tool",
            message: "\(message)\n\nTo install it yourself, run this command in Terminal:\n\n\(command)",
            buttons: [AlertContent.Button("Copy Command", role: .primary), AlertContent.Button("Close", role: .cancel)]
        )
    }

    /// Shows `outcome` on the window.
    static func present(_ outcome: Outcome, in context: WindowContext) async {
        switch outcome {
        case .installed:
            _ = await context.modals.alert(installedAlert())
        case .cancelled:
            break
        case .failed(let message, let command):
            let response = await context.modals.alert(failedAlert(message: message, command: command))
            if let command, response.buttonIndex == 0 {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}
