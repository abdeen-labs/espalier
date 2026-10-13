# Espalier

A macOS Git client in Swift 6, SwiftUI, and AppKit, ported from GitHub
Desktop (MIT). Desktop's source is the reference for git behavior, edge
cases, and layout: where things are, what each screen shows together, and
its flows. Espalier draws its own UI and uses desktop's copy where it reads
well.

- `docs/PROGRESS.md`: what's left.
- `docs/DECISIONS.md`: every decision and every deviation from desktop.
- `docs/DESIGN.md`: how Espalier looks.

I allow deviations from desktop when they produce a better result. Each one
is recorded in `docs/DECISIONS.md`, and I'm told about it.

Apply my feedback as stated; ask before extending it. Write down what I
asked for and nothing more: when I ask for one thing, the rule is that
thing, not a rule against its alternatives. The docs hold only what is
still needed; plans, briefs, and instructions for finished work go.

## Repository layout

```
Espalier.xcodeproj           App project. Shared scheme: Espalier.
Espalier/                    App target (synchronized folder). A thin entry point that shows
                             EspalierUI's EspalierScenes, and espalier.sh, the command line tool.
espalier-askpass/            Foundation-only helper that git runs as its askpass program.
Packages/EspalierKit/        All real code, in one library product named EspalierKit.
  Sources/EspalierSupport/   ChildProcess, POSIXPath, JSCompat, ExactString, Keychain, logging,
                             Scheduler. No dependencies.
  Sources/GitKit/            The git runner (`git()` in Core/Core.swift, `Dugite`) and ports of
                             desktop's lib/git, parsers, progress, models.
  Sources/GitHubKit/         GitHub API client, OAuth device flow, accounts.
  Sources/AIKit/             Bring-your-own-key providers, commit message and conflict prompts.
  Sources/EspalierCore/      The state layer: app and repository models, refresh, background
                             work, persistence, the askpass server, editors and shells.
  Sources/EspalierSyntax/    Syntax color: tree-sitter grammars and which one a file uses.
  Sources/EspalierUI/        SwiftUI views, AppKit where needed.
  Vendor/Grammars/           Five tree-sitter grammars vendored (see its README).
  Tests/TestSupport/         Test-only helpers and desktop's fixture repositories.
  Tests/<Module>Tests/       Swift Testing suites, many ported from desktop/app/test/unit.
scripts/                     fetch-git.sh, embed-git.sh, git-version, git-checksums.
Vendor/git/                  The bundled git (gitignored, installed by scripts/fetch-git.sh).
docs/                        What's left, decisions, design.
```

Desktop's fixture repositories store nested `.git` folders as `_git`, renamed
during setup.

Reference source, shared by every session and worktree:

- `/tmp/espalier-ref/desktop`: desktop at release-3.6.7-beta2.
- `/tmp/espalier-ref/dugite`: dugite 3.2.3.

If missing, clone them again: `git clone https://github.com/desktop/desktop.git /tmp/espalier-ref/desktop`
and `git clone https://github.com/desktop/dugite.git /tmp/espalier-ref/dugite`.

## Commands

Run `scripts/fetch-git.sh` once in every new checkout or worktree. It installs
`Vendor/git` from a local cache, so after the first download it is instant.

```bash
scripts/fetch-git.sh
```

Package build and tests (all real code lives here):

```bash
cd Packages/EspalierKit && swift build
cd Packages/EspalierKit && swift test
```

`swift test --skip-build` needs every test bundle built first
(`swift build --build-tests`).

App build, then verify the embedded git and the signature:

```bash
xcodebuild -project Espalier.xcodeproj -scheme Espalier -configuration Debug -derivedDataPath DerivedData build
DerivedData/Build/Products/Debug/Espalier.app/Contents/Resources/git/bin/git --version
codesign --verify --deep --strict DerivedData/Build/Products/Debug/Espalier.app
```

Tests find git through `ESPALIER_GIT_DIR`, else the nearest `Vendor/git` in a
parent directory of the package. The app uses `Contents/Resources/git`.

Performance tests are opt-in and need a large clone: clone microsoft/vscode
into `/tmp/espalier-ref/vscode`, run `ESPALIER_PERF_REPO=/tmp/espalier-ref/vscode
swift test -c release --filter PerformanceTests` in the package (`swift build
-c release --build-tests` can't build the tests' `@testable` imports), and
delete the clone after.

