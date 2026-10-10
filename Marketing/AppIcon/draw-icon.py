#!/usr/bin/env python3
"""Draws Espalier's app icon flat, as SVG in light and dark, for use outside the app.

    python3 Marketing/AppIcon/draw-icon.py

writes, next to this script, Espalier-Icon.svg and Espalier-Icon-Dark.svg on a
square background that fills the canvas, and Espalier-Icon-Transparent.svg and
Espalier-Icon-Dark-Transparent.svg with no background. The geometry and colors
are Espalier/AppIcon.icon's: its SVG layers and the fills in icon.json, drawn
flat with no glass, shadow, or icon mask. The back and middle panes keep the
icon's translucency as one opacity each, the average of what macOS's render of
the icon lets through; the front pane reads as opaque there and is drawn so.
Change the icon there first and then update this to match.

The PNGs beside the SVGs are 1024-pixel renders of them:

    inkscape -w 1024 Espalier-Icon.svg -o Espalier-Icon.png
"""
from pathlib import Path


OPACITY = dict(back=0.7, middle=0.8, front=1)

LIGHT = dict(name="Espalier", body="#1B2B4A", back="#5ED1C1", middle="#7EE0A0",
             front="#F4FAF6", branch="#1B2B4A", leaf="#3FA56B")
DARK = dict(name="Espalier", body="#101A2E", back="#2F8A86", middle="#3F9E6E",
            front="#2B3B5E", branch="#E9F1EC", leaf="#6FD39A")


def pane(x, y, color, opacity):
    fill = f' fill-opacity="{opacity}"' if opacity < 1 else ""
    return f'  <rect x="{x}" y="{y}" width="92" height="92" rx="22" fill="{color}"{fill}/>'


def svg(p, background):
    return "\n".join([
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 180 180">',
        f'  <title>{p["name"]}</title>',
        *([f'  <rect width="180" height="180" fill="{p["body"]}"/>'] if background else []),
        pane(22, 66, p["back"], OPACITY["back"]),
        pane(44, 46, p["middle"], OPACITY["middle"]),
        pane(66, 26, p["front"], OPACITY["front"]),
        '  <g transform="translate(110 74) scale(0.85)">',
        f'    <path d="M-8 32V-28M-8 12C-8 -4 14 -2 18 -18" stroke="{p["branch"]}" stroke-width="7" stroke-linecap="round" fill="none"/>',
        f'    <circle cx="-8" cy="32" r="7" fill="{p["branch"]}"/>',
        f'    <circle cx="-8" cy="-28" r="7" fill="{p["branch"]}"/>',
        f'    <path d="M16 -16C16 -32 26 -42 40 -44C40 -30 32 -18 16 -16Z" fill="{p["leaf"]}"/>',
        '  </g>',
        '</svg>',
    ]) + "\n"


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    (here / "Espalier-Icon.svg").write_text(svg(LIGHT, background=True))
    (here / "Espalier-Icon-Dark.svg").write_text(svg(DARK, background=True))
    (here / "Espalier-Icon-Transparent.svg").write_text(svg(LIGHT, background=False))
    (here / "Espalier-Icon-Dark-Transparent.svg").write_text(svg(DARK, background=False))
