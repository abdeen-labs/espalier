@testable import EspalierCore
import Foundation
import Testing
import TestSupport

@Suite("Editor lookup")
struct EditorsLookupTests {
    @Test("each lookup looks again: an editor installed since is found, one removed is left out")
    func looksAgain() async throws {
        let directory = try createTempDirectory()
        let code = try makeFakeApplication(in: directory, named: "Visual Studio Code.app")
        let zed = try makeFakeApplication(in: directory, named: "Zed.app")
        let locator = MutableApplicationLocator()
        let lookup = ExternalEditorLookup(locator: locator)
        #expect(await lookup.getAvailableEditors().isEmpty)

        locator.install("dev.zed.Zed", at: zed)
        #expect(await lookup.getAvailableEditors() == [FoundEditor(editor: "Zed", path: zed)])

        locator.install("com.microsoft.VSCode", at: code)
        locator.remove("dev.zed.Zed")
        #expect(await lookup.getAvailableEditors() == [FoundEditor(editor: "Visual Studio Code", path: code)])
    }

    @Suite("ExternalEditorResolution")
    struct Resolution {
        private static let code = FoundEditor(editor: "Visual Studio Code", path: "/Applications/Visual Studio Code.app")
        private static let xcode = FoundEditor(editor: "Xcode", path: "/Applications/Xcode.app")

        @Test("finds the selected editor and the default editor separately; the default is the only one installed")
        func separate() {
            #expect(
                ExternalEditorResolution(selectedEditor: "Xcode", installed: [Self.code, Self.xcode])
                    == ExternalEditorResolution(selectedEditor: Self.xcode, defaultEditor: nil)
            )
            #expect(
                ExternalEditorResolution(selectedEditor: "Xcode", installed: [Self.xcode])
                    == ExternalEditorResolution(selectedEditor: Self.xcode, defaultEditor: Self.xcode)
            )
            // With several installed and none selected, there's no default:
            // opening asks.
            #expect(
                ExternalEditorResolution(selectedEditor: nil, installed: [Self.code, Self.xcode])
                    == ExternalEditorResolution(selectedEditor: nil, defaultEditor: nil)
            )
            // An empty name counts as none.
            #expect(
                ExternalEditorResolution(selectedEditor: "", installed: [Self.code])
                    == ExternalEditorResolution(selectedEditor: nil, defaultEditor: Self.code)
            )
        }

        @Test("doesn't replace a selected editor that isn't installed")
        func keepsMissingSelection() {
            #expect(
                ExternalEditorResolution(selectedEditor: "Sublime Text", installed: [Self.code])
                    == ExternalEditorResolution(selectedEditor: nil, defaultEditor: Self.code)
            )
            #expect(
                ExternalEditorResolution(selectedEditor: "Sublime Text", installed: [])
                    == ExternalEditorResolution(selectedEditor: nil, defaultEditor: nil)
            )
        }
    }
}
