// The components the sheets, popovers, and panels outside Changes, the
// diff, and History share, each in light and dark: the sheet scaffold with
// its capsule fields, text area, choices, and buttons, also in Orchard's
// Ink and Espresso and Pop's Tangerine; the status bar's tones with the
// step indicator; the action list; and menus drawn as capsules.

import AppKit
import EspalierCore
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Sheet components", .captures) @MainActor
struct SheetComponentCaptures {
    private let area = "Components"

    private enum Choice: Hashable {
        case leave, bring
    }

    /// A sheet: capsule fields, a text area, choices, and Cancel beside the
    /// default button at work.
    private var sheetScaffold: some View {
        SheetScaffold("Create a Branch", message: "Branches keep your work apart until it's ready.") {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Name")
                TextField("Name", text: .constant("feature/hourly-forecast"))
                    .textFieldStyle(.capsule)
                TextField("Filter", text: .constant(""), prompt: Text("Filter").fieldPrompt())
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
    }

    @Test("the sheet scaffold: a capsule field, a text area, choices, and Cancel and the default button")
    func sheetScaffoldCapture() {
        capture(sheetScaffold, named: "sheetScaffold", area: area)
    }

    @Test("the sheet scaffold in Orchard's Ink and Espresso and Pop's Tangerine", arguments: [
        Look(theme: .orchard, color: .ink),
        Look(theme: .orchard, color: .espresso),
        Look(theme: .pop, color: .tangerine),
    ])
    func sheetScaffoldInLooks(_ look: Look) {
        capture(sheetScaffold, named: "sheetScaffold", area: area, look: look)
    }

    @Test("the status bar: waiting on the user, ready, and running")
    func statusBar() {
        let view = VStack(spacing: 0) {
            StatusBar(tone: .attention, title: "Resolve conflicts before Rebase", subtitle: Text("1 of 3 files resolved")) {
                WarningGlyph()
            } trailing: {
                Button("Abort Rebase") {}
                    .buttonStyle(.quiet)
            }
            StatusBar(tone: .ready, title: "All conflicts resolved", subtitle: Text("All 3 files resolved")) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(espalier: Palette.success))
            } trailing: {
                Button("Continue Rebase") {}
                    .buttonStyle(.prominent)
            }
            StatusBar(tone: .neutral, title: "Rebase in progress", subtitle: Text("Commit 2 of 5 · Fix crash when opening an empty repository")) {
                ArcProgress(.small)
            } trailing: {
                EmptyView()
            }
        }
        .frame(width: 760)
        capture(view, named: "statusBar", area: area)
    }

    @Test("the action list: rows with symbols in circles, key caps, a chevron, and a line under a title")
    func actionList() {
        let view = ActionList([
            ActionListItem(systemImage: "arrow.down.circle", title: "Clone a Repository from the Internet…", keyCap: "⇧⌘O") {},
            ActionListItem(systemImage: "plus", title: "Create a New Repository on Your Mac…", keyCap: "⌘N") {},
            ActionListItem(systemImage: "folder", title: "Add an Existing Repository", subtitle: "From your Mac") {},
        ])
        .frame(width: 420)
        .padding(Metrics.insetLarge)
        capture(view, named: "actionList", area: area)
    }

    @Test("menus drawn as capsules: quiet, small, and with a symbol")
    func capsuleMenus() {
        let view = HStack(spacing: Metrics.insetMedium) {
            PullDownButton("Merge Options") {
                MenuAction("Create a Merge Commit") {}
            } label: {
                MenuCapsuleLabel("Create a Merge Commit")
            }
            .buttonStyle(.quiet)
            .fixedSize()
            PullDownButton("Resolve") {
                MenuAction("Use the modified file from main") {}
            } label: {
                MenuCapsuleLabel("Resolve")
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .fixedSize()
            PullDownButton("Add") {
                MenuAction("Clone Repository…") {}
            } label: {
                MenuCapsuleLabel("Add", systemImage: "plus")
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(Metrics.insetLarge)
        capture(view, named: "capsuleMenus", area: area)
    }
}
