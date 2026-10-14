// A list of suggestions under a text field or the word being typed, in
// Espalier's menu card: rows 24 high, each a suggestion with an optional
// detail after it in tertiary text, the highlighted one the soft accent. It
// shows in an `AnchoredPanel` that takes clicks but never keys, so focus
// stays in the text: ↑ and ↓ move the highlight, Return or Tab accepts it,
// Escape closes the list, and typing goes on in the text, whose owner shows
// the suggestions again for what's typed (the list closes when none are
// left). A click on a suggestion accepts it; a click elsewhere closes the
// list and goes on. The list also closes when the text's editing ends, its
// insertion point moves away from what's being completed, and as the
// panel closes (Espalier going to the background, its window moving). One
// list is open at a time, and `MenuEventRouter` reads the app's events for
// it. VoiceOver hears how many suggestions there are and the one
// highlighted.
//
// `textFieldSuggestions(_:text:)` gives a SwiftUI text field the list.

import AppKit
import SwiftUI

/// A suggestion the list shows.
struct Suggestion: Equatable, Identifiable {
    /// What the list shows, and what accepting it inserts.
    var title: String
    /// What the list shows after it: a user's name, an issue's title.
    var detail: String?

    var id: String {
        title
    }
}

/// What the list shows: the suggestions, the one highlighted, and the
/// card's narrowest width.
@MainActor @Observable
final class SuggestionListModel {
    var suggestions: [Suggestion] = []
    var highlighted = 0
    /// The card is at least this wide (a field's capsule).
    var minimumWidth: CGFloat = 0
    /// The rows' frames in the card's root coordinates (its shadow margin
    /// included), as last laid out.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]

    /// The row whose frame contains `point` (in the card's root
    /// coordinates).
    func row(at point: CGPoint) -> Int? {
        rowFrames.first { $0.value.contains(point) }?.key
    }
}

/// A text's list of suggestions: shown, updated, and closed by the text's
/// owner as what's typed changes.
@MainActor
final class SuggestionList {
    /// The list that's open, if any.
    private(set) static var current: SuggestionList?

    let model = SuggestionListModel()
    private(set) var isOpen = false
    /// Says what VoiceOver hears (tests record it).
    var announcer = Announcer.voiceOver

    /// The text whose typing the list follows: a field's editor for a
    /// field.
    private weak var textView: NSTextView?
    private var onAccept: ((Suggestion) -> Void)?
    private var stillApplies: ((NSTextView) -> Bool)?
    private var panel: AnchoredPanel?
    private var hosting: NSHostingView<SuggestionListCardRoot>?
    private var container: SuggestionPanelView?
    private weak var anchorView: NSView?
    private var anchor = CGRect.zero
    private var observers: [any NSObjectProtocol] = []
    /// The row a mouse press in the card went down on.
    private var pressedRow: Int?

    /// The space before a suggestion's text in the card: an anchor moved
    /// left by it lines the suggestions' text up with the text typed.
    static let textInset = Metrics.Menu.inset + Metrics.Menu.rowPadding

    /// Shows `suggestions` for typing in `textView`, the card below
    /// `anchor` (in `view`'s coordinates) at least `minimumWidth` wide; no
    /// suggestions close the list. Shown again while open, it keeps the
    /// highlighted suggestion when it's still there.
    ///
    /// - Parameters:
    ///   - accept: Inserts the suggestion accepted, once the list closed.
    ///   - stillApplies: Whether the suggestions still apply to the text
    ///     after its selection changed (the insertion point is still at
    ///     what's being completed); nil for always.
    func show(
        _ suggestions: [Suggestion],
        for textView: NSTextView,
        below anchor: CGRect,
        in view: NSView,
        minimumWidth: CGFloat = 0,
        accept: @escaping (Suggestion) -> Void,
        stillApplies: ((NSTextView) -> Bool)? = nil
    ) {
        guard !suggestions.isEmpty, view.window != nil else {
            close()
            return
        }
        if isOpen, textView !== self.textView {
            close()
        }
        onAccept = accept
        self.stillApplies = stillApplies
        let wasOpen = isOpen
        let highlightedTitle = wasOpen && model.suggestions.indices.contains(model.highlighted) ? model.suggestions[model.highlighted].title : nil
        model.suggestions = suggestions
        model.minimumWidth = minimumWidth
        model.highlighted = highlightedTitle.flatMap { title in suggestions.firstIndex { $0.title == title } } ?? 0
        if wasOpen, view === anchorView, anchor == self.anchor {
            resize()
        } else {
            open(for: textView, below: anchor, in: view)
        }
        if !wasOpen {
            announcer.announce(suggestions.count == 1 ? "1 suggestion" : "\(suggestions.count) suggestions", priority: .medium)
        }
    }

