# Changelog

All notable changes to Espalier are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

At release time, `scripts/publish-release.sh` puts the section for the
version being shipped in the appcast, and Espalier's update window shows it,
so keep entries user-facing and write them for someone deciding whether to
install the update.

## [Unreleased]

<!-- Add entries here, under [Unreleased]. At release, leave this heading and
     comment in place and insert the new "## [x.y] - YYYY-MM-DD" heading just
     below, so the entries fall under it; then repoint the [Unreleased] link
     and add a compare-link at the bottom. -->

## [1.4] - 2026-10-24

### Added

- Commit with AI. The commit form's Manual | Assisted switch, remembered for each repository, has the AI provider you use for commit messages split the selected changes into commits by what they do, then makes them one at a time, running your hooks. You can cancel it partway, a run that fails or is canceled takes back only the commits it made, and your files are never rewritten. Push After Committing pushes the new commits.
- Sign in to more than one GitHub account on the same server, and choose the account each repository uses in Clone, Publish, Repository Settings ▸ Remote, or the repository's Account menu. Pull requests, checks, notifications, and HTTPS pushes and pulls use that account. Repositories you already have keep the account they used.
- A conflicted file in Changes shows each conflict as its two sides, headed by their branches' names. A side's button, such as Use main's Version, keeps that side of the conflict, and Undo puts the file back.
- Espalier moves as things change: menus, sheets, the sidebar, Changes, History, and the diff ease and fade, and counts roll, instead of jumping. With Reduce Motion on, they change at once.

### Changed

- Merging and rebasing start from the branch. Merge into Current Branch…, Squash and Merge into Current Branch…, and Rebase Current Branch… pick a branch and show its Ahead commits with the method chosen, ready to start. They replace the Integrate sheet.
- A branch's header says what it's compared with ("fix/crash compared with main") and lines up with the list.
- Branches in the sidebar starts with the default branch, then your recent branches, with Other Branches and Remote Branches below. A collapsed section shows how many items it holds, and the branch picker groups branches the same way.
- During a merge, rebase, or cherry-pick, the operation panel shows Commit Merge or Continue from the start, enabled once every file is resolved, and counts the files resolved.
- A rebase names both its sides by their branches, also when it was started outside Espalier.
- Espalier now includes Git 2.56.0, Git LFS 3.8.1, and Git Credential Manager 2.9.1.

### Fixed

- Checking out a branch whose worktree's folder was deleted no longer fails: Espalier offers to remove the missing worktree and check the branch out here. The worktree list marks a missing worktree, instead of switching to a folder that isn't there.

## [1.3] - 2026-10-22

### Added

- Create pull requests in Espalier. Create Pull Request… opens a sheet with the base branch, a title, a description filled in from the repository's pull request template, and a draft option, instead of GitHub's form in the browser.
- Stop a push, pull, fetch, or publish that hangs: after 10 seconds without progress, the sync button offers Stop. A pull can be stopped only while it fetches, so nothing is left half merged or rebased.
- Undo a revert: reverting a commit selects the new commit and shows a notice with Undo, and Edit ▸ Undo Revert takes it back too.
- Menu items and buttons that can't run say why in their tooltip, and asking for one anyway, such as checking out a branch during a merge, shows the reason.
- ⌘↩ presses Commit Merge or Continue when it's enabled.

### Changed

- A link that checks out a branch or pull request in a repository you already have asks first, naming the branch, the pull request, and any remote it adds for a fork.
- Initialize Git LFS asks before replacing hooks the repository already has, and moves the old hooks to the Trash.
- A new branch can't take an existing tag's name, and a new tag can't take a branch's.
- Squash and reorder no longer offer drops below a merge, and Squash… and Reorder name the merge in the way before anything starts.
- Pull says up front that it can't run while a merge, rebase, or cherry-pick is in progress.
- Commit menu items act only where they apply: Cherry-pick…, Squash…, and Copy SHA where commits show, and Revert on the checked-out branch's commits.
- When the selected files leave Changes after a discard, commit, or Ignore, the file in their place is selected, so the list stays where it was instead of going back to the top.
- Clone and Add Worktree read a leading ~ in Local Path as your home folder, and point out a path that isn't a full path before you submit it.
- When the selected worktree's folder is removed, a notice says so and names what the window shows instead.
- Ignore File tells you when a file it ignored is still tracked, so its changes still show.
- Notices that aren't a success show a gray symbol instead of a green one.

