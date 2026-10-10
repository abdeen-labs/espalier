@testable import EspalierCore
import EspalierSupport
import Testing
import TestSupport

/// Every expected value here was recorded by running `string-argv` in
/// JavaScript (bun).
@Suite("string-argv")
struct StringArgvTests {
    /// Compares code units, as JavaScript's `===` does, rather than Swift's
    /// canonical equivalence (which equates `"\u{E9}"` and `"e\u{301}"`).
    private func expectArguments(_ input: String, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = stringArgv(input)
        let same = actual.count == expected.count
            && zip(actual, expected).allSatisfy { JSCompat.strictEquals($0, $1) }
        #expect(same, "\(input.debugDescription) gave \(actual.debugDescription), not \(expected.debugDescription)", sourceLocation: sourceLocation)
    }

    @Test("strips the quotes of an argument that starts with one")
    func quotedArguments() {
        expectArguments("\"a b\" 'c d'", ["a b", "c d"])
        expectArguments("\"a'b\" 'a\"b'", ["a'b", "a\"b"])
        expectArguments("\"a\nb\"", ["a\nb"])
        expectArguments("\"\" ''", ["", ""])
        expectArguments("a \"\" b", ["a", "", "b"])
        // The closing quote ends the argument.
        expectArguments("\"a b\"c", ["a b", "c"])
        expectArguments("'a b'c'd e'", ["a b", "c'd e'"])
    }

    @Test("drops a quote that is never closed")
    func unclosedQuotes() {
        expectArguments("a\"b c", ["a", "b", "c"])
        expectArguments("\"a b", ["a", "b"])
        expectArguments("a\"b\"c\"d", ["a\"b\"c", "d"])
        expectArguments("\"\"\"", [""])
    }

    @Test("keeps the octal escapes of the package's regular expression")
    func octalEscapes() {
        // A quoted section inside an argument can't contain U+0003...
        expectArguments("x\"a\u{0003}b c\"", ["x", "a\u{0003}b c"])
        expectArguments("x\"a\u{0005}b c\"", ["x\"a\u{0005}b c\""])
        // ...and a quoted argument can't contain U+0005.
        expectArguments("\"a\u{0005}b c\"", ["a\u{0005}b", "c"])
        expectArguments("\"a\u{0003}b c\"", ["a\u{0003}b c"])
    }

    @Test("matches JavaScript", arguments: [
        NamedCase("matches JavaScript on hand-picked inputs", curatedCases),
        NamedCase("matches JavaScript on generated inputs", generatedCases),
    ])
    func matchesJavaScript(_ testCase: NamedCase<[(String, [String])]>) {
        for (input, expected) in testCase.value {
            expectArguments(input, expected)
        }
    }

