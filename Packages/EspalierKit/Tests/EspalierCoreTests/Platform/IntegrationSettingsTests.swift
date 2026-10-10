@testable import EspalierCore
import Testing

/// The shapes the integration settings are saved in.
@Suite("Integration settings")
struct IntegrationSettingsTests {
    @Test("launches a custom integration only when it's turned on and saved")
    func activeCustomIntegrations() {
        let custom = CustomIntegration(path: "/usr/local/bin/tool", arguments: "%TARGET_PATH%")

        #expect(IntegrationSettings(useCustomEditor: true, customEditor: custom).activeCustomEditor == custom)
        #expect(IntegrationSettings(useCustomEditor: false, customEditor: custom).activeCustomEditor == nil)
        #expect(IntegrationSettings(useCustomEditor: true).activeCustomEditor == nil)
        #expect(IntegrationSettings(useCustomShell: true, customShell: custom).activeCustomShell == custom)
        #expect(IntegrationSettings(useCustomShell: false, customShell: custom).activeCustomShell == nil)
    }
}
