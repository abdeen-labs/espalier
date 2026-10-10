// How the menus find the window they act on. The main window publishes its
// `WindowContext` as a focused scene value; menus read it with
// `@FocusedValue(WindowContext.self)` and disable themselves while another
// window is key (Settings or About). With no window key (the main window is
// minimized), they act on the main window's context and bring the window
// back (`MenuTarget`).
//
// Lists inside the inner split's panes publish their selection for Edit ▸
// Delete and Copy Path through `WindowState.focusedSelection` rather than
// focused values: the panes are hosted in their own `NSHostingView`s, whose
// focused values don't reach the scene's commands.

import SwiftUI

extension View {
    /// Publishes a list's selection for Edit ▸ Delete (⌘⌫) and Copy Path
    /// (⌥⌘C) while the list has keyboard focus.
    public func focusedSelection(_ selection: FocusedSelection?) -> some View {
        modifier(FocusedSelectionPublisher(selection: selection))
    }
}

/// Publishes a selection while the view has focus.
private struct FocusedSelectionPublisher: ViewModifier {
    let selection: FocusedSelection?
    @Environment(WindowContext.self) private var context: WindowContext?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused, initial: true) {
                publish()
            }
            .onChange(of: selection?.deleteTitle) {
                publish()
            }
    }

    private func publish() {
        guard let context, let owner = selection?.owner else {
            return
        }
        context.state.setFocusedSelection(isFocused ? selection : nil, owner: owner)
    }
}
