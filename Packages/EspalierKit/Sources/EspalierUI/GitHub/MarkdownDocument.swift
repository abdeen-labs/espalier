// GitHub-flavored Markdown (pull request descriptions, reviews, comments) as
// blocks a SwiftUI view lays out: selectable, links underlined per the
// setting, images loaded through the authenticated loader.
//
// Foundation's Markdown parser keeps inline styles, links, and images as
// attributes and marks each run with its blocks: paragraphs, headings, lists
// and task lists, quotes, code blocks, tables, and rules. GitHub's HTML is
// handled as pull requests use it: `<img>` tags become images, `<br>` a line
// break, comments are dropped, and other tags leave their text.

import EspalierSupport
import Foundation
import SwiftUI
import os

nonisolated private let signposter = OSSignposter(subsystem: Log.subsystem, category: "ui")

/// An image in Markdown or GitHub's HTML.
nonisolated struct MarkdownImage: Sendable, Equatable {
    var url: URL
    /// The alternative text, shown while the image can't be.
    var alt: String
    /// The width the HTML asked for, in points.
    var width: CGFloat?
}

/// One block of a Markdown document.
nonisolated struct MarkdownBlock: Sendable, Equatable, Identifiable {
    /// What starts a list item.
    enum ListMarker: Sendable, Equatable {
        case bullet
        case number(Int)
        /// A task list item, done or not.
        case task(done: Bool)
    }

    enum Content: Sendable, Equatable {
        /// A paragraph, or a heading of `level` (1 to 6).
        case text(AttributedString, headingLevel: Int?)
        /// A list item's first paragraph.
        case listItem(ListMarker, AttributedString)
        case code(String, language: String?)
        case table(header: [AttributedString], rows: [[AttributedString]])
        case image(MarkdownImage)
        /// A thematic break.
        case rule
    }

    var id: Int
    var content: Content
    /// How many list levels deep the block is (its indentation).
    var indent: Int = 0
    /// How many quotes deep the block is.
    var quoteDepth: Int = 0
}

/// A Markdown document as blocks.
nonisolated struct MarkdownDocument: Sendable, Equatable {
    var blocks: [MarkdownBlock] = []

    var isEmpty: Bool {
        blocks.isEmpty
    }

    /// Parses `markdown` (GitHub's). Links are underlined when
    /// `underlineLinks` is on (Settings ▸ Appearance).
    static func parse(_ markdown: String, underlineLinks: Bool = true) -> MarkdownDocument {
        signposter.withIntervalSignpost("MarkdownParse", id: signposter.makeSignpostID()) {
            let options = AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
                let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                return MarkdownDocument(blocks: text.isEmpty ? [] : [MarkdownBlock(id: 0, content: .text(AttributedString(text), headingLevel: nil))])
            }
            var builder = MarkdownBuilder(underlineLinks: underlineLinks)
            for run in attributed.runs {
                builder.add(run, text: attributed[run.range])
            }
            return MarkdownDocument(blocks: builder.finish())
        }
    }

    /// Parses `markdown` off the main actor.
    @concurrent
    static func parseInBackground(_ markdown: String, underlineLinks: Bool) async -> MarkdownDocument {
        parse(markdown, underlineLinks: underlineLinks)
    }
}

