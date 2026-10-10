// Ported from desktop/app/src/models/computed-action.ts

/// An action being computed in the background on behalf of the user
public enum ComputedAction: String, Hashable, Sendable {
    /// The action is being computed in the background
    case loading = "loading"
    /// The action should complete without any additional work required by the user
    case clean = "clean"
    /// The action requires additional work by the user to complete successfully
    case conflicts = "conflicts"
    /// The action cannot be completed, for reasons the app should explain
    case invalid = "invalid"
}
