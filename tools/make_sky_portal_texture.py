#!/usr/bin/env python3
"""Generate textures/lualore_sky_portal.png - the swirling sky portal sheet.

The texture is a vertical strip of 16x16 frames, played by the node's
`vertical_frames` animation. Two properties matter more than the look:

* It TILES. A portal is a sheet of many identical nodes, so the pattern must
  meet itself at every edge or the sheet shows a grid. The waves underneath
  are sines of whole multiples of the coordinate, and the twist that makes
  the vortex fades to nothing before the tile's edge, so the edges are pure
  waves and meet their neighbours exactly.
* It LOOPS. Every term is also an integer multiple of the frame phase t, so
  the last frame flows back into the first without a jump.

The swirl is a vortex at the centre of each tile: sample points are rotated
about the centre by an angle that is largest there and falls to zero at the
tile's inscribed circle. Outside that circle nothing is rotated, so the edges
show the plain underlying pattern and still tile. The pattern underneath is
scrolled by one whole period per loop, so it streams through the fixed vortex
and appears to spiral into it. Colours are posterised into a handful of bands
so the result reads as pixel art beside the game's other 16px textures.

Usage:
    python tools/make_sky_portal_texture.py
"""

import math
import os

from PIL import Image

SIZE = 16          # pixels per frame edge, to match the game's textures
FRAMES = 32        # frames in one loop
BANDS = 6          # colour bands after posterising

# dark sky -> royal blue -> pale cyan highlights
PALETTE = [
    (16, 34, 120),
    (34, 78, 205),
    (52, 112, 236),
    (84, 160, 250),
    (138, 206, 255),
    (205, 240, 255),
]
# the deep bands are more see-through, the highlights nearly solid
ALPHA_MIN, ALPHA_MAX = 140, 225

TAU = 2.0 * math.pi


# how far the centre of the vortex is twisted, in radians
TWIST = 4.2


def swirl(u, v):
    """Rotate (u, v) about the tile centre, more the closer it is."""
    dx, dy = u - 0.5, v - 0.5
    r = math.hypot(dx, dy)
    falloff = max(0.0, 1.0 - r / 0.5) ** 2
    a = TWIST * falloff
    ca, sa = math.cos(a), math.sin(a)
    return 0.5 + dx * ca - dy * sa, 0.5 + dx * sa + dy * ca


def field(u, v, t):
    """Swirl intensity at tile coordinates u, v (0..1) and loop phase t."""
    su, sv = swirl(u, v)
    s = (math.sin(TAU * (su + sv + t))
         + 0.8 * math.sin(TAU * (su - sv - t))
         + 0.45 * math.sin(TAU * (2 * su + 2 * t))
         + 0.3 * math.cos(TAU * (2 * sv - 2 * t)))
    return (s + 2.55) / 5.1   # roughly 0..1


def main():
    img = Image.new("RGBA", (SIZE, SIZE * FRAMES))
    px = img.load()
    for f in range(FRAMES):
        t = f / FRAMES
        for y in range(SIZE):
            for x in range(SIZE):
                k = max(0.0, min(0.999, field(x / SIZE, y / SIZE, t)))
                band = int(k * BANDS)
                r, g, b = PALETTE[band]
                a = int(ALPHA_MIN + (ALPHA_MAX - ALPHA_MIN) * band / (BANDS - 1))
                px[x, f * SIZE + y] = (r, g, b, a)

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "textures", "lualore_sky_portal.png")
    img.save(os.path.normpath(out))
    print("wrote %s (%dx%d, %d frames)" % (os.path.normpath(out),
                                          img.width, img.height, FRAMES))


if __name__ == "__main__":
    main()
