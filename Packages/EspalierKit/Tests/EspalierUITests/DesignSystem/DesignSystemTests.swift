// The design system's values: the track palette and its contrast, status
// colors, monograms, every SF Symbol EspalierUI's sources name (avatar URLs
// are AvatarLoaderTests'), a centered message's minimum height, and how
// AppKit lays out ref capsules.

import AppKit
import EspalierSupport
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Design system") @MainActor
struct DesignSystemTests {
    // MARK: Track palette

    @Test("the palette skips the entry nearest the accent's hue, and has no red or yellow")
    func paletteSkipsAccent() {
        #expect(TrackPalette.tones == [.pink, .violet, .orange, .green, .indigo, .cyan])
        let blueAccent = TrackPalette.palette(accent: .systemBlue)
        #expect(blueAccent == [.pink, .violet, .orange, .green, .indigo])
        #expect(TrackPalette.palette(accent: .systemPurple) == [.pink, .orange, .green, .indigo, .cyan])
        #expect(TrackPalette.palette(accent: .systemGray) == TrackPalette.tones)
    }

    @Test("the current branch's track takes the accent, the trunk is teal, and every other track keeps its color")
    func currentTrackTakesTheAccent() {
        let resolved = TrackPalette.Resolved(accent: .systemBlue, currentTrack: 2)
        #expect(resolved.color(forTrack: 2) == NSColor.systemBlue)
        #expect(resolved.color(forTrack: 0) == TrackPalette.trunk)
        #expect(resolved.color(forTrack: 1) == resolved.branches[0])
        #expect(resolved.color(forTrack: 3) == resolved.branches[2])
        #expect(resolved.color(forTrack: resolved.branches.count + 1) == resolved.branches[0])

        // On the default branch its track is the current one's: the accent.
        #expect(TrackPalette.Resolved(accent: .systemBlue, currentTrack: 0).color(forTrack: 0) == NSColor.systemBlue)
        // With no current branch (a detached HEAD) the trunk stays teal.
        let detached = TrackPalette.Resolved(accent: .systemBlue)
        #expect(detached.color(forTrack: 0) == TrackPalette.trunk)
        #expect(detached.color(forTrack: 2) == detached.branches[1])
    }

    @Test("a branch outside the graph: the accent when current, teal when default, else a color its name keeps")
    func branchColorsOutsideTheGraph() {
        #expect(TrackPalette.color(forBranch: "feature", isCurrent: true, isDefault: false, accent: .systemBlue) == NSColor.systemBlue)
        #expect(TrackPalette.color(forBranch: "main", isCurrent: false, isDefault: true, accent: .systemBlue) == TrackPalette.trunk)
        let first = TrackPalette.color(forBranch: "fix/locale-units", isCurrent: false, isDefault: false, accent: .systemBlue)
        #expect(first == TrackPalette.color(forBranch: "fix/locale-units", isCurrent: false, isDefault: false, accent: .systemBlue))
        let palette = TrackPalette.Resolved(accent: .systemBlue).branches
        #expect(palette.contains(first))
    }

    @Test("track colors are 3:1 against the content background, light and dark", arguments: [AppearanceVariant.light, .dark])
    func trackContrast(variant: AppearanceVariant) {
        let palette = TrackPalette.Resolved(accent: .controlAccentColor, currentTrack: 1)
        for track in 0...palette.branches.count + 1 {
            let ratio = ContrastCheck.ratio(palette.color(forTrack: track), against: Palette.background, in: variant)
            #expect(ratio >= 3, "track \(track) is \(ratio):1 in \(variant)")
        }
    }

    @Test("status letters are 4.5:1 on their tint, light and dark", arguments: [AppearanceVariant.light, .dark])
    func statusContrast(variant: AppearanceVariant) {
        for kind in FileStatusKind.allCases {
            let background = Palette.statusBackground(kind).resolved(in: variant)
            let base = Palette.background.resolved(in: variant)
            let tinted = base.blended(withFraction: background.alphaComponent, of: background.withAlphaComponent(1)) ?? base
            let ratio = ContrastCheck.ratio(Palette.statusForeground(kind), against: tinted, in: variant)
            #expect(ratio >= 4.5, "\(kind) is \(ratio):1 in \(variant)")
        }
    }

    @Test("diff markers are 4.5:1 against their line tints", arguments: [AppearanceVariant.light, .dark])
    func diffContrast(variant: AppearanceVariant) {
        let base = Palette.background.resolved(in: variant)
        for (marker, tint) in [(DiffColors.addedMarker, DiffColors.addedLine), (DiffColors.deletedMarker, DiffColors.deletedLine)] {
            let line = tint.resolved(in: variant)
            let background = base.blended(withFraction: line.alphaComponent, of: line.withAlphaComponent(1)) ?? base
            #expect(ContrastCheck.ratio(marker, against: background, in: variant) >= 4.5)
        }
    }

