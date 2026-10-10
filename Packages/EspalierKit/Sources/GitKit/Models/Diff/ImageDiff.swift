// Ported from desktop/app/src/models/diff/image-diff.ts

/// The image diff type.
public enum ImageDiffType: Int, Hashable, Sendable {
    /// Show the old and new images side by side.
    case twoUp = 0

    /// Swipe between the old and new image.
    case swipe = 1

    /// Onion skin.
    case onionSkin = 2

    /// Highlight differences.
    case difference = 3
}
