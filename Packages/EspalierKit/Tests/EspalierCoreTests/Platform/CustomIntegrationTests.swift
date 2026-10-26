@testable import EspalierCore
import Foundation
import Testing
import TestSupport

@Suite("Custom integrations")
struct CustomIntegrationTests {
    @Suite("expandTargetPathArgument")
    struct Expansion {
        @Test("replaces the placeholder wherever it appears")
        func replaces() {
            #expect(expandTargetPathArgument(["%TARGET_PATH%"], "/repo") == ["/repo"])
            #expect(expandTargetPathArgument(["-n", "%TARGET_PATH%", "--wait"], "/repo") == ["-n", "/repo", "--wait"])
            #expect(expandTargetPathArgument(["--folder-uri=%TARGET_PATH%"], "/repo") == ["--folder-uri=/repo"])
            #expect(expandTargetPathArgument(["%TARGET_PATH%:%TARGET_PATH%"], "/r") == ["/r:/r"])
            #expect(expandTargetPathArgument(["--other"], "/repo") == ["--other"])
        }

        @Test("strips quotes only around a whole placeholder")
        func quotes() {
            #expect(expandTargetPathArgument(["'%TARGET_PATH%'", "\"%TARGET_PATH%\""], "/a b") == ["/a b", "/a b"])
            #expect(expandTargetPathArgument(["--path='%TARGET_PATH%'"], "/a b") == ["--path='/a b'"])
            #expect(expandTargetPathArgument(["'%TARGET_PATH%\""], "/r") == ["'/r\""])
        }

        @Test("inserts the path literally")
        func literalPath() {
            // JavaScript's replaceAll would read these as replacement patterns:
            // "$$" as "$", "$&" as the placeholder, "$`" and "$'" as the text
            // around it.
            let paths = ["/Users/me/$$cash", "/Users/me/a$&b", "/Users/me/a$'b", "/Users/me/a$`b", "/Users/me/$1"]
            for path in paths {
                #expect(expandTargetPathArgument(["%TARGET_PATH%", "--x=%TARGET_PATH%"], path) == [path, "--x=\(path)"])
            }
        }

        @Test("compares code units")
        func codeUnits() {
            // A combining mark after the placeholder doesn't hide it, as it
            // would from Swift's character-based search.
            #expect(expandTargetPathArgument(["%TARGET_PATH%\u{301}"], "/r") == ["/r\u{301}"])
        }
    }

    @Test("checks for the placeholder")
    func checkPlaceholder() {
        #expect(checkTargetPathArgument(["--wait", "%TARGET_PATH%"]))
        #expect(checkTargetPathArgument(["--folder-uri=%TARGET_PATH%"]))
        #expect(!checkTargetPathArgument(["--wait", "TARGET_PATH"]))
        #expect(!checkTargetPathArgument([]))
    }

    @Suite("validateCustomIntegrationPath")
    struct PathValidation {
        @Test("accepts executable files and applications with a bundle ID")
        func valid() async throws {
            let directory = try createTempDirectory()
            try makeFile("\(directory)/tool", permissions: 0o755)
            let app = try makeFakeApplication(in: directory, named: "Editor.app", bundleIdentifier: "com.example.editor")

            #expect(await validateCustomIntegrationPath("\(directory)/tool") == CustomIntegrationPathValidation(isValid: true))
            #expect(await validateCustomIntegrationPath(app) == CustomIntegrationPathValidation(isValid: true, bundleID: "com.example.editor"))
        }

        @Test("rejects everything else")
        func invalid() async throws {
            let directory = try createTempDirectory()
            try makeFile("\(directory)/notes.txt", permissions: 0o644)
            try FileManager.default.createDirectory(atPath: "\(directory)/Folder", withIntermediateDirectories: true)
            try makeFakeApplication(in: directory, named: "NoPlist.app")
            try makeFakeApplication(in: directory, named: "NotAnApp", bundleIdentifier: "com.example.notanapp")
            try makeFakeApplication(in: directory, named: "Blank.app", bundleIdentifier: "  ")

            let invalid = CustomIntegrationPathValidation(isValid: false)
            #expect(await validateCustomIntegrationPath("") == invalid)
            #expect(await validateCustomIntegrationPath("\(directory)/missing") == invalid)
            #expect(await validateCustomIntegrationPath("\(directory)/notes.txt") == invalid)
            #expect(await validateCustomIntegrationPath("\(directory)/Folder") == invalid)
            #expect(await validateCustomIntegrationPath("\(directory)/NoPlist.app") == invalid)
            #expect(await validateCustomIntegrationPath("\(directory)/NotAnApp") == invalid)
            #expect(await validateCustomIntegrationPath("\(directory)/Blank.app") == invalid)
        }

        @Test("judges a symbolic link by what it points to")
        func symbolicLinks() async throws {
            let directory = try createTempDirectory()
            try makeFile("\(directory)/tool", permissions: 0o755)
            let app = try makeFakeApplication(in: directory, named: "Editor.app", bundleIdentifier: "com.example.editor")
            try FileManager.default.createDirectory(atPath: "\(directory)/Folder", withIntermediateDirectories: true)
            let links = [
                "tool-link": "\(directory)/tool",
                "Linked.app": app,
                "folder-link": "\(directory)/Folder",
                "dangling": "\(directory)/missing",
            ]
            for (name, destination) in links {
                try FileManager.default.createSymbolicLink(atPath: "\(directory)/\(name)", withDestinationPath: destination)
            }

            #expect(await validateCustomIntegrationPath("\(directory)/tool-link") == CustomIntegrationPathValidation(isValid: true))
            // Neither is an executable file: both would fail to launch.
            #expect(await validateCustomIntegrationPath("\(directory)/Linked.app") == CustomIntegrationPathValidation(isValid: true, bundleID: "com.example.editor"))
            #expect(await validateCustomIntegrationPath("\(directory)/folder-link") == CustomIntegrationPathValidation(isValid: false))
            #expect(await validateCustomIntegrationPath("\(directory)/dangling") == CustomIntegrationPathValidation(isValid: false))
        }
    }

    @Test("isValidCustomIntegration needs a valid path and the placeholder")
    func validity() async throws {
        let directory = try createTempDirectory()
        try makeFile("\(directory)/tool", permissions: 0o755)

        #expect(await isValidCustomIntegration(CustomIntegration(path: "\(directory)/tool", arguments: "--wait %TARGET_PATH%")))
        #expect(await isValidCustomIntegration(CustomIntegration(path: "\(directory)/tool", arguments: "'%TARGET_PATH%'")))
        #expect(await !isValidCustomIntegration(CustomIntegration(path: "\(directory)/tool", arguments: "--wait")))
        #expect(await !isValidCustomIntegration(CustomIntegration(path: "\(directory)/missing", arguments: "%TARGET_PATH%")))
    }

    @Suite("Stored format")
    struct StoredFormat {
        @Test("decodes the stored format")
        func decoding() throws {
            let stored = #"{"path":"/usr/local/bin/tool","arguments":"--title='a b' %TARGET_PATH%"}"#
            #expect(
                try JSONDecoder().decode(CustomIntegration.self, from: Data(stored.utf8))
                    == CustomIntegration(path: "/usr/local/bin/tool", arguments: "--title='a b' %TARGET_PATH%")
            )

            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(CustomIntegration.self, from: Data(#"{"arguments":"%TARGET_PATH%"}"#.utf8))
            }
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(CustomIntegration.self, from: Data(#"{"path":"/x","arguments":5}"#.utf8))
            }
        }
    }
}
