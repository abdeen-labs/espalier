// Test support for running hooks the way a Finder-launched Espalier does.
// A user's home directory whose startup files set up Homebrew, nvm, and
// mise as their installers do, stand-ins for the tools those put on PATH,
// and the launchd environment the app starts with.
//
// The stand-ins reproduce what each tool needs from its environment (how it
// finds itself, what it looks up on PATH), not what it does: they are
// shell scripts, and the "JavaScript" and "Python" programs are shell
// scripts run by stand-in interpreters.

@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// A login shell a user may have.
enum LoginShellKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case zsh
    case bash
    case fish

    /// The shell's path, or nil when it isn't installed (fish doesn't come
    /// with macOS).
    var path: String? {
        let candidates: [String] = switch self {
        case .zsh: ["/bin/zsh"]
        case .bash: ["/bin/bash"]
        case .fish: ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The shells installed on this Mac.
    static var installed: [LoginShellKind] {
        allCases.filter { $0.path != nil }
    }

    var testDescription: String { rawValue }
}

/// A user's login session as a Finder-launched Espalier sees it.
struct LoginSession: Sendable {
    let kind: LoginShellKind
    /// The user's home directory.
    let home: String
    /// Where hooks write what they saw.
    let output: String
    /// The login shell (`SHELL`).
    let shell: String
    /// What launchd gives an app opened from the Finder: no `PWD`, and
    /// launchd's `PATH`.
    let launchEnvironment: [String: String]

    /// Stands in for /opt/homebrew.
    var homebrewPrefix: String { POSIXPath.join(home, "homebrew") }
    /// Where nvm's default node version lives.
    var nodeBin: String { POSIXPath.join(home, ".nvm/versions/node/v22.11.0/bin") }
    /// mise's shims directory.
    var miseShims: String { POSIXPath.join(home, ".local/share/mise/shims") }
    /// The Python that mise installed (and pre-commit was installed with).
    var misePython: String { POSIXPath.join(home, ".local/share/mise/installs/python/3.12.7/bin/python3") }

    /// The startup file the user's own lines go in.
    var startupFile: String {
        switch kind {
        case .zsh: POSIXPath.join(home, ".zshrc")
        case .bash: POSIXPath.join(home, ".bashrc")
        case .fish: POSIXPath.join(home, ".config/fish/config.fish")
        }
    }

    /// A home directory set up for `kind`. `startupLines` go at the end of
    /// the shell's startup file.
    static func make(_ kind: LoginShellKind, startupLines: String = "") throws -> LoginSession {
        let shell = try #require(kind.path, "\(kind) isn't installed")
        let home = try createTempDirectory(prefix: "home-")
        let output = try createTempDirectory(prefix: "seen-")
        let tmp = try createTempDirectory(prefix: "tmp-") + "/"
        let session = LoginSession(
            kind: kind,
            home: home,
            output: output,
            shell: shell,
            launchEnvironment: [
                "HOME": home,
                "USER": "joe",
                "LOGNAME": "joe",
                "SHELL": shell,
                "TMPDIR": tmp,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.espalier-test/Listeners",
                "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
                "XPC_FLAGS": "0x0",
                "XPC_SERVICE_NAME": "application.com.espalier.Espalier.test",
                "__CFBundleIdentifier": "com.espalier.Espalier",
            ]
        )
        try session.install(startupLines: startupLines)
        return session
    }

    private func install(startupLines: String) throws {
        // Git's identity, as the user set it up.
        try writeTextFile(POSIXPath.join(home, ".gitconfig"), """
            [user]
            \tname = Joe Bloggs
            \temail = joe.bloggs@somewhere.com
            """)

        let bin = POSIXPath.join(homebrewPrefix, "bin")

        // Homebrew: its installer has the login shell evaluate
        // `brew shellenv`, which puts its bin and sbin first on PATH.
        try writeScript(POSIXPath.join(bin, "brew"), #"""
            #!/bin/sh
            # Stand-in for brew: `brew shellenv` prints what Homebrew's
            # installer has the shell's login file evaluate.
            prefix='\#(homebrewPrefix)'
            [ "$1" = shellenv ] || exit 1
            if [ "$2" = fish ]; then
              echo "set --global --export HOMEBREW_PREFIX \"$prefix\";"
              echo "set --global --export PATH \"$prefix/bin\" \"$prefix/sbin\" \$PATH;"
            else
              echo "export HOMEBREW_PREFIX=\"$prefix\";"
              echo "export PATH=\"$prefix/bin:$prefix/sbin\${PATH+:\$PATH}\";"
            fi
            """#)

        // A git on PATH, as Homebrew's (the hooks proxy asks it for its
        // exec path); here it runs the bundled git.
        let bundledGit = TestEnvironment.gitDirectory
        try writeScript(POSIXPath.join(bin, "git"), #"""
            #!/bin/sh
            # Stand-in for Homebrew's git.
            : "${GIT_EXEC_PATH:=\#(bundledGit.appending(path: "libexec/git-core").path(percentEncoded: false))}"
            export GIT_EXEC_PATH
            exec '\#(bundledGit.appending(path: "bin/git").path(percentEncoded: false))' "$@"
            """#)

        // mise, from Homebrew, activated with shims; a shim runs mise, so
        // it needs Homebrew's PATH too.
        try writeScript(POSIXPath.join(bin, "mise"), #"""
            #!/bin/sh
            # Stand-in for mise: `mise activate <shell> --shims` puts the
            # shims on PATH; `mise x -- <tool>` runs the tool's installed
            # version, as a shim asks it to.
            case "$1" in
            activate)
              if [ "$2" = fish ]; then
                echo "set --global --export PATH '\#(miseShims)' \$PATH"
              else
                echo "export PATH='\#(miseShims)':\"\$PATH\""
              fi ;;
            x)
              shift; [ "$1" = -- ] && shift
              tool=$1; shift
              exec '\#(POSIXPath.dirname(misePython))'/"$tool" "$@" ;;
            *) exit 1 ;;
            esac
            """#)
        try writeScript(POSIXPath.join(miseShims, "python3"), """
            #!/bin/sh
            # Stand-in for a mise shim.
            exec mise x -- python3 "$@"
            """)

        // A linter from Homebrew, for pre-commit's system hook.
        try writeScript(POSIXPath.join(bin, "ruff"), #"""
            #!/bin/sh
            # Stand-in for ruff: flags a debugger import.
            [ "$1" = check ] && shift
            status=0
            for file in "$@"; do
              if grep -q 'import pdb' "$file"; then
                echo "$file:1:1: T100 Trace found: pdb used"
                status=1
              fi
            done
            [ $status = 0 ] && echo "All checks passed!"
            exit $status
            """#)

        // The Python pre-commit is installed in: `python -m pre_commit
        // hook-impl` as pre-commit runs it.
        try writeScript(misePython, #"""
            #!/bin/sh
            # Stand-in for the Python that pre-commit is installed in.
            [ "$1" = -mpre_commit ] && [ "$2" = hook-impl ] || { echo "python3: unexpected arguments: $*" >&2; exit 2; }
            shift 2
            while [ $# -gt 0 ]; do
              case "$1" in
                --config=*) config=${1#--config=} ;;
                --hook-type=*) hook_type=${1#--hook-type=} ;;
                --hook-dir) shift; hook_dir=$1 ;;
                --) shift; break ;;
              esac
              shift
            done
            # pre-commit first runs the hook it replaced, from the directory
            # the installed hook found itself in.
            if [ -x "$hook_dir/$hook_type.legacy" ]; then
              "$hook_dir/$hook_type.legacy" "$@" || exit $?
            fi
            [ -f "$config" ] || { echo "No $config file was found"; exit 1; }
            files=$(git diff --cached --name-only --diff-filter=ACMR -- '*.py')
            if [ -z "$files" ]; then
              echo "ruff................................(no files to check)Skipped"
              exit 0
            fi
            if output=$(ruff check $files 2>&1); then
              echo "ruff.....................................................Passed"
            else
              echo "ruff.....................................................Failed"
              echo "- hook id: ruff"
              echo "- exit code: 1"
              echo
              echo "$output"
              exit 1
            fi
            """#)

        // nvm: the startup file sources nvm.sh, which puts the default node
        // on PATH.
        try writeTextFile(POSIXPath.join(home, ".nvm/nvm.sh"), """
            # Stand-in for nvm.sh: `nvm use default` as nvm does when it loads.
            NVM_BIN="$NVM_DIR/versions/node/v22.11.0/bin"
            export NVM_BIN
            PATH="$NVM_BIN:$PATH"
            export PATH
            """)
        try writeScript(POSIXPath.join(nodeBin, "node"), """
            #!/bin/sh
            # Stand-in for node: runs a JavaScript stand-in, a shell script.
            script=$1
            shift
            exec /bin/sh "$script" "$@"
            """)
        try writeScript(POSIXPath.join(nodeBin, "npx"), """
            #!/usr/bin/env node
            # Stand-in for npx: runs a package's binary.
            command=$1
            shift
            exec "node_modules/.bin/$command" "$@"
            """)

        // The startup files, as the installers leave them.
        switch kind {
        case .zsh:
            try writeTextFile(POSIXPath.join(home, ".zprofile"), """
                eval "$(\(bin)/brew shellenv)"
                """)
            try writeTextFile(startupFile, """
                export NVM_DIR="$HOME/.nvm"
                [ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"
                eval "$(mise activate zsh --shims)"
                \(startupLines)
                """)
        case .bash:
            try writeTextFile(POSIXPath.join(home, ".bash_profile"), """
                eval "$(\(bin)/brew shellenv)"
                [ -f ~/.bashrc ] && . ~/.bashrc
                """)
            try writeTextFile(startupFile, """
                export NVM_DIR="$HOME/.nvm"
                [ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"
                eval "$(mise activate bash --shims)"
                \(startupLines)
                """)
        case .fish:
            try writeTextFile(startupFile, """
                \(bin)/brew shellenv fish | source
                set --global --export NVM_DIR $HOME/.nvm
                set --global --export NVM_BIN $NVM_DIR/versions/node/v22.11.0/bin
                set --global --export PATH $NVM_BIN $PATH
                mise activate fish --shims | source
                \(startupLines)
                """)
        }
    }

    /// The variables a terminal's shell has in `directory`: the login shell
    /// run as Terminal runs it (with the session's environment and a
    /// terminal type), where the user would run git.
    func terminalEnvironment(in directory: String) async throws -> [String: String] {
        var environment = launchEnvironment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "Apple_Terminal"
        let result = try await runProcess(
            shell,
            ["-ilc", "echo ESPALIER-TERMINAL; command env -0"],
            environment: environment,
            currentDirectory: directory
        )
        let output = try #require(result.stdout.components(separatedBy: "ESPALIER-TERMINAL\n").last)
        return parseEnv0(output)
    }

    /// The `LANG` the login shell's startup files leave when the shell starts
    /// with the session's environment; nil when they set none.
    func loginShellLanguage() async throws -> String? {
        let result = try await runProcess(
            shell,
            ["-ilc", "echo ESPALIER-LANG; /usr/bin/printenv LANG"],
            environment: launchEnvironment
        )
        let output = try #require(result.stdout.components(separatedBy: "ESPALIER-LANG\n").last)
        let language = output.hasSuffix("\n") ? String(output.dropLast()) : output
        return language.isEmpty ? nil : language
    }

    /// A git runtime as `AppBootstrap.launch()` configures it for this
    /// session: the launch environment, the login shell's variables
    /// (`getEnvironmentFromShell`), the trampoline and hooks, and the
    /// default locale.
    ///
    /// Unless the test passes its own, operations wait for the shell as
    /// long as it takes, so a loaded machine can't make them go on without
    /// it.
    func runtime(
        trampoline: TrampolineEnvironment,
        hooks: HooksEnvironment,
        shellEnvironment: ShellEnvironment? = nil
    ) -> GitRuntime {
        let launchEnvironment = launchEnvironment
        return GitRuntime(
            gitDirectory: TestEnvironment.gitDirectory,
            processEnvironment: launchEnvironment,
            shellEnvironment: shellEnvironment ?? ShellEnvironment(scheduler: ManualScheduler()) {
                await getEnvironmentFromShell(launchEnvironment, timeout: .seconds(3600))
            },
            trampoline: trampoline,
            hooks: hooks,
            defaultLocale: defaultTerminalLocale()
        )
    }

    /// What a hook wrote with `/usr/bin/env -0 > "<output>/<name>"`.
    func hookEnvironment(_ name: String) throws -> [String: String] {
        let data = try Data(contentsOf: URL(filePath: POSIXPath.join(output, name)))
        return parseEnv0(String(decoding: data, as: UTF8.self))
    }

    /// The line a hook can run to record its environment as `name`.
    func recordEnvironment(_ name: String) -> String {
        "/usr/bin/env -0 > '\(POSIXPath.join(output, name))'"
    }
}

/// A trampoline server with its trampoline and hooks environments, as the
/// app wires them, for `session`, installed as the current task's runtime.
func withLoginSession<T>(
    _ session: LoginSession,
    prompter: TestPrompter = TestPrompter(),
    shellEnvironment: ShellEnvironment? = nil,
    _ body: (GitRuntime) async throws -> T
) async throws -> T {
    let suiteName = POSIXPath.join(try createTempDirectory(), "defaults")
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let server = TrampolineServer()
    let trampoline = TrampolineEnvironment(
        server: server,
        helperPath: askpassHelperPath,
        prompter: prompter,
        accounts: TestAccounts(),
        secrets: InMemorySecretStore(),
        defaults: defaults,
        appVersion: "1.0-test"
    )
    let hooks = HooksEnvironment(server: server, helperPath: askpassHelperPath, prompter: prompter, defaults: defaults)
    let runtime = session.runtime(trampoline: trampoline, hooks: hooks, shellEnvironment: shellEnvironment)

    do {
        let result = try await GitRuntime.withRuntime(runtime) {
            try await body(runtime)
        }
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

// MARK: - Repositories with hook managers

/// Sets up husky 9 in `repository`: `.husky/_` holds a script per hook
/// that runs husky's runner, `h`, and `core.hooksPath` points there. The
/// runner finds the user's script (`.husky/<hook>`) from its own path,
/// sources `~/.config/husky/init.sh`, puts `node_modules/.bin` on PATH,
/// and runs the script with `sh -e`.
///
/// `.husky/pre-commit` runs lint-staged through npx; lint-staged runs eslint
/// on the staged JavaScript files, and eslint fails on `debugger`.
func installHuskyWithLintStaged(in repository: Repository) async throws {
    let root = repository.path
    try writeScript(POSIXPath.join(root, ".husky/_/h"), #"""
        #!/usr/bin/env sh
        # Stand-in for husky 9's runner.
        name=$(basename "$0")
        script=$(dirname "$(dirname "$0")")/$name
        [ -f "$script" ] || exit 0
        init="${XDG_CONFIG_HOME:-$HOME/.config}/husky/init.sh"
        [ -f "$init" ] && . "$init"
        [ "${HUSKY-}" = "0" ] && exit 0
        export PATH="node_modules/.bin:$PATH"
        sh -e "$script" "$@"
        code=$?
        [ $code != 0 ] && echo "husky - $name script failed (code $code)"
        [ $code = 127 ] && echo "husky - command not found in PATH=$PATH"
        exit $code
        """#)
    for hook in ["pre-commit", "commit-msg", "post-commit", "post-checkout", "pre-push"] {
        try writeScript(POSIXPath.join(root, ".husky/_/\(hook)"), """
            #!/usr/bin/env sh
            . "$(dirname "$0")/h"
            """)
    }
    try writeTextFile(POSIXPath.join(root, ".husky/_/.gitignore"), "*\n")
    try writeTextFile(POSIXPath.join(root, ".husky/pre-commit"), "npx lint-staged\n")

    try writeScript(POSIXPath.join(root, "node_modules/lint-staged/bin/lint-staged.js"), #"""
        #!/usr/bin/env node
        # Stand-in for lint-staged: runs eslint on the staged JavaScript files.
        files=$(git diff --staged --diff-filter=ACMR --name-only -- '*.js')
        if [ -z "$files" ]; then
          echo "lint-staged could not find any staged files matching configured tasks."
          exit 0
        fi
        echo "[STARTED] Running tasks for staged files..."
        if ! eslint $files; then
          echo "[FAILED] eslint [FAILED]"
          exit 1
        fi
        echo "[COMPLETED] Running tasks for staged files..."
        """#)
    try writeScript(POSIXPath.join(root, "node_modules/eslint/bin/eslint.js"), #"""
        #!/usr/bin/env node
        # Stand-in for eslint: no-debugger.
        status=0
        for file in "$@"; do
          line=$(grep -n 'debugger' "$file" | head -n 1 | cut -d: -f1)
          if [ -n "$line" ]; then
            echo "$PWD/$file"
            echo "  $line:1  error  Unexpected 'debugger' statement  no-debugger"
            status=1
          fi
        done
        exit $status
        """#)
    try FileManager.default.createDirectory(atPath: POSIXPath.join(root, "node_modules/.bin"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: POSIXPath.join(root, "node_modules/.bin/lint-staged"),
        withDestinationPath: "../lint-staged/bin/lint-staged.js"
    )
    try FileManager.default.createSymbolicLink(
        atPath: POSIXPath.join(root, "node_modules/.bin/eslint"),
        withDestinationPath: "../eslint/bin/eslint.js"
    )
    try writeTextFile(POSIXPath.join(root, ".gitignore"), "node_modules/\n")
    // What `husky` (its init command) sets.
    try await setupLocalConfig(repository, [("core.hooksPath", ".husky/_")])
}

/// Installs the pre-commit framework's hook in `repository` as
/// `pre-commit install` does: `.git/hooks/pre-commit` finds its own
/// directory from `$0` and runs `python -m pre_commit` with the Python
/// pre-commit was installed with, a mise shim in `session` (which needs
/// mise, from Homebrew, on PATH). Its one hook runs ruff from Homebrew on
/// the staged Python files.
///
/// - Parameter legacyHook: The body of a hook `pre-commit install` found
///   and kept as `pre-commit.legacy`, which it runs first.
func installPreCommit(in repository: Repository, session: LoginSession, legacyHook: String? = nil) throws {
    let hooks = POSIXPath.join(repository.path, ".git/hooks")
    try writeScript(POSIXPath.join(hooks, "pre-commit"), #"""
        #!/usr/bin/env bash
        # Stand-in for the hook `pre-commit install` writes.
        INSTALL_PYTHON='\#(POSIXPath.join(session.miseShims, "python3"))'
        ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=pre-commit)
        HERE="$(cd "$(dirname "$0")" && pwd)"
        ARGS+=(--hook-dir "$HERE" -- "$@")
        if [ -x "$INSTALL_PYTHON" ]; then
            exec "$INSTALL_PYTHON" -mpre_commit "${ARGS[@]}"
        elif command -v pre-commit > /dev/null; then
            exec pre-commit "${ARGS[@]}"
        else
            echo '`pre-commit` not found.  Did you forget to activate your virtualenv?' 1>&2
            exit 1
        fi
        """#)
    if let legacyHook {
        try writeScript(POSIXPath.join(hooks, "pre-commit.legacy"), "#!/bin/sh\n\(legacyHook)\n")
    }
    try writeTextFile(POSIXPath.join(repository.path, ".pre-commit-config.yaml"), """
        repos:
        -   repo: local
            hooks:
            -   id: ruff
                name: ruff
                entry: ruff check
                language: system
                types: [python]
        """)
}

// MARK: - Support

/// Parses `env -0` output.
func parseEnv0(_ output: String) -> [String: String] {
    var variables: [String: String] = [:]
    for record in output.split(separator: "\0") {
        guard let separator = record.firstIndex(of: "="), separator != record.startIndex else {
            continue
        }
        variables[String(record[..<separator])] = String(record[record.index(after: separator)...])
    }
    return variables
}

/// Writes `contents` to `path`, creating its directory.
func writeTextFile(_ path: String, _ contents: String) throws {
    try FileManager.default.createDirectory(atPath: POSIXPath.dirname(path), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: URL(filePath: path))
}

/// The directories of a `PATH`, without the ones git puts first (its exec
/// path) and husky's `node_modules/.bin`.
func pathWithoutGitAndHusky(_ path: String?) -> [String] {
    let entries = (path ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    let firstShellEntry = entries.firstIndex { !$0.hasSuffix("libexec/git-core") && $0 != "node_modules/.bin" } ?? entries.endIndex
    return Array(entries[firstShellEntry...])
}
