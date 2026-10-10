// Ported from the POSIX cases of node/test/parallel/test-path-join.js,
// test-path-resolve.js, test-path-normalize.js, test-path-dirname.js,
// test-path-basename.js, test-path-extname.js, test-path-relative.js, and
// test-path-isabsolute.js

import EspalierSupport
import Testing

/// Node's tests use `__filename`, the absolute path of the test file, in a
/// few cases. These stand-ins keep those cases without depending on where the
/// tests live.
private func filename(_ testFile: String) -> String {
    "/home/node/test/parallel/\(testFile)"
}

@Suite("POSIXPath")
struct POSIXPathTests {
    @Test("test-path-join.js")
    func join() {
        let joinTests: [(arguments: [String], result: String)] = [
            ([".", "x/b", "..", "/b/c.js"], "x/b/c.js"),
            ([], "."),
            (["/.", "x/b", "..", "/b/c.js"], "/x/b/c.js"),
            (["/foo", "../../../bar"], "/bar"),
            (["foo", "../../../bar"], "../../bar"),
            (["foo/", "../../../bar"], "../../bar"),
            (["foo/x", "../../../bar"], "../bar"),
            (["foo/x", "./bar"], "foo/x/bar"),
            (["foo/x/", "./bar"], "foo/x/bar"),
            (["foo/x/", ".", "bar"], "foo/x/bar"),
            (["./"], "./"),
            ([".", "./"], "./"),
            ([".", ".", "."], "."),
            ([".", "./", "."], "."),
            ([".", "/./", "."], "."),
            ([".", "/////./", "."], "."),
            (["."], "."),
            (["", "."], "."),
            (["", "foo"], "foo"),
            (["foo", "/bar"], "foo/bar"),
            (["", "/foo"], "/foo"),
            (["", "", "/foo"], "/foo"),
            (["", "", "foo"], "foo"),
            (["foo", ""], "foo"),
            (["foo/", ""], "foo/"),
            (["foo", "", "/bar"], "foo/bar"),
            (["./", "..", "/foo"], "../foo"),
            (["./", "..", "..", "/foo"], "../../foo"),
            ([".", "..", "..", "/foo"], "../../foo"),
            (["", "..", "..", "/foo"], "../../foo"),
            (["/"], "/"),
            (["/", "."], "/"),
            (["/", ".."], "/"),
            (["/", "..", ".."], "/"),
            ([""], "."),
            (["", ""], "."),
            ([" /foo"], " /foo"),
            ([" ", "foo"], " /foo"),
            ([" ", "."], " "),
            ([" ", "/"], " /"),
            ([" ", ""], " "),
            (["/", "foo"], "/foo"),
            (["/", "/foo"], "/foo"),
            (["/", "//foo"], "/foo"),
            (["/", "", "/foo"], "/foo"),
            (["", "/", "foo"], "/foo"),
            (["", "/", "/foo"], "/foo"),
        ]
        for (arguments, expected) in joinTests {
            #expect(POSIXPath.join(arguments) == expected, "path.posix.join(\(arguments))")
        }
        // The variadic form with no arguments at all.
        #expect(POSIXPath.join() == ".")
    }

    @Test("test-path-resolve.js")
    func resolve() {
        // These resolve against an explicit directory rather than the
        // current one.
        let posixyCwd = "/home/node/project"

        let resolveTests: [(arguments: [String], result: String)] = [
            (["/var/lib", "../", "file/"], "/var/file"),
            (["/var/lib", "/../", "file/"], "/file"),
            (["a/b/c/", "../../.."], posixyCwd),
            ([], posixyCwd),
            ([""], posixyCwd),
            (["."], posixyCwd),
            (["/some/dir", ".", "/absolute/"], "/absolute"),
            (["/foo/tmp.3/", "../tmp.3/cycles/root.js"], "/foo/tmp.3/cycles/root.js"),
        ]
        for (arguments, expected) in resolveTests {
            #expect(
                POSIXPath.resolve(arguments, currentDirectory: posixyCwd) == expected,
                "path.posix.resolve(\(arguments))"
            )
        }

