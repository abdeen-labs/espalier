// Ported from desktop/app/src/lib/editors/launch.ts

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "integrations")

/// Starts an editor, detached and with its output ignored, without waiting
/// for it to exit.
///
/// - Parameters:
///   - editorPath: The application to open (with `spawnAsDarwinApp`), or the
///     executable to run.
///   - args: The arguments for the editor.
///   - editorName: How messages name the editor: `Visual Studio Code`, or
///     `the custom editor at /usr/local/bin/code`.
///   - spawnAsDarwinApp: Whether to open the application with `open -a`.
///   - editorNameIncludesPath: Whether `editorName` already ends with the
///     path, as a custom editor's does, so a missing editor's message
///     names the path once.
@concurrent
func launchEditor(
    _ editorPath: String,
    _ args: [String],
    _ editorName: String,
    _ spawnAsDarwinApp: Bool,
    editorNameIncludesPath: Bool = false,
    launcher: any IntegrationLauncher
) async throws(ExternalEditorError) {
    let exists = await pathExists(editorPath)
    if !exists {
        let editor = editorNameIncludesPath ? editorName : "\(editorName) at \(editorPath)"
        throw ExternalEditorError(
            "Espalier couldn't find \(editor). Choose an available editor in Settings ▸ Integrations.",
            metadata: ExternalEditorError.Metadata(openPreferences: true)
        )
    }

    // Editors are detached, with their output ignored, so closing the app
    // doesn't take them with it.
    let command =
        spawnAsDarwinApp
        ? LaunchCommand(executable: openCommandPath, arguments: ["-a", editorPath] + args, isDetached: true)
        : LaunchCommand(executable: editorPath, arguments: args, isDetached: true)

    do {
        try launcher.spawn(command, tracing: nil)
    } catch {
        logger.error(
            "Error while launching \(editorName, privacy: .private): \(error.localizedDescription, privacy: .public)"
        )
        throw ExternalEditorError(
            error.code == "EACCES"
                ? "Espalier doesn't have permission to open \(editorName). Choose another editor in Settings ▸ Integrations."
                : "Espalier couldn't open \(editorName). Choose another editor in Settings ▸ Integrations.",
            metadata: ExternalEditorError.Metadata(openPreferences: true)
        )
    }
}

/// Open a given file or folder in the desired external editor.
///
/// Runs `open -a <editor> <fullPath>`.
///
/// - Parameters:
///   - fullPath: A folder or file path to pass as an argument when launching
///     the editor.
///   - editor: The external editor to launch.
///   - launcher: Starts the process.
@concurrent
public func launchExternalEditor(
    _ fullPath: String,
    _ editor: FoundEditor,
    launcher: any IntegrationLauncher = ChildProcessLauncher()
) async throws(ExternalEditorError) {
    try await launchEditor(editor.path, [fullPath], editor.editor, true, launcher: launcher)
}

/// Open a given file or folder in the desired custom external editor.
///
/// Runs `open -a <path> <arguments>` for an application (one with a bundle
/// ID), otherwise `<path> <arguments>`, with `%TARGET_PATH%` in the
/// arguments replaced by `fullPath`.
///
/// - Parameters:
///   - fullPath: A folder or file path to pass as an argument when launching
///     the editor.
///   - customEditor: The external editor to launch.
///   - launcher: Starts the process.
@concurrent
public func launchCustomExternalEditor(
    _ fullPath: String,
    _ customEditor: CustomIntegration,
    launcher: any IntegrationLauncher = ChildProcessLauncher()
) async throws(ExternalEditorError) {
    let argv = parseCustomIntegrationArguments(customEditor.arguments)

    // Replace instances of TargetPathArgument with fullPath in
    // customEditor.arguments
    let args = expandTargetPathArgument(argv, fullPath)

    // In macOS we can use `open` if it's an app (i.e. if we have a bundleID),
    // which will open the right executable file for us, we only need the path
    // to the editor .app folder.
    let spawnAsDarwinApp = customEditor.bundleID != nil
    let editorName = "the custom editor at \(customEditor.path)"

    try await launchEditor(
        customEditor.path,
        args,
        editorName,
        spawnAsDarwinApp,
        editorNameIncludesPath: true,
        launcher: launcher
    )
}