Run the app as a Debug build with scratch repositories and an isolated home:
`open -n --env HOME=<scratch> --env CFFIXED_USER_HOME=<scratch>`. My
`~/.gitconfig` links to my dotfiles, so Configure Git and repository
settings are tried only in that home. `CFFIXED_USER_HOME` moves Application
Support and caches but not `UserDefaults`; pass `--args
-has-shown-welcome-flow NO` to see Welcome. I need the Mac back between
sessions: ask before taking control.

## Rules

- GitKit's ports of desktop's `lib/git` stay faithful: same arguments,
  environment, parsing, exit-code handling, and error mapping. A ported file
  starts with `// Ported from desktop/<path>` (or `dugite/<path>`) and keeps
  desktop's names and argument order, adapted to Swift.
- Comments describe the code and what it does. Decisions, their reasons, and
  how the code differs from desktop go in `docs/DECISIONS.md`.
- Desktop has bugs. Don't replicate them: fix them, test the fix, and record
  the deviation.
- No GitHub logos (desktop's `app/static/logos`) or Octocat imagery:
  desktop's MIT grant excludes GitHub's trademarks.

## Where rigor goes

My rule: rigor where a mistake hurts users, not everywhere.

- Full rigor for anything that writes to a repository (commit, checkout,
  merge, rebase, cherry-pick, squash, reorder, revert, stash, discard, reset),
  for credentials, and for hooks: tests for the edge cases, not just the
  happy path.
- Elsewhere, match what users can see: behavior, results, and meaning.

## Workers

- You work in your own git worktree and commit to its branch with clear
  messages; the lead merges into `main`.
- When done, run `swift build --build-tests` and only the suites your
  change touches (`swift test --skip-build --filter "..."`). If anything
  fails or warns, fix it and run again. Workers share
  one Mac, so a run waits its turn: `lockf -k /tmp/espalier-swift-test.lock
  swift test ...`. The lead runs the full suite once on `main` after
  merging. Report the result honestly, with output for failures; the lead
  takes it as fact and doesn't re-run it. Changes that touch no code
  (comments, docs) get no build or test run.
- Keep reports to one screen: what you did, what you left out and why, and
  follow-ups.

## Git and processes

- `GitResult`'s `stdout` and `stderr` decode UTF-8 on every access, so bind
  them once; `stdoutData` has the bytes.
- `Dugite.exec` and `Dugite.spawn` bypass hooks and the trampoline. Use them
  only where desktop calls dugite's `exec` directly; everything else runs
  `git(...)`.
- Pass a user's path to git as a pathspec through `literalPathspec(_:)` or
  `literalPathspecs(_:)`: as is, `*`, `?`, `[`, and a leading `:` would
  match other files. Not for arguments git reads as plain paths
  (`check-attr`, `update-index` or `checkout-index` stdin, `diff --no-index`,
  `<rev>:<path>`). Tests use TestSupport's `PatternPath` names.
- Read blobs with `getBlobContents` and `getPartialBlobContents`.
- Remote operations build their environment with `envForRemoteOperation(url)`.
- Processes go through `ChildProcess`; detached launches use
  `ChildProcess.spawnDetached`. `URL(filePath:)` decomposes non-ASCII names:
  file URLs use `URL(exactFilePath:)`.
- Parsing that matches desktop's output uses `JSCompat` and `ExactString`.
  JavaScript's `$` without the `m` flag is `\z`: ICU's `$` also matches
  before a final newline.
- Invisible and non-ASCII characters in a regex or string are written as
  escapes (`\u{2028}`).

## State layer (EspalierCore)

- **Models** (`AppModel`; one `RepositoryModel` per repository, with a
  feature model per area) are `@MainActor @Observable final class`es, each
  with its files in its feature's directory.
- **Operations.** Mutating intents are `async throws(OperationError)` and run
  git only inside `repository.perform(descriptor) { ctx in ... }`, which
  takes the exclusion lanes, relays progress and hook output, classifies
  errors, and requests a refresh (`refreshAfter`). Primitives taking
  `in ctx:` assume the lane is held.
- **Confirmations and decisions** are `confirmationRequired` and
  `decisionRequired` errors carrying their user-facing copy; the UI asks and
  runs the intent again with the answers. Git's credential and askpass
  prompts go through `PromptCenter`.
- **Refresh.** Only `RepositoryRefresher` writes `gitState`. An intent whose
  caller needs fresh state awaits `repository.awaitOperationRefresh(covering:)`,
  which returns once a pass that started after it has loaded its scope.
  Read-only loads for views use `LatestTask` slots, applied on the main
  actor after every await, so a stale load can't overwrite a newer one.
- **Trampoline.** The wire format lives in
  `espalier-askpass/TrampolineWire.swift`; EspalierCore's copy is a
  symlink. Edit the original, and keep the helper Foundation-only.

## UI (EspalierUI)

- Views call intents through `context.presenter.perform { ... }`;
  `WindowPresenter` turns confirmations, decisions, prompts, errors, and
  outcomes into UI. Sheets open with `context.modals.presentSheet(id:)` and
  close with `@Environment(\.dismissModal)`.
- Each feature registers its handlers in the `WindowActions` registry
  (`ActionID`) from its `*Actions.swift`; menus, the toolbar, and other
  features call actions.
- Colors, metrics, type, and motion come from `DesignSystem` tokens
  (`Palette`, `Metrics`, `Typography`, `Motion`); `docs/DESIGN.md` is the
  look.
- Copy: clear macOS wording in Apple's style (title-case buttons and menu
  items, sentence-case messages, short and plain); the voice is in
  `docs/DECISIONS.md` under Copy.
