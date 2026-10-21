// The Create Pull Request sheet: empty, seeded from the only commit and the
// repository's template, creating a draft, and GitHub's refusal of a fork's
// branch under the fields.

import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Create Pull Request", .captures, .offline) @MainActor
struct CreatePullRequestCaptures {
    private let area = "GitHub"

    private static let title = "Add the sign-in sheet"

    private static let template = """
        ## What changed

        ## How to test

        - [ ] Captures in light and dark
        """

    private func content(
        head: String = "feature/sign-in",
        isCreating: Bool = false,
        problem: String? = nil,
        canCreate: Bool = true
    ) -> CreatePullRequestContent {
        CreatePullRequestContent(
            repositoryName: "octocat/hello",
            base: "main",
            head: head,
            isCreating: isCreating,
            problem: problem,
            canCreate: canCreate
        )
    }

    private func form(_ content: CreatePullRequestContent, title: String = "", body: String = "", isDraft: Bool = false) -> some View {
        CreatePullRequestForm(
            content: content,
            title: .constant(title),
            bodyText: .constant(body),
            isDraft: .constant(isDraft),
            isPickingBase: .constant(false)
        ) {
            EmptyView()
        }
    }

    @Test("the sheet: empty, its title and description to write")
    func empty() {
        capture(form(content(canCreate: false)), named: "createPullRequest-empty", area: area)
    }

    @Test("the sheet: seeded from the only commit's summary and the repository's template")
    func seeded() {
        capture(form(content(), title: Self.title, body: Self.template), named: "createPullRequest-template", area: area)
    }

    @Test("the sheet: creating a draft")
    func creating() {
        capture(
            form(content(isCreating: true, canCreate: false), title: Self.title, body: Self.template, isDraft: true),
            named: "createPullRequest-creating",
            area: area
        )
    }

    @Test("the sheet: GitHub's refusal of a fork's branch, under the fields")
    func error() {
        let head = "hubot:feature/sign-in"
        capture(
            form(
                content(head: head, problem: "There's already an open pull request for \(head)."),
                title: Self.title,
                body: "With the device flow."
            ),
            named: "createPullRequest-error",
            area: area
        )
    }
}
