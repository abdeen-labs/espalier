// "Push Blocked: Secret Detected", which the shell's error host shows for
// `.pushProtectionBlocked`: the error's text, what exposing a secret allows,
// each secret (its description, with its ID when two share one), its first
// location (the short SHA with a copy button, "<path> at line <n>") and Show
// More Locations, and Bypass…, which asks why (BypassReasonSheet) and then
// shows "Bypassed"; a secret that needs approval links to GitHub's page
// instead. Then the user pushes again.

import AppKit
import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// A secret, as the sheet lists it.
nonisolated struct DetectedSecretContent: Sendable, Equatable, Identifiable {
    /// The secret's ID (GitHub's placeholder ID).
    var id: String
    /// "GitHub Personal Access Token", with " (<id>)" when another secret
    /// has the same description.
    var title: String
    var locations: [SecretLocation]
    /// GitHub's page for bypassing it.
    var bypassURL: URL?
    /// The user can't bypass it, only ask for a bypass on GitHub.
    var requiresApproval: Bool
    var isBypassed: Bool

    /// The secrets of an error, `bypassed` marked.
    static func list(_ secrets: [SecretScanResult], bypassed: Set<String>) -> [DetectedSecretContent] {
        secrets.map { secret in
            let shared = secrets.filter { $0.description == secret.description }.count > 1
            return DetectedSecretContent(
                id: secret.id,
                title: shared ? "\(secret.description) (\(secret.id))" : secret.description,
                locations: secret.locations,
                bypassURL: URL(string: secret.bypassURL),
                requiresApproval: secret.requiresApproval,
                isBypassed: bypassed.contains(secret.id)
            )
        }
    }
}

/// The secrets push protection found.
public struct PushProtectionSheet: View {
    private let error: OperationError
    @Environment(\.dismissModal) private var dismissModal
    @Environment(WindowContext.self) private var context: WindowContext?
    @State private var bypassed: Set<String> = []

    public init(error: OperationError) {
        self.error = error
    }

    public var body: some View {
        PushProtectionView(
            title: error.title,
            message: error.message,
            secrets: DetectedSecretContent.list(secrets, bypassed: bypassed),
            actions: PushProtectionActions(
                bypass: { id in
                    guard let secret = secrets.first(where: { $0.id == id }) else {
                        return
                    }
                    BypassReasonSheet.present(secret: secret, repositoryID: error.repositoryID, in: context) {
                        bypassed.insert(id)
                    }
                },
                open: { url in
                    context?.app.integrations.openInBrowser(url)
                },
                copy: Self.copy,
                close: { dismissModal() }
            )
        )
    }

    private var secrets: [SecretScanResult] {
        if case .pushProtectionBlocked(let secrets) = error.reason {
            return secrets
        }
        return []
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Shows the sheet for `secrets` (the `.reviewPushProtection` action,
    /// when a recovery runs from somewhere other than the error's own
    /// sheet).
    @MainActor
    static func present(repositoryID: RepositoryID, secrets: [SecretScanResult], in context: WindowContext) {
        let error = OperationError(.pushProtectionBlocked(secrets), operation: .push, repositoryID: repositoryID)
        context.modals.presentSheet(id: ErrorHost.sheetID) {
            PushProtectionSheet(error: error)
        }
    }
}

/// What the sheet's buttons do.
struct PushProtectionActions {
    /// Bypass… for the secret with this ID.
    var bypass: (String) -> Void
    var open: (URL) -> Void
    var copy: (String) -> Void
    var close: () -> Void
}

/// The sheet's content.
struct PushProtectionView: View {
    let title: String
    /// The error's message.
    let message: String
    let secrets: [DetectedSecretContent]
    let actions: PushProtectionActions

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            HStack(spacing: Metrics.insetMedium) {
                IconCircle("exclamationmark.shield.fill", size: Metrics.StateIcon.size, tint: Color(espalier: Palette.error))
                Text(title)
                    .font(Typography.sheetTitle)
                    .foregroundStyle(.text)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                Text(message)
                Text("Exposing this secret can allow someone to:")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.risks, id: \.self) { risk in
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.bulletSpacing) {
                            Text("•")
                                .foregroundStyle(.text3)
                            Text(risk)
                        }
                    }
                }
                .padding(.leading, Metrics.grid)
            }
            .foregroundStyle(.text2)
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(secrets) { secret in
                        DetectedSecretRow(secret: secret, actions: actions)
                        if secret.id != secrets.last?.id {
                            Hairline()
                        }
                    }
                }
                .cardSurface()
                .padding(1)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Secrets")
            HStack {
                Spacer()
                Button("Close", action: actions.close)
                    .buttonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Metrics.grid)
        }
        .padding(Metrics.Sheet.padding)
        .frame(width: Metrics.Sheet.terminalWidth, alignment: .leading)
        .background(Color(espalier: Palette.background))
    }

    /// What exposing a secret allows.
    static let risks = [
        "Verify the identity of the secrets",
        "Know which resources the secrets can access",
        "Act on behalf of the secret's owner",
        "Push the secrets to this repository without being blocked",
    ]
}

