/// How this build was compiled.
public enum BuildConfiguration {
    /// Whether this is a Debug build. SwiftPM and Xcode define `DEBUG` when
    /// they compile a package in its Debug configuration (`swift build`,
    /// `swift test`, and the app's Debug build), and never in Release.
    public static let isDebug: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()
}
