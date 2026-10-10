// Ported from desktop/app/src/models/dot-com-bots.ts

/// A GitHub.com bot account whose commits the app recognizes.
public struct KnownBot: Sendable, Hashable {
    public let login: String
    public let userId: Int
    public let integrationId: Int
    public let avatarURL: String
    public let endpoint: String
}

private func dotComBot(_ login: String, _ userId: Int, _ integrationId: Int) -> KnownBot {
    KnownBot(
        login: login,
        userId: userId,
        integrationId: integrationId,
        avatarURL: "https://avatars.githubusercontent.com/in/\(integrationId)?v=4",
        endpoint: getDotComAPIEndpoint()
    )
}

public let dependabotBot = dotComBot("dependabot[bot]", 49_699_333, 29110)
public let actionsBot = dotComBot("github-actions[bot]", 41_898_282, 15368)
public let githubPagesBot = dotComBot("github-pages[bot]", 52_472_962, 34598)
// https://github.com/apps/copilot-pull-request-reviewer
public let copilotPRReviewerBot = dotComBot("Copilot", 175_728_472, 946_600)
// https://github.com/apps/copilot-swe-agent
public let copilotSweAgentBot = dotComBot("Copilot", 198_982_749, 1_143_301)
// https://github.com/apps/github-copilot-cli
public let copilotCliBot = dotComBot("Copilot", 223_556_219, 1_693_627)

public let knownDotComBots: [KnownBot] = [
    dependabotBot,
    actionsBot,
    githubPagesBot,
    copilotPRReviewerBot,
    copilotSweAgentBot,
    copilotCliBot,
]
