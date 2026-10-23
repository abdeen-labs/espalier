// VoiceOver in the diff. Each row is one element with a label that reads the
// line, what happened to it, and whether the commit includes it. In Changes,
// rows offer actions to include or exclude the line or its block and to
// discard it; hunk headers offer their expansions. A conflicted file drawn
// as blocks reads each block's header as its side and conflict, with its
// Use <branch>'s Version action, and each line with its side. Rotors move
// between changes, hunks, and conflict markers (or conflicts).

import AppKit
import EspalierCore
import GitKit

extension DiffTableController {
    /// A row's VoiceOver label.
    func accessibilityLabel(ofRow row: Int) -> String? {
        guard document.rows.indices.contains(row) else {
            return nil
        }
        let documentRow = document.rows[row]
        switch documentRow.kind {
        case .hunk:
            return hunkLabel(document.hunks[Int(documentRow.hunk)])
        case .noNewline:
            return "No newline at end of file"
        case .conflictHeader:
            return document.conflictHeader(ofRow: row).map(conflictHeaderLabel)
        case .context, .added, .deleted, .modified:
            var parts: [String] = []
            if document.isSplit, documentRow.kind != .context {
                for column in [DiffColumn.before, .after] {
                    if let line = documentRow.line(column) {
                        parts.append(lineLabel(line))
                    }
                }
            } else if let line = documentRow.unifiedLine {
                parts.append(lineLabel(line))
            }
            return parts.joined(separator: " ")
        }
    }

    /// "Line 42, added: let x = 1. Included in commit."
    private func lineLabel(_ line: Int) -> String {
        let documentLine = document.lines[line]
        let content = documentLine.content.trimmingCharacters(in: .whitespaces)
        let text = content.isEmpty ? "blank" : content
        var label: String
        switch documentLine.type {
        case .add:
            label = "Line \(documentLine.newNumber), added: \(text)."
        case .delete:
            label = "Line \(documentLine.oldNumber) of the old file, deleted: \(text)."
        case .context, .hunk:
            label = "Line \(documentLine.newNumber): \(text)."
        }
        if documentLine.conflict == .marker {
            label = "Conflict marker. " + label
        } else if let conflict = documentLine.conflict, let blocks = shownContent?.conflicts, document.isWorkingFile {
            label = "\(blocks.name(conflict)). " + label
        }
        if let included = isIncluded(line: line) {
            label += included ? " Included in commit." : " Not included in commit."
        }
        if documentLine.noTrailingNewLine {
            label += " No newline at end of file."
        }
        return label
    }

    /// "main, conflict 1 of 2: 3 lines." (the common ancestor's block is
    /// "Base").
    private func conflictHeaderLabel(_ header: DocumentConflictHeader) -> String {
        let name = shownContent?.conflicts?.name(header.side) ?? ConflictBlocks.baseName
        let total = Set(document.conflictHeaders.map(\.conflict)).count
        let lines = header.lineCount == 1 ? "1 line" : "\(formatCount(header.lineCount, numberFormat)) lines"
        return "\(name), conflict \(formatCount(header.conflict + 1, numberFormat)) of \(formatCount(total, numberFormat)): \(lines)."
    }

    /// "Hunk, lines 10 to 18: 3 added, 1 deleted."
    private func hunkLabel(_ hunk: DocumentHunk) -> String {
        let first = hunk.header.newStartLine
        let last = max(hunk.header.newStartLine + hunk.header.newLineCount - 1, first)
        if hunk.isBottomDummy {
            return "Unchanged lines \(first) to \(last), not shown."
        }
        var label = "Hunk, lines \(first) to \(last): \(formatCount(hunk.addedCount, numberFormat)) added, \(formatCount(hunk.deletedCount, numberFormat)) deleted."
        if let inclusion = inclusion(ofHunk: hunk) {
            switch inclusion {
            case .all: label += " Included in commit."
            case .partial: label += " Partly included in commit."
            case .none: label += " Not included in commit."
            }
        }
        return label
    }

