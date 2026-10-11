// Espalier's text input: how every text view and field editor draws its
// selection, insertion point, and spelling marks, and which of AppKit's
// text popups are off. Selected text is the accent at 24% where the text
// has focus and a neutral wash where it doesn't; the insertion point is the
// accent; a misspelled word has a wave in the error hue under it (a grammar
// issue one in the warning hue). Automatic spelling correction, text
// replacement, text completion, inline predictions, math results, and
// Writing Tools are off, since they show only as the system's popups.
//
// Espalier's own text views (`EspalierTextView`) start out this way. Every
// other text view, SwiftUI's text fields' field editors included, is set up
// when it takes focus: `TextInputStyling` watches each window's first
// responder. Selection and marks are drawn by `EspalierLayoutManager`, a
// TextKit 1 layout manager, so a view on TextKit 2 moves to TextKit 1 when
// it's set up.

import AppKit
import ObjectiveC

/// The layout manager of every text view: the selection in
/// `Palette.textSelection` (`textSelectionInactive` where the view doesn't
/// have focus or its window isn't key), and spelling and grammar marks as
/// Espalier's wave instead of the system's dots.
nonisolated final class EspalierLayoutManager: NSLayoutManager {
    /// Set while the glyphs draw, so the system draws no spelling marks of
    /// its own.
    private var isDrawingGlyphs = false

    // MARK: Selection

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let textView = textView(forCharacterRange: charRange) else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // Layout managers draw on the main thread, in their text views.
        let (selectedRanges, isActive) = MainActor.assumeIsolated {
            (textView.selectedRanges.map(\.rangeValue), Self.isActive(textView))
        }
        guard isSelection(charRange, color: color, selectedRanges: selectedRanges) else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        (isActive ? Palette.textSelection : Palette.textSelectionInactive).setFill()
        for index in 0..<rectCount {
            rectArray[index].fill(using: .sourceOver)
        }
    }

    /// Whether a fill is the selection's: its characters are selected, and
    /// it isn't their own background color.
    private func isSelection(_ charRange: NSRange, color: NSColor, selectedRanges: [NSRange]) -> Bool {
        let isSelected = selectedRanges.contains { selected in
            selected.length > 0 && NSIntersectionRange(selected, charRange) == charRange
        }
        guard isSelected, let storage = textStorage, charRange.location < storage.length else {
            return false
        }
        let background = storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor
        return background != color
    }

    /// Whether `textView` shows its selection as active: it has focus in
    /// the key window.
    @MainActor
    static func isActive(_ textView: NSTextView) -> Bool {
        guard let window = textView.window else {
            return false
        }
        return window.isKeyWindow && window.firstResponder === textView
    }

    private func textView(forCharacterRange charRange: NSRange) -> NSTextView? {
        let glyphIndex = glyphIndexForCharacter(at: charRange.location)
        return textContainer(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)?.textView ?? firstTextView
    }

    // MARK: Spelling marks

    override func temporaryAttributes(atCharacterIndex charIndex: Int, effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        var attributes = super.temporaryAttributes(atCharacterIndex: charIndex, effectiveRange: effectiveCharRange)
        if isDrawingGlyphs {
            attributes[.spellingState] = nil
        }
        return attributes
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        isDrawingGlyphs = true
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        isDrawingGlyphs = false
        drawSpellingMarks(forGlyphRange: glyphsToShow, at: origin)
    }

    /// The waves under the misspelled words and grammar issues the spell
    /// checker marked in `glyphsToShow`.
    private func drawSpellingMarks(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else {
            return
        }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var index = charRange.location
        while index < NSMaxRange(charRange) {
            var marked = NSRange()
            let state = (temporaryAttribute(.spellingState, atCharacterIndex: index, longestEffectiveRange: &marked, in: charRange) as? NSNumber)?.intValue ?? 0
            if state != 0, marked.length > 0 {
                let isSpelling = state & NSAttributedString.SpellingState.spelling.rawValue != 0
                drawWave(underCharacters: marked, color: isSpelling ? Palette.spellingMark : Palette.grammarMark, at: origin)
            }
            index = max(NSMaxRange(marked), index + 1)
        }
    }

    /// A wave under `characters`, one per line they lie on, just below the
    /// baseline.
    private func drawWave(underCharacters characters: NSRange, color: NSColor, at origin: NSPoint) {
        guard let storage = textStorage else {
            return
        }
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        let font = storage.attribute(.font, at: characters.location, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let below = min(Metrics.SpellingMark.baselineOffset, -font.descender * 0.7)
        color.setStroke()
        enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, container, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            guard part.length > 0 else {
                return
            }
            let bounds = self.boundingRect(forGlyphRange: part, in: container)
            let baseline = lineRect.minY + self.location(forGlyphAt: part.location).y
            Self.wave(
                from: origin.x + bounds.minX,
                to: origin.x + bounds.maxX,
                y: origin.y + baseline + below
            ).stroke()
        }
    }

    /// Espalier's spelling mark: a soft wave between `start` and `end`,
    /// centered on `y`.
    static func wave(from start: CGFloat, to end: CGFloat, y: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = Metrics.SpellingMark.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let half = Metrics.SpellingMark.wavelength / 2
        let amplitude = Metrics.SpellingMark.amplitude
        var x = start
        var rising = true
        path.move(to: NSPoint(x: x, y: y))
        while x < end - 0.01 {
            let next = min(x + half, end)
            // A quadratic curve's peak is half its control point's height.
            let control = NSPoint(x: (x + next) / 2, y: y + (rising ? -2 : 2) * amplitude * (next - x) / half)
            path.curve(to: NSPoint(x: next, y: y), controlPoint: control)
            rising.toggle()
            x = next
        }
        return path
    }

    // MARK: Replacing another layout manager

    /// Takes on `other`'s settings, so it lays text out as `other` did
    /// (a secure field's delegate draws its bullets).
    @MainActor
    func adoptSettings(of other: NSLayoutManager) {
        delegate = other.delegate
        glyphGenerator = other.glyphGenerator
        typesetter = other.typesetter
        typesetterBehavior = other.typesetterBehavior
        usesFontLeading = other.usesFontLeading
        allowsNonContiguousLayout = other.allowsNonContiguousLayout
        backgroundLayoutEnabled = other.backgroundLayoutEnabled
        showsInvisibleCharacters = other.showsInvisibleCharacters
        showsControlCharacters = other.showsControlCharacters
        limitsLayoutForSuspiciousContents = other.limitsLayoutForSuspiciousContents
        usesDefaultHyphenation = other.usesDefaultHyphenation
    }
}

