# Releasing

How a release of Espalier is cut. Xcode builds, signs, and notarizes the
app; `scripts/publish-release.sh` packages and publishes it.

## How updates reach people

- Sparkle in Espalier checks `https://updates.abdeen.industries/espalier/appcast.xml`
  (Info.plist's `SUFeedURL`) once a day, after asking on the second launch,
  and on Espalier ▸ Check for Updates…. Only Release builds check.
- The update host (`abdeen/industries/updates`) answers `/espalier/<file>`
  with the bucket's object `espalier/<file>`. The bucket holds the appcast
  and every release's DMG, `espalier/Espalier-<version>.dmg`. The same DMG is
  the download for new users:
  `https://updates.abdeen.industries/espalier/Espalier-<version>.dmg`.
- Sparkle's EdDSA key signs the appcast (`SURequireSignedFeed`) and each DMG,
  and Espalier checks both against Info.plist's `SUPublicEDKey`, the DMG
  before unpacking it (`SUVerifyUpdateBeforeExtraction`). Once a release is
  out, `SUPublicEDKey` never changes: copies with it can't verify anything
  signed with another key.
- Gatekeeper's side is Apple's: Xcode signs the app with Developer ID,
  notarizes it, and staples the ticket. The DMG around it isn't notarized.

## One-time setup

1. **Developer ID Application certificate** in the login Keychain: Xcode ▸
   Settings ▸ Accounts ▸ the team ▸ Manage Certificates ▸ + ▸ Developer ID
   Application. When Xcode archives, `embed-git.sh` signs the bundled git
   with it; Xcode's export doesn't re-sign files under `Resources`, and a
   script can only sign with a certificate in the Keychain.
2. **Sparkle key**, under its own Keychain account. Sparkle's tools are in
   Xcode's DerivedData once Xcode has opened the project:
   `~/Library/Developer/Xcode/DerivedData/Espalier-*/SourcePackages/artifacts/sparkle/Sparkle/bin`.
   - `generate_keys --account espalier` creates the key and prints its public
     half. Put that in `Espalier/Info.plist` as `SUPublicEDKey` (a string) and
     commit it.
   - Back up the private key: `generate_keys --account espalier -x <file>`,
     keep the file's contents in your password manager, and delete the file.
     Without it, no update reaches installed copies again. On another Mac,
     `generate_keys --account espalier -f <file>` imports it.
3. **Bucket credentials** in the shell you release from, from the bucket's
   Credentials tab: `UPDATES_BUCKET`, `UPDATES_ACCESS_KEY_ID`,
   `UPDATES_SECRET_ACCESS_KEY`, and, when they differ from
   `https://t3.storageapi.dev` and `auto`, `UPDATES_ENDPOINT` and
   `UPDATES_REGION`.

## Cutting a release

1. **Release notes** go in `CHANGELOG.md` under `## [<version>] - <date>`,
   e.g. `## [1.0.1] - 2026-11-02`, written for the people updating: they're
   what the update window shows. `scripts/changelog.sh <version>` prints what
   will ship.
2. **Version**: raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the
   Espalier target's Debug and Release configurations (General ▸ Identity).
   The build number must be higher than every published one; Sparkle
   compares it.
3. **Commit and push** `main`.
4. **Archive**: Product ▸ Archive. The first time, macOS asks to let
   `codesign` use the Developer ID key: Always Allow.
5. **Export**: in the Organizer, Distribute App ▸ Direct Distribution. Xcode
   notarizes and staples the app. Put the exported `Espalier.app` at the
   checkout's root (it's ignored by git).
6. **Publish**: `scripts/publish-release.sh`. The first release runs with
   `FIRST_RELEASE=1`, since the feed has no appcast yet. `UPLOAD=0` stops
   after making `dist/Espalier-<version>.dmg` and the signed
   `dist/appcast.xml`, to look at them first.
7. **Check**: an installed older release finds the update with Check for
   Updates…, shows the notes, installs it, and relaunches.

## What the script checks

`publish-release.sh` stops before making anything when:

- the app's version isn't the project's, or it isn't notarized and stapled;
- the app's feed isn't Espalier's, or it has no public key;
- the checkout has changes, or HEAD isn't `origin/main`;
- the version's tag names another commit;
- the Keychain's Sparkle key isn't the app's;
- the build number isn't higher than every one in the feed.

It refuses to replace a published DMG with different contents, uploads the
DMG before the appcast, reads each back through the update host, and tags
`v<version>` last.

## When publishing stops partway

Fix the cause and run `scripts/publish-release.sh` again. The DMG in `dist/`
is reused while it holds the same app, a DMG already uploaded is kept when it
matches, the appcast's entry for the version is replaced, and the tag is
made at the end. A published DMG is never replaced: to ship a different
build, raise the version and archive again.
