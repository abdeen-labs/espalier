import EspalierSupport
import GitKit

/// The longest tag name allowed, in UTF-16 code units.
let maxTagNameLength = 245

extension BranchesModel {
    /// The tags created in Espalier that the next push pushes, oldest first.
    /// A tag deleted outside Espalier leaves the queue at the next refresh.
    public var tagsToPush: [String] {
        repository?.record.tagsToPush ?? []
    }

    /// Why `name` can't be a new tag's name, or nil: it's too long, taken,
    /// or git can't keep it beside a tag (`refNameConflict`).
    public func tagNameError(_ name: String) -> String? {
        // JavaScript's string length: UTF-16 code units.
        if name.utf16.count > maxTagNameLength {
            return "The tag name cannot be longer than \(maxTagNameLength) characters"
        }
        guard let tags = repository?.gitState.tags else {
            return nil
        }
        if tags[name] != nil {
            return "A tag named \(name) already exists"
        }
        if let conflict = refNameConflict(name, among: tags.keys) {
            return conflict.isSameName
                ? "A tag named \(conflict.existingName) already exists"
                : "A tag named \(conflict.existingName) already exists, so \(name) can't be used"
        }
        return nil
    }

    /// Creates an annotated tag with an empty message on `sha` and queues it
    /// for the next push. Returns after the repository's refresh.
    ///
    /// - Throws: `.precondition` with `tagNameError(_:)`'s message when the
    ///   name can't be used; git's errors (the tag isn't queued).
    public func createTag(_ name: String, at sha: String) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .createTag)
        }
        if let error = tagNameError(name) {
            throw OperationError(.precondition(error), operation: .createTag, repositoryID: repository.id)
        }
        try await repository.perform(OperationDescriptor(kind: .createTag)) { ctx in
            try await GitKit.createTag(ctx.repository, name, sha)
        }
        // The queue is in the record before the refresh's tag step, which
        // drops queued tags that don't exist.
        app.updateRecord(repository.id) { record in
            // A tag already queued isn't queued again.
            if !record.tagsToPush.contains(where: { JSCompat.strictEquals($0, name) }) {
                record.tagsToPush.append(name)
            }
        }
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// Deletes a local tag and takes it off the push queue. A tag that was
    /// pushed stays on the remote. Asks first: `.deleteTag`. Returns after the
    /// repository's refresh.
    public func deleteTag(_ name: String, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository, repository.app != nil else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .deleteTag)
        }
        if !confirmed.contains(.deleteTag) {
            throw OperationError(.confirmationRequired(.deleteTag(name)), operation: .deleteTag, repositoryID: repository.id)
        }
        try await repository.perform(OperationDescriptor(kind: .deleteTag)) { ctx in
            try await GitKit.deleteTag(ctx.repository, name)
        }
        removeTagToPush(name)
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// Empties the push queue after a push that wasn't aborted pushed it.
    func clearTagsToPush() {
        guard let repository, let app = repository.app else {
            return
        }
        app.updateRecord(repository.id) { $0.tagsToPush = [] }
    }

    private func removeTagToPush(_ name: String) {
        guard let repository, let app = repository.app else {
            return
        }
        app.updateRecord(repository.id) { record in
            record.tagsToPush.removeAll { JSCompat.strictEquals($0, name) }
        }
    }
}
