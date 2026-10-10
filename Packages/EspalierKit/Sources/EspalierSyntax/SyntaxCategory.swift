// What the grammars' highlight queries call each piece of code (their
// capture names), reduced to the categories a theme colors.

/// What a highlighted range of code is.
public enum SyntaxCategory: UInt8, Sendable, CaseIterable, Hashable, CustomStringConvertible {
    /// Text with no role of its own, or an embedded expression's code.
    case plain
    case keyword
    case string
    /// Escape sequences in strings.
    case escape
    case comment
    case number
    /// Named constants (`MAX_SIZE`, enum entries, Ruby symbols).
    case constant
    /// Literal constants of the language: `true`, `false`, `nil`, `null`.
    case builtinConstant
    /// Types, constructors, namespaces, modules.
    case type
    /// Function and method names, macros.
    case function
    case variable
    /// `self`, `this`, `super`.
    case builtinVariable
    /// Properties, fields, members, and keys.
    case property
    /// Attributes, annotations, decorators.
    case attribute
    /// Markup tags.
    case tag
    /// Labels, lifetimes, anchors.
    case label
    case `operator`
    case punctuation
    /// Markup headings.
    case heading
    /// Emphasized text.
    case emphasis
    /// Strongly emphasized text.
    case strong
    /// Link destinations and URLs.
    case link
    /// Link texts and reference labels.
    case linkText
    /// Code in markup (code spans and blocks).
    case code

    public var description: String {
        switch self {
        case .plain: "plain"
        case .keyword: "keyword"
        case .string: "string"
        case .escape: "escape"
        case .comment: "comment"
        case .number: "number"
        case .constant: "constant"
        case .builtinConstant: "builtinConstant"
        case .type: "type"
        case .function: "function"
        case .variable: "variable"
        case .builtinVariable: "builtinVariable"
        case .property: "property"
        case .attribute: "attribute"
        case .tag: "tag"
        case .label: "label"
        case .operator: "operator"
        case .punctuation: "punctuation"
        case .heading: "heading"
        case .emphasis: "emphasis"
        case .strong: "strong"
        case .link: "link"
        case .linkText: "linkText"
        case .code: "code"
        }
    }
}

/// What a capture in a highlight query does.
enum CaptureRole: Equatable, Sendable {
    /// Colors the captured node.
    case highlight(SyntaxCategory)
    /// Doesn't color anything: a predicate's helper (`@_name`), a
    /// spell-checking hint (`@spell`), or an injection's or local
    /// variable's capture in the wrong query.
    case ignored
}

/// The capture names the 23 grammars' highlight queries use (and the
/// common names newer queries use for the same things), and the category
/// each gives. A name not in the table takes its longest dotted prefix
/// that is (`function.method.builtin` is a `function`); a name with no such
/// prefix colors nothing.
///
/// | Capture name | Category |
/// |---|---|
/// | `keyword`, `keyword.*`, `conditional`, `repeat`, `include`, `exception`, `storageclass`, `preproc`, `type.qualifier` | keyword |
/// | `keyword.conditional.ternary` (Swift's `?` and `:`) | operator |
/// | `string`, `string.*`, `character`, `string.special.regex`, `string.regexp` | string |
/// | `string.escape`, `escape` | escape |
/// | `string.special.key` (JSON keys) | property |
/// | `string.special.symbol` (Ruby symbols) | constant |
/// | `comment`, `comment.*` | comment |
/// | `number`, `number.*`, `float`, `constant.numeric` | number |
/// | `constant`, `constant.macro` | constant |
/// | `constant.builtin`, `boolean` | builtinConstant |
/// | `type`, `type.*`, `constructor`, `namespace`, `module` | type |
/// | `function`, `function.*`, `method`, `method.*` | function |
/// | `variable`, `variable.parameter`, `parameter` | variable |
/// | `variable.builtin`, `parameter.builtin` | builtinVariable |
/// | `property`, `property.*`, `field`, `variable.member` | property |
/// | `attribute`, `tag.attribute` | attribute |
/// | `tag`, `tag.error` | tag |
/// | `tag.delimiter` | punctuation |
/// | `label` | label |
/// | `operator`, `character.special` (Swift's `_`) | operator |
/// | `punctuation`, `punctuation.*`, `delimiter` | punctuation |
/// | `embedded`, `none`, `markup.quote` | plain |
/// | `text.title`, `markup.heading` | heading |
/// | `text.emphasis`, `markup.italic`, `markup.strikethrough` | emphasis |
/// | `text.strong`, `markup.bold` | strong |
/// | `text.uri`, `markup.link.url` | link |
/// | `text.reference`, `markup.link`, `markup.link.label` | linkText |
/// | `text.literal`, `markup.raw` | code |
/// | `markup.list` | punctuation |
/// | `spell`, `nospell`, `conceal`, `_*`, `injection.*`, `local.*` | (ignored) |
enum CaptureNames {
    static let table: [String: SyntaxCategory] = [
        "keyword": .keyword,
        "keyword.conditional.ternary": .operator,
        "conditional": .keyword,
        "repeat": .keyword,
        "include": .keyword,
        "exception": .keyword,
        "storageclass": .keyword,
        "preproc": .keyword,
        "type.qualifier": .keyword,

        "string": .string,
        "character": .string,
        "string.escape": .escape,
        "escape": .escape,
        "string.special.key": .property,
        "string.special.symbol": .constant,

        "comment": .comment,

        "number": .number,
        "float": .number,
        "constant.numeric": .number,

        "constant": .constant,
        "constant.builtin": .builtinConstant,
        "boolean": .builtinConstant,

        "type": .type,
        "constructor": .type,
        "namespace": .type,
        "module": .type,

        "function": .function,
        "method": .function,

        "variable": .variable,
        "parameter": .variable,
        "variable.builtin": .builtinVariable,
        "parameter.builtin": .builtinVariable,
        "variable.member": .property,

        "property": .property,
        "field": .property,

        "attribute": .attribute,
        "tag": .tag,
        "tag.attribute": .attribute,
        "tag.delimiter": .punctuation,
        "label": .label,

        "operator": .operator,
        "character.special": .operator,
        "punctuation": .punctuation,
        "delimiter": .punctuation,

        "embedded": .plain,
        "none": .plain,

        "text.title": .heading,
        "text.emphasis": .emphasis,
        "text.strong": .strong,
        "text.uri": .link,
        "text.reference": .linkText,
        "text.literal": .code,
        "markup.heading": .heading,
        "markup.italic": .emphasis,
        "markup.strikethrough": .emphasis,
        "markup.bold": .strong,
        "markup.link.url": .link,
        "markup.link": .linkText,
        "markup.link.label": .linkText,
        "markup.raw": .code,
        "markup.quote": .plain,
        "markup.list": .punctuation,
    ]

    /// Captures that never color: spell-checking hints and concealment.
    static let ignoredNames: Set<String> = ["spell", "nospell", "conceal"]

    /// The role of a capture named `name` in a highlight query.
    static func role(_ name: String) -> CaptureRole {
        if name.hasPrefix("_") || ignoredNames.contains(name) || name.hasPrefix("injection.") || name.hasPrefix("local.") {
            return .ignored
        }
        var candidate = Substring(name)
        while true {
            if let category = table[String(candidate)] {
                return .highlight(category)
            }
            guard let dot = candidate.lastIndex(of: ".") else {
                return .ignored
            }
            candidate = candidate[..<dot]
        }
    }
}
