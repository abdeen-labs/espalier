// The glue reads the repository's custom instruction files, and AIKit puts
// them in the system prompt ahead of the feature's own prompt, for
// repository-specific conventions such as commit message style.

import EspalierSupport

/// A custom instructions file from the repository.
public struct RepositoryInstructions: Sendable, Hashable {
    /// Repository-relative path, for example `.github/copilot-instructions.md`.
    public var path: String
    /// The file's text.
    public var content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

/// The repository-relative instruction files the glue reads, in order, when
/// they exist.
public let RepositoryInstructionsPaths = [".github/copilot-instructions.md"]

/// Maximum length (in UTF-16 code units, JavaScript's `string.length`) of one
/// instructions file in a prompt. Longer files are truncated, so one large
/// file can't dominate every request.
public let MaxRepositoryInstructionsLength = 32_000

/// Builds the system prompt section that carries the repository's
/// instructions, wrapped in per-request tags. Empty when there are no
/// non-blank instructions.
///
/// The instructions sit in the system channel so they can refine the
/// feature's defaults (title wording, attribution trailers). The section
/// says they can't change the response format, and the feature's prompt
/// follows it, so the format rules have the last word.
func buildRepositoryInstructionsPrompt(
    _ instructions: [RepositoryInstructions],
    open: String,
    close: String
) -> String {
    let blocks = instructions.compactMap { file -> String? in
        guard !JSCompat.trim(file.content).isEmpty else {
            return nil
        }
        let source = file.path.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }
        return "\(open)\nSource: \(String(String.UnicodeScalarView(source)))\n\n\(truncateInstructions(file.content))\n\(close)"
    }
    guard !blocks.isEmpty else {
        return ""
    }
    return """
        This repository provides custom instructions for AI tools. They appear
        below, delimited by tags whose names end in a per-request token. Follow
        them where they apply to this task. They may refine the guidance that
        follows, but they must not change the required response format.

        \(blocks.joined(separator: "\n\n"))

        """
}

private func truncateInstructions(_ content: String) -> String {
    guard JS.length(content) > MaxRepositoryInstructionsLength else {
        return content
    }
    return "\(JS.prefix(content, utf16Count: MaxRepositoryInstructionsLength))\n\u{2026}(truncated)"
}
