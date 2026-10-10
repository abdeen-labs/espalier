// The colors of branches. Branch colors appear only where branches do:
// sidebar dots, the graph, and ref tags.

import AppKit
import SwiftUI

/// The colors of the history graph's tracks.
///
/// The current branch's track takes the user's accent color; the trunk
/// (track 0, the default branch's line) is teal. Other tracks take the
/// palette (pink, violet, orange, green, indigo, and cyan, without the
/// entry nearest the accent's hue, so no branch is mistaken for the current
/// one). Red and yellow are left out: they read as errors and warnings. A
/// track a local branch starts takes that branch's color (`BranchColors`),
/// so a line, its branch's tag, and its sidebar dot agree; other tracks
/// take entry `(t − 1) mod count` of the entries no branch has. Colors
/// follow the engine's tracks, so a line of development keeps its color as
/// lanes are reused.
public enum TrackPalette {
    /// A branch color.
    nonisolated public enum Tone: String, CaseIterable, Sendable {
        case pink, violet, orange, green, indigo, cyan

        /// The color, light and dark (three are Tailwind's 600 and 400
        /// shades).
        public var color: NSColor {
            switch self {
            case .pink: .espalierDynamic(light: .hex(0xDB2777), dark: .hex(0xF472B6))
            case .violet: .espalierDynamic(light: .hex(0x7C3AED), dark: .hex(0xA78BFA))
            case .orange: .espalierDynamic(light: .hex(0xEA580C), dark: .hex(0xFB923C))
            case .green: .espalierDynamic(light: .hex(0x16A34A), dark: .hex(0x4ADE80))
            case .indigo: .espalierDynamic(light: .hex(0x4F46E5), dark: .hex(0x818CF8))
            case .cyan: .espalierDynamic(light: .hex(0x0891B2), dark: .hex(0x22D3EE))
            }
        }

        /// The hue of the light shade, 0 to 1.
        public var hue: CGFloat {
            color.resolved(in: .light).hueComponent
        }
    }

    /// The branch palette, in order, before the accent's neighbor is skipped.
    nonisolated public static let tones: [Tone] = [.pink, .violet, .orange, .green, .indigo, .cyan]

    /// The trunk's teal.
    nonisolated public static let trunk = Palette.readable(
        .espalierDynamic(light: .hex(0x0F766E), dark: .hex(0x2DD4BF)),
        minimumContrast: 3
    )

    /// Each tone as track lines, dots, and tags draw it: 3:1 against the
    /// content background (4.5:1 under Increase Contrast).
    nonisolated static let toneColors: [Tone: NSColor] = Dictionary(
        uniqueKeysWithValues: tones.map { ($0, Palette.readable($0.color, minimumContrast: 3)) }
    )

    /// An accent with less saturation than this (graphite) skips nothing.
    nonisolated static let minimumAccentSaturation: CGFloat = 0.15

    /// The palette for an accent color: `tones` without the entry nearest
    /// the accent's hue.
    public static func palette(accent: NSColor = .controlAccentColor) -> [Tone] {
        let accent = accent.resolved(in: .light)
        guard accent.saturationComponent >= minimumAccentSaturation else {
            return tones
        }
        let hue = accent.hueComponent
        let nearest = tones.indices.min { first, second in
            hueDistance(tones[first].hue, hue) < hueDistance(tones[second].hue, hue)
        }
        guard let nearest else {
            return tones
        }
        var palette = tones
        palette.remove(at: nearest)
        return palette
    }

    /// The color of track `track`.
    public static func color(forTrack track: Int, currentTrack: Int? = nil, accent: NSColor = .controlAccentColor) -> NSColor {
        Resolved(accent: accent, currentTrack: currentTrack).color(forTrack: track)
    }

