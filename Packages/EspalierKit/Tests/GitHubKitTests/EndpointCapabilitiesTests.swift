// Ported from desktop/app/test/unit/endpoint-capabilities-test.ts

@testable import GitHubKit
import Testing

private func testDotCom(_ constraint: Bool, _ endpointVersion: String? = nil) -> Bool {
    testEndpoint(
        getDotComAPIEndpoint(),
        VersionConstraint(dotcom: constraint, ghe: false, es: false),
        endpointVersion
    )
}

private func testGHES(_ constraint: EnterpriseServerConstraint, _ endpointVersion: String? = nil) -> Bool {
    testEndpoint(
        "https://ghe.io",
        VersionConstraint(dotcom: false, ghe: false, es: constraint),
        endpointVersion
    )
}

private func testGHEDotCom(_ constraint: Bool) -> Bool {
    testEndpoint(
        "https://corp.ghe.com",
        VersionConstraint(dotcom: false, ghe: constraint, es: false)
    )
}

private func testEndpoint(
    _ endpoint: String,
    _ constraint: VersionConstraint,
    _ endpointVersion: String? = nil
) -> Bool {
    let version = endpointVersion.map { version in
        guard let parsed = SemVer(version) else {
            preconditionFailure("Couldn't parse endpoint version")
        }
        return parsed
    }
    return endpointSatisfies(constraint, getVersion: { _ in version })(endpoint)
}

@Suite("endpoint-capabilities")
struct EndpointCapabilitiesTests {
    @Suite("endpointSatisfies")
    struct EndpointSatisfies {
        @Test("recognizes github.com")
        func recognizesDotCom() {
            #expect(testDotCom(true) == true)
            #expect(testDotCom(false) == false)
        }

        @Test("recognizes GHES")
        func recognizesGHES() {
            #expect(testGHES(false) == false)
            #expect(testGHES(true) == true)
        }

        @Test("recognizes GHAE")
        func recognizesGHAE() {
            #expect(testGHEDotCom(false) == false)
            #expect(testGHEDotCom(true) == true)
        }

        // If we can't determine the actual version of a GitHub Enterprise Server
        // instance we'll assume it's running the oldest still supported version
        // of GHES. This is defined in the `assumedGHESVersion` constant in
        // EndpointCapabilities.swift and needs to be updated periodically.
        @Test("assumes GHES versions")
        func assumesGHESVersions() {
            #expect(testGHES(">= 3.1.1") == false)
            #expect(testGHES(">= 3.1.0") == true)
        }

        @Test("parses semver ranges")
        func parsesSemverRanges() {
            #expect(testGHES(">= 1", "1.0.0") == true)
            #expect(testGHES("> 1.0.0", "1.0.0") == false)
            #expect(testGHES("> 0.9.9", "1.0.0") == true)
        }
    }
}
