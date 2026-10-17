// About ▸ Acknowledgements: GitHub Desktop's MIT notice, which Espalier is
// based on; dugite, whose git runner Espalier ports; the tools bundled with
// Espalier, Git (GPL-2.0, with where its source is), Git LFS, Git
// Credential Manager, and Sparkle; SwiftTreeSitter, tree-sitter, and each grammar
// Espalier builds with, from their packages and Vendor/Grammars; and the
// bundled text fonts, each with its copyright and the SIL Open Font
// License as it ships with the font. The texts are in
// AcknowledgementTexts.swift, but the fonts', read from their files. It's a window of its own (a sheet
// would dwarf the About window): the components on the left, the selected
// one's license on the right.

import SwiftUI

/// Something Espalier is built on, with its license.
nonisolated struct Acknowledgement: Sendable, Equatable, Identifiable {
    /// The list's groups.
    enum Group: String, Sendable, CaseIterable {
        case basedOn = "Espalier Is Based On"
        case bundled = "Included with Espalier"
        case syntax = "Syntax Highlighting"
        case fonts = "Fonts"
    }

    /// The SwiftPM package identity, or a name for the others.
    var id: String
    var name: String
    var version: String?
    /// "MIT License", "GNU General Public License, version 2".
    var license: String
    var url: URL
    /// Something to know first, such as where Git's source is.
    var note: String?
    var text: String
    var group: Group

    /// "Version 2.53.0 · MIT License".
    var subtitle: String {
        [version.map { "Version \($0)" }, license].compactMap(\.self).joined(separator: " · ")
    }
}

extension Acknowledgement {
    /// Everything acknowledged, in the list's order.
    static let all: [Acknowledgement] = basedOn + bundled + syntax + fonts

    /// The bundled git's release (scripts/git-version, its build's tag).
    static let gitVersion = "2.53.0"
    static let bundledGitTag = "v2.53.0-4"

    static let basedOn: [Acknowledgement] = [
        Acknowledgement(
            id: "desktop",
            name: "GitHub Desktop",
            version: "3.6.7-beta2",
            license: "MIT License",
            url: URL(string: "https://github.com/desktop/desktop")!,
            note: "Espalier is a Mac app based on GitHub Desktop: its features, its Git behavior, and much of its wording.",
            text: AcknowledgementTexts.desktop,
            group: .basedOn
        ),
        Acknowledgement(
            id: "dugite",
            name: "dugite",
            version: "3.2.3",
            license: "MIT License",
            url: URL(string: "https://github.com/desktop/dugite")!,
            note: "Espalier runs Git the way dugite does.",
            text: AcknowledgementTexts.dugite,
            group: .basedOn
        ),
    ]

    static let bundled: [Acknowledgement] = [
        Acknowledgement(
            id: "git",
            name: "Git",
            version: gitVersion,
            license: "GNU General Public License, version 2",
            url: URL(string: "https://git-scm.com")!,
            note: "Espalier includes Git \(gitVersion), built by dugite-native \(bundledGitTag). Git's source code is at https://github.com/git/git/tree/v\(gitVersion), and the build's at https://github.com/desktop/dugite-native/tree/\(bundledGitTag).",
            text: AcknowledgementTexts.gpl2,
            group: .bundled
        ),
        Acknowledgement(
            id: "git-lfs",
            name: "Git LFS",
            version: "3.7.1",
            license: "MIT License",
            url: URL(string: "https://github.com/git-lfs/git-lfs")!,
            note: nil,
            text: AcknowledgementTexts.gitLFS,
            group: .bundled
        ),
        Acknowledgement(
            id: "git-credential-manager",
            name: "Git Credential Manager",
            version: "2.9.0",
            license: "MIT License",
            url: URL(string: "https://github.com/git-ecosystem/git-credential-manager")!,
            note: "Git Credential Manager's license is followed by the notices it ships with.",
            text: AcknowledgementTexts.gitCredentialManager + "\n\n" + AcknowledgementTexts.gitCredentialManagerNotice,
            group: .bundled
        ),
        Acknowledgement(
            id: "sparkle",
            name: "Sparkle",
            version: "2.10.0",
            license: "MIT License",
            url: URL(string: "https://sparkle-project.org")!,
            note: "Espalier updates itself with Sparkle. Its license is followed by those of the code it includes.",
            text: AcknowledgementTexts.packages["sparkle"] ?? "",
            group: .bundled
        ),
        // Create a New Repository's templates: generated from GitHub
        // Desktop 3.6.6's bundle by scripts/generate-repository-templates.swift.
        Acknowledgement(
            id: "gitignore",
            name: "gitignore templates",
            version: nil,
            license: "Creative Commons Zero v1.0 Universal",
            url: URL(string: "https://github.com/github/gitignore")!,
            note: "The .gitignore templates Create a New Repository offers are github/gitignore's.",
            text: AcknowledgementTexts.gitIgnoreTemplates,
            group: .bundled
        ),
        Acknowledgement(
            id: "choosealicense.com",
            name: "choosealicense.com",
            version: nil,
            license: "MIT License",
            url: URL(string: "https://github.com/github/choosealicense.com")!,
            note: "The licenses Create a New Repository offers come from choosealicense.com.",
            text: AcknowledgementTexts.chooseALicense,
            group: .bundled
        ),
        // Commit messages' :shortcode: emoji: generated from gemoji's
        // emoji.json by scripts/generate-emoji.swift.
        Acknowledgement(
            id: "gemoji",
            name: "gemoji",
            version: nil,
            license: "MIT License",
            url: URL(string: "https://github.com/github/gemoji")!,
            note: "The emoji shortcodes in commit messages are gemoji's. Espalier uses its table of shortcodes, not its images.",
            text: AcknowledgementTexts.gemoji,
            group: .bundled
        ),
    ]

