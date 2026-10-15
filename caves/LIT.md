# 🕯️ The Lit — Cave Wanderer

A lone flame creature that haunts caves at almost any depth. It carries its own
illumination, is completely passive until attacked, and reacts to danger with
one of two personalities: **fight** or **flight**.

## Behavior

| Situation | Reaction |
| --- | --- |
| Idle | Wanders slowly through the caves, resting now and then, leaving a trail of drifting embers. |
| Player nearby (not attacked) | Ignored completely — it is a passive creature. |
| Attacked (first time) | Rolls a 50/50 personality: **fight** or **flee** (decided once per creature and remembered). |
| **Fight** mode | Chases the player, keeps a casting distance and hurls fire bolts every ~2 seconds. A bolt deals 6 damage and sets the player burning for 4 seconds (1 damage/second; jumping into water douses it). Below 30% health it panics and switches to flight. |
| **Flee** mode | Runs away at high speed, hopping obstacles. If cornered (stuck) or chased closely for a couple of seconds, it **drills straight down through the floor**, removing diggable nodes for up to 24 blocks until it breaks into open space below. It will not drill into liquids, bedrock-like or protected nodes — then it just keeps running/jumping. Being hit again re-arms its drilling. |
| Calming down | When the attacker is gone (out of range for a few seconds, dead or logged out), it returns to wandering. |
| Defeated | Drops a **torch**, **coal** and **flint** (always all three). |

The Lit is fire-born: it takes no lava, fire, water or light damage, floats in
liquids, and emits a strong glow (a `lualore:lit_light` node follows above its
flame) so you will see its light before you see its face.

## Spawning

- Fairly common in **just about any cave**: any depth (height band
  `-31000 .. -8`, so shallow tunnels count too), light ≤ 12 (any dim or
  torch-lit cave), up to 3 per area, checked roughly every 15 seconds per
  player (`mobs:spawn` chance 500).
- Spawns on almost any natural underground surface via node groups —
  `group:stone`, `group:cobble`, `group:cracky`, `group:crumbly`,
  `group:sandstone` — plus explicit caverealms moss/lichen/algae stone and
  everness mineral cave stone entries for games where those use custom
  groups.
- If a `spawn.lua` file exists at the mod root, automatic spawning is skipped
  (same convention as all other mobs in this mod).
- Spawn egg: **"Lit"** (uses `alit.png`).

## Files

| File | Purpose |
| --- | --- |
| `caves/lit.lua` | The mob, fire bolt projectile, burn system, glow node and light sweeper. |
| `models/lit.gltf` | Original Blockbench model (3 animations: standing / walking / mining). |
| `models/lit_combined.gltf` | **Generated** — all three clips merged into one Luanti-compatible animation timeline. Used by the mob. |
| `textures/lit.png` | Skin, extracted from the embedded image in `lit.gltf`. |
| `textures/alit.png` | Spawn egg icon (top-left 64×64 band of the skin). |
| `textures/lualore_firebolt.png` | Fire bolt sprite + particle. |
| `tools/combine_gltf_animations.py` | Generates the combined model (see below). |

## Model / animation pipeline (important!)

Luanti (≤ 5.14) supports only **one animation per glTF file** and uses glTF
timestamps (seconds) as animation frame numbers. Blockbench exports one
animation per clip, so the three clips are concatenated into a single
timeline by `tools/combine_gltf_animations.py`:

```
 0.00 -  5.92  idle   (original "animation.standing.golbo")
 6.17 - 12.17  walk   (original "animation.walking.golbo")
12.42 - 18.92  drill  (original "animation.mining.golbo")
```

Take these numbers from what the tool prints. It does not simply append the
clips, because doing that produced three faults that together were most of
why the Lit looked mechanical:

1. **One channel per bone.** glTF lets a bone be driven by at most one
   channel per animation. Appending the clips gave `chest`, `torso` and
   `leftUpperArm` three channels each and two more bones two, which is
   invalid — the renderer picked a winner. Worse, a glTF sampler *clamps*
   outside its own key range, so the legs (keyed only in the walk) held a
   mid-stride pose through the whole idle and drill. Bones a clip does not
   animate now hold their **rest** pose for that clip, which is what the clip
   looks like in Blockbench.
2. **A guard gap between clips** (`--gap`, default 0.25). Without it the
   last frame of one clip is the first frame of the next, and whichever pose
   lost showed for a frame every time its clip looped.
3. **Closed loops and baked easing** (`--no-close-loops`, `--smooth N`). The
   walk was six one-second strides cut off three-quarters of the way through
   the sixth, so looping it jumped a quarter-stride — a lurch once per
   cycle. Each clip now ends on the pose it began with. Easing is resampled
   into denser `LINEAR` keys rather than written as `CUBICSPLINE`, because
   Luanti reads `LINEAR` samplers.

