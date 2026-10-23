// A co-author's token keeps its identity as others come and go, so the
// token removed is the one that fades out and the others move; a repeated
// co-author has a token of its own, and a login looked up keeps its token.

import GitKit
import Testing
@testable import EspalierUI

@Suite("Co-author token identity") @MainActor
struct CoAuthorTokenIDTests {
    @Test("Removing a co-author keeps the others' tokens, and repeated co-authors each have one")
    func identities() {
        let octocat = Author.known(KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: "octocat"))
        let hubot = Author.unknown(UnknownAuthor(username: "hubot", state: .searching))
        let jane = Author.known(KnownAuthor(name: "Jane Bloggs", email: "jane@example.com", username: nil))
        let authors = [octocat, hubot, octocat, jane]
        let ids = CoAuthorsField.tokenIDs(authors)
        #expect(Set(ids).count == authors.count)

        var remaining = authors
        remaining.remove(at: 1)
        #expect(CoAuthorsField.tokenIDs(remaining) == [ids[0], ids[2], ids[3]])

        let found = Author.known(KnownAuthor(name: "Hubot", email: "hubot@example.com", username: "hubot"))
        #expect(CoAuthorsField.tokenIDs([octocat, found, octocat, jane]) == ids)
    }
}
