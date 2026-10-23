// The welcome flow, which fills the main window until
// `has-shown-welcome-flow` is set: the welcome copy, Sign In to GitHub.com
// and to GitHub Enterprise, "New to GitHub? Create your free account.", and
// Skip This Step, which goes on to Configure Git, whose Finish ends the flow
// (`endWelcomeFlow()`). Signing in goes through the sign-in sheet; once it
// signs in, Configure Git follows. One step crossfades into the next over
// 0.22 s.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// The welcome flow's steps (the sign-in sheet signs in).
nonisolated enum WelcomeStep: Sendable, Equatable {
    case start
    case configureGit
}

/// The first step: what Espalier is, and signing in.
struct WelcomeStart: View {
    var signIn: @MainActor () -> Void = {}
    var signInToEnterprise: @MainActor () -> Void = {}
    var skip: @MainActor () -> Void = {}

    var body: some View {
        VStack(spacing: Metrics.Welcome.sectionSpacing) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: Metrics.Welcome.iconSize, height: Metrics.Welcome.iconSize)
                .accessibilityHidden(true)
            WelcomeHeading(
                title: "Welcome to Espalier",
                message: "Sign in to GitHub.com or GitHub Enterprise to work with your remotes and pull requests, or skip this step to jump straight into your local repositories."
            )
            VStack(spacing: Metrics.insetSmall) {
                Button(action: signIn) {
                    Text("Sign In to GitHub.com")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
                Button(action: signInToEnterprise) {
                    Text("Sign In to GitHub Enterprise…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.quiet)
            }
            .controlSize(.extraLarge)
            .frame(width: Metrics.Welcome.buttonWidth)
            VStack(spacing: Metrics.insetSmall) {
                // The link opens github.com's sign-up page in the browser.
                LinkedText(markdown: "New to GitHub? [Create your free account.](https://github.com/join)")
                    .foregroundStyle(.text2)
                Button("Skip This Step", action: skip)
                    .buttonStyle(.textLink)
            }
            .font(Typography.secondary)
        }
        .padding(Metrics.insetLarge * 2)
    }
}

/// A welcome step's heading: the title, and the line under it.
struct WelcomeHeading: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Metrics.insetSmall) {
            Text(title)
                .font(Typography.welcomeTitle)
                .foregroundStyle(.text)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(Typography.welcomeBody)
                .foregroundStyle(.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Metrics.Welcome.textWidth)
        }
    }
}

/// Welcome to Espalier.
public struct WelcomeView: View {
    static let signInSheetID = "welcome.signIn"

    @Environment(WindowContext.self) private var context
    @Environment(\.motion) private var motion
    @State private var flow: WelcomeFlow?

    public init() {}

    public var body: some View {
        Group {
            if let flow {
                switch flow.step {
                case .start:
                    WelcomeStart(
                        signIn: { signIn(SignInRequest(endpoint: nil, reason: .user), flow: flow) },
                        signInToEnterprise: { signIn(WelcomeFlow.enterpriseSignIn, flow: flow) },
                        skip: { animate { flow.skip() } }
                    )
                    .transition(stepTransition)
                case .configureGit:
                    if let configureGit = flow.configureGit {
                        ConfigureGitStep(model: configureGit, back: { animate { flow.back() } })
                            .transition(stepTransition)
                    }
                }
            } else {
                // Something must show for `onAppear` to make the flow: an
                // empty group never appears, and the window would stay blank.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(espalier: Palette.background))
        .onAppear {
            if flow == nil {
                flow = WelcomeFlow(app: context.app, presenter: context.presenter)
            }
        }
    }

    /// Shows the sign-in sheet; once signed in, Configure Git follows.
    private func signIn(_ request: SignInRequest, flow: WelcomeFlow) {
        let modals = context.modals
        modals.presentSheet(id: Self.signInSheetID) {
            SignInSheet(request: request) { account in
                modals.dismissSheet(id: Self.signInSheetID)
                animate { flow.signInFinished(account) }
            }
        }
    }

    /// One step crossfades into the next where motion runs; none otherwise.
    private var stepTransition: AnyTransition {
        motion.animates ? .opacity : .identity
    }

    private func animate(_ change: () -> Void) {
        withMotion(motion, Motion.arrive, change)
    }
}

/// Where the welcome flow is.
@MainActor @Observable
final class WelcomeFlow {
    private(set) var step: WelcomeStep = .start
    /// Configure Git's state, made each time the step shows (it reads the
    /// global configuration again, as it may have changed).
    private(set) var configureGit: ConfigureGitModel?

    @ObservationIgnored let app: AppModel
    @ObservationIgnored let presenter: WindowPresenter

    init(app: AppModel, presenter: WindowPresenter) {
        self.app = app
        self.presenter = presenter
    }

    /// The sign-in sheet asking for an Enterprise server's address.
    static let enterpriseSignIn = SignInRequest(endpoint: SignInRequest.enterpriseEndpoint, reason: .user)

    /// The sign-in sheet closed: Configure Git follows a sign-in; a
    /// cancelled one stays.
    func signInFinished(_ account: Account?) {
        if account != nil {
            showConfigureGit()
        }
    }

    /// Skip This Step: Configure Git.
    func skip() {
        showConfigureGit()
    }

    /// Back, from Configure Git.
    func back() {
        step = .start
        configureGit = nil
    }

    private func showConfigureGit() {
        configureGit = ConfigureGitModel(app: app, presenter: presenter)
        step = .configureGit
    }
}
