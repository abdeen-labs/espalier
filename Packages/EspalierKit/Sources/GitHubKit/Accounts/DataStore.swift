// Ported from desktop/app/src/lib/stores/stores.ts

import Foundation
import Synchronization

/// The data-only interface for storage.
///
/// GitHubKit stores small, non-secret strings through it: the accounts list
/// (without tokens) and GitHub Enterprise Server versions. The app provides an
/// implementation backed by `UserDefaults` (EspalierCore's
/// `UserDefaultsDataStore`); tests use `InMemoryDataStore`. Secrets go to a
/// `SecretStore` instead.
public protocol DataStore: Sendable {
    func setItem(_ key: String, _ value: String)
    func getItem(_ key: String) -> String?
}

/// A `DataStore` held in memory, for tests and previews.
public final class InMemoryDataStore: DataStore {
    private let items = Mutex<[String: String]>([:])

    public init(_ items: [String: String] = [:]) {
        self.items.withLock { $0 = items }
    }

    public func setItem(_ key: String, _ value: String) {
        items.withLock { $0[key] = value }
    }

    public func getItem(_ key: String) -> String? {
        items.withLock { $0[key] }
    }
}