    /// Closes the list.
    func close() {
        guard isOpen else {
            return
        }
        isOpen = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        panel?.onClose = nil
        panel?.close(reason: .closed)
        panel = nil
        hosting = nil
        container = nil
        pressedRow = nil
        if Self.current === self {
            Self.current = nil
        }
    }

    // MARK: Showing

    private func open(for textView: NSTextView, below anchor: CGRect, in view: NSView) {
        if Self.current !== self {
            Self.current?.close()
        }
        if isOpen {
            close()
        }
        self.textView = textView
        anchorView = view
        self.anchor = anchor
        let hosting = NSHostingView(rootView: SuggestionListCardRoot(model: model, motionSuppressed: !Motion.animates(view)))
        hosting.sizingOptions = [.intrinsicContentSize]
        let container = SuggestionPanelView()
        container.addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
        let panel = AnchoredPanel(interaction: .menu)
        panel.contentInsets = Metrics.Menu.shadowInsets
        panel.onClose = { [weak self] _ in
            self?.close()
        }
        self.hosting = hosting
        self.container = container
        self.panel = panel
        isOpen = true
        Self.current = self
        observe(textView)
        MenuEventRouter.shared.install()
        place()
    }

    /// Sizes the card for the suggestions and puts it below the anchor.
    private func place() {
        guard let panel, let hosting, let container, let view = anchorView else {
            return
        }
        let size = fittingSize(of: hosting)
        container.frame = CGRect(origin: .zero, size: size)
        hosting.frame = container.bounds
        panel.show(container, contentSize: size, anchor: anchor, in: view, placement: AnchoredPanel.Placement(edge: .below, alignment: .leading, gap: Metrics.Menu.gap))
        container.layoutSubtreeIfNeeded()
    }

    /// Sizes the card for new suggestions, where it is.
    private func resize() {
        guard let panel, let hosting, let container else {
            return
        }
        let size = fittingSize(of: hosting)
        panel.resize(to: size, animated: false)
        container.frame = CGRect(origin: .zero, size: size)
        container.layoutSubtreeIfNeeded()
    }

    /// The card's size, its shadow margin included, in whole points.
    private func fittingSize(of hosting: NSView) -> CGSize {
        let size = hosting.fittingSize
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Closes the list when the text's editing ends, or when its selection
    /// moves away from what the suggestions complete.
    private func observe(_ textView: NSTextView) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSText.didEndEditingNotification, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.close()
                }
            },
            center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main) { [weak self] notification in
                let textView = notification.object as? NSTextView
                MainActor.assumeIsolated {
                    guard let self, let textView, let stillApplies = self.stillApplies, !stillApplies(textView) else {
                        return
                    }
                    self.close()
                }
            },
        ]
    }

    // MARK: Events

    /// What the list did with an event.
    enum EventResult: Equatable {
        /// Used up: nothing else sees it.
        case consumed
        /// Left for the app to handle as usual.
        case passed
    }

    /// Handles an event of the app's while the list is open.
    @discardableResult
    func handle(_ event: NSEvent) -> EventResult {
        guard isOpen else {
            return .passed
        }
        guard let textView, let window = textView.window, window.firstResponder === textView else {
            close()
            return .passed
        }
        switch event.type {
        case .keyDown:
            return event.window === window ? handleKey(event, in: textView) : .passed
        case .mouseMoved:
            if let row = row(atScreen: MenuSession.screenLocation(of: event)) {
                highlight(row)
            }
            return .passed
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = MenuSession.screenLocation(of: event)
            guard let panel, panel.contentFrame.contains(point) else {
                close()
                return .passed
            }
            pressedRow = row(atScreen: point)
            return .consumed
        case .leftMouseUp:
            let point = MenuSession.screenLocation(of: event)
            guard let panel, panel.contentFrame.contains(point) else {
                pressedRow = nil
                return .passed
            }
            if let row = row(atScreen: point), row == pressedRow {
                accept(row)
            }
            pressedRow = nil
            return .consumed
        default:
            return .passed
        }
    }

    private func handleKey(_ event: NSEvent, in textView: NSTextView) -> EventResult {
        guard !textView.hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return .passed
        }
        switch event.keyCode {
        case KeyCode.downArrow:
            highlight(min(model.highlighted + 1, model.suggestions.count - 1))
        case KeyCode.upArrow:
            highlight(max(model.highlighted - 1, 0))
        case KeyCode.returnKey, KeyCode.enter, KeyCode.tab:
            accept(model.highlighted)
        case KeyCode.escape:
            close()
        default:
            return .passed
        }
        return .consumed
    }

    /// Highlights `row`, telling VoiceOver the suggestion it shows.
    private func highlight(_ row: Int) {
        guard model.suggestions.indices.contains(row), row != model.highlighted else {
            return
        }
        model.highlighted = row
        let suggestion = model.suggestions[row]
        announcer.announce([suggestion.title, suggestion.detail].compactMap { $0 }.joined(separator: ", "))
    }

    /// Closes the list and accepts the suggestion in `row`.
    private func accept(_ row: Int) {
        guard model.suggestions.indices.contains(row), let onAccept else {
            return
        }
        let suggestion = model.suggestions[row]
        close()
        onAccept(suggestion)
    }

    /// The row at `point` on screen.
    private func row(atScreen point: CGPoint) -> Int? {
        guard let panel, let hosting, panel.contentFrame.contains(point) else {
            return nil
        }
        return model.row(at: hosting.convert(panel.convertPoint(fromScreen: point), from: nil))
    }

    /// A row's rect on screen, once laid out.
    func screenFrame(ofRow row: Int) -> CGRect? {
        guard let panel, let hosting, let frame = model.rowFrames[row] else {
            return nil
        }
        return panel.convertToScreen(hosting.convert(frame, to: nil))
    }
}

