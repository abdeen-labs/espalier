// What Espalier's menus show: content built by `MenuBuilder` from actions,
// toggles, one-of choices, sections with optional headers, dividers, and
// cascading submenus. A menu's builder runs each time the menu opens, so it
// reads the state of that moment. `MenuCard` draws the content and
// `MenuSession` runs it.

import SwiftUI

/// A menu's entries, in order.
public struct MenuContent {
    /// One entry of a menu.
    public enum Entry {
        /// An item: an action, a toggle, a resolved choice, or a submenu.
        case item(MenuItem)
        /// A choice that the enclosing `MenuPicker` or pop-up resolves
        /// into a checkable item.
        case option(MenuOption)
        /// A section's header text.
        case header(String)
        /// A hairline between groups of items.
        case divider
    }

    public var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public init(@MenuBuilder _ content: () -> MenuContent) {
        self = content()
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// The items, in order, sections' and submenus' not included.
    public var items: [MenuItem] {
        entries.compactMap { entry in
            if case .item(let item) = entry {
                return item
            }
            return nil
        }
    }
}

/// An item of a menu.
public struct MenuItem {
    /// What choosing the item does.
    public enum Action {
        case run(() -> Void)
        case submenu(MenuContent)
    }

    public var title: String
    public var systemImage: String?
    /// A second line under the title, in secondary text.
    public var subtitle: String?
    public var isDestructive: Bool
    public var isEnabled: Bool
    /// Whether the item shows a check; nil when it can't be checked.
    public var isChecked: Bool?
    /// Closes the popover the menu was opened from before it acts.
    public var closesPopover: Bool
    public var action: Action
    /// The title's font, when it isn't the row's (a font's name in that
    /// font).
    public var titleFont: Font?

    public init(
        _ title: String,
        systemImage: String? = nil,
        subtitle: String? = nil,
        isDestructive: Bool = false,
        isEnabled: Bool = true,
        isChecked: Bool? = nil,
        closesPopover: Bool = false,
        action: Action
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.closesPopover = closesPopover
        self.action = action
    }

    /// The submenu, if the item opens one.
    public var submenu: MenuContent? {
        if case .submenu(let content) = action {
            return content
        }
        return nil
    }
}

/// A choice before its picker resolves it: its title and the value it
/// selects.
public struct MenuOption {
    public var title: String
    public var value: AnyHashable
    public var systemImage: String?
    public var subtitle: String?
    public var isEnabled: Bool
    /// The title's font, when it isn't the row's.
    public var titleFont: Font?

    /// The checkable item choosing it selects `value` through `select`;
    /// checked when `value` is `selected`.
    func item(selected: AnyHashable?, select: @escaping (AnyHashable) -> Void) -> MenuItem {
        let value = value
        var item = MenuItem(
            title,
            systemImage: systemImage,
            subtitle: subtitle,
            isEnabled: isEnabled,
            isChecked: value == selected,
            action: .run { select(value) }
        )
        item.titleFont = titleFont
        return item
    }
}

// MARK: - The builder

/// Something a `MenuBuilder` takes; it becomes menu content.
public protocol MenuElement {
    var menuContent: MenuContent { get }
}

extension MenuContent: MenuElement {
    public var menuContent: MenuContent {
        self
    }
}

/// Builds a menu's content from actions, toggles, choices, sections,
/// dividers, and submenus, with `if`, `switch`, and `for`.
@resultBuilder
public enum MenuBuilder {
    public static func buildExpression(_ element: some MenuElement) -> MenuContent {
        element.menuContent
    }

    public static func buildBlock(_ parts: MenuContent...) -> MenuContent {
        MenuContent(parts.flatMap(\.entries))
    }

    public static func buildOptional(_ part: MenuContent?) -> MenuContent {
        part ?? MenuContent()
    }

    public static func buildEither(first part: MenuContent) -> MenuContent {
        part
    }

    public static func buildEither(second part: MenuContent) -> MenuContent {
        part
    }

    public static func buildArray(_ parts: [MenuContent]) -> MenuContent {
        MenuContent(parts.flatMap(\.entries))
    }

    public static func buildLimitedAvailability(_ part: MenuContent) -> MenuContent {
        part
    }
}

/// An item that runs an action.
public struct MenuAction: MenuElement {
    private var item: MenuItem

    /// - Parameters:
    ///   - subtitle: A second line under the title.
    ///   - role: `.destructive` draws the title in the error color.
    public init(_ title: String, systemImage: String? = nil, subtitle: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        item = MenuItem(title, systemImage: systemImage, subtitle: subtitle, isDestructive: role == .destructive, action: .run(action))
    }

    /// Disables the item: it shows faded and can't be chosen.
    public func disabled(_ isDisabled: Bool) -> MenuAction {
        var copy = self
        copy.item.isEnabled = item.isEnabled && !isDisabled
        return copy
    }

    /// Closes the popover the menu was opened from before the action runs.
    public func closesPopover(_ closes: Bool = true) -> MenuAction {
        var copy = self
        copy.item.closesPopover = closes
        return copy
    }

    public var menuContent: MenuContent {
        MenuContent([.item(item)])
    }
}

/// An item with a check while it's on; choosing it turns it on or off.
public struct MenuToggle: MenuElement {
    private var item: MenuItem

    public init(_ title: String, systemImage: String? = nil, isOn: Binding<Bool>) {
        item = MenuItem(title, systemImage: systemImage, isChecked: isOn.wrappedValue, action: .run {
            isOn.wrappedValue.toggle()
        })
    }

