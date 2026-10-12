# Espalier's look

The visual design I chose: a flat, precise skeleton with
personality. New UI follows it. The values are `DesignSystem`'s tokens.
This describes Classic, the default theme, in SF Pro and SF Mono; the
other themes change what their tokens say (Themes, below).

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
- **Color has rules.** The accent (the Mac's, blue by default) is
  selection, the user's own changes, and the one prominent action in an
  area (a deeper shade of the accent, so white text reads on it). Branch colors appear only where branches do (sidebar
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
- **SF Symbols** for every icon; the app font for text (SF Pro by
  default), but key caps, which stay SF Pro; the code font (SF Mono by
  default) for what's monospaced.

## Themes, colors, and fonts

Settings ▸ Appearance picks a theme (Classic, Orchard, Islands, Pop), the
theme's color, the appearance, the app font, and the code font, each apart
from the others. Views never pick a theme: they use the tokens, which read the
current look.

- **The tokens** are `Theme` (DesignSystem/Themes/Theme.swift): surfaces,
  text, the accent and its fills, the prominent fill and its text, links,
  status, the diff's tints, branch colors, selection (the sidebar's fill,
  text, symbol, weight, and counts; lists'), the sidebar's tertiary text,
  the ahead count, section labels, radii, the commit title, button weights,
  the graph (line width, lane pitch, nodes), ref tags, file badges, avatars
  (shape, monograms' tone), the selection marks (Orchard's raised card,
  Pop's leading bar), quiet controls (their fill, raised or flat) and the
  selected segment, the marks on the accent (a check, a radio's dot, the
  switch's knob while on: white, but on a near-white accent), syntax
  colors, the control style (a shadow under prominent capsules, quiet
  capsules flat in floating cards), and the pane layout with its backdrop.
  `Palette`, `DiffColors`, `TrackPalette`, `Typography`, `Metrics`, and
  `TokenTheme` read them.
- **Each theme is one file** in DesignSystem/Themes (ClassicTheme.swift,
  OrchardTheme.swift, IslandsTheme.swift, PopTheme.swift), its colors in
  light and dark; Increase Contrast is derived as Classic's is.
- **The fonts** are `AppFont`'s (the sans) and `CodeFont`'s (the mono)
  faces (DesignSystem/Fonts), in `Typography` and `AppKitTypography`.
- **The look** (`Look`: theme, color, app font, code font) is the
  process's (`LookCenter`), or a task's own (`Look.with`).
- **Islands** is calm and friendly: the panes float as white cards on a
  cool sage backdrop (`#E3E9E5`, `#0E1210` in dark), and controls are soft
  pills with bold titles. Quiet capsules on the backdrop (the toolbar's)
  are white and raised, those in a card flat on the field fill; search
  fields on the backdrop are raised quiet capsules; the prominent capsule
  casts a small shadow. Section labels are bold, uppercase, and tracked;
  the sidebar's selected item is bold, its counts in the selection's ink.
  Avatars are rounded squares, file badges round and tinted, ref tags
  rounded rectangles tinted with the branch's color (the current branch's
  the prominent fill), the graph dots on 3.25-point lines, and a commit's
  title 18 bold. The marks on the accent are white in light and the card's
  dark in dark. Colors: Lagoon (the default; a deep sea blue-green,
  `#0B7A8C`), Indigo (`#4447C9`), Berry (`#B8255F`, its deletions
  vermilion, away from the accent).
- **The floating layout** (`PaneLayout.floatingCards`, Islands;
  Shell/FloatingPanes.swift): the window is the backdrop, the toolbar and
  the sidebar sit on it with no hairlines, and each pane is a card, the
  background fill at the card radius (14) with the raised ring and a soft
  shadow 1 point down, blurred 3 (none in dark), everything in it clipped
  to it. Cards are 8 apart, with no margin above them (the toolbar's band
  ends where they start), 2 after the sidebar, and 10 at the window's
  edges; a card draws its ring and shadow in the 2 points inside its
  frame. A place's two panes are the cards of its split: the split's
  divider is the gap, and the whole gap drags it; the panes' content keeps
  its flat widths. A destination with one pane, Commit Info, and the
  operation panel (above the place's cards) are cards too; a split inside
  a card (a commit's files beside its diff) stays flat. Settings' pane is a
  card under its header band, and the theme picker's preview shows the
  card. Switching between flat and floating keeps every view as it is.
- **Pop** is bright and confident: white panes beside a sidebar tinted with
  the accent, and saturated color in solid shapes. Section labels are bold,
  uppercase, and tracked, in the accent's ink three quarters over the
  sidebar; the sidebar's counts, pull request numbers, and header buttons
  are its ink at 70%, and ahead counts its ink itself. A selected row is a
  tint with a 3-point accent bar at its leading edge (the sidebar, History,
  the file lists); the sidebar's selected item is bold, it and its counts in
  the selection's ink. Ref tags are solid, white on the branch color in
  light and near-black on it in dark, the current branch's the prominent
  fill; file badges are solid, their letters white or near-black, whichever
  reads. Buttons are semibold and the prominent one bold; the marks on the
  accent (checks, radio dots, the switch's knob) are near-black on
  Tangerine, as its prominent text is, and on the others white in light and
  near-black in dark. Monograms are saturated, the graph bold (4-point
  lines, filled dots, a halo on the current commit), and a commit's title 18
  bold. Colors: Tangerine (the default; `#FF6A1F` with near-black text),
  Electric, Magenta; deletions turn raspberry (Tangerine) or vermilion
  (Magenta), away from the accent.

## Motion

Not every screen and element needs an animation. That doesn't mean
removing default animations, making the app feel dead, or dropping the
small touches that make the UI feel cared for. All motion goes through one
token, `Motion`.

- **Reduce Motion:** nothing animates, hover and press included; a jump
  keeps its still outline. Models update at once; only drawing animates.
  Offscreen windows draw none.
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
  generated. Under Reduce Motion they stand still: the arc at twelve
  o'clock, the segment in the middle.
- **Instant:** selection and arrow-key browsing, and what follows them; a
  slider's knob, dragged or stepped; navigating between repositories and
  places, and the reload after a branch switch; typing-driven updates;
  enabled ↔ disabled; paging; ticking times.

## Orchard

Warm and crafted: paper and stone instead of gray, one accent, orchard
colors for branches, soft and generous shapes. Its colors are Plum, Clay,
Ink (the default), Teal, and Espresso; the values are OrchardTheme.swift's.

- **Surfaces are paper and stone:** paper for the panes, the toolbar,
  sheets, and popovers; stone for the sidebar; warm white for
  menus, cards, toasts, and tooltips. Lines and text are warm too.
- **Controls are flat stone pills,** with no ring or shadow: quiet and
  secondary buttons alike, the location control, co-author tokens,
  fields, search fields, pop-ups, and the segmented control's track. The
  selected segment is a paper card raised by a soft warm shadow.
- **The sidebar's selection is a raised card:** paper on the stone, with
  a soft warm shadow and ring (the ring alone in dark), its symbol in the
  text color.
- **Section labels are sentence case,** 12 semibold, tertiary; a commit's
  title is 18 semibold.
- **One accent per color** marks selection, the current branch, focus,
  checks, and switches; the prominent fill is a shade deeper. Ink is a deep
  warm navy. Espresso has no hue: warm black, cream in dark, with
  coffee-brown links.
- **Marks on the accent** (checks, radio dots, the switch's knob while on)
  are white in light and the dark paper in dark, on dark's light accents.
- **Branches take orchard colors:** leaf green for the default branch
  (orange in Teal); orange, rose, plum, sky (periwinkle in Teal), teal, or
  leaf for the others, without those beside the color's accent, its
  deletions, or its default branch. Ref tags are the branch's color at 15%
  (22% in dark), their text mixed toward ink; the current branch's tag is
  the prominent fill.
- **The graph is dots,** 3.5 wide, lanes 17 apart.
- **The diff** tints in leaf green and brick (rose red in Clay), and code
  takes the orchard's colors: plum keywords, brick strings, warm gray
  comments, ochre numbers, teal types, and sky functions.
