# Espalier's look

The visual design I chose: a flat, precise skeleton with
personality. New UI follows it. The values are `DesignSystem`'s tokens, and
the app's snapshots show it in light and dark.

## Principles

- **Espalier draws its own UI, never stock.** Simple, clean, and modern,
  with personality: not elaborate, and not default controls with minimal
  touches. The system's own pieces (the window's chrome, Quick Look, the
  open and save panels) stay macOS's.
- **Flat.** Opaque surfaces, hairline dividers, and soft shadows only on
  things that float (menus, popovers, tooltips, sheets, alerts, toasts, the
  operation capsule).
- **Rounded.** Controls are capsules (buttons, the location control, search
  fields, segmented controls, ref tags, chips); rows, cards, and sheets have
  generous corners.
- **Sheets and alerts are cards in the window:** the content on the flat
  background, radius 22, with the sheet's shadow, centered over a neutral
  scrim (black 20%, 45% in dark) that covers the window in its corners. An
  alert has no icon; a critical one has the warning glyph before its title.
- **Selection is Espalier's own:** a selected row draws its tint in its
  rounded shape (the soft accent; the sidebar's neutral wash), never the
  system's highlight (`selectableRow(isSelected:)` in a SwiftUI list, a row
  view's `drawSelection` in an AppKit table). The row a context menu acts
  on shows a thin accent ring in its shape while the menu is open.
- **The focus ring is Espalier's:** a 2-point accent ring at 55% in the
  control's own shape (`FocusRing`), never the system's. A field and a
  pop-up draw it on their edge; a control with a fill of its own (a
  capsule, a switch, a checkbox's box, a radio mark, the slider's knob)
  1 point outside it; a list of choices around the chosen row (cards) or
  its mark (flat rows); a bare symbol or row around its frame.
- **Links are the accent,** deepened just enough to read as text
  (`Palette.link`), in the text's own font and weight. A link button
  underlines while the pointer is on it and dims while pressed; links in
  text underline while the pointer is on their text. The pointer is the
  pointing hand.
- **The slider** is a thin capsule track, faint neutral gray, filled in the
  same gray up to a round knob on the quiet fill with the quiet capsules'
  ring and shadow; the knob takes the capsules' hover and press.
- **Disclosure is a chevron** before the label, right while closed and
  down while open. A branch folder is the sidebar list's own outline row,
  with the list's chevron, its rows a level in, under its label.
- **Dragged commits** show the row the drag started on as History draws
  it, on a card with the floating ring and shadow; several stack up to
  two more cards behind it, with a count badge (white SF Mono on the
  deeper accent) at the front card's top trailing corner.
- **Menus are cards:** the `quiet` fill with the floating ring and shadow,
  radius 14, rows 24 high with radius 9 inside a 5-point inset. The row
  under the pointer or the keyboard is the soft accent, its text staying
  primary. A check column (accent checks) shows only when items can be
  checked; symbols and submenu chevrons are secondary; subtitles and
  section headers (in the section labels' style) are tertiary;
  destructive titles are the error color; disabled rows fade. Dividers are
  hairlines inset from the card's edges. A menu taller than the screen
  scrolls, its rows fading out at an end with more past it. A suggestion
  list is the same card under the text: each suggestion with its detail
  after it in tertiary text, scrolling past eight rows.
- **Popovers are cards too:** the content on the flat `background`, radius
  22, with the floating ring and shadow, and no arrow: centered beside the
  control that opens it, 6 points away. A popover is as large as its
  content, up to the screen.
- **Text selection is the accent:** in fields and text views, selected
  text sits on the accent at 16% (24% in dark) where the text has focus,
  and the insertion point is the accent. Text to copy is `Text` that can
  be selected; multi-line text to edit is a `TextEditor` on the `field`
  fill or a card.
- **Tooltips are small cards:** the `quiet` fill with the floating ring
  and a smaller shadow, radius 9, secondary text (12, secondary color)
  padded 6 by 8, wrapping at 280 points. One shows below the cursor once
  the pointer rests 0.8 s on a view (below a graph's node or stub), above
  the pointer at the screen's bottom; once one has shown, the next shows
  after 0.1 s, until none has for 1 s.
- **Find in the diff floats:** a capsule at the diff's top trailing corner
  with the floating shadow, holding the search field (its count, "3 of
  12", in SF Mono), the chevrons, and Done. Every match is a neutral wash
  in a rounded shape over its line's tint; the current one is the accent,
  as the selection it becomes when find closes. Nothing dims, and nothing
  bounces.
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
- **Controls** move as AppKit's controls do. Capsules fade their
  hover, ease a press, and crossfade when their kind changes (the sync
  button quiet ↔ blue). A menu (and a suggestion list) fades in over
  0.1 s, growing very slightly from its button or the pointer, and fades
  out over 0.15 s; its highlight is instant. A tooltip fades in over
  0.08 s and out over 0.15 s. A popover fades in over 0.22 s, settling
  from 97% toward its control, fades out over 0.15 s, and grows and
  shrinks with its content over 0.22 s. The segmented control's selection
  slides. A focus ring settles in from 1.04× as it fades in (0.15 s) and
  fades out (0.1 s). Checkbox and radio marks fade and scale in (a file
  row's checkbox crossfades), the switch's knob slides, and disclosure
  chevrons turn. A link's underline shows at once. A copy button shows a
  check for 1.5 s.
- **Sheets and alerts arrive:** the scrim fades in over 0.22 s while the card
  fades in and settles from 97%; both fade out over 0.15 s.
- **What the user changes moves:** the sync button's counts roll, and the
  branch name fades in after a switch. Bars and banners grow in while
  what's below moves, and leave quicker. Simple ↔ Graph and Unified ↔
  Split crossfade, and the shimmer crossfades into a generated message. A
  diff crossfades to its expanded lines, and a sidebar section's rows
  animate in and out as it opens and closes. The diff's find bar fades in, settling from 97%, and fades
  out; the next match scrolls into view, easing when it's within three
  screens. Hover in lists fades, row by row.
- **Work that runs moves:** the arc turns once every 0.9 s, the bar's
  segment sweeps every 1.4 s, and the shimmer passes over a message being
  generated. Under Reduce Motion and in snapshots they stand still: the
  arc at twelve o'clock, the segment in the middle.
- **Instant:** selection and arrow-key browsing, and what follows them; a
  slider's knob, dragged or stepped; navigating between repositories and
  places, and the reload after a branch switch; typing-driven updates;
  enabled ↔ disabled; paging; ticking times.