    static let curatedCases: [(String, [String])] = [
        ("", []),
        (" ", []),
        ("a", ["a"]),
        ("a b", ["a", "b"]),
        ("  a   b  ", ["a", "b"]),
        ("a\u{0009}b\u{000A}c\u{000D}d", ["a", "b", "c", "d"]),
        ("\"a b\"", ["a b"]),
        ("'a b'", ["a b"]),
        ("\"\"", [""]),
        ("''", [""]),
        ("\"\" ''", ["", ""]),
        ("a \"\" b", ["a", "", "b"]),
        ("\"a\"b", ["a", "b"]),
        ("a\"b\"", ["a\"b\""]),
        ("a\"b c\"d", ["a\"b c\"d"]),
        ("--name=\"a b\" x", ["--name=\"a b\"", "x"]),
        ("--name='a b' x", ["--name='a b'", "x"]),
        ("a\"b\"c\"d e\"f", ["a\"b\"c\"d e\"f"]),
        ("a\"b\"c\"d", ["a\"b\"c", "d"]),
        ("a\"b", ["a", "b"]),
        ("a \"b", ["a", "b"]),
        ("\"a b", ["a", "b"]),
        ("a'b\"c'd", ["a'b\"c'd"]),
        ("\"a'b\"", ["a'b"]),
        ("'a\"b'", ["a\"b"]),
        ("a\\ b", ["a\\", "b"]),
        ("\"a\\\"b\"", ["a\\", "b"]),
        ("a\\\"b c\\\"d", ["a\\\"b c\\\"d"]),
        ("%TARGET_PATH%", ["%TARGET_PATH%"]),
        ("\"%TARGET_PATH%\"", ["%TARGET_PATH%"]),
        ("'%TARGET_PATH%'", ["%TARGET_PATH%"]),
        ("--goto \"%TARGET_PATH%\"", ["--goto", "%TARGET_PATH%"]),
        ("-n %TARGET_PATH% --wait", ["-n", "%TARGET_PATH%", "--wait"]),
        ("--folder-uri=%TARGET_PATH%", ["--folder-uri=%TARGET_PATH%"]),
        ("--path='%TARGET_PATH%'", ["--path='%TARGET_PATH%'"]),
        ("a\u{00A0}b", ["a", "b"]),
        ("a\u{FEFF}b", ["a", "b"]),
        ("a\u{2028}b", ["a", "b"]),
        ("a\u{000B}b", ["a", "b"]),
        ("a\u{0085}b", ["a\u{0085}b"]),
        ("a\u{180E}b", ["a\u{180E}b"]),
        ("\"a\u{0003}b\"", ["a\u{0003}b"]),
        ("\"a\u{0005}b\"", ["a\u{0005}b"]),
        ("x\"a\u{0003}b\"", ["x", "a\u{0003}b"]),
        ("x\"a\u{0005}b\"", ["x\"a\u{0005}b\""]),
        ("\"a\u{000A}b\"", ["a\u{000A}b"]),
        ("\u{00E9} e\u{0301} \u{1F600}", ["\u{00E9}", "e\u{0301}", "\u{1F600}"]),
        ("\"\u{1F600} \u{1F600}\"", ["\u{1F600} \u{1F600}"]),
        ("''\"", [""]),
        ("\"'\"'\"", ["'"]),
        ("\"a\"\"b\"", ["a", "b"]),
        ("'a''b'", ["a", "b"]),
        ("a\"\"\"b", ["a\"\"", "b"]),
        ("a\"\"b", ["a\"\"b"]),
        ("a''b", ["a''b"]),
        ("\"\"\"", [""]),
        ("a=\"b\"c='d e'f g", ["a=\"b\"c='d e'f", "g"]),
    ]

