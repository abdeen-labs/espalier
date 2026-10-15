// Ported from desktop/app/test/unit/api-error-handling-test.ts

import Foundation
@testable import GitHubKit
import Testing

@Suite("http")
struct APIErrorHandlingTests {
    @Suite("APIError")
    struct APIErrorTests {
        @Test("creates an error with API message")
        func createsErrorWithAPIMessage() {
            let response = HTTPResponse(
                status: 422,
                statusText: "Unprocessable Entity",
                url: URL(string: "https://api.github.com/repos/owner/repo")
            )

            let apiError = APIErrorPayload(
                message: "Validation Failed",
                errors: [APIErrorItem(message: "name already exists", resource: "Repository", field: "name")]
            )

            let error = APIError(response: response, apiError: apiError)

            #expect(error.responseStatus == 422)
            #expect(error.message.contains("Validation Failed"))
            #expect(error.message.contains("name already exists"))
            #expect(error.apiError != nil)
        }

        @Test("handles API error without additional errors array")
        func handlesErrorWithoutAdditionalErrors() {
            let response = HTTPResponse(
                status: 403,
                statusText: "Forbidden",
                url: URL(string: "https://api.github.com/user")
            )

            let apiError = APIErrorPayload(message: "Resource not accessible by integration")

            let error = APIError(response: response, apiError: apiError)

            #expect(error.responseStatus == 403)
            #expect(error.message == "Resource not accessible by integration")
        }

        @Test("creates an error without an API error")
        func createsErrorWithoutAPIError() {
            let response = HTTPResponse(status: 404, statusText: "Not Found", url: URL(string: "https://api.github.com/test"))

            let error = APIError(response: response, apiError: nil)
            #expect(error.responseStatus == 404)
            #expect(error.apiError == nil)
        }
    }

    @Suite("getAbsoluteUrl")
    struct GetAbsoluteUrl {
        @Test("handles endpoint with trailing slash")
        func handlesEndpointWithTrailingSlash() {
            let url = getAbsoluteUrl("https://api.github.com/", "repos/owner/repo")
            #expect(url == "https://api.github.com/repos/owner/repo")
        }
    }
}
