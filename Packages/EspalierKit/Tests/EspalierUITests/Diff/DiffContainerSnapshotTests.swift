// Snapshots of the diff container's layouts: the header, a text diff with
// its warnings, a large diff, a submodule's change, a failed diff, an empty
// state, and the image modes; a text diff and the two-up image in light and
// dark, the rest in light. Which state shows when is
// DiffContainerContentTests'.

import AppKit
import EspalierCore
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

/// Image fixtures, drawn at test time.
@MainActor
enum ImageFixtures {
    /// A PNG of a rounded shape on a transparent background. The system
    /// colors resolve in the light appearance, whatever the Mac's is, so
    /// the fixture is the same image every run.
    static func png(width: Int, height: Int, color: NSColor, inset: CGFloat) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            color.setFill()
            let rect = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: inset, dy: inset)
            NSBezierPath(roundedRect: rect, xRadius: CGFloat(width) / 6, yRadius: CGFloat(width) / 6).fill()
            NSColor.white.setFill()
            CGRect(x: rect.midX - 4, y: rect.minY + 6, width: 8, height: rect.height - 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func image(_ data: Data) -> DiffImage {
        DiffImage(rawContents: data, mediaType: "image/png", bytes: data.count)
    }

    static var previous: DiffImage {
        image(png(width: 120, height: 90, color: .systemBlue, inset: 10))
    }

    static var current: DiffImage {
        image(png(width: 150, height: 90, color: .systemOrange, inset: 6))
    }
}

@Suite("Diff container snapshots") @MainActor
struct DiffContainerSnapshotTests {
    static let area = "Diff"
    static let size = CGSize(width: 640, height: 300)

    private func snapshot(_ view: some View, named name: String, size: CGSize = Self.size, appearances: [SnapshotAppearance] = [.light]) {
        assertSnapshot(
            view.environment(\.diffBuildsSynchronously, true).frame(width: size.width, height: size.height),
            named: name,
            area: Self.area,
            size: size,
            appearances: appearances
        )
    }

    private var modified: DiffFileInfo {
        DiffFileInfo(DiffFixtures.workingFile("Sources/App/RepositoryLoader.swift"))
    }

    // MARK: Text

    @Test("a text diff with its header")
    func textDiff() {
        snapshot(
            DiffContainer(.loaded(.text(DiffFixtures.swiftChange)), file: modified, context: .history),
            named: "container-text",
            appearances: SnapshotAppearance.allCases
        )
    }

    @Test("warnings above a text diff")
    func warnings() {
        let diff = DiffFixtures.swiftChange
        let warned = TextDiff(
            text: diff.text,
            hunks: diff.hunks,
            lineEndingsChange: LineEndingsChange(from: .crlf, to: .lf),
            maxLineNumber: diff.maxLineNumber,
            hasHiddenBidiChars: true
        )
        snapshot(DiffContainer(.loaded(.text(warned)), file: modified, context: .history), named: "container-warnings", size: CGSize(width: 640, height: 360))
    }

    // MARK: States

    @Test("a large diff")
    func largeDiffs() {
        let diff = DiffFixtures.swiftChange
        let large = LargeTextDiff(text: diff.text, hunks: diff.hunks, maxLineNumber: diff.maxLineNumber, hasHiddenBidiChars: false)
        snapshot(DiffContainer(.loaded(.largeText(large)), file: modified, context: .history), named: "container-large")
    }

    @Test("a submodule's change")
    func submodule() {
        let changed = SubmoduleDiff(
            fullPath: "/Users/joe/Developer/espalier/Vendor/lib", path: "Vendor/lib", url: "https://github.com/joe/lib.git",
            status: SubmoduleStatus(commitChanged: true, modifiedChanges: true, untrackedChanges: true),
            oldSHA: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0", newSHA: "0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6"
        )
        snapshot(SubmoduleDiffView(content: SubmoduleDiffContent(diff: changed, readOnly: false), openSubmodule: {}), named: "submodule-changed", size: CGSize(width: 560, height: 360))
    }

    @Test("a text diff with no hunks: whitespace changes hidden")
    func noHunks() {
        snapshot(NoHunksView(status: .modified(), hidesWhitespace: true), named: "empty-whitespace", size: CGSize(width: 480, height: 200))
    }

    @Test("a failed diff")
    func failed() {
        let error = OperationError(.other("Could not read the file."), operation: .loadDiff)
        snapshot(DiffContainer(.failed(error), file: modified, context: .history), named: "container-failed", size: CGSize(width: 480, height: 240))
    }

    // MARK: Images

    @Test("image diffs: the four modes")
    func images() {
        let diff = ImageDiff(previous: ImageFixtures.previous, current: ImageFixtures.current)
        let size = CGSize(width: 560, height: 300)
        for mode in ImageDiffType.allModes {
            snapshot(
                ImageDiffView(diff: diff, status: .modified, mode: mode),
                named: "image-\(mode)",
                size: size,
                appearances: mode == .twoUp ? SnapshotAppearance.allCases : [.light]
            )
        }
    }

    @Test("an image diff's header has the mode picker")
    func imageHeader() {
        let file = DiffFileInfo(path: "Assets/icon.png", status: .modified)
        let diff = ImageDiff(previous: ImageFixtures.previous, current: ImageFixtures.current)
        snapshot(DiffContainer(.loaded(.image(diff)), file: file, context: .history), named: "container-image", size: CGSize(width: 640, height: 320))
    }
}
