// Create a New Repository (⌘N): Name, Description, Local Path, the README
// checkbox, Git Ignore and License (featured licenses first, then a
// divider), "The repository will be created at <path>.", and its warnings:
// the folder is a repository already (with Add This Repository Instead),
// it's inside one, or a README, .gitignore, or LICENSE would be
// overwritten. A folder with files says how many will wait in Changes, as
// git would list them with the Git Ignore template chosen. Creating is the
// app's intent (`createRepository`); its errors show in the sheet,
// and the failures of later steps once it closes.

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// The Create sheet's state.
@MainActor @Observable
final class CreateRepositorySheetModel {
    @ObservationIgnored let app: AppModel
    var name: String
    var description = ""
    var basePath: String
    var createsReadme = false
    var gitIgnore: String?
    var license: String?
    /// Whether the base path is remembered for next time: not when the sheet
    /// was opened for a folder.
    let remembersBasePath: Bool
    /// What's at the folder, as last checked.
    private(set) var destination = CreateRepositoryDestination()
    /// The folder `destination` is for.
    private(set) var checkedPath: String?
    /// The files already in the folder, as last listed.
    private(set) var existingFiles = CreateRepositoryExistingFiles()
    /// The folder and Git Ignore template `existingFiles` are for.
    private(set) var listedFor: ExistingFilesKey?
    private(set) var isCreating = false
    /// Why creating failed, shown in the sheet.
    var problem: String?

    /// - Parameter folder: A folder to create the repository in (Add's
    ///   "Create a Repository…"): its name and the folder it's in.
    init(app: AppModel, folder: String? = nil) {
        self.app = app
        if let folder {
            name = POSIXPath.basename(folder)
            basePath = POSIXPath.dirname(folder)
            remembersBasePath = false
        } else {
            name = ""
            basePath = app.preferences.lastCloneLocation
            remembersBasePath = true
        }
    }

    var request: CreateRepositoryRequest {
        CreateRepositoryRequest(
            name: name,
            description: description,
            basePath: basePath,
            createsReadme: createsReadme,
            gitIgnore: gitIgnore,
            license: license,
            remembersBasePath: remembersBasePath
        )
    }

    var fullPath: String? {
        request.fullPath
    }

    /// The checks of the folder as it is now, once they've run.
    var currentDestination: CreateRepositoryDestination {
        checkedPath != nil && checkedPath == fullPath ? destination : CreateRepositoryDestination()
    }

    /// Whether Create Repository can be pressed.
    var canCreate: Bool {
        fullPath != nil && !isCreating && !currentDestination.isRepository
    }

    /// What the existing files are listed for: the folder and the Git Ignore
    /// template.
    var existingFilesKey: ExistingFilesKey? {
        fullPath.map { ExistingFilesKey(path: $0, gitIgnore: gitIgnore) }
    }

    /// The note about the folder's files that will wait in Changes ("This
    /// folder already has 3 files, …"); nil when there are none, or before
    /// they're listed.
    var existingFilesNote: String? {
        guard let key = existingFilesKey, listedFor == key, !currentDestination.isRepository else {
            return nil
        }
        let count = existingFiles.uncommittedCount(request)
        guard count > 0 else {
            return nil
        }
        let other = existingFiles.overwrittenCount(request) > 0 ? " other" : ""
        let files = count == 1 ? "1\(other) file" : "\(formatNumber(Double(count), app.preferences.numberFormat))\(other) files"
        return "This folder already has \(files), which you can commit from Changes."
    }

    /// Checks the folder: whether it's a repository, and which of the files
    /// creating writes it has.
    func checkDestination() async {
        guard let path = fullPath else {
            checkedPath = nil
            return
        }
        let destination = await checkCreateRepositoryDestination(path)
        // Only if the full path is still what we were checking.
        guard fullPath == path else {
            return
        }
        record(destination, for: path)
    }

    /// Lists the folder's files that would wait in Changes, with the Git
    /// Ignore template chosen.
    func listExistingFiles() async {
        guard let key = existingFilesKey else {
            listedFor = nil
            return
        }
        let files = await checkCreateRepositoryExistingFiles(key.path, gitIgnore: key.gitIgnore)
        // Only if they're still what we were listing them for.
        guard !Task.isCancelled, existingFilesKey == key else {
            return
        }
        existingFiles = files
        listedFor = key
    }

    /// Checks the folder and lists its files again each time Espalier
    /// becomes active while the sheet shows: files may have been added or
    /// removed meanwhile, or the folder made a repository. Runs until the
    /// calling task is cancelled.
    func checkOnActivation() async {
        let app = app
        await Observing.eachActivation({ app.isActive }) {
            await checkDestination()
            await listExistingFiles()
        }
    }

    /// Records what's at `path` (the checks' result).
    func record(_ destination: CreateRepositoryDestination, for path: String) {
        self.destination = destination
        checkedPath = path
    }

    /// Creates the repository. Its errors become `problem`.
    func create(presenter: WindowPresenter) async -> CreateRepositoryResult? {
        guard canCreate else {
            return nil
        }
        problem = nil
        isCreating = true
        defer { isCreating = false }
        let app = app
        let request = request
        do throws(OperationError) {
            return try await presenter.performThrowing { _ throws(OperationError) in
                try await app.createRepository(request)
            }
        } catch {
            problem = error.message
            return nil
        }
    }
}

