// Adapted from desktop/app/src/lib/trampoline/trampoline-command-parser.ts and
// desktop/vendor/desktop-trampoline/src/desktop-trampoline.c
//
// The wire format between espalier-askpass and Espalier's trampoline server.
// This file is compiled into both: the helper builds it from this folder, and
// EspalierCore's Trampoline/TrampolineWire.swift is a symbolic link to it, so
// the two sides can never disagree. Foundation only.
//
// The helper is also the hook proxy, which streams standard input to the app
// and standard error back while a hook runs, then receives an exit code. So
// every message is a frame:
//
//     type (1 byte) | payload length (4 bytes, big-endian) | payload
//
// The helper sends one `request` frame, then, when it forwards standard input,
// `standardInput` frames and one `standardInputEnd`. The app answers with
// `standardOutput` and `standardError` frames and ends with one `exit` frame.

import Foundation

enum TrampolineWire {
    /// The format's version. The app rejects requests in any other version,
    /// which can only come from a helper left over from another build.
    static let version: UInt16 = 1

    /// The largest payload one frame may carry.
    static let maximumPayloadLength = 1 << 20

    /// The length of a frame's type and length fields.
    static let headerLength = 5

    // MARK: Environment and arguments

    /// The path of the app's socket.
    static let socketVariable = "ESPALIER_TRAMPOLINE_SOCKET"

    /// The token for askpass and credential requests.
    static let tokenVariable = "ESPALIER_TRAMPOLINE_TOKEN"

    /// The path of the app's socket for hook requests. The hooks environment
    /// and the trampoline set their own variables, so neither depends on the
    /// other's server.
    static let hooksSocketVariable = "ESPALIER_HOOKS_SOCKET"

    /// The token for hook requests.
    static let hooksTokenVariable = "ESPALIER_HOOKS_TOKEN"

    /// The first argument when git runs the helper as a credential helper:
    /// `credential.helper` is `!'<helper>' --credential-helper`, and git
    /// appends the action (`get`, `store`, or `erase`).
    static let credentialHelperArgument = "--credential-helper"

    /// The prefix of git's name for a credential helper found in its exec
    /// path (`git credential-<name>` runs `git-credential-<name>`).
    static let credentialHelperProgramPrefix = "git-credential-"

    /// The hooks git knows. The helper is a hook proxy when it is invoked
    /// through a symbolic link with one of these names.
    static let hookNames: Set<String> = [
        "applypatch-msg",
        "pre-applypatch",
        "post-applypatch",
        "pre-commit",
        "pre-merge-commit",
        "prepare-commit-msg",
        "commit-msg",
        "post-commit",
        "pre-rebase",
        "post-checkout",
        "post-merge",
        "pre-push",
        "pre-receive",
        "update",
        "proc-receive",
        "post-receive",
        "post-update",
        "reference-transaction",
        "push-to-checkout",
        "pre-auto-gc",
        "post-rewrite",
        "sendemail-validate",
        "fsmonitor-watchman",
        "p4-changelist",
        "p4-prepare-changelist",
        "p4-post-changelist",
        "p4-pre-submit",
        "post-index-change",
    ]

    // MARK: Frames

    enum FrameType: UInt8 {
        // From the helper.
        case request = 0x01
        case standardInput = 0x02
        case standardInputEnd = 0x03

        // From the app.
        case standardOutput = 0x81
        case standardError = 0x82
        case exit = 0x83

        /// Whether the helper sends frames of this type.
        var isFromHelper: Bool { rawValue < 0x80 }
    }

    struct Frame: Equatable {
        var type: FrameType
        var payload: [UInt8]
    }

    enum DecodingError: Error, Equatable, CustomStringConvertible {
        case unknownFrameType(UInt8)
        case payloadTooLarge(Int)
        case malformedRequest
        case malformedExitCode

        var description: String {
            switch self {
            case .unknownFrameType(let type): "unknown frame type \(type)"
            case .payloadTooLarge(let length): "frame payload of \(length) bytes is too large"
            case .malformedRequest: "malformed request"
            case .malformedExitCode: "malformed exit code"
            }
        }
    }

    /// Encodes one frame without a payload.
    static func encode(_ type: FrameType) -> [UInt8] {
        encode(type, [UInt8]())
    }

