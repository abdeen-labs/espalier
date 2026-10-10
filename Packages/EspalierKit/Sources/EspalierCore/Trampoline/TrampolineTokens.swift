// Ported from desktop/app/src/lib/trampoline/trampoline-tokens.ts

import Foundation

/// `TrampolineServer` keeps the tokens with the handler registered for each,
/// so a request maps back to the git invocation that received the token.
/// This type only makes them.
enum TrampolineTokens {
    /// A new token: 32 bytes from the system's cryptographically secure
    /// generator, as 64 hexadecimal digits.
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            .map { byte in
                let hex = String(byte, radix: 16)
                return hex.count == 1 ? "0" + hex : hex
            }
            .joined()
    }
}

extension TrampolineServer {
    /// Allows invoking a function with a short-lived trampoline token that
    /// will be revoked right after the function finishes. Requests that
    /// present the token go to `handler`.
    ///
    /// - Parameter fn: Function to invoke with the trampoline token. It runs
    ///   on the caller's executor, not the server's.
    nonisolated func withTrampolineToken<T>(
        _ handler: any TrampolineCommandHandler,
        _ fn: (String) async throws -> T
    ) async throws -> T {
        let token = await register(handler)
        do {
            let result = try await fn(token)
            await revoke(token)
            return result
        } catch {
            await revoke(token)
            throw error
        }
    }
}