/// What a folder's existing files are listed for.
struct ExistingFilesKey: Hashable {
    /// The folder.
    var path: String
    /// The Git Ignore template, whose patterns are added.
    var gitIgnore: String?
}

/// The Create sheet.
struct CreateRepositorySheet: View {
    static let sheetID = "repository.create"

    @State var model: CreateRepositorySheetModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss

    var body: some View {
        CreateRepositoryForm(model: model, cancel: { dismiss() }, create: create, addInstead: addInstead)
            .task(id: model.fullPath) {
                await model.checkDestination()
            }
            .task(id: model.existingFilesKey) {
                await model.listExistingFiles()
            }
            .task {
                await model.checkOnActivation()
            }
    }

    private func create() {
        let model = model
        let context = context
        Task {
            guard let result = await model.create(presenter: context.presenter) else {
                return
            }
            dismiss()
            for failure in result.failures {
                context.presenter.present(failure)
            }
        }
    }

    /// Add This Repository Instead: the folder is a repository already.
    private func addInstead() {
        guard let path = model.fullPath else {
            return
        }
        let context = context
        dismiss()
        Task { await RepositoryActions.addRepositories([path], in: context) }
    }

    /// Shows the sheet, for a folder when one is given.
    static func present(forFolder folder: String? = nil, in context: WindowContext) {
        context.state.isRepositoryPopoverPresented = false
        let model = CreateRepositorySheetModel(app: context.app, folder: folder)
        context.modals.presentSheet(id: sheetID) {
            CreateRepositorySheet(model: model)
        }
    }
}

/// The Create sheet's form.
struct CreateRepositoryForm: View {
    @Bindable var model: CreateRepositorySheetModel
    var cancel: () -> Void = {}
    var create: () -> Void = {}
    var addInstead: () -> Void = {}
    @FocusState private var isNameFocused: Bool

    /// Where submodules are explained (git's book).
    static let submodulesURL = URL(string: "https://git-scm.com/book/en/v2/Git-Tools-Submodules")!

    var body: some View {
        SheetScaffold("Create a New Repository") {
            Form {
                // The labels in the form's column; the fields are capsules.
                LabeledContent("Name") {
                    TextField("Name", text: $model.name, prompt: Text("repository name").fieldPrompt())
                        .labelsHidden()
                        .focused($isNameFocused)
                }
                LabeledContent("Description") {
                    TextField("Description", text: $model.description)
                        .labelsHidden()
                }
                FolderField(label: "Local Path", path: $model.basePath) {
                    FolderChooser.chooseFolder(startingAt: model.basePath) { path in
                        model.basePath = path
                    }
                }
                warnings
                if let note = model.existingFilesNote {
                    FieldMessage(note, kind: .note)
                }
                Toggle("Initialize this repository with a README", isOn: $model.createsReadme)
                    .toggleStyle(.checkboxMark)
                if model.createsReadme, model.currentDestination.readmeExists {
                    FieldMessage(
                        "This folder already has a README.md file, which will be overwritten.",
                        kind: .warning
                    )
                }
                // The pop-ups as wide as the fields.
                LabeledContent("Git Ignore") {
                    CapsulePopUp("Git Ignore", selection: $model.gitIgnore, title: model.gitIgnore ?? "None") {
                        MenuChoice("None", value: String?.none)
                        MenuDivider()
                        for name in RepositoryTemplates.gitIgnoreNames {
                            MenuChoice(name, value: Optional(name))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.gitIgnore != nil, model.currentDestination.gitIgnoreExists {
                    FieldMessage(
                        "This folder already has a .gitignore file, which will be overwritten.",
                        kind: .warning
                    )
                }
                LabeledContent("License") {
                    CapsulePopUp("License", selection: $model.license, title: model.license ?? "None") {
                        MenuChoice("None", value: String?.none)
                        for license in RepositoryTemplates.featuredLicenses {
                            MenuChoice(license.name, value: Optional(license.name))
                        }
                        MenuDivider()
                        for license in RepositoryTemplates.otherLicenses {
                            MenuChoice(license.name, value: Optional(license.name))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.license != nil, model.currentDestination.licenseExists {
                    FieldMessage(
                        "This folder already has a LICENSE file, which will be overwritten.",
                        kind: .warning
                    )
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)

            if let problem = model.problem {
                FieldMessage(problem, kind: .error)
            }
            if let fullPath = model.fullPath, !model.currentDestination.isRepository {
                Text("The repository will be created at \(Text(fullPath).font(Typography.sha)).")
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            SheetButtons(
                "Create Repository",
                isConfirmDisabled: !model.canCreate,
                isWorking: model.isCreating,
                cancel: cancel,
                confirm: create
            )
        }
        .onAppear {
            isNameFocused = true
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if let fullPath = model.fullPath {
            let destination = model.currentDestination
            if destination.isRepository {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    FieldMessage("\(fullPath) is already a Git repository.", kind: .error)
                    Button("Add This Repository Instead", action: addInstead)
                        .buttonStyle(.textLink)
                }
            } else if destination.isSubfolderOfRepository {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    FieldMessage("\(fullPath) is inside another Git repository.", kind: .warning)
                    TextLink("Learn about submodules.", destination: Self.submodulesURL)
                        .font(Typography.subheadline)
                }
            }
        }
    }
}
