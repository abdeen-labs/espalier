// "Move Espalier to the Applications folder?" at launch, when
// `askToMoveToApplicationsFolder` is on, the app isn't in an Applications
// folder, and it isn't a development build: Not Now, Move and Restart, and
// "Do not show this message again", which Not Now saves.
// `ApplicationsFolderMover.live` moves the app: an Espalier already running
// from /Applications takes over, an older copy there goes to the Trash, the
// app is moved (copied from a read-only volume) as the user or, when
// /Applications isn't writable, after an administrator prompt, and it
// relaunches from there.
//
// The system calls go through `ApplicationsFolderMover`, so tests never move
// the app.

import AppKit
import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "move-to-applications")

/// What offering to move Espalier needs from the system.
struct ApplicationsFolderMover: Sendable {
    /// Whether Espalier runs from an Applications folder.
    var isInApplicationsFolder: @Sendable () -> Bool
    /// Whether this is a development build (the prompt never shows then: a
    /// build runs from where it was built).
    var isDevelopmentBuild: Bool
    /// Moves Espalier to /Applications and relaunches it from there.
    var moveAndRelaunch: @MainActor @Sendable () async throws(ApplicationsFolderMoveError) -> Void

    /// The real system.
    static let live = ApplicationsFolderMover(
        isInApplicationsFolder: {
            ApplicationsFolderMove.isInApplicationsFolder(Bundle.main.bundlePath)
        },
        isDevelopmentBuild: {
            #if DEBUG
            true
            #else
            false
            #endif
        }(),
        moveAndRelaunch: { () async throws(ApplicationsFolderMoveError) in
            try await ApplicationsFolderMove.moveAndRelaunch(Bundle.main.bundlePath)
        }
    )
}

/// Why moving Espalier failed.
struct ApplicationsFolderMoveError: Error, Equatable {
    let message: String
}

/// Offers to move Espalier to /Applications at launch.
@MainActor
public enum MoveToApplicationsPrompt {
    /// Shows the prompt if it applies.
    public static func presentIfNeeded(in context: WindowContext) {
        presentIfNeeded(in: context, mover: .live)
    }

    /// Shows the prompt if it applies, moving with `mover`.
    static func presentIfNeeded(in context: WindowContext, mover: ApplicationsFolderMover) {
        guard shouldAsk(context.app.preferences, mover: mover) else {
            return
        }
        let modals = context.modals
        Task {
            await waitForWindow(modals)
            let response = await modals.alert(alert, id: alertID)
            await respond(response, preferences: context.app.preferences, mover: mover) { content in
                await modals.alert(content)
            }
        }
    }

    static let alertID = "onboarding.moveToApplications"

    /// Whether to ask: the setting is on, Espalier isn't in an Applications
    /// folder, and it isn't a development build.
    static func shouldAsk(_ preferences: Preferences, mover: ApplicationsFolderMover) -> Bool {
        preferences.askToMoveToApplicationsFolder && !mover.isDevelopmentBuild && !mover.isInApplicationsFolder()
    }

    /// The alert: Move and Restart (the default), Not Now, and the
    /// suppression toggle.
    static let alert = AlertContent(
        title: "Move Espalier to the Applications folder?",
        message: "Espalier isn't running from the Applications folder. This could cause problems with the app, including with signing in.\n\nDo you want to move Espalier to the Applications folder now? This will also restart Espalier.",
        buttons: [
            AlertContent.Button("Move and Restart", role: .primary),
            AlertContent.Button("Not Now", role: .cancel),
        ],
        suppressionTitle: AlertContent.doNotShowAgain
    )

    /// Answers the prompt: Not Now saves "Do not show this message again";
    /// Move and Restart moves, and shows why (with `showAlert`) if it can't.
    static func respond(
        _ response: AlertResponse,
        preferences: Preferences,
        mover: ApplicationsFolderMover,
        showAlert: @MainActor (AlertContent) async -> AlertResponse
    ) async {
        guard response.buttonIndex == 0 else {
            if response.isSuppressed {
                preferences.askToMoveToApplicationsFolder = false
            }
            return
        }
        do throws(ApplicationsFolderMoveError) {
            try await mover.moveAndRelaunch()
        } catch {
            logger.error("Could not move Espalier to the Applications folder: \(error.message, privacy: .public)")
            _ = await showAlert(failureAlert(error.message))
        }
    }

    /// Moving failed.
    static func failureAlert(_ message: String) -> AlertContent {
        AlertContent(
            title: "Couldn't Move Espalier",
            message: "\(message)\n\nYou can move Espalier to the Applications folder in the Finder.",
            buttons: [AlertContent.Button("OK", role: .primary)]
        )
    }

