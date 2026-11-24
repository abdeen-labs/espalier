#!/usr/bin/env python3
"""Draws Espalier's app icon flat, as SVG in light and dark, for use outside the app.

    python3 Marketing/AppIcon/draw-icon.py

writes, next to this script, Espalier-Icon.svg and Espalier-Icon-Dark.svg on a
square background that fills the canvas, and Espalier-Icon-Transparent.svg and
Espalier-Icon-Dark-Transparent.svg with no background. The geometry and colors
are Espalier/AppIcon.icon's: its SVG layers (the peach, its crease, the leaf, and
the stem) and the fills in icon.json, drawn flat with no glass, shadow, or icon
mask. Change the icon there first and then update this to match.

The PNGs beside the SVGs are 1024-pixel renders of them:

    inkscape -w 1024 Espalier-Icon.svg -o Espalier-Icon.png
"""
from pathlib import Path


# The peach: round, with a dip at the stem, the short crease down its left
# shoulder, and the shine beside it.
BODY = ("M92.24 56.68C107.92 45.48 142.64 58.92 142.64 99.24C142.64 130.6 119.12 150.76 90 150.76"
        "C60.88 150.76 37.36 130.6 37.36 99.24C37.36 58.92 76.56 45.48 92.24 56.68Z")
CREASE = "M92.24 56.68C86.64 63.4 83.28 72.36 82.16 82.44"
SHINE = "M56.4 90.28C56.4 79.08 63.12 70.12 72.08 66.76"
# The stem, and the leaf from its foot.
STEM = "M92.24 54.44C92.24 45.48 95.6 39.88 102.32 36.52"
LEAF = "M91.12 51.08C81.38 67.96 62.22 71.9 43.94 61.34C53.68 44.47 72.84 40.52 91.12 51.08Z"

LIGHT = dict(name="Espalier", top="#FFFCF5", bottom="#F5E8D0", stem="#3A2A1F",
             leaf_top="#63C77C", leaf_bottom="#2F8A4C")
DARK = dict(name="Espalier", top="#3A2E24", bottom="#1A1410", stem="#FFF1DC",
            leaf_top="#7FD49A", leaf_bottom="#7FD49A")


def svg(p, background):
    return "\n".join([
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 180 180">',
        f'  <title>{p["name"]}</title>',
        '  <defs>',
        f'    <linearGradient id="body" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{p["top"]}"/><stop offset="1" stop-color="{p["bottom"]}"/></linearGradient>',
        '    <linearGradient id="peach" x1="0.15" y1="0.05" x2="0.85" y2="0.95">'
        '<stop offset="0" stop-color="#FFC98F"/><stop offset="0.55" stop-color="#FF9F6B"/>'
        '<stop offset="1" stop-color="#FF7F5C"/></linearGradient>',
        '    <radialGradient id="blush" cx="0.72" cy="0.68" r="0.5">'
        '<stop offset="0" stop-color="#FF5E7A" stop-opacity="0.75"/>'
        '<stop offset="1" stop-color="#FF5E7A" stop-opacity="0"/></radialGradient>',
        f'    <linearGradient id="leaf" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="{p["leaf_top"]}"/><stop offset="1" stop-color="{p["leaf_bottom"]}"/></linearGradient>',
        '  </defs>',
        *(['  <rect width="180" height="180" fill="url(#body)"/>'] if background else []),
        f'  <path d="{STEM}" fill="none" stroke="{p["stem"]}" stroke-width="8.96" stroke-linecap="round"/>',
        f'  <path d="{LEAF}" fill="url(#leaf)"/>',
        f'  <path d="{BODY}" fill="url(#peach)"/>',
        f'  <path d="{BODY}" fill="url(#blush)"/>',
        f'  <path d="{SHINE}" fill="none" stroke="#FFE6C4" stroke-opacity="0.85" stroke-width="5.6" stroke-linecap="round"/>',
        f'  <path d="{CREASE}" fill="none" stroke="#E8603F" stroke-width="5.04" stroke-linecap="round"/>',
        '</svg>',
    ]) + "\n"


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    (here / "Espalier-Icon.svg").write_text(svg(LIGHT, background=True))
    (here / "Espalier-Icon-Dark.svg").write_text(svg(DARK, background=True))
    (here / "Espalier-Icon-Transparent.svg").write_text(svg(LIGHT, background=False))
    (here / "Espalier-Icon-Dark-Transparent.svg").write_text(svg(DARK, background=False))
