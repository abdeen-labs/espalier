// The device-flow sign-in sheet, on `SignInModel`: the Enterprise address,
// the existing account, git's request ("Git is asking for credentials to
// access <url>.") with its confirmation for an Enterprise Server the user
// hasn't signed in to, and the errors.
//
// The steps: an Enterprise address and OAuth app (EnterpriseAddressStep),
// the note about the account a sign-in replaces, then the code with Copy
// Code and the server's verification page (pressing it also copies the
// code), "Waiting for you to authorize Espalier…" and the time left, inline
// errors with Get a New Code or Try Again, and "Signed in as @login" for a
// second. Whoever showed the sheet gets the account (git's prompt answers
// with it; a recovery runs its operation again), or nil when it's
// cancelled.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// Why the sign-in sheet shows, and for which server.
nonisolated public struct SignInRequest: Sendable, Equatable {
    /// Why it shows.
    public enum Reason: Sendable, Equatable {
        /// Settings ▸ Accounts, Welcome, or a call to action.
        case user
        /// Git asked for credentials for a URL (the `gitHubSignIn` prompt).
        case gitRequestedCredentials(url: String)
        /// A recovery (SAML, the workflow scope, an invalidated token).
        case recovery
    }

    /// The endpoint that asks for a GitHub Enterprise address: Add GitHub
    /// Enterprise Account…, Welcome's Sign In to GitHub Enterprise….
    public static let enterpriseEndpoint = ""

    /// The API endpoint, nil for GitHub.com, or `enterpriseEndpoint` to ask
    /// for an Enterprise server's address. For git's request, the URL git
    /// asked about.
    public var endpoint: String?
    public var reason: Reason

    public init(endpoint: String?, reason: Reason = .user) {
        self.endpoint = endpoint
        self.reason = reason
    }

    /// The sheet's header for git's prompt.
    public var header: String? {
        if case .gitRequestedCredentials(let url) = reason {
            return "Git is asking for credentials to access \(url)."
        }
        return nil
    }

    /// Whether the sign-in is to an Enterprise server, as far as the request
    /// says.
    var isEnterprise: Bool {
        switch reason {
        case .gitRequestedCredentials(let url):
            return (try? JSURL(url))?.hostname != "github.com"
        case .user, .recovery:
            guard let endpoint else {
                return false
            }
            return endpoint == Self.enterpriseEndpoint || !isDotCom(endpoint)
        }
    }
}

extension ActionID {
    /// Signs in to a GitHub Enterprise server, asking for its address.
    nonisolated public static var signInToEnterprise: ActionID {
        .signIn(endpoint: SignInRequest.enterpriseEndpoint, then: nil)
    }
}

// MARK: Content

/// What the sign-in sheet shows.
nonisolated struct SignInContent: Sendable, Equatable {
    /// The step.
    enum Step: Sendable, Equatable {
        /// The Enterprise server's address and OAuth app.
        case address(EnterpriseAddressContent)
        /// An account is signed in to the server; signing in replaces it.
        case existingAccount(host: String, login: String, error: String?, isBusy: Bool)
        /// Git asked to sign in to an Enterprise Server the user hasn't
        /// signed in to.
        case confirmServer(address: String)
        /// Ready to ask for a code (git's sign-in waits for the user).
        case ready
        /// Asking the server for a code.
        case requestingCode
        /// The code to enter, while waiting for the user.
        case code(SignInCodeContent)
        /// The last step failed.
        case failed(message: String, retryTitle: String)
        /// Signed in.
        case success(login: String, avatar: AvatarUser)

        /// Which step, without what it shows: moving to another one
        /// crossfades.
        var kind: Int {
            switch self {
            case .address: 0
            case .existingAccount: 1
            case .confirmServer: 2
            case .ready: 3
            case .requestingCode: 4
            case .code: 5
            case .failed: 6
            case .success: 7
            }
        }
    }

    /// "Sign In to GitHub.com", "Sign In to GitHub Enterprise".
    var title: String
    /// Git's request, when git asked.
    var header: String?
    var step: Step
}

