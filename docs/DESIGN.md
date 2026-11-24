# Espalier's look

Playful, creamy, and intuitive: cream cards on oat, warm espresso ink,
round type, and soft controls you want to press. New UI follows it. The
values are `DesignSystem`'s tokens. This describes Default, the theme a new
install opens in, in Blueberry; Frost changes what its tokens say
(Themes, below).

## Identity

- **The mark is a peach** with its stem and leaf, on cream: the app's icon
  (`Espalier/AppIcon.icon`), and `BrandMark`, which draws the same peach in
  the app.
- **The mark shows on Welcome and About,** hanging from a trellis band (a
  wash of peach under a lattice), and nowhere else in the app.
- **The name** is set in the theme's text font at its heaviest, drawn tight
  (`Wordmark`); Welcome's heading is as heavy.

## Principles

- **Espalier draws its own UI.** Simple, clean, and modern, with
  personality: not elaborate, and not default controls with minimal
  touches. The system's own pieces (the window's chrome, Quick Look, the
  open and save panels) stay macOS's.
- **Soft objects, not lines.** The panes are cream cards floating on the
  oat backdrop; inside them, cards, pills, and space group things rather
  than rules. Soft shadows on things that float (menus, popovers,
  tooltips, sheets, alerts, toasts, the operation capsule).
