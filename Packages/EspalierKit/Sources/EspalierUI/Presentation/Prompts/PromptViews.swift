// The sheets for the prompts git waits on: an SSH key's passphrase, an SSH
// user's password, credentials for a host that isn't GitHub, a failed hook,
// and an unknown SSH host. Their fields are a form's rows, labeled in the
// form's column.

import SwiftUI

/// The alert for an unknown SSH host.
nonisolated public enum SSHHostPrompt {
    public static func alert(host: String, ip: String, keyType: String, fingerprint: String) -> AlertContent {
        AlertContent(
            title: "SSH Host",
            message: "The authenticity of host '\(host) (\(ip))' can't be established. \(keyType) key fingerprint is \(fingerprint).\n\nAre you sure you want to continue connecting?",
            buttons: [AlertContent.Button("Connect", role: .primary), AlertContent.Button("Cancel", role: .cancel)]
        )
    }
}

/// A secret and whether to remember it.
public struct SecretPromptAnswer: Equatable {
    public var secret: String
    public var remember: Bool
}

/// A secure field and a "Remember" checkbox under the question: the SSH key
/// passphrase and SSH user password prompts.
struct SecretPrompt: View {
    let title: String
    /// The question, under the title.
    let message: String
    /// The field's label ("Passphrase").
    let fieldLabel: String
    let rememberTitle: String
    let onAnswer: (SecretPromptAnswer?) -> Void
    @State private var secret = ""
    @State private var remember = false

    var body: some View {
        SheetScaffold(title, message: message, width: Metrics.Sheet.compactWidth) {
            Form {
                // The label in the form's column; the field is a capsule.
                LabeledContent(fieldLabel) {
                    SecureField(fieldLabel, text: $secret)
                        .labelsHidden()
                }
                Toggle(rememberTitle, isOn: $remember)
                    .toggleStyle(.checkboxMark)
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
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
            message: "Enter passphrase for key '\(keyPath)':",
            fieldLabel: "Passphrase",
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
            message: "Enter password for '\(username)':",
            fieldLabel: "Password",
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
            Form {
                // The labels in the form's column; the fields are capsules.
                if knownUsername == nil {
                    LabeledContent("Username") {
                        TextField("Username", text: $username)
                            .labelsHidden()
                    }
                }
                LabeledContent("Password") {
                    VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                        HStack(spacing: Metrics.grid) {
                            Group {
                                if showsPassword {
                                    TextField("Password", text: $password)
                                } else {
                                    SecureField("Password", text: $password)
                                }
                            }
                            .labelsHidden()
                            Button {
                                showsPassword.toggle()
                            } label: {
                                Label(showsPassword ? "Hide Password" : "Show Password", systemImage: showsPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.icon)
                            .help(showsPassword ? "Hide Password" : "Show Password")
                            .accessibilityLabel(showsPassword ? "Hide Password" : "Show Password")
                        }
                        FieldMessage("Your hosting service may need a personal access token instead of your password.", kind: .note)
                    }
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
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

/// "<hook> Failed": the hook's output, as tall as it is up to the terminal
/// height, Abort, and Ignore and Continue.
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
        } buttons: {
            SheetButtons("Ignore and Continue", confirmRole: .destructive, cancelTitle: "Abort", cancel: { onAnswer(.abort) }) {
                onAnswer(.ignore)
            }
        }
    }
}
