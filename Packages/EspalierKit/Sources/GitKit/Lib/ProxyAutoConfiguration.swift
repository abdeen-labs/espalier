// Ported in part from Chromium's net/proxy_resolution/pac_file_decider.cc
// and pac_file_fetcher_impl.cc: where proxy auto-configuration scripts come
// from (automatic discovery's `http://wpad/wpad.dat`, a PAC file's URL, or
// the settings), how a PAC file is fetched, and running a script with
// CFNetwork. Fetched scripts are kept for a few minutes, so a burst of git
// operations fetches the file once rather than once per resolution.

import CFNetwork
import Darwin
import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "proxy")

/// How proxy auto-configuration runs.
struct ProxyAutoConfigurationOptions: Sendable {
    /// How long fetching a PAC file may take, and then running it.
    var timeout: TimeInterval = 10
    /// Where automatic proxy discovery looks for a PAC file.
    var discoveryURL = URL(string: "http://wpad/wpad.dat")!
    /// How long automatic discovery waits for its host to resolve before
    /// giving up on it, so a network without one doesn't stall each
    /// resolution (`PacFileDecider`'s quick check).
    var discoveryQuickCheck: TimeInterval = 1
    /// The fetched scripts.
    var scripts: PACScriptCache = .shared
}

/// Where a proxy auto-configuration script comes from.
enum ProxyAutoConfigurationSource: Sendable {
    /// Automatic proxy discovery, at this URL.
    case discovery(URL)
    /// A PAC file's URL.
    case url(URL)
    /// A script in the settings.
    case script(String)

    enum Load: Sendable {
        /// The script to run.
        case script(String)
        /// A URL only CFNetwork reads (not http or https), to run with it.
        case unfetched(URL)
        case failed(String)
    }

    /// Loads the script: fetches a PAC file, or for automatic discovery,
    /// first checks that its host resolves. Like Chromium, a script that
    /// doesn't define `FindProxyForURL` doesn't count.
    func load(options: ProxyAutoConfigurationOptions) async -> Load {
        let script: String
        switch self {
        case .discovery(let url):
            guard let host = url.host() else {
                return .failed("automatic proxy discovery has no host in \(url.absoluteString)")
            }
            // An IP address needs no lookup.
            if IPAddress(literal: host) == nil {
                guard await hostResolves(host, within: options.discoveryQuickCheck) else {
                    return .failed("automatic proxy discovery found no host for \(url.absoluteString)")
                }
            }
            do {
                script = try await options.scripts.script(at: url, timeout: options.timeout)
            } catch {
                return .failed("\(url.absoluteString): \(error)")
            }
        case .url(let url):
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return .unfetched(url)
            }
            do {
                script = try await options.scripts.script(at: url, timeout: options.timeout)
            } catch {
                return .failed("\(url.absoluteString): \(error)")
            }
        case .script(let text):
            script = text
        }
        guard script.contains("FindProxyForURL") else {
            return .failed("the script doesn't define FindProxyForURL")
        }
        return .script(script)
    }
}

// MARK: - Fetching PAC files

/// Why a PAC file couldn't be fetched.
enum PACFileFetchError: Error, CustomStringConvertible {
    case status(Int)
    case tooLarge
    case notHTTP

    var description: String {
        switch self {
        case .status(let status):
            "the server answered \(status)"
        case .tooLarge:
            "the file is larger than 1 MB"
        case .notHTTP:
            "not an HTTP response"
        }
    }
}

/// PAC files fetched over http and https, by URL, each kept for
/// `lifetime` after it's fetched. Failures aren't kept, so the next
/// resolution tries again. Safe to use from any task.
final class PACScriptCache: Sendable {
    static let shared = PACScriptCache()

    /// How long a fetched script is used before it's fetched again.
    static let defaultLifetime: TimeInterval = 5 * 60

    /// The largest PAC file read (`kDefaultMaxResponseBytes`).
    static let maximumSize = 1_048_576

    private struct Entry {
        var script: String
        var fetched: Date
    }

    let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let entries = Mutex<[String: Entry]>([:])

    init(lifetime: TimeInterval = defaultLifetime, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifetime = lifetime
        self.now = now
    }

    /// The script at `url`: the one fetched within `lifetime`, or a fresh
    /// fetch.
    func script(at url: URL, timeout: TimeInterval) async throws -> String {
        let key = url.absoluteString
        let cached: String? = entries.withLock { entries in
            guard let entry = entries[key] else {
                return nil
            }
            let age = now().timeIntervalSince(entry.fetched)
            guard age >= 0, age < lifetime else {
                entries[key] = nil
                return nil
            }
            return entry.script
        }
        if let cached {
            return cached
        }
        let script = try await Self.fetch(url, timeout: timeout)
        let fetched = now()
        entries.withLock { $0[key] = Entry(script: script, fetched: fetched) }
        return script
    }

    /// Fetches a PAC file as Chromium's `PacFileFetcherImpl` does: directly
    /// (never through a proxy), without caches or credentials, at most
    /// 1 MB, only a 200 answer, and decoded with the response's character
    /// set, else its byte order mark, else ISO-8859-1.
    static func fetch(_ url: URL, timeout: TimeInterval) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw PACFileFetchError.notHTTP
        }
        guard response.statusCode == 200 else {
            throw PACFileFetchError.status(response.statusCode)
        }
        if response.expectedContentLength > Int64(maximumSize) {
            throw PACFileFetchError.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumSize {
                throw PACFileFetchError.tooLarge
            }
        }
        return decode(data, charset: response.textEncodingName)
    }

    /// A PAC file's text (`ConvertResponseToUTF16`): in its character set,
    /// with invalid bytes replaced; without one, as its byte order mark
    /// says (UTF-16 or UTF-8, the mark removed), else ISO-8859-1.
    static func decode(_ data: Data, charset: String?) -> String {
        if let charset, !charset.isEmpty {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId {
                let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
                if stringEncoding == .utf8 {
                    return String(decoding: data, as: UTF8.self)
                }
                if let text = String(data: data, encoding: stringEncoding) {
                    return text
                }
            }
        }
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) ?? ""
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }
}

