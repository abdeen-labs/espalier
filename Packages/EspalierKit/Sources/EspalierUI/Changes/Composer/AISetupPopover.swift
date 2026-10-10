// The sparkle's popovers: setting up a provider when there's none, and
// choosing the model for commit messages when several are set up and none is
// chosen (AIKit never falls back silently).

import SwiftUI

/// Which popover the sparkle shows.
nonisolated public enum SparklePopover: Sendable, Equatable, Identifiable {
    case setup
    case chooseModel

    public var id: Self {
        self
    }
}

/// "Generate Commit Messages": no provider is set up yet.
public struct AISetupPopover: View {
    private let onOpenSettings: () -> Void

    public init(onOpenSettings: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            Label("Generate Commit Messages", systemImage: "sparkles")
                .font(Typography.heading)
            Text("Add a provider to use your own API key with OpenAI-compatible endpoints, Azure, Anthropic, or local providers like Ollama.")
                .font(Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Open AI Settings…", action: onOpenSettings)
                    .buttonStyle(.prominent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.insetLarge)
        .frame(width: Metrics.Composer.popoverWidth, alignment: .leading)
    }
}

/// "Choose a Model": several models are set up and none is chosen for
/// commit messages.
public struct AIModelPopover: View {
    private let choices: [SparkleModelChoice]
    private let onChoose: (SparkleModelChoice) -> Void

    public init(_ choices: [SparkleModelChoice], onChoose: @escaping (SparkleModelChoice) -> Void = { _ in }) {
        self.choices = choices
        self.onChoose = onChoose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            Text("Choose a Model")
                .font(Typography.heading)
            Text("Pick the model that writes commit messages. You can change it in Settings ▸ AI.")
                .font(Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(choices) { choice in
                    Button {
                        onChoose(choice)
                    } label: {
                        HStack {
                            Text(choice.modelName)
                            Spacer(minLength: Metrics.insetSmall)
                            Text(choice.providerName)
                                .foregroundStyle(.secondary)
                        }
                        .font(Typography.row)
                        .padding(.vertical, Metrics.grid)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.modelName), \(choice.providerName)")
                    if choice.id != choices.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(Metrics.insetLarge)
        .frame(width: Metrics.Composer.popoverWidth, alignment: .leading)
    }
}
