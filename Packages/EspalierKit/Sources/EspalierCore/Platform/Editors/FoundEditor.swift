// Ported from desktop/app/src/lib/editors/found-editor.ts

/// A found external editor on the user's machine
public struct FoundEditor: Sendable, Hashable {
    /// The friendly name of the editor, to be used in labels
    public let editor: String
    /// The executable associated with the editor to launch: on macOS, the
    /// application bundle
    public let path: String

    public init(editor: String, path: String) {
        self.editor = editor
        self.path = path
    }
}
