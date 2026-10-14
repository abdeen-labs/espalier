// Creating writes a repository, so it's checked end to end against real
// folders: the files and the initial commit, which leaves the folder's own
// files alone, the folder checks (with or without a trailing slash), the
// failures that stop and the ones that don't, and the license's tokens.

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

    @Test("creates the folder, adds and selects it, writes the chosen files, and commits them as Initial commit")
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
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(path, ".gitattributes")))
            #expect(try read(path, ".git/description") == "A Git client")
            let year = String(Calendar(identifier: .gregorian).component(.year, from: harness.scheduler.now))
            let license = try read(path, "LICENSE")
            #expect(license.contains("Copyright (c) \(year) \(TestEnvironment.authorName)"))
            #expect(!license.contains("[year]") && !license.contains("[fullname]"))

            let repository = Repository(path: path)
            #expect(try await runGit(["log", "--format=%s"], repository) == "Initial commit\n")
            #expect(try await runGit(["symbolic-ref", "--short", "HEAD"], repository) == "main\n")
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], repository) == ".gitignore\nLICENSE\nREADME.md\n")
            #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)

            // The model shows the commit once it returns.
            let model = try #require(app.repository(result.repositoryID))
            #expect(model.gitState.tip.branch?.name == "main")
            #expect(model.changes.workingDirectory.files.isEmpty)
            await app.idle()
        }
    }

    @Test("with nothing chosen, nothing is written or committed; the README has no blank line")
    func createsMinimalRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let result = try await app.createRepository(CreateRepositoryRequest(name: "plain", basePath: base))
            let path = POSIXPath.join(base, "plain")
            #expect(result.failures.isEmpty)
            let repository = Repository(path: path)
            #expect(try await isUnborn(repository))
            #expect(try FileManager.default.contentsOfDirectory(atPath: path) == [".git"])
            // No description was given: the one the bundled git's templates
            // wrote stays.
            #expect(try read(path, ".git/description").hasPrefix("Unnamed repository"))

            let readme = try await app.createRepository(CreateRepositoryRequest(name: "with-readme", basePath: base, createsReadme: true))
            #expect(readme.failures.isEmpty)
            #expect(try read(POSIXPath.join(base, "with-readme"), "README.md") == "# with-readme\n")
            await app.idle()
        }
    }

    @Test("in a folder with files and nothing chosen, makes no commit and leaves every file as it was, in Changes")
    func createsInFolderWithFiles() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let path = POSIXPath.join(base, "existing")
            try FileManager.default.createDirectory(atPath: POSIXPath.join(path, "Sources"), withIntermediateDirectories: true)
            try write("let x = 1\r\n", to: POSIXPath.join(path, "Sources", "main.swift"))
            try write("*.png binary\n", to: POSIXPath.join(path, ".gitattributes"))
            try write("token\n", to: POSIXPath.join(path, "secrets.txt"))

            let result = try await app.createRepository(CreateRepositoryRequest(name: "existing", basePath: base))

            #expect(result.failures.isEmpty)
            let repository = Repository(path: path)
            #expect(try await isUnborn(repository))
            #expect(try read(path, ".gitattributes") == "*.png binary\n")
            #expect(try read(path, "Sources/main.swift") == "let x = 1\r\n")
            #expect(try await untrackedPaths(repository) == [".gitattributes", "Sources/main.swift", "secrets.txt"])
            let model = try #require(app.repository(result.repositoryID))
            #expect(model.changes.workingDirectory.files.map(\.path).sorted() == [".gitattributes", "Sources/main.swift", "secrets.txt"])
            await app.idle()
        }
    }

    @Test("in a folder with files, commits only the files it writes and leaves the others uncommitted")
    func commitsOnlyItsFiles() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let path = POSIXPath.join(base, "project")
            try FileManager.default.createDirectory(atPath: POSIXPath.join(path, "node_modules", "left-pad"), withIntermediateDirectories: true)
            try write("module.exports = 1\n", to: POSIXPath.join(path, "node_modules", "left-pad", "index.js"))
            try write("debug\n", to: POSIXPath.join(path, "npm-debug.log"))
            try write("console.log(1)\n", to: POSIXPath.join(path, "index.js"))

            let result = try await app.createRepository(CreateRepositoryRequest(
                name: "project", basePath: base, createsReadme: true, gitIgnore: "Node", license: "MIT License"
            ))

            #expect(result.failures.isEmpty)
            let repository = Repository(path: path)
            #expect(try await runGit(["log", "--format=%s"], repository) == "Initial commit\n")
            #expect(try await runGit(["ls-tree", "-r", "--name-only", "HEAD"], repository) == ".gitignore\nLICENSE\nREADME.md\n")
            // The Node template ignores node_modules and the log.
            #expect(try await untrackedPaths(repository) == ["index.js"])
            #expect(try read(path, "index.js") == "console.log(1)\n")
            await app.idle()
        }
    }

    @Test("a README, .gitignore, or LICENSE already there is overwritten and committed when chosen, and left alone otherwise")
    func existingFilesItWrites() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()

            // README chosen; the .gitignore and LICENSE aren't.
            let some = POSIXPath.join(base, "some")
            try FileManager.default.createDirectory(atPath: some, withIntermediateDirectories: true)
            try write("# Old\n", to: POSIXPath.join(some, "README.md"))
            try write("build/\n", to: POSIXPath.join(some, ".gitignore"))
            try write("All rights reserved.\n", to: POSIXPath.join(some, "LICENSE"))
            let first = try await app.createRepository(CreateRepositoryRequest(name: "some", basePath: base, createsReadme: true))
            #expect(first.failures.isEmpty)
            let someRepository = Repository(path: some)
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], someRepository) == "README.md\n")
            #expect(try await runGit(["show", "HEAD:README.md"], someRepository) == "# some\n")
            #expect(try read(some, ".gitignore") == "build/\n")
            #expect(try read(some, "LICENSE") == "All rights reserved.\n")
            #expect(try await untrackedPaths(someRepository) == [".gitignore", "LICENSE"])

            // All three chosen.
            let all = POSIXPath.join(base, "all")
            try FileManager.default.createDirectory(atPath: all, withIntermediateDirectories: true)
            try write("# Old\n", to: POSIXPath.join(all, "README.md"))
            try write("build/\n", to: POSIXPath.join(all, ".gitignore"))
            try write("All rights reserved.\n", to: POSIXPath.join(all, "LICENSE"))
            try write("notes\n", to: POSIXPath.join(all, "notes.txt"))
            let second = try await app.createRepository(CreateRepositoryRequest(
                name: "all", basePath: base, createsReadme: true, gitIgnore: "Swift", license: "MIT License"
            ))
            #expect(second.failures.isEmpty)
            let allRepository = Repository(path: all)
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], allRepository) == ".gitignore\nLICENSE\nREADME.md\n")
            #expect(try read(all, ".gitignore") == RepositoryTemplates.gitIgnoreText(named: "Swift"))
            #expect(try read(all, "LICENSE").contains("MIT License"))
            #expect(try await untrackedPaths(allRepository) == ["notes.txt"])
            await app.idle()
        }
    }

    @Test("a README written over one named in another case is committed under the name it has on disk")
    func readmeInAnotherCase() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let base = try createTempDirectory()
            let path = POSIXPath.join(base, "cased")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try write("# Old\n", to: POSIXPath.join(path, "readme.md"))
            let isCaseSensitive = pathconf(path, _PC_CASE_SENSITIVE) == 1

            let result = try await app.createRepository(CreateRepositoryRequest(name: "cased", basePath: base, createsReadme: true))

            #expect(result.failures.isEmpty)
            let repository = Repository(path: path)
            if isCaseSensitive {
                // Two files: the new README is committed, the old one isn't.
                #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], repository) == "README.md\n")
                #expect(try await untrackedPaths(repository) == ["readme.md"])
            } else {
                #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], repository) == "readme.md\n")
                #expect(try await runGit(["show", "HEAD:readme.md"], repository) == "# cased\n")
                #expect(try await untrackedPaths(repository).isEmpty)
            }
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

            let result = try await app.createRepository(CreateRepositoryRequest(name: "inner", basePath: outer.path, createsReadme: true))
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
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], repository) == "LICENSE\n")
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
            #expect(try await isUnborn(Repository(path: POSIXPath.join(base, "unknown"))))
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

    @Test("the folder checks: nothing there, the files it would overwrite, a bare repository")
    func destinationChecks() async throws {
        let base = try createTempDirectory()
        #expect(await checkCreateRepositoryDestination(POSIXPath.join(base, "new")) == CreateRepositoryDestination())

        let existing = POSIXPath.join(base, "existing")
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        try write("# Hello\n", to: POSIXPath.join(existing, "README.md"))
        #expect(await checkCreateRepositoryDestination(existing) == CreateRepositoryDestination(readmeExists: true))
        try write("build/\n", to: POSIXPath.join(existing, ".gitignore"))
        try write("MIT\n", to: POSIXPath.join(existing, "LICENSE"))
        #expect(await checkCreateRepositoryDestination(existing) == CreateRepositoryDestination(
            readmeExists: true, gitIgnoreExists: true, licenseExists: true
        ))

        let bare = POSIXPath.join(base, "bare.git")
        _ = try await Dugite.exec(["init", "--bare", bare], base)
        #expect(await checkCreateRepositoryDestination(bare).isRepository)
    }

    @Test("counts the files that will wait in Changes, as git lists them with the template chosen, and creating leaves them there")
    func countsExistingFiles() async throws {
        try await withIsolatedGitConfig { _ in
            let base = try createTempDirectory()
            let folder = POSIXPath.join(base, "project")
            for (name, text) in [
                ("README.md", "# Old\n"),
                ("index.js", "console.log(1)\n"),
                (".DS_Store", "finder\n"),
                ("npm-debug.log", "debug\n"),
                ("node_modules/left-pad/index.js", "module.exports = 1\n"),
                // A nested .gitignore, and the folder it ignores.
                ("src/.gitignore", "generated/\n*.tmp\n"),
                ("src/app.js", "app\n"),
                ("src/cache.tmp", "cache\n"),
                ("src/generated/out.js", "out\n"),
                ("vendor/lib/lib.c", "int x;\n"),
            ] {
                try FileManager.default.createDirectory(atPath: POSIXPath.dirname(POSIXPath.join(folder, name)), withIntermediateDirectories: true)
                try write(text, to: POSIXPath.join(folder, name))
            }
            // A nested repository counts once.
            _ = try await Dugite.exec(["init", "--quiet", POSIXPath.join(folder, "vendor", "lib")], base)
            // The user's global excludes ignore .DS_Store.
            let excludes = POSIXPath.join(base, "global-excludes")
            try write(".DS_Store\n", to: excludes)
            try await setGlobalConfigValue("core.excludesFile", excludes)

            // README.md, index.js, npm-debug.log, node_modules' file,
            // src/.gitignore, src/app.js, and vendor/lib/.
            #expect(await checkCreateRepositoryExistingFiles(folder, gitIgnore: nil) == CreateRepositoryExistingFiles(count: 7, filesItWrites: ["README.md"]))
            // The Node template ignores node_modules and the log.
            let node = await checkCreateRepositoryExistingFiles(folder, gitIgnore: "Node")
            #expect(node == CreateRepositoryExistingFiles(count: 5, filesItWrites: ["README.md"]))
            #expect(await checkCreateRepositoryExistingFiles(POSIXPath.join(base, "missing"), gitIgnore: nil) == CreateRepositoryExistingFiles())

            // Created with the template and a README over the old one, the
            // others wait in Changes, as many as the count said.
            let request = CreateRepositoryRequest(name: "project", basePath: base, createsReadme: true, gitIgnore: "Node")
            #expect(node.uncommittedCount(request) == 4)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let result = try await app.createRepository(request)
            #expect(result.failures.isEmpty)
            let repository = Repository(path: folder)
            #expect(try await runGit(["ls-tree", "--name-only", "HEAD"], repository) == ".gitignore\nREADME.md\n")
            let untracked = try await runGit(["ls-files", "--others", "--exclude-standard"], repository)
            #expect(untracked == "index.js\nsrc/.gitignore\nsrc/app.js\nvendor/lib/\n")
            await app.idle()
        }
    }

    @Test("with a template chosen, the count reads the template in place of the folder's top-level .gitignore, and the .gitignore files below it")
    func countsWithTemplateReplacingGitIgnore() async throws {
        try await withIsolatedGitConfig { _ in
            let base = try createTempDirectory()
            let folder = POSIXPath.join(base, "project")
            for (name, text) in [
                // The folder's own .gitignore ignores the JavaScript and the
                // docs, and keeps a log the template ignores.
                (".gitignore", "*.js\n!keep.log\ndocs/\n"),
                ("README.md", "# Old\n"),
                ("index.js", "console.log(1)\n"),
                ("keep.log", "log\n"),
                // A .gitignore in the folder the old one ignored.
                ("docs/.gitignore", "*.tmp\n"),
                ("docs/guide.md", "guide\n"),
                ("docs/draft.tmp", "draft\n"),
                // A .gitignore whose negation wins over the template's *.log.
                ("src/.gitignore", "generated/\n!debug.log\n"),
                ("src/app.js", "app\n"),
                ("src/debug.log", "debug\n"),
                ("src/generated/gen.js", "gen\n"),
                // A folder whose name reads as a pattern.
                ("notes [1]/.gitignore", "*.tmp\n"),
                ("notes [1]/today.md", "today\n"),
                ("notes [1]/scratch.tmp", "scratch\n"),
                ("node_modules/left-pad/index.js", "module.exports = 1\n"),
            ] {
                try FileManager.default.createDirectory(atPath: POSIXPath.dirname(POSIXPath.join(folder, name)), withIntermediateDirectories: true)
                try write(text, to: POSIXPath.join(folder, name))
            }

            // .gitignore and README.md, which creating overwrites, index.js,
            // docs/.gitignore, docs/guide.md, src/.gitignore, src/app.js,
            // src/debug.log, notes [1]/.gitignore, and notes [1]/today.md.
            let node = await checkCreateRepositoryExistingFiles(folder, gitIgnore: "Node")
            #expect(node == CreateRepositoryExistingFiles(count: 10, filesItWrites: [".gitignore", "README.md"]))
            let request = CreateRepositoryRequest(name: "project", basePath: base, createsReadme: true, gitIgnore: "Node")
            #expect(node.uncommittedCount(request) == 8)

            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let result = try await app.createRepository(request)
            #expect(result.failures.isEmpty)
            let untracked = try await runGit(["ls-files", "--others", "--exclude-standard"], Repository(path: folder))
            #expect(untracked == "docs/.gitignore\ndocs/guide.md\nindex.js\nnotes [1]/.gitignore\nnotes [1]/today.md\nsrc/.gitignore\nsrc/app.js\nsrc/debug.log\n")
            await app.idle()
        }
    }

    @Test("the files left in Changes are the folder's, less those it overwrites")
    func uncommittedFiles() {
        let files = CreateRepositoryExistingFiles(count: 10, filesItWrites: ["README.md", ".gitignore"])
        #expect(files.uncommittedCount(CreateRepositoryRequest(name: "app", basePath: "/tmp")) == 10)
        // There's no LICENSE to overwrite.
        let all = CreateRepositoryRequest(name: "app", basePath: "/tmp", createsReadme: true, gitIgnore: "Swift", license: "MIT License")
        #expect(files.overwrittenCount(all) == 2)
        #expect(files.uncommittedCount(all) == 8)
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

    /// Whether the repository has no commit yet.
    private func isUnborn(_ repository: Repository) async throws -> Bool {
        let result = try await git(
            ["rev-parse", "--verify", "--quiet", "HEAD"],
            repository.path,
            "isUnborn",
            options: GitExecutionOptions(successExitCodes: [0, 1])
        )
        return result.exitCode == 1
    }

    /// The untracked files git shows, sorted.
    private func untrackedPaths(_ repository: Repository) async throws -> [String] {
        try await getStatusOrThrow(repository).workingDirectory.files
            .filter { $0.status.kind == .untracked }
            .map(\.path)
            .sorted()
    }

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
