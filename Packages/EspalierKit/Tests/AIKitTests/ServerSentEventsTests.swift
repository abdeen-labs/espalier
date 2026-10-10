@testable import AIKit
import Testing

private func parse(_ chunks: [[UInt8]], finish: Bool = true) -> [ServerSentEvent] {
    var parser = ServerSentEventParser()
    var events = chunks.flatMap { parser.feed($0) }
    if finish, let last = parser.finish() {
        events.append(last)
    }
    return events
}

private func parse(_ text: String, chunkSize: Int? = nil) -> [ServerSentEvent] {
    let bytes = Array(text.utf8)
    guard let chunkSize else {
        return parse([bytes])
    }
    return parse(stride(from: 0, to: bytes.count, by: chunkSize).map { Array(bytes[$0..<min($0 + chunkSize, bytes.count)]) })
}

@Suite("Server-sent events")
struct ServerSentEventsTests {
    @Test("parses events with types and data")
    func basics() {
        #expect(
            parse("event: message_start\ndata: {\"a\":1}\n\ndata: second\n\n")
                == [
                    ServerSentEvent(event: "message_start", data: #"{"a":1}"#),
                    ServerSentEvent(event: nil, data: "second"),
                ]
        )
    }

    @Test("joins multi-line data, and keeps an empty data field")
    func multiLineData() {
        #expect(parse("data: one\ndata:two\ndata\n\n") == [ServerSentEvent(event: nil, data: "one\ntwo\n")])
        #expect(parse("data:\n\n") == [ServerSentEvent(event: nil, data: "")])
    }

    @Test("ignores comments, unknown fields, and events without data")
    func ignores() {
        #expect(parse(": keep-alive\n\nid: 7\nretry: 100\nevent: ping\n\ndata: x\n\n") == [ServerSentEvent(event: nil, data: "x")])
    }

    @Test("accepts LF, CRLF, and CR line endings")
    func lineEndings() {
        let expected = [ServerSentEvent(event: "e", data: "1"), ServerSentEvent(event: nil, data: "2")]
        #expect(parse("event: e\ndata: 1\n\ndata: 2\n\n") == expected)
        #expect(parse("event: e\r\ndata: 1\r\n\r\ndata: 2\r\n\r\n") == expected)
        #expect(parse("event: e\rdata: 1\r\rdata: 2\r\r") == expected)
    }

    @Test("handles chunks split anywhere, including between CR and LF and inside UTF-8 sequences")
    func splitChunks() {
        let text = "event: e\r\ndata: caf\u{E9} \u{1F600}\r\n\r\ndata: {\"x\":\"\u{2014}\"}\n\n"
        let expected = [
            ServerSentEvent(event: "e", data: "caf\u{E9} \u{1F600}"),
            ServerSentEvent(event: nil, data: #"{"x":"\#u{2014}"}"#),
        ]
        for size in 1...7 {
            #expect(parse(text, chunkSize: size) == expected, "chunk size \(size)")
        }
    }

    @Test("splits fields on the colon and space code points, even before a combining mark")
    func combiningMarks() {
        #expect(parse("data:\u{301}x\n\n") == [ServerSentEvent(event: nil, data: "\u{301}x")])
        #expect(parse("data: \u{301}x\n\n") == [ServerSentEvent(event: nil, data: "\u{301}x")])
        #expect(parse(":\u{301} comment\n\ndata: y\n\n") == [ServerSentEvent(event: nil, data: "y")])
        #expect(parse("data\u{301}: z\n\n").isEmpty)
    }

    @Test("ignores a byte order mark at the start of the stream")
    func byteOrderMark() {
        #expect(parse([[0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)]) == [ServerSentEvent(event: nil, data: "x")])
    }

    @Test("keeps a final event that the stream didn't end with a blank line")
    func finalEvent() {
        #expect(parse("data: a\n\ndata: b") == [ServerSentEvent(event: nil, data: "a"), ServerSentEvent(event: nil, data: "b")])
        #expect(parse("data: a\n\ndata: b\n") == [ServerSentEvent(event: nil, data: "a"), ServerSentEvent(event: nil, data: "b")])
        #expect(parse([Array("data: a\n\ndata: b".utf8)], finish: false) == [ServerSentEvent(event: nil, data: "a")])
    }
}