    /// Encodes one frame. The payload must not exceed `maximumPayloadLength`.
    static func encode(_ type: FrameType, _ payload: some Collection<UInt8>) -> [UInt8] {
        precondition(payload.count <= maximumPayloadLength, "Trampoline frame payload too large")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerLength + payload.count)
        bytes.append(type.rawValue)
        appendUInt32(UInt32(payload.count), to: &bytes)
        bytes.append(contentsOf: payload)
        return bytes
    }

    /// Splits a byte stream into frames.
    struct FrameDecoder {
        private var buffer: [UInt8] = []
        private var offset = 0

        init() {}

        /// The number of bytes received but not yet returned in a frame.
        var bufferedByteCount: Int { buffer.count - offset }

        mutating func append(_ bytes: some Sequence<UInt8>) {
            if offset > 0, offset >= buffer.count / 2 {
                buffer.removeFirst(offset)
                offset = 0
            }
            buffer.append(contentsOf: bytes)
        }

        /// The next complete frame, or `nil` when more bytes are needed.
        /// Throws for an unknown type or an oversized payload, after which
        /// the stream can't be trusted.
        mutating func next() throws(DecodingError) -> Frame? {
            guard buffer.count - offset >= headerLength else { return nil }
            let rawType = buffer[offset]
            guard let type = FrameType(rawValue: rawType) else {
                throw .unknownFrameType(rawType)
            }
            let length = Int(readUInt32(buffer, at: offset + 1))
            guard length <= maximumPayloadLength else {
                throw .payloadTooLarge(length)
            }
            let start = offset + headerLength
            guard buffer.count - start >= length else { return nil }
            let payload = Array(buffer[start..<(start + length)])
            offset = start + length
            if offset == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                offset = 0
            }
            return Frame(type: type, payload: payload)
        }
    }

    // MARK: Requests

    /// What the helper was asked to do.
    enum RequestKind: String {
        /// `SSH_ASKPASS`: one argument, the prompt.
        case askpass
        /// A git credential helper: one argument, the action, and the
        /// credential on standard input.
        case credential
        /// A hook proxy: git's arguments for the hook (the first is the
        /// path git ran), and standard input when it is connected.
        case hook
    }

    /// The first frame the helper sends.
    struct Request: Equatable {
        var version: UInt16 = TrampolineWire.version
        /// A `RequestKind` raw value. Kept as a string so that the app can
        /// reject unknown kinds instead of failing to decode.
        var kind: String
        var token: String
        var workingDirectory: String
        var arguments: [String]
        /// The environment variables the request needs (for a hook, git's
        /// `GIT_` variables).
        var environment: [String: String]
        /// Whether `standardInput` frames follow, ended by `standardInputEnd`.
        var forwardsStandardInput: Bool
    }

    static func encodeRequest(_ request: Request) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(UInt8(request.version >> 8))
        bytes.append(UInt8(request.version & 0xFF))
        appendString(request.kind, to: &bytes)
        appendString(request.token, to: &bytes)
        appendString(request.workingDirectory, to: &bytes)
        appendUInt32(UInt32(request.arguments.count), to: &bytes)
        for argument in request.arguments {
            appendString(argument, to: &bytes)
        }
        appendUInt32(UInt32(request.environment.count), to: &bytes)
        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            appendString(key, to: &bytes)
            appendString(value, to: &bytes)
        }
        bytes.append(request.forwardsStandardInput ? 1 : 0)
        return bytes
    }

    static func decodeRequest(_ payload: [UInt8]) throws(DecodingError) -> Request {
        var reader = Reader(bytes: payload)
        guard let high = reader.byte(), let low = reader.byte() else { throw .malformedRequest }
        let version = UInt16(high) << 8 | UInt16(low)
        guard let kind = reader.string(),
              let token = reader.string(),
              let workingDirectory = reader.string(),
              let argumentCount = reader.count()
        else {
            throw .malformedRequest
        }
        var arguments: [String] = []
        for _ in 0..<argumentCount {
            guard let argument = reader.string() else { throw .malformedRequest }
            arguments.append(argument)
        }
        guard let environmentCount = reader.count() else { throw .malformedRequest }
        var environment: [String: String] = [:]
        for _ in 0..<environmentCount {
            guard let key = reader.string(), let value = reader.string() else { throw .malformedRequest }
            environment[key] = value
        }
        guard let flags = reader.byte(), flags <= 1, reader.isAtEnd else { throw .malformedRequest }
        return Request(
            version: version,
            kind: kind,
            token: token,
            workingDirectory: workingDirectory,
            arguments: arguments,
            environment: environment,
            forwardsStandardInput: flags == 1
        )
    }

    // MARK: Exit codes

    static func encodeExitCode(_ code: Int32) -> [UInt8] {
        var bytes: [UInt8] = []
        appendUInt32(UInt32(bitPattern: code), to: &bytes)
        return bytes
    }

    static func decodeExitCode(_ payload: [UInt8]) throws(DecodingError) -> Int32 {
        guard payload.count == 4 else { throw .malformedExitCode }
        return Int32(bitPattern: readUInt32(payload, at: 0))
    }

    // MARK: Primitives

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func appendString(_ string: String, to bytes: inout [UInt8]) {
        let utf8 = Array(string.utf8)
        appendUInt32(UInt32(utf8.count), to: &bytes)
        bytes.append(contentsOf: utf8)
    }

    /// Reads a request's fields, failing instead of reading past the end.
    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func byte() -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func uint32() -> UInt32? {
            guard bytes.count - index >= 4 else { return nil }
            defer { index += 4 }
            return readUInt32(bytes, at: index)
        }

        /// A count of following strings, each of which takes at least four
        /// bytes, so a count the payload can't hold is rejected before any
        /// allocation.
        mutating func count() -> Int? {
            guard let value = uint32(), Int(value) <= (bytes.count - index) / 4 else { return nil }
            return Int(value)
        }

        mutating func string() -> String? {
            guard let length = uint32().map(Int.init), bytes.count - index >= length else { return nil }
            defer { index += length }
            return String(decoding: bytes[index..<(index + length)], as: UTF8.self)
        }
    }
}