/// Builds blocks from the parser's runs.
nonisolated private struct MarkdownBuilder {
    let underlineLinks: Bool
    private(set) var blocks: [MarkdownBlock] = []

    /// The block the runs being added belong to: its innermost component's
    /// identity, and its components (innermost first).
    private var currentIdentity: Int?
    private var components: [PresentationIntent.IntentType] = []
    private var text = AttributedString()
    /// Whether the text being built continues a block an image split.
    private var isContinuation = false
    /// The list items whose first paragraph has been seen.
    private var listItemsStarted: Set<Int> = []
    /// The table being built.
    private var table: TableBuilder?

    init(underlineLinks: Bool) {
        self.underlineLinks = underlineLinks
    }

    mutating func add(_ run: AttributedString.Runs.Run, text slice: AttributedSubstring) {
        let inline = run.inlinePresentationIntent ?? []
        let runComponents = run.presentationIntent?.components ?? []
        if let table, inline.contains(.blockHTML) || !runComponents.contains(where: { $0.identity == table.identity }) {
            flush()
            emitTable()
        }
        if inline.contains(.blockHTML) {
            flush()
            addHTMLBlock(String(slice.characters), components: runComponents)
            return
        }

        let identity = runComponents.first?.identity
        if identity != currentIdentity || currentIdentity == nil {
            flush()
            currentIdentity = identity
            components = runComponents
            isContinuation = false
        }

        if case .tableCell? = runComponents.first?.kind {
            addTableCell(slice, components: runComponents)
            return
        }
        if case .thematicBreak? = runComponents.first?.kind {
            return
        }

        if let url = run.imageURL {
            flushText()
            emit(.image(MarkdownImage(url: url, alt: String(slice.characters), width: nil)))
            isContinuation = true
            return
        }
        if inline.contains(.inlineHTML) {
            addInlineHTML(String(slice.characters))
            return
        }
        if inline.contains(.lineBreak) {
            text.append(AttributedString("\n"))
            return
        }

        var piece = AttributedString(slice)
        piece.presentationIntent = nil
        if piece.link != nil, underlineLinks {
            piece.underlineStyle = .single
        }
        text.append(piece)
    }

    mutating func finish() -> [MarkdownBlock] {
        flush()
        emitTable()
        return blocks
    }

    // MARK: Blocks

    /// Ends the block being built.
    private mutating func flush() {
        flushText()
        if let kind = components.first?.kind, case .thematicBreak = kind, currentIdentity != nil {
            emit(.rule)
        }
        currentIdentity = nil
        components = []
    }

    /// Emits the table being built, if any.
    private mutating func emitTable() {
        guard let table else {
            return
        }
        self.table = nil
        emit(.table(header: table.header, rows: table.rows), indent: table.indent, quoteDepth: table.quoteDepth)
    }

    /// Emits the text built so far as its block's kind.
    private mutating func flushText() {
        guard let kind = components.first?.kind else {
            emitPlainText()
            return
        }
        defer {
            text = AttributedString()
        }
        switch kind {
        case .codeBlock(let languageHint):
            var code = String(text.characters)
            if code.hasSuffix("\n") {
                code.removeLast()
            }
            guard !code.isEmpty || !isContinuation else {
                return
            }
            emit(.code(code, language: languageHint))

        case .header(let level):
            guard !trimmed(text).characters.isEmpty else {
                return
            }
            emit(.text(trimmed(text), headingLevel: level))

        case .paragraph:
            guard !trimmed(text).characters.isEmpty else {
                return
            }
            if !isContinuation, let marker = listMarker() {
                var content = trimmed(text)
                var listMarker = marker
                if let done = Self.taskState(content) {
                    listMarker = .task(done: done)
                    content.removeSubrange(content.startIndex..<content.characters.index(content.startIndex, offsetBy: 4))
                }
                emit(.listItem(listMarker, content), indent: max(listDepth - 1, 0))
            } else {
                emit(.text(trimmed(text), headingLevel: nil))
            }

        default:
            emitPlainText()
        }
    }

    private mutating func emitPlainText() {
        let content = trimmed(text)
        text = AttributedString()
        guard !content.characters.isEmpty else {
            return
        }
        emit(.text(content, headingLevel: nil))
    }

    private mutating func emit(_ content: MarkdownBlock.Content, indent: Int? = nil, quoteDepth: Int? = nil) {
        blocks.append(MarkdownBlock(
            id: blocks.count,
            content: content,
            indent: indent ?? listDepth,
            quoteDepth: quoteDepth ?? components.reduce(0) { count, component in
                if case .blockQuote = component.kind { count + 1 } else { count }
            }
        ))
    }

    /// How many lists the block is in.
    private var listDepth: Int {
        components.reduce(0) { count, component in
            if case .listItem = component.kind { count + 1 } else { count }
        }
    }

    /// The marker of the list item whose first paragraph this is, if it is
    /// one.
    private mutating func listMarker() -> MarkdownBlock.ListMarker? {
        guard let index = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
              case .listItem(let ordinal) = components[index].kind
        else {
            return nil
        }
        guard listItemsStarted.insert(components[index].identity).inserted else {
            return nil
        }
        if components.indices.contains(index + 1), case .orderedList = components[index + 1].kind {
            return .number(ordinal)
        }
        return .bullet
    }

    /// "[ ] " or "[x] " at the start of a list item: a task, done or not.
    private static func taskState(_ text: AttributedString) -> Bool? {
        let characters = String(text.characters.prefix(4))
        switch characters {
        case "[ ] ": return false
        case "[x] ", "[X] ": return true
        default: return nil
        }
    }

    private func trimmed(_ text: AttributedString) -> AttributedString {
        var result = text
        while let first = result.characters.first, first.isWhitespace {
            result.removeSubrange(result.startIndex..<result.characters.index(after: result.startIndex))
        }
        while let last = result.characters.last, last.isWhitespace {
            result.removeSubrange(result.characters.index(before: result.endIndex)..<result.endIndex)
        }
        return result
    }

    // MARK: Tables

    private struct TableBuilder {
        let identity: Int
        let indent: Int
        let quoteDepth: Int
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        var rowIdentity: Int?
    }

    private mutating func addTableCell(_ slice: AttributedSubstring, components runComponents: [PresentationIntent.IntentType]) {
        guard let tableComponent = runComponents.first(where: { if case .table = $0.kind { true } else { false } }) else {
            return
        }
        if table?.identity != tableComponent.identity {
            if let table {
                emit(.table(header: table.header, rows: table.rows), indent: table.indent, quoteDepth: table.quoteDepth)
            }
            table = TableBuilder(
                identity: tableComponent.identity,
                indent: listDepth,
                quoteDepth: runComponents.reduce(0) { count, component in
                    if case .blockQuote = component.kind { count + 1 } else { count }
                }
            )
        }
        guard var table, runComponents.count > 1, case .tableCell(let column) = runComponents[0].kind else {
            return
        }
        var piece = AttributedString(slice)
        piece.presentationIntent = nil
        if piece.link != nil, underlineLinks {
            piece.underlineStyle = .single
        }
        let row = runComponents[1]
        if case .tableHeaderRow = row.kind {
            Self.append(piece, column: column, to: &table.header)
        } else {
            if table.rowIdentity != row.identity {
                table.rows.append([])
                table.rowIdentity = row.identity
            }
            Self.append(piece, column: column, to: &table.rows[table.rows.count - 1])
        }
        self.table = table
    }

    private static func append(_ piece: AttributedString, column: Int, to cells: inout [AttributedString]) {
        while cells.count <= column {
            cells.append(AttributedString())
        }
        cells[column].append(piece)
    }

    // MARK: HTML

    /// A `<br>`, an `<img>`, or another tag within a paragraph.
    private mutating func addInlineHTML(_ html: String) {
        if html.wholeMatch(of: /(?i)<br\s*\/?>/) != nil {
            text.append(AttributedString("\n"))
            return
        }
        if let image = MarkdownHTML.images(in: html).first {
            flushText()
            emit(.image(image))
            isContinuation = true
        }
        // Other tags (and comments) leave nothing; text between them comes
        // in its own runs.
    }

    /// A block of HTML: its images, and the text between them.
    private mutating func addHTMLBlock(_ html: String, components blockComponents: [PresentationIntent.IntentType]) {
        components = blockComponents
        defer {
            components = []
        }
        for part in MarkdownHTML.parts(of: html) {
            switch part {
            case .image(let image):
                emit(.image(image))
            case .text(let string):
                emit(.text(AttributedString(string), headingLevel: nil))
            }
        }
    }
}