    /// Waits until the window can hold the alert (its observer connects it
    /// as the window first lays out), a few run loop turns at most.
    private static func waitForWindow(_ modals: ModalPresenter) async {
        for _ in 0..<20 where modals.window == nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }
}

/// Moving the app bundle to /Applications.
enum ApplicationsFolderMove {
    /// Whether `bundlePath` is in an Applications folder: one of the
    /// system's, or any folder named Applications (another volume's).
    nonisolated static func isInApplicationsFolder(_ bundlePath: String) -> Bool {
        let folders = FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask).map { url in
            let path = url.path(percentEncoded: false)
            return path.hasSuffix("/") ? path : path + "/"
        }
        return folders.contains { bundlePath.hasPrefix($0) } || bundlePath.contains("/Applications/")
    }

    /// Where the bundle at `bundlePath` goes: `/Applications/<name>.app`, or
    /// nil for a path whose last component isn't an app bundle's name. What's
    /// at the destination is replaced (as an administrator, with `rm -rf`),
    /// so it must never be the Applications folder itself.
    nonisolated static func destination(for bundlePath: String) -> String? {
        let name = POSIXPath.basename(bundlePath)
        guard name.count > ".app".count, name.hasSuffix(".app"), !name.contains("/"), !name.hasPrefix(".") else {
            return nil
        }
        return POSIXPath.join("/Applications", name)
    }

    /// Moves the bundle at `bundlePath` to /Applications and relaunches it
    /// from there; quits when an Espalier already runs from there.
    @MainActor
    static func moveAndRelaunch(_ bundlePath: String) async throws(ApplicationsFolderMoveError) {
        guard let destination = destination(for: bundlePath) else {
            throw ApplicationsFolderMoveError(message: "Couldn't tell where to move Espalier in the Applications folder.")
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.bundleURL?.path(percentEncoded: false) == destination && $0 != NSRunningApplication.current }) {
            running.activate()
            AppTermination.quit()
            return
        }
        // A disk image (or a translocated download) is read-only: copy.
        let copies = isOnReadOnlyVolume(bundlePath) || bundlePath.contains("/AppTranslocation/")
        if FileManager.default.isWritableFile(atPath: "/Applications") {
            try await moveAsUser(bundlePath, to: destination, copies: copies)
        } else {
            try await moveAsAdministrator(bundlePath, to: destination, copies: copies)
        }
        try relaunch(destination)
    }

    private static func moveAsUser(_ source: String, to destination: String, copies: Bool) async throws(ApplicationsFolderMoveError) {
        do {
            try await Task.detached {
                let fileManager = FileManager.default
                var info = stat()
                if lstat(destination, &info) == 0 {
                    try fileManager.trashItem(at: URL(filePath: destination), resultingItemURL: nil)
                }
                if copies {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                } else {
                    try fileManager.moveItem(atPath: source, toPath: destination)
                }
            }.value
        } catch {
            throw ApplicationsFolderMoveError(message: error.localizedDescription)
        }
    }

    private static func moveAsAdministrator(_ source: String, to destination: String, copies: Bool) async throws(ApplicationsFolderMoveError) {
        let quotedSource = AdministratorCommand.shellQuoted(source)
        let quotedDestination = AdministratorCommand.shellQuoted(destination)
        let command = "/bin/rm -rf \(quotedDestination) && /bin/cp -pR \(quotedSource) \(quotedDestination)"
        do throws(AdministratorCommandError) {
            try await AdministratorCommand.run(command)
        } catch {
            switch error {
            case .cancelled:
                throw ApplicationsFolderMoveError(message: "Moving Espalier needs an administrator's permission.")
            case .failed(let message):
                throw ApplicationsFolderMoveError(message: message)
            }
        }
        // The copy is in place; the original goes to the Trash when it can.
        if !copies {
            try? FileManager.default.trashItem(at: URL(filePath: source), resultingItemURL: nil)
        }
    }

    /// Opens Espalier from `path` once this process has quit, then quits.
    @MainActor
    private static func relaunch(_ path: String) throws(ApplicationsFolderMoveError) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        do {
            _ = try ChildProcess.spawnDetached(ChildProcess.Configuration(executablePath: "/bin/sh", arguments: ["-c", script, path]))
        } catch {
            throw ApplicationsFolderMoveError(message: error.description)
        }
        AppTermination.quit()
    }

    private nonisolated static func isOnReadOnlyVolume(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            return false
        }
        return (info.f_flags & UInt32(MNT_RDONLY)) != 0
    }
}