/// The code step's content.
nonisolated struct SignInCodeContent: Sendable, Equatable {
    var userCode: String
    /// The page to enter it on.
    var verificationURL: URL?
    /// The page's address without its scheme: `github.com/login/device`.
    var verificationLabel: String
    var expiresAt: Date

    init(_ code: SignInCode) {
        userCode = code.userCode
        verificationURL = URL(string: code.verificationURI)
        verificationLabel = code.verificationURI.replacing(/^https?:\/\//, with: "")
        expiresAt = code.expiresAt
    }

    /// The time left, "14:52"; nil once the code has expired.
    func timeLeft(now: Date) -> String? {
        let seconds = Int(expiresAt.timeIntervalSince(now).rounded(.down))
        guard seconds > 0 else {
            return nil
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The Enterprise address step's content.
nonisolated struct EnterpriseAddressContent: Sendable, Equatable {
    var address: String
    var clientID: String
    var error: String?
    /// Whether the address is being checked.
    var isChecking: Bool
}

extension SignInContent {
    /// The content for the sign-in model's state.
    ///
    /// - Parameters:
    ///   - state: The model's state; nil before the sign-in starts.
    ///   - request: Why the sheet shows.
    ///   - accounts: The signed-in accounts, for the success step's avatar.
    init(state: SignInState?, request: SignInRequest) {
        let isEnterprise = state.map { state -> Bool in
            if case .endpointEntry = state {
                return true
            }
            return state.endpoint.map { !isDotCom($0) } ?? request.isEnterprise
        } ?? request.isEnterprise
        title = isEnterprise ? "Sign In to GitHub Enterprise" : "Sign In to GitHub.com"
        header = request.header

        switch state {
        case nil:
            // Before the sign-in starts: git's request waits for the user;
            // the others ask for a code at once.
            step = request.header == nil ? .requestingCode : .ready
        case .endpointEntry(let entry)?:
            step = .address(EnterpriseAddressContent(
                address: entry.address,
                clientID: entry.clientID,
                error: entry.error?.message,
                isChecking: entry.loading
            ))
        case .existingAccountWarning(let warning)?:
            step = .existingAccount(
                host: Self.host(warning.configuration.endpoint),
                login: warning.existingAccount.login,
                error: warning.error?.message,
                isBusy: warning.loading
            )
        case .authentication(let authentication)?:
            if let error = authentication.error {
                step = .failed(message: error.message, retryTitle: error == .codeExpired ? "Get a New Code" : "Try Again")
            } else if let code = authentication.code {
                step = .code(SignInCodeContent(code))
            } else if authentication.loading {
                step = .requestingCode
            } else if authentication.isUnrecognizedEnterpriseServer {
                step = .confirmServer(address: getHTMLURL(authentication.configuration.endpoint))
            } else {
                step = .ready
            }
        case .success(let success)?:
            let account = success.account
            step = .success(login: account.login, avatar: AvatarUser(
                email: lookupPreferredEmail(account),
                avatarURL: account.avatarURL.isEmpty ? nil : account.avatarURL,
                name: account.name,
                endpoint: account.endpoint
            ))
        }
    }

    /// The host to name: `github.com`, `ghe.example.com`.
    static func host(_ endpoint: String) -> String {
        (try? JSURL(getHTMLURL(endpoint)))?.host ?? endpoint
    }
}

// MARK: The sheet

extension EnvironmentValues {
    /// How long "Signed in as @login" shows before the sheet closes (tests
    /// shorten it).
    @Entry var signInSuccessDuration: Duration = .seconds(1)
}

/// Sign in with the device flow. `onFinish` gets the account, or nil when
/// the user cancelled.
public struct SignInSheet: View {
    /// The sheet's id when GitHub's actions show it.
    public static let sheetID = "espalier.github.signIn"

    private let request: SignInRequest
    private let onFinish: (Account?) -> Void
    @Environment(WindowContext.self) private var context: WindowContext?
    @Environment(\.dismissModal) private var dismissModal
    @Environment(\.signInSuccessDuration) private var successDuration
    @State private var session = SignInSession()

    public init(request: SignInRequest, onFinish: @escaping (Account?) -> Void) {
        self.request = request
        self.onFinish = onFinish
    }

    public var body: some View {
        if let signIn = context?.app.accounts.signIn {
            sheet(signIn)
        } else {
            // No window to sign in from (a snapshot of git's prompt): the
            // first step, and Cancel.
            SignInView(content: SignInContent(state: nil, request: request), actions: SignInActions(
                cancel: { finish(nil) },
                continueSignIn: {},
                submitAddress: { _, _ in },
                copyCode: { _ in },
                openVerificationPage: { _ in }
            ))
        }
    }

    private func sheet(_ signIn: SignInModel) -> some View {
        SignInView(
            content: SignInContent(state: session.isStarted ? signIn.state : nil, request: request),
            actions: SignInActions(
                cancel: { signIn.reset() },
                continueSignIn: { Task { await signIn.authenticate() } },
                submitAddress: { address, clientID in
                    Task {
                        await signIn.setEndpoint(address, clientID: clientID)
                        await Self.requestCodeIfReady(signIn, request: request)
                    }
                },
                copyCode: { code in Self.copy(code) },
                openVerificationPage: { code in
                    Self.copy(code)
                    signIn.openVerificationPage()
                }
            )
        )
        .task {
            await start(signIn)
        }
        .onDisappear {
            // Closed another way (the prompt git waited on went away): the
            // sign-in stops.
            if !session.isFinished {
                signIn.reset()
            }
        }
    }

    /// Starts the sign-in the request asks for.
    private func start(_ signIn: SignInModel) async {
        guard !session.isStarted else {
            return
        }
        session.isStarted = true
        await Self.begin(request, signIn: signIn) { result in
            switch result {
            case .success(let account):
                Task {
                    try? await Task.sleep(for: successDuration)
                    finish(account)
                }
            case .cancelled:
                finish(nil)
            }
        }
    }

    /// Begins the sign-in `request` asks for on `signIn`, reporting how it
    /// ends to `callback`: git's request waits for the user; GitHub.com's
    /// shows a code at once (after the note about an account it replaces);
    /// a new Enterprise account asks for the server; a known server (a
    /// recovery, Sign In Again) asks for a code at once.
    static func begin(_ request: SignInRequest, signIn: SignInModel, callback: @escaping @MainActor (SignInResult) -> Void) async {
        switch request.reason {
        case .gitRequestedCredentials(let url):
            await signIn.begin(gitCredentialURL: url, callback)
        case .user, .recovery:
            switch request.endpoint {
            case nil:
                signIn.beginDotComSignIn(callback)
                await requestCodeIfReady(signIn, request: request)
            case SignInRequest.enterpriseEndpoint?:
                signIn.beginEnterpriseSignIn(callback)
            case let endpoint?:
                await signIn.beginSignIn(endpoint: endpoint, callback)
            }
        }
    }

    /// Asks for a code once the sign-in is ready for one: the user asked to
    /// sign in, so the code shows at once. Git's request and an Enterprise
    /// Server to confirm wait for the user.
    static func requestCodeIfReady(_ signIn: SignInModel, request: SignInRequest) async {
        guard case .authentication(let authentication)? = signIn.state, authentication.code == nil, !authentication.loading,
              authentication.error == nil, !authentication.isUnrecognizedEnterpriseServer, request.header == nil
        else {
            return
        }
        await signIn.authenticate()
    }

    private func finish(_ account: Account?) {
        guard !session.isFinished else {
            return
        }
        session.isFinished = true
        // Whoever showed the sheet answers first (git's prompt host closes
        // its own sheet with the answer).
        onFinish(account)
        dismissModal()
    }

    private static func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    /// Whether the sheet's sign-in started and finished. Observable: the
    /// body shows the sign-in's state only once it started.
    @Observable fileprivate final class SignInSession {
        var isStarted = false
        var isFinished = false
    }
}

/// What the sign-in sheet's buttons do.
struct SignInActions {
    var cancel: () -> Void
    /// Asks for a code (Continue, Try Again, Get a New Code).
    var continueSignIn: () -> Void
    var submitAddress: (_ address: String, _ clientID: String) -> Void
    var copyCode: (String) -> Void
    var openVerificationPage: (String) -> Void

    static let none = SignInActions(cancel: {}, continueSignIn: {}, submitAddress: { _, _ in }, copyCode: { _ in }, openVerificationPage: { _ in })
}

/// The sheet's content for a step.
struct SignInView: View {
    let content: SignInContent
    let actions: SignInActions

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Sheet.spacing) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.titleSpacing) {
                Text(content.title)
                    .font(Typography.sheetTitle)
                    .foregroundStyle(.text)
                    .accessibilityAddTraits(.isHeader)
                if let header = content.header {
                    Text(header)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            // One step crossfades into the next over 0.22 s, as the
            // welcome flow's do.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Metrics.Sheet.spacing) {
                    step
                }
                .id(content.step.kind)
                .transition(.opacity)
            }
            .motion(Motion.arrive, value: content.step.kind)
        }
        .padding(Metrics.Sheet.padding)
        .frame(width: Metrics.Sheet.standardWidth, alignment: .leading)
        .background(Color(espalier: Palette.background))
    }

    @ViewBuilder
    private var step: some View {
        switch content.step {
        case .address(let address):
            EnterpriseAddressStep(content: address, cancel: actions.cancel, submit: actions.submitAddress)

        case .existingAccount(let host, let login, let error, let isBusy):
            Text("You're already signed in to \(host) with the account \(login). If you sign in with another account, it replaces \(login).")
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                SignInInlineError(message: error)
            }
            buttons {
                Button("Continue", action: actions.continueSignIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }

        case .confirmServer(let address):
            Text("Git is requesting permission to sign in to this server:")
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
            MonoChip(address, isSelectable: true)
            Label {
                Text("**Only continue if you recognize and trust this server.** Confirm this address appears in your browser. Otherwise, cancel and contact your repository administrator.")
                    .foregroundStyle(.text2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                WarningGlyph()
            }
            .font(Typography.secondary)
            buttons {
                Button("Continue", action: actions.continueSignIn)
                    .keyboardShortcut(.defaultAction)
            }

        case .ready:
            Text("Espalier will show a code to enter in your browser.")
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Continue", action: actions.continueSignIn)
                    .keyboardShortcut(.defaultAction)
            }

        case .requestingCode:
            HStack(spacing: Metrics.insetSmall) {
                ArcProgress(.small)
                Text("Getting a code…")
                    .foregroundStyle(.text2)
            }
            buttons {}

        case .code(let code):
            SignInCodeStep(code: code, actions: actions)
            buttons {}

        case .failed(let message, let retryTitle):
            SignInInlineError(message: message)
            buttons {
                Button(retryTitle, action: actions.continueSignIn)
                    .keyboardShortcut(.defaultAction)
            }

        case .success(let login, let avatar):
            HStack(spacing: Metrics.insetMedium) {
                Avatar(avatar, size: 32)
                Text("Signed in as @\(login)")
                    .font(Typography.heading)
                    .foregroundStyle(.text)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Metrics.insetMedium)
            .accessibilityElement(children: .combine)
        }
    }

    /// Cancel, then the step's buttons, trailing.
    private func buttons(@ViewBuilder _ trailing: () -> some View) -> some View {
        HStack(spacing: Metrics.insetSmall) {
            Spacer()
            Button("Cancel", role: .cancel, action: actions.cancel)
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            trailing()
                .buttonStyle(.prominent)
        }
        .padding(.top, Metrics.grid)
    }
}