    @Test("white text reads on the prominent fill at 4.5:1 in light")
    func buttonContrast() {
        // Dark mode's accent is the button itself: 4.5:1 is for light.
        #expect(ContrastCheck.ratio(.white, against: Palette.button, in: .light) >= 4.5)
    }

    // MARK: Monograms

    @Test("a monogram's image is its point size at its scale")
    func monograms() {
        #expect(MonogramRenderer.image(name: "Joe Bloggs", pointSize: 16, scale: 2)?.width == 32)
    }

    @Test("a monogram's color is the person's own: a hue from their email whatever its case, else their name, lighter in light than in dark")
    func monogramColors() throws {
        let joe = Monogram.hue(name: "Joe Bloggs", email: "joe@example.com")
        #expect(Monogram.hue(name: "Joseph", email: " JOE@example.com") == joe)
        #expect(Monogram.hue(name: "Joe Bloggs", email: "joe@elsewhere.example.com") != joe)
        #expect(Monogram.hue(name: "Joe Bloggs") == Monogram.hue(name: "Joe Bloggs", email: ""))
        #expect(Monogram.hue(name: "Joe Bloggs") != Monogram.hue(name: "Mary Jane"))

        // HSL to sRGB.
        let green = try #require(Monogram.hsl(1.0 / 3, saturation: 1, lightness: 0.5).usingColorSpace(.sRGB))
        #expect(abs(green.redComponent) < 0.001 && abs(green.greenComponent - 1) < 0.001 && abs(green.blueComponent) < 0.001)
        let light = Monogram.color(name: "Joe Bloggs", email: "joe@example.com", in: .light)
        let dark = Monogram.color(name: "Joe Bloggs", email: "joe@example.com", in: .dark)
        #expect(abs(light.hueComponent - joe) < 0.01 && abs(dark.hueComponent - joe) < 0.01)
        #expect(ColorContrast.luminance(light) > ColorContrast.luminance(dark))
        #expect(Monogram.color(name: "Joe Bloggs", email: "joe@example.com").resolved(in: .dark) == dark)
    }

    // MARK: Symbols

    @Test("every SF Symbol EspalierUI's sources name exists")
    func symbols() throws {
        let sources = POSIXPath.join((0..<4).reduce(#filePath) { path, _ in POSIXPath.dirname(path) }, "Sources/EspalierUI")
        let files = try #require(FileManager.default.subpaths(atPath: sources)).filter { $0.hasSuffix(".swift") }
        var names: [String: String] = [:]
        for file in files {
            let source = try String(contentsOfFile: POSIXPath.join(sources, file), encoding: .utf8)
            for name in SymbolNames.names(in: source) where names[name] == nil {
                names[name] = file
            }
        }
        // Each way of naming one is found: an argument, a property's value,
        // and the diff's drawing.
        #expect(names["folder"] != nil && names["lock.fill"] != nil && names["nosign"] != nil, "the scan missed names")
        for (name, file) in names.sorted(by: { $0.key < $1.key }) {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) (\(file)) doesn't exist")
        }
    }

    // MARK: Centered messages

    @Test("a message filling a column asks for no minimum height, however narrow it's offered")
    func fillingSpaceHasNoMinimum() {
        let message = CenteredMessage("No Repository Selected", systemImage: "folder", isLarge: true) {
            Button("Choose a Repository…") {}
        }
        let narrow = CGSize(width: 40, height: 0)
        // Offered a narrow column, the message's title wraps and it asks for
        // more height than a short window has.
        #expect(NSHostingController(rootView: message).sizeThatFits(in: narrow).height > 300)
        #expect(NSHostingController(rootView: message.fillingSpace()).sizeThatFits(in: narrow).height == 0)
    }

    // MARK: Ref capsules

    @Test("AppKit's ref capsules: at most three, then a capsule counting the rest, and fewer when the width runs out")
    func refCapsuleLayout() {
        let refs = [
            RefCapsuleContent(name: "main", kind: .currentBranch, track: 0),
            RefCapsuleContent(name: "feature/login", kind: .localBranch, track: 1),
            RefCapsuleContent(name: "origin/feature", kind: .remoteBranch, track: 2),
            RefCapsuleContent(name: "v1.2.0", kind: .tag, track: 0),
            RefCapsuleContent(name: "v1.1.0", kind: .tag, track: 0),
        ]
        let items = RefCapsuleRenderer.layout(refs)
        #expect(items.count == 4)
        #expect(items.last?.overflowCount == 2)
        #expect(RefCapsuleRenderer.layout(refs, maximumWidth: 60).count == 2)
    }
}
