// The Clone sheet's model: Cancel pressed while Clone resolves what to clone
// stops the clone, a leading `~` in the path is the home folder, and a path
// that isn't a full path is the field's problem before Clone.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Clone sheet", .offline) @MainActor
struct CloneSheetTests {
    /// The sheet on URL, with a URL and `path` typed.
    private func sheet(path: String) throws -> CloneSheetModel {
        let model = CloneSheetModel(app: try AppHarness().makeApp())
        model.source = .url
        model.setURL("https://example.com/octocat/app.git")
        model.setPath(path)
        return model
    }

    @Test("Cancel pressed while Clone resolves what to clone: nothing is cloned")
    func cancelWhileResolving() async throws {
        let model = try sheet(path: POSIXPath.join(try createTempDirectory(), "app"))
        let preparing = Task { await model.prepareClone() }
        model.cancel()
        #expect(await preparing.value == nil)
        #expect(model.current.problem == nil)
    }

    @Test("a leading ~ is the home folder; a path that isn't a full path is the field's problem, and Clone does nothing")
    func typedPaths() async throws {
        let folder = "espalier-clone-\(UUID().uuidString)"
        let model = try sheet(path: "~/\(folder)/app")
        await model.validatePath()
        #expect(model.current.problem == nil)
        let request = try #require(await model.prepareClone())
        #expect(request.path == POSIXPath.join(NSHomeDirectory(), folder, "app"))

        model.setPath("Developer/app")
        await model.validatePath()
        #expect(model.current.problem != nil)
        #expect(!model.canClone)
        #expect(await model.prepareClone() == nil)
    }
}
