// Ported from desktop/app/src/lib/editors/lookup.ts

import EspalierSupport
import Synchronization

/// Finds the installed external editors and the one to launch.
///
/// The app keeps one `ExternalEditorLookup` for its life, so its cache of
/// installed editors lasts as long.
public final class ExternalEditorLookup: Sendable {
    private let locator: any ApplicationLocator
    private let editorCache = Mutex<[FoundEditor]?>(nil)

    /// - Parameter locator: Finds applications. By default, Launch Services.
    public init(locator: any ApplicationLocator = LaunchServicesApplicationLocator()) {
        self.locator = locator
    }

    /// Resolve a list of installed editors on the user's machine, using the
    /// known install identifiers that each OS supports.
    ///
    /// The list is cached once it contains an editor. Until then, every call
    /// looks again, so an editor installed later is found without a restart.
    @concurrent
    public func getAvailableEditors() async -> [FoundEditor] {
        if let cached = editorCache.withLock({ $0 }), !cached.isEmpty {
            return cached
        }

        let editors = await getAvailableEditorsDarwin(locator: locator)
        editorCache.withLock { $0 = editors }
        return editors
    }

    /// Find an editor installed on the machine using the friendly name, or
    /// the first valid editor if `nil` is provided.
    ///
    /// Returns `nil` if no editors are found, and throws if the editor name
    /// cannot be found (i.e. it has been removed).
    @concurrent
    public func findEditorOrDefault(_ name: String?) async throws(ExternalEditorError) -> FoundEditor? {
        let editors = await getAvailableEditors()
        guard let first = editors.first else {
            return nil
        }

        // An empty name also means "the first valid editor".
        if let name, !name.isEmpty {
            guard let match = editors.first(where: { JSCompat.strictEquals($0.editor, name) }) else {
                throw ExternalEditorError(
                    "Espalier couldn't find the editor \(name). Choose an available editor in Settings ▸ Integrations.",
                    metadata: ExternalEditorError.Metadata(openPreferences: true)
                )
            }

            return match
        }

        return first
    }

    /// Finds the selected editor and the default editor separately, never
    /// substituting one for the other, so the app can keep a selected editor
    /// that isn't installed.
    ///
    /// A choice is never lost because its editor is missing for a moment (on
    /// a volume not yet mounted, say). With both editors in hand, the store
    /// can keep the stored choice and still find the editor
    /// `findEditorOrDefault` would launch: the default editor when nothing is
    /// selected, otherwise the selected editor, or the "could not be found"
    /// error when it's missing.
    @concurrent
    public func resolveExternalEditor(_ selectedEditor: String?) async -> ExternalEditorResolution {
        let editors = await getAvailableEditors()
        let selected = selectedEditor.flatMap { name in
            editors.first { JSCompat.strictEquals($0.editor, name) }
        }
        return ExternalEditorResolution(selectedEditor: selected, defaultEditor: editors.first)
    }
}

/// The installed editors behind an editor selection. See
/// `ExternalEditorLookup.resolveExternalEditor(_:)`.
public struct ExternalEditorResolution: Sendable, Hashable {
    /// The selected editor, when one is selected and it is installed.
    public var selectedEditor: FoundEditor?
    /// The first installed editor, used when no editor is selected; `nil`
    /// when no editor is installed.
    public var defaultEditor: FoundEditor?

    public init(selectedEditor: FoundEditor?, defaultEditor: FoundEditor?) {
        self.selectedEditor = selectedEditor
        self.defaultEditor = defaultEditor
    }
}
