// Ported from desktop/app/test/unit/email-test.ts

@testable import GitHubKit
import Testing

private func makeAccount(
    _ login: String,
    _ endpoint: String,
    _ emails: [APIEmail],
    _ id: Int,
    _ name: String
) -> Account {
    Account(login: login, endpoint: endpoint, token: "", emails: emails, avatarURL: "", id: id, name: name, plan: "free")
}

@Suite("emails")
struct EmailTests {
    @Suite("lookupPreferredEmail")
    struct LookupPreferredEmail {
        @Test("returns a stealth email address for empty list")
        func stealthForEmptyList() {
            let account = makeAccount("shiftkey", getDotComAPIEndpoint(), [], 1234, "Caps Lock")

            #expect(lookupPreferredEmail(account) == "1234+shiftkey@users.noreply.github.com")
        }

        @Test("returns a stealth email address for empty list from GHES")
        func stealthForEmptyListFromGHES() {
            let account = makeAccount("shiftkey", "https://github.example.com/api/v3", [], 1234, "Caps Lock")

            #expect(lookupPreferredEmail(account) == "1234+shiftkey@users.noreply.github.example.com")
        }

        @Test("returns the primary if it has public visibility")
        func primaryWithPublicVisibility() {
            let emails = [
                APIEmail(email: "shiftkey@example.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "shiftkey@users.noreply.github.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "my-primary-email@example.com", verified: true, primary: true, visibility: .public),
            ]

            let account = makeAccount("shiftkey", getDotComAPIEndpoint(), emails, -1, "Caps Lock")

            #expect(lookupPreferredEmail(account) == "my-primary-email@example.com")
        }

        @Test("returns the primary if it has null visibility")
        func primaryWithNullVisibility() {
            let emails = [
                APIEmail(email: "shiftkey@example.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "shiftkey@users.noreply.github.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "my-primary-email@example.com", verified: true, primary: true, visibility: nil),
            ]

            let account = makeAccount("shiftkey", getDotComAPIEndpoint(), emails, -1, "Caps Lock")

            #expect(lookupPreferredEmail(account) == "my-primary-email@example.com")
        }

        @Test("returns the noreply if there is no public address")
        func noReplyWithoutPublicAddress() {
            let emails = [
                APIEmail(email: "shiftkey@example.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "shiftkey@users.noreply.github.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "my-primary-email@example.com", verified: true, primary: true, visibility: .private),
            ]

            let account = makeAccount("shiftkey", getDotComAPIEndpoint(), emails, -1, "Caps Lock")

            #expect(lookupPreferredEmail(account) == "shiftkey@users.noreply.github.com")
        }

        @Test("returns the noreply if there is no public address for GitHub Enterprise as well")
        func noReplyWithoutPublicAddressForEnterprise() {
            let emails = [
                APIEmail(email: "shiftkey@example.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "shiftkey@users.noreply.github.example.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "my-primary-email@example.com", verified: true, primary: true, visibility: .private),
            ]

            let account = makeAccount("shiftkey", getEnterpriseAPIURL("https://github.example.com"), emails, -1, "Caps Lock")

            #expect(lookupPreferredEmail(account) == "shiftkey@users.noreply.github.example.com")
        }

        @Test("uses first email if nothing special found")
        func usesFirstEmail() {
            let emails = [
                APIEmail(email: "shiftkey@example.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "github-primary@example.com", verified: true, primary: false, visibility: nil),
            ]

            let account = makeAccount("shiftkey", getDotComAPIEndpoint(), emails, -1, "Caps Lock")

            #expect(lookupPreferredEmail(account) == "shiftkey@example.com")
        }
    }

    @Suite("isAttributableEmailFor")
    struct IsAttributableEmailFor {
        @Test("considers all email addresses on the account as well as legacy and modern stealth emails")
        func considersAllEmails() {
            let emails = [
                APIEmail(email: "personal@gmail.com", verified: true, primary: true, visibility: .public),
                APIEmail(email: "company@github.com", verified: true, primary: false, visibility: nil),
                APIEmail(email: "niik@users.noreply.github.com", verified: true, primary: false, visibility: nil),
            ]

            let endpoint = getDotComAPIEndpoint()
            let account = makeAccount("niik", endpoint, emails, 123, "")

            #expect(isAttributableEmailFor(account, "personal@gmail.com"))
            #expect(isAttributableEmailFor(account, "company@github.com"))
            #expect(isAttributableEmailFor(account, "niik@users.noreply.github.com") == true)
            #expect(isAttributableEmailFor(account, "123+niik@users.noreply.github.com") == true)
        }

        @Test("considers stealth emails for GitHub Enterprise")
        func considersStealthEmailsForEnterprise() {
            let endpoint = "https://github.example.com/api/v3"
            let account = makeAccount("niik", endpoint, [], 123, "")

            #expect(isAttributableEmailFor(account, "niik@users.noreply.github.example.com") == true)
            #expect(isAttributableEmailFor(account, "123+niik@users.noreply.github.example.com") == true)
            #expect(isAttributableEmailFor(account, "niik@users.noreply.github.com") == false)
        }

        @Test("considers email adresses in a case-insensitive manner")
        func considersEmailsCaseInsensitively() {
            let account = makeAccount(
                "niik",
                getDotComAPIEndpoint(),
                [APIEmail(email: "niik@GITHUB.COM", verified: true, primary: true, visibility: .public)],
                123,
                ""
            )

            #expect(isAttributableEmailFor(account, "niik@github.com"))
            #expect(isAttributableEmailFor(account, "niik@users.noreply.github.com") == true)
            #expect(isAttributableEmailFor(account, "123+niik@users.noreply.github.com") == true)
        }
    }
}