/// Sets up a text view the Espalier way.
@MainActor
enum TextInputStyle {
    /// Gives `textView` Espalier's selection, insertion point, marked text,
    /// and spelling marks, and turns off the popups that are the system's:
    /// automatic spelling correction, text replacement, text completion,
    /// inline predictions, math results, and Writing Tools. It can run
    /// again on a view already set up.
    static func apply(to textView: NSTextView) {
        if textView.selectedTextAttributes[.backgroundColor] as? NSColor !== Palette.textSelection {
            textView.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
        textView.insertionPointColor = Palette.caret
        if textView.markedTextAttributes?[.backgroundColor] as? NSColor !== Palette.markedText {
            textView.markedTextAttributes = [.backgroundColor: Palette.markedText]
        }
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.inlinePredictionType = .no
        textView.mathExpressionCompletionType = .no
        textView.writingToolsBehavior = .none
        installLayoutManager(in: textView)
    }

    /// Puts an `EspalierLayoutManager` in `textView`'s place for its own.
    /// Asking for the layout manager moves a TextKit 2 view to TextKit 1.
    private static func installLayoutManager(in textView: NSTextView) {
        guard let container = textView.textContainer, let current = container.layoutManager, !(current is EspalierLayoutManager) else {
            return
        }
        let replacement = EspalierLayoutManager()
        replacement.adoptSettings(of: current)
        container.replaceLayoutManager(replacement)
    }
}

/// Sets up the text views of every window as they take focus: SwiftUI's
/// text fields edit in field editors of SwiftUI's own, set up each time
/// editing starts.
@MainActor
public enum TextInputStyling {
    private static var isInstalled = false
    private static var observerKey: UInt8 = 0

    /// Watches every window that becomes key: once at launch.
    public static func install() {
        guard !isInstalled else {
            return
        }
        isInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let window {
                    attach(to: window)
                }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let window {
                    detach(from: window)
                }
            }
        }
    }

    /// Sets up `window`'s first responder now and each time it changes,
    /// once per window.
    static func attach(to window: NSWindow) {
        guard objc_getAssociatedObject(window, &observerKey) == nil else {
            return
        }
        let observation = window.observe(\.firstResponder, options: [.initial, .new]) { window, _ in
            MainActor.assumeIsolated {
                if let textView = window.firstResponder as? NSTextView {
                    TextInputStyle.apply(to: textView)
                }
            }
        }
        objc_setAssociatedObject(window, &observerKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Stops watching `window` (it's closing; it's watched again if it
    /// becomes key again).
    static func detach(from window: NSWindow) {
        (objc_getAssociatedObject(window, &observerKey) as? NSKeyValueObservation)?.invalidate()
        objc_setAssociatedObject(window, &observerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

extension Metrics {
    /// The wave under a misspelled word.
    nonisolated public enum SpellingMark {
        /// One rise and fall.
        public static let wavelength: CGFloat = 4
        /// How far it rises and falls from its center line.
        public static let amplitude: CGFloat = 0.9
        public static let lineWidth: CGFloat = 1.1
        /// Its center line's distance below the baseline, at most (less in
        /// a font with a shallower descent).
        public static let baselineOffset: CGFloat = 2.2
    }
}
