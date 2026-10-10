// Ported from desktop/app/test/unit/sanitized-repository-name-test.ts

@testable import EspalierCore
import Testing

@Suite("sanitizedRepositoryName")
struct SanitizedRepositoryNameTests {
    @Test("leaves a good repo name alone")
    func leavesGoodName() {
        let repoName = "this-is-fine"
        let result = sanitizedRepositoryName(repoName)
        #expect(result == "this-is-fine")
    }

    @Test("replaces invalid characters with dashes")
    func replacesInvalidCharacters() {
        let repoName = ".this..is\\not fine:yo?|is-it"
        let result = sanitizedRepositoryName(repoName)
        #expect(result == ".this..is-not-fine-yo--is-it")
    }

    @Test("replaces ending slash with dashes")
    func replacesEndingSlash() {
        let repoName = "hello/"
        let result = sanitizedRepositoryName(repoName)
        #expect(result == "hello-")
    }

    @Test("does not allow name to start with plus, replaces it with dashes")
    func replacesLeadingPlus() {
        let repoName = "++but-can-still-keep-the-rest"
        let result = sanitizedRepositoryName(repoName)
        #expect(result == "--but-can-still-keep-the-rest")
    }

    @Test("allow name to start with minus")
    func allowsLeadingMinus() {
        let repoName = "--but-can-still-keep-the-rest"
        let result = sanitizedRepositoryName(repoName)
        #expect(result == repoName)
    }

    @Test("replaces slash in newlines with dash")
    func replacesEscapedNewlines() {
        let repoName = "hello\\r\\nworld"
        let result = sanitizedRepositoryName(repoName)
        #expect(result == "hello-r-nworld")
    }

    @Test("allow name to have dots")
    func allowsDots() {
        let repoName = ".first.dot.is.ok"
        let result = sanitizedRepositoryName(repoName)
        #expect(result == repoName)
    }

    @Test("replaces one emoji with one dash")
    func replacesEmoji() {
        let repoName = "hello\u{1F413}world-repo"
        let result = sanitizedRepositoryName(repoName)
        #expect(result == "hello-world-repo")
    }

    // JavaScript replaces UTF-16 code units, so characters outside the emoji
    // ranges count as one dash per code unit.
    @Test("replaces each UTF-16 code unit outside the emoji ranges with a dash")
    func replacesCodeUnits() {
        #expect(sanitizedRepositoryName("caf\u{E9}") == "caf-")
        #expect(sanitizedRepositoryName("cafe\u{301}") == "cafe-")
        // U+1F9E1 (orange heart) isn't in the emoji ranges: two code units, two
        // dashes.
        #expect(sanitizedRepositoryName("a\u{1F9E1}b") == "a--b")
        #expect(sanitizedRepositoryName("a\u{1F680}b") == "a-b")
        #expect(sanitizedRepositoryName("") == "")
    }
}
