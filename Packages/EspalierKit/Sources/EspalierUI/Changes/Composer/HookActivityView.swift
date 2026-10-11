// The composer's hook line: while a commit runs a hook, a line says so, with
// Show Output (the live terminal output in a popover) and Stop. The state
// layer reports the hook (`ActiveOperation.hook`), its output
// (`terminalOutput`), and aborts it (`RepositoryModel.abortRunningHook()`).

import EspalierCore
import GitKit
import Synchronization
import SwiftUI

/// What the hook line shows.
nonisolated public struct HookActivityContent: Sendable, Equatable {
    /// The hook's name, such as `pre-commit`.
    public var hookName: String
    public var status: HookActivity.Status
    /// Whether the commit's terminal output can be shown.
    public var canShowOutput: Bool

    public init(hookName: String, status: HookActivity.Status, canShowOutput: Bool = true) {
        self.hookName = hookName
        self.status = status
        self.canShowOutput = canShowOutput
    }

    /// "pre-commit hook running…", "… finished", "… failed".
    public var text: String {
        if hookName == "pre-auto-gc", status == .finished {
            return "Optimizing repository…"
        }
        switch status {
        case .running: return "\(hookName) hook running…"
        case .finished: return "\(hookName) hook finished"
        case .failed: return "\(hookName) hook failed"
        }
    }

    /// Whether Stop applies: the hook is still running.
    public var canStop: Bool {
        status == .running
    }
}

/// The hook line: its state, Show Output, and Stop.
public struct HookActivityView: View {
    private let content: HookActivityContent
    private let output: TerminalOutputListener?
    private let onStop: () -> Void
    @State private var isShowingOutput = false

    /// - Parameters:
    ///   - output: Subscribes to the commit's live terminal output.
    ///   - onStop: Aborts the running hook.
    public init(_ content: HookActivityContent, output: TerminalOutputListener? = nil, onStop: @escaping () -> Void = {}) {
        self.content = content
        self.output = output
        self.onStop = onStop
    }

    public var body: some View {
        // One line when it fits; else the buttons go under the text.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.insetSmall) {
                status
                    .fixedSize()
                Spacer(minLength: Metrics.insetSmall)
                buttons
            }
            VStack(alignment: .leading, spacing: Metrics.grid) {
                status
                HStack(spacing: Metrics.insetSmall) {
                    Spacer(minLength: 0)
                    buttons
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var status: some View {
        HStack(spacing: Metrics.insetSmall) {
            statusGlyph
            Text(content.text)
                .font(Typography.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var buttons: some View {
        HStack(spacing: Metrics.insetSmall) {
            if content.canShowOutput {
                Button("Show Output") {
                    isShowingOutput = true
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .popoverCard(isPresented: $isShowingOutput, edge: .top, title: "Hook Output") {
                    LiveHookOutput(listener: output)
                }
            }
            Button("Stop", action: onStop)
                .buttonStyle(.quiet)
                .controlSize(.small)
                .disabled(!content.canStop)
                .tooltip("Stop the \(content.hookName) hook")
        }
        .fixedSize()
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch content.status {
        case .running:
            ArcProgress(.mini)
                .accessibilityHidden(true)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.success))
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color(espalier: Palette.error))
                .accessibilityHidden(true)
        }
    }
}

/// A hook's terminal output: SF Mono, selectable, scrolled to the end.
public struct HookOutputView: View {
    private let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SelectableText(text.isEmpty ? "No output yet." : text, font: AppKitTypography.sha, color: text.isEmpty ? .secondaryLabelColor : .labelColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.insetMedium)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.endID)
                }
            }
            .onChange(of: text, initial: true) {
                proxy.scrollTo(Self.endID, anchor: .bottom)
            }
        }
        .frame(width: Metrics.Composer.hookOutputWidth, height: Metrics.Composer.hookOutputHeight)
        .accessibilityLabel("Hook output")
    }

    private static let endID = "end"
}

/// The output popover, following the commit's output live.
struct LiveHookOutput: View {
    let listener: TerminalOutputListener?
    @State private var stream = HookOutputStream()

    var body: some View {
        HookOutputView(text: stream.text)
            .onAppear {
                stream.start(listener)
            }
            .onDisappear {
                stream.stop()
            }
    }
}

/// Collects a git process's terminal output for the popover.
@MainActor @Observable
final class HookOutputStream {
    private(set) var text = ""

    @ObservationIgnored private var subscription: TerminalOutputSubscription?
    /// Chunks that arrived off the main actor, in order, waiting to be
    /// appended.
    @ObservationIgnored private let pending = ChunkBuffer()

    /// The output kept: the end of a long run.
    static let maximumLength = 200_000

    /// Subscribes to `listener`: everything so far, then each new chunk.
    func start(_ listener: TerminalOutputListener?) {
        guard subscription == nil, let listener else {
            return
        }
        let pending = pending
        subscription = listener { [weak self] chunk in
            pending.append(chunk)
            Task { @MainActor [weak self] in
                self?.flush()
            }
        }
    }

    func stop() {
        subscription?.unsubscribe()
        subscription = nil
    }

    private func flush() {
        let chunks = pending.drain()
        guard !chunks.isEmpty else {
            return
        }
        var updated = text + chunks.joined()
        if updated.count > Self.maximumLength {
            updated = String(updated.suffix(Self.maximumLength))
        }
        text = updated
    }

    isolated deinit {
        subscription?.unsubscribe()
    }
}

/// Terminal output chunks, appended from any thread, drained on the main
/// actor in order.
nonisolated final class ChunkBuffer: Sendable {
    private let chunks = Mutex<[String]>([])

    func append(_ chunk: String) {
        chunks.withLock { $0.append(chunk) }
    }

    func drain() -> [String] {
        chunks.withLock { chunks in
            defer { chunks = [] }
            return chunks
        }
    }
}
