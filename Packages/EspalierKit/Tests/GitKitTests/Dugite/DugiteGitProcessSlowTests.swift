// Ported from dugite/test/slow/git-process-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing

@Suite("git-process")
struct DugiteGitProcessSlowTests {
    @Suite("clone")
    struct Clone {
        @Test("returns exit code and error when repository requires credentials")
        func returnsExitCodeAndErrorWhenRepositoryRequiresCredentials() async throws {
            let testRepoPath = try createTestDir("desktop-git-test-blank")
            let options = Dugite.ExecutionOptions(env: [
                "GIT_CONFIG_PARAMETERS": "'credential.helper='",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_ASKPASS": nil,
            ])

            try await withUnauthorizedServer { port in
                let result = try await Dugite.exec(
                    ["clone", "--", "http://foo:bar@127.0.0.1:\(port)/", "."],
                    testRepoPath,
                    options: options
                )
                try verify(result) { r in
                    try #require(r.exitCode == 128)
                }

                let error = Dugite.parseError(String(decoding: result.stderr, as: UTF8.self))
                #expect(error == .httpsAuthenticationFailed)
            }
        }
    }
}

// MARK: - A server that requires credentials

/// Runs `body` while a local HTTP server answers every request with
/// `401 Unauthorized` and a Basic challenge. The server listens on a free
/// port on the loopback interface, which `body` receives, and stops when
/// `body` returns.
private func withUnauthorizedServer<T>(_ body: (_ port: UInt16) async throws -> T) async throws -> T {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw currentPOSIXError() }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(fd, SOMAXCONN) == 0 else {
        let error = currentPOSIXError()
        close(fd)
        throw error
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &boundAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard named == 0 else {
        let error = currentPOSIXError()
        close(fd)
        throw error
    }
    let port = UInt16(bigEndian: boundAddress.sin_port)

    // Accept without blocking, whenever connections are pending.
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "UnauthorizedServer"))
    source.setEventHandler {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global().async {
                respondUnauthorized(client)
            }
        }
    }
    source.setCancelHandler {
        close(fd)
    }
    source.resume()
    defer { source.cancel() }

    return try await body(port)
}

/// Reads one request from `client`, answers it with `401 Unauthorized`, and
/// closes the connection.
private func respondUnauthorized(_ client: Int32) {
    defer { close(client) }

    // Accepted sockets inherit the listener's O_NONBLOCK on macOS.
    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    // Git's requests here are GETs, so the request ends with its headers.
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while request.range(of: Data("\r\n\r\n".utf8)) == nil {
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        request.append(contentsOf: buffer[0..<count])
    }

    let response = Array((
        "HTTP/1.1 401 Unauthorized\r\n"
            + "Content-Type: text/plain\r\n"
            + "WWW-Authenticate: Basic realm=\"foo\"\r\n"
            + "Content-Length: 0\r\n"
            + "Connection: close\r\n"
            + "\r\n"
    ).utf8)
    var written = 0
    while written < response.count {
        let count = response[written...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        guard count > 0 else { return }
        written += count
    }
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