    /// A row's actions: staging and discarding in Changes, expanding on hunk
    /// headers. None while a new document builds.
    func accessibilityActions(ofRow row: Int) -> [NSAccessibilityCustomAction] {
        guard document.rows.indices.contains(row), shownContent?.isInteractive == true, !isBuilding else {
            return []
        }
        let documentRow = document.rows[row]
        var actions: [NSAccessibilityCustomAction] = []

        if documentRow.kind == .conflictHeader {
            let header = Int(documentRow.block)
            guard canChooseConflictSide(header: header), let title = shownContent?.conflicts?.side(document.conflictHeaders[header].side)?.buttonTitle else {
                return actions
            }
            actions.append(NSAccessibilityCustomAction(name: title) { [weak self] in
                guard let self, self.canChooseConflictSide(header: header) else {
                    return false
                }
                self.chooseConflictSide(header: header)
                return true
            })
            return actions
        }

        if documentRow.kind == .hunk {
            let hunk = document.hunks[Int(documentRow.hunk)]
            for button in DiffHunkButton.buttons(for: hunk.expansionType) {
                actions.append(NSAccessibilityCustomAction(name: button.title) { [weak self] in
                    guard let self else {
                        return false
                    }
                    let (index, kind) = button.expansion(ofHunk: hunk.index)
                    self.actions.expandHunk(index, kind)
                    self.announce("Expanded")
                    return true
                })
            }
            if let staging = shownContent?.staging, staging.canSelectLines, let range = hunk.changedDiffLines, let inclusion = inclusion(ofHunk: hunk) {
                let include = inclusion != .all
                actions.append(NSAccessibilityCustomAction(name: include ? "Include Hunk" : "Exclude Hunk") { [weak self] in
                    self?.actions.staging?.setLines(.range(range), include, staging.diffGeneration)
                    return true
                })
            }
            return actions
        }

        guard let staging = shownContent?.staging, documentRow.isChange else {
            return actions
        }
        if staging.canSelectLines {
            for column in [DiffColumn.before, .after] {
                guard let line = documentRow.line(column), document.lines[line].isChange,
                      let included = isIncluded(line: line), !(column == .after && documentRow.before == documentRow.after)
                else {
                    continue
                }
                let number = document.lines[line].diffLineNumber
                let name = documentRow.kind == .modified
                    ? (included ? "Exclude \(column == .before ? "Deleted" : "Added") Line" : "Include \(column == .before ? "Deleted" : "Added") Line")
                    : (included ? "Exclude Line" : "Include Line")
                actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                    self?.actions.staging?.setLines(.line(number), !included, staging.diffGeneration)
                    return true
                })
            }
            if let block = document.block(ofRow: row) {
                let lines = block.rows.flatMap { document.diffLines(ofRow: $0) }
                let includedCount = lines.filter { staging.selection.isSelected($0) }.count
                let include = includedCount != lines.count
                actions.append(NSAccessibilityCustomAction(name: include ? "Include Block" : "Exclude Block") { [weak self] in
                    self?.actions.staging?.setLines(.block(containing: block.diffLines.lowerBound), include, staging.diffGeneration)
                    return true
                })
            }
        }
        if staging.canDiscard, let number = document.diffLines(ofRow: row).first,
           let title = self.actions.staging?.discardTitle(.line(number), staging.diffGeneration) {
            actions.append(NSAccessibilityCustomAction(name: title) { [weak self] in
                self?.actions.staging?.discardLines(.line(number), staging.diffGeneration)
                return true
            })
        }
        return actions
    }

    /// The rotors: changes, hunks, and conflict markers.
    func accessibilityRotors() -> [NSAccessibilityCustomRotor] {
        var rotors = [
            NSAccessibilityCustomRotor(label: "Changes", itemSearchDelegate: rotorDelegate(.changes)),
            NSAccessibilityCustomRotor(label: "Hunks", itemSearchDelegate: rotorDelegate(.hunks)),
        ]
        if !document.conflictMarkerRows.isEmpty {
            rotors.append(NSAccessibilityCustomRotor(
                label: document.isWorkingFile ? "Conflicts" : "Conflict Markers",
                itemSearchDelegate: rotorDelegate(.conflictMarkers)
            ))
        }
        return rotors
    }

    private func rotorDelegate(_ kind: DiffRotorDelegate.Kind) -> DiffRotorDelegate {
        DiffRotorDelegate(kind: kind, controller: self)
    }

    /// The rows a rotor stops at.
    func rotorRows(_ kind: DiffRotorDelegate.Kind) -> [Int] {
        switch kind {
        case .changes: document.blocks.compactMap(\.rows.first)
        case .hunks: document.hunks.filter { !$0.isBottomDummy }.map(\.row)
        case .conflictMarkers: document.conflictMarkerRows
        }
    }

    /// A row's view, scrolled into view, as a rotor's target.
    func rotorTarget(row: Int) -> NSView? {
        scrollRowIntoView(row)
        return tableView.rowView(atRow: row, makeIfNecessary: true)
    }
}

/// Moves VoiceOver between rows of one kind.
final class DiffRotorDelegate: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    enum Kind {
        case changes, hunks, conflictMarkers
    }

    let kind: Kind
    private weak var controller: DiffTableController?

    init(kind: Kind, controller: DiffTableController) {
        self.kind = kind
        self.controller = controller
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let controller else {
            return nil
        }
        let rows = controller.rotorRows(kind)
        let current = (searchParameters.currentItem?.targetElement as? DiffRowView)?.row
        let target: Int?
        switch searchParameters.searchDirection {
        case .previous:
            target = current.map { row in rows.last { $0 < row } } ?? rows.last
        default:
            target = current.map { row in rows.first { $0 > row } } ?? rows.first
        }
        guard let target, let view = controller.rotorTarget(row: target) else {
            return nil
        }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: view)
        result.customLabel = controller.accessibilityLabel(ofRow: target)
        return result
    }
}
