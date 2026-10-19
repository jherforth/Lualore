#!/usr/bin/env python3
"""Generate the Wooden Guardian model and texture for lualore.

Outputs
-------
models/wooden_guardian.gltf     (JSON glTF 2.0, base64-embedded buffer)
textures/wooden_guardian.png    (128x128 procedural bark texture)
textures/lualore_guardian_heart*.png  (16x16 tiles for the Guardian Heart)

With --preview DIR it also renders front and side views of each animation's
key poses to DIR, so the model can be checked without a modelling program.

The Guardian is an original walking tree-construct built from boxes: root
legs, a broad bark trunk under a mossy shoulder crown, long hanging arms with
knotted fists, and a carved head with amber knot-eyes and a sprout on top.
About 3.1 nodes tall, against the player's 2.

How it differs from tools/make_mirror_sentinel.py
--------------------------------------------------
The Sentinel only hovers and orbits, so all its bones rest at the origin. A
figure that walks needs real joints: every bone here rests at its pivot (hip,
shoulder, elbow, neck) with a matching inverse bind matrix, so rotating a bone
swings the limb about its joint. Vertices are written in model space and
weighted 1.0 to one bone each.

Conventions (checked against the Lit, which works in game)
-------------------------------------------------------------
* 10 units = 1 node; the origin is at the feet.
* The model faces -Z. Luanti's glTF import mirrors Z, so it faces forward.
* Luanti plays only the first glTF animation and reads its timestamps as
  frame numbers, so the three clips share one timeline as exclusive ranges
  with gaps between them, and the mob plays each range at speed 1:
      idle    0.0 - 2.0   (a slow sway)
      walk    2.5 - 3.5   (one stride pair, a closed loop)
      attack  4.0 - 4.8   (a two-armed overhead slam)
  Keys are sampled every 0.05 s from smooth functions, so playback is smooth
  under Luanti's LINEAR interpolation, and each clip ends exactly on its
  first pose.

Run from the mod root:
    python tools/make_wooden_guardian.py [--preview DIR]
"""

import base64
import json
import math
import os
import struct
import sys

from PIL import Image, ImageDraw

MODEL_PATH = os.path.join("models", "wooden_guardian.gltf")
TEXTURE_PATH = os.path.join("textures", "wooden_guardian.png")

CLIPS = {"idle": (0.0, 2.0), "walk": (2.5, 3.5), "attack": (4.0, 4.8)}
STEP = 0.05

# --------------------------------------------------------------------
# Skeleton: name, parent, pivot (model space)
# --------------------------------------------------------------------
BONES = [
    ("root",       None,     (0.0, 0.0, 0.0)),
    ("torso",      "root",   (0.0, 12.0, 0.0)),
    ("head",       "torso",  (0.0, 25.0, 0.0)),
    ("arm_l",      "torso",  (8.5, 24.0, 0.0)),
    ("forearm_l",  "arm_l",  (10.0, 14.5, 0.0)),
    ("arm_r",      "torso",  (-8.5, 24.0, 0.0)),
    ("forearm_r",  "arm_r",  (-10.0, 14.5, 0.0)),
    ("leg_l",      "root",   (3.5, 12.0, 0.0)),
    ("leg_r",      "root",   (-3.5, 12.0, 0.0)),
]
BONE_INDEX = {name: i for i, (name, _, _) in enumerate(BONES)}

# Texture zones (u0, v0, u1, v1), origin top-left.
ZONES = {
    "bark":  (0.00, 0.00, 0.50, 0.50),
    "face":  (0.50, 0.00, 1.00, 0.50),
    "ends":  (0.00, 0.50, 0.50, 1.00),
    "moss":  (0.50, 0.50, 1.00, 0.75),
    "knot":  (0.50, 0.75, 1.00, 1.00),
}

FACE_AXES = {
    (1, 0, 0):  ((0, 0, -1), (0, 1, 0)),
    (-1, 0, 0): ((0, 0, 1), (0, 1, 0)),
    (0, 1, 0):  ((1, 0, 0), (0, 0, -1)),
    (0, -1, 0): ((1, 0, 0), (0, 0, 1)),
    (0, 0, 1):  ((1, 0, 0), (0, 1, 0)),
    (0, 0, -1): ((-1, 0, 0), (0, 1, 0)),
}

