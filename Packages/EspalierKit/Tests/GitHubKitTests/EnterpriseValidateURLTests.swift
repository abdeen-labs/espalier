// Ported from desktop/app/test/unit/enterprise-validate-url-test.ts

@testable import GitHubKit
import Testing

@Suite("validateURL")
struct EnterpriseValidateURLTests {
    @Test("passes through a valid url")
    func passesThroughValidURL() throws {
        let url = "https://ghe.io:9000"
        let result = try validateURL(url)
        #expect(result == url)
    }

    @Test("prepends https if no protocol is provided")
    func prependsHTTPS() throws {
        let url = try validateURL("ghe.io")
        #expect(url == "https://ghe.io")
    }

    @Test("throws if given an invalid protocol")
    func throwsForInvalidProtocol() {
        #expect {
            try validateURL("ftp://ghe.io")
        } throws: { error in
            (error as? EnterpriseURLValidationError)?.kind == .invalidProtocol
        }
    }

    @Test("throws if given whitespace")
    func throwsForWhitespace() {
        #expect {
            try validateURL("    ")
        } throws: { error in
            (error as? EnterpriseURLValidationError)?.kind == .invalidURL
        }
    }

    @Test("handles whitespace alongside valid text")
    func handlesWhitespaceAlongsideText() throws {
        let url = try validateURL("ghe.io   ")
        #expect(url == "https://ghe.io")
    }
}
