// Fixed diffs and images for the diff's captures, and diff tables drawn
// once their documents are built: alone in a capture window, or in a
// SwiftUI view.

import AppKit
import EspalierCore
import Foundation
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

/// Fixed diffs, parsed from patches with GitKit's parser.
enum DiffCaptureFixtures {
    /// A text diff from a patch's hunks.
    static func textDiff(_ patch: String) -> TextDiff {
        let raw = try! DiffParser().parse(patch)
        return TextDiff(
            text: raw.contents,
            hunks: raw.hunks,
            lineEndingsChange: nil,
            maxLineNumber: raw.maxLineNumber,
            hasHiddenBidiChars: raw.hasHiddenBidiChars
        )
    }

    /// A change to a Swift file: a modified block (two lines for two), an
    /// added run, a deleted line, and a second hunk.
    static let swiftPatch = """
    diff --git a/Sources/App/RepositoryLoader.swift b/Sources/App/RepositoryLoader.swift
    index 1111111..2222222 100644
    --- a/Sources/App/RepositoryLoader.swift
    +++ b/Sources/App/RepositoryLoader.swift
    @@ -10,7 +10,9 @@ struct RepositoryLoader {
         func load() throws -> Repository {
             let path = configuration.path
    -        let tip = repo.tip!
    -        return Repository(path: path, tip: tip)
    +        guard let tip = repo.tip else {
    +            return .empty
    +        }
    +        return Repository(path: path, tip: tip, isBare: false)
         }
    \u{20}
         func reload() {
    @@ -40,6 +42,5 @@ struct RepositoryLoader {
         func close() {
             cache.removeAll()
    -        // TODO: notify observers
             isOpen = false
         }
     }
    """

    static var swiftChange: TextDiff {
        textDiff(swiftPatch)
    }

    /// The old file's line count before `swiftPatch`: 45 lines, then 10
    /// more below the diff (for expansion).
    static let swiftOldLineCount = 55

    /// The new file's line count after `swiftPatch`: 46 lines, then the
    /// same 10 below the diff.
    static let swiftNewLineCount = 56

    /// The Swift change with the dummy hunk at the bottom, as once its
    /// contents load.
    static var swiftChangeWithBottomHunk: TextDiff {
        let diff = swiftChange
        return getTextDiffWithBottomDummyHunk(diff, diff.hunks, swiftOldLineCount, swiftNewLineCount) ?? diff
    }

    /// A partial selection of the Swift change: the first deleted line and
    /// the last added line excluded.
    static var partialSelection: DiffSelection {
        let changed = swiftChange.hunks.flatMap(\.lines).compactMap { $0.isIncludeableLine() ? $0.originalLineNumber : nil }
        return DiffSelection.fromInitialSelection(.all)
            .withSelectableLines(Set(changed))
            .withLineSelection(changed[0], selected: false)
            .withLineSelection(changed[5], selected: false)
    }

    /// Staging the Swift change's lines, partly excluded.
    static var partialStaging: StagingState {
        StagingState(selection: partialSelection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
    }

    /// Lines long enough to wrap, a tab, and wide characters.
    static let wrappingPatch = """
    diff --git a/README.md b/README.md
    index 1111111..2222222 100644
    --- a/README.md
    +++ b/README.md
    @@ -1,3 +1,3 @@
     # Espalier
    -Espalier is a modern macOS client for Git and GitHub, written in Swift with SwiftUI and AppKit, that trains your branches along a wall.
    +Espalier is a modern macOS app for Git and GitHub, written in Swift with SwiftUI and AppKit, that trains your branches neatly along a wall.
     \tIndented with a tab, then \u{65E5}\u{672C}\u{8A9E}\u{306E}\u{30C6}\u{30AD}\u{30B9}\u{30C8} and more text after it to wrap.
    """

    static var wrapping: TextDiff {
        textDiff(wrappingPatch)
    }

    /// A conflicted file's diff against HEAD with the common ancestor's
    /// side (`diff3`): the markers, and ours, base, and theirs between
    /// them.
    static let conflictWithBasePatch = """
    diff --git a/Sources/App/Config.swift b/Sources/App/Config.swift
    index 1111111..2222222 100644
    --- a/Sources/App/Config.swift
    +++ b/Sources/App/Config.swift
    @@ -1,4 +1,10 @@
     let name = "espalier"
    +<<<<<<< HEAD
     let timeout = 30
    +||||||| base
    +let timeout = 10
    +=======
    +let timeout = 60
    +>>>>>>> feature/longer-timeout
     let retries = 3
     let verbose = false
    """

    static var conflictWithBase: TextDiff {
        textDiff(conflictWithBasePatch)
    }

    /// A last line without a newline, changed to have one.
    static let noNewlinePatch = """
    diff --git a/notes.txt b/notes.txt
    index 1111111..2222222 100644
    --- a/notes.txt
    +++ b/notes.txt
    @@ -1,2 +1,2 @@
     first line
    -last line
    \\ No newline at end of file
    +last line
    """

    static var noNewline: TextDiff {
        textDiff(noNewlinePatch)
    }

    /// A working directory file.
    static func workingFile(_ path: String) -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(path: path, status: .modified(), selection: .fromInitialSelection(.all))
    }
}