UP, DOWN, FRONT = (0, 1, 0), (0, -1, 0), (0, 0, -1)


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


class MeshBuilder:
    def __init__(self):
        self.positions, self.normals, self.uvs = [], [], []
        self.joints, self.weights, self.indices = [], [], []
        self.face_zone = []   # zone per quad, for the preview

    def add_box(self, center, size, zone, bone, overrides=None):
        overrides = overrides or {}
        cx, cy, cz = center
        hw, hh, hd = size[0] / 2.0, size[1] / 2.0, size[2] / 2.0
        b = BONE_INDEX[bone]
        for n, (right, up) in FACE_AXES.items():
            z = overrides.get(n, zone)
            u0, v0, u1, v1 = ZONES[z]
            inset = 1.0 / 128.0
            u0, v0, u1, v1 = u0 + inset, v0 + inset, u1 - inset, v1 - inset
            rh = hw if right[0] != 0 else (hh if right[1] != 0 else hd)
            uh = hh if up[1] != 0 else (hw if up[0] != 0 else hd)
            verts = []
            for ru, rv in ((-rh, -uh), (rh, -uh), (rh, uh), (-rh, uh)):
                verts.append((cx + right[0] * ru + up[0] * rv,
                              cy + right[1] * ru + up[1] * rv,
                              cz + right[2] * ru + up[2] * rv))
            a = tuple(verts[1][i] - verts[0][i] for i in range(3))
            c = tuple(verts[2][i] - verts[0][i] for i in range(3))
            w = cross(a, c)
            if w[0] * n[0] + w[1] * n[1] + w[2] * n[2] <= 0:
                raise AssertionError("bad winding for face %s" % (n,))
            # bottom-left, bottom-right, top-right, top-left
            for p, t in zip(verts, [(u0, v1), (u1, v1), (u1, v0), (u0, v0)]):
                self.positions.append(p)
                self.normals.append(n)
                self.uvs.append(t)
                self.joints.append((b, 0, 0, 0))
                self.weights.append((1.0, 0.0, 0.0, 0.0))
            o = len(self.positions) - 4
            self.indices += [o, o + 1, o + 2, o, o + 2, o + 3]
            self.face_zone.append(z)


def build_mesh():
    mb = MeshBuilder()
    ends = {UP: "ends", DOWN: "ends"}
    for side, sx in (("l", 1), ("r", -1)):
        # root legs, flaring into feet
        mb.add_box((3.5 * sx, 6.5, 0), (5, 11, 6), "bark", "leg_" + side, ends)
        mb.add_box((3.6 * sx, 1.0, -0.6), (6.6, 2, 8), "knot", "leg_" + side)
        # long arms: upper, forearm, knotted fist
        mb.add_box((10 * sx, 19.5, 0), (5, 10, 5), "bark", "arm_" + side, ends)
        mb.add_box((10 * sx, 10.5, 0), (4.5, 8, 4.5), "bark", "forearm_" + side, ends)
        mb.add_box((10 * sx, 4.5, -0.4), (6, 4, 6), "knot", "forearm_" + side)
        # moss tufts on the shoulders
        mb.add_box((6.8 * sx, 26.6, 0.2), (4.5, 1.6, 6), "moss", "torso")
    # pelvis and trunk
    mb.add_box((0, 13.5, 0), (11, 3, 8), "knot", "torso")
    mb.add_box((0, 19.5, 0), (14, 12, 9), "bark", "torso", ends)
    mb.add_box((0, 20.0, -4.9), (9, 7, 1.2), "knot", "torso")       # chest boss
    mb.add_box((0, 25.75, 0), (16, 1.5, 10.5), "moss", "torso")     # shoulder crown
    # head: carved face to the front, a brow, a sprout
    mb.add_box((0, 28.2, -0.4), (8, 6, 7), "bark", "head", {FRONT: "face", UP: "ends"})
    mb.add_box((0, 30.6, -3.8), (8.6, 1.0, 1.4), "knot", "head")
    mb.add_box((1.5, 32.4, 0.4), (1.0, 2.6, 1.0), "bark", "head")
    mb.add_box((2.2, 33.9, 0.4), (2.8, 1.2, 2.8), "moss", "head")
    return mb


