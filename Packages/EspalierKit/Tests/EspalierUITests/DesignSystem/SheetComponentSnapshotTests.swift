// The components the sheets, popovers, and panels outside Changes, the
// diff, and History share, each in light and dark: the sheet scaffold with
// its capsule fields, text area, choices, and buttons; the status bar's
// tones with the step indicator; the palette's search field and rows; the
// action list; and menus drawn as capsules.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Sheet components") @MainActor
struct SheetComponentSnapshotTests {
    private let area = "Components"

    private enum Choice: Hashable {
        case leave, bring
    }

    @Test("the sheet scaffold: a capsule field, a text area, choices, and Cancel and the default button")
    func sheetScaffold() {
        let view = SheetScaffold("Create a Branch", message: "Branches keep your work apart until it's ready.") {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Name")
                TextField("Name", text: .constant("feature/hourly-forecast"))
                    .textFieldStyle(.capsule)
                TextField("Filter", text: .constant(""), prompt: Text("Filter"))
                    .textFieldStyle(.capsule(systemImage: "magnifyingglass"))
                TextField("Disabled", text: .constant("Can't change"))
                    .textFieldStyle(.capsule)
                    .disabled(true)
            }
            Text("Requests hourly data with the daily forecast.")
                .font(Typography.row)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .textAreaSurface()
            ChoiceList("Base", selection: .constant(Choice.leave), choices: [
                ChoiceListItem("Leave my changes on main", description: "Your in-progress work will be stashed on this branch.", value: .leave),
                ChoiceListItem("Bring my changes to feature/login", description: "Your in-progress work will follow you.", value: .bring),
            ])
        } buttons: {
            SheetButtons("Create Branch", isWorking: true, cancel: {}, confirm: {})
        }
        assertSnapshot(view, named: "sheetScaffold", area: area)
    }

    @Test("the status bar: waiting on the user, ready, and running; the step indicator's segments and bar")
    func statusBar() {
        let view = VStack(spacing: 0) {
            StatusBar(tone: .attention, title: "Resolve conflicts before Rebase", subtitle: Text("1 of 3 conflicted files has been resolved.")) {
                WarningGlyph()
            } trailing: {
                StepIndicator([.done, .stopped, .stopped], label: "1 of 3")
                Button("Abort Rebase") {}
                    .buttonStyle(.quiet)
                Button("Continue Rebase") {}
                    .buttonStyle(.prominent)
                    .disabled(true)
            }
            StatusBar(tone: .ready, title: "All conflicts resolved", subtitle: Text("All conflicted files have been resolved.")) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(espalier: Palette.success))
            } trailing: {
                StepIndicator([.done, .done, .done], label: "3 of 3")
                Button("Continue Rebase") {}
                    .buttonStyle(.prominent)
            }
            StatusBar(tone: .neutral, title: "Rebase in progress", subtitle: Text("Commit 2 of 5 · Fix crash when opening an empty repository")) {
                ArcProgress(.small)
            } trailing: {
                StepIndicator(StepIndicator.steps(position: 2, total: 5), label: "Commit 2 of 5")
            }
            StatusBar(tone: .neutral, title: "Rebase in progress", subtitle: Text("Commit 14 of 40")) {
                ArcProgress(.small)
            } trailing: {
                StepIndicator(StepIndicator.steps(position: 14, total: 40), label: "Commit 14 of 40")
            }
        }
        .frame(width: 760)
        assertSnapshot(view, named: "statusBar", area: area)
    }

    @Test("the palette: its search field, a section label, rows, and the highlighted row on the accent")
    func paletteList() {
        let rows: [(name: String, detail: String, isHighlighted: Bool)] = [
            ("main", "2 hr ago", true),
            ("fix/locale-units", "3 hr ago", false),
        ]
        let view = VStack(alignment: .leading, spacing: 0) {
            PaletteSearchField("Filter branches", text: .constant(""), systemImage: "arrow.trianglehead.branch")
            SectionLabel("Recent Branches")
                .padding(.horizontal, Metrics.PaletteList.inset + Metrics.PaletteList.rowHorizontalPadding)
                .padding(.top, Metrics.PaletteList.sectionTopPadding)
                .padding(.bottom, Metrics.PaletteList.sectionBottomPadding)
            ForEach(rows, id: \.name) { row in
                PaletteProbeRow(name: row.name, detail: row.detail)
                    .paletteRow(isHighlighted: row.isHighlighted)
                    .padding(.horizontal, Metrics.PaletteList.inset)
            }
            SectionLabel("Selected in a sheet's list")
                .padding(.horizontal, Metrics.PaletteList.inset + Metrics.PaletteList.rowHorizontalPadding)
                .padding(.top, Metrics.PaletteList.sectionTopPadding)
                .padding(.bottom, Metrics.PaletteList.sectionBottomPadding)
            Text("octo-org/website")
                .foregroundStyle(.text)
                .selectableRow(isSelected: true)
                .padding(.horizontal, Metrics.ListRow.inset)
        }
        .padding(.bottom, Metrics.insetSmall)
        .frame(width: 380)
        assertSnapshot(view, named: "paletteList", area: area)
    }

    @Test("the action list: rows with symbols, key caps, and a chevron")
    func actionList() {
        let view = ActionList([
            ActionListItem(systemImage: "arrow.down.circle", title: "Clone a Repository from the Internet…", keyCap: "⇧⌘O") {},
            ActionListItem(systemImage: "plus", title: "Create a New Repository on Your Mac…", keyCap: "⌘N") {},
            ActionListItem(systemImage: "folder", title: "Add an Existing Repository", subtitle: "From your Mac") {},
        ])
        .frame(width: 420)
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "actionList", area: area)
    }

    @Test("menus drawn as capsules: quiet, small, and with a symbol")
    func capsuleMenus() {
        let view = HStack(spacing: Metrics.insetMedium) {
            Menu {
                Button("Create a merge commit") {}
            } label: {
                MenuCapsuleLabel("Create a merge commit")
            }
            .menuStyle(.button)
            .buttonStyle(.quiet)
            .menuIndicator(.hidden)
            .fixedSize()
            Menu {
                Button("Use the modified file from main") {}
            } label: {
                MenuCapsuleLabel("Resolve")
            }
            .menuStyle(.button)
            .buttonStyle(.quiet)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            Menu {
                Button("Clone Repository…") {}
            } label: {
                MenuCapsuleLabel("Add", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.quiet)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "capsuleMenus", area: area)
    }
}

/// A row reading `backgroundProminence`, as the palettes' rows do.
private struct PaletteProbeRow: View {
    let name: String
    let detail: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let colors = PaletteRowColors(prominence)
        HStack(spacing: Metrics.insetSmall) {
            Circle()
                .fill(colors.mark(.accentColor))
                .frame(width: Metrics.Sidebar.dotSize, height: Metrics.Sidebar.dotSize)
            Text(name)
                .font(Typography.row.weight(.medium))
                .foregroundStyle(colors.primary)
            Text("current")
                .font(Typography.tinyCount)
                .foregroundStyle(colors.secondary)
                .padding(.horizontal, Metrics.BranchPicker.currentTagPadding)
                .frame(height: Metrics.BranchPicker.currentTagHeight)
                .background(Capsule(style: .circular).fill(colors.tagFill))
            Spacer()
            Text(detail)
                .font(Typography.meta)
                .foregroundStyle(colors.tertiary)
        }
    }
}
