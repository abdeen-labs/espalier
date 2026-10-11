// Selectable text: text the user can select and copy (a drag, a double or
// triple click, ⌘A, ⌘C), drawn as SwiftUI's `Text` draws it: the same size
// for a proposal, line limit, truncation, alignment, line spacing, and
// baselines, with links in the link color that open through the environment's
// `openURL`. It's an `EspalierTextView`, so its selection is Espalier's,
// which SwiftUI's own selectable text can't show. One selection shows at a
// time: a view's selection clears when another view takes focus. It isn't
// in the key view loop, copies plain text, and VoiceOver reads it as static
// text.

import AppKit
import SwiftUI

/// Text the user can select and copy, in place of `Text` with
/// `textSelection(.enabled)`. It reads the line limit, truncation mode,
/// alignment, and line spacing from the environment, as `Text` does; its
/// font and color are given, since SwiftUI's can't be read back.
public struct SelectableText: View {
    private let text: AttributedString
    private let font: NSFont
    private let color: NSColor
    private let kerning: CGFloat
    private let accessibilityText: String?
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.truncationMode) private var truncationMode
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.lineSpacing) private var lineSpacing
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - font: A `Typography` role's AppKit twin.
    ///   - kerning: Extra space after each character, as `kerning(_:)`.
    ///   - accessibilityLabel: What VoiceOver reads instead of the text.
    public init(
        _ text: String,
        font: NSFont = AppKitTypography.row,
        color: NSColor = Palette.text,
        kerning: CGFloat = 0,
        accessibilityLabel: String? = nil
    ) {
        self.init(AttributedString(text), font: font, color: color, kerning: kerning, accessibilityLabel: accessibilityLabel)
    }

    /// Text with links, emoji, and inline styles (bold, italic, code, and
    /// strikethrough, as Markdown gives them).
    public init(
        _ text: AttributedString,
        font: NSFont = AppKitTypography.row,
        color: NSColor = Palette.text,
        kerning: CGFloat = 0,
        accessibilityLabel: String? = nil
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.kerning = kerning
        self.accessibilityText = accessibilityLabel
    }

    public var body: some View {
        let content = SelectableTextContent(
            string: SelectableTextContent.attributedString(text, font: font, color: color, kerning: kerning, paragraphStyle: paragraphStyle),
            lineLimit: lineLimit,
            truncation: truncation,
            lineSpacing: lineSpacing,
            accessibilityLabel: accessibilityText
        )
        let layout = SelectableTextLayout(content)
        // SwiftUI asks for the baselines on the main actor, as it lays out.
        SelectableTextRepresentable(content: content, layout: layout, openURL: openURL)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                let (width, height) = (dimensions.width, dimensions.height)
                return MainActor.assumeIsolated {
                    layout.firstBaseline(width: width, height: height)
                }
            }
            .alignmentGuide(.lastTextBaseline) { dimensions in
                let (width, height) = (dimensions.width, dimensions.height)
                return MainActor.assumeIsolated {
                    layout.lastBaseline(width: width, height: height)
                }
            }
    }

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if alignment == .center {
            style.alignment = .center
        } else if alignment == .trailing {
            style.alignment = layoutDirection == .rightToLeft ? .left : .right
        } else {
            style.alignment = .natural
        }
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .standard
        return style
    }

    private var truncation: NSLineBreakMode {
        if truncationMode == .head {
            return .byTruncatingHead
        }
        return truncationMode == .middle ? .byTruncatingMiddle : .byTruncatingTail
    }
}

/// What a selectable text shows: its string with every attribute, and how
/// it's limited.
struct SelectableTextContent {
    let string: NSAttributedString
    /// Nil for as many lines as the text has.
    let lineLimit: Int?
    /// How the last line shown is cut short.
    let truncation: NSLineBreakMode
    let lineSpacing: CGFloat
    let accessibilityLabel: String?

    /// `text` in `font` and `color`, with its links, and its inline styles
    /// as fonts and lines.
    static func attributedString(
        _ text: AttributedString,
        font: NSFont,
        color: NSColor,
        kerning: CGFloat,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
            if kerning != 0 {
                attributes[.kern] = kerning
            }
            if let intent = run.inlinePresentationIntent {
                attributes[.font] = styled(font, intent)
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attributes[.link] = link
            }
            if run.isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.isStruckThrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// `font` as an inline style draws it: bold, italic, or code (SF Mono
    /// at the same size).
    private static func styled(_ font: NSFont, _ intent: InlinePresentationIntent) -> NSFont {
        var styled = font
        if intent.contains(.code) {
            styled = .monospacedSystemFont(ofSize: font.pointSize, weight: intent.contains(.stronglyEmphasized) ? .bold : .regular)
        } else if intent.contains(.stronglyEmphasized) {
            styled = AppKitTypography.weighted(font, .bold)
        }
        if intent.contains(.emphasized) {
            styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask)
        }
        return styled
    }
}