- **Rounded and concentric.** Controls are capsules (buttons, the location
  control, search fields, segmented controls, chips); rows, cards, and
  sheets have generous rounded corners. What sits in a capsule's end is
  round and inset alike on every side (the location control's branch
  pill, a toast's badge and close button).
- **Tactile.** Capsule buttons stand on a lip, a deeper shade of their
  fill, inside the control's height, and sink onto it as they're pressed;
  checkboxes are chunky and pop as they're toggled.
- **What floats is a card:** menus, popovers, and tooltips with the
  floating ring and shadow; sheets and alerts centered in the window over a
  neutral scrim, led by a bold title. Toasts and the
  operation capsule are pillows with a round, soft badge that says what
  happened.
- **Selection is Espalier's own:** a selected row draws its tint in its
  rounded shape (a butter-yellow highlight, like a highlighter on
  paper): `selectableRow(isSelected:)` in a SwiftUI list, a row view's
  `drawSelection` in an AppKit table.
- **The focus ring is Espalier's:** an accent ring in the control's own
  shape (`FocusRing`).
- **Links are the accent** (`Palette.link`) in the text's own font,
  underlined while the pointer is on them.
- **Disclosure is a chevron** before the label, right while closed and
  down while open.
- **Text to copy** is `Text` that can be selected, or a pill that copies
  (a commit's SHA); multi-line text to edit is a `TextEditor` on the
  `field` fill or a card.
- **Every place has a color** (`PlaceIdentity`): Changes apricot, History
  teal, Branches blueberry, Tags honey, Stashes grape, Pull Requests plum,
  Worktrees leaf, Remotes slate. Only Settings' panes show as tiles, in
  its sidebar; elsewhere a symbol is plain, in secondary text or a status
  color. Changes' counts and its "in the commit" pill are the palette's
  accent.
- **Names are candy pills:** branches, tags, remotes, and counts are
  fully rounded pills in a tint of their color, the current branch's
  filled with the accent.
- **A file's status is a tile** in a tint of its color with its letter (A,
  M, D, R, C, U), bold, in the theme's code font.
- **Plain sentences:** "3 files changed", "All in the commit", "Push
  origin", "Fetched 2 minutes ago". A diff's hunk opens with git's own
  "@@" line, and a renamed file reads "old/path → new/path".
- **Pane headers are a bold title;** a commit opens with a header card.
  Empty states are a symbol on a soft box of their color, a bold title, a
  sentence, and the actions that help. A place's own state (a missing
  repository, no repository selected, a launch failure, a pull request
  that didn't load, nothing to commit, a clone on its way) has two fainter
  tiles tilted behind its box, each arranged its own way
  (`MessageTiles`).
- **The diff's changes are full-width bands,** and its included lines a
  band behind their numbers in the gutter, beside a bar.
- **Branch colors:** the current branch is the accent, the default branch
  teal; the others cycle through apricot, plum, grape, blue, and leaf,
  skipping those near the accent. A track keeps its color for its line of
  development.
- **Buttons come in three styles:** quiet, prominent (one per area), and
  secondary (Cancel in sheets, Undo). A prominent button that deletes or
  discards is red.
- **SF Symbols** for every icon; the theme's text font for text and its
  code font for what's monospaced. Pane titles are 15 and bold, commit titles 20 and bold.

## Themes, colors, and fonts

Settings ▸ Appearance picks a theme (Default or Frost), a palette, a
background tint, and the appearance, each apart from the others. The
theme is how the app looks, its fonts included; the
palette and the background are its colors, and every theme takes every
palette and background. Views use the tokens, which read the current look.

- **A palette** is an accent color and the colors made from it: links,
  the prominent fill, and selected items' tints. Each is a hue of its own:
  System (the Mac's accent color), Blueberry (the default) and Slate (made
  for Default), Iris (made for Frost), Lagoon, Plum, Tangerine, Magenta,
  and Volt, and White (white prominent fills under ink text; what's drawn in
  the accent is ink in light and white in dark). A theme's default branch and renamed colors give way to others
  beside an accent near their hue.

- **Default** is playful and creamy: cream cards floating on oat (cocoa
  on dark roast in dark), espresso text, the butter highlight for every
  selection, the palette's accent for the prominent action, focus, and
  links, raised pillow controls with bold titles, a thick graph with round
  dots, status colors from an orchard (leaf, tomato,
  honey, grape), and lists that fade out at an edge with more beyond it.
  Its text is Allo, at its roundest, and its code Maple Mono.
- **Frost** is quiet and precise: a glass window around one inset card,
  its panes clear and divided by hairlines; near-white and near-black
  surfaces; washes for lines, hover, selection, and fields; one neutral
  selection; ink for the prominent action; flat controls, small radii,
  and a fine graph. Its text is Geist, and its code Geist Mono. Where
  Default draws cards, pills, and tiles, Frost draws plainly
  (`Theme.current.style`): rows and headers split by hairlines, counts as
  text, small square status badges, monospaced branch and tag labels,
  compact rows, system-size semibold titles, and plain symbols in
  Settings' sidebar.
- **A background tint** (Neutral, Warm, Cool, Sage, Rose, Lavender) gives
  a theme's surfaces its hue in place of the theme's own, faint on white
  and stronger toward gray, each surface as light as before. Default's
  highlight is a highlighter in the tint's color on Cool (blue), Sage
  (green), Rose (pink), and Lavender (purple).

## Motion

Not every screen and element needs an animation. That doesn't mean
removing default animations, making the app feel dead, or dropping the
small touches that make the UI feel cared for. All motion goes through one
token, `Motion`.

- **Reduce Motion:** nothing animates, hover and press included. Models
  update at once; only drawing animates.
- **Controls** move as AppKit's controls do: hover fades, presses ease,
  and what floats fades in, settling toward its control, and fades out
  quicker.
- **What the user changes moves:** counts and a button's or pop-up's new
  title roll, bars and banners grow in while what's below moves, view
  switches crossfade, and rows animate in and out as a section opens and
  closes. Hover in lists fades, row by row.
- **The mark grows in** on Welcome and About: its stem draws out, then its
  leaf and the peach pop.
- **Work that runs moves:** the arc turns, the bar's segment sweeps, and
  the shimmer passes over a message being generated. The generated message
  fades in over half a second, settling long, its summary rising into
  place.
- **The trackpad taps** as a drag takes a new place to drop, and ticks as
  a dragged slider's knob reaches an end.
- **Instant:** selection and arrow-key browsing, and what follows them; a
  slider's knob, dragged or stepped; navigating between repositories and
  places, and the reload after a branch switch; typing-driven updates;
  enabled ↔ disabled; paging; ticking times.
