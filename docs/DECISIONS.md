# Decisions

Every deviation from desktop and every choice I made, with the
reason.

## Project

- **Only Git Credential Manager gets JIT entitlements** (`allow-jit`,
  `allow-unsigned-executable-memory`), which .NET's JIT needs under the
  hardened runtime. Every other Mach-O is hardened with none; desktop signs
  every bundled file with those two plus `automation.apple-events`.
- **Debug builds are `dev.abdeen.espalier.debug`** (my call), so a build from
  Xcode keeps its own preferences, caches, notification settings, and
  Launch Services entry apart from an installed release. The repository
  list and Keychain items are still shared.
- **Folders are a document type at the `Alternate` rank,** so Open With and
  Dock drops offer Espalier without it becoming the default for folders.
- **The app icon** (my design): three frosted panes on navy with a
  branch whose tip is a leaf, an Icon Composer document rendered in light,
  dark, and tinted styles. Dark mode has its own colors because the
  automatic treatment hid the branch.

## Licensing

- **Open source under the MIT license, released by Abdeen Labs** (my call),
  in the `abdeen-labs` organization. A client that holds users'
  credentials, tokens, signing keys, and AI keys earns trust by being
  readable, and desktop, which it ports, is open source too.
- **`LICENSE-THIRD-PARTY` carries the notices for what the repository takes
  from other projects** (desktop's and dugite's ports and desktop's
  fixtures, gemoji, choosealicense.com's licenses, github/gitignore's
  templates, the vendored grammars, the bundled fonts): MIT asks for the notice with every
  copy, and About ▸ Acknowledgements covers only the app.

## Desktop's layout, Espalier's look

- **Desktop's layout, not its look** (my call). Desktop defines what Espalier
  can do, how git operations behave (arguments, safety checks, edge cases,
  errors), and where things are: the window's arrangement, what each screen
  shows together, and its flows. Its visual style isn't used; Espalier draws
  its own for macOS. A layout that departs from desktop's needs a better
  result and is recorded here.
- **Copy isn't copied word for word** (my call): desktop's strings are reused
  where they read well; otherwise Espalier writes clear macOS copy that
  means the same thing.
- **Espalier draws its own UI** (my call): every control, list, and surface
  is Espalier's own design. Simple, clean, and modern, with personality;
  `docs/DESIGN.md` is the look. The system's own pieces stay macOS's (my
  call): the window's chrome (the traffic lights, the toolbar, and the
  split view), Quick Look, and the open and save panels, which need no
  privacy permissions.
- **History has a simple mode** (my call; desktop has none), the default for a
  new install: the graph overwhelms anyone who doesn't know what they're
  looking at.
- **The diff has no "Show check marks" setting** (my call): the tinted
  gutter already shows inclusion without relying on color, since a line
  left out is faded.
- **Themes are a setting** (my call): Settings ▸ Appearance picks a theme
  (Classic, the default; Orchard; Islands; Pop) and a color of that
  theme's own (Orchard: Plum, Clay, Ink, the default, Teal, Espresso;
  Islands: Berry, Lagoon, the default, Indigo; Pop: Tangerine, the
  default, Electric, Magenta), each theme with its own colors. Classic
  follows the Mac's accent color. Theme, color, background tint, app
  font, and code font are separate picks, and a theme keeps its color and
  its tint when another is chosen.
- **The background tint is a setting** (my call): Settings ▸ Appearance's
  Background swatches pick the theme's own backgrounds (Default), Neutral,
  Warm, Cool, Sage, Rose, or Lavender. A tint re-hues the opaque surfaces
  (panes, sidebar, fields, hunk headers, lines, cards, control fills) at
  each one's own luminance, so text keeps its contrast; a surface too near
  white for the hue is as light as the hue allows. Its chroma grows with a
  surface's depth, as the themes' own tints do. Washes, text, the accent,
  status colors, and Pop's accent-tinted sidebar (my call) stay the
  theme's. A swatch is the theme's light field fill in that tint, its
  chroma tripled, since the tints are too faint to tell apart at swatch
  size.
- **The app font and the code font are two settings** (my call), picked
  apart from each other and from the theme, any app font with any code
  font. The app font is all the interface's text: SF Pro (the default),
  Fixel Text, Atkinson Hyperlegible Next, or Martian Grotesk. The code font
  is everything drawn monospaced (commit IDs, counts, ahead and behind,
  ref tags, code, terminal output): SF Mono (the default), Geist Mono, or
  Atkinson Hyperlegible Mono.
- **The bundled fonts ship unmodified,** each with its license: Atkinson's
  Reserved Font Names forbid a modified version keeping its name, so none
  is subset or converted.
- **Each font is scaled to read alike,** whichever the other is
  (Atkinson Hyperlegible Next 1.04, Martian Grotesk 0.88, Atkinson
  Hyperlegible Mono 1.02, the others 1); the app font relative to the text
  styles, so the Mac's Text Size still applies, the code font at fixed
  sizes.
- **Rows keep SF Pro's line height at the app font's body size,** so a
  face with tall line metrics (Fixel) doesn't grow every row; the code
  font doesn't change rows.
- **Monos never join characters** (`calt` and `liga` off): the diff shows
  exact characters.
- **Key caps stay SF Pro** whatever the app font: the other faces lack
  the keys' symbols. Bundled faces fall back on the system font's cascade
  list, so a missing glyph takes SF's line height.
- **A change of theme, color, background tint, or fonts applies at
  once** to every open window; menus, popovers, and tooltips take it when
  they next open.
- **Classic's dark prominent fill is the accent itself:** white on the
  default blue is 3.65:1, under the 4.5:1 every other theme's prominent
  fill reaches.
- **Marks on the accent follow its lightness:** a check, a radio's dot,
  and the switch's knob are white, but the background's color on a
  near-white accent (under 1.3:1, none of the Mac's), and a theme can set
  its own. Orchard's are the dark paper in dark, where white is 1.2:1 on
  Espresso's cream and about 2:1 on the other colors' light accents.

## GitHub

**Sign-in uses Espalier's own OAuth app and the device flow** (desktop opens
the browser and receives a callback), with desktop's scopes: `repo`,
`user`, `workflow`.

## GitKit runner

