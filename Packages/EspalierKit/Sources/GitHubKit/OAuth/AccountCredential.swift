// Ported from desktop/app/src/lib/account-credential.ts

import Foundation

// This is the secure-store format for an account's OAuth credential, not the
// git credential trampoline: `AccountsStore` writes and reads every token
// through it.
//
// A credential with a refresh token or an expiry is stored as a versioned
// record, prefixed `espalier-oauth:`, so a token's expiry is remembered. A
// versioned record needs a refresh token or an expiry; one with neither is
// rejected. A record of a version other than 1 is rejected as one this build
// doesn't know (`isUnknownVersion`).

private let prefix = "espalier-oauth:"

/// A `nil` credential represents missing or previously invalidated credentials.
public typealias AccountCredential = OAuthToken?

/// Store the entire credential in one secure-store item.
public func serializeAccountCredential(_ credential: AccountCredential) -> String {
    if let credential, credential.refreshToken == nil, credential.expiresAt == nil {
        return credential.accessToken
    }

    var record: [String: JSONValue] = ["version": 1]
    if let credential {
        var fields: [String: JSONValue] = ["accessToken": .string(credential.accessToken)]
        if let refreshToken = credential.refreshToken {
            fields["refreshToken"] = .string(refreshToken)
        }
        if let expiresAt = credential.expiresAt {
            fields["expiresAt"] = .number(Double(expiresAt))
        }
        if let refreshTokenExpiresAt = credential.refreshTokenExpiresAt {
            fields["refreshTokenExpiresAt"] = .number(Double(refreshTokenExpiresAt))
        }
        record["credential"] = .object(fields)
    } else {
        record["credential"] = .null
    }

    let json = (try? JSONValue.object(record).serialized()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return prefix + json
}

/// The stored credential could not be read.
public struct AccountCredentialError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    /// Whether the credential is a well-formed record of a version this
    /// build doesn't know, rather than a broken one.
    public let isUnknownVersion: Bool

    public init(isUnknownVersion: Bool = false) {
        self.isUnknownVersion = isUnknownVersion
    }

    public var message: String { "Couldn't read this account's saved credentials. Sign in again." }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Read legacy tokens and versioned credentials without exposing malformed data.
public func deserializeAccountCredential(_ value: String?) throws -> AccountCredential {
    guard let value, !value.isEmpty else {
        return nil
    }
    guard value.hasPrefix(prefix) else {
        return OAuthToken(accessToken: value)
    }

    // Never include the secure-store contents in an exception.
    guard let record = try? JSONValue.parse(Data(value.dropFirst(prefix.count).utf8)), record.isRecord else {
        throw AccountCredentialError()
    }
    guard record["version"] == .number(1) else {
        if case .number? = record["version"] {
            throw AccountCredentialError(isUnknownVersion: true)
        }
        throw AccountCredentialError()
    }
    guard let credential = record["credential"] else {
        throw AccountCredentialError()
    }

    if credential == .null {
        return nil
    }

    let refreshToken = credential["refreshToken"]
    guard credential.isRecord,
          isToken(credential["accessToken"]),
          refreshToken == nil || isToken(refreshToken),
          case .string(let accessToken)? = credential["accessToken"]
    else {
        throw AccountCredentialError()
    }

    let expiresAt = try validExpiry(credential["expiresAt"])
    let refreshTokenExpiresAt = try validExpiry(credential["refreshTokenExpiresAt"])
    guard refreshToken != nil || expiresAt != nil else {
        throw AccountCredentialError()
    }

    return OAuthToken(
        accessToken: accessToken,
        refreshToken: refreshToken?.stringValue,
        expiresAt: expiresAt,
        refreshTokenExpiresAt: refreshTokenExpiresAt
    )
}

/// An optional expiry: absent, or a non-negative safe integer.
private func validExpiry(_ value: JSONValue?) throws -> Int64? {
    guard let value else {
        return nil
    }
    guard case .number(let number) = value, isSafeInteger(number), number >= 0 else {
        throw AccountCredentialError()
    }
    return Int64(number)
}
