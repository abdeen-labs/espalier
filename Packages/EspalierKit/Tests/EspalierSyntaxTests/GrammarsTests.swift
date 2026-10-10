// Which grammar a file uses. Every grammar's highlighting is checked in
// HighlightSampleTests.

import EspalierSyntax
import Testing

@Suite("Grammars")
struct GrammarsTests {
    @Test("files map to their grammar by name, then by extension")
    func paths() {
        #expect(Grammars.grammar(forPath: "Sources/App/Main.swift")?.id == "swift")
        #expect(Grammars.grammar(forPath: "web/App.TSX")?.id == "tsx")
        #expect(Grammars.grammar(forPath: "include/thing.h")?.id == "c")
        #expect(Grammars.grammar(forPath: "Gemfile")?.id == "ruby")
        #expect(Grammars.grammar(forPath: "app/Gemfile")?.id == "ruby")
        #expect(Grammars.grammar(forPath: ".github/workflows/ci.yml")?.id == "yaml")
        #expect(Grammars.grammar(forPath: "README") == nil)
        #expect(Grammars.grammar(forPath: ".gitignore") == nil)
        #expect(Grammars.grammar(forPath: "archive.tar.gz") == nil)
    }
}
