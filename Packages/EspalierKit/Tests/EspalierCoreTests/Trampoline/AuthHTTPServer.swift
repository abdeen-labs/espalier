import Foundation
import Synchronization

/// A minimal HTTP server on 127.0.0.1 that requires HTTP Basic authentication
/// and serves one repository's refs over git's dumb HTTP protocol, which is
/// all `git ls-remote` needs. It answers every host it is asked for, so it
/// also works as the HTTP proxy for fake host names (`http_proxy`), and
/// records each request's `Authorization` header.
final class AuthHTTPServer: Sendable {
    struct Request: Sendable, Equatable {
        let method: String
        let target: String
        let host: String?
        let authorization: String?
    }

    /// The commit `refs/heads/main` points at.
    static let commit = "0123456789abcdef0123456789abcdef01234567"

    let port: UInt16
    private let source: any DispatchSourceRead
    private let shared: Shared

    private struct State {
        var username: String
        var password: String
        var realm: String
        var requests: [Request] = []
    }

    private final class Shared: Sendable {
        let state: Mutex<State>

        init(_ state: State) {
            self.state = Mutex(state)
        }
    }

    init(username: String, password: String, realm: String = "Espalier Test") throws {
        let shared = Shared(State(username: username, password: password, realm: realm))
        self.shared = shared

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 64) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        port = UInt16(bigEndian: address.sin_port)

        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "AuthHTTPServer"))
        source.setCancelHandler {
            close(descriptor)
        }
        source.setEventHandler {
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                DispatchQueue.global().async {
                    Self.serve(client, shared)
                }
            }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }

    /// The URL of the repository, `http://127.0.0.1:<port>/<path>`.
    func url(_ path: String = "repo.git") -> String {
        "http://127.0.0.1:\(port)/\(path)"
    }

    /// The server as an HTTP proxy, for `http_proxy`.
    var proxyURL: String {
        "http://127.0.0.1:\(port)"
    }

    var requests: [Request] {
        shared.state.withLock { $0.requests }
    }

    /// The `Authorization` headers git sent, in order.
    var authorizations: [String?] {
        requests.map(\.authorization)
    }

    func setCredentials(username: String, password: String) {
        shared.state.withLock {
            $0.username = username
            $0.password = password
        }
    }

    func stop() {
        source.cancel()
    }

    static func basic(_ username: String, _ password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private static func serve(_ client: Int32, _ shared: Shared) {
        defer { close(client) }
        let flags = fcntl(client, F_GETFL)
        _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var received = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator: [UInt8] = Array("\r\n\r\n".utf8)
        while !received.ends(with: terminator) {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            received.append(contentsOf: buffer[0..<count])
            if let range = received.firstRange(of: terminator) {
                received = Array(received[..<range.upperBound])
            }
        }

        let head = String(decoding: received, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let request = Request(method: requestLine[0], target: requestLine[1], host: headers["host"], authorization: headers["authorization"])
        let (expected, realm) = shared.state.withLock { state in
            state.requests.append(request)
            return (basic(state.username, state.password), state.realm)
        }

        let response: String
        if request.authorization != expected {
            response = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        } else if request.target.contains("/info/refs") {
            let body = "\(commit)\trefs/heads/main\n"
            response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        } else if request.target.hasSuffix("/HEAD") {
            let body = "ref: refs/heads/main\n"
            response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        } else {
            response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }

        let bytes = Array(response.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(client, $0.baseAddress! + offset, bytes.count - offset) }
            guard written > 0 else { return }
            offset += written
        }
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}
