// swift-tools-version: 6.4

import PackageDescription

/// Settings shared by every target.
let common: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

/// The app-facing layers opt into approachable concurrency: nonisolated async
/// functions run on the caller's actor unless marked `@concurrent`.
///
/// The library layers (EspalierSupport, GitKit, GitHubKit, AIKit) deliberately
/// keep the classic semantics, so their nonisolated async functions always run
/// off the main actor. They spawn processes and parse large outputs, and that
/// work must never land on the main thread just because a main-actor model
/// awaited it.
let approachable: [SwiftSetting] = common + [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

/// Grammars for syntax color in diffs, as SwiftPM packages:
/// (repository, release, product).
/// CSS, JavaScript, Lua, Python, and YAML are vendored instead
/// (Vendor/Grammars/README.md).
let grammarPackages: [(url: String, version: Version, product: String)] = [
    ("https://github.com/tree-sitter/tree-sitter-bash", "0.25.1", "TreeSitterBash"),
    ("https://github.com/tree-sitter/tree-sitter-c", "0.24.2", "TreeSitterC"),
    ("https://github.com/tree-sitter/tree-sitter-cpp", "0.23.4", "TreeSitterCPP"),
    ("https://github.com/tree-sitter/tree-sitter-c-sharp", "0.23.5", "TreeSitterCSharp"),
    ("https://github.com/tree-sitter/tree-sitter-go", "0.25.0", "TreeSitterGo"),
    ("https://github.com/tree-sitter/tree-sitter-html", "0.23.2", "TreeSitterHTML"),
    ("https://github.com/tree-sitter/tree-sitter-java", "0.23.5", "TreeSitterJava"),
    ("https://github.com/tree-sitter/tree-sitter-json", "0.24.8", "TreeSitterJSON"),
    ("https://github.com/fwcd/tree-sitter-kotlin", "0.3.8", "TreeSitterKotlin"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-markdown", "0.5.3", "TreeSitterMarkdown"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-objc", "3.0.2", "TreeSitterObjc"),
    ("https://github.com/tree-sitter/tree-sitter-php", "0.25.1", "TreeSitterPHP"),
    ("https://github.com/tree-sitter/tree-sitter-ruby", "0.23.1", "TreeSitterRuby"),
    ("https://github.com/tree-sitter/tree-sitter-rust", "0.24.2", "TreeSitterRust"),
    ("https://github.com/alex-pinkus/tree-sitter-swift", "0.7.4-with-generated-files", "TreeSitterSwift"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-toml", "0.7.0", "TreeSitterTOML"),
    ("https://github.com/tree-sitter/tree-sitter-typescript", "0.23.2", "TreeSitterTypeScript"),
]

/// The vendored grammars (Vendor/Grammars), whose release manifests leave
/// out their scanners.
let vendoredGrammars = ["TreeSitterCSS", "TreeSitterJavaScript", "TreeSitterLua", "TreeSitterPython", "TreeSitterYAML"]

/// A vendored grammar: the release's parser and scanner, its queries as
/// resources, its Swift binding header. Warnings are off for its C, as
/// SwiftPM turns them off for packages it fetches: the code is upstream's,
/// unmodified.
func vendoredGrammar(_ name: String, exclude: [String] = []) -> Target {
    .target(
        name: name,
        path: "Vendor/Grammars/\(name)",
        exclude: ["LICENSE"] + exclude,
        sources: ["src/parser.c", "src/scanner.c"],
        resources: [.copy("queries")],
        publicHeadersPath: "bindings/swift",
        cSettings: [.headerSearchPath("src"), .unsafeFlags(["-w"])]
    )
}

let package = Package(
    name: "EspalierKit",
    platforms: [.macOS(.v27)],
    products: [
        .library(
            name: "EspalierKit",
            targets: [
                "EspalierSupport",
                "GitKit",
                "GitHubKit",
                "AIKit",
                "EspalierCore",
                "EspalierUI",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        // The C library SwiftTreeSitter wraps; EspalierSyntax imports it directly.
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
    ] + grammarPackages.map { .package(url: $0.url, exact: $0.version) },
    targets: [
        // Shared, dependency-free utilities: Keychain, logging, file helpers.
        .target(
            name: "EspalierSupport",
            swiftSettings: common
        ),

        // Git: process runner over the bundled git, one file per git command,
        // parsers, error mapping, progress, hooks environment.
        .target(
            name: "GitKit",
            dependencies: ["EspalierSupport"],
            swiftSettings: common
        ),

        // GitHub REST/GraphQL client, OAuth device flow, accounts.
        .target(
            name: "GitHubKit",
            dependencies: ["EspalierSupport"],
            swiftSettings: common
        ),

        // Bring-your-own-key AI providers, commit message and conflict prompts.
        .target(
            name: "AIKit",
            dependencies: ["EspalierSupport"],
            swiftSettings: common
        ),

        // @Observable app and repository models, watcher, background fetch,
        // persistence, askpass server.
        .target(
            name: "EspalierCore",
            dependencies: ["EspalierSupport", "GitKit", "GitHubKit", "AIKit"],
            swiftSettings: approachable
        ),

        // The helper git runs for askpass, credentials, and hooks. Its source
        // is the Xcode target's folder (Sources/espalier-askpass is a symlink
        // to ../../../espalier-askpass), built here under another name so
        // tests can drive the real helper end to end. Foundation only.
        .executableTarget(
            name: "EspalierAskpassHelper",
            path: "Sources/espalier-askpass",
            swiftSettings: common
        ),

        // Syntax color: tree-sitter, the grammars, and the language for a
        // file. Classic concurrency, so parsing stays off the main actor.
        .target(
            name: "EspalierSyntax",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitter", package: "tree-sitter"),
            ]
                + grammarPackages.map { .product(name: $0.product, package: String($0.url.split(separator: "/").last!)) }
                + vendoredGrammars.map { .target(name: $0) },
            swiftSettings: common
        ),
        vendoredGrammar("TreeSitterCSS"),
        vendoredGrammar("TreeSitterJavaScript"),
        vendoredGrammar("TreeSitterLua"),
        vendoredGrammar("TreeSitterPython"),
        vendoredGrammar("TreeSitterYAML", exclude: ["src/schema.core.c", "src/schema.json.c", "src/schema.legacy.c"]),

        // SwiftUI and AppKit views. The text fonts' files are copied as they
        // are, each family with its license (Resources/Fonts/SOURCES.md).
        .target(
            name: "EspalierUI",
            dependencies: ["EspalierSupport", "GitKit", "GitHubKit", "AIKit", "EspalierCore", "EspalierSyntax"],
            resources: [.copy("Resources/Fonts")],
            swiftSettings: approachable + [.defaultIsolation(MainActor.self)]
        ),

        // Test-only helpers and desktop's fixture repositories, shared by every
        // test target. Not part of any product.
        .target(
            name: "TestSupport",
            dependencies: ["EspalierSupport", "GitKit", "GitHubKit"],
            path: "Tests/TestSupport",
            resources: [.copy("Resources/fixtures")],
            swiftSettings: common
        ),

        // Test-only helpers for EspalierCore's models:
        // test doubles for the app environment's seams and model fixtures,
        // shared by EspalierCore's and EspalierUI's tests.
        .target(
            name: "EspalierCoreTestSupport",
            dependencies: ["EspalierCore", "EspalierSupport", "GitKit", "GitHubKit", "AIKit", "TestSupport"],
            path: "Tests/EspalierCoreTestSupport",
            swiftSettings: approachable
        ),

        .testTarget(
            name: "EspalierSupportTests",
            dependencies: ["EspalierSupport", "TestSupport"],
            swiftSettings: common
        ),
        .testTarget(
            name: "GitKitTests",
            dependencies: ["GitKit", "TestSupport"],
            swiftSettings: common
        ),
        .testTarget(
            name: "GitHubKitTests",
            dependencies: ["GitHubKit", "TestSupport"],
            swiftSettings: common
        ),
        .testTarget(
            name: "AIKitTests",
            dependencies: ["AIKit", "TestSupport"],
            swiftSettings: common
        ),
        .testTarget(
            name: "EspalierCoreTests",
            dependencies: ["EspalierCore", "GitKit", "GitHubKit", "TestSupport", "EspalierCoreTestSupport", "EspalierAskpassHelper"],
            swiftSettings: approachable
        ),
        .testTarget(
            name: "EspalierSyntaxTests",
            dependencies: ["EspalierSyntax"],
            swiftSettings: common
        ),
        .testTarget(
            name: "EspalierUITests",
            dependencies: ["EspalierUI", "EspalierCore", "TestSupport", "EspalierCoreTestSupport"],
            swiftSettings: approachable
        ),
        // Captures: views drawn to PNGs to look at, never compared. They run
        // only when ESPALIER_CAPTURES names a folder (scripts/capture.sh).
        .testTarget(
            name: "EspalierCaptures",
            dependencies: ["EspalierUI", "EspalierCore", "GitKit", "GitHubKit", "TestSupport", "EspalierCoreTestSupport"],
            swiftSettings: approachable
        ),
    ]
)