    static let syntax: [Acknowledgement] = [
        package("swift-tree-sitter", name: "SwiftTreeSitter", version: "0.25.0", license: "BSD 3-Clause License", url: "https://github.com/tree-sitter/swift-tree-sitter"),
        package("tree-sitter", version: "0.25.10", url: "https://github.com/tree-sitter/tree-sitter"),
        package("tree-sitter-bash", version: "0.25.1", url: "https://github.com/tree-sitter/tree-sitter-bash"),
        package("tree-sitter-c", version: "0.24.2", url: "https://github.com/tree-sitter/tree-sitter-c"),
        package("tree-sitter-c-sharp", version: "0.23.5", url: "https://github.com/tree-sitter/tree-sitter-c-sharp"),
        package("tree-sitter-cpp", version: "0.23.4", url: "https://github.com/tree-sitter/tree-sitter-cpp"),
        package("tree-sitter-css", version: "0.25.0", url: "https://github.com/tree-sitter/tree-sitter-css"),
        package("tree-sitter-go", version: "0.25.0", url: "https://github.com/tree-sitter/tree-sitter-go"),
        package("tree-sitter-html", version: "0.23.2", url: "https://github.com/tree-sitter/tree-sitter-html"),
        package("tree-sitter-java", version: "0.23.5", url: "https://github.com/tree-sitter/tree-sitter-java"),
        package("tree-sitter-javascript", version: "0.25.0", url: "https://github.com/tree-sitter/tree-sitter-javascript"),
        package("tree-sitter-json", version: "0.24.8", url: "https://github.com/tree-sitter/tree-sitter-json"),
        package("tree-sitter-kotlin", version: "0.3.8", url: "https://github.com/fwcd/tree-sitter-kotlin"),
        package("tree-sitter-lua", version: "0.5.0", url: "https://github.com/tree-sitter-grammars/tree-sitter-lua"),
        package("tree-sitter-markdown", version: "0.5.3", url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown"),
        package("tree-sitter-objc", version: "3.0.2", url: "https://github.com/tree-sitter-grammars/tree-sitter-objc"),
        package("tree-sitter-php", version: "0.25.1", url: "https://github.com/tree-sitter/tree-sitter-php"),
        package("tree-sitter-python", version: "0.25.0", url: "https://github.com/tree-sitter/tree-sitter-python"),
        package("tree-sitter-ruby", version: "0.23.1", url: "https://github.com/tree-sitter/tree-sitter-ruby"),
        package("tree-sitter-rust", version: "0.24.2", url: "https://github.com/tree-sitter/tree-sitter-rust"),
        package("tree-sitter-swift", version: "0.7.4-with-generated-files", url: "https://github.com/alex-pinkus/tree-sitter-swift"),
        package("tree-sitter-toml", version: "0.7.0", url: "https://github.com/tree-sitter-grammars/tree-sitter-toml"),
        package("tree-sitter-typescript", version: "0.23.2", url: "https://github.com/tree-sitter/tree-sitter-typescript"),
        package("tree-sitter-yaml", version: "0.7.2", url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml"),
    ]

    /// The bundled text fonts (Resources/Fonts): each family's folder, and
    /// its license as the font ships it.
    static let fonts: [Acknowledgement] = [
        font("fixel", name: "Fixel Text", version: "1.000", url: "https://github.com/MacPaw/Fixel"),
        font("geist-mono", name: "Geist Mono", version: "1.701", url: "https://github.com/vercel/geist-font"),
        font("atkinson-hyperlegible-next", name: "Atkinson Hyperlegible Next", version: "2.001", url: "https://github.com/googlefonts/atkinson-hyperlegible-next"),
        font("atkinson-hyperlegible-mono", name: "Atkinson Hyperlegible Mono", version: "2.001", url: "https://github.com/googlefonts/atkinson-hyperlegible-next-mono"),
        font("martian-grotesk", name: "Martian Grotesk", version: "1.100", url: "https://github.com/evilmartians/grotesk"),
    ]

    /// The license file of the bundled font in `folder`.
    static func fontLicense(_ folder: String) -> String {
        guard let url = BundledFonts.directory?.appending(path: folder).appending(path: "OFL.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
    }

    private static func font(_ folder: String, name: String, version: String, url: String) -> Acknowledgement {
        Acknowledgement(
            id: "font-\(folder)",
            name: name,
            version: version,
            license: "SIL Open Font License 1.1",
            url: URL(string: url)!,
            note: nil,
            text: fontLicense(folder),
            group: .fonts
        )
    }

    private static func package(_ identity: String, name: String? = nil, version: String, license: String = "MIT License", url: String) -> Acknowledgement {
        Acknowledgement(
            id: identity,
            name: name ?? identity,
            version: version,
            license: license,
            url: URL(string: url)!,
            note: nil,
            text: AcknowledgementTexts.packages[identity] ?? "",
            group: .syntax
        )
    }
}

/// One acknowledgement: its name, version, license, links, and text.
struct AcknowledgementDetail: View {
    let acknowledgement: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.insetMedium) {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    Text(acknowledgement.name)
                        .font(Typography.commitSummary)
                        .foregroundStyle(.text)
                        .textSelection(.enabled)
                    Text(acknowledgement.subtitle)
                        .font(Typography.secondary)
                        .foregroundStyle(.text2)
                    TextLink(acknowledgement.url.absoluteString, destination: acknowledgement.url)
                        .font(Typography.secondary)
                }
                if let note = acknowledgement.note {
                    Text(note)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text(acknowledgement.text)
                    .font(Typography.terminal)
                    .foregroundStyle(.text2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Metrics.insetLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(acknowledgement.id)
    }
}

/// Acknowledgements: the components on the left, the selected one's
/// license on the right.
public struct AcknowledgementsView: View {
    @State private var selection: Acknowledgement.ID?

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Acknowledgement.Group.allCases, id: \.self) { group in
                    // The group's label is a row of its own: a list's
                    // floating header draws a line.
                    SectionLabel(group.rawValue)
                        .padding(.horizontal, Metrics.ListRow.horizontalPadding)
                        .padding(.top, Metrics.PaletteList.sectionTopPadding)
                        .padding(.bottom, Metrics.PaletteList.sectionBottomPadding)
                        .listRowInsets(EdgeInsets(top: 0, leading: Metrics.ListRow.inset, bottom: 0, trailing: Metrics.ListRow.inset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(Acknowledgement.all.filter { $0.group == group }) { acknowledgement in
                        Text(acknowledgement.name)
                            .foregroundStyle(.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .selectableRow(isSelected: acknowledgement.id == selection)
                            .tag(acknowledgement.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: Metrics.ListRow.inset, bottom: 1, trailing: Metrics.ListRow.inset))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .rowsDrawSelection()
            .background(Color(espalier: Palette.sidebar))
            .frame(width: Metrics.About.acknowledgementsListWidth)
            Hairline(.vertical)
            if let acknowledgement = Acknowledgement.all.first(where: { $0.id == selection }) {
                AcknowledgementDetail(acknowledgement: acknowledgement)
            } else {
                PlaceholderNote("Select a component to see its license")
            }
        }
        .frame(minWidth: Metrics.About.acknowledgementsWidth, minHeight: Metrics.About.acknowledgementsHeight)
        .background(Color(espalier: Palette.background))
        .lookFont()
        .onAppear {
            if selection == nil {
                selection = Acknowledgement.all.first?.id
            }
        }
    }
}
