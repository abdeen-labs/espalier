# dmgbuild's settings for Espalier's disk image: the app and a link to
# Applications, in a window that opens in icon view with background.png
# behind them and the app's icon as the volume's. publish-release.sh runs
#
#   dmgbuild -s scripts/dmg/settings.py -D app=<Espalier.app> \
#     -D background=scripts/dmg/background.png Espalier <dmg>
#
# and dmgbuild finds background@2x.png beside the picture it's given.
# `defines` holds what -D gave.

import os.path

app = defines["app"]

# LZMA makes the bundled git about a quarter smaller than zlib (UDZO).
format = "ULMO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = defines["background"]

# The window, title bar included: the picture's width, and 384 points of it
# under a 32-point title bar. The icons' names end above the bottom edge
# with room to spare, so the window has nothing to scroll.
window_rect = ((400, 380), (660, 416))
icon_size = 128
text_size = 13

# The icons' centers, from the content's top left: draw-background.swift's
# `appIcon` and `applicationsIcon`. For people who show hidden files, the
# volume's own files sit below the window's content, not over the picture.
icon_locations = {
    os.path.basename(app): (180, 240),
    "Applications": (480, 240),
    ".background.tiff": (180, 700),
    ".VolumeIcon.icns": (480, 700),
}
