#!/usr/bin/env python3
"""Generate the Mirror Sentinel model and texture for lualore.

Outputs
-------
models/mirror_sentinel.gltf    (JSON glTF 2.0, base64-embedded buffer)
textures/mirror_sentinel.png   (128x128 procedural texture)

The Sentinel is an original flying construct built purely from boxes:

  * a black obelisk core with four mirror-glass face plates
  * a crown of spikes (animated with a slow sway)
  * four shard slabs orbiting the core (animated rotation)
  * the whole core hovers (animated translation)

Implementation notes (verified against Luanti 5.14 / docs.luanti.org):
  * entities always use a 10x mesh scale: 10 units = 1 node
  * only the first glTF animation is played; its timestamps are seconds
  * skeletal animation with weight-1 bones is the well-supported path;
    all bones rest at the origin with identity inverse bind matrices, so
    vertex data lives directly in model space and animating a bone gives
    a clean delta transform (translation for hover, Y-rotation to orbit
    the shards around the core).

Run from the mod root:
    python tools/make_mirror_sentinel.py
"""

import base64
import json
import math
import os
import struct

from PIL import Image, ImageDraw, ImageFilter

MODEL_PATH = os.path.join("models", "mirror_sentinel.gltf")
TEXTURE_PATH = os.path.join("textures", "mirror_sentinel.png")

# --------------------------------------------------------------------
# Geometry helpers
# --------------------------------------------------------------------

# Bone indices used by the skin.
BONE_CORE = 0
BONE_ORBIT = 1
BONE_CROWN = 2

# Texture UV zones (u0, v0, u1, v1), origin top-left like glTF.
ZONES = {
    "hull":  (0.00, 0.00, 0.50, 0.50),
    "face":  (0.50, 0.00, 1.00, 0.50),
    "shard": (0.00, 0.50, 0.50, 1.00),
    "crown": (0.50, 0.50, 1.00, 1.00),
}

# Per-face (right, up) vectors giving counter-clockwise winding when
# viewed from outside (right x up == outward normal).
FACE_AXES = {
    (1, 0, 0):  ((0, 0, -1), (0, 1, 0)),
    (-1, 0, 0): ((0, 0, 1), (0, 1, 0)),
    (0, 1, 0):  ((1, 0, 0), (0, 0, -1)),
    (0, -1, 0): ((1, 0, 0), (0, 0, 1)),
    (0, 0, 1):  ((1, 0, 0), (0, 1, 0)),
    (0, 0, -1): ((-1, 0, 0), (0, 1, 0)),
}


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


class MeshBuilder:
    def __init__(self):
        self.positions = []
        self.normals = []
        self.uvs = []
        self.joints = []
        self.weights = []
        self.indices = []

    def add_box(self, center, size, zone, bone):
        cx, cy, cz = center
        hw, hh, hd = size[0] / 2.0, size[1] / 2.0, size[2] / 2.0
        u0, v0, u1, v1 = ZONES[zone]
        inset = 1.0 / 128.0  # keep clear of texture zone borders
        u0, v0, u1, v1 = u0 + inset, v0 + inset, u1 - inset, v1 - inset

        for normal, (right, up) in FACE_AXES.items():
            # Half-extent of the face along its own right/up axes.
            rh = hw if right[0] != 0 else (hh if right[1] != 0 else hd)
            uh = hh if up[1] != 0 else (hw if up[0] != 0 else hd)
            n = normal

            corners = [
                (-rh, -uh), (rh, -uh), (rh, uh), (-rh, uh),
            ]
            verts = []
            for ru, rv in corners:
                x = cx + right[0] * ru + up[0] * rv
                y = cy + right[1] * ru + up[1] * rv
                z = cz + right[2] * ru + up[2] * rv
                verts.append((x, y, z))

            # Winding self-check: (v1-v0) x (v2-v0) must face outward.
            a = tuple(verts[1][i] - verts[0][i] for i in range(3))
            b = tuple(verts[2][i] - verts[0][i] for i in range(3))
            c = cross(a, b)
            if c[0] * n[0] + c[1] * n[1] + c[2] * n[2] <= 0:
                raise AssertionError("bad winding for face %s" % (n,))

            uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
            for pos, tex in zip(verts, uv):
                self.positions.append(pos)
                self.normals.append(n)
                self.uvs.append(tex)
                self.joints.append((bone, 0, 0, 0))
                self.weights.append((1.0, 0.0, 0.0, 0.0))

            o = len(self.positions) - 4
            self.indices += [o, o + 1, o + 2, o, o + 2, o + 3]


