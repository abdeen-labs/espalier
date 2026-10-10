import GitKit
import Testing

@Suite("GitLFSProgressParser")
struct LFSProgressParserTests {
    private static let plain = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)

    @Test("describes the transfer of every file seen so far")
    func describesTransfers() {
        var parser = GitLFSProgressParser(numberFormat: Self.plain)

        guard case .progress(let first) = parser.parse("download 1/2 5/300 my cool image.jpg") else {
            Issue.record("Expected progress")
            return
        }
        #expect(first.percent == 0)
        #expect(first.details.title == "Downloading \"my cool image.jpg\"")
        #expect(first.details.text == "Downloading my cool image.jpg (0 out of an estimated 2 completed, 5 B / 300 B)")
        #expect(first.details.value == 5)
        #expect(first.details.total == 300)

        guard case .progress(let second) = parser.parse("download 2/2 2048/2048 other.bin") else {
            Issue.record("Expected progress")
            return
        }
        #expect(second.details.text == "Downloading other.bin (1 out of an estimated 2 completed, 2 KiB / 2.3 KiB)")

        guard case .progress(let third) = parser.parse("upload 1/1 1536/1536 my cool image.jpg") else {
            Issue.record("Expected progress")
            return
        }
        // The file's earlier progress is replaced, not added to.
        #expect(third.details.title == "Uploading \"my cool image.jpg\"")
        #expect(third.details.text == "Uploading my cool image.jpg (2 out of an estimated 2 completed, 3.5 KiB / 3.5 KiB)")
    }

    @Test("names the direction")
    func directions() {
        var parser = GitLFSProgressParser(numberFormat: Self.plain)
        #expect(parser.parse("checkout 1/1 1/1 a").text.hasPrefix("Checking out a "))
        #expect(parser.parse("sideways 1/1 1/1 b").text.hasPrefix("Downloading b "))
    }

    @Test("rejects lines with other separators or terminators")
    func strictLines() {
        var parser = GitLFSProgressParser(numberFormat: Self.plain)
        #expect(!parser.parse("download 1/2 5/300 name\n").isProgress)
        #expect(!parser.parse("download 1/2 5/300").isProgress)
        #expect(!parser.parse("download x/2 5/300 name").isProgress)
        // JavaScript's \s includes U+00A0 and U+FEFF.
        #expect(parser.parse("download\u{A0}1/2\u{FEFF}5/300 name").isProgress)
    }
}
