import Foundation
import GitKit
import Testing

@Suite("hooks/shell-escape")
struct ShellEscapeTests {
    @Test("quotes the command and each argument")
    func quotesEachArgument() {
        #expect(ShellEscape.bash.quoteCommand("/path/to/printenvz") == "'/path/to/printenvz'")
        #expect(ShellEscape.bash.quoteCommand("cmd", "a b", "") == "'cmd' 'a b' ''")
        // Inside single quotes, everything but a single quote is literal.
        #expect(
            ShellEscape.bash.quoteCommand(#"$HOME `id` "x" * ~ \ "# + "\n !")
                == #"'$HOME `id` "x" * ~ \ "# + "\n !'"
        )
    }

    @Test("escapes single quotes")
    func escapesSingleQuotes() {
        #expect(ShellEscape.bash.quoteCommand("it's") == #"'it'\''s'"#)
        #expect(ShellEscape.bash.quoteCommand("'") == #"''\'''"#)
        #expect(ShellEscape.bash.quoteCommand("''") == #"''\'''\'''"#)
    }

    @Test("removes NUL, backspace, escape, and CSI characters")
    func removesControlCharacters() {
        #expect(ShellEscape.bash.quoteCommand("a\0b\u{8}c\u{1B}d\u{9B}e") == "'abcde'")
    }

    @Test("removes lone carriage returns and keeps CRLF")
    func removesLoneCarriageReturns() {
        #expect(ShellEscape.bash.quoteCommand("a\rb\r\nc\r") == "'ab\r\nc'")
        // The control characters go first, so a carriage return that they
        // separated from its line feed stays.
        #expect(ShellEscape.bash.quoteCommand("a\r\0\nb") == "'a\r\nb'")
    }

    @Test("escapes Unicode scalars, not grapheme clusters")
    func escapesUnicodeScalars() {
        // The quote and the combining mark after it form one grapheme cluster.
        #expect(ShellEscape.bash.quoteCommand("e\u{301}'\u{301}") == "'e\u{301}'\\''\u{301}'")
    }

    @Test("quoted commands reach the shell unchanged", arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
    func roundTrip(shell: String) async throws {
        let arguments = [
            "plain",
            "with space",
            "it's",
            #"$HOME `id` "x" * ~ \ ! ; & | < > ( ) { } [ ] # ?"#,
            "line1\nline2\r\nline3",
            "",
            "é ü 🙂",
        ]
        let command = ShellEscape.bash.quoteCommand(
            "printf", "%s\\0",
            arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6]
        )

        let stdout = try await runProcess(shell, ["-c", command])

        let printed = String(decoding: stdout, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        #expect(printed == arguments)
    }
}
