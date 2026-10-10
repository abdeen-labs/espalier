// Ported from desktop/app/src/models/progress.ts

/// Base interface containing all the properties that progress events
/// need to support.
///
/// The optional `description` is declared by each conforming type instead,
/// because checkout progress narrows it to a required string.
public protocol ProgressEvent: Sendable {
    /// The overall progress of the operation, represented as a fraction between
    /// 0 and 1.
    var value: Double { get set }

    /// An informative text for user consumption indicating the current operation
    /// state. This will be high level such as 'Pushing origin' or
    /// 'Fetching upstream' and will typically persist over a number of progress
    /// events. For more detailed information about the progress see
    /// the description field
    var title: String? { get }
}

/// An object describing progression of an operation that can't be
/// directly mapped or attributed to either one of the more specific
/// progress events (Fetch, Checkout etc). An example of this would be
/// our own refreshing of internal repository state that takes part
/// after fetch, push and pull.
public struct GenericProgress: ProgressEvent, Hashable {
    public var value: Double
    public let title: String?
    /// An informative text for user consumption. In the case of git progress this
    /// will usually be the last raw line of output from git.
    public let description: String?

    public init(value: Double, title: String? = nil, description: String? = nil) {
        self.value = value
        self.title = title
        self.description = description
    }
}

/// An object describing the progression of a branch checkout operation
public struct CheckoutProgress: ProgressEvent, Hashable {
    public var value: Double
    public let title: String?
    /// Infotext for the user.
    public let description: String

    /// The branch or commit that's currently being checked out
    public let target: String

    public init(value: Double, title: String? = nil, description: String, target: String) {
        self.value = value
        self.title = title
        self.description = description
        self.target = target
    }
}

/// An object describing the progression of a fetch operation
public struct FetchProgress: ProgressEvent, Hashable {
    public var value: Double
    public let title: String?
    /// An informative text for user consumption. In the case of git progress this
    /// will usually be the last raw line of output from git.
    public let description: String?

    /// The remote that's being fetched
    public let remote: String

    public init(value: Double, title: String? = nil, description: String? = nil, remote: String) {
        self.value = value
        self.title = title
        self.description = description
        self.remote = remote
    }
}

/// An object describing the progression of a pull operation
public struct PullProgress: ProgressEvent, Hashable {
    public var value: Double
    public let title: String?
    /// An informative text for user consumption. In the case of git progress this
    /// will usually be the last raw line of output from git.
    public let description: String?

    /// The remote that's being pulled from
    public let remote: String

    public init(value: Double, title: String? = nil, description: String? = nil, remote: String) {
        self.value = value
        self.title = title
        self.description = description
        self.remote = remote
    }
}

/// An object describing the progression of a push operation
public struct PushProgress: ProgressEvent, Hashable {
    public var value: Double
    public let title: String?
    /// An informative text for user consumption. In the case of git progress this
    /// will usually be the last raw line of output from git.
    public let description: String?

    /// The remote that's being pushed to
    public let remote: String

    /// The branch that's being pushed
    public let branch: String

    public init(
        value: Double,
        title: String? = nil,
        description: String? = nil,
        remote: String,
        branch: String
    ) {
        self.value = value
        self.title = title
        self.description = description
        self.remote = remote
        self.branch = branch
    }
}

/// An object describing the progression of a clone operation
public struct CloneProgress: ProgressEvent, Hashable {
    public var value: Double
    public let title: String?
    /// An informative text for user consumption. In the case of git progress this
    /// will usually be the last raw line of output from git.
    public let description: String?

    public init(value: Double, title: String? = nil, description: String? = nil) {
        self.value = value
        self.title = title
        self.description = description
    }
}

/// An object describing the progression of a revert operation.
public struct RevertProgress: ProgressEvent, Hashable {
    public var value: Double
    public let title: String?
    /// An informative text for user consumption. In the case of git progress this
    /// will usually be the last raw line of output from git.
    public let description: String?

