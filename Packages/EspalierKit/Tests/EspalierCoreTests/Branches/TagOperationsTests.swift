// These drive `BranchesModel`'s tags against real git (creating, deleting,
// refreshing, and the tags-to-push queue), with the queue in the record.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Tags", .offline) @MainActor
struct TagOperationsTests {
    @Test("creates an annotated tag and queues it for the next push")
    func createsTag() async throws {
        let fixture = try await makeSelectedRepository()
        let head = try await fixture.head()
        try await fixture.model.branches.createTag("v1.0", at: head)

        #expect(fixture.model.gitState.tags?["v1.0"] == head)
        #expect(fixture.model.branches.tagsToPush == ["v1.0"])
        #expect(fixture.model.record.tagsToPush == ["v1.0"])
        // Annotated, with an empty message.
        #expect(JSCompat.trim(try await runGit(["cat-file", "-t", "v1.0"], fixture.local)) == "tag")
        await fixture.app.idle()
        #expect(fixture.harness.repositoryListContents()?.contains("\"v1.0\"") == true)
    }

    @Test("a taken or long tag name is refused")
    func nameChecks() async throws {
        let fixture = try await makeSelectedRepository()
        let head = try await fixture.head()
        try await fixture.model.branches.createTag("v1.0", at: head)

        #expect(fixture.model.branches.tagNameError("v1.0") != nil)
        #expect(fixture.model.branches.tagNameError("v2.0") == nil)
        let long = String(repeating: "a", count: 246)
        #expect(fixture.model.branches.tagNameError(long) != nil)
        #expect(fixture.model.branches.tagNameError(String(repeating: "a", count: 245)) == nil)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.createTag("v1.0", at: head)
        }
        #expect(preconditionText(error) != nil)
        #expect(fixture.model.branches.tagsToPush == ["v1.0"])
        await fixture.app.idle()
    }

    @Test("a tag git refuses isn't queued")
    func refusedTag() async throws {
        let fixture = try await makeSelectedRepository()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.createTag("v1.0", at: String(repeating: "0", count: 40))
        }
        #expect(error?.operation == .createTag)
        #expect(fixture.model.branches.tagsToPush.isEmpty)
        await fixture.app.idle()
    }

    @Test("deleting a tag asks first, then takes it off the queue")
    func deletesTag() async throws {
        let fixture = try await makeSelectedRepository()
        let head = try await fixture.head()
        try await fixture.model.branches.createTag("v1.0", at: head)
        try await fixture.model.branches.createTag("v1.1", at: head)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.deleteTag("v1.0")
        }
        #expect(error?.reason == .confirmationRequired(.deleteTag("v1.0")))

        try await fixture.model.branches.deleteTag("v1.0", confirmed: [.deleteTag])
        #expect(fixture.model.gitState.tags?["v1.0"] == nil)
        #expect(fixture.model.branches.tagsToPush == ["v1.1"])
        await fixture.app.idle()
    }

    @Test("a queued tag deleted outside Espalier leaves the queue at the next refresh")
    func deletedElsewhere() async throws {
        let fixture = try await makeSelectedRepository()
        let head = try await fixture.head()
        try await fixture.model.branches.createTag("v1.0", at: head)
        try await fixture.model.branches.createTag("v1.1", at: head)

        try await runGit(["tag", "-d", "v1.0"], fixture.local)
        await fixture.model.refresh(.refs, reason: .fileSystem)
        #expect(fixture.model.branches.tagsToPush == ["v1.1"])
        await fixture.app.idle()
    }

    @Test("the queue survives a relaunch, and a push empties it")
    func queuePersists() async throws {
        let fixture = try await makeSelectedRepository()
        try await fixture.model.branches.createTag("v1.0", at: try await fixture.head())
        await fixture.app.idle()

        let relaunched = await fixture.harness.loadedApp()
        await relaunched.idle()
        let model = try #require(relaunched.repository(fixture.model.id))
        #expect(model.branches.tagsToPush == ["v1.0"])

        model.branches.clearTagsToPush()
        #expect(model.branches.tagsToPush.isEmpty)
        #expect(model.record.tagsToPush.isEmpty)
        await relaunched.idle()
    }
}
