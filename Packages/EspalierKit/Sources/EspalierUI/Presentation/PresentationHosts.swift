// Attaches the presenter's hosts to the window. Each host watches one piece
// of state and shows it through the window's `ModalPresenter`.

import EspalierCore
import GitKit
import SwiftUI

/// Shows the presenter's confirmations, decisions, and errors, the prompts
/// git waits on, and the state notices.
struct PresentationHosts: ViewModifier {
    let context: WindowContext

    func body(content: Content) -> some View {
        content
            .onChange(of: context.presenter.confirmation?.id, initial: true) {
                if let pending = context.presenter.confirmation {
                    ConfirmationHost.present(pending, in: context)
                }
            }
            .onChange(of: context.presenter.decision?.id, initial: true) {
                if let pending = context.presenter.decision {
                    DecisionHost.present(pending, in: context)
                }
            }
            .onChange(of: context.presenter.error?.id, initial: true) {
                if let presented = context.presenter.error {
                    ErrorHost.present(presented, in: context)
                }
            }
            .onChange(of: context.app.prompts.pending.map(\.id), initial: true) {
                context.promptHost.update()
            }
            .onChange(of: context.app.loadState == .ready && context.app.persistenceIssue != nil, initial: true) {
                if context.app.loadState == .ready {
                    StateNoticesHost.showPersistenceIssue(in: context)
                }
            }
            .onChange(of: context.app.loadState == .ready && context.app.integrations.lfsFiltersError != nil, initial: true) {
                if context.app.loadState == .ready {
                    StateNoticesHost.showLFSFiltersError(in: context)
                }
            }
            .onChange(of: context.app.selectedRepository?.sync.upstreamRemoteConflict, initial: true) {
                StateNoticesHost.showUpstreamRemoteConflict(in: context)
            }
            // The AI conflict sheet opens with a round, also one that
            // started by itself.
            .modifier(AIConflictSheetHost(context: context))
            // Invalidated accounts, account problems, notification clicks.
            .gitHubPresentationHosts(context)
    }
}

extension View {
    /// Attaches the window's presentation hosts.
    func presentationHosts(_ context: WindowContext) -> some View {
        modifier(PresentationHosts(context: context))
    }
}
