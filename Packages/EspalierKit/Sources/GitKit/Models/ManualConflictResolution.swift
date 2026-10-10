// Ported from desktop/app/src/models/manual-conflict-resolution.ts

// NOTE: These strings have semantic value, they're passed directly
// as `--ours` and `--theirs` to git checkout. Please be careful
// when modifying this type.
public enum ManualConflictResolution: String, Hashable, Sendable {
    case theirs = "theirs"
    case ours = "ours"
}
