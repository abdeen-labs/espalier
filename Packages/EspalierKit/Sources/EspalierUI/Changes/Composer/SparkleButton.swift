// The sparkle in the summary field, which generates a commit message with
// the user's AI provider. Its states: ready, no files, no provider (opens
// setup), several models and none chosen (asks), generating (cancels), done
// (stays tinted until edited), and hidden while AI is turned off.
// `app.ai.status(for:)`, the repository's `commitMessageGeneration`, and
// `hasChangesToDescribe` decide the state.

import AIKit
import EspalierCore
import GitKit
import SwiftUI

/// The sparkle's state.
nonisolated public enum SparkleState: Sendable, Equatable {
    /// AI features are off (Settings ▸ AI): no sparkle.
    case hidden
    /// Generates with the model.
    case ready(model: String?)
    /// No files are included and nothing is being amended: disabled.
    case noFiles(model: String?)
    /// No provider is set up: opens the setup popover.
    case noProvider
    /// Several models and none chosen for commit messages: asks which.
    case chooseModel
    /// A message is being generated: cancels it.
    case generating
    /// The fields hold a generated message the user hasn't edited.
    case generated(model: String?)
    /// A commit is running: disabled.
    case unavailable(model: String?)

    /// Whether the button does anything now.
    public var isEnabled: Bool {
        switch self {
        case .hidden, .noFiles, .unavailable: false
        case .ready, .noProvider, .chooseModel, .generating, .generated: true
        }
    }

    /// The tooltip.
    public var help: String {
        switch self {
        case .hidden: ""
        case .ready(let model), .generated(let model), .unavailable(let model): Self.generateTitle(model)
        case .noFiles(let model): "\(Self.generateTitle(model)). Select files to generate a commit message."
        case .noProvider, .chooseModel: "Generate Commit Message"
        case .generating: "Cancel Generating Commit Details"
        }
    }

    /// "Generate Commit Message with GPT-5".
    static func generateTitle(_ model: String?) -> String {
        model.map { "Generate Commit Message with \($0)" } ?? "Generate Commit Message"
    }
}

extension SparkleState {
    /// The sparkle for a repository, from the status of commit message
    /// generation: hidden while AI is off; generating; setup without a
    /// provider; the model choice with several models and none chosen;
    /// else (a model resolves, consent given or not) whether there's
    /// something to describe and a commit runs.
    @MainActor
    public static func make(_ repository: RepositoryModel, app: AppModel, isCommitting: Bool) -> SparkleState {
        let ai = app.ai
        switch ai.status(for: .commitMessageGeneration) {
        case .disabled:
            return .hidden
        case .needsProvider where repository.ai.commitMessageGeneration != .generating:
            return .noProvider
        case .needsModelChoice where repository.ai.commitMessageGeneration != .generating:
            return .chooseModel
        case .needsProvider, .needsModelChoice, .needsConsent, .ready:
            break
        }
        if repository.ai.commitMessageGeneration == .generating {
            return .generating
        }
        let model = ai.resolvedModel(for: .commitMessageGeneration)?.model.name
        if !repository.ai.hasChangesToDescribe {
            return .noFiles(model: model)
        }
        if isCommitting {
            return .unavailable(model: model)
        }
        return repository.commit.draft.generatedByAI ? .generated(model: model) : .ready(model: model)
    }
}

/// A model the user can choose for commit messages, as the popover lists it.
nonisolated public struct SparkleModelChoice: Sendable, Equatable, Identifiable {
    /// The selection key (`AIModelChoice.key`).
    public var id: String
    public var modelName: String
    public var providerName: String

    public init(id: String, modelName: String, providerName: String) {
        self.id = id
        self.modelName = modelName
        self.providerName = providerName
    }

    /// The popover's entry for `choice`.
    public init(_ choice: AIModelChoice) {
        self.init(id: choice.key, modelName: choice.model.name, providerName: choice.provider.name)
    }
}

/// The sparkle button, first in the commit message card's footer: the
/// sparkles symbol in an accent-tinted circle, filled with the accent while
/// the message it generated is unedited.
public struct SparkleButton: View {
    private let state: SparkleState
    private let action: () -> Void
    @State private var isHovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ state: SparkleState, action: @escaping () -> Void = {}) {
        self.state = state
        self.action = action
    }

    public var body: some View {
        if state != .hidden {
            Button(action: action) {
                icon
                    .frame(width: ComposerMetrics.footerButtonSize, height: ComposerMetrics.footerButtonSize)
                    .background(Circle().fill(fill).hoverMotion(isHovering))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!state.isEnabled)
            .opacity(state.isEnabled ? 1 : CheckboxDrawing.disabledOpacity)
            .onHover { isHovering = $0 }
            .help(state.help)
            .accessibilityLabel(state.help)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if state == .generating {
            if isHovering {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
            } else {
                ArcProgress(.mini)
            }
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: ComposerMetrics.footerButtonSize / 2))
                .foregroundStyle(isGenerated ? Color.white : Color.accentColor)
        }
    }

    private var isGenerated: Bool {
        if case .generated = state {
            return true
        }
        return false
    }

    /// The circle: the accent's soft wash (deeper on hover), or the accent
    /// itself for a generated message.
    private var fill: Color {
        if isGenerated {
            return Color(espalier: Palette.button)
        }
        let alpha = contrast == .increased ? 0.2 : 0.12
        return Color.accentColor.opacity(isHovering && state.isEnabled ? alpha * 1.8 : alpha)
    }
}
