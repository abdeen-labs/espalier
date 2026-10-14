// Ported in part from desktop/app/src/ui/diff/diff-search-input.tsx
//
// The diff's find bar: a floating capsule at the diff's top trailing
// corner, where desktop hangs its search box. The field searches as it's
// typed in, the count beside it ("3 of 12"); the chevrons, Return and
// Shift-Return, and ⌘G and ⇧⌘G move between matches; Escape and Done close
// it, leaving the current match selected in the diff. While the field has
// focus the bar takes ⌘F (selecting the query), ⌘G, and ⇧⌘G itself, before
// the field could take Edit ▸ Find's commands. It fades in, settling from
// 97%, over 0.22 s and fades out over 0.15 s.

import AppKit
import SwiftUI

extension Metrics {
    /// The diff's find bar.
    enum DiffFind {
        /// The field's width, at most and at least.
        static let fieldWidth: CGFloat = 220
        static let minimumFieldWidth: CGFloat = 96
        /// Between the bar's edge and its controls.
        static let padding: CGFloat = 5
        /// Between the bar's controls.
        static let spacing: CGFloat = 2
        /// The bar's distance from the diff's top edge, and from its sides.
        static let topInset: CGFloat = Metrics.insetSmall
        static let sideInset: CGFloat = Metrics.insetLarge
        /// The band at the diff's top the bar covers: a match scrolled into
        /// view stays below it.
        static var coveredHeight: CGFloat {
            topInset + Metrics.ControlHeight.regular + padding * 2
        }
    }
}

/// The find bar: the field and its count, the chevrons, and Done.
struct DiffFindBar: View {
    @Bindable var find: DiffFindModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.DiffFind.spacing) {
            field
            Button {
                find.findPrevious()
            } label: {
                chevron("Previous Match", systemImage: "chevron.up")
            }
            .buttonStyle(.icon)
            .tooltip("Previous Match (⇧⌘G)")
            .disabled(find.matches.isEmpty)
            Button {
                find.findNext()
            } label: {
                chevron("Next Match", systemImage: "chevron.down")
            }
            .buttonStyle(.icon)
            .tooltip("Next Match (⌘G)")
            .disabled(find.matches.isEmpty)
            Button("Done") {
                find.close()
            }
            .buttonStyle(.secondary)
            .padding(.leading, Metrics.DiffFind.spacing)
        }
        .padding(Metrics.DiffFind.padding)
        .floatingSurface()
        // A click on the chevrons leaves the field focused.
        .fieldRegion()
        .background {
            shortcuts
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in Diff")
    }

    /// The field: the magnifying glass, the query, and the count.
    private var field: some View {
        HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.text3)
                .accessibilityHidden(true)
            TextField("Find in Diff", text: $find.query, prompt: Text("Find in Diff").fieldPrompt())
                .textFieldStyle(.plain)
                // AppKit's one-line mode: a pasted line break becomes a
                // space.
                .lineLimit(1)
                .font(Typography.row)
                .foregroundStyle(.text)
                .focused($isFocused)
                .onKeyPress(.return, phases: [.down, .repeat]) { press in
                    if press.modifiers.contains(.shift) {
                        find.findPrevious()
                    } else {
                        find.findNext()
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    find.close()
                    return .handled
                }
                // The line's inset from the capsule's top, as in the
                // capsule search field.
                .padding(.top, (Metrics.ControlHeight.regular - Metrics.CapsuleField.lineHeight) / 2)
                .frame(maxHeight: .infinity, alignment: .top)
                .announcesFilterResults(find.query) { [find] in
                    find.matches.count
                }
            if let count = find.countText {
                Text(count)
                    .font(find.matches.isEmpty ? Typography.secondary : Typography.count)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(find.countAccessibilityLabel ?? count)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: Metrics.DiffFind.minimumFieldWidth, maxWidth: Metrics.DiffFind.fieldWidth)
        .frame(height: Metrics.ControlHeight.regular)
        .background(Capsule(style: .circular).fill(.field))
        .overlay {
            CapsuleFocusRing(isFocused: isFocused)
        }
        .contentShape(Capsule(style: .circular))
        .onTapGesture {
            isFocused = true
        }
        .onChange(of: find.focusRequest, initial: true) {
            if find.focusRequest {
                isFocused = true
                find.focusRequest = false
            }
        }
    }

    private func chevron(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
        }
    }

    /// ⌘F, ⌘G, and ⇧⌘G while the field has focus, read from the key event
    /// itself (SwiftUI's keyboard shortcuts match ⌘G and ⇧⌘G to either of
    /// two buttons).
    private var shortcuts: some View {
        FindKeyEquivalents(isActive: isFocused) { key in
            switch key {
            case .selectQuery:
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case .next:
                find.findNext()
            case .previous:
                find.findPrevious()
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// The bar arriving (fading in and settling from 97% over 0.22 s) and
    /// leaving (fading out over 0.15 s); none where motion doesn't run.
    static func transition(animates: Bool) -> AnyTransition {
        guard animates else {
            return .identity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)).animation(Motion.animation(Motion.arrive)),
            removal: .opacity.animation(Motion.animation(Motion.leave))
        )
    }
}

/// The find bar's key equivalents.
private enum FindKey {
    case selectQuery, next, previous
}

/// Takes ⌘F, ⌘G, and ⇧⌘G from the window's key equivalents while active.
private struct FindKeyEquivalents: NSViewRepresentable {
    let isActive: Bool
    let perform: (FindKey) -> Void

    func makeNSView(context: Context) -> FindKeyEquivalentView {
        FindKeyEquivalentView()
    }

    func updateNSView(_ view: FindKeyEquivalentView, context: Context) {
        view.perform = isActive ? perform : nil
    }
}

/// The view behind `FindKeyEquivalents`: it draws nothing and takes no
/// clicks.
private final class FindKeyEquivalentView: NSView {
    var perform: ((FindKey) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let perform, event.type == .keyDown else {
            return false
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("f", [.command]):
            perform(.selectQuery)
        case ("g", [.command]):
            perform(.next)
        case ("g", [.command, .shift]):
            perform(.previous)
        default:
            return false
        }
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
