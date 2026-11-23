# Espalier's look

Playful, creamy, and intuitive: cream cards on oat, warm espresso ink,
round type, and soft controls you want to press. New UI follows it. The
values are `DesignSystem`'s tokens. This describes Default, the theme a new
install opens in, in Blueberry, Allo, and Maple Mono; Islands changes what
its tokens say (Themes, below).

## Principles

- **Espalier draws its own UI.** Simple, clean, and modern, with
  personality: not elaborate, and not default controls with minimal
  touches. The system's own pieces (the window's chrome, Quick Look, the
  open and save panels) stay macOS's.
- **Soft.** Hairline dividers, and soft shadows on things that float
  (menus, popovers, tooltips, sheets, alerts, toasts, the operation
  capsule) and on the panes, cream cards floating on the oat backdrop.
- **Rounded.** Controls are capsules (buttons, the location control, search
  fields, segmented controls, chips); ref tags, rows, cards, and sheets have
  generous rounded corners.
- **Tactile.** Capsule buttons stand on a lip, a deeper shade of their
  fill, and sink onto it as they're pressed.
- **What floats is a card:** menus, popovers, and tooltips with the
  floating ring and shadow; sheets and alerts centered in the window over a
  neutral scrim.
- **Selection is Espalier's own:** a selected row draws its tint in its
  rounded shape (a butter-yellow highlight, like a highlighter on paper): `selectableRow(isSelected:)` in a SwiftUI
  list, a row view's `drawSelection` in an AppKit table.
- **The focus ring is Espalier's:** an accent ring in the control's own
  shape (`FocusRing`).
- **Links are the accent** (`Palette.link`) in the text's own font,
  underlined while the pointer is on them.
- **Disclosure is a chevron** before the label, right while closed and
  down while open.
- **Text to copy** is `Text` that can be selected; multi-line text to edit
  is a `TextEditor` on the `field` fill or a card.
- **Places have tiles:** Changes and History in the sidebar draw their
  symbols on colored tiles (apricot and teal).
- **Branch colors:** the current branch is the accent, the default branch
  teal; the others cycle through apricot, plum, grape, blue, and leaf,
  skipping those near the accent. A track keeps its color for its line of
  development.
- **Buttons come in three styles:** quiet, prominent (one per area), and
  secondary (Cancel in sheets, Undo). A prominent button that deletes or
  discards is red.
- **SF Symbols** for every icon; the app font for text (Allo, at its
  roundest, by default); the code font (Maple Mono by default) for what's
  monospaced. Pane titles are 15 and bold, commit titles 20 and bold.

## Themes, colors, and fonts

Settings ▸ Appearance picks a theme (Default or Islands), a palette, a
background tint, the appearance, the app font, and the code font, each
apart from the others. The theme is how the app looks; the
palette and the background are its colors, and every theme takes every
palette and background. Views use the tokens, which read the current look.

- **A palette** is an accent color and the colors made from it: links,
  the prominent fill, and selected items' tints. Each is a hue of its own:
  System (the Mac's accent color), Blueberry (the default) and Slate (made
  for Default), Lagoon and Plum (made for Islands), and Tangerine, Magenta, and
  Volt. A theme's default branch and renamed colors give way to others
  beside an accent near their hue.

- **Default** is playful and creamy: cream cards floating on oat (cocoa
  on dark roast in dark), espresso text, the butter highlight for every
  selection, the palette's accent for the prominent action, focus, and
  links, raised pillow controls with bold titles, round file badges, a
  thick graph with round dots, status colors from an orchard (leaf, tomato,
  honey, grape), and lists that fade out at an edge with more beyond it.
- **Islands** is calm and friendly: the panes float as cards on a sage
  backdrop (the floating layout), with soft pills and bold titles.
- **A background tint** (Neutral, Warm, Cool, Sage, Rose, Lavender) gives
  a theme's surfaces its hue in place of the theme's own, faint on white
  and stronger toward gray, each surface as light as before.

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
