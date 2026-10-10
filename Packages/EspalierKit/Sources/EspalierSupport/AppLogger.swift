// Espalier's loggers: the unified log, as `os.Logger` writes it, with info
// and above mirrored to the rolling log file (RollingLogFile.swift).
// Messages use `os.Logger`'s interpolation and privacy: a value is private
// unless it's marked `.public`, except numbers and Booleans, which are
// public unless marked `.private`. A private value shows as `<private>` in
// the file, as the unified log shows it to anyone without private data
// turned on.

import Foundation
import os
import Synchronization

/// Whether a logged value shows, as with `os.Logger`'s `OSLogPrivacy`.
public enum LogPrivacy: Sendable {
    /// Shown everywhere.
    case `public`
    /// `<private>` in the unified log unless private data is turned on (as
    /// it is under a debugger), and in the log file always.
    case `private`
}

/// How a logged floating-point value is formatted.
public enum LogFloatFormat: Sendable {
    /// `precision` digits after the decimal point.
    case fixed(precision: Int)
}

/// A log message: text, and values that are public or private.
public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    enum Segment: Sendable, Equatable {
        /// Literal text and public values.
        case text(String)
        case privateValue(String)
    }

    var segments: [Segment]

    public init(stringLiteral value: String) {
        segments = [.text(value)]
    }

    public init(stringInterpolation: StringInterpolation) {
        segments = stringInterpolation.segments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var segments: [Segment] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(2 * interpolationCount + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            append(literal, privacy: .public)
        }

        /// A string, private unless `privacy` is `.public`.
        public mutating func appendInterpolation(_ value: String, privacy: LogPrivacy = .private) {
            append(value, privacy: privacy)
        }

        /// A value, private unless `privacy` is `.public`.
        public mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .private) {
            append(String(describing: value), privacy: privacy)
        }

        /// An integer, public unless `privacy` is `.private`.
        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: LogPrivacy = .public) {
            append(String(value), privacy: privacy)
        }

        /// A floating-point number, public unless `privacy` is `.private`.
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, privacy: LogPrivacy = .public) {
            append(String(describing: value), privacy: privacy)
        }

        /// A floating-point number in `format`, public unless `privacy` is
        /// `.private`.
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, format: LogFloatFormat, privacy: LogPrivacy = .public) {
            switch format {
            case .fixed(let precision):
                append(String(format: "%.\(max(precision, 0))f", Double(value)), privacy: privacy)
            }
        }

        /// A Boolean, public unless `privacy` is `.private`.
        public mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .public) {
            append(value ? "true" : "false", privacy: privacy)
        }

        private mutating func append(_ string: String, privacy: LogPrivacy) {
            switch privacy {
            case .public:
                if case .text(let text)? = segments.last {
                    segments[segments.count - 1] = .text(text + string)
                } else {
                    segments.append(.text(string))
                }
            case .private:
                segments.append(.privateValue(string))
            }
        }
    }

    /// The message with each private value as `<private>`.
    public var redacted: String {
        var result = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                result += text
            case .privateValue:
                result += "<private>"
            }
        }
        return result
    }

    /// Writes the message to the unified log, its public text public and
    /// its private values private. `os.Logger` takes only messages whose
    /// shape is known when it's compiled, so text and private values
    /// alternate in one of four shapes, with up to three private values;
    /// with more, the third runs on to the end of the last one.
    func send(to logger: Logger, level: OSLogType) {
        var publicTexts = [""]
        var privateValues: [String] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                publicTexts[publicTexts.count - 1] += text
            case .privateValue(let value):
                if privateValues.count < 3 {
                    privateValues.append(value)
                } else {
                    privateValues[2] += publicTexts.removeLast() + value
                }
                publicTexts.append("")
            }
        }
        let texts = publicTexts
        let values = privateValues
        switch values.count {
        case 0:
            logger.log(level: level, "\(texts[0], privacy: .public)")
        case 1:
            logger.log(level: level, "\(texts[0], privacy: .public)\(values[0], privacy: .private)\(texts[1], privacy: .public)")
        case 2:
            logger.log(
                level: level,
                "\(texts[0], privacy: .public)\(values[0], privacy: .private)\(texts[1], privacy: .public)\(values[1], privacy: .private)\(texts[2], privacy: .public)"
            )
        default:
            logger.log(
                level: level,
                "\(texts[0], privacy: .public)\(values[0], privacy: .private)\(texts[1], privacy: .public)\(values[1], privacy: .private)\(texts[2], privacy: .public)\(values[2], privacy: .private)\(texts[3], privacy: .public)"
            )
        }
    }
}

/// A logger for one category of Espalier's subsystem
/// (`Log.logger(category:)`), with `os.Logger`'s levels: `trace` and
/// `debug` (the unified log only), `info`, `notice` and `log`, `warning`
/// and `error`, `critical` and `fault`.
public struct AppLogger: Sendable {
    public let category: String
    private let logger: Logger
    private let destination: LogDestination

    /// - Parameters:
    ///   - subsystem: The unified log's subsystem.
    ///   - category: The unified log's category, also in the file's lines.
    ///   - destination: Where info and above is mirrored.
    public init(subsystem: String, category: String, destination: LogDestination) {
        self.category = category
        logger = Logger(subsystem: subsystem, category: category)
        self.destination = destination
    }

    public func trace(_ message: @autoclosure () -> LogMessage) {
        write(.debug, message)
    }

    public func debug(_ message: @autoclosure () -> LogMessage) {
        write(.debug, message)
    }

    public func info(_ message: @autoclosure () -> LogMessage) {
        write(.info, message)
    }

    public func notice(_ message: @autoclosure () -> LogMessage) {
        write(.default, message)
    }

    public func log(_ message: @autoclosure () -> LogMessage) {
        write(.default, message)
    }

    public func log(level: OSLogType, _ message: @autoclosure () -> LogMessage) {
        write(level, message)
    }

    public func warning(_ message: @autoclosure () -> LogMessage) {
        write(.error, message)
    }

    public func error(_ message: @autoclosure () -> LogMessage) {
        write(.error, message)
    }

    public func critical(_ message: @autoclosure () -> LogMessage) {
        write(.fault, message)
    }

    public func fault(_ message: @autoclosure () -> LogMessage) {
        write(.fault, message)
    }

    /// Builds the message only when the unified log or the file takes it.
    private func write(_ level: OSLogType, _ message: () -> LogMessage) {
        let file = level == .debug ? nil : destination.file
        let isEnabled = logger.isEnabled(type: level)
        guard isEnabled || file != nil else {
            return
        }
        let message = message()
        if isEnabled {
            message.send(to: logger, level: level)
        }
        file?.append(LogEntry(date: Date(), level: LogEntry.levelName(level), category: category, message: message.redacted))
    }
}

/// Where loggers mirror info and above: the rolling log file, once one is
/// set.
public final class LogDestination: Sendable {
    private let current = Mutex<RollingLogFile?>(nil)

    public init() {}

    /// The file messages go to; nil writes none.
    public var file: RollingLogFile? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}
