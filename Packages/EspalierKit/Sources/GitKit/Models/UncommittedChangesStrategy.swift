// Ported from desktop/app/src/models/uncommitted-changes-strategy.ts

public enum UncommittedChangesStrategy: String, Hashable, Sendable {
    case askForConfirmation = "AskForConfirmation"
    case stashOnCurrentBranch = "StashOnCurrentBranch"
    case moveToNewBranch = "MoveToNewBranch"
}

public let defaultUncommittedChangesStrategy: UncommittedChangesStrategy = .askForConfirmation