/// Images for image diffs, drawn when a capture runs.
@MainActor
enum DiffCaptureImages {
    /// A PNG of a rounded shape on a transparent background, its colors
    /// resolved in the light appearance whatever the Mac's.
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

    /// A blue icon, 120 by 90.
    static var previous: DiffImage {
        image(png(width: 120, height: 90, color: .systemBlue, inset: 10))
    }

    /// An orange icon, 150 by 90.
    static var current: DiffImage {
        image(png(width: 150, height: 90, color: .systemOrange, inset: 6))
    }

    /// The blue icon changed to the orange one.
    static var modified: ImageDiff {
        ImageDiff(previous: previous, current: current)
    }
}

// MARK: - The table in a window

/// A diff table alone in a capture window, its document built.
@MainActor
final class DiffTableScene {
    let window: CaptureWindow
    let controller: DiffTableController

    /// A table of `size` in `appearance` showing `content`, once the
    /// document is built and laid out.
    init(_ content: DiffTableContent, size: CGSize, appearance: CaptureAppearance) async {
        // The run's look becomes the process's before the table is made.
        _ = Capture.look
        window = CaptureWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        let controller = DiffTableController()
        self.controller = controller
        window.contentView = controller.scrollView
        controller.scrollView.layoutSubtreeIfNeeded()
        controller.apply(content)
        await waitUntilRunLoopIdle { controller.showsItsDocument }
        controller.scrollView.layoutSubtreeIfNeeded()
    }

    /// A point in a row: at `x`, at the row's vertical middle.
    func point(row: Int, x: CGFloat) -> CGPoint {
        CGPoint(x: x, y: controller.tableView.rect(ofRow: row).midY)
    }

    /// The middle of a range of x.
    static func middle(_ range: ClosedRange<CGFloat>) -> CGFloat {
        (range.lowerBound + range.upperBound) / 2
    }

    /// Draws the table as it's laid out, then takes it out of its window.
    func image() -> NSBitmapImageRep {
        controller.scrollView.layoutSubtreeIfNeeded()
        let image = Capture.image(of: controller.scrollView)
        controller.tearDown()
        window.contentView = nil
        return image
    }
}

// MARK: - SwiftUI views with a table

/// Captures a SwiftUI view of `size` that shows a diff table, in each
/// appearance, once the table shows its document and `ready` holds;
/// `prepare` gets the laid-out host and the table before drawing.
@MainActor
func captureDiffView(
    _ makeView: () -> some View,
    named name: String,
    area: String,
    size: CGSize,
    appearances: [CaptureAppearance] = [.light],
    ready: @escaping @MainActor (DiffTableController) -> Bool = { _ in true },
    prepare: (NSView, DiffTableController) -> Void = { _, _ in },
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    // The run's look becomes the process's before any view is made.
    _ = Capture.look
    for appearance in appearances {
        let root = Capture.prepared(makeView().frame(width: size.width, height: size.height))
            .background(Color(nsColor: Palette.background))
        let host = NSHostingView(rootView: root)
        let window = CaptureWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        await waitUntilRunLoopIdle {
            host.layoutSubtreeIfNeeded()
            return host.captureDescendants(DiffTableView.self).first?.controller.map { ready($0) && $0.showsItsDocument } ?? false
        }
        if let controller = host.captureDescendants(DiffTableView.self).first?.controller {
            prepare(host, controller)
        }
        host.layoutSubtreeIfNeeded()
        capture(named: name, area: area, appearances: [appearance], sourceLocation: sourceLocation) { _ in
            Capture.image(of: host)
        }
        window.contentView = nil
    }
}
