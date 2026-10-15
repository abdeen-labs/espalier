// Open With starts on the editor chosen in Settings, whatever the order of
// the installed editors.

@testable import EspalierCore
import EspalierCoreTestSupport
import Testing
@testable import EspalierUI

@Suite("Open With") @MainActor
struct OpenWithTests {
    private func makeApp() throws -> AppModel {
        let app = try AppHarness().makeApp()
        app.integrations.availableEditors = [
            FoundEditor(editor: "Xcode", path: "/Applications/Xcode.app"),
            FoundEditor(editor: "Visual Studio Code", path: "/Applications/Visual Studio Code.app"),
        ]
        return app
    }

    private func openWith(_ app: AppModel) -> OpenWithModel {
        OpenWithModel(integrations: app.integrations, settings: app.preferences.integrations, path: "/tmp/repository")
    }

    @Test("starts on the editor chosen in Settings, and on the first editor with none chosen")
    func selectedEditor() throws {
        let app = try makeApp()
        #expect(openWith(app).choice == .named("Xcode"))
        app.integrations.selectEditor("Visual Studio Code")
        #expect(openWith(app).choice == .named("Visual Studio Code"))
    }

    @Test("starts on the custom editor chosen in Settings, with its path and arguments")
    func customEditor() throws {
        let app = try makeApp()
        var settings = app.preferences.integrations
        settings.customEditor = CustomIntegration(path: "/usr/local/bin/subl", arguments: "-n %TARGET_PATH%")
        settings.useCustomEditor = true
        app.preferences.integrations = settings

        let model = openWith(app)
        #expect(model.choice == .configure)
        #expect(model.customPath == "/usr/local/bin/subl")
        #expect(model.customArguments == "-n %TARGET_PATH%")
    }
}
