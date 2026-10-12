@testable import EspalierCore
import Foundation
import Testing
import TestSupport

@Suite("Editor lookup")
struct EditorsLookupTests {
    @Suite("findEditorOrDefault")
    struct FindEditorOrDefault {
        @Test("finds the named editor, or the first one without a name")
        func finds() async throws {
            let directory = try createTempDirectory()
            let code = try makeFakeApplication(in: directory, named: "Visual Studio Code.app")
            let xcode = try makeFakeApplication(in: directory, named: "Xcode.app")
            let lookup = ExternalEditorLookup(
                locator: FakeApplicationLocator(["com.microsoft.VSCode": code, "com.apple.dt.Xcode": xcode])
            )

            #expect(try await lookup.findEditorOrDefault("Xcode") == FoundEditor(editor: "Xcode", path: xcode))
            #expect(try await lookup.findEditorOrDefault(nil) == FoundEditor(editor: "Visual Studio Code", path: code))
            // An empty name counts as none.
            #expect(try await lookup.findEditorOrDefault("") == FoundEditor(editor: "Visual Studio Code", path: code))
        }

        @Test("throws when the named editor isn't installed")
        func missing() async throws {
            let directory = try createTempDirectory()
            let code = try makeFakeApplication(in: directory, named: "Visual Studio Code.app")
            let lookup = ExternalEditorLookup(locator: FakeApplicationLocator(["com.microsoft.VSCode": code]))

            let error = await #expect(throws: ExternalEditorError.self) {
                try await lookup.findEditorOrDefault("Sublime Text")
            }
            #expect(error?.metadata == ExternalEditorError.Metadata(openPreferences: true))
        }

        @Test("returns nothing when no editor is installed, even for a name")
        func noEditors() async throws {
            let lookup = ExternalEditorLookup(locator: FakeApplicationLocator())
            #expect(try await lookup.findEditorOrDefault(nil) == nil)
            #expect(try await lookup.findEditorOrDefault("Xcode") == nil)
        }
    }

    @Suite("resolveExternalEditor")
    struct Resolution {
        @Test("returns the selected editor and the default editor separately")
        func separate() async throws {
            let directory = try createTempDirectory()
            let code = try makeFakeApplication(in: directory, named: "Visual Studio Code.app")
            let xcode = try makeFakeApplication(in: directory, named: "Xcode.app")
            let lookup = ExternalEditorLookup(
                locator: FakeApplicationLocator(["com.microsoft.VSCode": code, "com.apple.dt.Xcode": xcode])
            )
            let codeEditor = FoundEditor(editor: "Visual Studio Code", path: code)
            let xcodeEditor = FoundEditor(editor: "Xcode", path: xcode)

            #expect(
                await lookup.resolveExternalEditor("Xcode")
                    == ExternalEditorResolution(selectedEditor: xcodeEditor, defaultEditor: codeEditor)
            )
            #expect(
                await lookup.resolveExternalEditor(nil)
                    == ExternalEditorResolution(selectedEditor: nil, defaultEditor: codeEditor)
            )
        }

        @Test("doesn't replace a selected editor that isn't installed")
        func keepsMissingSelection() async throws {
            let directory = try createTempDirectory()
            let code = try makeFakeApplication(in: directory, named: "Visual Studio Code.app")
            let lookup = ExternalEditorLookup(locator: FakeApplicationLocator(["com.microsoft.VSCode": code]))

            #expect(
                await lookup.resolveExternalEditor("Sublime Text")
                    == ExternalEditorResolution(
                        selectedEditor: nil,
                        defaultEditor: FoundEditor(editor: "Visual Studio Code", path: code)
                    )
            )
            #expect(
                await ExternalEditorLookup(locator: FakeApplicationLocator()).resolveExternalEditor("Sublime Text")
                    == ExternalEditorResolution(selectedEditor: nil, defaultEditor: nil)
            )
        }
    }
}
