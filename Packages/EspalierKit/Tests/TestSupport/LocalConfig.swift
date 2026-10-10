// Ported from desktop/app/test/helpers/local-config.ts

import GitKit

/// Sets each key to its value in the repository's own configuration.
public func setupLocalConfig(_ repository: Repository, _ localConfig: [(String, String)]) async throws {
    for (key, value) in localConfig {
        _ = try await Dugite.exec(["config", key, value], repository.path)
    }
}
