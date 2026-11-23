// The welcome flow, which fills the main window until
// `has-shown-welcome-flow` is set: the welcome copy, Sign In to GitHub.com
// and to GitHub Enterprise, "New to GitHub? Create your free account.", and
// Skip This Step, which goes on to Configure Git, whose Finish ends the flow
// (`endWelcomeFlow()`). Each step is a cream card on the backdrop, the
// steps' dots at its top. Signing in goes through the sign-in sheet; once
// it signs in, Configure Git follows. One step crossfades into the next over
// 0.22 s.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// The welcome flow's steps (the sign-in sheet signs in).
nonisolated enum WelcomeStep: Sendable, Hashable {
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
            AppIconArt(size: Metrics.Welcome.iconSize)
                .padding(.top, Metrics.WelcomeCard.iconLift)
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
        .welcomeCard(step: .start)
    }
}

/// A welcome step's heading: the title in display type, and the line
/// under it.
struct WelcomeHeading: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Metrics.insetMedium) {
            Text(title)
                .font(Typography.welcomeTitle)
                .foregroundStyle(.text)
                .multilineTextAlignment(.center)
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

extension View {
    /// A welcome step's frame: the step on a cream card, the steps' dots at
    /// its top, centered on the oat backdrop, scrolling when the window is
    /// shorter than the card.
    func welcomeCard(step: WelcomeStep) -> some View {
        modifier(WelcomeCardModifier(step: step))
    }
}

private struct WelcomeCardModifier: ViewModifier {
    let step: WelcomeStep

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: Metrics.WelcomeCard.dotsSpacing) {
                    WelcomeStepDots(step: step)
                    content
                }
                .padding(.horizontal, Metrics.WelcomeCard.horizontalPadding)
                .padding(.vertical, Metrics.WelcomeCard.verticalPadding)
                .surface(Color(espalier: Palette.background), elevation: .floating, in: RoundedRectangle(cornerRadius: Metrics.WelcomeCard.radius, style: .continuous))
                .padding(Metrics.WelcomeCard.margin)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                .unbouncedScrollContent()
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
        }
        .background(Color(espalier: Theme.current.backdrop))
    }
}

/// Where the welcome flow is, as dots: the current step a wide pill in the
/// accent, the other a dot. VoiceOver reads "Step 1 of 2".
struct WelcomeStepDots: View {
    let step: WelcomeStep

    var body: some View {
        let steps: [WelcomeStep] = [.start, .configureGit]
        HStack(spacing: Metrics.WelcomeCard.dotSpacing) {
            ForEach(steps, id: \.self) { each in
                Capsule(style: .circular)
                    .fill(each == step ? Color.accent : Color(espalier: Palette.line2))
                    .frame(width: each == step ? Metrics.WelcomeCard.currentDotWidth : Metrics.WelcomeCard.dotSize, height: Metrics.WelcomeCard.dotSize)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")
    }
}

extension Metrics {
    /// The welcome flow's card.
    public enum WelcomeCard {
        /// Inside the card.
        public static let horizontalPadding: CGFloat = 48
        public static let verticalPadding: CGFloat = 32
        /// Around the card, on the backdrop.
        public static let margin: CGFloat = 24
        public static let radius: CGFloat = 32
        /// The steps' dots: their size, the current one's width, between
        /// them, and below them.
        public static let dotSize: CGFloat = 8
        public static let currentDotWidth: CGFloat = 24
        public static let dotSpacing: CGFloat = 6
        public static let dotsSpacing: CGFloat = 20
        /// Space above the icon, under the dots.
        public static let iconLift: CGFloat = 4
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
        .background(Color(espalier: Theme.current.backdrop))
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
