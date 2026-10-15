#!/usr/bin/env python3
"""Combine all animations of a glTF file into one continuous timeline.

Why: Luanti (<= 5.14) supports only a *single* animation for .gltf models and
uses the animation time values (seconds) as animation frame numbers for
`set_animation({x = start, y = end}, 1)`. Blockbench exports one glTF animation
per animation clip, which older Luanti versions cannot select between.

This tool concatenates the chosen clips back to back into a single animation
("combined") whose timeline starts at 0. The result is a drop-in model where
frame ranges select each clip:

    clip 1: 0.000 .. d1
    clip 2: d1    .. d1+d2
    ...

ONE TRACK PER BONE. The glTF specification requires that, within a single
animation, each (node, path) target is driven by at most one channel. An
earlier version of this tool appended each clip's channels unchanged, so a
bone animated in three clips ended up with three channels fighting over it -
invalid glTF, and in practice whichever one the renderer applied last won.
Worse, glTF samplers CLAMP outside their own time range, so a bone animated
only in the walk clip held the walk's first pose for the whole of the idle
clip: the Lit stood in a mid-stride stance, then snapped when the clip
changed. Both faults are why the animations looked clunky irrespective of how
they were authored.

So channels are merged here. For every bone the tool emits exactly one track
covering the whole timeline, and in segments where a clip does not animate
that bone it holds the bone's REST pose - which is what the clip looks like in
Blockbench, where an untouched bone simply stays where it is.

Usage:
    python tools/combine_gltf_animations.py [options] in.gltf out.gltf [name...]

Options:
    --gap SECONDS     guard gap between clips (default 0.25)
    --smooth N        sub-samples per authored key when baking easing
                      (default 8; 0 or 1 disables)
    --no-close-loops  keep clips exactly as authored, snap and all

If no names are given, every animation is used in file order. The output keeps
the skinned mesh, materials and buffers of the source and contains exactly one
animation; the original animations are not included.
"""

import base64
import json
import math
import os
import struct
import sys

FLOAT = 5126  # GL_FLOAT

# How much to nudge a key that lands exactly on a clip boundary, so times stay
# strictly increasing. A millisecond is far below one rendered frame.
EPSILON = 0.001

CLIP, FILL_START, FILL_END = 0, 1, 2   # where a merged key came from

# Clips are separated by a short guard gap so no frame belongs to two clips.
# Without it clip N's last frame is clip N+1's first, and whichever pose loses
# shows for a frame every time its clip loops - the Lit's idle would flash a
# walking stance each time it came round. Nothing is ever played inside the
# gap, so its length only has to be larger than one rendered frame.
DEFAULT_GAP = 0.25

# Sub-samples inserted between each pair of authored keys when smoothing.
# Lit's keys are 0.25 apart and play at 1.0 frame-units/second, so 8 puts a
# sample every ~31 ms - roughly two rendered frames, where the straight lines
# between samples stop being distinguishable from the curve. Higher just costs
# file size: measured peak angular acceleration across the walk was 24300
# deg/s^2 unsmoothed, 18000 at 4, 9600 at 8 and 5000 at 16.
DEFAULT_SMOOTH = 8

COMPONENTS = {"translation": 3, "rotation": 4, "scale": 3}
TYPE_NAME = {3: "VEC3", 4: "VEC4"}
REST_DEFAULT = {"translation": [0.0, 0.0, 0.0],
                "rotation": [0.0, 0.0, 0.0, 1.0],
                "scale": [1.0, 1.0, 1.0]}


def read_floats(doc, blob, accessor_index, components):
    """Read a float accessor as a list of `components`-long lists."""
    acc = doc["accessors"][accessor_index]
    if acc["componentType"] != FLOAT:
        raise SystemExit("only float animation data is supported")
    if "sparse" in acc:
        raise SystemExit("sparse accessors are not supported")
    bv = doc["bufferViews"][acc["bufferView"]]
    stride = bv.get("byteStride") or (4 * components)
    offset = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    out = []
    for i in range(acc["count"]):
        out.append(list(struct.unpack_from("<" + "f" * components, blob,
                                           offset + i * stride)))
    return out


