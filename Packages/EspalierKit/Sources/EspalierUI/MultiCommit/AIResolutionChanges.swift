// Ported in part from desktop/app/src/ui/multi-commit-operation/dialog/copilot-conflicts-changes.tsx
//
// The AI conflict sheet's Changes tab, a read-only diff of what each
// conflicted file would become (the model's resolution, or the side chosen)
// against the file on disk with its conflict markers
// (`resolutionDiff(forPath:hidesWhitespace:)`): the files on the left, the
// diff (`DiffContainer`) on the right.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// The Changes tab: each resolved file's diff.
struct AIResolutionChanges: View {
    let repository: RepositoryModel
    /// The conflicted files, in the results' order.
    let paths: [String]
    @State private var selectedPath: String?
    @State private var diff = ResolutionDiffState.loading

    /// The file list's width.
    private static let listWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            List(paths, id: \.self, selection: $selectedPath) { path in
                VStack(alignment: .leading, spacing: 1) {
                    Text(POSIXPath.basename(path))
                        .foregroundStyle(.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(choiceLabel(for: path))
                        .font(Typography.subheadline)
                        .foregroundStyle(.text2)
                }
                .padding(.vertical, Metrics.grid)
                .selectableRow(isSelected: path == selectedPath)
                .tooltip(path)
                .tag(path)
                .listRowInsets(Metrics.ListRow.insets(isFirst: path == paths.first, isLast: path == paths.last))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .rowsDrawSelection()
            .background(Color(espalier: Palette.sidebar))
            .frame(width: Self.listWidth)
            Hairline(.vertical)
            diffView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedPath == nil {
                selectedPath = paths.first
            }
        }
        .task(id: DiffKey(path: selectedPath, choice: selectedPath.map { repository.ai.resolutionChoice(forPath: $0) })) {
            await load()
        }
    }

    @ViewBuilder
    private var diffView: some View {
        if let selectedPath {
            switch diff {
            case .loading:
                DelayedProgressView()
            case .loaded(let resolution?):
                DiffContainer(.loaded(resolution.diff), file: DiffFileInfo(path: selectedPath, status: .conflicted), context: .aiResolution)
            case .loaded(nil):
                PlaceholderNote("No suggested changes for this file")
            case .failed(let message):
                PlaceholderNote(message)
            }
        } else {
            PlaceholderNote("Select a file to see its resolution")
        }
    }

    private func choiceLabel(for path: String) -> String {
        switch repository.ai.resolutionChoice(forPath: path) {
        case .model: "The model's suggestion"
        case .ours: "Current"
        case .theirs: "Incoming"
        }
    }

    private func load() async {
        guard let selectedPath else {
            return
        }
        if case .loaded = diff {
            // Keep showing the last diff until the next one arrives.
        } else {
            diff = .loading
        }
        do {
            let loaded = try await repository.ai.resolutionDiff(forPath: selectedPath)
            if !Task.isCancelled {
                diff = .loaded(loaded)
            }
        } catch {
            if !Task.isCancelled {
                diff = .failed(error.message)
            }
        }
    }
}

/// The Changes tab's diff.
enum ResolutionDiffState: Equatable {
    case loading
    /// Nil when the file has no suggestion and no side is chosen.
    case loaded(ResolutionDiff?)
    case failed(String)
}

/// What the diff depends on: the file, and how it's resolved.
private struct DiffKey: Equatable {
    let path: String?
    let choice: ConflictResolutionChoice?
}
