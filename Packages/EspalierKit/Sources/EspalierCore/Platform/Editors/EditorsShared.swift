// Ported from desktop/app/src/lib/editors/shared.ts

import Foundation

/// An error from finding or launching an external editor.
public struct ExternalEditorError: Error, LocalizedError, Sendable, Hashable {
    /// What the error dialog offers besides closing.
    public struct Metadata: Sendable, Hashable {
        /// The error dialog should link off to the default editor's website
        public var suggestDefaultEditor: Bool
        /// The error dialog should direct the user to open Settings
        public var openPreferences: Bool

        public init(suggestDefaultEditor: Bool = false, openPreferences: Bool = false) {
            self.suggestDefaultEditor = suggestDefaultEditor
            self.openPreferences = openPreferences
        }
    }

    public let message: String
    /// The error's metadata.
    public let metadata: Metadata

    public init(_ message: String, metadata: Metadata = Metadata()) {
        self.message = message
        self.metadata = metadata
    }

    public var errorDescription: String? {
        message
    }
}

/// The editor suggested when no supported editor is installed.
public struct SuggestedExternalEditor: Sendable, Hashable {
    public let name: String
    public let url: String
}

public let suggestedExternalEditor = SuggestedExternalEditor(
    name: "Visual Studio Code",
    url: "https://code.visualstudio.com"
)

extension ExternalEditorError {
    /// The error reported when an editor should open but none is installed
    /// (`findEditorOrDefault` returns nothing).
    public static var noSuitableEditorInstalled: ExternalEditorError {
        ExternalEditorError(
            "Espalier couldn't find a supported editor. Install \(suggestedExternalEditor.name), then restart Espalier and try again.",
            metadata: Metadata(suggestDefaultEditor: true)
        )
    }
}
