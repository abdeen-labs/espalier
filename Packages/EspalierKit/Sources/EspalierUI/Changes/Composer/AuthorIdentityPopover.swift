// The author's avatar at the end of the commit message card's footer, and
// its popover: who the commit is by, and a warning when the email won't
// link the commit to the GitHub account, or when the branch's rules don't
// allow it.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// Who the next commit is by, as the composer shows it.
nonisolated public struct AuthorIdentityContent: Sendable, Equatable {
    /// Why the commit's author needs attention.
    public enum Warning: Sendable, Equatable {
        /// The email isn't one of the account's, so GitHub won't link the
        /// commit to it.
        case misattributed(isEnterprise: Bool)
        /// The branch's rules don't allow the email.
        case disallowedEmail(ruleCount: Int, canBypass: Bool)
    }

    /// Git's `user.name`, or nil without an identity.
    public var name: String?
    /// Git's `user.email`.
    public var email: String?
    /// The repository's GitHub endpoint, for the avatar.
    public var endpoint: String?
    public var warning: Warning?
    /// With a warning, the addresses of the repository's account that the
    /// global email can be set to (its verified addresses, and GitHub.com's
    /// private one); empty otherwise.
    public var accountEmails: [String]
    /// The address the pop-up starts on, one of `accountEmails`.
    public var preferredAccountEmail: String?

    public init(
        name: String?,
        email: String?,
        endpoint: String? = nil,
        warning: Warning? = nil,
        accountEmails: [String] = [],
        preferredAccountEmail: String? = nil
    ) {
        self.name = name
        self.email = email
        self.endpoint = endpoint
        self.warning = warning
        self.accountEmails = accountEmails
        self.preferredAccountEmail = preferredAccountEmail
    }

    /// The avatar's user, when there's an identity.
    public var avatarUser: AvatarUser? {
        guard let email else {
            return nil
        }
        return AvatarUser(email: email, avatarURL: nil, name: name ?? email, endpoint: endpoint)
    }

    /// The popover's title.
    public var title: String {
        if let name, !name.isEmpty {
            return "Committing as \(name)"
        }
        if let email {
            return "Committing with \(email)"
        }
        return "No Author Set"
    }

    /// What the warning says.
    public var warningText: String? {
        switch warning {
        case .misattributed(let isEnterprise)?:
            "This email address doesn't match your GitHub\(isEnterprise ? " Enterprise" : "") account. Your commits won't be attributed to you."
        case .disallowedEmail(let count, let canBypass)?:
            "This email address fails \(count == 1 ? "1 rule" : "\(count) rules") for commits on this branch"
                + (canBypass ? ", but you can bypass \(count == 1 ? "it" : "them")." : ".")
        case nil:
            nil
        }
    }

    /// What VoiceOver says for the avatar button.
    public var accessibilityLabel: String {
        switch warning {
        case .misattributed?: "Commit author: the commit may not be attributed to you"
        case .disallowedEmail?: "Commit author: the email address isn't allowed"
        case nil: "Commit author"
        }
    }
}

extension AuthorIdentityContent {
    /// The author for a repository: git's identity, checked against the
    /// branch's author email rules first, then against the account the
    /// repository uses.
    @MainActor
    public static func make(_ repository: RepositoryModel, app: AppModel) -> AuthorIdentityContent {
        guard let identity = repository.gitState.commitAuthor else {
            return AuthorIdentityContent(name: nil, email: nil)
        }
        var content = AuthorIdentityContent(
            name: identity.name,
            email: identity.email,
            endpoint: repository.record.gitHubRepository?.endpoint
        )
        let account = app.accounts.account(for: repository.record)
        // The branch's author email rules.
        let failures = repository.gitHub.commitAuthorRuleFailures
        if failures.status != .pass {
            content.warning = .disallowedEmail(
                ruleCount: failures.failed.count + failures.bypassed.count,
                canBypass: failures.status == .bypass
            )
        } else if let account, !isAttributableEmailFor(account, identity.email) {
            content.warning = .misattributed(isEnterprise: isEnterpriseAccount(account))
        }
        if content.warning != nil, let account {
            content.offerAccountEmails(of: account)
        }
        return content
    }

    /// Offers `account`'s addresses for the global email, starting on its
    /// preferred one, or the first when that isn't offered.
    mutating func offerAccountEmails(of account: Account) {
        accountEmails = gitAuthorEmailChoices(for: [account]).map(\.email)
        let preferred = lookupPreferredEmail(account).lowercased()
        preferredAccountEmail = accountEmails.first { $0.lowercased() == preferred } ?? accountEmails.first
    }
}

/// The author's avatar, a button that shows who the commit is by.
public struct AuthorAvatarButton: View {
    private let content: AuthorIdentityContent
    private let canOpenRepositorySettings: Bool
    private let onOpenGitSettings: () -> Void
    private let onOpenRepositorySettings: () -> Void
    private let onUpdateEmail: (String) -> Void
    @State private var isShowingPopover = false

