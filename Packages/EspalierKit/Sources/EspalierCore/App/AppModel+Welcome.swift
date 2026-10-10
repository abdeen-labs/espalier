extension AppModel {
    /// Whether the welcome flow shows: until it ends, the first time
    /// Espalier runs. Menus are disabled meanwhile (`capabilities`), and
    /// signing in starts loading the account's repositories to clone.
    ///
    /// After it, an empty list (`repositories.isEmpty`) is the Get Started
    /// state.
    public var isShowingWelcomeFlow: Bool {
        !preferences.hasShownWelcomeFlow
    }

    /// Ends the welcome flow for good.
    public func endWelcomeFlow() {
        preferences.hasShownWelcomeFlow = true
    }
}
