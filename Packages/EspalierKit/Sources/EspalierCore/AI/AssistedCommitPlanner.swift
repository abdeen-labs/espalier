// Ported from desktop/app/src/lib/assisted-commit-planning.ts (desktop#22977)
//
// The planner's glue between GitKit's snapshot and AIKit's model request:
// only the snapshot's analysis goes to the model, and its plan comes back
// to GitKit, which validates the plan and every cumulative tree.

import AIKit
import EspalierSupport
import Foundation
import GitKit

/// The model declined to describe the selection.
struct AssistedCommitPlanRefused: Error, LocalizedError, Sendable {
    let reason: String

    var errorDescription: String? {
        "The model didn't plan these changes: \(reason)"
    }
}

/// What a planning turn is doing.
enum AssistedCommitPlanningStep: Sendable, Equatable {
    /// Asking for a plan.
    case planning(changes: Int)
    /// Asking for one message for the whole selection, after a split that
    /// can't be committed in its order.
    case summarizing(changes: Int)
}

enum AssistedCommitPlanner {
    /// Asks the model for a plan of the analysis's units, in a mode.
    typealias Propose = @Sendable (AIAssistedCommitAnalysis, AIAssistedCommitPlanningMode) async throws -> AIAssistedCommitResponse

    /// The snapshot's analysis, as AIKit takes it: IDs, kinds, paths, and
    /// diffs, nothing else.
    static func analysis(_ snapshot: AssistedCommitSnapshot) -> AIAssistedCommitAnalysis {
        AIAssistedCommitAnalysis(
            snapshotID: snapshot.analysis.snapshotID,
            changes: snapshot.analysis.changes.map { change in
                AIAssistedCommitChange(id: change.id, kind: change.kind.rawValue, path: change.path, oldPath: change.oldPath, diff: change.diff)
            }
        )
    }

    /// Plans the snapshot's commits and validates the plan.
    ///
    /// A plan is validated as it is; uncertain boundaries become one commit
    /// with the model's message for the whole selection. Only a well-formed
    /// split that can't be committed in its order (`unsafePlan`) gets a
    /// second turn, asking for one fresh message for all of the selection;
    /// nothing from the first turn goes into it. A refusal, an invalid
    /// response, a provider failure, or a change to the files is an error,
    /// never a reason to fall back.
    ///
    /// - Parameters:
    ///   - onStep: Awaited before each turn.
    ///   - propose: Asks the model.
    static func plan(
        _ snapshot: AssistedCommitSnapshot,
        options: AssistedCommitOptions,
        onStep: @Sendable (AssistedCommitPlanningStep) async -> Void,
        propose: Propose
    ) async throws -> ValidatedAssistedCommitPlan {
        let analysis = analysis(snapshot)
        guard !analysis.changes.isEmpty else {
            throw AIAssistedCommitError(.emptySelection, "An empty commit doesn't need a model.")
        }

        func ask(_ mode: AIAssistedCommitPlanningMode) async throws -> AIAssistedCommitResponse {
            try checkCancelled(options)
            await onStep(mode == .plan ? .planning(changes: analysis.changes.count) : .summarizing(changes: analysis.changes.count))
            try checkCancelled(options)
            let response = try await propose(analysis, mode)
            try checkCancelled(options)
            if case .unsafe(let reason) = response {
                throw AssistedCommitPlanRefused(reason: reason)
            }
            return response
        }

        let proposal: AssistedCommitPlan
        switch try await ask(.plan) {
        case .plan(let groups):
            proposal = AssistedCommitPlan(
                snapshotID: snapshot.id,
                commits: groups.map { AssistedCommitPlanCommit(title: $0.title, description: $0.description, changeIDs: $0.changeIDs) }
            )
        case .uncertainBoundaries(let title, let description):
            proposal = try await snapshot.singleCommitPlan(reason: .uncertainBoundaries, title: title, description: description)
        case .unsafe(let reason):
            throw AssistedCommitPlanRefused(reason: reason)
        }

        do {
            return try await snapshot.validate(proposal, options: options)
        } catch let error as AssistedCommitError where error.code == .unsafePlan && proposal.commits.count > 1 {
            // One more turn, for one commit of everything.
        }

        let message: (title: String, description: String?)
        switch try await ask(.singleCommit) {
        case .plan(let groups):
            guard groups.count == 1 else {
                throw AIAssistedCommitError(.invalidResponse, "The model split the changes when asked for one commit.")
            }
            message = (groups[0].title, groups[0].description)
        case .uncertainBoundaries(let title, let description):
            message = (title, description)
        case .unsafe(let reason):
            throw AssistedCommitPlanRefused(reason: reason)
        }
        let single = try await snapshot.singleCommitPlan(reason: .unsafeSplit, title: message.title, description: message.description)
        return try await snapshot.validate(single, options: options)
    }

    private static func checkCancelled(_ options: AssistedCommitOptions) throws {
        if options.cancellation.isCancelled || Task.isCancelled {
            throw AssistedCommitError(.cancelled, "The assisted commit was cancelled.")
        }
    }
}
