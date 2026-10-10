/// OAuth settings for signing in to GitHub.
///
/// Espalier signs in with the OAuth device flow only. A client ID is a public
/// identifier, and the device flow needs no client secret, so none exists
/// anywhere in this codebase. GitHub Enterprise Server needs an OAuth app
/// registered on that server, so enterprise accounts carry their own client ID
/// instead of this one.
public enum OAuthConfig {
    /// The client ID of Espalier's OAuth app on github.com (device flow enabled).
    public static let dotComClientID = "Ov23liPybuNotM82b8a0"

    /// The scopes requested at sign-in.
    public static let scopes = ["repo", "user", "workflow"]
}
