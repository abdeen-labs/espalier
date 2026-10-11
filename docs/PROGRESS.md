# Progress

What's left. Finished work is in git history and `docs/DECISIONS.md`.

Every feature is built, along with the visual redesign, motion, and the copy
pass.

## Left

1. **The running app on my Mac.** I'm checking it; the lead fixes what I
   find directly, without agents. Still to look at:
   - The flat window, the sidebar toggle, the trailing toolbar items'
     alignment, the toolbar customization palette, sidebar selection with
     focus, and Settings' titlebar (no band or flash; the window buttons
     level with the pane name).
   - Motion: the sync button's width while it crossfades and its spinner
     turning into the ring; the branch name fading in; Changes' row hover,
     rows departing and arriving, the footer's bars moving the list, the
     operation bar (and a fast rebase never showing it); the diff's
     expansion, Unified ↔ Split, the staging crossfade; Simple ↔ Graph, a
     merge's commits sliding out, the loading line after 300 ms, new
     commits sliding in; switching repositories with nothing animating; the
     Last Commit row and co-authors field growing in; copy buttons' checks
     (the submodule diff and push protection included), toasts, focus
     rings, the switch's knob, Settings' rows; everything instant with
     Reduce Motion on.
   - ⌘Z after a squash or cherry-pick toast; Return in the integrate sheet;
     no highlight flash when the sidebar first shows; `+10 −2` updating as
     files are saved, and its cost on a big repository; "Stopped at commit
     2 of 4" in a real rebase; the Remove Repository sheet, the Force Push
     alert, and the invalidated-token alert's Sign In….
   - The unsafe-repository view (launch with
     `GIT_TEST_ASSUME_DIFFERENT_OWNER=1` if git honors it from the app); a
     squash's Undo toast; that the unpushed arrows follow a reorder; branch
     badges loading as Other Branches scrolls; ⌘⌫ in a popover's field never
     discarding files; the stash alert.
   - Menus: no Close All under File with Option held; Show Worktrees on ⌥⌘W;
     ⌘J and ⌥⌘F in History (Debug ▸ Check Menu Shortcuts); a command from a
     minimized window brings it back; a fork's pull request link ends on
     `pr/N`; the sample notification's review sheet; the Dock bouncing for a
     failure while inactive.
   - Popovers: typing in the repository and branch filters as they open,
     and focus back in the window after; ⌘T and ⌘B and a click on the
     location control closing them; the repository popover's menus above
     it; the base branch picker over Preview Pull Request; the checks
     popover resizing as checks load; the arrival and leaving motion; the
     toolbar's popovers in full screen; VoiceOver moving in and back.
   - Signing: pinentry-mac's window and its Cancel; a rebase signed with a
     passphrase-protected SSH key asks once; 1Password's `op-ssh-sign`.
   - Accessibility: ⇧F10 in Changes, History, a commit's files, and the
     sidebar; VO-⇧-M on their rows; setting AXSelected on a Changes row (not
     its cell) in Accessibility Inspector; VoiceOver hearing a filter's
     count, a commit start and finish, and Push complete.
   - History's scrolling in a Release build (Debug ▸ History Scroll
     Benchmark: hitches at most 5 ms/s).
2. **My checks:** GitHub sign-in (github.com and Enterprise) and
   what follows it (pull requests, checks and Re-run, notifications, push
   protection, forks, and the mentionables and branch `push_control`
   preview endpoints, which may differ for a non-desktop OAuth app); an AI
   provider key (Azure's routes and `api-key` header, Anthropic's thinking
   options per model, OpenAI's unverified-organization fallback); installing
   the command line tool (writes `/usr/local/bin/espalier` behind an
   administrator prompt: ask first).
3. **Last, mine:** Sparkle, once the app is close to a release and with my
   feed and keys; Developer ID signing, notarization, and appcast hosting.
