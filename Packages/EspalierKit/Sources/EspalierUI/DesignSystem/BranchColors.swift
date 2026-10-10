// Which color each branch has. A branch's color comes from its name and the
// repository's other branches, never from what History has loaded, so a
// sidebar dot, the branch's ref tag, and the line it starts in the graph
// agree before History loads and after.

import AppKit

/// The colors of a repository's branches.
///
/// The current branch is the accent; the default branch is the trunk's
/// teal. Every other local branch takes the palette entry its name hashes
/// to, or, when a branch before it (by name) already has that entry, the
/// next free one; once every entry is taken, the next branch starts over
/// with its own entry. A remote branch has the color of the local branch
/// with its name ("origin/main" is main's), else its name's entry. The
/// graph draws the lines no local branch starts in the entries no branch
/// has (`otherTones`), so they never look like a branch's line.
public struct BranchColors: Equatable {
    /// The palette, without the entry nearest the accent.
    public let tones: [TrackPalette.Tone]
    public let current: String?
    public let defaultBranch: String?
    /// Every other local branch's entry.
    public let assigned: [String: TrackPalette.Tone]
    /// The remotes' names, longest first, to split "origin/main".
    public let remoteNames: [String]

    /// - Parameters:
    ///   - branches: The local branches' names.
    ///   - current: The checked-out branch.
    ///   - defaultBranch: The default branch (a remote branch's name when
    ///     there's no local one).
    ///   - remoteNames: The remotes, to find a remote branch's local name.
    public init(branches: [String], current: String?, defaultBranch: String?, remoteNames: [String] = [], accent: NSColor = .controlAccentColor) {
        let tones = TrackPalette.palette(accent: accent)
        self.tones = tones
        self.current = current
        self.defaultBranch = defaultBranch
        self.remoteNames = remoteNames.sorted { $0.count > $1.count }
        var assigned: [String: TrackPalette.Tone] = [:]
        var taken: Set<TrackPalette.Tone> = []
        let others = Set(branches).subtracting([current, defaultBranch].compactMap { $0 }).sorted()
        for name in others where !tones.isEmpty {
            if taken.count == tones.count {
                taken = []
            }
            let preferred = Self.index(of: name, count: tones.count)
            let tone = (0..<tones.count).lazy
                .map { tones[(preferred + $0) % tones.count] }
                .first { !taken.contains($0) } ?? tones[preferred]
            taken.insert(tone)
            assigned[name] = tone
        }
        self.assigned = assigned
    }

    /// The color of the local branch `name`, or nil when it isn't one.
    public func color(forBranch name: String, accent: NSColor = .controlAccentColor) -> NSColor? {
        if name == current {
            return accent
        }
        if name == defaultBranch {
            return TrackPalette.trunk
        }
        return assigned[name].map(TrackPalette.color(of:))
    }

    /// The color of the remote branch `name` ("origin/main"): its local
    /// branch's, else its name's entry.
    public func color(forRemoteBranch name: String, accent: NSColor = .controlAccentColor) -> NSColor {
        if name == defaultBranch {
            return TrackPalette.trunk
        }
        let local = localName(ofRemoteBranch: name)
        if let color = color(forBranch: local, accent: accent) {
            return color
        }
        return tones.isEmpty ? TrackPalette.trunk : TrackPalette.color(of: tones[Self.index(of: local, count: tones.count)])
    }

    /// The color of a branch a merge's message names (simple mode's stubs):
    /// a local branch's own; a remote branch's ("origin/x"), or a pull
    /// request's ("jonas/x", `isPullRequest`), its local branch's; else an
    /// entry no branch has, by the name (or, when the message names none,
    /// by `merge`, the merge's SHA), so a branch that's gone never looks
    /// like one that exists.
    public func color(forMergedBranch name: String?, isPullRequest: Bool, merge: String, accent: NSColor = .controlAccentColor) -> NSColor {
        if let name {
            if let color = color(forBranch: name, accent: accent) {
                return color
            }
            if remoteNames.contains(where: { name.hasPrefix($0 + "/") }) {
                return color(forRemoteBranch: name, accent: accent)
            }
            if isPullRequest, let color = color(forBranch: localName(ofRemoteBranch: name), accent: accent) {
                return color
            }
        }
        let free = otherTones
        guard !free.isEmpty else {
            return TrackPalette.trunk
        }
        return TrackPalette.color(of: free[Self.index(of: name ?? merge, count: free.count)])
    }

    /// The color of the branch `branch` (local or remote).
    public func color(of branch: (name: String, isRemote: Bool), accent: NSColor = .controlAccentColor) -> NSColor {
        if branch.isRemote {
            return color(forRemoteBranch: branch.name, accent: accent)
        }
        return color(forBranch: branch.name, accent: accent)
            ?? (tones.isEmpty ? TrackPalette.trunk : TrackPalette.color(of: tones[Self.index(of: branch.name, count: tones.count)]))
    }

    /// The entries no branch has, for the graph's other lines: all of them
    /// when fewer than two are left, so neighboring lines still differ.
    public var otherTones: [TrackPalette.Tone] {
        let used = Set(assigned.values)
        let free = tones.filter { !used.contains($0) }
        return free.count >= 2 ? free : tones
    }

    /// "main" for "origin/main": the name after the longest remote it
    /// starts with, else after its first component.
    func localName(ofRemoteBranch name: String) -> String {
        for remote in remoteNames where name.hasPrefix(remote + "/") {
            return String(name.dropFirst(remote.count + 1))
        }
        guard let slash = name.firstIndex(of: "/") else {
            return name
        }
        return String(name[name.index(after: slash)...])
    }

    /// The palette index a name hashes to (FNV-1a over its UTF-8: stable
    /// between launches, unlike `hashValue`).
    static func index(of name: String, count: Int) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(max(count, 1)))
    }
}