Verified after regenerating: 12 channels for 12 bones, no duplicate targets,
every clip's loop seam under 0.1°, and leg travel through the idle exactly 0°.

The mob plays these ranges with speed 1.0:

- idle / walk via the standard `animation` table (`stand_*`, `walk_*`, with
  `speed_normal = 1` — correct for glTF),
- the drill clip directly during burrowing.

**If you re-export `lit.gltf`, regenerate the combined model:**

```
python tools/combine_gltf_animations.py models/lit.gltf \
    models/lit_combined.gltf animation.standing.golbo \
    animation.walking.golbo animation.mining.golbo
```

Sizes / orientation:

- Entity meshes render at 10 units = 1 node, so the 20-unit model is 2.0
  nodes tall at scale 1. `VISUAL_SIZE = 1.25` renders it at ~2.5 nodes tall
  (twice its original size). Change `VISUAL_SIZE` in `caves/lit.lua` to taste.
- If the creature faces the wrong way in game, add `rotate = 180` (or 90/270)
  to the mob definition.
- The embedded base64 image in the glTF is ignored by Luanti — the texture is
  supplied through `textures = {"lit.png"}`.

## Tuning

All gameplay knobs are constants at the top of `caves/lit.lua`:

| Constant | Default | Meaning |
| --- | --- | --- |
| `VISUAL_SIZE` | `1.25` | Rendered size multiplier (~2.5 nodes tall). |
| `BURN_TIME` | `4` | Seconds the player burns after a bolt hit. |
| `BURN_DAMAGE` | `1` | Burn damage per second. |
| `BOLT_DAMAGE` | `6` | Direct bolt hit damage (fleshy group). |
| `BOLT_SPEED` | `14` | Projectile speed. |
| `CHASE_SPEED` | `1.9` | Fight-mode movement speed. |
| `RUN_SPEED` | `3.2` | Flee-mode movement speed. |
| `DRILL_STEP_TIME` | `0.28` | Seconds per floor block removed while burrowing. |
| `DRILL_SINK_SPEED` | `3.0` | Downward speed while burrowing. |
| `DRILL_MAX_DEPTH` | `24` | Give up if no open space found within this many blocks. |
| `WANDER_SPEED` | `1.0` | Idle wandering speed. |

Stats: 16–24 HP, armor 50, collisionbox 0.6×1.0.

## Implementation notes

- **Aggression hook:** the mob reacts to damage through mobs_redo's `do_punch`
  callback plus a health-drop safety net in `do_custom` (covers arrows and
  other damage sources), so "passive until attacked" is robust across
  mobs_redo versions.
- **Movement control:** mobs_redo's own wandering is disabled
  (`walk_chance = 0`, `stand_chance = 0`, `randomly_turn = false`,
  `jump_height = 0`) — movement, turning and animations are driven by the
  custom AI. The mob's `state` is kept in sync (`"walk"` / `"stand"`) so
  mobs_redo never fights the current animation; while drilling the state is
  set to `"drill"` (an unknown state silences the engine's state machine
  entirely).
- **Glow:** a `lualore:lit_light` node (light level 14, invisible, not
  pointable, no drops) follows above the flame. Every placed light is tracked
  and a background sweeper removes stray lights (after despawns, unloads,
  `/clear_mobs`, etc.) once no Lit is nearby.
- **Drilling respects protection:** it never removes nodes in protected areas
  and aborts cleanly if it hits undiggable ground.

## Testing

1. Place a Lit via the spawn egg in a dark cave: it should wander, glow, and
   ignore you.
2. Punch it: it either attacks with fire bolts (watch the burn damage) or
   runs; chase it against a wall to watch it burrow down.
3. Kill it: expect a torch, coal and flint.

## Texture maintenance (important when editing the skin)

The model's uv rectangles overlap 1-pixel transparent seams in the atlas;
faces that sample those texels render with *invisible* pixels (gaps),
regardless of the RGB colour behind them, because alpha = 0 skips the pixel
entirely. After editing `textures/lit.png` in any image editor, re-heal the
seams:

```
python tools/dilate_texture.py textures/lit.png textures/lit.png 3
```

The tool only writes into fully transparent texels (using the neighbouring
skin colours), so painted pixels are never modified. When drawing new skin
by hand, leave a 1-pixel padding around every patch instead.

Helper tools (run from the mod root, Pillow required):

```
python tools/preview_gltf.py models/lit_combined.gltf textures/lit.png tools/lit_preview.png
python tools/lit_skin_audit.py models/lit_combined.gltf
python tools/atlas_peek.py textures/lit.png
```

`preview_gltf.py` renders front/side/back views and paints any pixel that
samples a transparent texel in magenta; `lit_skin_audit.py` welds the mesh
and checks for holes, bad UVs and transparent sampling; `atlas_peek.py`
prints an ASCII alpha map of a texture.
