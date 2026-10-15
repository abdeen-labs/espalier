// Space in the Changes list includes the selected files in full unless
// every one already is, then excludes them all, as a file's checkbox does:
// a partly included file is included in full, and a mixed selection ends up
// all included rather than each file flipped.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Inclusion toggle", .offline, .hangGuard(minutes: 5)) @MainActor
struct InclusionToggleTests {
    @Test("Space includes a partly included file or a mixed selection in full, and excludes files all included")
    func space() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            let controller = ChangesController(context: fixture.context, repository: fixture.repository)
            let readme = try fixture.file("README.md").id
            let loader = try fixture.file("Sources/App/Loader.swift").id
            @MainActor func inclusion(_ path: String) throws -> DiffSelectionType {
                try fixture.file(path).selection.getSelectionType()
            }

            // README.md partly included: one of its lines left out.
            changes.setLineSelection(try fixture.file("README.md").selection.withLineSelection(1, selected: false), forFile: readme)
            #expect(try inclusion("README.md") == .partial)

            controller.toggleInclusion(of: [readme])
            #expect(try inclusion("README.md") == .all)
            controller.toggleInclusion(of: [readme])
            #expect(try inclusion("README.md") == .none)

            // One left out, one included: both end up included.
            controller.toggleInclusion(of: [readme, loader])
            #expect(try inclusion("README.md") == .all)
            #expect(try inclusion("Sources/App/Loader.swift") == .all)

            // Both included: both are left out.
            controller.toggleInclusion(of: [readme, loader])
            #expect(try inclusion("README.md") == .none)
            #expect(try inclusion("Sources/App/Loader.swift") == .none)
            #expect(try inclusion("LICENSE") == .all)
        }
    }
}
