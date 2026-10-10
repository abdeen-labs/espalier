// Ported from desktop/app/test/unit/http-test.ts

@testable import GitHubKit
import Testing

@Suite("getAbsoluteUrl")
struct HTTPTests {
    @Suite("dotcom endpoint")
    struct DotComEndpoint {
        let dotcomEndpoint = getDotComAPIEndpoint()

        @Test("handles missing leading slash")
        func handlesMissingLeadingSlash() {
            let result = getAbsoluteUrl(dotcomEndpoint, "user/repos")
            #expect(result == "https://api.github.com/user/repos")
        }
    }

    @Suite("enterprise endpoint")
    struct EnterpriseEndpoint {
        let enterpriseEndpoint = "https://my-cool-company.com/api/v3"

        @Test("handles leading slash")
        func handlesLeadingSlash() {
            let result = getAbsoluteUrl(enterpriseEndpoint, "/user/repos")
            #expect(result == "\(enterpriseEndpoint)/user/repos")
        }

        @Test("handles next page resource which already contains prefix")
        func handlesNextPageWithPrefix() {
            let result = getAbsoluteUrl(enterpriseEndpoint, "/api/v3/user/repos?page=2")
            #expect(result == "\(enterpriseEndpoint)/user/repos?page=2")
        }

        @Test("doesn't mangle encoded query parameters")
        func keepsEncodedQueryParameters() {
            let result = getAbsoluteUrl(enterpriseEndpoint, "/issues?since=2019-05-10T16%3A00%3A00Z")
            #expect(result == "\(enterpriseEndpoint)/issues?since=2019-05-10T16%3A00%3A00Z")
        }
    }
}
