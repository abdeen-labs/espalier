// The sign-in sheet's first step for GitHub Enterprise: the server's address
// (placeholder "https://example.ghe.com"), and the client ID of an OAuth app
// registered on it with the device flow enabled (a client ID per server).
// Errors are the model's (an invalid URL, https only, and the server check),
// shown under the fields; a github.com address switches to GitHub.com's
// sign-in.

import SwiftUI

/// The Enterprise server's address and OAuth app.
struct EnterpriseAddressStep: View {
    let content: EnterpriseAddressContent
    let cancel: () -> Void
    let submit: (_ address: String, _ clientID: String) -> Void
    @State private var address: String
    @State private var clientID: String
    @FocusState private var focusedField: Field?
    @Environment(\.motion) private var motion

    private enum Field {
        case address, clientID
    }

    init(content: EnterpriseAddressContent, cancel: @escaping () -> Void, submit: @escaping (_ address: String, _ clientID: String) -> Void) {
        self.content = content
        self.cancel = cancel
        self.submit = submit
        _address = State(initialValue: content.address)
        _clientID = State(initialValue: content.clientID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            Form {
                // Verbatim: a localized key's Markdown would draw the
                // placeholder as a link.
                // The labels in the form's column; the fields are capsules.
                LabeledContent("Enterprise address") {
                    TextField("Enterprise address", text: $address, prompt: Text(verbatim: "https://example.ghe.com").fieldPrompt())
                        .labelsHidden()
                        .focused($focusedField, equals: .address)
                        .textContentType(.URL)
                }
                LabeledContent("OAuth App Client ID") {
                    TextField("OAuth App Client ID", text: $clientID)
                        .labelsHidden()
                        .focused($focusedField, equals: .clientID)
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
            .disabled(content.isChecking)
            Text(helpText)
                .font(Typography.meta)
                .foregroundStyle(.text3)
                .fixedSize(horizontal: false, vertical: true)
            if let error = content.error {
                // Fades in over 0.22 s and out over 0.15 s. It comes with
                // the fields enabling again, which draws at once, so the
                // buttons below shift at once too.
                SignInInlineError(message: error)
                    .barTransition()
            }
            HStack(spacing: Metrics.insetSmall) {
                // The check's progress fades in and out over 0.15 s.
                if content.isChecking {
                    ArcProgress(.small)
                        .transition(checkingTransition)
                    Text("Checking the server…")
                        .font(Typography.secondary)
                        .foregroundStyle(.text2)
                        .transition(checkingTransition)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    submit(address, clientID)
                }
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
                .disabled(content.isChecking || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, Metrics.grid)
        }
        .onAppear {
            focusedField = content.address.isEmpty ? .address : .clientID
        }
    }

    /// The check's progress coming and going: a fade of its own, so the
    /// fields and buttons it disables and enables change at once.
    private var checkingTransition: AnyTransition {
        motion.animates ? AnyTransition.opacity.animation(Motion.animation(Motion.leave)) : .identity
    }

    /// "Your administrator can register an OAuth app with device flow
    /// enabled on <host>."
    private var helpText: String {
        let host = URL(string: address.trimmingCharacters(in: .whitespaces)).flatMap(\.host) ?? ""
        let server = host.isEmpty ? "your server" : host
        return "Your administrator can register an OAuth app with device flow enabled on \(server)."
    }
}
