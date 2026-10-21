#!/usr/bin/env python3
"""Generate textures/lualore_cracks.png: a 16x16 transparent overlay of dark
cracks, drawn over the game's own mese texture for Cracked Mese
(portal/portal_ruins.lua), so it matches whatever texture pack is in use.

Run from the mod root:
    python tools/make_cracked_mese_texture.py
"""

import os

from PIL import Image

SIZE = 16
# Crack paths as pixel runs: a main fissure corner to corner, with branches.
PATHS = [
    [(1, 2), (2, 3), (3, 3), (4, 4), (5, 5), (6, 5), (7, 6), (8, 7), (9, 8),
     (10, 8), (11, 9), (12, 10), (13, 11), (14, 13), (15, 14)],
    [(7, 6), (7, 5), (8, 4), (8, 3), (9, 2), (10, 1)],
    [(10, 8), (10, 9), (9, 10), (9, 11), (8, 12), (7, 13), (7, 14)],
    [(4, 4), (3, 5), (3, 6), (2, 7)],
    [(12, 10), (13, 9), (14, 8)],
    [(0, 11), (1, 11), (2, 12), (3, 12)],
]
DARK = (24, 18, 8, 230)
EDGE = (70, 56, 24, 150)


def main():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    for path in PATHS:
        for x, y in path:
            px[x, y] = DARK
    # a lighter rim along each crack, so it reads as broken, not drawn on
    for path in PATHS:
        for x, y in path:
            for dx, dy in ((0, 1), (1, 0)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < SIZE and 0 <= ny < SIZE and px[nx, ny][3] == 0:
                    px[nx, ny] = EDGE
    out = os.path.join("textures", "lualore_cracks.png")
    img.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