# --------------------------------------------------------------------
# Poses
# --------------------------------------------------------------------
def smooth(a, b, x):
    """Smoothstep from a to b as x goes 0..1 (clamped)."""
    x = max(0.0, min(1.0, x))
    x = x * x * (3 - 2 * x)
    return a + (b - a) * x


def keyframes(points, s):
    """Piecewise smoothstep through (s, value) points, s in 0..1."""
    for (s0, v0), (s1, v1) in zip(points, points[1:]):
        if s <= s1:
            return smooth(v0, v1, (s - s0) / (s1 - s0) if s1 > s0 else 1)
    return points[-1][1]


def pose(t):
    """Per-bone (rx, ry, rz in degrees) and the root's bob, at time t."""
    rot = {name: (0.0, 0.0, 0.0) for name, _, _ in BONES}
    bob = 0.0
    tau = 2 * math.pi
    lo, hi = CLIPS["idle"]
    if lo <= t <= hi:
        s = (t - lo) / (hi - lo)
        w = math.sin(tau * s)
        rot["torso"] = (-1.5 * w, 0, 0)
        rot["head"] = (0, 6 * math.sin(tau * s + 1.0), 0)
        rot["arm_l"] = (3 * math.sin(tau * s + 0.5), 0, -2.0)
        rot["arm_r"] = (3 * math.sin(tau * s + 0.5), 0, 2.0)
        rot["forearm_l"] = rot["forearm_r"] = (4 + 2 * w, 0, 0)
        bob = 0.25 * w
    lo, hi = CLIPS["walk"]
    if lo <= t <= hi:
        s = (t - lo) / (hi - lo)
        w = math.sin(tau * s)
        rot["leg_l"] = (28 * w, 0, 0)
        rot["leg_r"] = (-28 * w, 0, 0)
        rot["arm_l"] = (-22 * w, 0, -2.0)
        rot["arm_r"] = (22 * w, 0, 2.0)
        rot["forearm_l"] = (12 + 6 * max(0, -w), 0, 0)
        rot["forearm_r"] = (12 + 6 * max(0, w), 0, 0)
        rot["torso"] = (-3, 5 * w, 0)
        rot["head"] = (2, -3 * w, 0)
        bob = 0.8 * abs(w)
    lo, hi = CLIPS["attack"]
    if lo <= t <= hi:
        s = (t - lo) / (hi - lo)
        # wind up overhead, slam down in front, recover
        arm = keyframes([(0, 0), (0.45, 155), (0.62, 15), (1.0, 0)], s)
        fore = keyframes([(0, 0), (0.45, 25), (0.62, -8), (1.0, 0)], s)
        lean = keyframes([(0, 0), (0.45, 7), (0.62, -15), (1.0, 0)], s)
        rot["arm_l"] = (arm, 0, -4.0)
        rot["arm_r"] = (arm, 0, 4.0)
        rot["forearm_l"] = rot["forearm_r"] = (fore, 0, 0)
        rot["torso"] = (lean, 0, 0)
        rot["head"] = (-lean * 0.5, 0, 0)
        bob = keyframes([(0, 0), (0.45, 0.6), (0.62, -0.8), (1.0, 0)], s)
    return rot, bob


