/// One server-sent event.
struct ServerSentEvent: Sendable, Hashable {
    /// The `event:` field, or `nil` for the default `message` type.
    var event: String?
    /// The `data:` lines, joined with newlines.
    var data: String
}

/// An incremental parser for the `text/event-stream` format, following the
/// HTML standard's event stream interpretation.
///
/// Bytes can arrive split anywhere: inside a line, between a CR and its LF,
/// or inside a multi-byte UTF-8 sequence. Lines are decoded only once they're
/// complete.
struct ServerSentEventParser {
    private var line: [UInt8] = []
    private var lastByteWasCR = false
    private var isFirstLine = true
    private var eventType: String?
    private var data = ""
    private var hasData = false

    /// Feeds one byte; returns an event when the byte completes one.
    mutating func feed(_ byte: UInt8) -> ServerSentEvent? {
        switch byte {
        case 0x0A where lastByteWasCR:
            // The LF of a CRLF pair; the CR already ended the line.
            lastByteWasCR = false
            return nil
        case 0x0A, 0x0D:
            lastByteWasCR = byte == 0x0D
            return processLine()
        default:
            lastByteWasCR = false
            line.append(byte)
            return nil
        }
    }

    /// Feeds a chunk of bytes; returns the events it completes, in order.
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
        bytes.compactMap { feed($0) }
    }

    /// Ends the stream. Returns a final event that wasn't followed by a blank
    /// line. The standard discards it; AIKit keeps it, because some local
    /// servers close the stream without the final blank line.
    mutating func finish() -> ServerSentEvent? {
        if !line.isEmpty {
            _ = processLine()
        }
        return dispatch()
    }

    private mutating func processLine() -> ServerSentEvent? {
        var bytes = line
        line.removeAll(keepingCapacity: true)

        // A UTF-8 byte order mark at the start of the stream is ignored.
        if isFirstLine {
            isFirstLine = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                bytes.removeFirst(3)
            }
        }

        if bytes.isEmpty {
            return dispatch()
        }

        // The line is split on bytes, as the standard splits it on code
        // points: a colon or space followed by a combining mark is still a
        // colon or a space (Swift's `Character` would join them).
        let colon = UInt8(ascii: ":")
        if bytes.first == colon {
            // A comment, often used as a keep-alive.
            return nil
        }

        let field: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let separator = bytes.firstIndex(of: colon) {
            field = bytes[..<separator]
            value = bytes[(separator + 1)...]
            if value.first == UInt8(ascii: " ") {
                value = value.dropFirst()
            }
        } else {
            field = bytes[...]
            value = []
        }

        if field.elementsEqual("event".utf8) {
            eventType = String(decoding: value, as: UTF8.self)
        } else if field.elementsEqual("data".utf8) {
            if hasData {
                data += "\n"
            }
            data += String(decoding: value, as: UTF8.self)
            hasData = true
        }
        // `id` and `retry` don't matter for a single request.
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            eventType = nil
            data = ""
            hasData = false
        }
        guard hasData else {
            return nil
        }
        return ServerSentEvent(event: eventType, data: data)
    }
}
