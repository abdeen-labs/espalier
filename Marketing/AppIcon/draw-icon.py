#!/usr/bin/env python3
"""Draws Espalier's app icon flat, as SVG in light and dark, for use outside the app.

    python3 Marketing/AppIcon/draw-icon.py

writes, next to this script, Espalier-Icon.svg and Espalier-Icon-Dark.svg on a
square background that fills the canvas, and Espalier-Icon-Transparent.svg and
Espalier-Icon-Dark-Transparent.svg with no background. The geometry and colors
are Espalier/AppIcon.icon's: its SVG layers (the tree, the fruit, and the glow
behind the fruit) and the fills in icon.json, drawn flat with no glass, shadow,
or icon mask. Change the icon there first and then update this to match.

The PNGs beside the SVGs are 1024-pixel renders of them:

    inkscape -w 1024 Espalier-Icon.svg -o Espalier-Icon.png
"""
from pathlib import Path


# The tree: a trunk trained into three tiers, the lower two peeling off it.
TREE = [
    "M58 146V66A22 22 0 0 1 80 44H124",
    "M58 108C58 95 66 87 80 87H108",
    "M58 146C58 136 66 130 80 130H124",
]
TIPS = [(124, 44), (124, 130)]
FRUIT = (108, 87)

LIGHT = dict(name="Espalier", top="#F6F2FF", bottom="#E1D6FF",
             ink_top="#3A2380", ink_bottom="#24145C", fruit="#8B5CF6", glow="#B48CFF")
DARK = dict(name="Espalier", top="#221A33", bottom="#0B0712",
            ink_top="#F6F1FF", ink_bottom="#DCCFF7", fruit="#C996FF", glow="#B48CFF")


def svg(p, background):
    x, y = FRUIT
    return "\n".join([
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 180 180">',
        f'  <title>{p["name"]}</title>',
        '  <defs>',
        f'    <linearGradient id="body" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{p["top"]}"/><stop offset="1" stop-color="{p["bottom"]}"/></linearGradient>',
        f'    <linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="0" y1="40" x2="0" y2="150">'
        f'<stop offset="0" stop-color="{p["ink_top"]}"/><stop offset="1" stop-color="{p["ink_bottom"]}"/></linearGradient>',
        f'    <radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="{x}" cy="{y}" r="34">'
        f'<stop offset="0" stop-color="{p["glow"]}" stop-opacity="0.5"/>'
        f'<stop offset="1" stop-color="{p["glow"]}" stop-opacity="0"/></radialGradient>',
        '  </defs>',
        *(['  <rect width="180" height="180" fill="url(#body)"/>'] if background else []),
        f'  <circle cx="{x}" cy="{y}" r="34" fill="url(#glow)"/>',
        '  <g fill="none" stroke="url(#ink)" stroke-width="13" stroke-linecap="round" stroke-linejoin="round">',
        *(f'    <path d="{d}"/>' for d in TREE),
        '  </g>',
        *(f'  <circle cx="{cx}" cy="{cy}" r="11" fill="url(#ink)"/>' for cx, cy in TIPS),
        f'  <circle cx="{x}" cy="{y}" r="11.5" fill="{p["fruit"]}"/>',
        '</svg>',
    ]) + "\n"


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    (here / "Espalier-Icon.svg").write_text(svg(LIGHT, background=True))
    (here / "Espalier-Icon-Dark.svg").write_text(svg(DARK, background=True))
    (here / "Espalier-Icon-Transparent.svg").write_text(svg(LIGHT, background=False))
    (here / "Espalier-Icon-Dark-Transparent.svg").write_text(svg(DARK, background=False))
