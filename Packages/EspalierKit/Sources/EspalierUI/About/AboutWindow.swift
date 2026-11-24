// About Espalier, a window of its own: the mark over its trellis band, the
// name as the brand sets it, the version and build, the line about GitHub
// Desktop, and Acknowledgements…, which opens the Acknowledgements window.

import AppKit
import SwiftUI

/// What the About window shows.
nonisolated struct AboutContent: Sendable, Equatable {
    var version: String
    var build: String

    /// "Version 1.0 (1)".
    var versionLine: String {
        "Version \(version) (\(build))"
    }

    /// The running app's version and build.
    static func current(_ bundle: Bundle = .main) -> AboutContent {
        let info = bundle.infoDictionary
        return AboutContent(
            version: info?["CFBundleShortVersionString"] as? String ?? "1.0",
            build: info?["CFBundleVersion"] as? String ?? "1"
        )
    }
}

/// The About window's layout.
struct AboutView: View {
    let content: AboutContent
    var showAcknowledgements: @MainActor () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            BrandHero(markSize: Metrics.About.iconSize, bandHeight: Metrics.About.bandHeight)
            VStack(spacing: Metrics.insetSmall) {
                Wordmark(size: Metrics.About.nameSize)
                MonoChip(content.versionLine, isSelectable: true)
                Text("A native Mac Git client, originally rooted in GitHub Desktop.")
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Metrics.grid)
                Button("Acknowledgements…", action: showAcknowledgements)
                    .buttonStyle(.quiet)
                    .padding(.top, Metrics.insetSmall)
            }
            .padding(.horizontal, Metrics.insetLarge * 2)
            .padding(.top, Metrics.insetMedium)
            .padding(.bottom, Metrics.insetLarge * 2)
        }
        .frame(width: Metrics.About.width)
        .background(Color(espalier: Palette.background))
    }
}

/// The About window's content.
public struct AboutWindow: View {
    private let content: AboutContent
    @Environment(\.openWindow) private var openWindow

    public init() {
        content = .current()
    }

    public var body: some View {
        AboutView(content: content) {
            openWindow(id: EspalierScenes.acknowledgementsWindowID)
        }
        .lookFont()
    }
}