### Fixed

- The window no longer flashes empty as Espalier opens.
- Discarding a deleted file no longer deletes an untracked folder or file now at its path.
- Discarding changes permanently removes staged new files and renamed files' new paths, instead of leaving them behind.
- Merge, rebase, push, and new branches use the branch when a tag has the same name.
- A build or tool writing into folders git ignores no longer keeps Espalier refreshing the repository.
- Very large diffs no longer load in full before showing as too large.
- Stash Changes and Continue is no longer offered on a detached HEAD, where it did nothing.
- Pull, Push, and Fetch could wait for a later full refresh before finishing.
- A token in a remote's address no longer appears in Espalier's log.
- Move to Applications handles an app name with accented characters.
- While a rebase stops on conflicts, discarding several selected files or using Edit ▸ Delete no longer discards tracked files; only untracked files can be discarded then, as in a file's menu.
- A submodule that can't be committed no longer counts toward the commit: the file count, the Commit button, and Include All leave it out.
- Cancelling Clone while it looks up the repository no longer starts the clone anyway.
- A link or command-line open that Espalier can't act on, such as a branch that doesn't exist or a pull request whose fork was deleted, says why instead of stopping silently.
- Go ▸ Back, Forward, First Parent, Second Parent, and Child work in History's simple list, not just the graph, and Back and Forward stay within the repository you're in.
- ⌘F in History focuses the commit search.
- The toolbar search clears when you switch repositories.
- Opening a file from a stash or a commit that isn't on disk beeps, instead of trying to open a missing path.
- VoiceOver no longer announces "Pull complete" for a pull that stops on conflicts.

## [1.2.1] - 2026-10-18

### Changed

- The commit message card shows a focus ring while you type in it, as the filter fields do.
- As you filter one of the sidebar icons' popovers, it grows and shrinks from the bottom, so the filter field stays where it is.

### Fixed

- A sidebar icon's popover opens in place, instead of bouncing as it appears.
- Clicking just beside a popover, such as on the sidebar icon that opened it, now closes it, instead of doing nothing.
- A popover now closes on Escape or a click outside it while one of its tooltips shows.
- A sidebar icon stays highlighted while its popover is open.
- The sidebar icons' popovers no longer scroll when everything in them fits.
- Lists, popovers, menus, sheets, and Settings no longer bounce past their ends when you scroll them.

## [1.2] - 2026-10-17

### Changed

- The repository list marks each repository with a symbol for its kind: a folder for one on GitHub, a lock for a private one, a branch for a fork, and a computer for one that isn't on GitHub. They replace the letter badges.
- Clone now warns about a folder whose name ends in .app, which macOS treats as an app, instead of refusing it.

### Fixed

- Opening a repository link or a folder in Espalier now brings it to the front, instead of leaving it behind other windows.
- Clone no longer suggests a folder it can't use for a repository whose name ends in .app: for getworkouts.app, it suggests getworkouts-app.
- A repository listed both in Recent and under its owner is now highlighted in one place at a time, and the arrow keys move through both.
- The repository list, the branch list, and sheets no longer bounce sideways when you swipe across them.

## [1.1] - 2026-10-17

### Fixed

- Answering whether Espalier should check for updates automatically no longer quits it.
- Scrolling a pane in Settings no longer draws its content over the pane's name.
- Clicking below the files in Changes now leaves no file selected, instead of selecting the first file again a moment later.
- A tooltip showing as Mission Control opens no longer stretches the window's highlight past its bottom edge.

## [1.0] - 2026-10-17

The first release.

[Unreleased]: https://github.com/abdeen-labs/espalier/compare/v1.4...HEAD
[1.4]: https://github.com/abdeen-labs/espalier/compare/v1.3...v1.4
[1.3]: https://github.com/abdeen-labs/espalier/compare/v1.2.1...v1.3
[1.2.1]: https://github.com/abdeen-labs/espalier/compare/v1.2...v1.2.1
[1.2]: https://github.com/abdeen-labs/espalier/compare/v1.1...v1.2
[1.1]: https://github.com/abdeen-labs/espalier/compare/v1.0...v1.1
[1.0]: https://github.com/abdeen-labs/espalier/tree/v1.0
