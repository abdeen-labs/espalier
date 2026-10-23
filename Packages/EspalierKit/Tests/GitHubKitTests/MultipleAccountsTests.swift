// Ported from desktop/app/test/unit/group-accounts-by-host-test.ts,
// clone-info-test.ts, and repository-matching-test.ts (the account probes).

import Foundation
@testable import GitHubKit
import Synchronization
import TestSupport
import Testing

private func account(_ login: String, endpoint: String = getDotComAPIEndpoint(), id: Int = 1) -> Account {
    Account(login: login, endpoint: endpoint, token: "\(login)-token", emails: [], avatarURL: "", id: id, name: login)
}

private func fullRepository(owner: String = "octocat", name: String = "hello") -> APIFullRepository {
    APIFullRepository(
        repository: createMockAPIRepository(name: name, owner: createMockAPIIdentity(login: owner)),
        parent: nil,
        permissions: APIRepositoryPermissions(admin: false, push: true, pull: true)
    )
}

/// A failure to check an account's access: neither a 404 nor an answer.
private struct AccessCheckFailed: Error {}

/// How a lookup answers for an account.
enum ProbeAnswer: Sendable {
    case visible, hidden, fails
}

/// A lookup answering by login, recording who was asked.
private final class AccessLookup: Sendable {
    private let answers: [String: ProbeAnswer]
    private let asked = Mutex<[String]>([])

    init(_ answers: [String: ProbeAnswer]) {
        self.answers = answers
    }

    var logins: [String] {
        asked.withLock { $0 }
    }

    var lookup: RepositoryAccessLookup {
        { account, owner, name in
            self.asked.withLock { $0.append(account.login) }
            switch self.answers[account.login] ?? .hidden {
            case .visible: return fullRepository(owner: owner, name: name)
            case .hidden: return nil
            case .fails: throw AccessCheckFailed()
            }
        }
    }
}

/// A chooser that records what it offered and answers with `answer`.
private final class RecordingChooser: Sendable {
    private let offers = Mutex<[[String]]>([])
    private let answer: @Sendable ([Account]) -> Account?

    init(_ answer: @escaping @Sendable ([Account]) -> Account?) {
        self.answer = answer
    }

    var offered: [[String]] {
        offers.withLock { $0 }
    }

    var choose: RemoteAccountChooser {
        { _, accounts in
            self.offers.withLock { $0.append(accounts.map(\.login)) }
            return self.answer(accounts)
        }
    }
}

@Suite("Multiple accounts", .offline)
struct MultipleAccountsTests {
    // MARK: Identity

    @Test("an account is its endpoint and login, ignoring case")
    func identity() {
        let identity = AccountIdentity(endpoint: "https://api.github.com", login: "Octocat")
        #expect(identity == AccountIdentity(endpoint: "https://API.github.com", login: "octocat"))
        #expect(identity != AccountIdentity(endpoint: "https://api.github.com", login: "monalisa"))
        #expect(identity != AccountIdentity(endpoint: "https://ghe.example.com/api/v3", login: "octocat"))
        #expect(Set([identity, AccountIdentity(endpoint: "https://api.github.com", login: "OCTOCAT")]).count == 1)
        #expect(isSameAccount(identity, account("octocat").identity))
        #expect(!isSameAccount(identity, nil))
    }

    // MARK: Grouping by host

