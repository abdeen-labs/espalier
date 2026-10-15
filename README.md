# Espalier

Espalier is a Git client for macOS. It brings the workflows of
[GitHub Desktop](https://github.com/desktop/desktop) to a Mac app written in
Swift, SwiftUI, and AppKit: changes and commits, history with a commit graph,
branches, merges and rebases, pull requests, and GitHub sign-in. It also
supports AI commit messages and merge conflict resolution through AI providers
you configure with your own keys.

Espalier is in early development. See [docs/PROGRESS.md](docs/PROGRESS.md).

## Requirements

- macOS 27 or later on Apple silicon
- Xcode 27 to build

## Building

Espalier bundles its own copy of Git (with Git LFS and Git Credential Manager)
from desktop's [dugite-native](https://github.com/desktop/dugite-native)
releases. It never uses the system's Git. Install the pinned build once:

```bash
scripts/fetch-git.sh
```

Then build the app in Xcode with the `Espalier` scheme, or from the command line:

```bash
xcodebuild -project Espalier.xcodeproj -scheme Espalier -configuration Debug -derivedDataPath DerivedData build
```

Run the tests from the package:

```bash
cd Packages/EspalierKit && swift test
```

## Credits

Espalier began as a port of [GitHub Desktop](https://github.com/desktop/desktop),
which is released under the MIT license, copyright GitHub, Inc. Desktop's test
suite and fixture repositories are the basis of many of Espalier's tests. The
bundled Git comes from [dugite-native](https://github.com/desktop/dugite-native).

Espalier is an independent project. It is not affiliated with, endorsed by, or
sponsored by GitHub, Inc. GitHub is a trademark of GitHub, Inc.

## License

Espalier is released by [Abdeen Labs](https://abdeen.dev) under the
[MIT license](LICENSE). Code and data from other projects keep their own
licenses, listed in [LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY).
