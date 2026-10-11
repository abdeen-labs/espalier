// Espalier's text area: multi-line plain text to edit (a squashed commit's
// description, the ignored files' patterns), in place of SwiftUI's
// `TextEditor`. It's an `EspalierTextView` in a scroll view without a
// background, so the area's surface (`textAreaSurface()`, a card) shows
// through; its selection, insertion point, spelling marks, and scroller are
// Espalier's, and the system's text popups are off. Its text starts at its
// top edge, inset by the line fragment padding as `TextEditor`'s did, so a
// placeholder laid over it lines up the same way. Disabled, it can't be
// edited and fades to 45%.

import AppKit
import SwiftUI

/// Multi-line plain text to edit.
struct TextArea: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = AppKitTypography.row
    var textColor: NSColor = Palette.text
    /// What VoiceOver calls it.
    var accessibilityLabel: String?
    /// Told when it takes focus and loses it.
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TextAreaTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = Metrics.TextArea.lineFragmentPadding
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.useEspalierScrollers()
        scrollView.documentView = textView
        context.coordinator.textView = textView
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else {
            return
        }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
        }
        let isEnabled = context.environment.isEnabled
        if textView.isEditable != isEnabled {
            textView.isEditable = isEnabled
        }
        scrollView.alphaValue = isEnabled ? 1 : Palette.disabledOpacity
        if textView.accessibilityLabel() != accessibilityLabel {
            textView.setAccessibilityLabel(accessibilityLabel)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextArea
        weak var textView: TextAreaTextView?

        init(_ parent: TextArea) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, parent.text != textView.string else {
                return
            }
            parent.text = textView.string
        }
    }
}

/// The text area's text view, which tells the area when it takes focus and
/// loses it.
final class TextAreaTextView: EspalierTextView {
    weak var coordinator: TextArea.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.parent.onFocusChange(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            coordinator?.parent.onFocusChange(false)
        }
        return resigned
    }

    /// Leaving the window takes the focus with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            coordinator?.parent.onFocusChange(false)
        }
    }
}