def build_mesh():
    mb = MeshBuilder()

    # --- core obelisk (bone: core) ---
    mb.add_box((0, -4.0, 0), (9, 8, 9), "hull", BONE_CORE)
    mb.add_box((0, 3.0, 0), (7, 11, 7), "hull", BONE_CORE)
    mb.add_box((0, 8.5, 0), (9, 2, 9), "hull", BONE_CORE)
    mb.add_box((0, -9.5, 0), (6, 3, 6), "hull", BONE_CORE)
    mb.add_box((0, -12.0, 0), (3, 2, 3), "hull", BONE_CORE)

    # --- mirror face plates on all four sides (bone: core) ---
    mb.add_box((0, 1.5, 5.5), (6, 9, 1), "face", BONE_CORE)
    mb.add_box((0, 1.5, -5.5), (6, 9, 1), "face", BONE_CORE)
    mb.add_box((5.5, 1.5, 0), (1, 9, 6), "face", BONE_CORE)
    mb.add_box((-5.5, 1.5, 0), (1, 9, 6), "face", BONE_CORE)

    # --- crown (bone: crown) ---
    mb.add_box((0, 12.0, 0), (3, 6, 3), "crown", BONE_CROWN)
    mb.add_box((3.5, 11.0, 0), (2.5, 4, 2.5), "crown", BONE_CROWN)
    mb.add_box((-3.5, 11.0, 0), (2.5, 4, 2.5), "crown", BONE_CROWN)
    mb.add_box((0, 11.0, 3.5), (2.5, 4, 2.5), "crown", BONE_CROWN)
    mb.add_box((0, 11.0, -3.5), (2.5, 4, 2.5), "crown", BONE_CROWN)

    # --- orbiting shards (bone: orbit) ---
    mb.add_box((9, 0, 0), (2, 14, 7), "shard", BONE_ORBIT)
    mb.add_box((-9, 0, 0), (2, 14, 7), "shard", BONE_ORBIT)
    mb.add_box((0, 0, 9), (7, 14, 2), "shard", BONE_ORBIT)
    mb.add_box((0, 0, -9), (7, 14, 2), "shard", BONE_ORBIT)

    return mb


# --------------------------------------------------------------------
# glTF assembly
# --------------------------------------------------------------------

def pack_accessors(mb):
    """Serialize all arrays into one buffer and build the JSON tables."""
    blob = bytearray()
    buffer_views = []
    accessors = []

    def add_view(data, target=None):
        # 4-byte alignment for every view start.
        while len(blob) % 4:
            blob.append(0)
        view = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)}
        if target:
            view["target"] = target
        buffer_views.append(view)
        blob.extend(data)
        return len(buffer_views) - 1

    def add_accessor(data, view, comp_type, acc_type, count, vmin=None, vmax=None):
        acc = {
            "bufferView": view,
            "componentType": comp_type,
            "count": count,
            "type": acc_type,
        }
        if vmin is not None:
            acc["min"] = vmin
            acc["max"] = vmax
        accessors.append(acc)
        return len(accessors) - 1

    def f32(values):
        return struct.pack("<%df" % len(values), *values)

    count = len(mb.positions)

    flat_pos = [c for p in mb.positions for c in p]
    pos_view = add_view(f32(flat_pos), 34962)
    pos_min = [min(p[i] for p in mb.positions) for i in range(3)]
    pos_max = [max(p[i] for p in mb.positions) for i in range(3)]
    pos_acc = add_accessor(None, pos_view, 5126, "VEC3", count, pos_min, pos_max)

    flat_nrm = [c for n in mb.normals for c in n]
    nrm_view = add_view(f32(flat_nrm), 34962)
    nrm_acc = add_accessor(None, nrm_view, 5126, "VEC3", count)

    flat_uv = [c for t in mb.uvs for c in t]
    uv_view = add_view(f32(flat_uv), 34962)
    uv_acc = add_accessor(None, uv_view, 5126, "VEC2", count)

    flat_joints = [c for j in mb.joints for c in j]
    joint_view = add_view(struct.pack("<%dH" % len(flat_joints), *flat_joints), 34962)
    joint_acc = add_accessor(None, joint_view, 5123, "VEC4", count)

    flat_weights = [c for w in mb.weights for c in w]
    weight_view = add_view(f32(flat_weights), 34962)
    weight_acc = add_accessor(None, weight_view, 5126, "VEC4", count)

    idx_view = add_view(struct.pack("<%dH" % len(mb.indices), *mb.indices), 34963)
    idx_acc = add_accessor(None, idx_view, 5123, "SCALAR", len(mb.indices))

    # Identity inverse bind matrices: every bone rests at the origin.
    identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    ibm_view = add_view(f32(identity * 3))
    ibm_acc = add_accessor(None, ibm_view, 5126, "MAT4", 3)

    return blob, buffer_views, accessors, pos_acc, nrm_acc, uv_acc, joint_acc, \
        weight_acc, idx_acc, ibm_acc