/// The HTML GitHub's Markdown carries, as pull requests use it.
nonisolated enum MarkdownHTML {
    enum Part: Equatable {
        case image(MarkdownImage)
        case text(String)
    }

    /// The images and text of `html`, in order: comments dropped, tags
    /// removed, entities decoded, blank text left out.
    static func parts(of html: String) -> [Part] {
        let withoutComments = html.replacing(/<!--[\s\S]*?-->/, with: "")
        var parts: [Part] = []
        var rest = Substring(withoutComments)
        while let match = rest.firstMatch(of: /(?i)<img\b[^>]*>/) {
            appendText(rest[rest.startIndex..<match.range.lowerBound], to: &parts)
            if let image = image(fromTag: String(match.output)) {
                parts.append(.image(image))
            }
            rest = rest[match.range.upperBound...]
        }
        appendText(rest, to: &parts)
        return parts
    }

    /// The images of `html`'s `<img>` tags.
    static func images(in html: String) -> [MarkdownImage] {
        parts(of: html).compactMap { part in
            if case .image(let image) = part { image } else { nil }
        }
    }

    private static func appendText(_ html: Substring, to parts: inout [Part]) {
        let text = decodeEntities(String(html).replacing(/(?i)<br\s*\/?>/, with: "\n").replacing(/<[^>]*>/, with: ""))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            parts.append(.text(joined))
        }
    }

    /// The image an `<img>` tag shows: its `src`, `alt`, and `width`.
    static func image(fromTag tag: String) -> MarkdownImage? {
        guard let source = attribute("src", in: tag), let url = URL(string: decodeEntities(source)) else {
            return nil
        }
        let width = attribute("width", in: tag).flatMap { Double($0.replacing(/px$/, with: "")) }.map { CGFloat($0) }
        return MarkdownImage(url: url, alt: decodeEntities(attribute("alt", in: tag) ?? ""), width: width)
    }

    /// An attribute's value: double-quoted, single-quoted, or bare.
    private static func attribute(_ name: String, in tag: String) -> String? {
        // Attributes follow white space (so `data-src` isn't `src`).
        guard let regex = try? Regex("(?i)\\s\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"),
              let match = tag.firstMatch(of: regex)
        else {
            return nil
        }
        for index in 1..<match.output.count {
            if let value = match.output[index].substring {
                return String(value)
            }
        }
        return nil
    }

    /// Decodes the entities pull requests' HTML uses.
    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else {
            return string
        }
        var result = string
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", "\u{00A0}"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}