    /// - Parameter action: Runs when the item is chosen, to turn it on or
    ///   off.
    public init(_ title: String, systemImage: String? = nil, isOn: Bool, action: @escaping () -> Void) {
        item = MenuItem(title, systemImage: systemImage, isChecked: isOn, action: .run(action))
    }

    public func disabled(_ isDisabled: Bool) -> MenuToggle {
        var copy = self
        copy.item.isEnabled = item.isEnabled && !isDisabled
        return copy
    }

    public var menuContent: MenuContent {
        MenuContent([.item(item)])
    }
}

/// A choice of a `MenuPicker` or a pop-up: checked while its value is the
/// selection, and choosing it selects its value.
public struct MenuChoice: MenuElement {
    private var option: MenuOption

    public init(_ title: String, value: some Hashable, systemImage: String? = nil, subtitle: String? = nil) {
        option = MenuOption(title: title, value: AnyHashable(value), systemImage: systemImage, subtitle: subtitle, isEnabled: true)
    }

    /// The choice with its title in `font`.
    public func titleFont(_ font: Font?) -> MenuChoice {
        var copy = self
        copy.option.titleFont = font
        return copy
    }

    public func disabled(_ isDisabled: Bool) -> MenuChoice {
        var copy = self
        copy.option.isEnabled = option.isEnabled && !isDisabled
        return copy
    }

    public var menuContent: MenuContent {
        MenuContent([.option(option)])
    }
}

/// One-of choices inline in a menu, bound to a selection: the chosen one
/// shows a check.
public struct MenuPicker<Value: Hashable>: MenuElement {
    private let selection: Binding<Value>
    private let content: MenuContent

    public init(selection: Binding<Value>, @MenuBuilder content: () -> MenuContent) {
        self.selection = selection
        self.content = content()
    }

    public var menuContent: MenuContent {
        content.resolvingOptions(selection: selection)
    }
}

/// A group of entries, set off by dividers, under optional header text.
public struct MenuSection: MenuElement {
    private let header: String?
    private let content: MenuContent

    public init(_ header: String? = nil, @MenuBuilder content: () -> MenuContent) {
        self.header = header
        self.content = content()
    }

    public var menuContent: MenuContent {
        guard !content.isEmpty else {
            return MenuContent()
        }
        return MenuContent([.divider] + (header.map { [.header($0)] } ?? []) + content.entries + [.divider])
    }
}

/// A hairline between groups of items.
public struct MenuDivider: MenuElement {
    public init() {}

    public var menuContent: MenuContent {
        MenuContent([.divider])
    }
}

/// An item that opens a cascading menu of its content.
public struct Submenu: MenuElement {
    private var item: MenuItem

    public init(_ title: String, systemImage: String? = nil, @MenuBuilder content: () -> MenuContent) {
        item = MenuItem(title, systemImage: systemImage, action: .submenu(content()))
    }

    /// Disables the item: it shows faded and its menu doesn't open.
    public func disabled(_ isDisabled: Bool) -> Submenu {
        var copy = self
        copy.item.isEnabled = item.isEnabled && !isDisabled
        return copy
    }

    public var menuContent: MenuContent {
        MenuContent([.item(item)])
    }
}

// MARK: - Resolving and tidying

extension MenuContent {
    /// The content with its choices resolved against `selection`, nested
    /// submenus' included.
    public func resolvingOptions<Value: Hashable>(selection: Binding<Value>) -> MenuContent {
        resolvingOptions(selected: AnyHashable(selection.wrappedValue)) { value in
            if let value = value.base as? Value {
                selection.wrappedValue = value
            }
        }
    }

    /// The content with its choices resolved: checked when their value is
    /// `selected`, and selecting through `select`.
    func resolvingOptions(selected: AnyHashable?, select: @escaping (AnyHashable) -> Void) -> MenuContent {
        MenuContent(entries.map { entry in
            switch entry {
            case .option(let option):
                return .item(option.item(selected: selected, select: select))
            case .item(var item):
                if case .submenu(let content) = item.action {
                    item.action = .submenu(content.resolvingOptions(selected: selected, select: select))
                }
                return .item(item)
            case .header, .divider:
                return entry
            }
        })
    }

    /// The content as a menu shows it: choices left unresolved become
    /// disabled items, a header with nothing under it goes, and dividers
    /// never lead, trail, or follow one another (or a header). Submenus
    /// are tidied too.
    public var tidied: MenuContent {
        var result: [Entry] = []
        for entry in entries {
            switch entry {
            case .divider:
                if let last = result.last, !last.isDivider, !last.isHeader {
                    result.append(.divider)
                }
            case .header:
                if result.last?.isHeader == true {
                    result.removeLast()
                }
                result.append(entry)
            case .option(let option):
                var item = option.item(selected: nil) { _ in }
                item.isEnabled = false
                result.append(.item(item))
            case .item(var item):
                if case .submenu(let content) = item.action {
                    item.action = .submenu(content.tidied)
                }
                result.append(.item(item))
            }
        }
        while let last = result.last, last.isDivider || last.isHeader {
            result.removeLast()
        }
        return MenuContent(result)
    }
}

extension MenuContent.Entry {
    var isDivider: Bool {
        if case .divider = self {
            return true
        }
        return false
    }

    var isHeader: Bool {
        if case .header = self {
            return true
        }
        return false
    }
}