    public init(value: Double, title: String? = nil, description: String? = nil) {
        self.value = value
        self.title = title
        self.description = description
    }
}

public struct MultiCommitOperationProgress: ProgressEvent, Hashable {
    public var value: Double
    public let title: String?
    /// An informative text for user consumption. In the case of git progress this
    /// will usually be the last raw line of output from git.
    public let description: String?

    /// The summary of the commit applied
    public let currentCommitSummary: String
    /// The number to signify which commit in a selection is being applied
    public let position: Int
    /// The total number of commits in the operation
    public let totalCommitCount: Int

    public init(
        value: Double,
        title: String? = nil,
        description: String? = nil,
        currentCommitSummary: String,
        position: Int,
        totalCommitCount: Int
    ) {
        self.value = value
        self.title = title
        self.description = description
        self.currentCommitSummary = currentCommitSummary
        self.position = position
        self.totalCommitCount = totalCommitCount
    }
}

/// Any progress event. The cases are its `kind` values; there is no clone
/// case.
///
/// Named `AnyProgress` because a GitKit type named `Progress` would make
/// Foundation's `Progress` ambiguous in every file that imports both.
public enum AnyProgress: ProgressEvent, Hashable {
    case generic(GenericProgress)
    case checkout(CheckoutProgress)
    case fetch(FetchProgress)
    case pull(PullProgress)
    case push(PushProgress)
    case revert(RevertProgress)
    case multiCommitOperation(MultiCommitOperationProgress)

    /// The overall progress of the operation, represented as a fraction between
    /// 0 and 1.
    public var value: Double {
        get {
            switch self {
            case .generic(let progress): progress.value
            case .checkout(let progress): progress.value
            case .fetch(let progress): progress.value
            case .pull(let progress): progress.value
            case .push(let progress): progress.value
            case .revert(let progress): progress.value
            case .multiCommitOperation(let progress): progress.value
            }
        }
        set {
            switch self {
            case .generic(var progress):
                progress.value = newValue
                self = .generic(progress)
            case .checkout(var progress):
                progress.value = newValue
                self = .checkout(progress)
            case .fetch(var progress):
                progress.value = newValue
                self = .fetch(progress)
            case .pull(var progress):
                progress.value = newValue
                self = .pull(progress)
            case .push(var progress):
                progress.value = newValue
                self = .push(progress)
            case .revert(var progress):
                progress.value = newValue
                self = .revert(progress)
            case .multiCommitOperation(var progress):
                progress.value = newValue
                self = .multiCommitOperation(progress)
            }
        }
    }

    /// An informative text for user consumption indicating the current operation
    /// state.
    public var title: String? {
        switch self {
        case .generic(let progress): progress.title
        case .checkout(let progress): progress.title
        case .fetch(let progress): progress.title
        case .pull(let progress): progress.title
        case .push(let progress): progress.title
        case .revert(let progress): progress.title
        case .multiCommitOperation(let progress): progress.title
        }
    }

    /// An informative text for user consumption. In the case of git progress this
    /// will usually be the last raw line of output from git.
    public var description: String? {
        switch self {
        case .generic(let progress): progress.description
        case .checkout(let progress): progress.description
        case .fetch(let progress): progress.description
        case .pull(let progress): progress.description
        case .push(let progress): progress.description
        case .revert(let progress): progress.description
        case .multiCommitOperation(let progress): progress.description
        }
    }
}

/// Clamps progress values between minimum and maximum.
/// Useful for reserving portions of progress reporting for different stages.
public func clampProgress<T: ProgressEvent>(
    _ minimum: Double,
    _ maximum: Double,
    _ progressCallback: @escaping @Sendable (T) -> Void
) -> @Sendable (T) -> Void {
    { progress in
        var clamped = progress
        clamped.value = minimum + progress.value * (maximum - minimum)
        progressCallback(clamped)
    }
}