    /// A sample of 20,000 random strings over quotes, backslashes, ASCII and
    /// Unicode whitespace, U+0003, U+0005, combining marks, and emoji, all of
    /// which the Swift version matched.
    static let generatedCases: [(String, [String])] = [
        ("-'a\u{1F600}$-b%TARGET_PATH%\u{000D}c\u{0003}-", ["-", "a\u{1F600}$-b%TARGET_PATH%", "c\u{0003}-"]),
        ("   \"", []),
        ("ae\u{0301}\u{1F600}'\u{00E9}", ["ae\u{0301}\u{1F600}", "\u{00E9}"]),
        ("'\u{0005}\u{000A}\\   $c'b\u{0005}cc", ["\u{0005}", "\\", "$c", "b\u{0005}cc"]),
        ("a  \u{0005}\u{FEFF}\"\u{1F600}\u{0085}=", ["a", "\u{0005}", "\u{1F600}\u{0085}="]),
        ("c\"", ["c"]),
        ("e\u{0301}\u{000D}\"\u{00A0}", ["e\u{0301}"]),
        ("\u{000A}%TARGET_PATH%a\u{FEFF}\u{0009}", ["%TARGET_PATH%a"]),
        (" \u{1F600}\u{1F600}'", ["\u{1F600}\u{1F600}"]),
        ("\u{000B} \u{00A0}c\"\"\u{1F600}", ["c\"\"\u{1F600}"]),
        ("-\u{000A}e\u{0301}c\u{000A}\"", ["-", "e\u{0301}c"]),
        ("\"\u{0009}\u{0009}-", ["-"]),
        ("a\"b\u{0009}\u{000A}\u{1F600}-c ", ["a", "b", "\u{1F600}-c"]),
        ("\u{000A}\"'cc\"\u{000A}'%TARGET_PATH%\u{0085}\u{0003}", ["'cc", "%TARGET_PATH%\u{0085}\u{0003}"]),
        ("\u{00A0}\"\"\"\u{2028}\\\"\u{000D}\"\u{000A}\u{0085}=", ["", "\u{2028}\\", "\u{0085}="]),
        ("  \u{0005}$a\u{0009}\u{FEFF}\\", ["\u{0005}$a", "\\"]),
        ("\u{00A0}\u{000A}\u{00A0}a\\\u{000D}\u{2028}\u{000D}%TARGET_PATH%='", ["a\\", "%TARGET_PATH%="]),
        ("\u{00A0}\\\u{0085}c- \u{00A0}\"\u{00E9}%TARGET_PATH%", ["\\\u{0085}c-", "\u{00E9}%TARGET_PATH%"]),
        ("\u{00E9}\u{00E9}'\u{000B}\u{000B}'-", ["\u{00E9}\u{00E9}'\u{000B}\u{000B}'-"]),
        ("\u{00A0}-'\u{000D}\u{000D}\u{000D}c\"-", ["-", "c", "-"]),
        ("a\\ \"-\"\u{00E9}\"", ["a\\", "-", "\u{00E9}"]),
        ("%TARGET_PATH%\"\u{0003}\u{000D}\u{0005}'\u{0085}\u{0085}\u{00A0}=\\\u{0009}=", ["%TARGET_PATH%", "\u{0003}", "\u{0005}", "\u{0085}\u{0085}", "=\\", "="]),
        ("\"\u{FEFF}-\u{0085}\u{000A}\u{000A}'\u{1F600}bc", ["-\u{0085}", "\u{1F600}bc"]),
        ("\u{0003}\u{000D}\u{00E9}-a=\u{0003}\u{0005}$'\u{00A0}'\"", ["\u{0003}", "\u{00E9}-a=\u{0003}\u{0005}$'\u{00A0}'"]),
        ("\u{0003}\u{0009}%TARGET_PATH%\u{FEFF}'b\\'c\u{00A0}  \u{1F600}'", ["\u{0003}", "%TARGET_PATH%", "b\\", "c", "\u{1F600}"]),
        ("\u{1F600}$'", ["\u{1F600}$"]),
        ("\u{0085}\u{0009}'a'\u{00A0}\u{000B}\u{0005}\\", ["\u{0085}", "a", "\u{0005}\\"]),
        ("\u{1F600}\u{0085}'c\u{000B}\u{FEFF}\u{000A} 'a", ["\u{1F600}\u{0085}'c\u{000B}\u{FEFF}\u{000A} 'a"]),
        ("=\u{0009}'\\\u{0085}", ["=", "\\\u{0085}"]),
        ("\u{1F600}b' \u{0009}b\"", ["\u{1F600}b", "b"]),
        ("\u{0009}c='\u{00E9}=\u{00E9}c\u{00A0}%TARGET_PATH% \\", ["c=", "\u{00E9}=\u{00E9}c", "%TARGET_PATH%", "\\"]),
        ("\"c\u{00E9}=aa", ["c\u{00E9}=aa"]),
        ("$\u{000D}\u{000B}\u{FEFF}\u{00A0}\u{000B}'  e\u{0301}  \u{FEFF}\u{000D}\u{1F600}", ["$", "e\u{0301}", "\u{1F600}"]),
        ("-\"", ["-"]),
        ("\u{0085}  \u{000D}$-\\b-c\u{0003}\u{2028}", ["\u{0085}", "$-\\b-c\u{0003}"]),
        ("a$\"\u{00A0}\"$\\\u{000D} \u{1F600}\"cb", ["a$\"\u{00A0}\"$\\", "\u{1F600}", "cb"]),
        ("\u{1F600}\u{0009}  '\u{1F600}\u{1F600} %TARGET_PATH%\"'\u{0003}  ", ["\u{1F600}", "\u{1F600}\u{1F600} %TARGET_PATH%\"", "\u{0003}"]),
        ("$$\u{000D}a=%TARGET_PATH%", ["$$", "a=%TARGET_PATH%"]),
        ("  $\"\u{FEFF}\u{00E9}\u{0003}\u{2028}\u{00E9}", ["$", "\u{00E9}\u{0003}", "\u{00E9}"]),
        (" -\u{0005}\u{0005}\\", ["-\u{0005}\u{0005}\\"]),
        ("%TARGET_PATH%' %TARGET_PATH%--=\u{1F600}", ["%TARGET_PATH%", "%TARGET_PATH%--=\u{1F600}"]),
        ("\u{00A0}-\u{FEFF}b'\"e\u{0301}e\u{0301}-\u{0003}\u{0005}", ["-", "b", "e\u{0301}e\u{0301}-\u{0003}\u{0005}"]),
        ("$\u{0005}\u{2028}\"'\u{0085}\u{000B}\u{000B}\u{00E9}=", ["$\u{0005}", "\u{0085}", "\u{00E9}="]),
        ("\u{00E9}e\u{0301}\u{0003}$\"e\u{0301}\u{000A}\u{00E9}a ", ["\u{00E9}e\u{0301}\u{0003}$", "e\u{0301}", "\u{00E9}a"]),
        ("\u{000D}\u{00A0} '\u{FEFF}", []),
        ("", []),
        ("\u{00A0}=b\"", ["=b"]),
        ("c\\'\u{2028}\u{0009}    ' =\u{00A0}", ["c\\'\u{2028}\u{0009}    '", "="]),
        ("-\"\u{FEFF} \u{1F600}\u{1F600}\u{FEFF}\u{0005}\u{0085}-'\u{1F600}", ["-", "\u{1F600}\u{1F600}", "\u{0005}\u{0085}-", "\u{1F600}"]),
        ("-'\u{0003}%TARGET_PATH%\u{00A0}\u{000D}\u{2028}c\u{0009}\u{1F600}\u{0085}\u{0085}'", ["-", "\u{0003}%TARGET_PATH%\u{00A0}\u{000D}\u{2028}c\u{0009}\u{1F600}\u{0085}\u{0085}"]),
        ("\u{000A}-a\u{000A}\"\u{000D}\u{00A0}\u{FEFF}'$\u{0005}=", ["-a", "$\u{0005}="]),
        ("\u{0005}$\u{000B}b=c'-\\c\u{0009}e\u{0301}b", ["\u{0005}$", "b=c", "-\\c", "e\u{0301}b"]),
        ("'\u{000B}c  \"", ["c"]),
        ("\u{0003}\"a\u{00E9}\"a   c\u{1F600}", ["\u{0003}\"a\u{00E9}\"a", "c\u{1F600}"]),
        ("'\u{00A0}", []),
        ("", []),
        ("\"b%TARGET_PATH%e\u{0301} \u{0003}\u{00E9}", ["b%TARGET_PATH%e\u{0301}", "\u{0003}\u{00E9}"]),
        ("", []),
        ("%TARGET_PATH%c\u{0085}%TARGET_PATH%\u{0009}\u{00E9}a\"\u{00A0}\u{000B}'\\  ", ["%TARGET_PATH%c\u{0085}%TARGET_PATH%", "\u{00E9}a", "\\"]),
        ("b=\u{0003}\u{0009}='\"a", ["b=\u{0003}", "=", "a"]),
        ("\u{FEFF}\u{1F600}\\\"=\u{000A}a\u{0005} '", ["\u{1F600}\\", "=", "a\u{0005}"]),
        ("'\"- a\u{00E9}  -\u{1F600}\\\"\u{0009}", ["- a\u{00E9}  -\u{1F600}\\"]),
        ("\u{1F600}'\u{1F600}\"\u{0005}c", ["\u{1F600}", "\u{1F600}", "\u{0005}c"]),
        ("$\u{0003}%TARGET_PATH%a$\u{000A}\u{000B}$-'=\u{0005}\u{0003}", ["$\u{0003}%TARGET_PATH%a$", "$-", "=\u{0005}\u{0003}"]),
        ("\u{0085}'\u{0005}e\u{0301}  ", ["\u{0085}", "\u{0005}e\u{0301}"]),
        ("$\u{FEFF}=e\u{0301}b\"c\"\u{FEFF}\u{0005}\u{1F600}e\u{0301}", ["$", "=e\u{0301}b\"c\"", "\u{0005}\u{1F600}e\u{0301}"]),
        ("a\\\u{000B}\\\"\"=\u{000B}   %TARGET_PATH%ae\u{0301}", ["a\\", "\\\"\"=", "%TARGET_PATH%ae\u{0301}"]),
        ("-a'\u{000A}'\u{2028}'$-\u{0005}\u{000D}\"-", ["-a'\u{000A}'", "$-\u{0005}", "-"]),
        ("\u{0009}\u{1F600}\u{0085}\u{1F600}\u{00E9}=c\u{0009}\u{0003}\u{0009}\u{0085}\\", ["\u{1F600}\u{0085}\u{1F600}\u{00E9}=c", "\u{0003}", "\u{0085}\\"]),
        ("\\  \\\u{0003}%TARGET_PATH%cb'$", ["\\", "\\\u{0003}%TARGET_PATH%cb", "$"]),
        ("", []),
        ("\"\u{1F600}\u{00E9}$\u{FEFF}e\u{0301}'", ["\u{1F600}\u{00E9}$", "e\u{0301}"]),
        ("\u{0003}a'\u{0005}c\u{1F600}\u{0005}", ["\u{0003}a", "\u{0005}c\u{1F600}\u{0005}"]),
        ("\u{0009}'\u{2028}--\u{00E9}\u{0085}\u{0009}\u{0009}", ["--\u{00E9}\u{0085}"]),
        ("  \"\u{00A0}a $\u{2028}=", ["a", "$", "="]),
        ("\u{0009}\u{FEFF}\u{0005}'", ["\u{0005}"]),
        ("$\u{000A}\\'\u{0009}\u{000D}=%TARGET_PATH%  \\c\u{000D}", ["$", "\\", "=%TARGET_PATH%", "\\c"]),
        ("e\u{0301}\u{0003}ac\\'\u{FEFF}\u{000A}'e\u{0301}", ["e\u{0301}\u{0003}ac\\'\u{FEFF}\u{000A}'e\u{0301}"]),
        (" b", ["b"]),
        ("cb\u{0003}a\u{000A}'$", ["cb\u{0003}a", "$"]),
        ("\u{1F600}b\u{000D}\u{00E9}'\u{1F600} ", ["\u{1F600}b", "\u{00E9}", "\u{1F600}"]),
        ("cb\u{00A0}\u{0005}'b%TARGET_PATH%", ["cb", "\u{0005}", "b%TARGET_PATH%"]),
        ("\u{0085}\"   =\\b\u{00A0}\u{00A0}=\u{0085}\u{00E9}", ["\u{0085}", "=\\b", "=\u{0085}\u{00E9}"]),
        ("'    \"\u{0085}\u{0085}\"\u{000D}\u{FEFF}", ["\u{0085}\u{0085}"]),
        (" \u{00E9}\u{0005}\u{1F600}\u{0009}$\u{0009}\u{00A0}\"\"\u{0009}\u{2028}", ["\u{00E9}\u{0005}\u{1F600}", "$", ""]),
        ("\u{00A0}e\u{0301}\u{2028}\"\u{00E9}", ["e\u{0301}", "\u{00E9}"]),
        ("\"'\u{00A0}'\u{00E9}\u{0003}\u{00A0}e\u{0301}$$e\u{0301}", ["\u{00A0}", "\u{00E9}\u{0003}", "e\u{0301}$$e\u{0301}"]),
        ("'\u{0003}\u{0003}\"\u{0009}\u{000D}b\u{000B}\u{2028}\u{000A}\u{1F600}", ["\u{0003}\u{0003}", "b", "\u{1F600}"]),
        ("=\u{00A0}\u{0009}%TARGET_PATH%\u{1F600}\u{2028}\"abb-", ["=", "%TARGET_PATH%\u{1F600}", "abb-"]),
        ("\u{00E9}\u{FEFF}%TARGET_PATH%b=\u{000A}\"\u{000A}\u{000B}", ["\u{00E9}", "%TARGET_PATH%b="]),
        ("$\u{2028}\u{2028}\\\"\u{0003}b\\\"\u{2028}c", ["$", "\\", "\u{0003}b\\", "c"]),
        ("\u{0085}\u{0085}\u{00E9}e\u{0301}'b''\u{0005}\u{000D}\u{0085}", ["\u{0085}\u{0085}\u{00E9}e\u{0301}'b'", "\u{0005}", "\u{0085}"]),
        ("\"\u{0005}  \\'=", ["\u{0005}", "\\", "="]),
        ("$\"\u{2028}\u{1F600}\u{000D}-'$ ", ["$", "\u{1F600}", "-", "$"]),
        ("\u{00E9}\"  $\u{000D}' \"\u{1F600}\\\u{000D}'  ", ["\u{00E9}\"  $\u{000D}' \"\u{1F600}\\"]),
        ("'", []),
        ("\"=\u{000A}\u{0085}%TARGET_PATH%\u{000D}b\"", ["=\u{000A}\u{0085}%TARGET_PATH%\u{000D}b"]),
        ("\u{00E9}%TARGET_PATH% \u{0009}=\u{FEFF}e\u{0301}\u{0005}\u{2028}''%TARGET_PATH%\u{0003}", ["\u{00E9}%TARGET_PATH%", "=", "e\u{0301}\u{0005}", "", "%TARGET_PATH%\u{0003}"]),
        ("\u{00E9}\u{000B}\u{000A}=", ["\u{00E9}", "="]),
        ("-\"", ["-"]),
        ("\\\u{0085}%TARGET_PATH%a\u{2028}%TARGET_PATH%", ["\\\u{0085}%TARGET_PATH%a", "%TARGET_PATH%"]),
        ("\u{00A0}\u{0005}%TARGET_PATH%%TARGET_PATH%", ["\u{0005}%TARGET_PATH%%TARGET_PATH%"]),
        ("'c\u{1F600}c-\u{1F600}\u{000B}-%TARGET_PATH%\u{1F600}\u{0085}  ", ["c\u{1F600}c-\u{1F600}", "-%TARGET_PATH%\u{1F600}\u{0085}"]),
        ("'\u{1F600}\u{00A0}", ["\u{1F600}"]),
        ("=ac\u{000A}\u{00A0}", ["=ac"]),
        ("e\u{0301}\u{0009}\u{0085}''\\\u{1F600}", ["e\u{0301}", "\u{0085}''\\\u{1F600}"]),
        ("%TARGET_PATH%'c\u{0085}b'\u{000B}\\", ["%TARGET_PATH%'c\u{0085}b'", "\\"]),
        ("'\u{0009}e\u{0301}'$\\  ", ["\u{0009}e\u{0301}", "$\\"]),
        ("ac\u{1F600}  \"\u{1F600}\u{000A}\u{000D}\u{1F600}\u{000A}", ["ac\u{1F600}", "\u{1F600}", "\u{1F600}"]),
        ("\u{0009}\"%TARGET_PATH%-$b\\$\"=\u{0005}\"'", ["%TARGET_PATH%-$b\\$", "=\u{0005}"]),
        ("\u{00A0}'\"$\"a \u{00A0}\u{000B}", ["$", "a"]),
        ("cb\u{0009}'", ["cb"]),
        ("\u{000B}a\u{0003}'\u{1F600}\u{000B} $\\", ["a\u{0003}", "\u{1F600}", "$\\"]),
        ("%TARGET_PATH%e\u{0301}b\u{000D}\\'", ["%TARGET_PATH%e\u{0301}b", "\\"]),
        ("\u{FEFF}\u{000B}\u{0005}\u{1F600}\u{000B}=\"\u{FEFF}=\u{0085}", ["\u{0005}\u{1F600}", "=", "=\u{0085}"]),
        (" %TARGET_PATH%\u{0005}\u{FEFF}\u{00E9}'%TARGET_PATH%\"'\u{2028}%TARGET_PATH%", ["%TARGET_PATH%\u{0005}", "\u{00E9}'%TARGET_PATH%\"'", "%TARGET_PATH%"]),
        ("\"\u{00A0}\u{00E9}\u{0085}=%TARGET_PATH%\u{0003}ce\u{0301}\u{00A0}", ["\u{00E9}\u{0085}=%TARGET_PATH%\u{0003}ce\u{0301}"]),
        ("-\u{000A}\u{FEFF}\u{0003}c\u{00E9}%TARGET_PATH%a\u{00E9}'\u{1F600}\u{0085}", ["-", "\u{0003}c\u{00E9}%TARGET_PATH%a\u{00E9}", "\u{1F600}\u{0085}"]),
        ("==\"\u{2028}\"b\u{000D}\u{000D}$  \u{000A}\u{000B}\u{00A0}", ["==\"\u{2028}\"b", "$"]),
        ("\u{0003}-\"'\u{000D}\u{2028}\u{0003}\u{1F600}", ["\u{0003}-", "\u{0003}\u{1F600}"]),
    ]
}
