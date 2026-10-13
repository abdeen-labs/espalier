// The design system's small pieces, in light and dark: the file status and
// checks glyphs, ref capsules as SwiftUI and AppKit draw them, and
// monograms as avatars, as a view, and as AppKit's image.

import AppKit
import EspalierCore
import GitHubKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Design system", .captures) @MainActor
struct DesignSystemCaptures {
    private let area = "DesignSystem"

    /// Every kind of ref, the current branch's and one more on the first
    /// track.
    private let refs = [
        RefCapsuleContent(name: "main", kind: .currentBranch, track: 0),
        RefCapsuleContent(name: "feature/login", kind: .localBranch, track: 1),
        RefCapsuleContent(name: "main", kind: .localBranchWithUpstream(remote: "origin"), track: 0),
        RefCapsuleContent(name: "origin/feature", kind: .remoteBranch, track: 2),
        RefCapsuleContent(name: "v1.2.0", kind: .tag, track: 0),
        RefCapsuleContent(name: "HEAD", kind: .detachedHead, track: 0),
    ]

    @Test("the file status glyphs, the checks glyphs, and the warning glyph")
    func glyphs() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            HStack(spacing: Metrics.insetSmall) {
                ForEach(FileStatusKind.allCases, id: \.self) { kind in
                    StatusGlyph(kind)
                }
            }
            HStack(spacing: Metrics.insetSmall) {
                ForEach(ChecksState.allCases, id: \.self) { state in
                    ChecksGlyph(state)
                }
                WarningGlyph()
            }
        }
        .padding(Metrics.insetMedium)
        capture(view, named: "glyphs", area: area)
    }

    @Test("ref capsules in SwiftUI: each kind side by side, and the list that keeps three")
    func refCapsules() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            HStack(spacing: Metrics.RefCapsule.spacing) {
                ForEach(refs) { RefCapsule($0) }
            }
            RefCapsuleList(refs)
        }
        .padding(Metrics.insetMedium)
        capture(view, named: "refCapsules", area: area)
    }

    @Test("ref capsules in AppKit, as a graph cell draws them: three, then a capsule counting the rest")
    func refCapsulesAppKit() {
        let items = RefCapsuleRenderer.layout(refs)
        capture({ RefCapsuleDrawingView(items: items) }, named: "refCapsules-appkit", area: area, size: CGSize(width: 320, height: 28))
    }

    @Test("monograms: as avatars at two sizes, with no name, and as AppKit's image")
    func avatars() {
        capture(named: "avatars", area: area) { appearance in
            let monogram = MonogramRenderer.image(
                name: "Mary Jane",
                pointSize: 32,
                scale: Capture.scale,
                variant: appearance == .dark ? .dark : .light
            )
            let view = HStack(spacing: Metrics.insetSmall) {
                Avatar(AvatarUser(email: "joe@example.com", avatarURL: nil, name: "Joe Bloggs", endpoint: nil))
                Avatar(AvatarUser(email: "octo@example.com", avatarURL: nil, name: "Octocat", endpoint: nil), size: 24)
                MonogramView(name: "", email: "", size: 32)
                if let monogram {
                    Image(decorative: monogram, scale: Capture.scale)
                }
            }
            .padding(Metrics.insetMedium)
            return Capture.render(view, appearance: appearance)
        }
    }
}

/// Draws laid-out ref capsules, as a graph cell does.
private final class RefCapsuleDrawingView: NSView {
    let items: [RefCapsuleRenderer.Item]

    init(items: [RefCapsuleRenderer.Item]) {
        self.items = items
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        RefCapsuleRenderer.draw(items, at: CGPoint(x: 6, y: 6), appearance: effectiveAppearance)
    }
}