def quat_euler(rx, ry, rz):
    """Rotation X, then Y, then Z (degrees) as a quaternion (x, y, z, w)."""
    def axis(ax, deg):
        h = math.radians(deg) / 2.0
        q = [0.0, 0.0, 0.0, math.cos(h)]
        q[ax] = math.sin(h)
        return q

    def mul(a, b):
        ax, ay, az, aw = a
        bx, by, bz, bw = b
        return [aw * bx + ax * bw + ay * bz - az * by,
                aw * by - ax * bz + ay * bw + az * bx,
                aw * bz + ax * by - ay * bx + az * bw,
                aw * bw - ax * bx - ay * by - az * bz]
    q = mul(axis(2, rz), mul(axis(1, ry), axis(0, rx)))
    n = math.sqrt(sum(c * c for c in q))
    return tuple(c / n for c in q)


def sample_times():
    times = []
    for name in ("idle", "walk", "attack"):
        lo, hi = CLIPS[name]
        n = int(round((hi - lo) / STEP))
        times += [round(lo + i * STEP, 4) for i in range(n + 1)]
    return times


# --------------------------------------------------------------------
# glTF assembly
# --------------------------------------------------------------------
def local_translation(i):
    name, parent, pivot = BONES[i]
    if parent is None:
        return pivot
    pp = BONES[BONE_INDEX[parent]][2]
    return tuple(pivot[k] - pp[k] for k in range(3))


