// A commit's (or the working copy's) changed files in History's details:
// chips with the status badge, the name, and the counts, the selected one
// accent-tinted, wrapping up to four rows with the rest a scroll away. A
// commit with more files than `chipLimit` lists them in rows beside the
// diff instead, where hundreds of paths can be read. Both select with the
// mouse and the arrow keys, open with a double click or Return, and have
// the files' context menu, which ⇧F10 opens on the selected file.

import AppKit
import EspalierSupport
import GitKit
import SwiftUI

/// A changed file, as a chip or a row shows it.
nonisolated struct HistoryFileContent: Sendable, Equatable, Identifiable {
    var file: CommittedFileRowContent
    /// Lines added and deleted; nil when unknown or binary.
    var added: Int?
    var deleted: Int?

    var id: String {
        file.id
    }

    var chip: FileChipContent {
        FileChipContent(name: file.fileName, status: file.status, added: added, deleted: deleted)
    }
}

extension HistoryFileContent {
    /// A commit's file, with its counts from the changeset.
    init(_ file: CommittedFileChange, in changeset: ChangesetData) {
        let counts = changeset.lineCounts[file.id]
        self.init(file: CommittedFileRowContent(file), added: counts?.added, deleted: counts?.deleted)
    }
}

/// How the files show: chips over the diff, or rows beside it.
enum HistoryFilesStyle {
    case chips, rows

    /// More files than this show as rows: chips are quick to scan for a
    /// few files, and rows, with their folders, for many.
    static let chipLimit = 40

    static func style(forFileCount count: Int) -> HistoryFilesStyle {
        count > chipLimit ? .rows : .chips
    }
}

extension Metrics {
    /// History's changed files.
    enum HistoryFiles {
        /// Between chips, and between their rows.
        static let chipSpacing: CGFloat = 6
        /// Chips show up to this many rows before they scroll.
        static let visibleChipRows = 4
        /// The height of `visibleChipRows` rows of chips.
        static var chipsMaximumHeight: CGFloat {
            CGFloat(visibleChipRows) * ControlHeight.regular + CGFloat(visibleChipRows - 1) * chipSpacing
        }
    }
}

/// The selection and what the files' controls do.
struct HistoryFilesActions {
    var select: (String?) -> Void = { _ in }
    /// Double click or Return; nil when files don't open.
    var open: ((String) -> Void)?
}

/// The files as chips or rows, with keyboard selection.
struct HistoryFiles<Menu: View>: View {
    let files: [HistoryFileContent]
    let selection: String?
    var style = HistoryFilesStyle.chips
    var actions = HistoryFilesActions()
    /// Focuses the files when it changes (Return in the graph).
    var focusRequest = 0
    /// The context menu for a file.
    @ViewBuilder var menu: (HistoryFileContent) -> Menu
    @FocusState private var isFocused: Bool
    @State private var contentHeight: CGFloat = 0
    /// What's been typed for type select, and when.
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    /// On the selected file: where ⇧F10 pops up its menu.
    @State private var menuAnchor = KeyboardMenuAnchor()

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                switch style {
                case .chips:
                    chips
                case .rows:
                    rows
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                move(direction)
            }
            .onKeyPress(.return) {
                guard let selection, let open = actions.open else {
                    return .ignored
                }
                open(selection)
                return .handled
            }
            .onKeyPress(keys: [KeyEquivalent(KeyboardContextMenu.f10)], phases: .down) { press in
                // ⇧F10: the selected file's menu; nothing without one.
                guard KeyboardContextMenu.isShortcut(press) else {
                    return .ignored
                }
                if selection != nil {
                    menuAnchor.showMenu()
                }
                return .handled
            }
            .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters), phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else {
                    return .ignored
                }
                typeSelect(press.characters)
                return .handled
            }
            .onChange(of: selection) {
                if let selection {
                    proxy.scrollTo(selection)
                }
            }
            .onChange(of: focusRequest) {
                isFocused = true
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Changed Files")
        }
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.vertical) {
            FlowLayout(spacing: Metrics.HistoryFiles.chipSpacing) {
                ForEach(files) { file in
                    item(file) {
                        FileChip(file.chip, isSelected: file.id == selection)
                            .help(file.file.tooltip)
                    }
                }
            }
            // Room for the chips' rings and shadows.
            .padding(3)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = height
            }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, Metrics.HistoryFiles.chipsMaximumHeight + 6))
        .padding(-3)
    }

    // MARK: Rows

    private var rows: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    item(file) {
                        HistoryFileRow(content: file, isSelected: file.id == selection)
                    }
                }
            }
            .padding(.vertical, Metrics.grid)
        }
    }

    // MARK: Selection

    /// A chip or row: a click selects it, a double click opens it, and a
    /// secondary click (or ⇧F10 on the selected one) shows its menu.
    private func item(_ file: HistoryFileContent, @ViewBuilder content: () -> some View) -> some View {
        content()
            .id(file.id)
            .background {
                if file.id == selection {
                    KeyboardMenuAnchorView(anchor: menuAnchor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
                actions.select(file.id)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                actions.open?(file.id)
            })
            .contextMenu {
                menu(file)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                actions.select(file.id)
            }
    }

    /// Typing selects the first file whose name starts with what's typed,
    /// as a list's type select does; a pause starts over.
    private func typeSelect(_ characters: String) {
        let now = Date()
        if now.timeIntervalSince(typedAt) > Self.typeSelectPause {
            typed = ""
        }
        typed += characters
        typedAt = now
        if let id = HistoryFilesNavigation.file(named: typed, in: files), id != selection {
            actions.select(id)
        }
    }

    /// How long a pause in typing starts a new type select.
    private static var typeSelectPause: TimeInterval { 1 }

    /// The arrow keys: the previous or next file (left and up, right and
    /// down), the first when none is selected.
    private func move(_ direction: MoveCommandDirection) {
        let step: Int
        switch direction {
        case .up, .left: step = -1
        case .down, .right: step = 1
        @unknown default: return
        }
        if let id = HistoryFilesNavigation.file(after: selection, step: step, in: files), id != selection {
            actions.select(id)
        }
    }
}

