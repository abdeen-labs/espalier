# Espalier's look

The visual design I chose: a flat, precise skeleton with
personality. New UI follows it. The values are `DesignSystem`'s tokens, and
the app's snapshots show it in light and dark.

## Principles

- **Native means written natively, not stock** ("Native means written
  natively" in `docs/DECISIONS.md`). Simple, clean, and modern, with
  personality: not elaborate, and not default controls with minimal
  touches.
- **Flat.** Opaque surfaces, hairline dividers, and soft shadows only on
  things that float (sheets, popovers, toasts, the operation capsule).
  Menus, context menus, and system alerts stay as macOS draws them.
- **Rounded.** Controls are capsules (buttons, the location control, search
  fields, segmented controls, ref tags, chips); rows, cards, and sheets have
  generous corners.
- **Selection is Espalier's own:** a selected row draws its tint in its
  rounded shape (the soft accent; the sidebar's neutral wash), never the
  system's highlight (`selectableRow(isSelected:)` in a SwiftUI list, a row
  view's `drawSelection` in an AppKit table).
- **Personality comes from:** the capsule controls, the transit-map graph,
  the diff's tinted gutter, monospaced IDs and counts, visible key caps, the
  colored repository badges, and branch colors.
- **Color has rules.** Blue is selection, the user's own changes, and the
  one prominent action in an area (a deeper shade of the accent, so white
  text reads on it). Branch colors appear only where branches do (sidebar
  dots, the graph, ref tags). Status colors appear only for status.
  Everything else is neutral.
- **Branch colors:** the current branch is the accent, the default branch
  teal; the others cycle through pink, violet, orange, green, indigo, and
  cyan, skipping the one nearest the accent. Red and yellow stay out (they
  read as errors and warnings). A track keeps its color for its line of
  development.
- **Buttons come in three styles:** quiet, prominent (one per area), and
  secondary (Cancel in sheets, Undo).
- **Progress is the arc and the bar,** never the system's spinner or bars.
  The arc is about a quarter of a faint ring, turning clockwise while how
  far the work has got isn't known and filling the ring from twelve
  o'clock once it is; mini in a symbol's place, small beside text, large
  alone in a pane. The bar is a thin capsule on a faint track, its segment
  sweeping until it fills. Both are neutral gray, white on a prominent
  capsule.
- **SF Symbols** for every icon; SF Pro and SF Mono for text.

## Motion

Not every screen and element needs an animation. That doesn't mean
removing default animations, making the app feel dead, or dropping the
small touches that make the UI feel cared for. All motion goes through one
token, `Motion`.

- **Reduce Motion:** nothing animates, hover and press included; a jump
  keeps its still outline. Models update at once; only drawing animates.
  Snapshots and offscreen windows draw none.
- **Controls** keep their native counterparts' motion. Capsules fade their
  hover, ease a press, and crossfade when their kind changes (the sync
  button quiet ↔ blue). The segmented control's selection slides. A focus
  ring settles in. Checkbox and radio marks fade and scale in, the switch's
  knob slides, and disclosure chevrons turn. A copy button shows a check
  for 1.5 s.
- **What the user changes moves:** counts roll, and the branch name fades
  in after a switch. Bars and banners grow in while what's below moves,
  and leave quicker. Simple ↔ Graph and Unified ↔ Split crossfade, and the
  shimmer crossfades into a generated message. A diff's expanded lines
  slide down, and a sidebar section's rows animate in and out as it opens
  and closes. Hover in lists fades, with one layer per AppKit table.
- **Work that runs moves:** the arc turns once every 0.9 s, the bar's
  segment sweeps every 1.4 s, and the shimmer passes over a message being
  generated. Under Reduce Motion and in snapshots they stand still: the
  arc at twelve o'clock, the segment in the middle.
- **Instant:** selection and arrow-key browsing, and what follows them;
  navigating between repositories and places, and the reload after a
  branch switch; typing-driven updates; enabled ↔ disabled; paging;
  ticking times.