    @Test("groups by web host, sorted alphabetically, keeping the accounts' order")
    func groupsByHost() {
        let zebraBob = account("bob", endpoint: "https://zebra.example.com/api/v3")
        let acme = account("carol", endpoint: "https://acme.example.com/api/v3")
        let zebraAlice = account("alice", endpoint: "https://zebra.example.com/api/v3")
        let ghe = account("dave", endpoint: "https://api.octo.ghe.com/")
        let acmePort = account("erin", endpoint: "https://acme.example.com:8443/api/v3")

        let groups = groupAccountsByHost([zebraBob, ghe, acmePort, acme, zebraAlice])

        #expect(groups == [
            AccountHostGroup(host: "acme.example.com", accounts: [acme]),
            AccountHostGroup(host: "acme.example.com:8443", accounts: [acmePort]),
            AccountHostGroup(host: "octo.ghe.com", accounts: [ghe]),
            AccountHostGroup(host: "zebra.example.com", accounts: [zebraBob, zebraAlice]),
        ])
    }

    @Test("pickers list GitHub.com's accounts first, then each Enterprise host's")
    func pickerGroups() {
        let enterprise = account("bob", endpoint: "https://a.example.com/api/v3")
        let first = account("first")
        let second = account("second", id: 2)

        let groups = groupAccountsForPicker([enterprise, first, second])

        #expect(groups.map(\.host) == ["github.com", "a.example.com"])
        #expect(groups.first?.accounts == [first, second])
        #expect(groupAccountsForPicker([enterprise]).map(\.host) == ["a.example.com"])
    }

    // MARK: Endpoints of remotes

    @Test("finds the endpoint a remote is on: a known one it matches, else its host's", arguments: [
        NamedCase("an SSH remote of a server whose site is on another port", (
            remote: "git@ghe.example.com:team/tool.git", candidates: ["https://ghe.example.com:8443/api/v3"], endpoint: "https://ghe.example.com:8443/api/v3"
        )),
        NamedCase("an HTTPS remote on another port than the known server's", (
            remote: "https://ghe.example.com/team/tool.git", candidates: ["https://ghe.example.com:8443/api/v3"], endpoint: "https://ghe.example.com/api/v3"
        )),
        NamedCase("an HTTPS remote on a port", (
            remote: "https://ghe.example.com:8443/team/tool.git", candidates: [], endpoint: "https://ghe.example.com:8443/api/v3"
        )),
        NamedCase("GitHub.com over SSH", (remote: "git@github.com:octocat/hello.git", candidates: [], endpoint: "https://api.github.com")),
        NamedCase("GitHub's SSH over HTTPS", (remote: "ssh://git@ssh.github.com:443/octocat/hello.git", candidates: [], endpoint: "https://api.github.com")),
    ])
    func endpointForRemote(_ testCase: NamedCase<(remote: String, candidates: [String], endpoint: String)>) throws {
        let remote = try #require(parseRemote(testCase.value.remote))
        #expect(getEndpointForRemote(remote, candidates: testCase.value.candidates) == testCase.value.endpoint)
    }

    @Test("an anonymous match is on the endpoint without a login")
    func anonymousMatch() {
        let match = toAnonymousMatch(endpoint: "https://ghe.example.com/api/v3", owner: "team", name: "tool")
        #expect(match.account.endpoint == "https://ghe.example.com/api/v3")
        #expect(match.account.login.isEmpty)
        #expect(match.account.token.isEmpty)
        #expect(match.owner == "team")
        #expect(match.name == "tool")
    }

    // MARK: Choosing an account for a remote

    @Test("assigns the only account that can see the repository, without asking")
    func onlyAccountWithAccess() async throws {
        let lookup = AccessLookup(["first": .hidden, "second": .visible])
        let chooser = RecordingChooser { _ in nil }

        let choice = try await chooseAccountForRemoteRepository(
            [account("first"), account("second", id: 2)],
            "https://github.com/octocat/hello.git",
            lookup: lookup.lookup,
            choose: chooser.choose
        )

        guard case .assigned(let assignment) = choice else {
            Issue.record("Expected an assignment, got \(choice)")
            return
        }
        #expect(assignment.account.login == "second")
        #expect(assignment.apiRepository?.name == "hello")
        #expect(chooser.offered.isEmpty)
        #expect(Set(lookup.logins) == ["first", "second"])
    }

    @Test("asks which account when several can see the repository")
    func severalWithAccess() async throws {
        let lookup = AccessLookup(["first": .visible, "second": .visible])
        let chooser = RecordingChooser { $0.last }

        let choice = try await chooseAccountForRemoteRepository(
            [account("first"), account("second", id: 2)],
            "https://github.com/octocat/hello.git",
            lookup: lookup.lookup,
            choose: chooser.choose
        )

        guard case .assigned(let assignment) = choice else {
            Issue.record("Expected an assignment, got \(choice)")
            return
        }
        #expect(assignment.account.login == "second")
        #expect(chooser.offered == [["first", "second"]])
    }

    @Test("an account whose access can't be checked is undecided: it's offered, never a reason to settle on another")
    func failedCheckIsUndecided() async throws {
        let lookup = AccessLookup(["first": .fails, "second": .visible])
        let chooser = RecordingChooser { accounts in accounts.first { $0.login == "second" } }

        let choice = try await chooseAccountForRemoteRepository(
            [account("first"), account("second", id: 2)],
            "https://github.com/octocat/hello.git",
            lookup: lookup.lookup,
            choose: chooser.choose
        )

        guard case .assigned(let assignment) = choice else {
            Issue.record("Expected an assignment, got \(choice)")
            return
        }
        #expect(assignment.account.login == "second")
        // Not assigned on its own: the first account might have access.
        #expect(chooser.offered == [["second", "first"]])
    }

    @Test("picking the undecided account checks it again before using it")
    func pickingUndecidedChecksAgain() async throws {
        let lookup = AccessLookup(["first": .fails, "second": .visible])
        let chooser = RecordingChooser { accounts in accounts.first { $0.login == "first" } }

        await #expect(throws: AccessCheckFailed.self) {
            _ = try await chooseAccountForRemoteRepository(
                [account("first"), account("second", id: 2)],
                "https://github.com/octocat/hello.git",
                lookup: lookup.lookup,
                choose: chooser.choose
            )
        }
        #expect(lookup.logins.filter { $0 == "first" }.count == 2)
    }

    @Test("no account that can see it is no access; failed checks alone are undecided, and nothing is asked", arguments: [
        NamedCase("each account answered 404", (answers: ["first": ProbeAnswer.hidden, "second": .hidden], undecided: false)),
        NamedCase("an account couldn't be checked", (answers: ["first": .hidden, "second": .fails], undecided: true)),
    ])
    func noAccountWithAccess(_ testCase: NamedCase<(answers: [String: ProbeAnswer], undecided: Bool)>) async throws {
        let lookup = AccessLookup(testCase.value.answers)
        let chooser = RecordingChooser { $0.first }

        let choice = try await chooseAccountForRemoteRepository(
            [account("first"), account("second", id: 2)],
            "https://github.com/octocat/hello.git",
            lookup: lookup.lookup,
            choose: chooser.choose
        )

        switch choice {
        case .noAccess: #expect(!testCase.value.undecided)
        case .undecided: #expect(testCase.value.undecided)
        default: Issue.record("Expected no account, got \(choice)")
        }
        #expect(chooser.offered.isEmpty)
    }

    @Test("checks an account signed in from the chooser before accepting it")
    func signedInFromChooser() async throws {
        let signedIn = account("third", id: 3)
        let lookup = AccessLookup(["first": .visible, "second": .visible, "third": .visible])
        let chooser = RecordingChooser { _ in signedIn }

        let choice = try await chooseAccountForRemoteRepository(
            [account("first"), account("second", id: 2)],
            "https://github.com/octocat/hello.git",
            lookup: lookup.lookup,
            choose: chooser.choose
        )

        guard case .assigned(let assignment) = choice else {
            Issue.record("Expected an assignment, got \(choice)")
            return
        }
        #expect(assignment.account.login == "third")
        #expect(assignment.apiRepository != nil)
        #expect(lookup.logins.contains("third"))
    }

    @Test("refuses an account signed in from the chooser that can't see the repository")
    func signedInFromChooserWithoutAccess() async throws {
        let lookup = AccessLookup(["first": .visible, "second": .visible, "third": .hidden])
        let chooser = RecordingChooser { _ in account("third", id: 3) }

        await #expect(throws: GitHubError.self) {
            _ = try await chooseAccountForRemoteRepository(
                [account("first"), account("second", id: 2)],
                "https://github.com/octocat/hello.git",
                lookup: lookup.lookup,
                choose: chooser.choose
            )
        }
    }

    @Test("asks only the accounts on the remote's server, and a cancelled choice is cancelled")
    func onlyAccountsOnTheServer() async throws {
        let lookup = AccessLookup(["first": .visible, "second": .visible, "enterprise": .visible])
        let chooser = RecordingChooser { _ in nil }

        let choice = try await chooseAccountForRemoteRepository(
            [account("first"), account("enterprise", endpoint: "https://ghe.example.com/api/v3", id: 3), account("second", id: 2)],
            "git@github.com:octocat/hello.git",
            lookup: lookup.lookup,
            choose: chooser.choose
        )

        guard case .cancelled = choice else {
            Issue.record("Expected cancelled, got \(choice)")
            return
        }
        #expect(!lookup.logins.contains("enterprise"))
        #expect(chooser.offered == [["first", "second"]])
    }

    @Test("checks a wiki's access through its repository, without the API's repository")
    func wiki() async throws {
        let asked = Mutex<[String]>([])
        let lookup: RepositoryAccessLookup = { _, owner, name in
            asked.withLock { $0.append("\(owner)/\(name)") }
            return fullRepository(owner: owner, name: name)
        }

        let assignment = try await probeRemoteRepositoryAccount(account("first"), "https://github.com/octocat/hello.wiki.git", lookup: lookup)

        #expect(asked.withLock { $0 } == ["octocat/hello"])
        #expect(assignment?.match.name == "hello.wiki")
        #expect(assignment?.apiRepository == nil)
    }

    // MARK: What a URL clones

    /// A clone info lookup answering by login, recording who was asked.
    private final class CloneLookup: Sendable {
        private let answers: [String: ProbeAnswer]
        private let asked = Mutex<[(login: String, gitProtocol: GitProtocol?)]>([])

        init(_ answers: [String: ProbeAnswer]) {
            self.answers = answers
        }

        var logins: [String] {
            asked.withLock { $0.map(\.login) }
        }

        var protocols: [GitProtocol?] {
            asked.withLock { $0.map(\.gitProtocol) }
        }

        var lookup: CloneInfoLookup {
            { account, owner, name, gitProtocol in
                self.asked.withLock { $0.append((account.login, gitProtocol)) }
                switch self.answers[account.login] ?? .hidden {
                case .visible:
                    let url = gitProtocol == .ssh ? "git@github.com:\(owner)/\(name).git" : "https://github.com/\(owner)/\(name).git"
                    return APIRepositoryCloneInfo(url: url, defaultBranch: "main")
                case .hidden: return nil
                case .fails: throw AccessCheckFailed()
                }
            }
        }
    }

    private func resolve(_ url: String, _ accounts: [Account], _ lookup: CloneLookup) async throws -> URLCloneInfoResolution {
        await resolveURLCloneInfo(try #require(parseRemote(url)), url: url, accounts: accounts, lookup: lookup.lookup)
    }

    @Test("tries each account on the URL's host in order, so the second account finds what the first can't see")
    func triesEachAccount() async throws {
        let lookup = CloneLookup(["first": .hidden, "second": .visible])

        let resolution = try await resolve(
            "https://github.com/octocat/private.git",
            [account("first"), account("enterprise", endpoint: "https://ghe.example.com/api/v3", id: 3), account("second", id: 2)],
            lookup
        )

        #expect(resolution == .clone(APIRepositoryCloneInfo(url: "https://github.com/octocat/private.git", defaultBranch: "main")))
        #expect(lookup.logins == ["first", "second"])
    }

    @Test("keeps an SSH URL's protocol")
    func keepsSSH() async throws {
        let lookup = CloneLookup(["first": .visible])

        let resolution = try await resolve("git@github.com:octocat/hello.git", [account("first")], lookup)

        #expect(resolution == .clone(APIRepositoryCloneInfo(url: "git@github.com:octocat/hello.git", defaultBranch: "main")))
        #expect(lookup.protocols == [.ssh])
    }

    @Test("falls back to GitHub.com without signing in")
    func anonymous() async throws {
        let lookup = CloneLookup(["": .visible])

        let resolution = try await resolve("https://github.com/octocat/hello", [account("first")], lookup)

        #expect(resolution == .clone(APIRepositoryCloneInfo(url: "https://github.com/octocat/hello.git", defaultBranch: "main")))
        #expect(lookup.logins == ["first", ""])
    }

    @Test("an SSH URL nothing can see is cloned as typed; an HTTPS one isn't found", arguments: [
        NamedCase("SSH", (url: "git@github.com:octocat/hidden.git", found: true)),
        NamedCase("HTTPS", (url: "https://github.com/octocat/hidden.git", found: false)),
    ])
    func nothingCanSeeIt(_ testCase: NamedCase<(url: String, found: Bool)>) async throws {
        let lookup = CloneLookup([:])

        let resolution = try await resolve(testCase.value.url, [account("first")], lookup)

        #expect(resolution == (testCase.value.found ? .clone(APIRepositoryCloneInfo(url: testCase.value.url)) : .notFound))
    }

    @Test("a lookup that fails clones the URL as typed, after asking the others")
    func lookupFails() async throws {
        let lookup = CloneLookup(["first": .fails, "second": .hidden])

        let resolution = try await resolve("https://github.com/octocat/hello.git", [account("first"), account("second", id: 2)], lookup)

        #expect(resolution == .clone(APIRepositoryCloneInfo(url: "https://github.com/octocat/hello.git")))
        #expect(lookup.logins == ["first", "second", ""])
    }

    @Test("a URL on a host without an account is cloned as typed, asking nobody")
    func otherHost() async throws {
        let lookup = CloneLookup(["first": .visible])

        let resolution = try await resolve("https://gitlab.com/octocat/hello.git", [account("first")], lookup)

        #expect(resolution == .clone(APIRepositoryCloneInfo(url: "https://gitlab.com/octocat/hello.git")))
        #expect(lookup.logins.isEmpty)
    }
}
