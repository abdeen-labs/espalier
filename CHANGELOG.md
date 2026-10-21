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

### Added

- Create pull requests in Espalier. Create Pull Request… opens a sheet with the base branch, a title, a description filled in from the repository's pull request template, and a draft option, instead of GitHub's form in the browser.

### Changed

- A link that checks out a branch or pull request in a repository you already have asks first, naming the branch, the pull request, and any remote it adds for a fork.
- Initialize Git LFS asks before replacing hooks the repository already has, and moves the old hooks to the Trash.
- A new branch can't take an existing tag's name, and a new tag can't take a branch's.

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

[Unreleased]: https://github.com/abdeen-labs/espalier/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/abdeen-labs/espalier/compare/v1.2...v1.2.1
[1.2]: https://github.com/abdeen-labs/espalier/compare/v1.1...v1.2
[1.1]: https://github.com/abdeen-labs/espalier/compare/v1.0...v1.1
[1.0]: https://github.com/abdeen-labs/espalier/tree/v1.0
