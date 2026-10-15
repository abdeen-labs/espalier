// Why the user bypasses push protection for a secret: "Why are you bypassing
// this <description>?", It's used in tests, It's a false positive, I'll fix
// it later, and the destructive Allow Me to Expose This Secret. The bypass
// goes to GitHub (`bypassPushProtection(_:reason:)`); its error shows as an
// alert.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// A reason, with its title and description.
nonisolated struct BypassReasonOption: Sendable, Equatable, Identifiable {
    var reason: BypassReason
    var title: String
    var description: String

    var id: String {
        reason.rawValue
    }

    /// The reasons, in order.
    static let all = [
        BypassReasonOption(
            reason: .usedInTests,
            title: "It's used in tests",
            description: "The secret poses no risk. If anyone finds it, they cannot do any damage or gain access to sensitive information."
        ),
        BypassReasonOption(
            reason: .falsePositive,
            title: "It's a false positive",
            description: "The detected string is not a secret."
        ),
        BypassReasonOption(
            reason: .willFixLater,
            title: "I'll fix it later",
            description: "The secret is real, I understand the risk, and I will need to revoke it. This will open a security alert and notify admins of this repository."
        ),
    ]
}

/// Asks why a secret is bypassed, then bypasses it.
struct BypassReasonSheet: View {
    static let sheetID = "espalier.github.bypassReason"

    let secret: SecretScanResult
    let repository: RepositoryModel?
    let onBypassed: () -> Void
    @Environment(WindowContext.self) private var context: WindowContext?
    @Environment(\.dismissModal) private var dismissModal
    @State private var reason: BypassReason = .falsePositive
    @State private var isBypassing = false

    var body: some View {
        BypassReasonView(
            secretDescription: secret.description,
            reason: $reason,
            isBypassing: isBypassing,
            cancel: { dismissModal() },
            bypass: bypass
        )
    }

    private func bypass() {
        guard let repository, let context, !isBypassing else {
            return
        }
        isBypassing = true
        let secret = secret
        let reason = reason
        Task {
            let bypassed = await Self.bypass(secret, reason: reason, repository: repository, presenter: context.presenter)
            isBypassing = false
            if bypassed {
                onBypassed()
                dismissModal()
            }
        }
    }

    /// Tells GitHub why the secret may be pushed
    /// (`bypassPushProtection(_:reason:)`) through the window's presenter,
    /// which shows a failure; whether GitHub allowed it.
    static func bypass(_ secret: SecretScanResult, reason: BypassReason, repository: RepositoryModel, presenter: WindowPresenter) async -> Bool {
        let response = await presenter.perform { _ throws(OperationError) in
            try await repository.gitHub.bypassPushProtection(secret, reason: reason)
        }
        return response != nil
    }

    /// Shows the sheet over the window's topmost sheet.
    @MainActor
    static func present(secret: SecretScanResult, repositoryID: RepositoryID?, in context: WindowContext?, onBypassed: @escaping () -> Void) {
        guard let context else {
            return
        }
        let repository = repositoryID.flatMap { context.app.repository($0) } ?? context.repository
        context.modals.presentSheet(id: sheetID) {
            BypassReasonSheet(secret: secret, repository: repository, onBypassed: onBypassed)
        }
    }
}

/// The sheet's content.
struct BypassReasonView: View {
    let secretDescription: String
    @Binding var reason: BypassReason
    let isBypassing: Bool
    let cancel: () -> Void
    let bypass: () -> Void

    var body: some View {
        SheetScaffold("Bypass Push Protection", message: "Why are you bypassing this \(secretDescription)?") {
            ChoiceList(
                "Reason",
                selection: $reason,
                choices: BypassReasonOption.all.map { ChoiceListItem($0.title, description: $0.description, value: $0.reason) }
            )
            .disabled(isBypassing)
        } buttons: {
            if isBypassing {
                ArcProgress(.small)
            }
            Spacer()
            // Exposing a secret is never the default.
            Button("Allow Me to Expose This Secret", role: .destructive, action: bypass)
                .buttonStyle(.quiet)
                .disabled(isBypassing)
            SheetDismissButton("Cancel", action: cancel)
        }
    }
}