def build_gltf():
    mb = build_mesh()
    blob = bytearray()
    views, accessors = [], []

    def add_view(data, target=None):
        while len(blob) % 4:
            blob.append(0)
        v = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)}
        if target:
            v["target"] = target
        views.append(v)
        blob.extend(data)
        return len(views) - 1

    def add_acc(view, ctype, atype, count, vmin=None, vmax=None):
        a = {"bufferView": view, "componentType": ctype, "count": count, "type": atype}
        if vmin is not None:
            a["min"], a["max"] = vmin, vmax
        accessors.append(a)
        return len(accessors) - 1

    def f32(vals):
        return struct.pack("<%df" % len(vals), *vals)

    n = len(mb.positions)
    pos = add_acc(add_view(f32([c for p in mb.positions for c in p]), 34962), 5126, "VEC3", n,
                  [min(p[i] for p in mb.positions) for i in range(3)],
                  [max(p[i] for p in mb.positions) for i in range(3)])
    nrm = add_acc(add_view(f32([c for p in mb.normals for c in p]), 34962), 5126, "VEC3", n)
    uv = add_acc(add_view(f32([c for p in mb.uvs for c in p]), 34962), 5126, "VEC2", n)
    jnt = add_acc(add_view(struct.pack("<%dH" % (4 * n), *[c for j in mb.joints for c in j]),
                           34962), 5123, "VEC4", n)
    wgt = add_acc(add_view(f32([c for w in mb.weights for c in w]), 34962), 5126, "VEC4", n)
    idx = add_acc(add_view(struct.pack("<%dH" % len(mb.indices), *mb.indices), 34963),
                  5123, "SCALAR", len(mb.indices))
    ibm = []
    for _, _, (px, py, pz) in BONES:
        ibm += [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -px, -py, -pz, 1]  # column-major
    ibm_acc = add_acc(add_view(f32(ibm)), 5126, "MAT4", len(BONES))

    # animation: one channel per bone (rotation) plus the root's bob
    times = sample_times()
    t_acc = add_acc(add_view(f32(times)), 5126, "SCALAR", len(times), [times[0]], [times[-1]])
    samplers, channels = [], []
    poses = [pose(t) for t in times]
    for i, (name, _, _) in enumerate(BONES):
        quats = [quat_euler(*p[0][name]) for p in poses]
        out = add_acc(add_view(f32([c for q in quats for c in q])), 5126, "VEC4", len(quats))
        samplers.append({"input": t_acc, "output": out, "interpolation": "LINEAR"})
        channels.append({"sampler": len(samplers) - 1, "target": {"node": i, "path": "rotation"}})
    base = local_translation(0)
    trans = [(base[0], base[1] + p[1], base[2]) for p in poses]
    out = add_acc(add_view(f32([c for v in trans for c in v])), 5126, "VEC3", len(trans))
    samplers.append({"input": t_acc, "output": out, "interpolation": "LINEAR"})
    channels.append({"sampler": len(samplers) - 1, "target": {"node": 0, "path": "translation"}})

    nodes = []
    for i, (name, parent, _) in enumerate(BONES):
        node = {"name": name, "translation": list(local_translation(i))}
        kids = [j for j, b in enumerate(BONES) if b[1] == name]
        if kids:
            node["children"] = kids
        nodes.append(node)
    mesh_node = len(nodes)
    nodes.append({"name": "guardian_mesh", "mesh": 0, "skin": 0})

    doc = {
        "asset": {"version": "2.0", "generator": "lualore make_wooden_guardian.py"},
        "scene": 0,
        "scenes": [{"nodes": [0, mesh_node]}],
        "nodes": nodes,
        "skins": [{"joints": list(range(len(BONES))), "skeleton": 0,
                   "inverseBindMatrices": ibm_acc}],
        "meshes": [{"name": "wooden_guardian", "primitives": [{
            "attributes": {"POSITION": pos, "NORMAL": nrm, "TEXCOORD_0": uv,
                           "JOINTS_0": jnt, "WEIGHTS_0": wgt},
            "indices": idx, "material": 0}]}],
        "materials": [{"name": "bark", "pbrMetallicRoughness": {
            "baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0.0, "roughnessFactor": 0.95}}],
        "animations": [{"name": "guardian", "samplers": samplers, "channels": channels}],
        "bufferViews": views,
        "accessors": accessors,
        "buffers": [{"byteLength": len(blob), "uri": "data:application/octet-stream;base64,"
                     + base64.b64encode(bytes(blob)).decode("ascii")}],
    }

    # ---- self checks ----
    assert len(mb.indices) % 3 == 0 and max(mb.indices) < n
    assert len(mb.positions) == len(mb.joints) == len(mb.weights)
    for v in views:
        assert v["byteOffset"] + v["byteLength"] <= len(blob)
    assert all(b > a for a, b in zip(times, times[1:])), "times must increase"
    for name, (lo, hi) in CLIPS.items():
        first, last = pose(lo), pose(hi)
        for bone in first[0]:
            for a, b in zip(first[0][bone], last[0][bone]):
                assert abs(a - b) < 1e-6, "%s does not loop on %s" % (name, bone)
        assert abs(first[1] - last[1]) < 1e-6, "%s bob does not loop" % name
    return doc, mb


# --------------------------------------------------------------------
# Texture
# --------------------------------------------------------------------
def build_texture():
    size = 128
    img = Image.new("RGBA", (size, size))
    px = img.load()

    def noise(x, y, s):
        v = math.sin(x * 12.9898 + y * 78.233 + s * 37.719) * 43758.5453
        return v - math.floor(v)

    def zone_box(z):
        u0, v0, u1, v1 = ZONES[z]
        return int(u0 * size), int(v0 * size), int(u1 * size), int(v1 * size)

    def bark_pixel(x, y, x0, y0, w, h, dark=0.0):
        # vertical ridges with a wavering grain
        ridge = math.sin((x - x0) * 0.9 + math.sin((y - y0) * 0.21) * 1.6)
        n = noise(x, y, 1) * 0.25
        k = 0.55 + 0.25 * ridge + n - dark
        return (int(92 * k + 18), int(62 * k + 12), int(36 * k + 8), 255)

    x0, y0, x1, y1 = zone_box("bark")
    for y in range(y0, y1):
        for x in range(x0, x1):
            px[x, y] = bark_pixel(x, y, x0, y0, x1 - x0, y1 - y0)

    x0, y0, x1, y1 = zone_box("face")
    for y in range(y0, y1):
        for x in range(x0, x1):
            px[x, y] = bark_pixel(x, y, x0, y0, x1 - x0, y1 - y0, 0.05)
    w, h = x1 - x0, y1 - y0
    d = ImageDraw.Draw(img)
    for cx in (x0 + w * 0.30, x0 + w * 0.70):            # carved sockets, glowing knots
        cy = y0 + h * 0.42
        d.ellipse([cx - 7, cy - 6, cx + 7, cy + 6], fill=(30, 18, 10, 255))
        d.ellipse([cx - 4, cy - 3, cx + 4, cy + 3], fill=(255, 180, 40, 255))
        d.ellipse([cx - 2, cy - 2, cx + 1, cy + 1], fill=(255, 240, 160, 255))
    d.rectangle([x0 + w * 0.32, y0 + h * 0.70, x0 + w * 0.68, y0 + h * 0.76], fill=(36, 22, 12, 255))

    x0, y0, x1, y1 = zone_box("ends")
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    for y in range(y0, y1):
        for x in range(x0, x1):
            r = math.hypot(x - cx, y - cy)
            ring = 0.5 + 0.5 * math.sin(r * 1.1 + noise(x, y, 3) * 0.8)
            edge = r > (x1 - x0) * 0.46
            if edge:
                px[x, y] = bark_pixel(x, y, x0, y0, 1, 1, 0.1)
            else:
                k = 0.75 + 0.25 * ring
                px[x, y] = (int(176 * k), int(132 * k), int(82 * k), 255)

    x0, y0, x1, y1 = zone_box("moss")
    for y in range(y0, y1):
        for x in range(x0, x1):
            k = 0.6 + 0.4 * noise(x, y, 5)
            px[x, y] = (int(58 * k), int(118 * k), int(40 * k), 255)

    x0, y0, x1, y1 = zone_box("knot")
    for y in range(y0, y1):
        for x in range(x0, x1):
            swirl = math.sin(math.hypot(x - x0 - 20, y - y0 - 14) * 0.7)
            k = 0.45 + 0.2 * swirl + 0.2 * noise(x, y, 7)
            px[x, y] = (int(86 * k + 14), int(56 * k + 10), int(32 * k + 6), 255)
    return img


def build_heart_textures():
    """16x16 tiles for the Guardian Heart node: a carved front with a
    glowing knot, plank sides, and a ring-grain top."""
    def noise(x, y, s):
        v = math.sin(x * 12.9898 + y * 78.233 + s * 37.719) * 43758.5453
        return v - math.floor(v)

    def plank(x, y):
        k = 0.7 + 0.15 * math.sin(x * 1.3 + y * 0.2) + 0.15 * noise(x, y, 2)
        if y % 8 == 0:
            k *= 0.7  # plank seam
        return (int(150 * k), int(104 * k), int(60 * k), 255)

    side = Image.new("RGBA", (16, 16))
    for y in range(16):
        for x in range(16):
            side.putpixel((x, y), plank(x, y))
    front = side.copy()
    for y in range(16):
        for x in range(16):
            r = math.hypot(x - 7.5, y - 7.5)
            if r < 2.2:
                front.putpixel((x, y), (255, 236, 150, 255))
            elif r < 3.6:
                front.putpixel((x, y), (250, 170, 40, 255))
            elif r < 5.2:
                front.putpixel((x, y), (54, 32, 16, 255))
    top = Image.new("RGBA", (16, 16))
    for y in range(16):
        for x in range(16):
            r = math.hypot(x - 7.5, y - 7.5)
            if r > 7.2:
                top.putpixel((x, y), (80, 54, 30, 255))
            else:
                k = 0.78 + 0.22 * math.sin(r * 1.7)
                top.putpixel((x, y), (int(186 * k), int(140 * k), int(88 * k), 255))
    return {"lualore_guardian_heart.png": front, "lualore_guardian_heart_side.png": side,
            "lualore_guardian_heart_top.png": top}


# --------------------------------------------------------------------
# Preview: skin the mesh on the CPU and draw it
# --------------------------------------------------------------------
def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def mat_rt(q, t):
    x, y, z, w = q
    return [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), t[0]],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), t[1]],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), t[2]],
            [0, 0, 0, 1]]


