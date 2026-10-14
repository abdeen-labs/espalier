// Ported from desktop/app/src/lib/editors/lookup.ts

import EspalierSupport

/// Finds the installed external editors.
public final class ExternalEditorLookup: Sendable {
    private let locator: any ApplicationLocator

    /// - Parameter locator: Finds applications. By default, Launch Services.
    public init(locator: any ApplicationLocator = LaunchServicesApplicationLocator()) {
        self.locator = locator
    }

    /// Resolve a list of installed editors on the user's machine, using the
    /// known install identifiers that each OS supports.
    ///
    /// Each call looks again, so an editor installed or removed since is
    /// found or left out.
    @concurrent
    public func getAvailableEditors() async -> [FoundEditor] {
        await getAvailableEditorsDarwin(locator: locator)
    }
}

/// The installed editors behind an editor selection.
///
/// The selected editor and the default editor are found separately, never
/// substituting one for the other, so the app can keep a selected editor
/// that isn't installed: a choice is never lost because its editor is
/// missing for a moment (on a volume not yet mounted, say).
public struct ExternalEditorResolution: Sendable, Hashable {
    /// The selected editor, when one is selected and it is installed.
    public var selectedEditor: FoundEditor?
    /// The editor used when none is selected: the only one installed. Nil
    /// when none is installed, or several are, when opening asks which one
    /// to use.
    public var defaultEditor: FoundEditor?

    public init(selectedEditor: FoundEditor?, defaultEditor: FoundEditor?) {
        self.selectedEditor = selectedEditor
        self.defaultEditor = defaultEditor
    }

    /// The resolution of the editor named `selectedEditor` (nil or empty:
    /// none is selected) among the installed `editors`.
    public init(selectedEditor: String?, installed editors: [FoundEditor]) {
        let name = selectedEditor.flatMap { $0.isEmpty ? nil : $0 }
        self.selectedEditor = name.flatMap { name in
            editors.first { JSCompat.strictEquals($0.editor, name) }
        }
        defaultEditor = editors.count == 1 ? editors.first : nil
    }
}