/// Whether `host` resolves within `timeout` seconds. The lookup runs on a
/// thread of its own, which finishes on its own if the time runs out.
func hostResolves(_ host: String, within timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let pending = PendingContinuation(continuation)
        let finish: @Sendable (Bool) -> Void = { resolved in
            pending.resume(returning: resolved)
        }
        let thread = Thread {
            var result: UnsafeMutablePointer<addrinfo>?
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result {
                freeaddrinfo(result)
            }
            finish(status == 0)
        }
        thread.name = "dev.abdeen.espalier.proxy-discovery"
        thread.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(false)
        }
    }
}

/// A continuation resumed by whichever of two threads finishes first.
private final class PendingContinuation: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning value: Bool) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }
}

// MARK: - Running scripts

/// A PAC file to run: at a URL, or a script.
enum ProxyAutoConfiguration: Sendable {
    case url(URL)
    case script(String)
}

/// A proxy auto-configuration didn't finish in time.
struct ProxyAutoConfigurationTimeoutError: Error, CustomStringConvertible {
    var description: String { "Proxy auto-configuration timed out" }
}

/// Runs a proxy auto-configuration with CFNetwork for `targetURL` and
/// returns the proxies it chose, as Chromium reads CFNetwork's answers
/// (`ProxyResolverApple`): entries it can't use are left out.
///
/// CFNetwork reports the result on a run loop, so this runs one on a thread
/// of its own, in a private mode, for at most `timeout` seconds. Cancelling
/// the task stops it.
func executeProxyAutoConfiguration(
    _ configuration: ProxyAutoConfiguration,
    for targetURL: URL,
    timeout: TimeInterval
) async throws -> [ProxyListEntry] {
    let execution = ProxyAutoConfigurationExecution()

    let dictionaries = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: execution.run(configuration, for: targetURL, timeout: timeout))
            }
            thread.name = "dev.abdeen.espalier.proxy-auto-configuration"
            thread.start()
        }
    } onCancel: {
        execution.cancel()
    }
    return dictionaries.compactMap { ProxyListEntry(cfNetwork: $0.values) }
}

/// A proxy dictionary CFNetwork returned, passed between threads.
struct CFNetworkProxy: @unchecked Sendable {
    let values: [String: Any]
}

/// One run of a proxy auto-configuration, on its own thread.
private final class ProxyAutoConfigurationExecution: Sendable {
    private struct State {
        var runLoop: RunLoopReference?
        var isCancelled = false
    }

    /// `CFRunLoopStop` may be called from any thread.
    private struct RunLoopReference: @unchecked Sendable {
        let runLoop: CFRunLoop
    }

    /// What the cancelling task and the run loop's thread share.
    private let state = Mutex(State())

    /// The run loop mode the source is scheduled in, so nothing else on the
    /// thread runs.
    private static let mode = CFRunLoopMode("dev.abdeen.espalier.proxy-auto-configuration" as CFString)

    func cancel() {
        let runLoop = state.withLock { state in
            state.isCancelled = true
            return state.runLoop
        }
        if let runLoop {
            CFRunLoopStop(runLoop.runLoop)
        }
    }

    private var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    /// Runs the configuration on the current thread's run loop.
    func run(
        _ configuration: ProxyAutoConfiguration,
        for targetURL: URL,
        timeout: TimeInterval
    ) -> Result<[CFNetworkProxy], any Error> {
        let outcome = Outcome()
        var context = CFStreamClientContext(
            version: 0,
            info: Unmanaged.passUnretained(outcome).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: CFProxyAutoConfigurationResultCallback = { info, proxies, error in
            let outcome = Unmanaged<Outcome>.fromOpaque(info).takeUnretainedValue()
            if let error {
                outcome.result = .failure(error as any Error)
            } else {
                let dictionaries = (proxies as NSArray) as? [[String: Any]] ?? []
                outcome.result = .success(dictionaries.map(CFNetworkProxy.init))
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        let source: CFRunLoopSource = switch configuration {
        case .url(let url):
            CFNetworkExecuteProxyAutoConfigurationURL(url as CFURL, targetURL as CFURL, callback, &context)
        case .script(let script):
            CFNetworkExecuteProxyAutoConfigurationScript(script as CFString, targetURL as CFURL, callback, &context)
        }

        let runLoop: CFRunLoop = CFRunLoopGetCurrent()
        let reference = RunLoopReference(runLoop: runLoop)
        state.withLock { $0.runLoop = reference }
        CFRunLoopAddSource(runLoop, source, Self.mode)

        let deadline = Date.now.addingTimeInterval(timeout)
        while outcome.result == nil, !isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }
            CFRunLoopRunInMode(Self.mode, remaining, false)
        }

        CFRunLoopRemoveSource(runLoop, source, Self.mode)
        CFRunLoopSourceInvalidate(source)
        state.withLock { $0.runLoop = nil }

        if let result = outcome.result {
            return result
        }
        if isCancelled {
            return .failure(CancellationError())
        }
        return .failure(ProxyAutoConfigurationTimeoutError())
    }

    /// The callback's result. Only the run loop's thread touches it.
    private final class Outcome: @unchecked Sendable {
        var result: Result<[CFNetworkProxy], any Error>?
    }
}
