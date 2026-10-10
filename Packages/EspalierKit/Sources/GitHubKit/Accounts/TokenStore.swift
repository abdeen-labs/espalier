// Ported from desktop/app/src/lib/stores/token-store.ts

import EspalierSupport

/// Account tokens in the system's secure storage, keyed by
/// `getKeyForAccount` and the user's login.
///
/// `KeychainSecretStore` from EspalierSupport stores generic passwords in the
/// login keychain. `AccountsStore` takes any `SecretStore`, so tests use
/// `InMemorySecretStore` instead.
public typealias TokenStore = KeychainSecretStore