def quat_y(degrees):
    half = math.radians(degrees) / 2.0
    return (0.0, math.sin(half), 0.0, math.cos(half))


def quat_x(degrees):
    half = math.radians(degrees) / 2.0
    return (math.sin(half), 0.0, 0.0, math.cos(half))


def pack_animation(blob, buffer_views, accessors):
    """Append animation sampler data and return animation channels."""
    def add_view(data):
        while len(blob) % 4:
            blob.append(0)
        buffer_views.append({"buffer": 0, "byteOffset": len(blob),
                             "byteLength": len(data)})
        blob.extend(data)
        return len(buffer_views) - 1

    def add_accessor(view, comp_type, acc_type, count):
        accessors.append({
            "bufferView": view,
            "componentType": comp_type,
            "count": count,
            "type": acc_type,
        })
        return len(accessors) - 1

    def floats(values):
        return struct.pack("<%df" % len(values), *values)

    samplers = []
    channels = []

    def add_channel(node, path, times, values, comp_count):
        view_in = add_view(floats(times))
        acc_in = add_accessor(view_in, 5126, "SCALAR", len(times))
        flat = [c for v in values for c in v]
        view_out = add_view(floats(flat))
        acc_type = "VEC3" if comp_count == 3 else "VEC4"
        acc_out = add_accessor(view_out, 5126, acc_type, len(values))
        samplers.append({"input": acc_in, "output": acc_out,
                         "interpolation": "LINEAR"})
        channels.append({"sampler": len(samplers) - 1,
                         "target": {"node": node, "path": path}})

    # Core hover: gentle bob (plus/minus 0.7 units = 0.07 nodes).
    add_channel(1, "translation",
                [0, 1, 2, 3, 4],
                [(0, 0.7, 0), (0, 0, 0), (0, -0.7, 0), (0, 0, 0), (0, 0.7, 0)],
                3)

    # Shard counter-bob for a floaty feel.
    add_channel(2, "translation",
                [0, 1, 2, 3, 4],
                [(0, -0.5, 0), (0, 0, 0), (0, 0.5, 0), (0, 0, 0), (0, -0.5, 0)],
                3)

    # Shard orbit: one full turn per 4 seconds, quarter keys so the
    # direction is unambiguous.
    add_channel(2, "rotation",
                [0, 1, 2, 3, 4],
                [quat_y(0), quat_y(90), quat_y(180), quat_y(270), quat_y(360)],
                4)

    # Crown sway: slow left/right tilt.
    add_channel(3, "rotation",
                [0, 2, 4],
                [quat_x(4), quat_x(-4), quat_x(4)],
                4)

    return samplers, channels


def build_gltf():
    mb = build_mesh()
    blob, buffer_views, accessors, pos_acc, nrm_acc, uv_acc, joint_acc, \
        weight_acc, idx_acc, ibm_acc = pack_accessors(mb)

    samplers, channels = pack_animation(blob, buffer_views, accessors)

    doc = {
        "asset": {"version": "2.0", "generator": "lualore make_mirror_sentinel.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {"name": "root", "children": [1, 2, 3, 4]},
            {"name": "core"},
            {"name": "orbit"},
            {"name": "crown"},
            {"name": "sentinel_mesh", "mesh": 0, "skin": 0},
        ],
        "skins": [{
            "joints": [1, 2, 3],
            "skeleton": 0,
            "inverseBindMatrices": ibm_acc,
        }],
        "meshes": [{
            "name": "mirror_sentinel",
            "primitives": [{
                "attributes": {
                    "POSITION": pos_acc,
                    "NORMAL": nrm_acc,
                    "TEXCOORD_0": uv_acc,
                    "JOINTS_0": joint_acc,
                    "WEIGHTS_0": weight_acc,
                },
                "indices": idx_acc,
                "material": 0,
            }],
        }],
        "materials": [{
            "name": "sentinel",
            "pbrMetallicRoughness": {
                "baseColorFactor": [1, 1, 1, 1],
                "metallicFactor": 0.0,
                "roughnessFactor": 0.85,
            },
        }],
        "animations": [{
            "name": "idle",
            "samplers": samplers,
            "channels": channels,
        }],
        "bufferViews": buffer_views,
        "accessors": accessors,
        "buffers": [{
            "byteLength": len(blob),
            "uri": "data:application/octet-stream;base64,"
                   + base64.b64encode(bytes(blob)).decode("ascii"),
        }],
    }

    # ---- self checks -------------------------------------------------
    assert len(mb.indices) % 3 == 0
    assert max(mb.indices) < len(mb.positions)
    assert len(mb.positions) == len(mb.joints) == len(mb.weights)
    for view in buffer_views:
        assert view["byteOffset"] + view["byteLength"] <= len(blob)

    return doc, mb


