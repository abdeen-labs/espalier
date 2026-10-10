// Small views the repository sheets share: a line under a field, the buttons
// row, a folder field with Choose…, and a sign-in call to action.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import SwiftUI

/// The design system's line under a field, taking the width it's given, so a
/// long message wraps in a form's column instead of running past it.
struct SheetMessage: View {
    private let text: String
    private let kind: FieldMessage.Kind

    init(_ text: String, kind: FieldMessage.Kind) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        FieldMessage(text, kind: kind)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A folder's path with Choose…
struct FolderField: View {
    let label: String
    @Binding var path: String
    var prompt = "repository path"
    var choose: () -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: Metrics.insetSmall) {
                TextField(label, text: $path, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.capsule)
                Button("Choose…", action: choose)
                    .buttonStyle(.quiet)
            }
        }
    }
}

/// "Sign in to your GitHub.com account to access your repositories."
/// [Sign In…] (the call to action Clone and Publish show for a server
/// without an account).
struct RepositorySignInPrompt: View {
    /// Whether it's for GitHub Enterprise rather than GitHub.com.
    let isEnterprise: Bool
    /// The server to sign in to: nil for GitHub.com.
    let endpoint: String?
    @Environment(WindowContext.self) private var context

    /// The text for a server.
    static func message(forEnterprise isEnterprise: Bool) -> String {
        isEnterprise
            ? "Sign in to your GitHub Enterprise account to access your repositories."
            : "Sign in to your GitHub.com account to access your repositories."
    }

    var body: some View {
        VStack(spacing: Metrics.insetMedium) {
            IconCircle("person.crop.circle", size: 36)
            Text(Self.message(forEnterprise: isEnterprise))
                .font(Typography.row)
                .foregroundStyle(.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(.signIn(endpoint: endpoint, then: nil), title: "Sign In…")
                .buttonStyle(.quiet)
        }
        .frame(maxWidth: .infinity)
        .padding(Metrics.insetLarge)
    }
}

/// Choose…: a folder, as a sheet on the sheet that asks.
@MainActor
enum FolderChooser {
    /// An open panel for a folder that may not exist yet, starting at
    /// `directory`.
    static func chooseFolder(startingAt directory: String?, prompt: String = "Choose", completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        if let directory, !directory.isEmpty {
            panel.directoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        }
        begin(panel) { url in
            completion(AddRepositoryPanel.folderPath(url))
        }
    }

    /// Clone's Choose…, a save panel: "Select", "Clone As:", the folder and
    /// name of `path`, folders can be made.
    static func chooseCloneDestination(_ path: String, completion: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.prompt = "Select"
        panel.nameFieldLabel = "Clone As:"
        panel.canCreateDirectories = true
        if !path.isEmpty {
            panel.directoryURL = URL(filePath: POSIXPath.dirname(path), directoryHint: .isDirectory)
            panel.nameFieldStringValue = POSIXPath.basename(path)
        }
        begin(panel) { url in
            completion(AddRepositoryPanel.folderPath(url))
        }
    }

    private static func begin(_ panel: NSSavePanel, completion: @escaping (URL) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                completion(url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