        // Test handling relative paths to be safe when process.cwd() fails.
        #expect(POSIXPath.resolve([], currentDirectory: "") == ".")
    }

    @Test("test-path-normalize.js")
    func normalize() {
        #expect(POSIXPath.normalize("./fixtures///b/../b/c.js") == "fixtures/b/c.js")
        #expect(POSIXPath.normalize("/foo/../../../bar") == "/bar")
        #expect(POSIXPath.normalize("a//b//../b") == "a/b")
        #expect(POSIXPath.normalize("a//b//./c") == "a/b/c")
        #expect(POSIXPath.normalize("a//b//.") == "a/b")
        #expect(POSIXPath.normalize("/a/b/c/../../../x/y/z") == "/x/y/z")
        #expect(POSIXPath.normalize("///..//./foo/.//bar") == "/foo/bar")
        #expect(POSIXPath.normalize("bar/foo../../") == "bar/")
        #expect(POSIXPath.normalize("bar/foo../..") == "bar")
        #expect(POSIXPath.normalize("bar/foo../../baz") == "bar/baz")
        #expect(POSIXPath.normalize("bar/foo../") == "bar/foo../")
        #expect(POSIXPath.normalize("bar/foo..") == "bar/foo..")
        #expect(POSIXPath.normalize("../foo../../../bar") == "../../bar")
        #expect(POSIXPath.normalize("../.../.././.../../../bar") == "../../bar")
        #expect(POSIXPath.normalize("../../../foo/../../../bar") == "../../../../../bar")
        #expect(POSIXPath.normalize("../../../foo/../../../bar/../../") == "../../../../../../")
        #expect(POSIXPath.normalize("../foobar/barfoo/foo/../../../bar/../../") == "../../")
        #expect(POSIXPath.normalize("../.../../foobar/../../../bar/../../baz") == "../../../../baz")
        #expect(POSIXPath.normalize("foo/bar\\baz") == "foo/bar\\baz")
    }

    @Test("test-path-dirname.js")
    func dirname() {
        #expect(POSIXPath.dirname(filename("test-path-dirname.js")).suffix(13) == "test/parallel")

        #expect(POSIXPath.dirname("/a/b/") == "/a")
        #expect(POSIXPath.dirname("/a/b") == "/a")
        #expect(POSIXPath.dirname("/a") == "/")
        #expect(POSIXPath.dirname("") == ".")
        #expect(POSIXPath.dirname("/") == "/")
        #expect(POSIXPath.dirname("////") == "/")
        #expect(POSIXPath.dirname("//a") == "//")
        #expect(POSIXPath.dirname("foo") == ".")
    }

    @Test("test-path-basename.js")
    func basename() {
        #expect(POSIXPath.basename(filename("test-path-basename.js")) == "test-path-basename.js")
        #expect(POSIXPath.basename(filename("test-path-basename.js"), ".js") == "test-path-basename")
        #expect(POSIXPath.basename(".js", ".js") == "")
        #expect(POSIXPath.basename("js", ".js") == "js")
        #expect(POSIXPath.basename("file.js", ".ts") == "file.js")
        #expect(POSIXPath.basename("file", ".js") == "file")
        #expect(POSIXPath.basename("file.js.old", ".js.old") == "file")
        #expect(POSIXPath.basename("") == "")
        #expect(POSIXPath.basename("/dir/basename.ext") == "basename.ext")
        #expect(POSIXPath.basename("/basename.ext") == "basename.ext")
        #expect(POSIXPath.basename("basename.ext") == "basename.ext")
        #expect(POSIXPath.basename("basename.ext/") == "basename.ext")
        #expect(POSIXPath.basename("basename.ext//") == "basename.ext")
        #expect(POSIXPath.basename("aaa/bbb", "/bbb") == "bbb")
        #expect(POSIXPath.basename("aaa/bbb", "a/bbb") == "bbb")
        #expect(POSIXPath.basename("aaa/bbb", "bbb") == "bbb")
        #expect(POSIXPath.basename("aaa/bbb//", "bbb") == "bbb")
        #expect(POSIXPath.basename("aaa/bbb", "bb") == "b")
        #expect(POSIXPath.basename("aaa/bbb", "b") == "bb")
        #expect(POSIXPath.basename("/aaa/bbb", "/bbb") == "bbb")
        #expect(POSIXPath.basename("/aaa/bbb", "a/bbb") == "bbb")
        #expect(POSIXPath.basename("/aaa/bbb", "bbb") == "bbb")
        #expect(POSIXPath.basename("/aaa/bbb//", "bbb") == "bbb")
        #expect(POSIXPath.basename("/aaa/bbb", "bb") == "b")
        #expect(POSIXPath.basename("/aaa/bbb", "b") == "bb")
        #expect(POSIXPath.basename("/aaa/bbb") == "bbb")
        #expect(POSIXPath.basename("/aaa/") == "aaa")
        #expect(POSIXPath.basename("/aaa/b") == "b")
        #expect(POSIXPath.basename("/a/b") == "b")
        #expect(POSIXPath.basename("//a") == "a")
        #expect(POSIXPath.basename("a", "a") == "")

        // On unix a backslash is just treated as any other character.
        #expect(POSIXPath.basename("\\dir\\basename.ext") == "\\dir\\basename.ext")
        #expect(POSIXPath.basename("\\basename.ext") == "\\basename.ext")
        #expect(POSIXPath.basename("basename.ext\\") == "basename.ext\\")
        #expect(POSIXPath.basename("basename.ext\\\\") == "basename.ext\\\\")
        #expect(POSIXPath.basename("foo") == "foo")

        // POSIX filenames may include control characters
        // c.f. http://www.dwheeler.com/essays/fixing-unix-linux-filenames.html
        let controlCharFilename = "Icon\u{0D}"
        #expect(POSIXPath.basename("/a/b/\(controlCharFilename)") == controlCharFilename)
    }

    @Test("test-path-extname.js")
    func extname() {
        let testPaths: [(path: String, expected: String)] = [
            (filename("test-path-extname.js"), ".js"),
            ("", ""),
            ("/path/to/file", ""),
            ("/path/to/file.ext", ".ext"),
            ("/path.to/file.ext", ".ext"),
            ("/path.to/file", ""),
            ("/path.to/.file", ""),
            ("/path.to/.file.ext", ".ext"),
            ("/path/to/f.ext", ".ext"),
            ("/path/to/..ext", ".ext"),
            ("/path/to/..", ""),
            ("file", ""),
            ("file.ext", ".ext"),
            (".file", ""),
            (".file.ext", ".ext"),
            ("/file", ""),
            ("/file.ext", ".ext"),
            ("/.file", ""),
            ("/.file.ext", ".ext"),
            (".path/file.ext", ".ext"),
            ("file.ext.ext", ".ext"),
            ("file.", "."),
            (".", ""),
            ("./", ""),
            (".file.", "."),
            (".file..", "."),
            ("..", ""),
            ("../", ""),
            ("..file.ext", ".ext"),
            ("..file", ".file"),
            ("..file.", "."),
            ("..file..", "."),
            ("...", "."),
            ("...ext", ".ext"),
            ("....", "."),
            ("file.ext/", ".ext"),
            ("file.ext//", ".ext"),
            ("file/", ""),
            ("file//", ""),
            ("file./", "."),
            ("file.//", "."),
        ]
        for (path, expected) in testPaths {
            #expect(POSIXPath.extname(path) == expected, "path.posix.extname(\(path.debugDescription))")
        }

        // On *nix, backslash is a valid name component like any other character.
        #expect(POSIXPath.extname(".\\") == "")
        #expect(POSIXPath.extname("..\\") == ".\\")
        #expect(POSIXPath.extname("file.ext\\") == ".ext\\")
        #expect(POSIXPath.extname("file.ext\\\\") == ".ext\\\\")
        #expect(POSIXPath.extname("file\\") == "")
        #expect(POSIXPath.extname("file\\\\") == "")
        #expect(POSIXPath.extname("file.\\") == ".\\")
        #expect(POSIXPath.extname("file.\\\\") == ".\\\\")
    }

    @Test("test-path-relative.js")
    func relative() {
        let relativeTests: [(from: String, to: String, result: String)] = [
            ("/var/lib", "/var", ".."),
            ("/var/lib", "/bin", "../../bin"),
            ("/var/lib", "/var/lib", ""),
            ("/var/lib", "/var/apache", "../apache"),
            ("/var/", "/var/lib", "lib"),
            ("/", "/var/lib", "var/lib"),
            ("/foo/test", "/foo/test/bar/package.json", "bar/package.json"),
            ("/Users/a/web/b/test/mails", "/Users/a/web/b", "../.."),
            ("/foo/bar/baz-quux", "/foo/bar/baz", "../baz"),
            ("/foo/bar/baz", "/foo/bar/baz-quux", "../baz-quux"),
            ("/baz-quux", "/baz", "../baz"),
            ("/baz", "/baz-quux", "../baz-quux"),
            ("/page1/page2/foo", "/", "../../.."),
        ]
        for (from, to, expected) in relativeTests {
            #expect(POSIXPath.relative(from, to) == expected, "path.posix.relative(\(from.debugDescription), \(to.debugDescription))")
        }
    }

    @Test("test-path-isabsolute.js")
    func isAbsolute() {
        #expect(POSIXPath.isAbsolute("/home/foo") == true)
        #expect(POSIXPath.isAbsolute("/home/foo/..") == true)
        #expect(POSIXPath.isAbsolute("bar/") == false)
        #expect(POSIXPath.isAbsolute("./baz") == false)
    }
}

