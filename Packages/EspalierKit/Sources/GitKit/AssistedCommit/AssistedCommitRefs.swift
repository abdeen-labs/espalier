// Ported from desktop/app/src/lib/git/update-ref.ts
// (updateRefWithVerification and withRefLock).

import EspalierSupport
import Foundation
import Synchronization

/// A one-shot flag that closures can share.
final class AssistedFlag: Sendable {
    private let state = Mutex(false)

    func set() {
        state.withLock { $0 = true }
    }

    var isSet: Bool {
        state.withLock { $0 }
    }
}

/// Compare-and-swap of `ref`, checked while git holds its lock (and HEAD's
/// lock when HEAD names it): `git update-ref --stdin` prepares the
/// transaction, `verify` runs, and the transaction commits only when
/// `verify` passes. A HEAD switched to another branch at the same commit
/// can't slip between the check and the update.
///
/// The ref is updated as it is (`no-deref`). A nil `newValue` deletes it
/// while it's at `oldValue`; a zero `oldValue` creates it.
///
/// Runs through `Dugite.spawn`, since the transaction needs its standard
/// input open while `verify` runs, which `git()` doesn't keep. Nothing here
/// needs the trampoline, and git runs `reference-transaction` hooks itself.
func assistedUpdateRef(
    _ root: String,
    ref: String,
    oldValue: String,
    newValue: String?,
    reason: String,
    verify: @Sendable () async throws -> Void
) async throws {
    let command: String
    if let newValue {
        command = "update \(ref)\0\(newValue)\0\(oldValue)\0"
    } else {
        command = "delete \(ref)\0\(oldValue)\0"
    }
    let child = try Dugite.spawn(
        ["update-ref", "-m", reason, "--stdin", "-z"],
        root,
        env: ["TERM": "dumb"],
        pipesStandardInput: true
    )
    let output = AssistedRefTransactionOutput()
    child.observeStandardOutput { output.appendStandardOutput($0) }
    child.observeStandardError { output.appendStandardError($0) }
    child.onClose { output.close() }
    child.startReading()

    var prepared = false
    var verificationError: (any Error)?
    do {
        try await child.writeToStandardInput(Data("start\0option no-deref\0\(command)prepare\0".utf8))
        prepared = await output.waitUntilPrepared()
        if prepared {
            do {
                try await verify()
            } catch {
                verificationError = error
            }
            try await child.writeToStandardInput(Data((verificationError == nil ? "commit\0" : "abort\0").utf8))
        }
    } catch {
        verificationError = verificationError ?? error
    }
    child.closeStandardInput()
    let termination = await child.waitUntilExit()

    if let verificationError {
        throw verificationError
    }
    let (stdout, stderr) = output.snapshot()
    guard prepared, termination == .exit(0), stdout.contains("commit: ok") else {
        throw AssistedCommitError(
            .repositoryChanged,
            "Git couldn't update \(ref): it changed during the assisted commit.",
            underlying: GitLibError(stderr.isEmpty ? stdout : stderr)
        )
    }
}

/// What `git update-ref --stdin` writes, and whether it prepared.
private final class AssistedRefTransactionOutput: Sendable {
    private struct State {
        var stdout = Data()
        var stderr = Data()
        var prepared: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    func appendStandardOutput(_ chunk: Data) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.stdout.append(chunk)
            guard state.prepared == nil, String(decoding: state.stdout, as: UTF8.self).contains("prepare: ok\n") else {
                return nil
            }
            state.prepared = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: true)
    }

    func appendStandardError(_ chunk: Data) {
        state.withLock { $0.stderr.append(chunk) }
    }

    /// Git exited (or closed its output) without preparing.
    func close() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.prepared == nil else {
                return nil
            }
            state.prepared = false
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: false)
    }

    func waitUntilPrepared() async -> Bool {
        await withCheckedContinuation { continuation in
            let prepared = state.withLock { state -> Bool? in
                if let prepared = state.prepared {
                    return prepared
                }
                state.waiter = continuation
                return nil
            }
            if let prepared {
                continuation.resume(returning: prepared)
            }
        }
    }

    func snapshot() -> (stdout: String, stderr: String) {
        state.withLock { (String(decoding: $0.stdout, as: UTF8.self), String(decoding: $0.stderr, as: UTF8.self)) }
    }
}

/// Runs `action` holding HEAD's lock and the updated ref's lock, as git
/// holds them while it updates them, after checking the ref is at
/// `expectedValue` (nil: unborn). For changes that aren't ref updates (the
/// index) that must not race one.
func assistedWithRefLock<T: Sendable>(
    _ identity: AssistedRepositoryIdentity,
    expectedValue: String?,
    _ action: @Sendable () async throws -> T
) async throws -> T {
    let ref = identity.updatedRef
    let names = ref == "HEAD" ? ["HEAD"] : ["HEAD", ref]
    var locks: [AssistedLockFile] = []
    let outcome: Result<T, any Error>
    do {
        for name in names {
            let path = try await assistedGitPath(identity.root, name) + ".lock"
            try assistedMakeDirectories(POSIXPath.dirname(path))
            locks.append(try AssistedLockFile.acquire(path))
        }
        let current = try await git(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"],
            identity.root,
            "assistedCommitLockedRefValue",
            options: GitExecutionOptions(successExitCodes: [0, 1])
        )
        let actual = current.exitCode == 0 ? assistedTrimLine(current.stdout) : nil
        guard actual == expectedValue else {
            throw AssistedCommitError(.repositoryChanged, "The branch moved during the assisted commit.")
        }
        outcome = .success(try await action())
    } catch {
        outcome = .failure(error)
    }
    var cleanupError: (any Error)?
    for lock in locks.reversed() {
        do {
            try lock.release()
        } catch {
            cleanupError = cleanupError ?? error
        }
    }
    let value = try outcome.get()
    if let cleanupError {
        throw AssistedCommitError(.cleanupFailed, "Espalier couldn't remove its lock on the branch.", underlying: cleanupError)
    }
    return value
}
