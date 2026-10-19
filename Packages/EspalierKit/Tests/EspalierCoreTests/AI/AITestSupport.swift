// Helpers for the AI tests (providers, commit messages, conflict
// resolution). `MockAIProvider` is a trimmed copy of AIKit's test server
// (Tests/AIKitTests/Support/MockServer.swift): an OpenAI-compatible server
// behind a `URLProtocol`, so AIKit's real request, streaming, and error
// code runs and nothing reaches the network.

import AIKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Observation
import Synchronization
import Testing
import TestSupport

// MARK: - The mock provider

/// A request the mock provider received.
struct AIRequestRecord: Sendable {
    let url: URL
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data

    private var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    private var messages: [[String: Any]] {
        json["messages"] as? [[String: Any]] ?? []
    }

    /// The system prompt (Chat Completions).
    var systemPrompt: String {
        messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
    }

    /// The user prompt (Chat Completions).
    var userPrompt: String {
        messages.first { $0["role"] as? String == "user" }?["content"] as? String ?? ""
    }

    var isStreaming: Bool {
        json["stream"] as? Bool ?? false
    }

    var model: String? {
        json["model"] as? String
    }

    /// The files a conflict resolution prompt asks about, in order: each
    /// path with its number of conflicts, or nil for a delete-vs-modify
    /// conflict.
    var conflictFiles: [(path: String, hunks: Int?)] {
        var files: [(path: String, hunks: Int?)] = []
        for line in userPrompt.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## File: ") {
                let name = String(line.dropFirst("## File: ".count))
                let suffix = " (delete-vs-modify conflict)"
                if name.hasSuffix(suffix) {
                    files.append((String(name.dropLast(suffix.count)), nil))
                } else {
                    files.append((name, 0))
                }
            } else if line.hasPrefix("### Conflict "), let last = files.last, let count = last.hunks {
                files[files.count - 1] = (last.path, count + 1)
            }
        }
        return files
    }
}

/// How the mock provider answers a request.
enum AIMockReply: Sendable {
    /// A Chat Completions response whose content is the commit message JSON.
    case commitMessage(title: String, description: String)
    /// A Chat Completions response with this content.
    case content(String)
    /// An event stream: the reasoning, then the content.
    case stream(reasoning: [String], content: String)
    /// An event stream with the reasoning, then nothing until the request
    /// is cancelled.
    case streamThenHang(reasoning: [String])
    /// An error response.
    case error(status: Int, body: String, headers: [String: String] = [:])
    /// No response until the request is cancelled.
    case hang
    /// This reply, once the test calls `MockAIProvider.releaseDeferred()`.
    indirect case deferred(AIMockReply)
}

/// An OpenAI-compatible provider for one test, at its own `https://*.test`
/// host, answering through `handler`.
final class MockAIProvider: Sendable {
    typealias Handler = @Sendable (AIRequestRecord) -> AIMockReply

    private struct State {
        var handler: Handler
        var requests: [AIRequestRecord] = []
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var stoppedCount = 0
        var deferred: [@Sendable () -> Void] = []
    }

    let host: String
    let session: URLSession
    private let state: Mutex<State>

