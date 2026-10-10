// The state notices' alerts (`StateNotice`): the repository list that
// couldn't be read (and where it went), and a fork's upstream remote
// pointing elsewhere. Their buttons' order is what the host's response index
// means, and each notice's key shows it once.

import EspalierCore
import Foundation
import Testing
@testable import EspalierUI

@Suite("State notices") @MainActor
struct StateNoticesTests {
    @Test("an unreadable repository list says where the file went, with OK first and Show in Finder second")
    func unreadable() {
        let movedTo = URL(filePath: "/Users/joe/Library/Application Support/Espalier/repositories (unreadable).json")
        let notice = StateNotice.persistence(.repositoryListUnreadable(movedTo: movedTo))
        #expect(notice.key == "persistence.unreadable")
        // The host shows the file in Finder for the second button.
        #expect(notice.alert.buttons == [
            AlertContent.Button("OK", role: .primary),
            AlertContent.Button("Show in Finder", role: .secondary),
        ])
        #expect(notice.alert.message.contains("/Users/joe/Library/Application Support/Espalier/repositories (unreadable).json"))
    }

    @Test("an upstream remote that points elsewhere offers Update first and Ignore to cancel, once per repository and URL")
    func upstreamRemoteConflict() {
        func notice(_ id: RepositoryID, currentURL: String) -> StateNotice {
            .upstreamRemoteConflict(
                repositoryID: id,
                repositoryName: "website",
                parentName: "octo-org/website",
                currentURL: currentURL,
                expectedURL: "https://github.com/octo-org/website.git"
            )
        }
        let conflict = notice(UIFixtures.repositoryID, currentURL: "https://github.com/someone/website.git")
        // The host updates the remote for the first button and ignores it
        // otherwise.
        #expect(conflict.alert.buttons == [
            AlertContent.Button("Update", role: .destructive),
            AlertContent.Button("Ignore", role: .cancel),
        ])
        #expect(conflict.alert.message.contains("website"))
        #expect(conflict.alert.message.contains("octo-org/website"))
        #expect(conflict.alert.message.contains("https://github.com/someone/website.git"))
        #expect(conflict.alert.message.contains("https://github.com/octo-org/website.git"))

        // Shown again for another URL or another repository, not for the
        // same one.
        #expect(notice(UIFixtures.repositoryID, currentURL: "https://github.com/someone/website.git").key == conflict.key)
        #expect(notice(UIFixtures.repositoryID, currentURL: "https://github.com/other/website.git").key != conflict.key)
        #expect(notice(RepositoryID(), currentURL: "https://github.com/someone/website.git").key != conflict.key)
    }
}