    /// The color a branch gets without the repository's other branches (a
    /// row outside the sidebar): the current branch's accent, the default
    /// branch's teal, or the palette entry its name hashes to, so it stays
    /// the same between launches. `BranchColors` gives the sidebar's and
    /// the graph's, which keep branches apart.
    public static func color(forBranch name: String, isCurrent: Bool, isDefault: Bool, accent: NSColor = .controlAccentColor) -> NSColor {
        if isCurrent {
            return accent
        }
        if isDefault {
            return trunk
        }
        let palette = palette(accent: accent)
        return color(of: palette[BranchColors.index(of: name, count: palette.count)])
    }

    /// A tone as lines, dots, and tags draw it.
    public static func color(of tone: Tone) -> NSColor {
        toneColors[tone] ?? tone.color
    }

    /// The palette for one accent color, current branch, and set of
    /// branches, for drawing many rows.
    public struct Resolved: Equatable {
        /// The current branch's track's color: the accent.
        public let current: NSColor
        /// The trunk's teal.
        public let trunk: NSColor
        /// The palette, before branches take their colors.
        public let branches: [NSColor]
        /// The current branch's track, if it's laid out.
        public let currentTrack: Int?
        /// The branches' colors (`BranchColors`), when they're known.
        public let branchColors: BranchColors?
        /// The tracks local branches start, by branch: each takes its
        /// branch's color.
        public let trackBranches: [Int: String]
        /// Those tracks' colors.
        public let namedTracks: [Int: NSColor]
        /// The colors other tracks cycle through: the entries no branch
        /// has.
        public let otherTracks: [NSColor]

        /// - Parameters:
        ///   - currentTrack: The current branch's track.
        ///   - branchColors: The repository's branches' colors.
        ///   - trackBranches: The tracks local branches start, with their
        ///     branch.
        public init(accent: NSColor = .controlAccentColor, currentTrack: Int? = nil, branchColors: BranchColors? = nil, trackBranches: [Int: String] = [:]) {
            current = accent
            trunk = TrackPalette.trunk
            branches = TrackPalette.palette(accent: accent).map(TrackPalette.color(of:))
            self.currentTrack = currentTrack
            self.branchColors = branchColors
            self.trackBranches = trackBranches
            var named: [Int: NSColor] = [:]
            for (track, branch) in trackBranches {
                if let color = branchColors?.color(forBranch: branch, accent: accent) {
                    named[track] = color
                }
            }
            namedTracks = named
            otherTracks = branchColors.map { $0.otherTones.map(TrackPalette.color(of:)) } ?? branches
        }

        /// The color of track `track`.
        public func color(forTrack track: Int) -> NSColor {
            if track == currentTrack {
                return current
            }
            if let color = namedTracks[track] {
                return color
            }
            guard track > 0, !otherTracks.isEmpty else {
                return trunk
            }
            return otherTracks[(track - 1) % otherTracks.count]
        }

        /// The color of a ref's tag: a branch's own color (so a tag matches
        /// its sidebar dot), else its commit's track's.
        public func color(forRef ref: RefCapsuleContent) -> NSColor {
            switch ref.kind {
            case .currentBranch, .currentBranchWithUpstream, .detachedHead:
                return current
            case .localBranch, .localBranchWithUpstream:
                return branchColors?.color(forBranch: ref.name, accent: current) ?? color(forTrack: ref.track)
            case .remoteBranch:
                return branchColors?.color(forRemoteBranch: ref.name, accent: current) ?? color(forTrack: ref.track)
            case .tag:
                return color(forTrack: ref.track)
            }
        }

        public static func == (lhs: Resolved, rhs: Resolved) -> Bool {
            lhs.current == rhs.current && lhs.currentTrack == rhs.currentTrack
                && lhs.branchColors == rhs.branchColors && lhs.trackBranches == rhs.trackBranches
        }
    }

    /// The distance between two hues on the color wheel, 0 to 0.5.
    nonisolated static func hueDistance(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        let difference = abs(first - second)
        return min(difference, 1 - difference)
    }
}
