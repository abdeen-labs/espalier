// Ported from desktop/app/test/unit/api-test.ts

import Foundation
@testable import GitHubKit
import TestSupport
import Testing

private struct PageInfo {
    let perPage: Int
    let page: Int
}

private func createHeadersWithNextLink(_ url: String) -> HTTPHeaders {
    ["Link": "<\(url)>; rel=\"next\""]
}

private func assertNext(_ current: PageInfo, _ expected: PageInfo, sourceLocation: SourceLocation = #_sourceLocation) {
    let headers = createHeadersWithNextLink("/items?per_page=\(current.perPage)&page=\(current.page)")

    let nextPath = getNextPagePathWithIncreasingPageSize(HTTPResponse(headers: headers))

    guard let nextPath, let components = URLComponents(string: nextPath) else {
        Issue.record("Expected a next page path", sourceLocation: sourceLocation)
        return
    }

    #expect(components.path == "/items", sourceLocation: sourceLocation)

    let query = Dictionary(
        (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { _, last in last }
    )
    let perPage = Int(query["per_page"] ?? "")
    let page = Int(query["page"] ?? "")

    #expect(perPage == expected.perPage, sourceLocation: sourceLocation)
    #expect(page == expected.page, sourceLocation: sourceLocation)

    // If getNextPagePathWithIncreasingPageSize has fiddled with the
    // page size or page number we want to ensure that the next page will
    // get us more items than what we've gotten thus far.
    if let perPage, let page, current.perPage != perPage || current.page != page {
        let receivedCurrent = current.perPage * current.page
        let receivedNext = perPage * page

        #expect(receivedNext > receivedCurrent, sourceLocation: sourceLocation)
    }
}

@Suite("API", .offline)
struct APITests {
    @Suite("getNextPagePathWithIncreasingPageSize")
    struct GetNextPagePathWithIncreasingPageSize {
        @Test("returns null when there's no link header")
        func returnsNullWithoutLinkHeader() {
            #expect(getNextPagePathWithIncreasingPageSize(HTTPResponse()) == nil)
        }

        @Test("returns raw link when missing page size")
        func returnsRawLinkWithoutPageSize() {
            let nextPath = getNextPagePathWithIncreasingPageSize(
                HTTPResponse(headers: createHeadersWithNextLink("/items?page=2"))
            )

            #expect(nextPath == "/items?page=2")
        }

        @Test("returns raw link when missing page number")
        func returnsRawLinkWithoutPageNumber() {
            let nextPath = getNextPagePathWithIncreasingPageSize(
                HTTPResponse(headers: createHeadersWithNextLink("/items?per_page=10"))
            )

            #expect(nextPath == "/items?per_page=10")
        }

        @Test("does not increase page size when not aligned")
        func doesNotIncreaseWhenNotAligned() {
            let nextPath = getNextPagePathWithIncreasingPageSize(
                HTTPResponse(headers: createHeadersWithNextLink("/items?per_page=10&page=2"))
            )

            #expect(nextPath == "/items?per_page=10&page=2")
        }

        @Test("increases page size on alignment with an initial page size of 10")
        func increasesFromTen() {
            assertNext(PageInfo(perPage: 10, page: 2), PageInfo(perPage: 10, page: 2))
            assertNext(PageInfo(perPage: 10, page: 3), PageInfo(perPage: 20, page: 2))
            assertNext(PageInfo(perPage: 20, page: 2), PageInfo(perPage: 20, page: 2))
            assertNext(PageInfo(perPage: 20, page: 3), PageInfo(perPage: 40, page: 2))
            assertNext(PageInfo(perPage: 40, page: 2), PageInfo(perPage: 40, page: 2))
            assertNext(PageInfo(perPage: 40, page: 3), PageInfo(perPage: 80, page: 2))
            assertNext(PageInfo(perPage: 80, page: 3), PageInfo(perPage: 80, page: 3))
            assertNext(PageInfo(perPage: 80, page: 4), PageInfo(perPage: 80, page: 4))
            assertNext(PageInfo(perPage: 80, page: 5), PageInfo(perPage: 80, page: 5))
            assertNext(PageInfo(perPage: 80, page: 6), PageInfo(perPage: 100, page: 5))
        }

        @Test("increases page size on alignment with an initial page size of 1")
        func increasesFromOne() {
            assertNext(PageInfo(perPage: 1, page: 2), PageInfo(perPage: 1, page: 2))
            assertNext(PageInfo(perPage: 1, page: 3), PageInfo(perPage: 2, page: 2))
            assertNext(PageInfo(perPage: 2, page: 3), PageInfo(perPage: 4, page: 2))
            assertNext(PageInfo(perPage: 4, page: 2), PageInfo(perPage: 4, page: 2))
            assertNext(PageInfo(perPage: 4, page: 3), PageInfo(perPage: 8, page: 2))
            assertNext(PageInfo(perPage: 8, page: 2), PageInfo(perPage: 8, page: 2))
            assertNext(PageInfo(perPage: 8, page: 3), PageInfo(perPage: 16, page: 2))
            assertNext(PageInfo(perPage: 16, page: 2), PageInfo(perPage: 16, page: 2))
            assertNext(PageInfo(perPage: 16, page: 3), PageInfo(perPage: 32, page: 2))
            assertNext(PageInfo(perPage: 32, page: 2), PageInfo(perPage: 32, page: 2))
            assertNext(PageInfo(perPage: 32, page: 3), PageInfo(perPage: 64, page: 2))
        }

        @Test("doesn't increase page size when page size is 100")
        func doesNotIncreasePastHundred() {
            for page in 2...10 {
                assertNext(PageInfo(perPage: 100, page: page), PageInfo(perPage: 100, page: page))
            }
        }
    }

    @Suite("fetchProtectedBranches")
    struct FetchProtectedBranches {
        private let mock = MockGitHub()
        private let path = "/repos/desktop/desktop/branches"

        private var api: API {
            API(endpoint: "https://api.github.com", token: "token", runtime: mock.runtime)
        }

        @Test("returns the protected branches from a successful request")
        func returnsProtectedBranches() async {
            let branches = [
                APIBranch(name: "main", protected: true),
                APIBranch(name: "release", protected: true),
            ]
            mock.on("GET", path, respond: .json(encoding: branches))

            #expect(await api.fetchProtectedBranches(owner: "desktop", name: "desktop") == branches)
            #expect(mock.requests("GET", path).first?.query["protected"] == "true")
        }

        @Test("returns null when the request fails")
        func returnsNullOnFailure() async {
            mock.on("GET", path, respond: .networkError(.notConnectedToInternet))

            #expect(await api.fetchProtectedBranches(owner: "desktop", name: "desktop") == nil)
        }
    }
}