/// The code to enter, the button that opens the page for it, and the time
/// left.
private struct SignInCodeStep: View {
    let code: SignInCodeContent
    let actions: SignInActions
    @Environment(\.fixedNow) private var fixedNow

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            Text("Enter this code at \(code.verificationLabel):")
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.insetMedium) {
                Spacer()
                Text(code.userCode)
                    .font(Typography.deviceCode)
                    .kerning(Metrics.SignIn.codeKerning)
                    .foregroundStyle(.text)
                    .textSelection(.enabled)
                    .accessibilityLabel("Code: \(code.userCode.map(String.init).joined(separator: " "))")
                Spacer()
                Button {
                    actions.copyCode(code.userCode)
                } label: {
                    Label("Copy Code", systemImage: "doc.on.doc")
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
            }
            .padding(Metrics.insetMedium)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                    .fill(.field)
            )
            Button {
                actions.openVerificationPage(code.userCode)
            } label: {
                Text("Open \(code.verificationLabel)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.prominent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .tooltip("Copies the code and opens the page in your browser")
            if let fixedNow {
                status(now: fixedNow)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    status(now: timeline.date)
                }
            }
        }
    }

    @ViewBuilder
    private func status(now: Date) -> some View {
        if let timeLeft = code.timeLeft(now: now) {
            VStack(alignment: .leading, spacing: Metrics.grid) {
                HStack(spacing: Metrics.insetSmall) {
                    ArcProgress(.small)
                    Text("Waiting for you to authorize Espalier…")
                        .foregroundStyle(.text2)
                }
                Text("The code expires in \(timeLeft).")
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .monospacedDigit()
            }
        } else {
            HStack {
                SignInInlineError(message: "This code has expired.")
                Spacer()
                Button("Get a New Code", action: actions.continueSignIn)
                    .buttonStyle(.quiet)
            }
        }
    }
}

/// An error under a step.
struct SignInInlineError: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(Color(espalier: Palette.error))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color(espalier: Palette.error))
                .accessibilityLabel("Error")
        }
        .font(Typography.secondary)
    }
}