/// The suggestion list's panel view: it holds the card, and its tracking
/// area makes the panel get mouse moves though it's never key.
@MainActor
final class SuggestionPanelView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {}

    override func isAccessibilityElement() -> Bool {
        false
    }
}

// MARK: - The card

/// The card with the environment its panel gives it.
struct SuggestionListCardRoot: View {
    let model: SuggestionListModel
    let motionSuppressed: Bool

    var body: some View {
        SuggestionListCard(model: model)
            .environment(\.motionSuppressed, motionSuppressed)
            .lookFont()
    }
}

/// The suggestions drawn as Espalier's menu card, scrolling past
/// `Metrics.Suggestions.visibleRows` rows, which fade out toward an end
/// with more past it, as a menu's do. It fades and grows very slightly
/// from its top as it opens, except under Reduce Motion and offscreen;
/// what's typed changes it at once.
struct SuggestionListCard: View {
    let model: SuggestionListModel
    @Environment(\.motion) private var motion
    @State private var hasAppeared = false
    @State private var scrollEdges = MenuScrollEdges()

    static let coordinateSpace = "Espalier.SuggestionListCard"

    var body: some View {
        let isShown = hasAppeared || !motion.animates
        card
            .scaleEffect(isShown ? 1 : Metrics.Menu.growthScale, anchor: .top)
            .opacity(isShown ? 1 : 0)
            .padding(EdgeInsets(Metrics.Menu.shadowInsets))
            .coordinateSpace(.named(Self.coordinateSpace))
            .onPreferenceChange(SuggestionRowFrames.self) { [model] frames in
                MainActor.assumeIsolated {
                    model.rowFrames = frames
                }
            }
            .onAppear {
                withMotion(motion, Motion.menuArrive) {
                    hasAppeared = true
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var card: some View {
        Group {
            if model.suggestions.count > Metrics.Suggestions.visibleRows {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        rows
                    }
                    .scrollIndicators(.never)
                    .onScrollGeometryChange(for: MenuScrollEdges.self) { geometry in
                        MenuScrollEdges(geometry)
                    } action: { _, edges in
                        scrollEdges = edges
                    }
                    .mask {
                        MenuScrollFade(edges: scrollEdges)
                    }
                    .frame(height: CGFloat(Metrics.Suggestions.visibleRows) * Metrics.Menu.rowHeight + 2 * Metrics.Menu.inset)
                    .onChange(of: model.highlighted) { _, row in
                        proxy.scrollTo(row)
                    }
                }
            } else {
                rows
            }
        }
        .frame(minWidth: max(model.minimumWidth, Metrics.Menu.minimumWidth), alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .surface(.quiet, elevation: .floating, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, suggestion in
                SuggestionListRow(suggestion: suggestion, isHighlighted: index == model.highlighted)
                    .id(index)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: SuggestionRowFrames.self, value: [index: proxy.frame(in: .named(Self.coordinateSpace))])
                        }
                    }
            }
        }
        .padding(Metrics.Menu.inset)
    }
}