/// Lays out a selectable text's string as its text view does: its size for
/// a proposal as `Text` sizes itself, the lines that fit a height, and its
/// baselines.
final class SelectableTextLayout {
    /// A line as laid out.
    struct Line {
        /// The line's rectangle, line spacing included.
        let fragment: CGRect
        /// The part of it the text takes.
        let used: CGRect
        /// The baseline, from the text's top.
        let baseline: CGFloat
    }

    private struct Key: Hashable {
        let width: CGFloat
        let maximumLines: Int
    }

    let lineLimit: Int?
    let truncation: NSLineBreakMode
    private let lineSpacing: CGFloat
    private let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    /// The lines laid out so far, by width and line limit.
    private var laidOut: [Key: [Line]] = [:]

    /// The width that stands for no limit.
    static let unbounded: CGFloat = 10_000_000
    /// How far a line may reach past a height and still count as fitting.
    private static let slack: CGFloat = 0.5

    init(_ content: SelectableTextContent) {
        lineLimit = content.lineLimit
        truncation = content.truncation
        lineSpacing = content.lineSpacing
        storage = NSTextStorage(attributedString: content.string)
        container.lineFragmentPadding = 0
        layoutManager.delegate = TextLineMetrics.shared
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    /// The size `Text` would take for `proposal`: as wide as its widest
    /// line, and as many lines as fit the proposed height (at least one),
    /// up to the line limit.
    func size(for proposal: ProposedViewSize) -> CGSize {
        let lines = visibleLines(width: Self.layoutWidth(proposal.width), height: proposal.height ?? .infinity)
        guard storage.length > 0, let last = lines.last else {
            return .zero
        }
        let width = lines.map(\.used.maxX).max() ?? 0
        return CGSize(width: ceil(width), height: ceil(bottom(of: last)))
    }

    /// How many lines a text view `width` by `height` shows: the line
    /// limit (0 for none) when they fit, else as many as fit, at least one.
    func maximumLines(width: CGFloat, height: CGFloat) -> Int {
        let limit = lineLimit ?? 0
        let all = lines(width: Self.layoutWidth(width), maximumLines: limit)
        guard let last = all.last, bottom(of: last) > height + Self.slack else {
            return limit
        }
        return max(1, all.filter { bottom(of: $0) <= height + Self.slack }.count)
    }

    /// The first baseline shown at `width` by `height`, from the top.
    func firstBaseline(width: CGFloat, height: CGFloat) -> CGFloat {
        visibleLines(width: width, height: height).first?.baseline ?? 0
    }

    /// The last baseline shown at `width` by `height`, from the top.
    func lastBaseline(width: CGFloat, height: CGFloat) -> CGFloat {
        visibleLines(width: width, height: height).last?.baseline ?? 0
    }

    private func visibleLines(width: CGFloat, height: CGFloat) -> [Line] {
        let width = Self.layoutWidth(width)
        return lines(width: width, maximumLines: maximumLines(width: width, height: height))
    }

    /// A line's bottom, without the line spacing after it: `Text` spaces
    /// lines only between them.
    private func bottom(of line: Line) -> CGFloat {
        line.fragment.maxY - max(0, min(lineSpacing, line.fragment.maxY - line.used.maxY))
    }

    /// The width to lay out at for a proposed one: no limit for none.
    private static func layoutWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else {
            return unbounded
        }
        return min(max(proposed, 1), unbounded)
    }

    private func lines(width: CGFloat, maximumLines: Int) -> [Line] {
        let key = Key(width: width, maximumLines: maximumLines)
        if let lines = laidOut[key] {
            return lines
        }
        container.size = CGSize(width: width, height: Self.unbounded)
        container.maximumNumberOfLines = maximumLines
        container.lineBreakMode = maximumLines > 0 ? truncation : .byWordWrapping
        let glyphs = layoutManager.glyphRange(for: container)
        var lines: [Line] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, lineGlyphs, _ in
            let baseline = fragment.minY + self.layoutManager.location(forGlyphAt: lineGlyphs.location).y
            lines.append(Line(fragment: fragment, used: used, baseline: baseline))
        }
        // A final line break starts an empty last line.
        let extra = layoutManager.extraLineFragmentRect
        if extra.height > 0, maximumLines == 0 || lines.count < maximumLines {
            let ascent = lines.last.map { $0.baseline - $0.fragment.minY } ?? 0
            lines.append(Line(fragment: extra, used: layoutManager.extraLineFragmentUsedRect, baseline: extra.minY + ascent))
        }
        laidOut[key] = lines
        return lines
    }
}

/// The view behind `SelectableText`.
private struct SelectableTextRepresentable: NSViewRepresentable {
    let content: SelectableTextContent
    let layout: SelectableTextLayout
    let openURL: OpenURLAction

