// Ported in part from desktop/app/src/ui/rename-branch/rename-branch-dialog.tsx
//
// Branch ▸ Rename… (⇧⌘R), a branch row's Rename…, and the branch segment's
// open the sheet.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the Rename Branch sheet shows.
nonisolated public struct RenameBranchSheetContent: Sendable, Equatable {
    public var branchName: String
    /// The branch's upstream, when it tracks one: renaming doesn't rename
    /// it.
    public var upstream: String?

    public init(branchName: String, upstream: String?) {
        self.branchName = branchName
        self.upstream = upstream
    }

    public var title: String {
        "Rename Branch"
    }

    /// The warning for a tracking branch.
    public var remoteWarning: String? {
        upstream.map { "This branch tracks \($0). Renaming it won't change the branch's name on the remote." }
    }
}

/// The Rename Branch sheet: the new name, and Rename.
public struct RenameBranchSheet: View {
    static let sheetID = "espalier.renameBranch"

    private let content: RenameBranchSheetContent
    private let branches: [Branch]
    private let checkRules: (@MainActor (String) async -> BranchNameRuleError?)?
    private let onRename: (String) -> Void
    @State private var name: String
    @State private var ruleCheck: BranchNameRuleCheck?
    @FocusState private var isNameFocused: Bool
    @Environment(\.dismissModal) private var dismissModal

    /// - Parameters:
    ///   - checkRules: Asks the repository's rules about a name
    ///     (`checkBranchNameRules`); the prefilled name is checked when the
    ///     sheet opens.
    public init(
        _ content: RenameBranchSheetContent,
        branches: [Branch],
        checkRules: (@MainActor (String) async -> BranchNameRuleError?)? = nil,
        onRename: @escaping (String) -> Void
    ) {
        self.content = content
        self.branches = branches
        self.checkRules = checkRules
        self.onRename = onRename
        _name = State(initialValue: content.branchName)
    }

    public var body: some View {
        let basic = BranchNameValidation.validate(name, branches: branches, verb: "saved", currentName: content.branchName)
        let validation = BranchNameRuleCheck.applying(ruleCheck, to: basic)
        let isUnchanged = JSCompat.strictEquals(validation.sanitizedName, content.branchName)
        SheetScaffold(content.title) {
            if let warning = content.remoteWarning {
                Label {
                    Text(warning)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    WarningGlyph()
                }
                .font(Typography.secondary)
            }
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                TextField("Name", text: $name, prompt: Text("Branch name"))
                    .textFieldStyle(.capsule)
                    .focused($isNameFocused)
                    .onSubmit { rename(validation, isUnchanged: isUnchanged) }
                NameValidationMessages(validation)
            }
        } buttons: {
            SheetButtons("Rename", isConfirmDisabled: !validation.isValid || isUnchanged, cancel: { dismissModal() }) {
                rename(validation, isUnchanged: isUnchanged)
            }
        }
        .onAppear {
            isNameFocused = true
        }
        .task(id: basic) {
            if let check = await BranchNameRuleCheck.run(basic, with: checkRules) {
                ruleCheck = check
            }
        }
    }

    private func rename(_ validation: BranchNameValidation, isUnchanged: Bool) {
        guard validation.isValid, !isUnchanged else {
            return
        }
        let name = validation.sanitizedName
        dismissModal()
        onRename(name)
    }

    /// Shows the sheet for `branch`.
    static func present(_ branch: Branch, in context: WindowContext) {
        guard let repository = context.repository else {
            return
        }
        context.modals.presentSheet(id: sheetID) {
            RenameBranchSheet(
                RenameBranchSheetContent(branchName: branch.name, upstream: branch.upstream),
                branches: repository.gitState.branches.all,
                checkRules: { [weak repository] name in
                    await repository?.gitHub.checkBranchNameRules(name)
                }
            ) { [weak context] name in
                guard let context else {
                    return
                }
                Task {
                    await BranchActions.rename(branch, to: name, in: context)
                }
            }
        }
    }
}