/// One suggestion: its text, then its detail in tertiary text, on the
/// soft accent while highlighted.
private struct SuggestionListRow: View {
    let suggestion: Suggestion
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Suggestions.detailSpacing) {
            Text(suggestion.title)
                .font(Typography.row)
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let detail = suggestion.detail {
                Text(detail)
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: Metrics.Suggestions.textMaximumWidth, alignment: .leading)
        .padding(.horizontal, Metrics.Menu.rowPadding)
        .frame(height: Metrics.Menu.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                .fill(isHighlighted ? AnyShapeStyle(.accentSoft) : AnyShapeStyle(.clear))
        )
    }
}

/// The rows' frames, by index.
private struct SuggestionRowFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension Metrics {
    /// Suggestion lists: the menu card's rows, scrolling past a few.
    public enum Suggestions {
        /// The rows shown before the list scrolls.
        public static let visibleRows = 8
        /// Between a suggestion and its detail.
        public static let detailSpacing: CGFloat = 8
        /// A suggestion and its detail are cut past this width.
        public static let textMaximumWidth: CGFloat = 380
    }
}

// MARK: - A SwiftUI text field's suggestions

extension View {
    /// Suggestions for the text field this is applied to, in Espalier's
    /// suggestion list under it, at least as wide: shown as `text` changes
    /// while the field is being edited, and updated as `suggestions` do.
    /// Accepting one replaces the field's text with it.
    func textFieldSuggestions(_ suggestions: [String], text: String) -> some View {
        modifier(TextFieldSuggestionsModifier(suggestions: suggestions, text: text))
    }
}

private struct TextFieldSuggestionsModifier: ViewModifier {
    let suggestions: [String]
    let text: String
    @State private var controller = TextFieldSuggestions()

    func body(content: Content) -> some View {
        content
            .background {
                SuggestionAnchorRepresentable(controller: controller)
                    .accessibilityHidden(true)
            }
            .onChange(of: text) { _, text in
                controller.textChanged(to: text, suggestions: suggestions)
            }
            .onChange(of: suggestions) { _, suggestions in
                controller.suggestionsChanged(suggestions)
            }
            .onDisappear {
                controller.list.close()
            }
    }
}

/// A SwiftUI text field's suggestion list, and the view behind the field
/// it opens below.
@MainActor
final class TextFieldSuggestions {
    let list = SuggestionList()
    weak var anchor: SuggestionAnchorView?
    /// The suggestion last accepted: the text change it makes shows no
    /// list.
    private var accepted: String?

    /// The field's text changed: shows the suggestions while it's being
    /// edited, unless the change is a suggestion accepted.
    func textChanged(to text: String, suggestions: [String]) {
        if let accepted, accepted == text {
            self.accepted = nil
            return
        }
        accepted = nil
        show(suggestions)
    }

    /// The suggestions changed: an open list shows them.
    func suggestionsChanged(_ suggestions: [String]) {
        if list.isOpen {
            show(suggestions)
        }
    }

    private func show(_ suggestions: [String]) {
        guard let anchor, let editor = anchor.editedTextView else {
            list.close()
            return
        }
        list.show(suggestions.map { Suggestion(title: $0) }, for: editor, below: anchor.bounds, in: anchor, minimumWidth: anchor.bounds.width) { [weak self, weak editor] suggestion in
            guard let self, let editor else {
                return
            }
            accepted = suggestion.title
            editor.insertText(suggestion.title, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
    }
}

/// The view behind a SwiftUI text field with suggestions: the list opens
/// below it. It draws nothing and takes no clicks.
@MainActor
final class SuggestionAnchorView: NSView {
    /// The editor of the text field in front of this view, while it's
    /// being edited.
    var editedTextView: NSTextView? {
        guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.window === window else {
            return nil
        }
        let frame = convert(bounds, to: nil)
        let fieldFrame = field.convert(field.bounds, to: nil)
        return frame.contains(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)) ? editor : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

private struct SuggestionAnchorRepresentable: NSViewRepresentable {
    let controller: TextFieldSuggestions

    func makeNSView(context: Context) -> SuggestionAnchorView {
        let view = SuggestionAnchorView()
        controller.anchor = view
        return view
    }

    func updateNSView(_ view: SuggestionAnchorView, context: Context) {
        controller.anchor = view
    }
}
