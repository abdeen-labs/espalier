@testable import EspalierCore
import Foundation
import Testing
import TestSupport

@Suite("macOS editors")
struct EditorsDarwinTests {
    @Test("finds installed editors in the list's order")
    func detection() async throws {
        let directory = try createTempDirectory()
        let zed = try makeFakeApplication(in: directory, named: "Zed.app")
        let code = try makeFakeApplication(in: directory, named: "Visual Studio Code.app")
        let xcode = try makeFakeApplication(in: directory, named: "Xcode.app")
        let locator = FakeApplicationLocator([
            "dev.zed.Zed": zed,
            "com.apple.dt.Xcode": xcode,
            "com.microsoft.VSCode": code,
        ])

        #expect(
            await getAvailableEditorsDarwin(locator: locator) == [
                FoundEditor(editor: "Visual Studio Code", path: code),
                FoundEditor(editor: "Xcode", path: xcode),
                FoundEditor(editor: "Zed", path: zed),
            ]
        )
    }

    @Test("uses the first bundle identifier whose application exists")
    func firstIdentifierWins() async throws {
        let directory = try createTempDirectory()
        let oss = try makeFakeApplication(in: directory, named: "Code - OSS.app")
        let codium = try makeFakeApplication(in: directory, named: "VSCodium.app")
        let sublime3 = try makeFakeApplication(in: directory, named: "Sublime Text 3.app")
        let sublime2 = try makeFakeApplication(in: directory, named: "Sublime Text 2.app")

        let locator = FakeApplicationLocator([
            "com.visualstudio.code.oss": oss,
            "com.vscodium": codium,
            // Launch Services remembers a deleted application.
            "com.sublimetext.4": "\(directory)/Sublime Text.app",
            "com.sublimetext.3": sublime3,
            "com.sublimetext.2": sublime2,
        ])

        let editors = await getAvailableEditorsDarwin(locator: locator)
        #expect(editors == [
            FoundEditor(editor: "VSCodium", path: oss),
            FoundEditor(editor: "Sublime Text", path: sublime3),
        ])
    }

    @Test("skips an editor whose only application was deleted")
    func deletedApplication() async throws {
        let directory = try createTempDirectory()
        let locator = FakeApplicationLocator(["com.microsoft.VSCode": "\(directory)/Visual Studio Code.app"])
        #expect(await getAvailableEditorsDarwin(locator: locator).isEmpty)
    }
}
