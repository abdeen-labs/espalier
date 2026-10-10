// Ported from desktop/app/src/lib/hooks/shell-escape.ts

/// Quoting for the shells that load the environment for hooks.
///
/// The login shell's quoting is always bash's (`getShell`).
public enum ShellEscape {
    /// How to run a command in a shell: the arguments that come before the
    /// command, and how to quote the command.
    public struct Shell: Sendable {
        /// The arguments that come before the quoted command.
        public let args: [String]

        /// Escapes one argument for use inside single quotes.
        let escape: @Sendable (_ arg: String) -> String

        /// Quotes `cmd` and each of `args` as a single word, and joins them
        /// with spaces.
        public func quoteCommand(_ cmd: String, _ args: String...) -> String {
            quoteCommand(cmd, args)
        }

        func quoteCommand(_ cmd: String, _ args: [String]) -> String {
            shQuoteCommand(escape, cmd, args)
        }
    }

    public static let bash = Shell(args: ["-ilc"], escape: bashEscape)
}

// https://github.com/ericcornelissen/shescape/blob/89072ba7de233f81f5553b52098671c94eb9bd0c/src/internal/unix/bash.js#L39
//
// The regexes match Unicode scalars. Swift's default grapheme semantics
// would read "\r\n", or a quote followed by a combining mark, as one
// character.
private func bashEscape(_ arg: String) -> String {
    arg
        .replacing(/[\0\u{8}\u{1B}\u{9B}]/.matchingSemantics(.unicodeScalar), with: "")
        .replacing(/\r(?!\n)/.matchingSemantics(.unicodeScalar), with: "")
        .replacing(/'/.matchingSemantics(.unicodeScalar), with: "'\\''")
}

private func shQuoteCommand(_ escapeFn: (String) -> String, _ cmd: String, _ args: [String]) -> String {
    ([cmd] + args).map { "'\(escapeFn($0))'" }.joined(separator: " ")
}
