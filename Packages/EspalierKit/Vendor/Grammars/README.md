# Vendored tree-sitter grammars

These five grammars are copied from their releases because their SwiftPM
manifests leave out the external scanner: they add `src/scanner.c` only when
`FileManager.default.fileExists(atPath: "src/scanner.c")`, a relative path
SwiftPM doesn't evaluate from the package's directory, so linking fails. Each
folder holds the release's parser, scanner, headers, highlight queries, and
license (all MIT), unmodified. `Package.swift` builds them as targets with the
scanner listed.

| Module | Source | Release |
|---|---|---|
| TreeSitterCSS | tree-sitter/tree-sitter-css | v0.25.0 (`dda5cfc`) |
| TreeSitterJavaScript | tree-sitter/tree-sitter-javascript | v0.25.0 (`44c892e`) |
| TreeSitterLua | tree-sitter-grammars/tree-sitter-lua | v0.5.0 (`10fe005`) |
| TreeSitterPython | tree-sitter/tree-sitter-python | v0.25.0 (`293fdc0`) |
| TreeSitterYAML | tree-sitter-grammars/tree-sitter-yaml | v0.7.2 (`7708026`) |

The other grammars are SwiftPM dependencies in `Package.swift`. Replace a
folder here with a dependency once a release's manifest lists its scanner.
YAML's scanner includes `src/schema.core.c` itself, so the schema files are
excluded from the build but must stay.
