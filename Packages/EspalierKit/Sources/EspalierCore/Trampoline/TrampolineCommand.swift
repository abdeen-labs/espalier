// Ported from desktop/app/src/lib/trampoline/trampoline-command.ts

import Foundation

/// Represents a command in our trampoline mechanism.
struct TrampolineCommand: Sendable {
    /// Identifier of the command: askpass, credential helper, or hook proxy.
    ///
    /// This will be used to find a suitable handler in the app to react to
    /// the command.
    let identifier: TrampolineWire.RequestKind

    /// Trampoline token sent with this command via the
    /// `ESPALIER_TRAMPOLINE_TOKEN` (or, for hooks, `ESPALIER_HOOKS_TOKEN`)
    /// environment variable.
    let trampolineToken: String

    /// Parameters of the command.
    ///
    /// This corresponds to the command line arguments (argv) except the name
    /// of the program (argv[0]), except for hooks, where the first parameter
    /// is the path git ran.
    let parameters: [String]

    /// Environment variables that were set when the command was invoked.
    let environmentVariables: [String: String]

    /// The helper's working directory.
    let workingDirectory: String

    /// Whether the helper forwards its standard input, which is streamed (see
    /// `TrampolineConnection.standardInput`).
    let forwardsStandardInput: Bool

    /// The process that started the helper, or nil when it can't be found:
    /// for askpass, the ssh or ssh-keygen process asking.
    let parentProcessID: pid_t?
}

/// Represents a handler for trampoline commands, registered for one token.
///
/// Handlers write their output and exit status to the connection
/// themselves, because the hook proxy streams output while the hook runs.
protocol TrampolineCommandHandler: Sendable {
    func handle(_ command: TrampolineCommand, connection: TrampolineConnection) async
}
