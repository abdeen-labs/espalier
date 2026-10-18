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

## [1.1] - 2026-10-17

### Fixed

- Answering whether Espalier should check for updates automatically no longer quits it.
- Scrolling a pane in Settings no longer draws its content over the pane's name.
- Clicking below the files in Changes now leaves no file selected, instead of selecting the first file again a moment later.
- A tooltip showing as Mission Control opens no longer stretches the window's highlight past its bottom edge.

## [1.0] - 2026-10-17

The first release.

[Unreleased]: https://github.com/abdeen-labs/espalier/compare/v1.1...HEAD
[1.1]: https://github.com/abdeen-labs/espalier/compare/v1.0...v1.1
[1.0]: https://github.com/abdeen-labs/espalier/tree/v1.0