    init(handler: @escaping Handler = { _ in .error(status: 500, body: #"{"error":{"message":"No reply"}}"#) }) {
        host = "ai-\(UUID().uuidString.lowercased()).test"
        state = Mutex(State(handler: handler))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAIURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        MockAIURLProtocol.register(self, for: host)
    }

    deinit {
        MockAIURLProtocol.unregister(host)
        session.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
    }

    /// The provider's base URL.
    var baseURL: String {
        "https://\(host)/v1"
    }

    /// Answers every later request with `handler`.
    func answer(_ handler: @escaping Handler) {
        state.withLock { $0.handler = handler }
    }

    var requests: [AIRequestRecord] {
        state.withLock { $0.requests }
    }

    /// How many requests were cancelled or finished early.
    var stoppedCount: Int {
        state.withLock { $0.stoppedCount }
    }

    /// Waits until `count` requests have arrived.
    func waitForRequests(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state in
                if state.requests.count >= count {
                    return true
                }
                state.waiters.append((count, continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    fileprivate func receive(_ request: AIRequestRecord) -> AIMockReply {
        let (handler, ready) = state.withLock { state in
            state.requests.append(request)
            let received = state.requests.count
            let ready = state.waiters.filter { $0.count <= received }.map(\.continuation)
            state.waiters.removeAll { $0.count <= received }
            return (state.handler, ready)
        }
        for continuation in ready {
            continuation.resume()
        }
        return handler(request)
    }

    fileprivate func recordStop() {
        state.withLock { $0.stoppedCount += 1 }
    }

    fileprivate func addDeferred(_ delivery: @escaping @Sendable () -> Void) {
        state.withLock { $0.deferred.append(delivery) }
    }

    /// Sends the deferred replies.
    func releaseDeferred() {
        let deliveries = state.withLock { state in
            defer { state.deferred = [] }
            return state.deferred
        }
        for delivery in deliveries {
            delivery()
        }
    }
}

/// Answers requests for registered mock providers.
final class MockAIURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Weak {
        weak var provider: MockAIProvider?
    }

    private static let providers = Mutex<[String: Weak]>([:])

    static func register(_ provider: MockAIProvider, for host: String) {
        providers.withLock { $0[host] = Weak(provider: provider) }
    }

    static func unregister(_ host: String) {
        providers.withLock { _ = $0.removeValue(forKey: host) }
    }

    private static func provider(for url: URL) -> MockAIProvider? {
        guard let host = url.host(percentEncoded: false) else {
            return nil
        }
        return providers.withLock { $0[host]?.provider }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let provider = Self.provider(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var headers: [String: String] = [:]
        for (field, value) in request.allHTTPHeaderFields ?? [:] {
            headers[field.lowercased()] = value
        }
        let reply = provider.receive(AIRequestRecord(url: url, headers: headers, body: readBody()))
        if case .deferred(let later) = reply {
            provider.addDeferred { [self] in
                self.respond(later, url: url)
            }
            return
        }
        respond(reply, url: url)
    }

    private func respond(_ reply: AIMockReply, url: URL) {
        let status: Int
        let contentType: String
        var extraHeaders: [String: String] = [:]
        let body: Data
        var finishes = true
        switch reply {
        case .hang, .deferred:
            return
        case .streamThenHang(let reasoning):
            status = 200
            contentType = "text/event-stream"
            body = Data(reasoning.map { streamEvent(["reasoning_content": $0]) }.joined().utf8)
            finishes = false
        case .commitMessage(let title, let description):
            status = 200
            contentType = "application/json"
            body = chatCompletion(content: jsonString(["title": title, "description": description]))
        case .content(let content):
            status = 200
            contentType = "application/json"
            body = chatCompletion(content: content)
        case .stream(let reasoning, let content):
            status = 200
            contentType = "text/event-stream"
            var events = reasoning.map { streamEvent(["reasoning_content": $0]) }
            events.append(streamEvent(["content": content]))
            events.append("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n")
            events.append("data: [DONE]\n\n")
            body = Data(events.joined().utf8)
        case .error(let errorStatus, let errorBody, let headers):
            status = errorStatus
            contentType = "application/json"
            extraHeaders = headers
            body = Data(errorBody.utf8)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType].merging(extraHeaders) { _, new in new }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if let url = request.url {
            Self.provider(for: url)?.recordStop()
        }
    }

    private func chatCompletion(content: String) -> Data {
        let object: [String: Any] = [
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func streamEvent(_ delta: [String: String]) -> String {
        "data: \(jsonString(["choices": [["index": 0, "delta": delta]]]))\n\n"
    }

    private func readBody() -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// `value` as JSON text.
func jsonString(_ value: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

extension Result {
    /// The error, when it failed.
    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}

// MARK: - Conflict resolution replies

/// A conflict resolution response resolving every file the request asks
/// about: hunk `i` of a file becomes `content(path, i)`, and a
/// delete-vs-modify conflict gets `actions[path]` (keep by default).
func conflictResolutionReply(
    for request: AIRequestRecord,
    reasoning: [String] = ["Looking at what each side changed in these files. Both sides add lines that can be kept."],
    actions: [String: String] = [:],
    content: (String, Int) -> String = { path, hunk in "resolved \(path) \(hunk)" }
) -> AIMockReply {
    let resolutions: [[String: Any]] = request.conflictFiles.map { file in
        if let hunks = file.hunks {
            return [
                "path": file.path,
                "hunks": (0..<hunks).map { ["resolvedContent": content(file.path, $0)] },
                "reasoning": "Combined both sides of \(file.path).",
            ]
        }
        return [
            "path": file.path,
            "action": actions[file.path] ?? "keep",
            "hunks": [Any](),
            "reasoning": "The modified file matters more than the deletion.",
        ]
    }
    let payload: [String: Any] = [
        "summary": "### Conflicting changes\nBoth sides changed the same lines.\n\n### Resolution\nKept both changes.",
        "references": [Any](),
        "resolutions": resolutions,
    ]
    return .stream(reasoning: reasoning, content: jsonString(payload))
}

/// A 401 that every request would get, which AIKit doesn't retry.
let authenticationFailure = AIMockReply.error(
    status: 401,
    body: #"{"error":{"message":"Incorrect API key provided."}}"#,
    headers: ["x-should-retry": "false"]
)

/// A server error, without retries.
let serverFailure = AIMockReply.error(
    status: 500,
    body: #"{"error":{"message":"The server had an error."}}"#,
    headers: ["x-should-retry": "false"]
)

// MARK: - Fixtures

/// A repository added to an app whose AI requests go to a mock provider,
/// and selected.
@MainActor
struct AIFixture {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    let local: Repository
    let server: MockAIProvider

    /// Prepares a repository with `prepare`, then adds it to a new app and
    /// selects it.
    static func make(
        server: MockAIProvider = MockAIProvider(),
        defaults: [String: Any] = [:],
        configure: (AppHarness) async throws -> Void = { _ in },
        _ prepare: (Repository) async throws -> Void
    ) async throws -> AIFixture {
        let local = try setupEmptyRepository("main")
        try await prepare(local)
        let harness = try AppHarness()
        for (key, value) in defaults {
            harness.defaults.defaults.set(value, forKey: key)
        }
        try await configure(harness)
        var environment = harness.environment
        environment.aiSession = server.session
        let app = AppModel(environment: environment)
        await app.load()
        await app.accounts.idle()
        let model = try await harness.addAndSelect(local, to: app)
        let fixture = AIFixture(harness: harness, app: app, model: model, local: local, server: server)
        await fixture.settle()
        return fixture
    }

    var ai: RepositoryAIModel {
        model.ai
    }

    /// Waits for refreshes, operations, and what follows them.
    func settle() async {
        await app.idle()
        await model.operations.enrichmentIdle()
        await model.changes.diffIdle()
        await app.idle()
    }

    /// Refreshes the status and waits for what follows.
    func refresh() async {
        await model.refresh(.status, reason: .user)
        await settle()
    }

    /// Adds a provider for the mock with `models`, its API key, its request
    /// timeout (nil for the default), and (unless `consent` is false) the
    /// consents of both features.
    @discardableResult
    func addProvider(models: [String] = ["test-model"], consent: Bool = true, requestTimeoutSeconds: Double? = nil) throws -> BYOKProvider {
        let provider = BYOKProvider(
            id: UUID().uuidString.lowercased(),
            name: "Test AI",
            type: .openai,
            baseUrl: server.baseURL,
            authKind: .apiKey,
            requestTimeoutSeconds: requestTimeoutSeconds,
            models: models.map { BYOKModel(id: $0, name: "Model \($0)") }
        )
        try app.ai.addProvider(provider, secret: .set("sk-test-key"))
        if consent {
            for feature in AIFeature.allCases {
                app.ai.recordConsent(getAIDataDisclosure(for: feature, provider: provider).consentIdentifier)
            }
        }
        return provider
    }

    func write(_ path: String, _ contents: String) throws {
        try harness.write(path, contents, in: local)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOfFile: POSIXPath.join(local.path, path), encoding: .utf8)
    }

    /// The branch named `name` as the last refresh loaded it.
    func branch(_ name: String) throws -> Branch {
        try #require(model.gitState.branches.all.first { $0.name == name }, "No branch \(name)")
    }

    /// Merges `branch` and waits for the conflicts it stops on.
    func mergeWithConflicts(_ branch: String) async throws {
        #expect(try await model.operations.merge(self.branch(branch)) == .conflicted)
        await settle()
        #expect(model.operations.conflictState != nil)
    }

    /// The index's stage numbers for `path` (empty when it isn't in the
    /// index; `[0]` once resolved).
    func indexStages(_ path: String) async throws -> [Int] {
        let output = try await runGit(["ls-files", "--stage", "--", path], local)
        return output.split(separator: "\n").compactMap { line in
            line.split(separator: " ").dropFirst(2).first.flatMap { Int($0.prefix(1)) }
        }
    }
}

/// Writes `files` (path to contents) and commits everything.
func commit(_ files: [String: String], _ message: String, in repository: Repository) async throws {
    for (path, contents) in files {
        let fullPath = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(filePath: fullPath))
    }
    try await runGit(["add", "-A"], repository)
    try await runGit(["commit", "-m", message], repository)
}

/// The message of an AI provider's failure, if the error is one.
func providerFailureMessage(_ error: OperationError?) -> String? {
    if case .ai(.provider(_, let message))? = error?.reason { message } else { nil }
}

/// Whether the error's only recovery opens Settings ▸ AI.
func opensAISettings(_ error: OperationError?) -> Bool {
    guard let recoveries = error?.recoveries, recoveries.count == 1, case .openSettings(.ai) = recoveries[0] else {
        return false
    }
    return true
}

/// Waits until `condition` holds, checking again whenever an observable
/// property it read changes (no polling).
@MainActor
func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

/// A repository whose `main` and `feature` branches change the same lines
/// of each file in `paths`, with `main` checked out: merging `feature`
/// conflicts in every one.
func prepareConflictingBranches(_ repository: Repository, paths: [String]) async throws {
    try await commit(Dictionary(uniqueKeysWithValues: paths.map { ($0, "first\nshared\nlast\n") }), "Initial commit", in: repository)
    try await runGit(["branch", "feature"], repository)
    try await commit(Dictionary(uniqueKeysWithValues: paths.map { ($0, "first\nmain side\nlast\n") }), "Change on main", in: repository)
    try await runGit(["checkout", "-q", "feature"], repository)
    try await commit(Dictionary(uniqueKeysWithValues: paths.map { ($0, "first\nfeature side\nlast\n") }), "Change on feature (#12)", in: repository)
    try await runGit(["checkout", "-q", "main"], repository)
}