/// A secret: its title, Bypass… or Bypassed, and its locations.
private struct DetectedSecretRow: View {
    let secret: DetectedSecretContent
    let actions: PushProtectionActions
    @State private var showsMoreLocations = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
            HStack(spacing: Metrics.insetSmall) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.text2)
                    .accessibilityHidden(true)
                Text(secret.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.text)
                    .textSelection(.enabled)
                Spacer(minLength: Metrics.insetSmall)
                bypass
            }
            if let first = secret.locations.first {
                HStack(spacing: Metrics.insetSmall) {
                    SecretLocationView(location: first, copy: actions.copy)
                    if secret.locations.count > 1 {
                        Button {
                            showsMoreLocations.toggle()
                        } label: {
                            Label(showsMoreLocations ? "Show Fewer Locations" : "Show More Locations", systemImage: "ellipsis.circle")
                        }
                        .buttonStyle(.icon)
                        .tooltip(showsMoreLocations ? "Show Fewer Locations" : "Show More Locations")
                        .accessibilityLabel(showsMoreLocations ? "Show Fewer Locations" : "Show More Locations")
                    }
                }
                if showsMoreLocations {
                    ForEach(Array(secret.locations.dropFirst().enumerated()), id: \.offset) { _, location in
                        SecretLocationView(location: location, copy: actions.copy)
                    }
                }
            }
        }
        .padding(Metrics.insetMedium)
    }

    @ViewBuilder
    private var bypass: some View {
        if secret.isBypassed {
            Label("Bypassed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.success))
                .font(Typography.secondary)
        } else if secret.requiresApproval, let url = secret.bypassURL {
            Button("Bypass…") {
                actions.open(url)
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .tooltip("Ask for a bypass on GitHub")
            .accessibilityLabel("Bypass \(secret.title)")
        } else {
            Button("Bypass…") {
                actions.bypass(secret.id)
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .accessibilityLabel("Bypass \(secret.title)")
        }
    }
}

/// Where a secret is: the commit's short SHA (with a copy button), and
/// "<path> at line <n>".
private struct SecretLocationView: View {
    let location: SecretLocation
    let copy: (String) -> Void

    var body: some View {
        HStack(spacing: Metrics.grid) {
            Image(systemName: "smallcircle.filled.circle")
                .foregroundStyle(.text3)
                .accessibilityHidden(true)
            Text(String(location.commitSha.prefix(7)))
                .font(Typography.sha)
                .foregroundStyle(.text2)
                .textSelection(.enabled)
            // After a copy, the symbol is a check for a moment (CopyButton).
            CopyButton(location.commitSha, copy: copy) { systemImage in
                // The copy symbol's room, whichever shows.
                ZStack {
                    Image(systemName: "doc.on.doc")
                        .hidden()
                    Image(systemName: systemImage)
                }
                .foregroundStyle(.text3)
            }
            .buttonStyle(.bare)
            .tooltip("Copy the full SHA")
            .accessibilityLabel("Copy the full SHA")
            Text(verbatim: "\(location.path) at line \(location.lineNumber)")
                .font(Typography.secondary)
                .foregroundStyle(.text3)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .tooltip(location.path)
        }
    }
}
