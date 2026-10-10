// The Debug menu, in Debug builds only. It holds benchmarks and checks to
// run on the real app.

import EspalierSupport

/// The Debug menu.
public enum DebugMenu {
    /// Whether the menu shows: in every Debug build, never in Release.
    public static let isEnabled = BuildConfiguration.isDebug
}
