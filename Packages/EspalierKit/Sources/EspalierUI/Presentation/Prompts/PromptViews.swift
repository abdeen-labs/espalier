// The sheets for the prompts git waits on: an SSH key's passphrase, an SSH
// user's password, credentials for a host that isn't GitHub, a failed hook,
// and an unknown SSH host.

import SwiftUI

/// The alert for an unknown SSH host.
nonisolated public enum SSHHostPrompt {
    public static func alert(host: String, ip: String, keyType: String, fingerprint: String) -> AlertContent {
        AlertContent(
            title: "SSH Host",
            message: "The authenticity of host '\(host) (\(ip))' can't be established. \(keyType) key fingerprint is \(fingerprint).\n\nAre you sure you want to continue connecting?",
            buttons: [AlertContent.Button("Yes", role: .primary), AlertContent.Button("No", role: .cancel)]
        )
    }
}

/// A secret and whether to remember it.
public struct SecretPromptAnswer: Equatable {
    public var secret: String
    public var remember: Bool
}

/// A secure field with a label and a "Remember" checkbox: the SSH key
/// passphrase and SSH user password prompts.
struct SecretPrompt: View {
    let title: String
    let label: String
    /// The empty field's placeholder ("Passphrase"), so the label above
    /// isn't repeated inside it.
    let placeholder: String
    let rememberTitle: String
    let onAnswer: (SecretPromptAnswer?) -> Void
    @State private var secret = ""
    @State private var remember = false

    var body: some View {
        SheetScaffold(title, width: Metrics.Sheet.compactWidth) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                Text(label)
                    .font(Typography.row)
                    .foregroundStyle(.text2)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(label, text: $secret, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.capsule)
            }
            Toggle(rememberTitle, isOn: $remember)
                .toggleStyle(.checkbox)
        } buttons: {
            SheetButtons("OK", isConfirmDisabled: secret.isEmpty, cancel: { onAnswer(nil) }) {
                onAnswer(SecretPromptAnswer(secret: secret, remember: remember))
            }
        }
    }
}

/// "SSH Key Passphrase".
public struct PassphrasePrompt: View {
    private let keyPath: String
    private let onAnswer: (SecretPromptAnswer?) -> Void

    public init(keyPath: String, onAnswer: @escaping (SecretPromptAnswer?) -> Void) {
        self.keyPath = keyPath
        self.onAnswer = onAnswer
    }

    public var body: some View {
        SecretPrompt(
            title: "SSH Key Passphrase",
            label: "Enter passphrase for key '\(keyPath)':",
            placeholder: "Passphrase",
            rememberTitle: "Remember passphrase",
            onAnswer: onAnswer
        )
    }
}

/// "SSH User Password".
public struct PasswordPrompt: View {
    private let username: String
    private let onAnswer: (SecretPromptAnswer?) -> Void

    public init(username: String, onAnswer: @escaping (SecretPromptAnswer?) -> Void) {
        self.username = username
        self.onAnswer = onAnswer
    }

    public var body: some View {
        SecretPrompt(
            title: "SSH User Password",
            label: "Enter password for '\(username)':",
            placeholder: "Password",
            rememberTitle: "Remember password",
            onAnswer: onAnswer
        )
    }
}

/// Credentials for a host that isn't GitHub.
public struct GenericAuthAnswer: Equatable {
    public var username: String
    public var password: String
}

/// "Authentication Failed": a username (when git doesn't know it) and a
/// password or token.
public struct GenericAuthPrompt: View {
    private let endpoint: String
    private let knownUsername: String?
    private let onAnswer: (GenericAuthAnswer?) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var showsPassword = false

    public init(endpoint: String, username: String?, onAnswer: @escaping (GenericAuthAnswer?) -> Void) {
        self.endpoint = endpoint
        knownUsername = username
        self.onAnswer = onAnswer
    }

    public var body: some View {
        SheetScaffold("Authentication Failed", message: explanation) {
            if knownUsername == nil {
                VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                    FieldLabel("Username")
                    TextField("Username", text: $username)
                        .labelsHidden()
                        .textFieldStyle(.capsule)
                }
            }
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Password")
                HStack(spacing: Metrics.grid) {
                    Group {
                        if showsPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.capsule)
                    Button {
                        showsPassword.toggle()
                    } label: {
                        Label(showsPassword ? "Hide Password" : "Show Password", systemImage: showsPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.icon)
                    .help(showsPassword ? "Hide Password" : "Show Password")
                    .accessibilityLabel(showsPassword ? "Hide Password" : "Show Password")
                }
            }
            Text("Your hosting service may need a personal access token instead of your password.")
                .font(Typography.meta)
                .foregroundStyle(.text3)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            SheetButtons("OK", isConfirmDisabled: password.isEmpty || (knownUsername ?? username).isEmpty, cancel: { onAnswer(nil) }) {
                onAnswer(Self.answer(knownUsername: knownUsername, enteredUsername: username, password: password))
            }
        }
    }

    /// OK's answer: the username git asked about, else the one entered,
    /// and the password.
    static func answer(knownUsername: String?, enteredUsername: String, password: String) -> GenericAuthAnswer {
        GenericAuthAnswer(username: knownUsername ?? enteredUsername, password: password)
    }

    private var explanation: String {
        if let knownUsername {
            return "Espalier couldn't sign in to \(endpoint). Enter the password for \(knownUsername) to try again."
        }
        return "Espalier couldn't sign in to \(endpoint). Enter your username and password to try again."
    }
}

/// "<hook> Failed": the hook's output, Abort, and Ignore and Continue.
public struct HookFailedPrompt: View {
    /// What to do about the failed hook.
    public enum Answer: Equatable {
        case abort, ignore
    }

    private let hookName: String
    private let terminalOutput: String
    private let onAnswer: (Answer) -> Void

    public init(hookName: String, terminalOutput: String, onAnswer: @escaping (Answer) -> Void) {
        self.hookName = hookName
        self.terminalOutput = terminalOutput
        self.onAnswer = onAnswer
    }

    public var body: some View {
        SheetScaffold("\(hookName) Failed", message: "The \(hookName) hook failed. What would you like to do?", width: Metrics.Sheet.terminalWidth) {
            TerminalOutputView(terminalOutput)
                .frame(height: Metrics.Sheet.terminalHeight)
        } buttons: {
            SheetButtons("Ignore and Continue", confirmRole: .destructive, cancelTitle: "Abort", cancel: { onAnswer(.abort) }) {
                onAnswer(.ignore)
            }
        }
    }
}
