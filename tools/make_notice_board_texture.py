#!/usr/bin/env python3
"""Generate textures/lualore_notice_board.png - the village notice board face.

A 16x16 pixel-art board: a dark wooden frame around cork, with three
pinned notes. Kept procedural so it can be tweaked and regenerated.

Usage:
    python tools/make_notice_board_texture.py
"""

import os

from PIL import Image

FRAME = [(92, 58, 30), (78, 48, 24)]          # alternating frame planks
CORK = [(176, 128, 74), (164, 116, 64), (186, 138, 84)]
PAPER = (236, 228, 204)
INK = (120, 110, 96)
PINS = [(200, 40, 40), (40, 90, 190), (60, 150, 60)]

# (x0, y0, x1, y1, pin colour) of each note
NOTES = [(2, 2, 7, 7, 0), (8, 3, 13, 8, 1), (4, 9, 11, 13, 2)]


def main():
    img = Image.new("RGBA", (16, 16))
    px = img.load()
    for y in range(16):
        for x in range(16):
            if x in (0, 15) or y in (0, 15):
                px[x, y] = FRAME[(x + y) % 2] + (255,)
            else:
                px[x, y] = CORK[(x * 7 + y * 3) % 3] + (255,)
    for x0, y0, x1, y1, pin in NOTES:
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                px[x, y] = PAPER + (255,)
        # a couple of lines of "writing"
        for y in range(y0 + 2, y1, 2):
            for x in range(x0 + 1, x1):
                px[x, y] = INK + (255,)
        px[(x0 + x1) // 2, y0] = PINS[pin] + (255,)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "textures", "lualore_notice_board.png")
    img.save(os.path.normpath(out))
    print("wrote", os.path.normpath(out))


if __name__ == "__main__":
    main()
