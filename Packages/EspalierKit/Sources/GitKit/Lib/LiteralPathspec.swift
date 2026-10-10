// The paths Espalier passes git as pathspecs are literal.
//
// Git reads the arguments after `--` as pathspecs, where `*`, `?`, `[`,
// and `\` are glob characters and a leading `:` starts magic (`:!x` names
// every file but x), so discarding `a*.txt` would also overwrite ab.txt,
// and removing a conflicted `:!x` would remove every other file. Each path
// is prefixed with `:(literal)` rather than setting `GIT_LITERAL_PATHSPECS`,
// which hooks and the commands git runs for submodules would inherit,
// changing how their own pathspecs read.

/// The pathspec that names exactly `path`, relative to the repository's
/// root (git runs there): `:(literal)<path>`, which git matches without
/// globbing or magic.
///
/// Use it for paths only, never for arguments git reads as plain paths
/// (`check-attr`, `update-index`, `diff --no-index`, a `<rev>:<path>`), and
/// never for patterns the code means.
///
/// An empty path stays empty, which git refuses ("empty string is not a
/// valid pathspec"); `:(literal)` alone would name every file.
public func literalPathspec(_ path: String) -> String {
    path.isEmpty ? path : ":(literal)\(path)"
}

/// `literalPathspec(_:)` of each path.
public func literalPathspecs(_ paths: [String]) -> [String] {
    paths.map(literalPathspec)
}