/// Moving through the files with the keyboard.
nonisolated enum HistoryFilesNavigation {
    /// The file `step` files from `selection` (−1 the previous, 1 the
    /// next), staying at the ends; the first when none is selected.
    static func file(after selection: String?, step: Int, in files: [HistoryFileContent]) -> String? {
        guard !files.isEmpty else {
            return nil
        }
        guard let index = selection.flatMap({ id in files.firstIndex { $0.id == id } }) else {
            return files[0].id
        }
        return files[min(max(index + step, 0), files.count - 1)].id
    }

    /// The first file whose name starts with `typed`, ignoring case.
    static func file(named typed: String, in files: [HistoryFileContent]) -> String? {
        let prefix = typed.lowercased()
        return files.first { $0.file.fileName.lowercased().hasPrefix(prefix) }?.id
    }
}

extension HistoryFiles where Menu == EmptyView {
    init(files: [HistoryFileContent], selection: String?, style: HistoryFilesStyle = .chips, actions: HistoryFilesActions = HistoryFilesActions(), focusRequest: Int = 0) {
        self.init(files: files, selection: selection, style: style, actions: actions, focusRequest: focusRequest) { _ in EmptyView() }
    }
}

/// A file as a row: the status badge, the name, its folder, and its
/// counts; the selected one accent-tinted.
struct HistoryFileRow: View {
    let content: HistoryFileContent
    var isSelected = false

    var body: some View {
        HStack(spacing: 9) {
            StatusGlyph(content.file.status)
            Text(content.file.fileName)
                .font(Typography.row.weight(.medium))
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !content.file.directory.isEmpty {
                Text(content.file.directory)
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Metrics.grid)
            HistoryLineCounts(added: content.added, deleted: content.deleted)
        }
        .padding(.horizontal, Metrics.insetSmall)
        .frame(height: Metrics.RowHeight.file)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                    .fill(.accentSoft)
            }
        }
        .padding(.horizontal, 6)
        .help(content.file.tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "+10 −2" in SF Mono, in the diff's colors; zero counts left out.
struct HistoryLineCounts: View {
    let added: Int?
    let deleted: Int?

    var body: some View {
        HStack(spacing: Metrics.grid) {
            if let added, added > 0 {
                Text("+\(formatCount(added))")
                    .foregroundStyle(Color(espalier: DiffColors.addedMarker))
            }
            if let deleted, deleted > 0 {
                Text("−\(formatCount(deleted))")
                    .foregroundStyle(Color(espalier: DiffColors.deletedMarker))
            }
        }
        .font(Typography.count)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added ?? 0) added lines, \(deleted ?? 0) removed lines")
    }
}

/// The label over the files: "CHANGED FILES 3", and the lines added and
/// removed.
struct CommitFilesHeader: View {
    let summary: CommitFilesSummary

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            SectionLabel("Changed Files", count: summary.fileCount)
                .accessibilityLabel(summary.title)
            Spacer(minLength: Metrics.grid)
            if summary.linesAdded > 0 || summary.linesDeleted > 0 {
                HistoryLineCounts(added: summary.linesAdded, deleted: summary.linesDeleted)
            }
        }
    }
}
