// The state notices' alerts (`StateNotice`): the repository list that
// couldn't be read, and a fork's upstream remote pointing elsewhere. Their
// buttons' order is what the host's response index means, and each notice's
// key shows it once.

import EspalierCore
import Foundation
import Testing
@testable import EspalierUI

@Suite("State notices") @MainActor
struct StateNoticesTests {
    @Test("an unreadable repository list's alert has its primary button first and its secondary second")
    func unreadable() {
        let movedTo = URL(filePath: "/Users/joe/Library/Application Support/Espalier/repositories (unreadable).json")
        let notice = StateNotice.persistence(.repositoryListUnreadable(movedTo: movedTo))
        #expect(notice.key == "persistence.unreadable")
        // The host shows the file in Finder for the second button.
        #expect(notice.alert.buttons.map(\.role) == [.primary, .secondary])
    }

    @Test("an upstream remote that points elsewhere offers the update first and a cancel, once per repository and URL")
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
        #expect(conflict.alert.buttons.map(\.role) == [.destructive, .cancel])

        // Shown again for another URL or another repository, not for the
        // same one.
        #expect(notice(UIFixtures.repositoryID, currentURL: "https://github.com/someone/website.git").key == conflict.key)
        #expect(notice(UIFixtures.repositoryID, currentURL: "https://github.com/other/website.git").key != conflict.key)
        #expect(notice(RepositoryID(), currentURL: "https://github.com/someone/website.git").key != conflict.key)
    }
}