def read_scalar_floats(doc, blob, accessor_index):
    return [v[0] for v in read_floats(doc, blob, accessor_index, 1)]


def load_buffer(doc, in_path):
    buf = doc["buffers"][0]
    uri = buf.get("uri")
    if not uri:
        raise SystemExit("buffer 0 has no uri (embedded .glb is not supported)")
    if uri.startswith("data:"):
        return bytearray(base64.b64decode(uri.split(",", 1)[1]))
    with open(os.path.join(os.path.dirname(in_path), uri), "rb") as f:
        return bytearray(f.read())


def append_accessor(doc, blob, new_views, new_accessors, values, components):
    """Write a float accessor and return its index."""
    flat = []
    for v in values:
        flat.extend(v)
    data = b"".join(struct.pack("<f", x) for x in flat)
    pad = (4 - (len(blob) % 4)) % 4   # keep every bufferView 4-byte aligned
    if pad:
        blob.extend(b"\0" * pad)
    view_index = len(doc["bufferViews"]) + len(new_views)
    new_views.append({"buffer": 0, "byteOffset": len(blob),
                      "byteLength": len(data)})
    blob.extend(data)

    acc = {
        "bufferView": view_index,
        "componentType": FLOAT,
        "count": len(values),
        "type": "SCALAR" if components == 1 else TYPE_NAME[components],
    }
    if components == 1:
        acc["min"] = [min(x[0] for x in values)]
        acc["max"] = [max(x[0] for x in values)]
    acc_index = len(doc["accessors"]) + len(new_accessors)
    new_accessors.append(acc)
    return acc_index


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else 0.0


def align_signs(values):
    """Make a quaternion track sign-continuous.

    q and -q are the same rotation, but a sign flip between neighbouring keys
    makes any interpolation take the long way round - a bone snapping through
    a full turn. Exporters flip signs freely, so fix it before interpolating.
    """
    out = [list(values[0])]
    for v in values[1:]:
        if sum(a * b for a, b in zip(out[-1], v)) < 0.0:
            v = [-x for x in v]
        out.append(list(v))
    return out


def catmull_rom(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    return [0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2
                   + (-a + 3 * b - 3 * c + d) * t3)
            for a, b, c, d in zip(p0, p1, p2, p3)]


def normalise(v):
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v] if n else list(v)


def close_loop(clip_tracks, end_time):
    """End every track of a clip on the pose it started from.

    Every clip here is played on a loop, so its last frame interpolates back
    into its first. A clip that stops partway through its cycle therefore
    snaps: Lit's walk is six one-second strides cut off at 5.75s, so looping
    it jumps the last quarter of a stride, which reads as a lurch once per
    cycle. Repeating the opening pose at the end removes the jump without
    touching the authored keys.
    """
    for track in clip_tracks.values():
        if not track["times"]:
            continue
        if track["times"][-1] >= end_time - 1e-9:
            continue
        first = track["values"][:track["per_key"]]
        track["times"] = track["times"] + [end_time]
        track["values"] = track["values"] + [list(v) for v in first]


def smooth_track(track, subdivisions):
    """Resample a LINEAR track along a Catmull-Rom spline through its keys.

    Luanti's glTF support reads LINEAR samplers, so easing cannot be expressed
    as an interpolation mode - straight lines between four poses per stride is
    what makes the motion read as mechanical. Resampling bakes the curve into
    denser LINEAR keys instead, which renders identically everywhere.

    A track whose first and last poses match is treated as a loop, so its
    tangents wrap and the loop point is smooth in speed as well as position.
    """
    if track["per_key"] != 1 or subdivisions < 2:
        return
    times, values = track["times"], track["values"]
    if len(times) < 3:
        return
    comps = len(values[0])
    vals = align_signs(values) if comps == 4 else [list(v) for v in values]
    looped = max(abs(a - b) for a, b in zip(vals[0], vals[-1])) < 1e-6
    n = len(vals)

    def at(i):
        if looped:
            # the duplicated end key is the same pose as the start, so step
            # over it when wrapping
            return vals[i % (n - 1)]
        return vals[max(0, min(n - 1, i))]

    out_t, out_v = [], []
    for i in range(n - 1):
        a, b = vals[i], vals[i + 1]
        flat = max(abs(x - y) for x, y in zip(a, b)) < 1e-6
        steps = 1 if flat else subdivisions
        for k in range(steps):
            f = k / steps
            t = times[i] + (times[i + 1] - times[i]) * f
            v = a if f == 0.0 else catmull_rom(at(i - 1), a, b, at(i + 2), f)
            out_t.append(t)
            out_v.append(normalise(v) if comps == 4 else v)
    out_t.append(times[-1])
    out_v.append(vals[-1])
    track["times"], track["values"] = out_t, out_v


