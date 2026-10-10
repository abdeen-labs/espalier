// Ported from desktop/app/test/unit/commit-identity-test.ts

import Foundation
import GitKit
import Testing

@Suite("CommitIdentity")
struct CommitIdentityTests {
    @Suite("#parseIdent")
    struct ParseIdent {
        @Test("understands a normal ident string")
        func understandsANormalIdentString() throws {
            let identity = try CommitIdentity.parseIdentity(
                "Markus Olsson <markus@github.com> 1475670580 +0200"
            )
            #expect(identity.name == "Markus Olsson")
            #expect(identity.email == "markus@github.com")
            let expected = try #require(ISO8601DateFormatter().date(from: "2016-10-05T12:29:40Z"))
            #expect(identity.date == expected)
        }

        @Test("parses timezone information")
        func parsesTimezoneInformation() throws {
            let identity1 = try CommitIdentity.parseIdentity(
                "Markus Olsson <markus@github.com> 1475670580 +0130"
            )
            #expect(identity1.tzOffset == 90)

            let identity2 = try CommitIdentity.parseIdentity(
                "Markus Olsson <markus@github.com> 1475670580 -0245"
            )
            #expect(identity2.tzOffset == -165)
        }

        @Test("parses even if the email address isn't a normal email")
        func parsesEvenIfTheEmailAddressIsNotANormalEmail() throws {
            let identity = try CommitIdentity.parseIdentity(
                "Markus Olsson <Markus Olsson> 1475670580 +0200"
            )
            #expect(identity.name == "Markus Olsson")
            #expect(identity.email == "Markus Olsson")
        }

        @Test("parses even if the email address is broken")
        func parsesEvenIfTheEmailAddressIsBroken() throws {
            // https://github.com/git/git/blob/3ef7618e616e023cf04180e30d77c9fa5310f964/ident.c#L292-L296
            let identity = try CommitIdentity.parseIdentity(
                "Markus Olsson <Markus >Olsson> 1475670580 +0200"
            )
            #expect(identity.name == "Markus Olsson")
            #expect(identity.email == "Markus >Olsson")
        }
    }
}