- **Kept over Node's `execFile`:** standard input is `/dev/null` unless the
  caller supplies input (an empty open pipe would hang a git command that
  reads it); output is read for at most 2 s after git exits (a grandchild
  holding git's pipes would otherwise hang `git()`); writing to a child
  that stopped reading isn't fatal (`F_SETNOSIGPIPE`).

## GitHub-owned services

Desktop calls some endpoints only its own OAuth app may use. Instead:

- **Live notifications** (the alive channel and its WebSocket): Espalier
  polls the REST API every 2 minutes (or as `X-Poll-Interval` asks) for the
  selected repository's pull requests while high-signal notifications are
  on, with conditional requests, so unchanged ones cost no rate limit.
- **Avatar tokens:** Espalier uses the API's public `avatar_url`.
- **Server feature flags:** not used.
- **Release notes:** part of desktop's updater; Sparkle replaces it.
- **Copilot:** out of scope; bring-your-own-key providers replace it.

## AI

**No agent loop.** Desktop's Copilot sessions run with no tools, so AIKit
calls each provider's chat API directly with desktop's prompts, streaming
where desktop streams (conflict resolution shows the model's reasoning).

## Models

- **Renames:** desktop's `Image` is `DiffImage` and its `Progress` union
  `AnyProgress`, which would clash with `SwiftUI.Image` and
  `Foundation.Progress`.
- **`DiffHunkHeader` equality compares all four fields** (desktop's compares
  `oldStartLine` twice and never `newLineCount`).

## Markers written into repositories

Espalier names fork remotes `espalier-<owner>` and marks its automatic
stashes `!!Espalier<branch>`, so nothing in a user's repository carries
GitHub branding. It also recognizes desktop's `github-desktop-<owner>` and
`!!GitHub_Desktop<branch>`, so both carry over.

## The user's shell environment

- **Git gets the user's shell environment,** as desktop's `lib/shell.ts`
  does: launched from the Finder, the Dock, or `open`, Espalier runs
  `$SHELL -ilc` once at launch and takes its variables.
- **Deviations:** the variables go into `GitRuntime.processEnvironment`, not
  the process's own environment, which can't change safely while other
  threads read it. Operations wait for the load (at most 5 s) and later
  ones get the variables once they arrive, where desktop gave up after 5 s
  for the whole session.
- **Fixed parsing:** a value containing a newline or an empty value no
  longer loses the next variable; startup files that print are ignored; the
  shell's own `PWD`, `OLDPWD`, `SHLVL`, and `_` are left out (desktop gave
  git and binary hooks `PWD=/`).

## Hooks

- **The hooks environment is on by default** (desktop enables it only in
  beta builds), under desktop's keys `git-hooks-env-enabled` and
  `git-cache-hooks-env`.
- **`getRepoHooks` follows symbolic links,** as git does; desktop skipped
  symlinked hooks, and its `core.hooksPath` redirect then stopped them.
- **Hooks that aren't intercepted keep running.** Desktop's redirect skipped
  every hook not in `interceptHooks` (for example `reference-transaction`).
  Espalier's temporary hooks directory runs executable ones by their own
  path, so husky and pre-commit's `$0`-relative tools work.
- **The hooks' login shell starts as a terminal's does,** with launchd's
  `PATH` and the app's user, home, shell, SSH agent, and locale; desktop
  started it empty. With no locale set (a Finder launch), hooks and the
  programs git starts get the UTF-8 locale a new Terminal window would, so
  Ruby hooks read UTF-8 files and gpg reads a non-ASCII signing key. Git
  gets it as `LC_CTYPE` only: `LANG` would translate GnuPG's messages,
  which signing failures are read from.
- **A hook's progress arrives before git's exit** (desktop could end an
  operation before its last hook event).
- **Also:** `core.hooksPath` is read with `--type=path` (`~` expands); abort
  and cancel kill the hook's process group, where desktop left the hook
  running; a hook failure falls back to the prompter when the operation
  passes no `onHookFailure` (except for background work); hooks see
  `ESPALIER=1` as well as `GITHUB_DESKTOP=1`.

## Refreshing

- **A file watcher adds live updates while the window is visible** (desktop
  refreshes on focus and after operations only), so Changes stays current
  beside an editor. It's paused while Espalier's own operation runs, and
  status runs with `--no-optional-locks`, so a refresh never writes the
  index and can't trigger itself.
- **Suggestions and the sync button wait for the repository's state**
  (status, remotes, and refs): desktop's button reads "Publish repository"
  whenever it has no remote, so a repository just selected could flash it.

## State layer

- **Repository identity is a UUID,** so alias, GitHub, and path changes
  keep drafts and selections (desktop's structural hash dropped them).
- **An unreadable repository list is moved aside** and the user told; a
  newer version's is used read-only.
- **Preferences** are UserDefaults under desktop's keys, read with desktop's
  lenient `getBoolean`; Espalier-only settings get new keys. Not kept: zoom,
  pane widths, Copilot settings, usage stats, Windows settings, the
  thank-you card. Defaults live in code; nothing is written at launch.
- **Commit drafts live in memory** and are lost on quit, as in desktop
  (my call); quitting with one asks first.
- **Exclusion:** a local lane (index, working tree, HEAD, local refs) and a
  network lane, shared by a repository's worktrees; pull and remote
  configuration take the network lane. Desktop guarded only push, pull,
  fetch, and double commits. A user operation waits behind background work
  and fails with `busy` behind another user operation (desktop silently
  dropped a user fetch during a background fetch).
- **Writes are never cancelled implicitly:** selection changes, stopping
  services, and quitting never interrupt a git write; only a user's cancel
  does (clone, hook abort).
- **Background services stop by cancelling their loop,** never an operation
  (fixes desktop's orphaned pruner interval and pull request timer). They
  start once the selected repository is associated with GitHub (desktop
  waited for it to be selected again).
- **`X-Poll-Interval` is read in seconds** (desktop compared it with
  milliseconds).
- **Branch pruning keeps desktop's safeguards,** runs as background work,
  records each deletion with its SHA (restorable), reads the branches itself
  and keeps one that moved since it was found merged, and writes the last
  prune date only once a prune runs.
- **Background errors keep their side effects** (marking a repository
  missing) but are never presented.
- **Retrying a push keeps its options** (desktop retried a force push as a
  normal push). **A force push forgets the rewrite only once it succeeds,**
  and only pushed tags leave the queue.
- **Hook aborts are `cancelled(.hookAborted)`,** never an error (desktop's
  pull showed git's error).
- **Multi-commit undo is offered only while the tip is the operation's
  result and the tree is clean;** otherwise it would hard-reset newer work.
- **Conflict and multi-commit state derive from git state** on every status
  pass (desktop set the conflicts step in two racing places).
- **`pull.rebase`** accepts git's boolean spellings; `merges` and
  `interactive` count as rebase.
- **Local commits are computed on a detached HEAD** (`HEAD --not
  --remotes`); desktop kept a stale list.
- **URL schemes:** `espalier://openRepo/<url>?branch=&pr=&filepath=`
  (desktop's grammar), with no `oauth` action. URL actions match ignoring
  case, don't reveal files outside the repository, and check a pull request
  out.
- **GitHub Desktop's links** (`x-github-client`, `github-mac`: "Open with
  GitHub Desktop" on GitHub) open in Espalier when Settings ▸ Integrations ▸
  "Open GitHub Desktop links in Espalier" is on (`open-github-desktop-links`,
  off by default; my call). On, Espalier is the default app for both schemes
  and takes them back at launch and whenever it becomes active, since
  GitHub Desktop claims them each time it launches (my call); a re-claim
  macOS refuses or the user declines is logged and waits for the next
  launch. Off, they go back to GitHub Desktop when it's installed. The
  setting changes only when the user flips the switch (my call), and is saved
  once Launch Services has made the change. A link Espalier can't open (any
  action but `openRepo`, such as GitHub Desktop's `oauth` sign-in) goes to
  GitHub Desktop when it's installed.
- **Revert has a conflict flow** (`REVERT_HEAD`, continue, abort); desktop
  left the repository mid-revert with a generic error.
- **Rebase's "rewrites published commits" check examines the branch being
  rebased** (desktop passed the base branch).
- **Cherry-pick undo records the local branch actually checked out,** and
  success selects the new commit.
- **Hiding whitespace keeps partial line selections;** staging always uses
  the full diff, and editing selections is disabled while whitespace is
  hidden (desktop discarded partial staging). Whole-file inclusion survives
  a change of status kind.
- **No tutorial** (my call): onboarding is signing in and adding repositories.
- **The default clone folder is `~/Developer`** (my call), Apple's convention;
  the last folder used is remembered.
- **Signed-out accounts** (token rejected or expired) stay listed until
  signed in again or dismissed. Signing in again replaces the account once
  the new sign-in succeeds.
- **Fast-forwarding other branches skips branches checked out in other
  worktrees** (git's refusal stopped them all).
- **Publishing refuses before creating anything on GitHub when `origin`
  exists.** An empty `FETCH_HEAD` keeps the last fetched date.
- **Removing a repository** asks before moving it to the Trash even with
  confirmations off, is refused while a user operation runs (as is
  relocating), drops everything kept for it, and selects the most recent
  repository. Linked worktrees record their main worktree, so they're
  recovered after `git worktree remove`.
- **Pull request lists:** an empty answer replaces the list, a list with a
  failed page is never stored, and fork remotes are pruned only after
  GitHub answers. **Repository rules:** RE2 patterns are translated to ICU
  (one that can't compile passes); a required pull request blocks the
  commit with a message.
- **Clones can be cancelled** (desktop's can't): Cancel Clone, removing the
  clone, or quitting stops git's process group and removes what it cloned.
  Two clones into one folder are refused, and so is a relative path.
- **Worktrees:** deleting the current worktree deletes first, from the main
  worktree, then switches, so a failure leaves things as they were; moving
  onto an existing path is refused; a new worktree's branch name that
  names a remote branch checks it out (desktop made a local branch named
  `origin/topic`); new worktrees get their submodules.

## History graph

- **Espalier draws its own graph** (desktop has none): the trunk (the
  default branch's first parents) is a straight line in lane 0; other lines
  take the lowest free lane to its right; no line passes through a node;
  each line keeps its color.
- **Long edges become stubs** (my call): an edge whose parent is more than 30
  rows away is two short linked stubs instead of a lane held the whole way,
  taking desktop's history from 23 lanes on average (max 55) to about 3
  (max 10). Trunk edges are never cut.
- **History is in topological order** (`--topo-order`), and pages start from
  the commits the scope's refs pointed at, so they stay consistent while
  refs move (desktop's `--skip` paging duplicated or dropped commits when
  HEAD moved). The scope is remembered per repository.
- **Espalier writes a commit-graph file when a repository has none**
  (my call): `git commit-graph write --reachable --split` as background work,
  as `git gc` would, once per repository. It touches no commits, refs, or
  files, and operations never wait for it.
- **History shows all local branches by default** (desktop shows the current
  branch), and has a commit search (desktop has none).

## Commit signing

- **Signing is git's, with the user's configuration.** `--no-gpg-sign` only
  for commits that never become history (squash's temporary commit, stash
  entries).
- **ssh-keygen's passphrase prompt is answered** (desktop's askpass knew only
  ssh's), with the same prompt and Keychain entry, once per git command; a
  stored passphrase ssh-keygen rejects is forgotten.
- **Signing failures are explained** before git's output: the program
  missing, a terminal-only pinentry (use pinentry-mac), a cancelled or wrong
  passphrase, no key, an expired key, no gpg-agent, SSH's key, agent, and
  file problems. None hang.
- **A revert that couldn't be committed is put back** with `git reset
  --merge HEAD`, as `git revert --abort` does; desktop left it staged with
  nothing to continue or abort.

## External dependencies

**Established packages are allowed and encouraged** (my call) where one does
the job well. Desktop's logic stays ported; a package replaces only
infrastructure. Each is recorded here with its purpose and license.

- **Syntax color: SwiftTreeSitter 0.25.0** (BSD 3-Clause) **and 23
  grammars** (MIT), in `EspalierSyntax`. Five are vendored (`Vendor/Grammars`, see its README).
  Two Swift patterns are added, as Xcode colors them: a subscript isn't a
  call, and a called capitalized name is a type.
- **Sparkle** for updates, once I have a feed and keys.

## The app

**Layout**

- **One window, two columns:** the sidebar and a detail area whose inner
  split is remembered per place (Changes: files | diff; History: commits |
  details, Simple and Graph each with its own width). Three columns would
  make Changes and History share one middle width, which suits neither.
- **The sidebar is the current repository's places:** Changes, History,
  Branches, Pull Requests, Tags, and Stashes. Switching the working copy is
  desktop's: the repository popover (⌘T) lists worktrees and repositories;
  the sidebar doesn't.
- **Operations are non-modal:** progress and conflicts show in an operation
  panel in Changes or a floating capsule elsewhere; outcomes are toasts with
  Undo where available, also when a recovery (Stash Changes and Continue,
  Retry, signing in) runs the operation again. Modal UI is kept for
  confirmations, the branch-switch decision, prompts git is waiting on, and
  forms.
- **Closing the window quits Espalier,** as Apple's single-window apps do
  (desktop keeps running), after the quit guard: operations that write to a
  repository, running clones, and unfinished commit messages in any
  repository ask first.
- **The Debug menu is in Debug builds only** (my call).
- **A rolling log file** (my call): `~/Library/Logs/Espalier/Espalier.log`
  (`Espalier Debug` for a Debug build), info and above, private values as
  `<private>`, at most two files of about 5 MB. **Show Logs in Finder**
  writes this session's unified log to the same folder.

**My choices**

- **Syntax color in diffs** (tree-sitter).
- **macOS shortcut conventions win** where desktop's clash: ⌘G and ⇧⌘G are
  Find Next and Previous, Go to Commit Message is ⌘J, View on GitHub ⌥⇧⌘G,
  Copy Path ⌥⌘C, and ⌘⌫ deletes the selection. ⌘P and ⇧⌘P stay Push and
  Pull, since Espalier doesn't print.
- **⌘S shows and hides the sidebar,** in place of the system's ⌃⌘S;
  Espalier has nothing to save.
- **The working copy is always the graph's top node,** even with no
  changes, so rows stay stable as the tree goes from clean to dirty.
- **The AI sparkle shows before any provider is set up** (it opens setup),
  and a setting turns AI features off entirely.
- **A code text size (⌘= / ⌘−) replaces desktop's window zoom.**
- **Avatars wherever possible,** from every source desktop uses, in its
  order (`getAvatarUrlCandidates`), and the person's initials on their own
  color when none can supply one (including GitHub.com's one generated
  image for emails it doesn't know). **No Gravatar:** it would send
  authors' emails to a third party.

**Added in Espalier:** the history graph with scope, search, and stub
navigation (a Go menu); simple mode; a Tags section; every branch's stash
listed (restoring stays on the current branch's); Restore Pruned Branch;
toolbar customization; a sidebar filter; a Commit menu; Amend Last Commit in
the composer's options; the commit inspector; the quit guard; the code text
size; "Show in Finder" everywhere.

**Dropped from desktop:** zoom; pane-width keys and ⌘8/⌘9 (the split views
resize by dragging); the `show-changes-filter` toggle; Windows menus and access keys; the
tutorial, Explore, and the thank-you card; release notes and update banners
(Sparkle); the unsupported-OS banner; Copilot's handoff, disclaimers,
call-outs, and nudges; the untrusted-certificate dialog; browser OAuth (the
device flow); emoji autocomplete (`:shortcode:` emoji still render); links
to GitHub's help pages; the Test menu; Save/Cancel in Settings, which apply
immediately; importing desktop's repository list and settings (my call).

**Changes and the diff**

- **Return opens a file in the external editor,** as Finder-like lists do;
  Space toggles inclusion (desktop's Enter).
- **An unknown co-author's token is drawn in the warning color.** The
  co-authors are a region of the commit message card. Hiding co-authors
  keeps them in the draft, never committed or checked while hidden
  (desktop cleared them).
- **"N included" counts every file the next commit includes,** in full or in
  part, including files the filter hides; the include-all checkbox reflects
  only the files shown.
- **Diffs paint before the file's contents load;** expansion and syntax
  color follow (desktop waited). Find works from anywhere in the window.
  Copying a diff skips hunk headers. A submodule URL without a host means
  GitHub.com (desktop showed "null").
- **Starting to amend sets an unfinished message aside** and brings it back
  afterwards. Amend works on a detached HEAD, not during a rebase.
- **The commit button names the branch** ("Commit 3 Files to main"), as
  desktop's does; a long name is cut in the middle.
- **One commit form through a merge or rebase,** as desktop's: during a
  merge the commit form shows git's message and Commit Merge, enabled once
  nothing is left to resolve; a stopped rebase, cherry-pick, or revert shows
  Continue in its place. The operation bar keeps the title, progress,
  Resolve with AI, and Abort. ⌘↩ doesn't commit a merge or continue.
- **Conflicted files are rows of the one list,** as desktop's, with their
  actions in the row and in its context menu.
- **With no changes the header stays** ("0 changed files") over the empty
  list; "No Local Changes" shows only beside it.
- **A stash's files are the Changes rows, read-only,** under a header with
  Restore and Discard….
- **The diff is laid out as desktop's:** the expansion buttons in the hunk
  header's gutter (side by side where desktop stacks them), the `@@` line as
  git writes it in the code font, one bar per line that is both the
  inclusion mark and its block's handle (colored per line), and in Split
  the handle between the halves. Unified/Split is in the diff's options
  menu, which holds only view settings; an image's modes sit above it.
  Espalier keeps a checkbox in each hunk header.
- **A left-out line keeps a faint add or delete tint and fades its text,**
  without a strikethrough: a struck-through deletion reads as deleted when
  it stays. Included lines' numbers aren't bold.
- **The diff's line cursor shows after the arrow keys or a gutter click,**
  not after a click in the text.
- **Conflict regions:** ours mint, the common ancestor gray, theirs orange.
- **Lines that don't wrap scroll sideways under a scroller,** the line
  numbers fixed. A wrapped line continues at its indent plus two columns.
- **A large diff shows no counts until it's shown.** The whitespace hint's
  buttons are Cancel and Show Whitespace (desktop: No and Yes).
- **Find in the diff is Espalier's own bar,** a floating capsule where
  desktop's search box hangs, at the diff's top trailing corner: it floats
  over the diff rather than pushing it down, and the current match scrolls
  clear of it. It searches as it's typed in (desktop searched on Return),
  literally and ignoring case as desktop's does, context lines counting on
  both sides when split; a query of only spaces finds nothing. It stays
  open when focus leaves it (desktop closed it on blur), so ⌘G and ⇧⌘G go
  on from the diff or the file list. Escape in it or in the diff, or Done,
  closes it and selects the current match in the diff, which takes focus.
  ⌘G and ⇧⌘G with it closed reopen it on the next or previous match from
  the selection; Use Selection for Find searches for the selection's first
  line. It stays open from file to file, each opening at its first match,
  and the current match stays on its line through Unified ↔ Split and
  expanding. Past 10,000 matches the count says "10,000+" and the rest
  aren't found.

**History**

- **Squash, reorder, and Reset to Commit act on the current branch's
  first-parent line from HEAD down,** with no merge in between (desktop's
  list indexes pick the wrong commits once all branches show), and rewrite
  from the oldest moved commit's parent (desktop used the last loaded row,
  so a paged history could rewrite from the root).
- **A squash or reorder that would replay a merge commit says why,** and
  Reorder refuses at once rather than after a location is chosen.
- **Commits not on the current branch can be cherry-picked onto it,**
  because History shows other branches. Desktop's "same branch" rule still
  applies to commits on it.
- **Squash keeps co-authors in every repository** (desktop only in GitHub
  repositories); each can be removed in the sheet.
- **Undo Commit refuses a commit with tags everywhere** (desktop's History
  menu didn't). Undo needs the latest unpushed commit and no operation in
  progress; reset needs an ancestor with only unpushed commits after it.
- **Without a remote, nothing shows as unpushed.**
- **A commit's files sit beside its diff,** as desktop's, in a list with
  each file's name and folder.
- **A branch's row shows that branch's history** (desktop compares): its
  first-parent line in Simple, the graph at its tip in Graph, with History,
  Behind, and Ahead in the header and the merge call to action on Behind.
  Nothing rewrites there (squash, reorder, Reset, Undo, amend);
  cherry-picking onto the current branch still works.
- **Simple and Graph share their rows' look:** the font, short times
  ("12m", "Oct 5"), the avatar and tags before the title, the unpushed
  arrow, and the selection. The simple rail draws the graph's nodes.
- **Commit Info shows what the header doesn't:** dates, the committer,
  parents, branches, co-authors, and trailers.
- **A tag off the simple line, or a ref outside the graph's scope,** says so
  above the list, with Show in Graph or Show All Branches.
- **The squash sheet's message is a commit message card.**

**Branches**

- **Checkout refuses during any operation in progress,** an interrupted
  rebase included, as does creating a branch that checks out: with a
  merge's, cherry-pick's, or revert's conflicts staged, `git checkout`
  silently drops `MERGE_HEAD`, `CHERRY_PICK_HEAD`, or `REVERT_HEAD` (desktop
  blocked only during a rebase). Rename and delete refuse during a rebase,
  squash, or reorder.
- **A branch row's Rename… and Delete… work on any local branch;** the
  Branch menu keeps desktop's rules for the current branch.
- **Delete Branch makes Delete the default button,** as every confirmation
  does (my call; desktop's makes Cancel the default).
- **The branch popover is desktop's branch switcher:** a click or Return
  checks a branch out, and "Choose a branch to merge into <current>" sits
  beside New Branch…. The sidebar's branches use its groups (Default,
  Recent, Other, Remote), Other open at first.
- **The current branch, worktree, repository, or pull request has a
  semibold title,** and nothing else marks it; a checked-out pull request
  says "Checked Out".

**Repositories**

- **Creating a repository refuses a repository's own folder** (desktop
  compared paths as typed, so `name/` committed an existing repository's
  changes as "Initial commit"); an existing README is overwritten only after
  a warning.
- **The .gitignore templates and licenses** come from desktop's static
  folder (github/gitignore, CC0; choosealicense.com, MIT), credited in
  Acknowledgements.
- **A repository's own author never writes an empty value** (desktop's
  switch back to the global config failed when only one value was local).
- **Clone shows GitHub Enterprise once an Enterprise account exists,** and so
  does Publish. Retry Clone runs in the clone flow, so it still gets the Git
  LFS and fork questions. Publish needs a repository without a remote.
- **The sidebar's filter matches substrings;** the repository popover and
  the clone lists match fuzzily, as desktop's did.
- **Add Worktree refuses what's in the way and an invalid branch name**
  (desktop silently used the worktree's name).
- **The repository popover is desktop's repository list:** the filter and
  Add at the top, then worktrees (with New Worktree…), then repositories by
  group, with desktop's context menus. Its height follows its rows, up to
  the window's. Worktrees live here (desktop has a dropdown of their own).
- **The command line tool** is `espalier.sh` in the bundle (`espalier`,
  `espalier open [path]`, `espalier clone [-b branch] <url or owner/name>`),
  linked at `/usr/local/bin/espalier` as the user or after an administrator
  prompt.
- **Move to Applications** isn't offered in Debug builds; as the user it
  puts an older copy in the Trash, as an administrator it replaces it.

**Settings**

- **A missing editor or shell shows as not installed,** never replaced and
  saved (desktop replaced it); with no choice, the default is the first
  installed editor, looked up at each launch.
- **One author form** (desktop's `GitConfigUserForm`) in Settings ▸ Git,
  Repository Settings, and Configure Git. Open With and Settings choose an
  editor with the same pop-up.
- **Sheets label their fields in a column beside them** (Clone's is
  "Repository URL"); a plain choice of two is a radio list, choices with
  descriptions are cards.
- **The Settings window is 720 wide.** Tabs in sheets are centered. The
  welcome flow has no step indicator.
- **Git's output in an error shows in a box as tall as it,** up to 260
  points, then scrolls. Toasts have a close button.
- **The SSH host prompt's buttons are Connect and Cancel** (desktop: Yes
  and No); the Open With sheet's title has no ellipsis.

**GitHub**

- **Descriptions, reviews, and comments are Markdown Espalier renders.**
  Images carry the account's token only to repository assets and
  Enterprise avatars on the account's own origin, never across a redirect.
- **Exposing a secret is never the default button.**
- **A clicked notification** selects its repository and pull request, and a
  review or comment opens in a sheet.
- **Pull request links check the pull request out.**
- **Pull requests have their own symbol** (desktop's reads as a figure at
  small sizes) and drafts a Draft tag. A check's step row opens the step.
- **Preview Pull Request fills the window** less its 40-point margins, as
  desktop's dialog does.

## GitHubKit

- **Device flow requests are form-encoded** (RFC 8628); desktop's token
  request sends JSON.
- **Tokens:** Keychain service `Espalier - <endpoint>`, account = login.
  Refresh tokens are discarded (refreshing needs a client secret, which a
  device-flow app doesn't have), so expiring tokens mean signing in again.
  Token revocation needs the secret too, so sign-out removes the local
  token and points to the OAuth app's settings.
- **Enterprise (Server and ghe.com) needs an OAuth app with device flow
  registered on that server;** its client ID is stored per account.
- **No untrusted-certificate prompt:** the error names the server and says
  to trust its certificate in Keychain Access. Redirects keep
  `Authorization` only on the same origin.
- **Desktop bugs fixed:** `fetchAllOpenPullRequests` throws when a page
  fails; `fetchIssues` filters on `pull_request`; `getEndpointForRepository`
  matches Enterprise Server accounts; migrating a ghe.com account moves its
  token; a failed user fetch at the end of sign-in is an error.

## Reading the repository

- **SHA-256 repositories work** (desktop assumes 40-character IDs).
- **Commit message diffs use a copy of the index** (an APFS clone through
  `GIT_INDEX_FILE`), so the repository's index is never written, staged
  changes survive, and it works while another process holds `index.lock`.
- **Paths compare exactly,** so paths differing only in Unicode
  normalization stay apart.
- **Kept as desktop:** `getGitDescription` reads `<path>/.git/description`,
  so it's empty for linked worktrees and submodules.
- **Desktop bugs fixed:** `.gitignore` writes with `core.autocrlf` and
  `safecrlf`; `splitBuffer` skipping a delimiter's UTF-16 length; a binary
  rename breaking `getBinaryPaths`; missing `--no-ext-diff` on range diffs;
  pull request preview image diffs against the wrong base; uppercase image
  extensions; a detached rebase's `head-name` newline.

## Writing to the repository

- **Discarding is safer than desktop's:** a copy's source keeps its changes;
  a rename's old path isn't overwritten when an untracked file is there; a
  Trash failure partway finishes what's in the Trash before offering the
  rest; discarding lines is refused if the file changed since its diff was
  shown. Discard All always confirms.
- **A conflicted stash pop keeps the entry:** `git stash pop --quiet` exits 1
  with nothing on stderr, which desktop took for success, dropping the
  entry. A conflicted restore's entry is dropped once its files are
  resolved with its changes kept.
- **Revert conflicts are recognized** (`error: could not revert`; dugite's
  pattern matches only old git's hint).
- **Finishing a conflicted merge, a squash merge, a rebase, cherry-pick,
  and revert intercept their hooks,** as a commit does; desktop ran them
  without the login shell's environment. Abort on a cherry-pick or revert's
  hook rolls back as git's other errors do.
- **Three refusals to rebase that desktop shows raw are mapped:** staged
  changes (`RebaseWithStagedChanges`, also with unstaged ones, which
  desktop's `RebaseWithLocalChanges` misses) offer Stash Changes and
  Continue as unstaged changes do; a rebase already in progress
  (`RebaseAlreadyInProgress`, git's `rebase-merge` or `rebase-apply`
  directory) and a stopped `git am` (`ApplyingPatchesInProgress`) say what
  to finish first.
- **A squash merge with nothing to commit is up to date** (desktop failed
  with "There are no changes to commit"). Aborting one runs `git reset
  --merge` (desktop committed, then `reset --hard`, discarding edits in
  files the merge never touched).
- **No `--ff` option,** as desktop: the user's `merge.ff` applies.
- **A merge can be committed with your own message:** the commit form shows
  git's message (`SQUASH_MSG`, then `MERGE_MSG`) with Commit Merge, enabled
  once nothing is left to resolve. Unchanged, it is git's `--no-edit`
  commit; edited, it is committed as written. The user's draft comes back
  afterwards.
- **Manual conflict resolutions belong to one operation** (desktop's carried
  over to the next).
- **Cherry-pick:** a failure aborts what git left and returns to the branch
  it started on; conflicts git doesn't name (rename/delete) wait for the
  user; an empty resolution mid-sequence continues with the rest (desktop
  stopped and reported success).
- **Operations refuse to start over one git began since the last refresh.**
- **Squash messages ride in the todo list** (`fixup`, then `fixup -C` with a
  commit made to carry the message), so no editor runs, `#` lines survive,
  and the message survives conflicts. Interactive rebases keep commits that
  become empty; a squash whose changes cancel out is refused and the branch
  restored. Squash and reorder throw git's errors after aborting the rebase
  they started.
- **Conflict detection doesn't depend on git's hints** (rebase forces
  `advice.mergeConflict=true` and clears `GIT_ADVICE`; so does pull, whose
  stopped rebase otherwise read as a merge). No editor is ever launched.
  Continuing strips git's comments when `commit.cleanup` would keep them.
- **Interrupted rebases are taken over:** one stopped between commits
  shows as interrupted, to continue or abort, and so does one killed while
  finishing, which Continue completes with git's own `--continue` (notes
  and a killed `post-rewrite` hook may then run a second time). A rebase
  that fails other than on conflicts is aborted.
- **A rebase's leftover state** (a state directory Espalier can't continue
  or abort) offers Clear Old Rebase and Continue wherever git or Espalier
  refuses an operation over it; desktop showed git's error. Clearing runs
  `git rebase --quit` and deletes the `REBASE_HEAD` it leaves: HEAD, the
  index, and the working tree stay as they are, and an autostash goes to
  the stash list. A rebase stopped on conflicts or interrupted between
  commits keeps its refusal.
- **`REBASE_HEAD` alone is no rebase,** as git 2.53 treats it: Espalier
  reads a rebase from its state directory only, so nothing is refused over
  it.
- **Desktop bugs fixed:** `createDesktopStashEntry` on exit code 1;
  `stashEntryCount` one short; `testForInvalidChars`'s stateful regex;
  `parseCommitSHA` on a first commit or detached HEAD; `tipEquals` ignoring
  branch names; `determineMergeability` reporting a clean merge when git
  can't merge; cherry-pick's `-m 1` as one argument; squash dropping `#`
  lines and losing its message after conflicts; `--continue`/`--skip` with
  `--no-verify`; "up to date" missed with `rebase.autoStash`.

## Network

- **Proxies are read and applied as Chromium does on macOS,** written as
  the PAC string it reports and parsed with desktop's `parsePACString`.
  Differences: a PAC file's `SOCKS` is SOCKS5, and `HTTPS`, `SOCKS4`,
  `SOCKS5`, and bracketed IPv6 answers are dropped (CFNetwork's reading); a
  script with a syntax error answers direct instead of falling back to the
  manual proxies; a PAC script in the settings (`ProxyAutoConfigJavaScript`,
  set by profiles) runs, where Chromium ignores it; a proxy port outside
  1–65535 drops the proxy, where Chromium truncates it; a PAC file over
  http(s) is fetched by Espalier and kept 5 minutes by URL, where Chromium
  keeps it until its next poll; a PAC file gets 10 s.
- **The clone destination check covers the account's real home directory,**
  not only `HOME`.
- **Desktop bugs fixed:** git 2.53's "Updating files" progress title
  (checkout progress never moved); the revert parser's 0/0 percentages; a
  failed LFS progress file made git-lfs write a file named `null` into the
  repository; `tailByLine` splitting lines across reads; `pull` dropping its
  hook and output callbacks; `isTrackedByLFS` lacking `--`.

## Trampoline: credentials, SSH, and the hooks proxy

- **One Foundation-only helper** is the credential helper, the SSH askpass
  program, and the hooks proxy, talking to one server per launch over a
  Unix socket in a private directory (0700, socket 0600, peers checked with
  `getpeereid`). Each git invocation gets its own token; revoking it closes
  its connections and cancels its prompts.
- **The credential helper is set by absolute path** through
  `GIT_CONFIG_PARAMETERS`, so nothing is added to the bundled git and
  filters such as Git LFS see it. External credential helper mode runs the
  bundled Git Credential Manager.
- **SSH uses `SSH_ASKPASS_REQUIRE=force`,** so ssh asks through the app even
  when it was started from a terminal. The host key prompt parser accepts
  OpenSSH 10's format.
- **github.com host keys are trusted automatically** only for GitHub's
  current published fingerprints (desktop trusted only the RSA key GitHub
  revoked in 2023).
- **SSH secrets are stored when the operation succeeds,** so a mistyped
  passphrase can be corrected (desktop stored them at once).

## Editors and shells

- **Desktop bugs fixed:** `%TARGET_PATH%` expands literally (desktop's
  `replaceAll` read `$&` in paths as a pattern); symbolic links are
  validated by their target; `findShellOrDefault` returns nil rather than
  crashing.

## Preferences and integrations

- **Code text size** (`diff-code-text-size`) steps through desktop's zoom
  factors; `diff-wrap-lines` and `ai-features-enabled` default to on.
- **The design theme, its color and background tint, the app font, and
  the code font** are Espalier's own settings (`design-theme`, one
  `design-theme-color-<theme>` and one `design-theme-background-<theme>`
  per theme, `app-font`, `code-font`); an unknown value, or another
  theme's color, reads as the default.
- **The appearance** is Settings ▸ Appearance's System, Light, or Dark (`theme`,
  desktop's values; System by default).
- **No command works through an open sheet.**
- **Desktop bugs fixed:** Git LFS 3's "warning: the … attribute" (dugite's
  pattern missed it, so mismatched global filters were never offered an
  update); Settings could write an empty `user.name` or `user.email`.

## AIKit

- **Prompts are desktop's, byte for byte,** except that the commit prompt's
  attribution says "AI".
- **Providers:** OpenAI-compatible Chat Completions (default) and Responses
  (`store: false`), Azure (deployment URLs or the v1 routes), and Anthropic
  Messages (adaptive thinking and effort for current Claude models, budgets
  for older ones).
- **Safety:** base URLs are validated with Foundation's parser (what
  `URLSession` uses), so `http://localhost\@evil.com` can't pass as local;
  `http://` only for local hosts; redirects are refused so credentials never
  follow one; the session is ephemeral; credentials print redacted.
- **A provider's API key or bearer token is saved trimmed** (desktop saves
  it as typed), so a key pasted with a line break works; a blank one counts
  as none.
- **No silent fallback to another model:** a selection resolves only if it is
  valid or exactly one model is configured; otherwise the app asks.
- **Repository instructions** (`.github/copilot-instructions.md`) go in the
  system prompt, capped at 32k characters.
- **Timeouts and retries:** one deadline per call (60 s for commit messages,
  600 s for conflicts, or the provider's own), shared by every attempt.
  Retries follow the OpenAI and Anthropic SDKs: at most twice, for 408, 409,
  429, 5xx, and connection failures, honoring `x-should-retry` and
  `Retry-After`; only before a stream starts.
- **Conflict markers:** a file with a marker outside its blocks is skipped,
  and a reassembled file that still has one fails, so no file with markers
  is reported resolved.
- **Consent replaces the disclaimer:** before a feature's first request to a
  provider host, the disclosure is shown and consent kept, revocable in
  Settings. Always use AI starts a round only in the selected repository,
  with consent and an unambiguous model.
- **Desktop bugs fixed:** AI resolutions are staged as literal paths (a path
  like `src/[id].ts` also staged `src/i.ts`) and never overwrite files
  changed since the round; successful chunks are kept and failed files can
  be retried alone; later batches stop after an auth, quota, rate-limit, or
  network error; a rebase's conflicts get commit context.
- **Dropped with Copilot:** built-in models, the "auto" default, quota and
  billing codes, per-account selections.

## Edge states

- **Leaving commits behind asks.** Checking out from a detached HEAD asks
  "Leave N Commits Behind?" when HEAD has commits no branch, tag, or remote
  branch has and the target doesn't contain (desktop switched silently).
- **`git am` and bisect are shown:** a stopped `git am` or a bisect takes
  the operation panel's place, says Espalier can't continue or abort it,
  and offers the commands and Open in Terminal (desktop didn't notice).
- **No partial edits that can't round-trip:** lines of a diff that isn't
  UTF-8, or that a `diff=` driver's textconv converts, can't be committed
  or discarded alone; the whole file can (desktop corrupted such commits).
- **Literal pathspecs:** every path passed as a pathspec gets `:(literal)`,
  so git matches exactly that file. Desktop passed paths as they were:
  discarding `a*.txt` overwrote `ab.txt`'s changes, and `:!x` named every
  other file. A prefix rather than `GIT_LITERAL_PATHSPECS`, which hooks and
  submodule commands would inherit.
- **Ignore rules name only their file:** backslashes and trailing spaces are
  escaped, names with line breaks are refused, and "Ignore All .ext Files"
  escapes the extension (desktop's `*.t[x]t` ignored every `.txt` file).
- **Restoring a stash with files in the way restores nothing,** and lists
  them; desktop's partial restore of an `--include-untracked` entry would
  apply the rest twice on a retry.
- **Discard and Copy Path act on Changes only while it has keyboard focus:**
  ⌘⌫ typed in a popover's field discarded the selected files when discard
  confirmation was off.
- **Discard confirmations:** Discard All Changes… and several files always
  ask; only the one-file question offers "Do not show this message again".
- **Switch Branch asks about an existing stash once:** when leaving changes
  would replace the branch's stash, the question carries that warning
  (desktop asked "Overwrite Stash?" again).
- **Stash Changes and Continue** stashes, then runs the operation, as
  desktop's flow did. Rebase honors `rebase.autoStash`. The branch pruner
  keeps branches being rebased in any worktree.
- **Status keeps desktop's arguments,** `--no-optional-locks` included:
  taking optional locks would mean taking `index.lock`. Nothing (fsmonitor,
  untracked cache) is turned on for the user.
- **Desktop bugs fixed:** a rebase with git's apply backend is read from
  `rebase-apply`; submodules that aren't checked out are listed, so
  discarding a deleted submodule folder restores it; a submodule with only
  uncommitted changes inside is never committed; patch headers quote paths
  with control characters, so partial commits of such files work; `git log`
  reads `--encoding=UTF-8`; New Branch on an unborn branch refuses clearly,
  and leaving an unborn branch never tries a stash. No unshallow, as
  desktop.

## History's simple mode

- **A branch's first-parent line,** the current branch's from HEAD in
  History and another branch's in its row's place, one commit after
  another, grouped by nothing and with no uncommitted-work row (my call).
  The style is app-wide, simple when nothing is stored.
- **The notice above the list** counts the commits the base (the branch
  Update from <branch> merges) has that this branch doesn't, and shows only
  when there are some and the two share a merge base; none on a detached
  HEAD, an unborn branch, or the base itself.
- **The branch as one line** (my call): a rail in the branch's track color
  that takes the base's color from the commit where the branch started, so
  where the branch began shows without a heading. A merge's stub takes the
  merged branch's color.
- **Unpushed marks:** a commit the upstream doesn't have; on an unpublished
  branch, one no remote has; with no remote, none.
- **A merge is one row** naming the branch and pull request from the
  messages GitHub, git, GitLab, Bitbucket, and Azure DevOps write. It
  expands to the commits it brought in (at most 1,000; the rest through
  Graph). Go to Commit finds a commit inside a merge and expands it.

## The look

`docs/DESIGN.md` is the look; these are the decisions behind it.

- **The flat window is a `NavigationSplitView`,** so collapsing the
  sidebar, full screen, the traffic lights, and toolbar customization work
  as AppKit makes them; its content is opaque over macOS's glass.
- **Tokens have light, dark, and Increase Contrast values.** Status letters
  and diff markers keep 4.5:1 contrast.
- **The toolbar's search capsule shows ⌥⌘F,** the real Search shortcut (⌘F is
  Find).
- **The sync button holds still while a push, pull, or fetch runs**
  (my call). It keeps its title, color, and count, with the arc in its symbol's place,
  and takes no clicks; what runs and git's step are its tooltip and what
  VoiceOver hears. Desktop retitled it at every step, which moved the
  button and "Fetched just now". An operation the button didn't offer
  shows that action instead. The progress lasts until the refresh after
  the operation has loaded, so the button goes straight to the new state.
- **Branch colors:** every local branch other than the current and default
  ones takes the palette entry its name hashes to, or the next free one;
  remote branches take their local branch's color. The sidebar dot, the
  tag, and the line agree. Creating or deleting a branch can recolor a
  later-named one.
- **A commit's details show its tags, not branches** (my call; the rows show
  branches), and keep the "CHANGED FILES" label (my call).
- **The "CHANGED FILES" label is always whole** (my call): the lines added
  and removed beside it show only when the column has room for them.
- **The diff, the file lists, and History's lists don't bounce** past
  their edges (my call).
- **No focus ring over a selection** (my call): History's commit and file
  rows, and the diff's line cursor, show only their accent tint, focused or
  not.
- **Every control's focus ring is Espalier's,** shown with keyboard
  navigation on (a field's always): capsules, symbol and bare buttons, menu
  buttons, pop-ups, steppers, switches, checkboxes, choice lists, the
  segmented control, fields, links, and the slider. A list of choices is
  one stop, ringing its chosen row or mark.
- **Links are the accent, deepened to read as text** (`Palette.link`, 4.5:1;
  6:1 under Increase Contrast). Links in text underline while the pointer
  is anywhere on their text: a text's links can't each track the pointer.
- **The slider's arrows step 1% of its range,** Page Up and Page Down 10%,
  Home and End to the ends. Desktop's range inputs stepped 0.1%, too fine
  to see.
- **A branch folder's whole row opens and closes it,** not only its
  chevron.
- **A drag of commits is one dragging item** carrying them all, so its
  image is Espalier's stack with its own count, not the system's badge.
- **The commit message card shows which field has focus with its own
  tint** (my call): a soft accent filling the summary's or the
  description's whole part of the card, edge to edge, hidden in an
  inactive window and while the fields are read-only. A hairline divides
  the summary from the description.
- **The description scrolls only when its text is taller than it shows**
  (my call): a shorter text, or the placeholder, holds still under a scroll
  instead of bouncing.
- **Every list's rows draw their own selection** (my call), in the row's
  rounded shape, focused or not.
- **The insertion point is the accent,** as the selection is: it's where
  the user's own changes go.
- **Four corner radii:** 5 for checkboxes and key caps, 9 for rows, 14 for
  cards, 22 for sheets and popovers.
- **A card in a pane has a ring and no shadow;** only what floats casts
  one.
- **Type sizes are the system's** (10, 11, 12, 13, 15); the mono's roles in
  fixed-height capsules keep fixed sizes.
- **A disabled control fades to 45%.**
- **Every checkbox, pop-up, switch, and button is Espalier's,** sheets and
  forms included.
- **Password fields keep macOS's dots and caps-lock indicator** (my call),
  in Espalier's capsule.
- **Menus are Espalier's card,** in a panel of their own that can reach
  past the window. A pull-down's and a pop-up's open below their button (a
  pop-up's at least as wide as its capsule, not over it); a context menu's
  at the pointer. A click outside closes a menu and does nothing else, but
  a right-click on another view with a context menu opens that menu. A
  menu closes when its window moves, resizes, or closes, and when Espalier
  goes to the background. The window keeps its focus while one is open.
- **Text keeps AppKit's context menu** (my call), in every field and
  text view, with Look Up, Translate, Services, Writing Tools, and the
  rest; the commit message's fields put their own items first.
- **Completions show in Espalier's suggestion list** (the commit message,
  the co-authors field, and Add Worktree's Branch Name): the menu card
  under the word being completed, its text lined up with the word's, or
  under the field, as wide as it. ↑ and ↓ move, Return or Tab accepts,
  Escape closes, typing goes on filtering, and a click accepts; focus stays
  in the text. A login just put in the co-authors field shows no list
  again until more is typed.
- **A context menu's row shows a ring in the accent** while its menu is
  open, in the SwiftUI lists and the AppKit tables alike; the menu acts on the selection when that row is in it, else on the
  row alone, as desktop's. The diff's lines show none: its menus act on a
  line's changes or on the text.
- **Popovers are Espalier's card, with no arrow:** centered beside the
  control, a small gap away, on the other
  side when there's no room, in a panel of their own that can reach past
  the window and floats above a sheet's card. A click outside closes one
  and does nothing else, a click on its control included; so do Escape,
  Espalier going to the background, the menu bar opening, and the window
  moving, resizing, or closing. Menus opened in a popover come first.
- **A popover takes the keys when it has a field, the keyboard opened it,
  or VoiceOver runs;** opened with a click, one of text and buttons leaves
  the window focused, and a click on a field in it moves focus there.
  Closing gives focus back to the window.
- **The menus act on the main window while its popover has the keys;** a
  sheet's popover leaves them off, as the sheet does.
- **⌘T and ⌘B close their popovers while they're open,** as desktop's
  foldouts toggle.
- **Tooltips are Espalier's card,** in a panel of their own; Espalier
  sets no system tooltips, and the system's own windows (the open and save
  panels, Quick Look) keep theirs. The card takes a row's radius, 9: a
  card's 14 is nearly round on one line. One shows once the pointer rests
  0.8 s (desktop's waits 0.4 s), the next after 0.1 s while one has shown
  in the last second. A click, a key press, or a scroll hides it until the
  pointer moves off the view. VoiceOver hears a tooltip as the view's hint
  (an AppKit view's help). They show for the pointer only; desktop also
  shows some for keyboard focus.
- **No expansion tooltips:** rows that cut a name or path off have it in
  their tooltip, shown whether or not it's cut off; desktop shows branch,
  pull request, check, worktree, and repository names only when they're
  cut off.
- **A stash's unavailable Restore says why under its title.**
- **Changes' rows show lines added and removed against HEAD** (desktop has
  none), staged and unstaged together; binary files, submodules, and
  conflicted files show none, and none load past 1,000 files.
- **The Changes column stays beside the no-changes card,** because amending
  and the Stashed Changes row need it.
- **A toast's Undo answers ⌘Z** while it shows; typing since then undoes
  first.
- **Settings is Espalier's own window** (my call).
- **Git Credential Manager's description is Espalier's own;** desktop's
  "experimental" was a caution about its own integration.
- **Progress is Espalier's own** (my call): the arc and the capsule bar,
  everywhere. Both are neutral gray,
  since color is only for selection, branches, and status, and stand still
  under Reduce Motion.
- **The operation panel shows a running operation only past 300 ms,** so a
  fast one never flashes; a commit clicked meanwhile is refused as busy.
- **Sidebar sections draw their own Show/Hide chevron,** just before the
  header's buttons: the list's own takes the header's trailing edge, so
  hovering the plus would move it.
- **Switching repositories leaves the sidebar's sections in place**
  (my call): a repository that hasn't loaded has no branches, tags, or pull
  requests yet, so Branches would vanish and come back, moving the row just
  clicked. The sections keep the previous repository's rows, which can't
  be chosen meanwhile, until the selected one has loaded (at most 1 s),
  then change in one step.

## The app shell

- **File ▸ Close is Espalier's own** (⌘W), without AppKit's hidden Close All
  (⌥⌘W), which would take Show Worktrees' shortcut. ⌘J and ⌥⌘F run in the main
  window whichever menu item holds them.
- **⌃⇥ and ⇧⌃⇥ go between Changes and History** (desktop's Ctrl+Tab), as
  View ▸ Next Place and Previous Place. From any other place, ⌃⇥ shows
  Changes and ⇧⌃⇥ History (desktop has only the two tabs, and ignores
  Shift). Both run before a text view or list can take them to move focus.
- **A click away from a text field ends its editing** (my call), as in
  desktop's web page: AppKit keeps the commit message and the toolbar
  search focused after a click on the background, a label, or a button. A
  click anywhere but the focused field and the area that belongs to it
  unfocuses it; a Control-click, which opens a context menu, leaves it.
- **With the main window minimized, menus act on it and bring it back;**
  while Settings or About is key they stay off.
- **Alerts and sheets shown while Espalier is inactive** beep and bounce the
  Dock icon.
- **Sheets and alerts are cards in the window,** centered as desktop
  centers its dialogs, over a scrim that dims the whole window in its own
  corners. A card opened over another stacks above it and dims it too.
  The window behind takes no clicks, its title bar and window buttons
  included; Minimize, Zoom, and Full Screen in the menus still act on it.
- **A card taller than its window scrolls inside the card,** 40 points from
  the window's edges.
- **An alert's default button is the prominent capsule, destructive or
  not,** as in the compact confirmation sheets. Return presses it; Escape
  and ⌘. press the cancel button, or an alert's only button, and do
  nothing in an alert whose buttons all act.
- **An alert with no window to cover** (the quit guard while the main
  window is hidden or minimized) is its card alone, centered on the active
  screen, and holds the app until answered.
- **VoiceOver can't reach a window behind a sheet or an alert.**
- **A link that needs a clone waits** for the sheets and alerts in front of
  it and for the welcome flow; links queue in order.
- **`espalier` takes options anywhere,** in minimist's forms; `--` ends them.
- **An organization's OAuth App access restrictions** show as "Organization
  Access Restricted" with Request Access on GitHub (not in desktop).
- **A signed-out account has Remove.**
- **The Git LFS filters alert's Edit Global Git Config… closes the alert**
  and opens the file (desktop's link left its dialog open).
- **Commit messages render emoji and links,** as desktop's text-token
  parser does: `:shortcode:` emoji (GitHub's custom ones stay text), URLs,
  and in GitHub repositories `#123` and `@mentions`. An issue reference
  with no known web address stays text (desktop linked "null/issues/n").
- **Compare to Branch** shows each branch's behind and ahead counts and date,
  counted only for rows on screen, without fork remotes' branches.
- **The toolbar search filters a pull request's files** in its place, as it
  does Changes' and a stash's, with No Matching Files when none match.

## Accessibility

- **VoiceOver hears how many items a filter matches** ("No results", "1
  result", "12 results") once its text has been still for 1 s: the branch
  picker, the repository popover, the sidebar filter, the toolbar search,
  Clone's list, and find in the diff. Moving between the diff's matches
  says which is current, as desktop's does ("Result 2 of 5 for "tip"").
- **A commit is announced** "Committing" (or "Amending last commit") once
  git runs, not on the button press, so a cancelled question says nothing;
  then "Committed to main" ("Committed" on a detached HEAD, "Amended last
  commit"). A failure speaks through its alert or sheet.
- **"Push complete", "Fetch complete", and "Pull complete" only when one the
  user started succeeds.** Desktop announced "push complete" whenever the
  progress ended, a failure included, and a background fetch said "fetch
  complete".
- **⇧F10 opens a list's context menu** at its selected row, in Changes'
  files, History, a commit's files, and the sidebar, and the diff's text
  menu at its line cursor; VoiceOver's Show Menu (VO-⇧-M) opens the same
  menu, on a diff line too. No menu item holds it, so Keyboard Shortcuts
  lists it under Lists.
- **A choice's description is its VoiceOver hint** in radio lists and
  choice cards.
- **Setting AXSelected on a Changes file's cell selects that file alone,**
  as a click does; setting it to false does nothing.

## Copy

Desktop's wording stays where it is true for Espalier and reads well. The
voice:

- No first person or apology ("We found…", "Sorry, I can't find…"), no
  "Please"; contractions.
- Confirmation titles ask the question ("Discard Changes?", "Force Push?"),
  and buttons name the action ("Force Push", "Undo Anyway", "Delete Anyway",
  "Sign In…"/"Not Now").
- Error alert titles in title case ("Clone Failed"); toasts without
  "Successfully".
- macOS words: folder, app, "on Your Mac", the Trash, "check out" as a verb,
  lowercase "internet"; Settings named by pane ("Settings ▸ Integrations");
  commands that open a sheet end in an ellipsis.
- GitHub's settings are quoted as GitHub labels them ("Keep my email
  addresses private").
- Left as they are: git's own output, strings matched against git's or
  GitHub's output, AI prompts, logs, GitHub's push-protection bypass
  wording, and alerts' "Do not show this message again" (AppKit's
  wording).