    func makeNSView(context: Context) -> SelectableTextView {
        let view = SelectableTextView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SelectableTextView, context: Context) {
        let openURL = openURL
        view.onOpenURL = { url in
            openURL(url)
        }
        view.show(content, layout: layout)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextView, context: Context) -> CGSize? {
        layout.size(for: proposal)
    }
}

/// A text view that shows text to select and copy: not editable, without a
/// background or insets, showing as many lines as fit its height, the last
/// one truncated, as `Text` does.
final class SelectableTextView: EspalierTextView {
    /// Opens a link that's clicked.
    var onOpenURL: ((URL) -> Void)?
    /// Finds how many lines fit the view.
    private var textLayout: SelectableTextLayout?
    /// What VoiceOver reads instead of the text.
    private var accessibilityText: String?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        importsGraphics = false
        allowsUndo = false
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        layoutManager?.delegate = TextLineMetrics.shared
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        linkTextAttributes = [.foregroundColor: Palette.link, .cursor: NSCursor.pointingHand]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `content`. Text added at the end (output as it arrives) keeps
    /// the selection; any other change clears it.
    func show(_ content: SelectableTextContent, layout: SelectableTextLayout) {
        textLayout = layout
        accessibilityText = content.accessibilityLabel
        if let storage = textStorage, !storage.isEqual(to: content.string) {
            let shown = storage.length
            if shown > 0, content.string.length > shown,
               content.string.attributedSubstring(from: NSRange(location: 0, length: shown)).isEqual(to: storage) {
                storage.append(content.string.attributedSubstring(from: NSRange(location: shown, length: content.string.length - shown)))
            } else {
                storage.setAttributedString(content.string)
                setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        fitLines()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitLines()
    }

    /// Shows as many lines as fit, up to the line limit, the last one
    /// truncated when more don't.
    private func fitLines() {
        guard let textLayout, let container = textContainer else {
            return
        }
        let maximum = textLayout.maximumLines(width: bounds.width, height: bounds.height)
        if container.maximumNumberOfLines != maximum {
            container.maximumNumberOfLines = maximum
        }
        let mode = maximum > 0 ? textLayout.truncation : .byWordWrapping
        if container.lineBreakMode != mode {
            container.lineBreakMode = mode
        }
    }

    /// A clicked link opens through SwiftUI's `openURL`.
    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = link as? URL ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, let onOpenURL else {
            super.clicked(onLink: link, at: charIndex)
            return
        }
        onOpenURL(url)
    }

    /// Copies and drags plain text.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    /// Writes the selection as plain text, a line for each selected range:
    /// NSTextView writes only its own (legacy) types.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else {
            return super.writeSelection(to: pboard, type: type)
        }
        let text = selectedRanges.map { (string as NSString).substring(with: $0.rangeValue) }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
    }

    /// Tab passes it by, as it passes a label.
    override var canBecomeKeyView: Bool {
        false
    }

    /// Return, Enter, Escape, and Tab mean nothing to text that can't be
    /// edited: they go on to the views behind it (a sheet's buttons, the
    /// next field).
    override func keyDown(with event: NSEvent) {
        if Self.passedOnKeyCodes.contains(event.keyCode) {
            nextResponder?.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Return, Enter, Escape, and Tab.
    private static let passedOnKeyCodes: Set<UInt16> = [36, 76, 53, 48]

    /// Another view taking focus clears the selection: one selection shows
    /// at a time.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange().length > 0 {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        }
        return resigned
    }

    // MARK: Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    override func accessibilityValue() -> String? {
        string
    }

    override func accessibilityLabel() -> String? {
        accessibilityText ?? super.accessibilityLabel()
    }
}

/// Lays lines out as SwiftUI's `Text` does: each line as tall as its
/// tallest font's ascent and descent, each rounded up, with the baseline at
/// the rounded ascent; from one line to the next, that height or the fonts'
/// own height plus the paragraph's line spacing, whichever is more.
final class TextLineMetrics: NSObject, NSLayoutManagerDelegate {
    static let shared = TextLineMetrics()

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = layoutManager.textStorage else {
            return false
        }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var fontHeight: CGFloat = 0
        var spacing: CGFloat = 0
        storage.enumerateAttributes(in: characters) { attributes, _, _ in
            if let font = attributes[.font] as? NSFont {
                ascent = max(ascent, ceil(font.ascender))
                descent = max(descent, ceil(-font.descender))
                fontHeight = max(fontHeight, font.ascender - font.descender)
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                spacing = style.lineSpacing
            }
        }
        guard ascent > 0 else {
            return false
        }
        let height = ascent + descent
        let isLast = NSMaxRange(characters) >= storage.length
        lineFragmentRect.pointee.size.height = isLast ? height : max(height, fontHeight + spacing)
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = ascent
        return true
    }
}
