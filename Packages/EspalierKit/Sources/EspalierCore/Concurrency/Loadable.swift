/// A value that is loaded on demand.
///
/// `loading` keeps the previous value, so a view can keep showing it while
/// the new one loads. Models use `OperationError` as `Failure`.
public enum Loadable<Value: Sendable, Failure: Error>: Sendable {
    /// Nothing asked for yet, or the request was withdrawn.
    case idle
    /// Loading; `previous` is the value shown until the load ends.
    case loading(previous: Value?)
    case loaded(Value)
    case failed(Failure)

    /// The loaded value, or the previous one while loading.
    public var value: Value? {
        switch self {
        case .loaded(let value): value
        case .loading(let previous): previous
        case .idle, .failed: nil
        }
    }

    public var isLoading: Bool {
        if case .loading = self { true } else { false }
    }

    /// The failure, when the last load failed.
    public var failure: Failure? {
        if case .failed(let failure) = self { failure } else { nil }
    }

    /// The state for loading again: `.loading`, keeping the current value.
    public var reloading: Loadable {
        .loading(previous: value)
    }

    /// The state for a finished load.
    public init(_ result: Result<Value, Failure>) {
        switch result {
        case .success(let value): self = .loaded(value)
        case .failure(let failure): self = .failed(failure)
        }
    }

    /// The same state with the value transformed.
    public func map<NewValue: Sendable>(_ transform: (Value) throws(Failure) -> NewValue) -> Loadable<NewValue, Failure> {
        switch self {
        case .idle:
            return .idle
        case .loading(let previous):
            do {
                return .loading(previous: try previous.map(transform))
            } catch {
                return .failed(error)
            }
        case .loaded(let value):
            do {
                return .loaded(try transform(value))
            } catch {
                return .failed(error)
            }
        case .failed(let failure):
            return .failed(failure)
        }
    }
}

extension Loadable: Equatable where Value: Equatable, Failure: Equatable {}
