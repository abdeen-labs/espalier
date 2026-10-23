// Small views the repository sheets share: a folder field with Choose…, a
// call to action (a symbol, a line, and a button), and the sign-in call to
// action, whose new account the sheet chooses.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import SwiftUI

/// A folder's path with Choose…
struct FolderField: View {
    let label: String
    @Binding var path: String
    var prompt = "repository path"
    var choose: () -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: Metrics.insetSmall) {
                TextField(label, text: $path, prompt: Text(prompt).fieldPrompt())
                    .labelsHidden()
                    .textFieldStyle(.capsule)
                Button("Choose…", action: choose)
                    .buttonStyle(.quiet)
            }
        }
    }
}

/// "Sign in to your GitHub account to access your repositories." [Sign
/// In…], and Sign In to GitHub Enterprise…: what Clone and Publish show
/// without an account. The sign-in sheet shows on top, and the account
/// signed in to goes to `onSignIn`, for the sheet to choose it.
struct AccountsSignInPrompt: View {
    var onSignIn: (Account) -> Void
    @Environment(WindowContext.self) private var context

    var body: some View {
        SheetCallToAction(systemImage: "person.crop.circle", message: "Sign in to your GitHub account to access your repositories.") {
            VStack(spacing: Metrics.insetSmall) {
                Button("Sign In…") {
                    signIn(nil)
                }
                .buttonStyle(.quiet)
                Button("Sign In to GitHub Enterprise…") {
                    signIn(SignInRequest.enterpriseEndpoint)
                }
                .buttonStyle(.textLink)
            }
        }
    }

    private func signIn(_ endpoint: String?) {
        let onSignIn = onSignIn
        context.modals.presentSheet(id: SignInSheet.sheetID) {
            SignInSheet(request: SignInRequest(endpoint: endpoint)) { account in
                if let account {
                    onSignIn(account)
                }
            }
        }
    }
}

/// A call to action in a sheet's area: a symbol in a soft circle, a line,
/// and a button (signing in, publishing).
struct SheetCallToAction<Action: View>: View {
    let systemImage: String
    let message: String
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: Metrics.insetMedium) {
            IconCircle(systemImage, size: Metrics.StateIcon.callToActionSize)
                .accessibilityHidden(true)
            Text(message)
                .font(Typography.row)
                .foregroundStyle(.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action
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
