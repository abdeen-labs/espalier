// Adapted from desktop/app/src/lib/trampoline/trampoline-command-parser.ts

/// The purpose of this type is to process the data received from the
/// trampoline client (espalier-askpass) and build a command from it.
///
/// The helper sends frames (see `TrampolineWire`): one request, then
/// standard input when the request forwards it.
struct TrampolineCommandParser: Sendable {
    enum State: Equatable, Sendable {
        /// Waiting for the request frame.
        case request
        /// Receiving standard input frames until `standardInputEnd`.
        case standardInput
        /// The helper has sent everything it may send.
        case finished
    }

    enum Event: Equatable, Sendable {
        case request(TrampolineWire.Request)
        case standardInput([UInt8])
        case standardInputEnd
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case decoding(TrampolineWire.DecodingError)
        case unexpectedFrame(TrampolineWire.FrameType, State)
        case standardInputTooLarge

        var description: String {
            switch self {
            case .decoding(let error): "\(error)"
            case .unexpectedFrame(let type, let state): "unexpected \(type) frame in state \(state)"
            case .standardInputTooLarge: "standard input is too large"
            }
        }
    }

    private var decoder = TrampolineWire.FrameDecoder()
    private var standardInputLength = 0
    private(set) var state = State.request

    /// The most standard input a command may send.
    let maximumStandardInputLength: Int

    init(maximumStandardInputLength: Int) {
        self.maximumStandardInputLength = maximumStandardInputLength
    }

    /// Whether or not it has finished parsing the command.
    var hasFinished: Bool { state == .finished }

    /// Takes a chunk of data and returns what it completes.
    ///
    /// Throws if anything unexpected is received, including anything at all
    /// after the parser has finished. The connection must then be closed.
    mutating func process(_ bytes: some Sequence<UInt8>) throws(ParseError) -> [Event] {
        decoder.append(bytes)
        var events: [Event] = []
        while true {
            let next: TrampolineWire.Frame?
            do {
                next = try decoder.next()
            } catch {
                throw .decoding(error)
            }
            guard let frame = next else { return events }

            switch (state, frame.type) {
            case (.request, .request):
                let request: TrampolineWire.Request
                do {
                    request = try TrampolineWire.decodeRequest(frame.payload)
                } catch {
                    throw .decoding(error)
                }
                events.append(.request(request))
                state = request.forwardsStandardInput ? .standardInput : .finished

            case (.standardInput, .standardInput):
                standardInputLength += frame.payload.count
                guard standardInputLength <= maximumStandardInputLength else {
                    throw .standardInputTooLarge
                }
                events.append(.standardInput(frame.payload))

            case (.standardInput, .standardInputEnd):
                events.append(.standardInputEnd)
                state = .finished

            default:
                throw .unexpectedFrame(frame.type, state)
            }
        }
    }
}
