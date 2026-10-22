// The Debug menu's checks: Check Menu Shortcuts (`MenuBarAudit` on the
// running app's menu bar) and Post Sample Pull Request Notification (one
// sample review that routes like a real one when clicked).

import EspalierCore
import GitHubKit
import SwiftUI

/// Registers the Debug menu's checks.
@MainActor
enum DebugActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.checkMenuShortcuts) { [weak context] _ in
            guard let context else {
                return
            }
            await MenuBarAudit.check(in: context)
        }

        actions.register(.postSampleNotification) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            if let pullRequest = await repository.gitHub.postSampleNotification() {
                context.presenter.show(Toast("Posted a sample notification for #\(pullRequest.pullRequestNumber).", systemImage: "bell", tone: .notice))
            } else {
                context.presenter.show(Toast("This repository has no open pull request to notify about.", systemImage: "bell.slash", tone: .notice))
            }
        }
    }
}