def rest_pose(doc, node_index, path):
    node = doc["nodes"][node_index]
    value = node.get(path)
    if value is None:
        return list(REST_DEFAULT[path])
    return list(value)


def main():
    if len(sys.argv) < 3 or "-h" in sys.argv or "--help" in sys.argv:
        print(__doc__)
        return 1
    argv = sys.argv[1:]
    gap = DEFAULT_GAP
    smooth = DEFAULT_SMOOTH
    closing = True
    for flag, cast in (("--gap", float), ("--smooth", int)):
        if flag in argv:
            i = argv.index(flag)
            value = cast(argv[i + 1])
            del argv[i:i + 2]
            if flag == "--gap":
                gap = value
            else:
                smooth = value
    if "--no-close-loops" in argv:
        closing = False
        argv.remove("--no-close-loops")
    in_path, out_path = argv[0], argv[1]
    wanted = argv[2:]

    with open(in_path, encoding="utf-8") as f:
        doc = json.load(f)

    blob = load_buffer(doc, in_path)
    animations = doc.get("animations") or []
    if wanted:
        by_name = {a.get("name"): a for a in animations}
        chosen = []
        for name in wanted:
            if name not in by_name:
                raise SystemExit(
                    "animation %r not found (available: %s)" % (name, list(by_name))
                )
            chosen.append(by_name[name])
    else:
        chosen = animations
    if not chosen:
        raise SystemExit("no animations to combine")

    # ---- pull every clip apart into per-target tracks -----------------
    # clips[i][(node, path)] = {"times": [...], "values": [[...]], "interp": str}
    clips = []
    durations = []
    for anim in chosen:
        tracks = {}
        duration = 0.0
        for ch in anim["channels"]:
            src = anim["samplers"][ch["sampler"]]
            target = ch["target"]
            node = target.get("node")
            path = target["path"]
            if node is None:
                continue
            if path not in COMPONENTS:
                raise SystemExit("unsupported animation path %r" % path)
            interp = src.get("interpolation", "LINEAR")
            comps = COMPONENTS[path]
            times = read_scalar_floats(doc, blob, src["input"])
            # CUBICSPLINE stores in-tangent, value and out-tangent per key.
            per_key = 3 if interp == "CUBICSPLINE" else 1
            values = read_floats(doc, blob, src["output"], comps)
            if len(values) != len(times) * per_key:
                raise SystemExit(
                    "channel on %s.%s has %d values for %d keys"
                    % (node, path, len(values), len(times)))
            key = (node, path)
            if key in tracks:
                # Two channels for one target inside a single source clip is
                # already invalid; keep the first and say so.
                print("  warning: %s.%s is targeted twice in %r, keeping the first"
                      % (doc["nodes"][node].get("name", node), path,
                         anim.get("name")))
                continue
            tracks[key] = {"times": times, "values": values, "interp": interp,
                           "per_key": per_key}
            duration = max(duration, max(times) if times else 0.0)
        clips.append(tracks)
        durations.append(duration)

    # Close each clip's loop, then bake easing into denser keys. Both run
    # per clip, before the clips are concatenated, so nothing is ever
    # smoothed across a clip boundary.
    for i, tracks in enumerate(clips):
        if closing and tracks:
            step = median([b - a for track in tracks.values()
                           for a, b in zip(track["times"], track["times"][1:])])
            if step > 0:
                end = durations[i] + step
                close_loop(tracks, end)
                durations[i] = end
        for track in tracks.values():
            smooth_track(track, smooth)

    targets = []
    for tracks in clips:
        for key in tracks:
            if key not in targets:
                targets.append(key)
    targets.sort(key=lambda k: (doc["nodes"][k[0]].get("name", ""), k[1]))

    # A target is cubic in the output if it is cubic anywhere, so the whole
    # merged track uses one layout.
    cubic = {
        key: any(c.get(key, {}).get("interp") == "CUBICSPLINE" for c in clips)
        for key in targets
    }

    # ---- build one merged track per target ---------------------------
    new_views = []
    new_accessors = []
    samplers = []
    channels = []
    ranges = []

    offsets = []
    running = 0.0
    for dur in durations:
        offsets.append(running)
        running += dur + gap
    total = running - gap if durations else 0.0

    for key in targets:
        node, path = key
        comps = COMPONENTS[path]
        is_cubic = cubic[key]
        keys = []   # [time, chunk, kind]

        def push(t, vals, kind):
            # Each clip's own keys keep their exact times, because a clip's
            # first and last key are the frames Luanti loops between: if a
            # fill key displaced them, every loop would start or end on the
            # rest pose for one frame. Fill keys give way instead.
            if keys:
                prev = keys[-1]
                if kind == FILL_START and prev[2] == FILL_END and prev[1] == vals:
                    return          # the previous hold simply continues
                if t <= prev[0]:
                    if prev[2] == CLIP:
                        t = prev[0] + EPSILON
                    else:
                        prev[0] = t - EPSILON
                        if len(keys) > 1 and prev[0] <= keys[-2][0]:
                            prev[0] = keys[-2][0] + EPSILON
                            t = prev[0] + EPSILON
            keys.append([t, vals, kind])

        for i, tracks in enumerate(clips):
            off = offsets[i]
            dur = durations[i]
            track = tracks.get(key)
            if track:
                per_key = track["per_key"]
                for k, t in enumerate(track["times"]):
                    chunk = track["values"][k * per_key:(k + 1) * per_key]
                    if is_cubic and per_key == 1:
                        # promote a linear key into a cubic one with flat
                        # tangents, so a mixed track keeps one layout
                        zero = [0.0] * comps
                        chunk = [zero, chunk[0], zero]
                    push(off + t, chunk, CLIP)
            else:
                # This clip leaves the bone alone, so hold its rest pose for
                # the whole segment. Without these keys the sampler clamps to
                # a neighbouring clip's pose and the bone is stuck in, say, a
                # walking stance while standing still.
                rest = rest_pose(doc, node, path)
                chunk = [[0.0] * comps, rest, [0.0] * comps] if is_cubic else [rest]
                push(off, chunk, FILL_START)
                push(off + dur, chunk, FILL_END)

        times = [[k[0]] for k in keys]
        values = []
        for k in keys:
            values.extend(k[1])

        input_index = append_accessor(doc, blob, new_views, new_accessors,
                                      times, 1)
        output_index = append_accessor(doc, blob, new_views, new_accessors,
                                       values, comps)
        samplers.append({
            "input": input_index,
            "interpolation": "CUBICSPLINE" if is_cubic else "LINEAR",
            "output": output_index,
        })
        channels.append({"sampler": len(samplers) - 1,
                         "target": {"node": node, "path": path}})

    for i, anim in enumerate(chosen):
        ranges.append((anim.get("name"), offsets[i], offsets[i] + durations[i]))

    merged = {
        "name": "animation.combined",
        "samplers": samplers,
        "channels": channels,
    }

    doc["bufferViews"].extend(new_views)
    doc["accessors"].extend(new_accessors)
    doc["animations"] = [merged]
    doc["buffers"][0]["byteLength"] = len(blob)
    doc["buffers"][0]["uri"] = "data:application/octet-stream;base64," + base64.b64encode(
        blob
    ).decode("ascii")

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))

    print("wrote %s" % out_path)
    for name, start, end in ranges:
        print("  clip %-32s %.3f .. %.3f" % (name, start, end))
    print("  total duration: %.3f (gap %.3f between clips)" % (total, gap))
    print("  loops closed: %s   smoothing: %s"
          % ("yes" if closing else "no",
             ("%dx resample" % smooth) if smooth >= 2 else "off"))
    print("  %d bones, one track each (was one channel per bone per clip)"
          % len(targets))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
