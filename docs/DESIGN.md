# Espalier's look

The visual design I chose: a flat, precise skeleton with
personality. New UI follows it. The values are `DesignSystem`'s tokens.
This describes Classic, the default theme, in SF Pro and SF Mono; the
other themes change what their tokens say (Themes, below).

## Principles

- **Espalier draws its own UI.** Simple, clean, and modern, with
  personality: not elaborate, and not default controls with minimal
  touches. The system's own pieces (the window's chrome, Quick Look, the
  open and save panels) stay macOS's.
- **Flat.** Opaque surfaces, hairline dividers, and soft shadows only on
  things that float (menus, popovers, tooltips, sheets, alerts, toasts, the
  operation capsule).
- **Rounded.** Controls are capsules (buttons, the location control, search
  fields, segmented controls, ref tags, chips); rows, cards, and sheets have
  generous corners.
- **What floats is a card:** menus, popovers, and tooltips with the
  floating ring and shadow; sheets and alerts centered in the window over a
  neutral scrim.
- **Selection is Espalier's own:** a selected row draws its tint in its
  rounded shape (the soft accent; the sidebar's neutral wash):
  `selectableRow(isSelected:)` in a SwiftUI list, a row view's
  `drawSelection` in an AppKit table.
- **The focus ring is Espalier's:** an accent ring in the control's own
  shape (`FocusRing`).
- **Links are the accent** (`Palette.link`) in the text's own font,
  underlined while the pointer is on them.
- **Disclosure is a chevron** before the label, right while closed and
  down while open.
- **Text to copy** is `Text` that can be selected; multi-line text to edit
  is a `TextEditor` on the `field` fill or a card.
- **Branch colors:** the current branch is the accent, the default branch
  teal; the others cycle through pink, violet, orange, green, blue, and
  cyan, skipping the one nearest the accent. A track keeps its color for
  its line of development.
- **Buttons come in three styles:** quiet, prominent (one per area), and
  secondary (Cancel in sheets, Undo).
- **SF Symbols** for every icon; the app font for text (SF Pro by
  default); the code font (SF Mono by default) for what's monospaced.

## Themes, colors, and fonts

Settings ▸ Appearance picks a theme (Classic, Frost, Islands, Pop), the
theme's color, its background tint, the appearance, the app font, and the
code font, each apart from the others. Views use the tokens, which read the
current look.

- **Frost** is quiet and precise: near-white and near-black
  with almost no hue, a neutral wash for every selection, ink for the
  prominent action, flat pills, one accent for focus and links, and lists
  that fade out at an edge with more beyond it. Its chrome is glass around
  one inset card.
- **Islands** is calm and friendly: the panes float as cards on a sage
  backdrop (the floating layout), with soft pills and bold titles.
- **Pop** is bright and confident: a sidebar tinted with the accent, a bar
  beside the selected row, and saturated color in solid shapes.
- **A background tint** (Neutral, Warm, Cool, Sage, Rose, Lavender) gives
  any theme's surfaces its hue in place of the theme's own, faint on white
  and stronger toward gray, each surface as light as before. Pop's sidebar
  keeps its accent. Islands can also take Classic's backgrounds.

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
