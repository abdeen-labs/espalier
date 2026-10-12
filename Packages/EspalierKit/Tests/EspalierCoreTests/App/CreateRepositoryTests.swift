// Creating writes a repository, so it's checked end to end against real
// folders: the files and the initial commit, the folder checks (with or
// without a trailing slash), the failures that stop and the ones that
// don't, and the license's tokens.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Create repository", .offline) @MainActor
struct CreateRepositoryTests {
    // MARK: Creating

    @Test("creates the folder, adds and selects it, writes the chosen files, and commits them all as Initial commit")
    func createsRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let request = CreateRepositoryRequest(
                name: "espalier",
                description: "A Git client",
                basePath: base,
                createsReadme: true,
                gitIgnore: "Swift",
                license: "MIT License"
            )
            let path = POSIXPath.join(base, "espalier")

            let result = try await app.createRepository(request)

            #expect(result.failures.isEmpty)
            let record = try #require(app.record(result.repositoryID))
            #expect(record.path == path)
            #expect(app.selection == .repository(result.repositoryID))
            #expect(app.preferences.lastCloneLocation == base)

            #expect(try read(path, "README.md") == "# espalier\nA Git client\n")
            #expect(try read(path, ".gitignore") == RepositoryTemplates.gitIgnoreText(named: "Swift"))
            #expect(try read(path, ".gitattributes") == "# Auto detect text files and perform LF normalization\n* text=auto\n")
            #expect(try read(path, ".git/description") == "A Git client")
            let year = String(Calendar(identifier: .gregorian).component(.year, from: harness.scheduler.now))
            let license = try read(path, "LICENSE")
            #expect(license.contains("Copyright (c) \(year) \(TestEnvironment.authorName)"))
            #expect(!license.contains("[year]") && !license.contains("[fullname]"))

