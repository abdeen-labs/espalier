// Ported from desktop/app/src/lib/git/credential.ts

import EspalierSupport
import Foundation

/// A credential in git's credential helper format: `key=value` attributes in
/// the order git (or a helper) sent them.
///
/// Array attributes (`wwwauth[]`, `capability[]`) are stored as numbered
/// keys, `wwwauth[0]`, `wwwauth[1]`, and so on; see `parseCredential`.
public struct GitCredential: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// The attributes, in insertion order.
    public private(set) var entries: [Entry]

    public init(_ entries: [(String, String)] = []) {
        self.entries = []
        for (key, value) in entries {
            self[key] = value
        }
    }

    /// The value for `key`. Setting a value for an existing key keeps its
    /// position, as a JavaScript `Map` does; setting `nil` deletes it.
    public subscript(key: String) -> String? {
        get {
            entries.first { JSCompat.strictEquals($0.key, key) }?.value
        }
        set {
            let index = entries.firstIndex { JSCompat.strictEquals($0.key, key) }
            switch (index, newValue) {
            case (let index?, let value?):
                entries[index].value = value
            case (let index?, nil):
                entries.remove(at: index)
            case (nil, let value?):
                entries.append(Entry(key: key, value: value))
            case (nil, nil):
                break
            }
        }
    }

    /// Whether `key` has a value.
    public func has(_ key: String) -> Bool {
        self[key] != nil
    }
}

/// A credential value contains a newline or NUL, which git's credential
/// format can't carry.
public struct ForbiddenCredentialCharactersError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let key: String

    public init(key: String) {
        self.key = key
    }

    public var description: String { "forbidden characters in credential value: \(key)" }
    public var errorDescription: String? { description }
}

/// `git credential` failed. The message is git's standard error.
public struct GitCredentialCommandError: Error, CustomStringConvertible, LocalizedError {
    public let message: String

    public var description: String { message }
    public var errorDescription: String? { message }
}

public func parseCredential(_ value: String) -> GitCredential {
    var cred = GitCredential()

    // The credential helper protocol is a simple key=value format but some of
    // its keys are actually arrays which are represented as multiple key[]
    // entries. Since we're currently storing credentials as a Map we need to
    // handle this and expand multiple key[] entries into a key[0], key[1]...
    // key[n] sequence. We then remove the number from the key when we're
    // formatting the credential
    //
    // Lines split on `/\r?\n/`. Swift reads "\r\n" as one Character, so this
    // works on Unicode scalars.
    for rawLine in value.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = rawLine
        if line.last == "\r" {
            line.removeLast()
        }
        guard let eqIx = line.firstIndex(of: "=") else {
            continue
        }

        let k = String(String.UnicodeScalarView(line[..<eqIx]))
        let v = String(String.UnicodeScalarView(line[line.index(after: eqIx)...]))

        if k.unicodeScalars.reversed().starts(with: "][".unicodeScalars) {
            let base = String(k.unicodeScalars.dropLast(2))
            var i = 0
            var newKey: String
            repeat {
                newKey = "\(base)[\(i)]"
                i += 1
            } while cred.has(newKey)

            cred[newKey] = v
        } else {
            cred[k] = v
        }
    }

    return cred
}

public func formatCredential(_ credential: GitCredential) throws(ForbiddenCredentialCharactersError) -> String {
    var lines: [String] = []
    for entry in credential.entries {
        if entry.value.unicodeScalars.contains("\n") || entry.value.unicodeScalars.contains("\0") {
            throw ForbiddenCredentialCharactersError(key: entry.key)
        }
        lines.append("\(unnumberedKey(entry.key))=\(entry.value)\n")
    }

    return lines.joined()
}

/// `key` with a trailing `[<digits>]` replaced by `[]`.
private func unnumberedKey(_ key: String) -> String {
    var scalars = Array(key.unicodeScalars)
    guard scalars.last == "]" else { return key }
    var index = scalars.count - 2
    while index >= 0, ("0"..."9").contains(scalars[index]) {
        index -= 1
    }
    guard index >= 0, index < scalars.count - 2, scalars[index] == "[" else { return key }
    scalars.replaceSubrange(index..., with: "[]".unicodeScalars)
    return String(String.UnicodeScalarView(scalars))
}

// Can't use git() as that will call withTrampolineEnv which calls this method
private func exec(
    _ cmd: String,
    _ cred: GitCredential,
    _ path: String,
    _ env: [String: String?]
) async throws -> GitCredential {
    var environment: [String: String?] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "",
        "TERM": "dumb",
    ]
    environment.merge(env) { $1 }

    let result = try await Dugite.exec(
        [
            "-c", "credential.helper=",
            "-c", "credential.helper=manager",
            "credential",
            cmd,
        ],
        path,
        options: Dugite.ExecutionOptions(env: environment, stdin: Data(try formatCredential(cred).utf8))
    )
    if result.exitCode != 0 {
        throw GitCredentialCommandError(message: String(decoding: result.stderr, as: UTF8.self))
    }
    return parseCredential(String(decoding: result.stdout, as: UTF8.self))
}

/// Runs `git credential fill` against Git Credential Manager (the bundled
/// `git-credential-manager`). Throws `GitCredentialCommandError` when git
/// fails, for example because no credential was found and prompting isn't
/// allowed.
public func fillCredential(_ cred: GitCredential, _ path: String, _ env: [String: String?] = [:]) async throws -> GitCredential {
    try await exec("fill", cred, path, env)
}

/// Runs `git credential approve` against Git Credential Manager.
@discardableResult
public func approveCredential(_ cred: GitCredential, _ path: String, _ env: [String: String?] = [:]) async throws -> GitCredential {
    try await exec("approve", cred, path, env)
}

/// Runs `git credential reject` against Git Credential Manager.
@discardableResult
public func rejectCredential(_ cred: GitCredential, _ path: String, _ env: [String: String?] = [:]) async throws -> GitCredential {
    try await exec("reject", cred, path, env)
}