# --------------------------------------------------------------------
# Texture
# --------------------------------------------------------------------

def build_texture():
    size = 128
    top = (20, 16, 31)
    bottom = (13, 10, 21)
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = row
    draw = ImageDraw.Draw(img, "RGBA")

    # Panel grid over the whole texture.
    for x in range(0, size, 16):
        draw.line([(x, 0), (x, size)], fill=(42, 33, 64, 255))
    for y in range(0, size, 16):
        draw.line([(0, y), (size, y)], fill=(42, 33, 64, 255))

    # Rivets at panel corners.
    for x in range(8, size, 16):
        for y in range(8, size, 16):
            draw.ellipse([x - 1, y - 1, x + 1, y + 1], fill=(58, 47, 82, 255))

    # Hull zone scratches.
    for i in range(14):
        x0 = 4 + (i * 11) % 56
        y0 = 4 + (i * 17) % 56
        draw.line([(x0, y0), (x0 + 7, y0 + 3)], fill=(10, 8, 17, 200), width=1)

    # Mirror face zone: radial sheen + cracks + rune ring.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    center = (96, 32)
    for r, alpha in ((26, 40), (20, 55), (14, 70)):
        gdraw.ellipse([center[0] - r, center[1] - r,
                       center[0] + r, center[1] + r],
                      outline=(176, 144, 255, alpha), width=2)
    # Cracks radiating from the mirror centre.
    for angle in range(0, 360, 45):
        rad = math.radians(angle)
        x1 = center[0] + math.cos(rad) * 6
        y1 = center[1] + math.sin(rad) * 6
        x2 = center[0] + math.cos(rad) * 27
        y2 = center[1] + math.sin(rad) * 27
        mx = center[0] + math.cos(rad + 0.25) * 17
        my = center[1] + math.sin(rad + 0.25) * 17
        gdraw.line([(x1, y1), (mx, my), (x2, y2)],
                   fill=(203, 179, 255, 150), width=1)
    glow = glow.filter(ImageFilter.GaussianBlur(1.2))
    img.paste(Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB"),
              (0, 0))

    # Shard zone: long streaks along the slab axis.
    for i in range(0, 64, 6):
        shade = 40 if (i // 6) % 2 else 30
        draw.line([(i, 64), (i + 16, 128)], fill=(shade, shade - 8, shade + 14, 180))

    # Crown zone: darker with bright rune ticks.
    draw.rectangle([64, 64, 128, 128], fill=(15, 12, 24, 90))
    for i in range(8):
        x = 70 + i * 7
        draw.line([(x, 72), (x, 120)], fill=(36, 28, 56, 220))
    for i in range(4):
        x = 74 + i * 14
        draw.line([(x, 92), (x + 4, 96), (x, 100)], fill=(176, 144, 255, 200))

    # Zone borders to avoid bleeding.
    for x0, y0, x1, y1 in ((0, 0, 63, 63), (65, 0, 127, 63),
                           (0, 65, 63, 127), (65, 65, 127, 127)):
        draw.rectangle([x0, y0, x1, y1], outline=(8, 6, 14, 255))

    img.save(TEXTURE_PATH)
    return size


# --------------------------------------------------------------------

def main():
    os.makedirs("models", exist_ok=True)
    os.makedirs("textures", exist_ok=True)

    doc, mb = build_gltf()
    with open(MODEL_PATH, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))

    tex_size = build_texture()

    xs = [p[0] for p in mb.positions]
    ys = [p[1] for p in mb.positions]
    zs = [p[2] for p in mb.positions]
    print("wrote %s (%d bytes)" % (MODEL_PATH, os.path.getsize(MODEL_PATH)))
    print("wrote %s (%dx%d)" % (TEXTURE_PATH, tex_size, tex_size))
    print("vertices: %d, triangles: %d" % (len(mb.positions), len(mb.indices) // 3))
    print("model extents (units, 10 units = 1 node):")
    print("  x: %.1f .. %.1f  (%.2f nodes)" % (min(xs), max(xs), (max(xs) - min(xs)) / 10))
    print("  y: %.1f .. %.1f  (%.2f nodes)" % (min(ys), max(ys), (max(ys) - min(ys)) / 10))
    print("  z: %.1f .. %.1f  (%.2f nodes)" % (min(zs), max(zs), (max(zs) - min(zs)) / 10))


if __name__ == "__main__":
    main()
