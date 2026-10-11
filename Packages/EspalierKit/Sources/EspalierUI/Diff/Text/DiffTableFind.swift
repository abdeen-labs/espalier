// The diff table's side of find. Edit ▸ Find's commands reach the table
// (from anywhere in the window, through `DiffFindForwarder`) and act on the
// diff's find model, which the container's bar shows. The table draws the
// matches (`DiffRowRenderer`), scrolls the current one into view clear of
// the bar, and when the bar closes selects the current match and takes
// focus.

import AppKit

/// Edit ▸ Find's commands, by their menu items' tags (AppKit's find
/// action numbers).
enum DiffFindCommand: Int {
    /// Find… (⌘F): shows the bar and focuses its field.
    case show = 1
    /// Find Next (⌘G).
    case next = 2
    /// Find Previous (⇧⌘G).
    case previous = 3
    /// Use Selection for Find (⌘E).
    case useSelection = 7
}

extension DiffTableController {
    /// Makes `find` the model the table draws and scrolls for (the
    /// container's, which its bar shows).
    func attach(_ find: DiffFindModel) {
        guard find !== self.find else {
            return
        }
        self.find.disconnect(self)
        self.find = find
        connectFind()
        find.documentDidChange(document, isNewFile: true)
        redrawVisibleRows()
    }

    /// Follows the find model's changes.
    func connectFind() {
        find.connect(self) { [weak self] change in
            self?.findDidChange(change)
        }
    }

    private func findDidChange(_ change: DiffFindChange) {
        switch change {
        case .matches:
            redrawVisibleRows()
        case .current(let animated):
            redrawVisibleRows()
            if let match = find.currentMatch {
                revealFindMatch(match, animated: animated)
            }
        case .closed:
            if let match = find.currentMatch, document.rows.indices.contains(match.row) {
                textSelection = DiffTextSelection(
                    column: match.column,
                    anchor: DiffTextPosition(row: match.row, offset: match.range.lowerBound),
                    head: DiffTextPosition(row: match.row, offset: match.range.upperBound)
                )
                setCursor(row: match.row, extending: false, shows: false)
            }
            tableView.window?.makeFirstResponder(tableView)
            redrawVisibleRows()
        }
    }

    // MARK: Commands

    /// Where find starts from: the text selection's start, else the first
    /// line on screen.
    var findOrigin: DiffFindPosition {
        if let selection = textSelection {
            return DiffFindPosition(row: selection.start.row, column: selection.column, offset: selection.start.offset)
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        return DiffFindPosition(row: max(visible.location, 0), column: .before, offset: 0)
    }

    /// Runs an Edit ▸ Find command. Find Next and Previous with nothing to
    /// search for show the bar and focus its field.
    func performFind(_ command: DiffFindCommand) {
        switch command {
        case .show:
            find.show(focus: true, from: findOrigin)
        case .next, .previous:
            guard find.hasQuery else {
                find.show(focus: true, from: findOrigin)
                return
            }
            let origin = find.isShown ? nil : findOrigin
            if command == .next {
                find.findNext(from: origin)
            } else {
                find.findPrevious(from: origin)
            }
        case .useSelection:
            guard let selection = textSelection, !selection.isEmpty else {
                return
            }
            find.useSelection(document.text(of: selection), at: findOrigin)
        }
    }

    /// Whether an Edit ▸ Find command can run: there's a diff to search,
    /// and text selected for Use Selection for Find.
    func canPerformFind(_ command: DiffFindCommand) -> Bool {
        switch command {
        case .show, .next, .previous:
            document.rowCount > 0
        case .useSelection:
            textSelection.map { !$0.isEmpty } ?? false
        }
    }

    // MARK: Scrolling to a match

    /// Scrolls `match` into view, clear of the find bar over the diff's
    /// top: centered up and down when it's off screen or under the bar,
    /// and, while lines don't wrap, centered in its side's text when it's
    /// outside it. With `animated`, a match within three screens scrolls
    /// with motion (`Motion.scroll`); farther, or under Reduce Motion, at
    /// once.
    func revealFindMatch(_ match: DiffFindMatch, animated: Bool) {
        guard document.rows.indices.contains(match.row) else {
            return
        }
        let rects = textRects(row: match.row, side: match.column, range: match.range)
        let rect = rects.dropFirst().reduce(rects.first ?? tableView.rect(ofRow: match.row)) { $0.union($1) }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let covered = find.isShown ? Metrics.DiffFind.coveredHeight : 0
        var target = visible.origin
        if rect.minY < visible.minY + covered || rect.maxY > visible.maxY {
            target.y = rect.midY - (visible.height + covered) / 2
        }
        if shownContent?.wrapsLines == false {
            // In the table, text is where it would be unscrolled; scrolled
            // sideways by x, a side's text shows from x plus its start.
            let text = geometry.half(match.column).text
            if rect.minX < visible.minX + text.lowerBound || rect.maxX > visible.minX + text.upperBound {
                target.x = rect.midX - (text.lowerBound + text.upperBound) / 2
            }
        }
        target.x = min(max(target.x, 0), max(tableView.frame.width - visible.width, 0))
        target.y = min(max(target.y, 0), max(tableView.frame.height - visible.height, 0))
        guard target != visible.origin else {
            return
        }
        let isNear = abs(target.y - visible.minY) <= visible.height * 3
        if animated, isNear, Motion.animates(tableView) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.scroll
                context.timingFunction = Motion.scrollTimingFunction
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }
}