    public init(
        _ content: AuthorIdentityContent,
        canOpenRepositorySettings: Bool = true,
        onOpenGitSettings: @escaping () -> Void = {},
        onOpenRepositorySettings: @escaping () -> Void = {},
        onUpdateEmail: @escaping (String) -> Void = { _ in }
    ) {
        self.content = content
        self.canOpenRepositorySettings = canOpenRepositorySettings
        self.onOpenGitSettings = onOpenGitSettings
        self.onOpenRepositorySettings = onOpenRepositorySettings
        self.onUpdateEmail = onUpdateEmail
    }

    public var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            AuthorAvatar(content, size: Metrics.Composer.avatarSize)
        }
        .buttonStyle(.bare(.circle))
        .tooltip(content.title)
        .accessibilityLabel(content.accessibilityLabel)
        .popoverCard(isPresented: $isShowingPopover, title: content.title) {
            AuthorIdentityPopover(
                content,
                canOpenRepositorySettings: canOpenRepositorySettings,
                onOpenGitSettings: {
                    isShowingPopover = false
                    onOpenGitSettings()
                },
                onOpenRepositorySettings: {
                    isShowingPopover = false
                    onOpenRepositorySettings()
                },
                onUpdateEmail: { email in
                    isShowingPopover = false
                    onUpdateEmail(email)
                }
            )
        }
    }
}

/// The avatar, or a person symbol without an identity, with a warning badge.
struct AuthorAvatar: View {
    let content: AuthorIdentityContent
    let size: CGFloat

    init(_ content: AuthorIdentityContent, size: CGFloat) {
        self.content = content
        self.size = size
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let user = content.avatarUser {
                Avatar(user, size: size)
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
            if content.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(Typography.tinyCount)
                    .offset(x: Metrics.grid, y: Metrics.grid)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Who the commit is by, any warning, and where to change it: with a
/// warning, the account's addresses and Update Email, which sets the global
/// email.
public struct AuthorIdentityPopover: View {
    private let content: AuthorIdentityContent
    private let canOpenRepositorySettings: Bool
    private let onOpenGitSettings: () -> Void
    private let onOpenRepositorySettings: () -> Void
    private let onUpdateEmail: (String) -> Void
    @State private var accountEmail: String

    public init(
        _ content: AuthorIdentityContent,
        canOpenRepositorySettings: Bool = true,
        onOpenGitSettings: @escaping () -> Void = {},
        onOpenRepositorySettings: @escaping () -> Void = {},
        onUpdateEmail: @escaping (String) -> Void = { _ in }
    ) {
        self.content = content
        self.canOpenRepositorySettings = canOpenRepositorySettings
        self.onOpenGitSettings = onOpenGitSettings
        self.onOpenRepositorySettings = onOpenRepositorySettings
        self.onUpdateEmail = onUpdateEmail
        _accountEmail = State(initialValue: content.preferredAccountEmail ?? content.accountEmails.first ?? "")
    }

    /// The pop-up's label.
    static let accountEmailsLabel = "Your Account Emails"
    /// Update Email's tooltip.
    static let updateEmailHelp = "Use this address as the email in your global Git config"

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            HStack(spacing: Metrics.insetSmall) {
                AuthorAvatar(content, size: Metrics.Composer.avatarSize * 2)
                VStack(alignment: .leading, spacing: Metrics.grid / 2) {
                    Text(content.title)
                        .font(Typography.heading)
                    if let email = content.email {
                        SelectableText(email, font: AppKitTypography.secondary, color: .secondaryLabelColor)
                    } else {
                        Text("Set your name and email in Git settings.")
                            .font(Typography.secondary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let warning = content.warningText {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(espalier: Palette.warning))
                        .accessibilityLabel("Warning")
                    Text(warning)
                        .font(Typography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !content.accountEmails.isEmpty {
                    accountEmails
                }
            }
            HStack(spacing: Metrics.insetSmall) {
                Spacer(minLength: 0)
                Button("Repository Settings…", action: onOpenRepositorySettings)
                    .disabled(!canOpenRepositorySettings)
                Button("Git Settings…", action: onOpenGitSettings)
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
        }
        .padding(Metrics.insetLarge)
        .frame(width: Metrics.Composer.popoverWidth, alignment: .leading)
    }

    /// The account's addresses, and Update Email.
    private var accountEmails: some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            Text(Self.accountEmailsLabel)
                .font(Typography.secondary)
                .foregroundStyle(.secondary)
            // The whole width: a private address is long.
            CapsulePopUp(Self.accountEmailsLabel, selection: $accountEmail, title: accountEmail) {
                for email in content.accountEmails {
                    MenuChoice(email, value: email)
                }
            }
            .frame(maxWidth: .infinity)
            HStack {
                Spacer(minLength: 0)
                Button("Update Email") {
                    onUpdateEmail(accountEmail)
                }
                .buttonStyle(.prominent)
                .controlSize(.small)
                .disabled(accountEmail.isEmpty)
                .tooltip(Self.updateEmailHelp)
            }
        }
    }
}
