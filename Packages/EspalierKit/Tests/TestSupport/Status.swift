// Ported from desktop/app/test/helpers/status.ts

import GitKit

/// git status may return null in some edge cases but for the most
/// part we know we'll get a valid input so let's fail the test
/// if we get null, rather than need to handle it everywhere
public func getStatusOrThrow(_ repository: Repository) async throws -> StatusResult {
    guard let inner = try await getStatus(repository) else {
        throw TestSupportError("git status returned null which was not expected")
    }

    return inner
}