            let repository = Repository(path: path)
            #expect(try await runGit(["log", "--format=%s"], repository) == "Initial commit\n")
            #expect(try await runGit(["symbolic-ref", "--short", "HEAD"], repository) == "main\n")
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], repository) == ".gitattributes\n.gitignore\nLICENSE\nREADME.md\n")
            #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)

            // The model shows the commit once it returns.
            let model = try #require(app.repository(result.repositoryID))
            #expect(model.gitState.tip.branch?.name == "main")
            #expect(model.changes.workingDirectory.files.isEmpty)
            await app.idle()
        }
    }

    @Test("with nothing chosen, the folder still gets a .gitattributes, which is the initial commit; the README has no blank line")
    func createsMinimalRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let result = try await app.createRepository(CreateRepositoryRequest(name: "plain", basePath: base))
            let path = POSIXPath.join(base, "plain")
            #expect(result.failures.isEmpty)
            let repository = Repository(path: path)
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], repository) == ".gitattributes\n")
            // No description was given: the one the bundled git's templates
            // wrote stays.
            #expect(try read(path, ".git/description").hasPrefix("Unnamed repository"))

            let readme = try await app.createRepository(CreateRepositoryRequest(name: "with-readme", basePath: base, createsReadme: true))
            #expect(readme.failures.isEmpty)
            #expect(try read(POSIXPath.join(base, "with-readme"), "README.md") == "# with-readme\n")
            await app.idle()
        }
    }

    @Test("in a folder with files, keeps its .gitattributes and commits everything in it")
    func createsInFolderWithFiles() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let path = POSIXPath.join(base, "existing")
            try FileManager.default.createDirectory(atPath: POSIXPath.join(path, "Sources"), withIntermediateDirectories: true)
            try write("let x = 1\n", to: POSIXPath.join(path, "Sources", "main.swift"))
            try write("*.png binary\n", to: POSIXPath.join(path, ".gitattributes"))

            let result = try await app.createRepository(CreateRepositoryRequest(name: "existing", basePath: base))

            #expect(result.failures.isEmpty)
            #expect(try read(path, ".gitattributes") == "*.png binary\n")
            let repository = Repository(path: path)
            #expect(try await runGit(["ls-tree", "-r", "--name-only", "HEAD"], repository) == ".gitattributes\nSources/main.swift\n")
            await app.idle()
        }
    }

    @Test("a name with folders makes them, and a non-ASCII name keeps its form")
    func createsNestedAndUnicodeFolders() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()

            let nested = try await app.createRepository(CreateRepositoryRequest(name: "octo-org/website", basePath: base))
            #expect(app.record(nested.repositoryID)?.path == POSIXPath.join(base, "octo-org", "website"))

            let name = "caf\u{E9}"
            let unicode = try await app.createRepository(CreateRepositoryRequest(name: name, basePath: base, createsReadme: true))
            #expect(app.record(unicode.repositoryID)?.path == POSIXPath.join(base, name))
            // The folder's name on disk is the composed form typed.
            #expect(rawNames(in: base).contains { $0.unicodeScalars.elementsEqual(name.unicodeScalars) })
            #expect(try read(POSIXPath.join(base, name), "README.md") == "# \(name)\n")
            await app.idle()
        }
    }

    @Test("a subfolder of a repository becomes a repository of its own")
    func createsInSubfolderOfRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let outer = try await setupTwoCommitRepo()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let destination = await checkCreateRepositoryDestination(POSIXPath.join(outer.path, "inner"))
            #expect(destination == CreateRepositoryDestination(isRepository: false, isSubfolderOfRepository: false, readmeExists: false))
            try FileManager.default.createDirectory(atPath: POSIXPath.join(outer.path, "inner"), withIntermediateDirectories: true)
            #expect(await checkCreateRepositoryDestination(POSIXPath.join(outer.path, "inner")).isSubfolderOfRepository)

            let result = try await app.createRepository(CreateRepositoryRequest(name: "inner", basePath: outer.path))
            #expect(result.failures.isEmpty)
            let inner = Repository(path: POSIXPath.join(outer.path, "inner"))
            #expect(try await runGit(["log", "--format=%s"], inner) == "Initial commit\n")
            // The outer repository's history is untouched.
            #expect(try await runGit(["rev-list", "--count", "HEAD"], outer) == "2\n")
            await app.idle()
        }
    }

    @Test("refuses a folder that is a repository already, with or without a trailing slash, and leaves it alone")
    func refusesExistingRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let existing = try await setupTwoCommitRepo()
            try write("work in progress\n", to: POSIXPath.join(existing.path, "notes.txt"))
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = POSIXPath.dirname(existing.path)
            let name = POSIXPath.basename(existing.path)

            for typed in [name, "\(name)/"] {
                #expect(await checkCreateRepositoryDestination(POSIXPath.join(base, typed)).isRepository)
                await #expect(throws: OperationError.self) {
                    try await app.createRepository(CreateRepositoryRequest(name: typed, basePath: base, createsReadme: true))
                }
            }
            #expect(try await runGit(["rev-list", "--count", "HEAD"], existing) == "2\n")
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(existing.path, "README.md")))
            #expect(app.repositories.isEmpty)
            await app.idle()
        }
    }

    @Test("without a name or a folder there's nothing to create")
    func requiresNameAndFolder() async throws {
        #expect(CreateRepositoryRequest(name: "  ", basePath: "/tmp").fullPath == nil)
        #expect(CreateRepositoryRequest(name: "app", basePath: "").fullPath == nil)
        #expect(CreateRepositoryRequest(name: " app ", basePath: "/Users/joe").fullPath == "/Users/joe/ app ")
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        await #expect(throws: OperationError.self) {
            try await app.createRepository(CreateRepositoryRequest(name: "", basePath: "/tmp"))
        }
        // A relative folder would resolve against Espalier's own.
        await #expect(throws: OperationError.self) {
            try await app.createRepository(CreateRepositoryRequest(name: "app", basePath: "Developer"))
        }
        #expect(!FileManager.default.fileExists(atPath: "Developer/app"))
    }

    @Test("a folder that can't be made fails and adds nothing")
    func folderCantBeMade() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            #expect(chmod(base, 0o555) == 0)
            defer { chmod(base, 0o755) }

            await #expect(throws: OperationError.self) {
                try await app.createRepository(CreateRepositoryRequest(name: "locked", basePath: base))
            }
            #expect(app.repositories.isEmpty)
        }
    }

    @Test("a step that fails is reported, and the others and the commit go on")
    func failingStepContinues() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let path = POSIXPath.join(base, "blocked")
            // A folder where the README goes: writing it fails.
            try FileManager.default.createDirectory(atPath: POSIXPath.join(path, "README.md"), withIntermediateDirectories: true)

            let result = try await app.createRepository(CreateRepositoryRequest(
                name: "blocked", basePath: base, createsReadme: true, license: "MIT License"
            ))

            #expect(result.failures.count == 1)
            let repository = Repository(path: path)
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], repository) == ".gitattributes\nLICENSE\n")
            await app.idle()
        }
    }

    @Test("a template that doesn't exist fails its step only")
    func unknownTemplates() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let result = try await app.createRepository(CreateRepositoryRequest(
                name: "unknown", basePath: base, gitIgnore: "NoSuchLanguage", license: "No Such License"
            ))
            #expect(result.failures.count == 2)
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], Repository(path: POSIXPath.join(base, "unknown"))) == ".gitattributes\n")
            await app.idle()
        }
    }

    @Test("opened for a folder, the folder it's in isn't remembered for next time")
    func doesntRememberPrefilledFolder() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let before = app.preferences.lastCloneLocation
            let base = try createTempDirectory()
            _ = try await app.createRepository(CreateRepositoryRequest(name: "prefilled", basePath: base, remembersBasePath: false))
            #expect(app.preferences.lastCloneLocation == before)
            await app.idle()
        }
    }

    // MARK: The folder checks

    @Test("the folder checks: nothing there, a README, a bare repository")
    func destinationChecks() async throws {
        let base = try createTempDirectory()
        #expect(await checkCreateRepositoryDestination(POSIXPath.join(base, "new")) == CreateRepositoryDestination())

        let withReadme = POSIXPath.join(base, "with-readme")
        try FileManager.default.createDirectory(atPath: withReadme, withIntermediateDirectories: true)
        try write("# Hello\n", to: POSIXPath.join(withReadme, "README.md"))
        #expect(await checkCreateRepositoryDestination(withReadme) == CreateRepositoryDestination(readmeExists: true))

        let bare = POSIXPath.join(base, "bare.git")
        _ = try await Dugite.exec(["init", "--bare", bare], base)
        #expect(await checkCreateRepositoryDestination(bare).isRepository)
    }

    // MARK: Licenses and templates

    @Test("fills both kinds of token with the author, the project, and the year, and inserts values as they are")
    func licenseTokens() {
        let license = RepositoryLicense(
            name: "Test",
            isFeatured: false,
            body: "Copyright (c) [year] [fullname] <{email}>\n{project}: [description]\n[year]\n"
        )
        let fields = LicenseFields(fullname: "Jo $& Bloggs", email: "jo@example.com", project: "app", description: "", year: "2026")
        #expect(licenseText(license, fields) == "Copyright (c) 2026 Jo $& Bloggs <jo@example.com>\napp: \n2026\n")
    }

    // MARK: Helpers

    private func read(_ folder: String, _ file: String) throws -> String {
        try String(contentsOfFile: POSIXPath.join(folder, file), encoding: .utf8)
    }

    private func write(_ text: String, to path: String) throws {
        try (Data(text.utf8) as NSData).write(toFile: path, options: [])
    }

    /// The names in a folder as the file system stores their bytes
    /// (FileManager may change their normalization).
    private func rawNames(in folder: String) -> [String] {
        guard let directory = opendir(folder) else {
            return []
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            names.append(name)
        }
        return names
    }
}