/// Cases Node's tests don't cover, where `POSIXPath` could diverge from
/// Node. The expected values are Node 24's.
@Suite("POSIXPath divergences from Node")
struct POSIXPathNodeDivergenceTests {
    @Test("resolve returns an absolute current directory as is when there is nothing to resolve")
    func resolveReturnsCurrentDirectoryAsIs() {
        let cwd = "/foo/../bar/"
        #expect(POSIXPath.resolve([], currentDirectory: cwd) == "/foo/../bar/")
        #expect(POSIXPath.resolve([""], currentDirectory: cwd) == "/foo/../bar/")
        #expect(POSIXPath.resolve(["."], currentDirectory: cwd) == "/foo/../bar/")
        #expect(POSIXPath.resolve(["a"], currentDirectory: cwd) == "/bar/a")
        #expect(POSIXPath.resolve([".", "."], currentDirectory: cwd) == "/bar")
        #expect(POSIXPath.resolve(["./"], currentDirectory: cwd) == "/bar")
        #expect(POSIXPath.resolve([], currentDirectory: "relative/dir") == "relative/dir")
        #expect(POSIXPath.resolve(["."], currentDirectory: "relative/dir") == "relative/dir")
    }

    @Test("relative compares code units, not canonically equivalent strings")
    func relativeComparesCodeUnits() {
        // Precomposed and decomposed "é" are different paths to Node.
        let relative = POSIXPath.relative("/a/\u{E9}", "/a/e\u{301}")
        #expect(Array(relative.utf8) == Array("../e\u{301}".utf8))
    }

    @Test("basename measures the suffix in UTF-16 code units")
    func basenameMeasuresSuffixInUTF16() {
        // The suffix is longer than the path in UTF-16 code units, so Node
        // ignores it, but not in UTF-8 bytes.
        #expect(POSIXPath.basename("\u{E9}\u{E9}\u{E9}/b/", "abcdefgb") == "b")
        // A suffix that is no longer than the path, which the last component
        // only partly matches, keeps trailing separators in Node.
        #expect(POSIXPath.basename("b/", "ab") == "b/")
    }
}
