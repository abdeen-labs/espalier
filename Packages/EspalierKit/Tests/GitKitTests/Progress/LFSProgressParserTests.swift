import GitKit
import Testing

@Suite("GitLFSProgressParser")
struct LFSProgressParserTests {
    private static let plain = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)

    @Test("totals the bytes of every file seen so far")
    func totalsTransfers() {
        var parser = GitLFSProgressParser(numberFormat: Self.plain)

        guard case .progress(let first) = parser.parse("download 1/2 5/300 my cool image.jpg") else {
            Issue.record("Expected progress")
            return
        }
        #expect(first.percent == 0)
        #expect(first.details.value == 5)
        #expect(first.details.total == 300)

        guard case .progress(let second) = parser.parse("download 2/2 2048/2048 other.bin") else {
            Issue.record("Expected progress")
            return
        }
        #expect(second.details.value == 2053)
        #expect(second.details.total == 2348)

        guard case .progress(let third) = parser.parse("upload 1/1 1536/1536 my cool image.jpg") else {
            Issue.record("Expected progress")
            return
        }
        // The file's earlier progress is replaced, not added to.
        #expect(third.details.value == 3584)
        #expect(third.details.total == 3584)
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