- Long lists use `NSTableView` or `List`.

## Tests

- Directories and repositories come from TestSupport
  (`createTempDirectory()`, `setupFixtureRepository(_:)`, and the helpers
  from desktop's `app/test/helpers`: `setupEmptyRepository`,
  `setupConflictedRepo`, `makeCommit`, `cloneRepository`, ...), which
  install the hermetic environment: author "Joe Bloggs", an empty `HOME`,
  and no inherited `GIT_*` variables. `withGitEnvironment` scopes
  environment variables to one task; `withIsolatedGitConfig { configPath in
  ... }` isolates global config.
- TestSupport's `createBranch(_:_:_:)` shadows GitKit's when the start point
  isn't optional; write `GitKit.createBranch(...)` for GitKit's.
- Commit signing tests use throwaway keys: GPG a temporary `GNUPGHOME`,
  stopping the agent it started (`gpgconf --kill gpg-agent` with that
  `GNUPGHOME`); SSH throwaway key files with `SSH_AUTH_SOCK` unset. So does
  checking signing in the running app, in scratch repositories.
- GitHub tests run offline, on `MockGitHub` and the `.offline` trait.
- State layer tests build environments with `AppHarness`
  (EspalierCoreTestSupport, with `ManualFileWatcher` and recording
  services) and wait with `idle()` and `ManualScheduler`. `AppHarness`
  starts a background service only when given `backgroundServices:`.
- Never write screenshot, snapshot, or string tests (tests of strings the
  UI shows).
- Tests run in parallel in one process, so a test leaves process-wide state
  (`setenv`, `chdir`, `GitRuntime.configure`) alone.
- Blocking work in a test (a blocking `read`, a semaphore wait,
  `Thread.sleep`) runs on a dispatch queue behind a continuation, off the
  concurrency pool.
- A failure only under heavy load is a race: fix the race (sleeps, retries,
  and longer timeouts only hide it). The exception is a wall-clock bound in
  code you didn't touch ("took too long", cancellation latency) that passes
  when run alone: name it in your report and leave it to the lead.
- A test that waits on something that might never happen takes
  `.hangGuard(minutes:)` (TestSupport; 5 minutes suits most tests).
  `.timeLimit(minutes:)` is for a test that checks its own speed. Waits wait
  for the event itself (`AsyncEvent`, observation, a dispatch source) and
  end when the task is cancelled.
- Cases of one shape are one `@Test(arguments:)` over `NamedCase`s.
- A test earns its place by checking behavior: no tests of constants,
  copied mapping tables, test doubles, or exact duplicates.

## Conventions

- Swift 6 language mode and Swift Testing (`import Testing`).
- Concurrency is configured per module in `Package.swift`:
  - EspalierSupport, GitKit, GitHubKit, and AIKit keep classic semantics, so a
    nonisolated `async` function always runs off the main actor. Process
    spawning and parsing large outputs run there, off the main thread.
  - EspalierCore and EspalierUI enable `NonisolatedNonsendingByDefault`.
    EspalierUI also defaults to main-actor isolation.
- Values crossing module boundaries are `Sendable` structs and enums.
- File names must be unique within a module.
- Log with `Log.logger(category:)` from EspalierSupport. Never log tokens,
  keys, passwords, or file contents.
