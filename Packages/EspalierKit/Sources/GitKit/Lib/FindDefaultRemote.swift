// Ported from desktop/app/src/lib/stores/helpers/find-default-remote.ts

import EspalierSupport

/// Attempt to find the remote which we consider to be the "default"
/// remote, i.e. in most cases the 'origin' remote.
///
/// If no remotes are given this method will return nil, if no "default"
/// branch could be found the first remote is considered the default.
///
/// - Parameter remotes: A list of remotes for a given repository
public func findDefaultRemote(_ remotes: [Remote]) -> Remote? {
    remotes.first { JSCompat.strictEquals($0.name, "origin") } ?? remotes.first
}
