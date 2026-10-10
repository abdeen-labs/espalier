// Ported from desktop/app/src/lib/hooks/get-shell.ts

/// The shell that loads the user's environment for hooks.
public struct LoginShell: Sendable {
    /// The path of the shell.
    public let shell: String

    /// The arguments that come before the quoted command. They run it in an
    /// interactive login shell, so the user's startup files set up the
    /// environment.
    public let args: [String]

    let quoting: ShellEscape.Shell

    /// Quotes `cmd` and each of `args` as a single word for the shell, and
    /// joins them with spaces.
    public func quoteCommand(_ cmd: String, _ args: String...) -> String {
        quoting.quoteCommand(cmd, args)
    }
}

/// Returns the user's login shell: `SHELL` from the git runtime's
/// environment, falling back to `/bin/sh`.
public func getShell() -> LoginShell {
    // For our purposes quoting using bash rules should be sufficient,
    // we only need to pass a path to an executable that we control.
    // Should we start using this to quote commands that Git gives us
    // those are quite innocuous as well (like shas and paths). There
    // shouldn't be any user input in there.
    let bash = ShellEscape.bash
    return LoginShell(
        shell: GitRuntime.current.processEnvironment["SHELL"] ?? "/bin/sh",
        args: bash.args,
        quoting: bash
    )
}
