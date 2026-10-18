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

[Unreleased]: https://github.com/abdeen-labs/espalier/compare/v1.2...HEAD
[1.2]: https://github.com/abdeen-labs/espalier/compare/v1.1...v1.2
[1.1]: https://github.com/abdeen-labs/espalier/compare/v1.0...v1.1
[1.0]: https://github.com/abdeen-labs/espalier/tree/v1.0