def skin_matrices(t):
    rot, bob = pose(t)
    world = [None] * len(BONES)
    for i, (name, parent, pivot) in enumerate(BONES):
        tr = local_translation(i)
        if parent is None:
            tr = (tr[0], tr[1] + bob, tr[2])
        local = mat_rt(quat_euler(*rot[name]), tr)
        world[i] = local if parent is None else mat_mul(world[BONE_INDEX[parent]], local)
    out = []
    for i, (_, _, (px, py, pz)) in enumerate(BONES):
        ibm = [[1, 0, 0, -px], [0, 1, 0, -py], [0, 0, 1, -pz], [0, 0, 0, 1]]
        out.append(mat_mul(world[i], ibm))
    return out


ZONE_COLOUR = {"bark": (110, 76, 44), "face": (120, 84, 50), "ends": (170, 128, 80),
               "moss": (66, 128, 46), "knot": (84, 56, 32)}


def render(mb, t, view, scale=8, size=(320, 320)):
    mats = skin_matrices(t)
    img = Image.new("RGB", size, (200, 214, 230))
    d = ImageDraw.Draw(img)
    quads = []
    for q in range(len(mb.indices) // 6):
        o = mb.indices[q * 6]
        pts = []
        for k in range(4):
            v = mb.positions[o + k]
            m = mats[mb.joints[o + k][0]]
            pts.append([sum(m[r][c] * (list(v) + [1])[c] for c in range(4)) for r in range(3)])
        nrm = cross([pts[1][i] - pts[0][i] for i in range(3)], [pts[2][i] - pts[0][i] for i in range(3)])
        ln = math.sqrt(sum(c * c for c in nrm)) or 1
        nrm = [c / ln for c in nrm]
        if view == "front":       # looking along +Z at the face (which is at -Z)
            proj = [(-p[0], p[1], -p[2]) for p in pts]
            facing = -nrm[2]
        else:                     # from the model's left (+X)
            proj = [(p[2], p[1], p[0]) for p in pts]
            facing = nrm[0]
        if facing <= 0:
            continue
        depth = sum(p[2] for p in proj) / 4
        light = 0.55 + 0.45 * max(0, nrm[1] * 0.5 + facing * 0.7)
        col = tuple(int(c * light) for c in ZONE_COLOUR[mb.face_zone[q]])
        quads.append((depth, proj, col))
    quads.sort(key=lambda q: q[0])
    for _, proj, col in quads:
        d.polygon([(size[0] / 2 + p[0] * scale, size[1] - 20 - p[1] * scale) for p in proj],
                  fill=col, outline=(40, 28, 18))
    # a player-height marker (2 nodes = 20 units) for scale
    d.line([(14, size[1] - 20), (14, size[1] - 20 - 20 * scale)], fill=(200, 30, 30), width=3)
    return img


def main():
    doc, mb = build_gltf()
    with open(MODEL_PATH, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
    build_texture().save(TEXTURE_PATH)
    for name, img in build_heart_textures().items():
        img.save(os.path.join("textures", name))
    lo = [min(p[i] for p in mb.positions) for i in range(3)]
    hi = [max(p[i] for p in mb.positions) for i in range(3)]
    print("wrote %s (%d vertices, %d triangles, %d bones)" % (
        MODEL_PATH, len(mb.positions), len(mb.indices) // 3, len(BONES)))
    print("  extent x %.1f, y %.1f, z %.1f units (%.2f nodes tall)" % (
        hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], (hi[1] - lo[1]) / 10))
    print("wrote %s" % TEXTURE_PATH)
    if "--preview" in sys.argv:
        out = sys.argv[sys.argv.index("--preview") + 1]
        os.makedirs(out, exist_ok=True)
        shots = [("idle", 0.0), ("walk", 2.75), ("windup", 4.36), ("slam", 4.5)]
        sheet = Image.new("RGB", (320 * len(shots), 640), (255, 255, 255))
        for i, (label, t) in enumerate(shots):
            sheet.paste(render(mb, t, "front"), (320 * i, 0))
            sheet.paste(render(mb, t, "side"), (320 * i, 320))
            ImageDraw.Draw(sheet).text((320 * i + 8, 6), label, fill=(0, 0, 0))
        sheet.save(os.path.join(out, "guardian_preview.png"))
        print("wrote preview %s" % os.path.join(out, "guardian_preview.png"))


if __name__ == "__main__":
    main()
