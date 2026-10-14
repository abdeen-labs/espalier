import Foundation

/// The external editor and shell settings.
///
/// Each setting has its own key; `Preferences` reads and writes each one
/// under that key (`PreferenceKey.externalEditor` and the rest).
public struct IntegrationSettings: Sendable, Hashable {
    /// The selected editor's name (`externalEditor`), or `nil` when none was
    /// ever selected.
    ///
    /// Keep the name when its editor isn't installed; see
    /// `ExternalEditorLookup.resolveExternalEditor(_:)`.
    public var selectedExternalEditor: String?
    /// The selected shell (`shell`, Terminal by default). A shell that isn't
    /// installed is kept, and opening reports it missing.
    public var selectedShell: Shell
    /// Whether to launch the custom editor instead of the selected editor
    /// (`use-custom-editor`, off by default).
    public var useCustomEditor: Bool
    /// The custom editor (`custom-editor`).
    public var customEditor: CustomIntegration?
    /// Whether to launch the custom shell instead of the selected shell
    /// (`use-custom-shell`, off by default).
    public var useCustomShell: Bool
    /// The custom shell (`custom-shell`).
    public var customShell: CustomIntegration?

    public init(
        selectedExternalEditor: String? = nil,
        selectedShell: Shell = .default,
        useCustomEditor: Bool = false,
        customEditor: CustomIntegration? = nil,
        useCustomShell: Bool = false,
        customShell: CustomIntegration? = nil
    ) {
        self.selectedExternalEditor = selectedExternalEditor
        self.selectedShell = selectedShell
        self.useCustomEditor = useCustomEditor
        self.customEditor = customEditor
        self.useCustomShell = useCustomShell
        self.customShell = customShell
    }

    /// The custom editor to launch instead of the selected editor, when
    /// `useCustomEditor` is on and one is saved.
    public var activeCustomEditor: CustomIntegration? {
        useCustomEditor ? customEditor : nil
    }

    /// The custom shell to launch instead of the selected shell, when
    /// `useCustomShell` is on and one is saved.
    public var activeCustomShell: CustomIntegration? {
        useCustomShell ? customShell : nil
    }
}
