// Menu items that run the window's actions, titled, enabled, and checked
// as the menu bar's items are. In-window menus build from them.

import SwiftUI

extension WindowActions {
    /// An item that runs `action`, titled (unless `title` says otherwise)
    /// and enabled as its menu bar item is.
    func menuAction(_ action: ActionID, title: String? = nil, systemImage: String? = nil, subtitle: String? = nil) -> MenuAction {
        MenuAction(title ?? self.title(for: action), systemImage: systemImage, subtitle: subtitle) { [self] in
            perform(action)
        }
        .disabled(!canPerform(action))
    }

    /// A check-marked item that runs `action`, checked as its menu bar item
    /// is.
    func menuToggle(_ action: ActionID) -> MenuToggle {
        MenuToggle(title(for: action), isOn: isChecked(action)) { [self] in
            perform(action)
        }
        .disabled(!canPerform(action))
    }
}
