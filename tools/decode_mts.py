#!/usr/bin/env python3
"""Decode a Luanti .mts schematic into human-readable layers.

Usage:
    python tools/decode_mts.py schematics/skycastle.mts

Prints size, name table, y-slice probabilities and a layer-by-layer
ASCII map so the geometry can be verified without starting the game.

MTS v4 layout (verified against the engine's mg_schematic.cpp):
    "MTSM" | u16 BE version | 3x u16 BE size
    | sy x u8 yslice prob   (127 = always)
    | u16 BE name count | names as (u16 len + bytes)
    | zlib stream containing the node data in three planes:
        count x u16 BE content id
        count x u8 prob         (127 = always)
        count x u8 param2
Node order inside each plane is x fastest, then y, then z.
"""

import struct
import sys
import zlib


def decode(path):
    data = open(path, "rb").read()
    if data[:4] != b"MTSM":
        raise SystemExit("not an MTS file")
    version, sx, sy, sz = struct.unpack(">HHHH", data[4:12])
    pos = 12
    yslice = list(data[pos:pos + sy])
    pos += sy
    (name_count,) = struct.unpack(">H", data[pos:pos + 2])
    pos += 2
    names = []
    for _ in range(name_count):
        (length,) = struct.unpack(">H", data[pos:pos + 2])
        pos += 2
        names.append(data[pos:pos + length].decode("utf-8"))
        pos += length
    payload = zlib.decompress(data[pos:])

    count = sx * sy * sz
    if len(payload) != count * 4:
        raise SystemExit("unexpected payload length %d for %d nodes" % (len(payload), count))

    content_plane = payload[:2 * count]
    prob_plane = payload[2 * count:3 * count]
    param2_plane = payload[3 * count:]

    def record(i):
        index, = struct.unpack_from(">H", content_plane, i * 2)
        return index, prob_plane[i], param2_plane[i]

    used = set()
    for i in range(count):
        index, prob, param2 = record(i)
        if index >= name_count:
            raise SystemExit("index %d out of range" % index)
        used.add(index)

    print("== %s ==" % path)
    print("version %d, size %dx%dx%d, %d names" % (version, sx, sy, sz, name_count))
    print("yslice_prob (file space):", yslice)
    for i, n in enumerate(names):
        print("  name[%d] = %s" % (i, n))

    prob_hist = {}
    for b in prob_plane:
        prob_hist[b] = prob_hist.get(b, 0) + 1
    param2_hist = {}
    for b in param2_plane:
        param2_hist[b] = param2_hist.get(b, 0) + 1
    print("prob byte histogram:", prob_hist)
    print("param2 byte histogram:", param2_hist)

    tags = {}
    for i in sorted(used):
        base = names[i].split(":")[-1]
        tags[i] = base[:8]

    for y in range(sy):
        print("-- layer y=%d --" % y)
        for z in range(sz):
            row = []
            for x in range(sx):
                i = x + sx * (y + sy * z)
                index, prob, param2 = record(i)
                row.append("%-8s(m%02x)" % (tags[index], param2))
            print("  z=%d: %s" % (z, " | ".join(row)))


if __name__ == "__main__":
    for path in sys.argv[1:]:
        decode(path)
