# 🏚️ Procedural Ruins

`ruins/ruins.lua` scatters **broken castles, ruined towers, collapsed wall
fragments and ancient stone circles** across the six village biome families.
Unlike village buildings (fixed schematics), ruins are generated node by node
with a deterministic random generator — every ruin is unique, walls crumble
naturally, sections have collapsed, and the structures follow the terrain.

## Ruin types

| Type | Weight | Description |
| --- | --- | --- |
| `castle` | 40% | 19–27 node square: outer walls with a 2-cell gate (flanked by taller pillars), 3×3 corner tower ruins, a 5×5 inner keep (larger castles), courtyard flagstones, interior rubble and thinning rubble fields outside the walls. Always contains a chest when chests are enabled. |
| `tower` | 30% | 7×7/9×9 hollow tower ruin, 4–9 nodes tall with a heavily crumbled crown, rubble at the base. 35% chest chance. |
| `walls` | 18% | A 12–20 node wall fragment with taller broken ends, following the terrain. 10% chest chance. |
| `stones` | 12% | A ring of 8–14 standing stones (some fallen) around an altar stone that is sometimes a glowing lamp. 25% chest chance, placed beside the altar. |

If the chosen type does not fit the local terrain, the placer automatically
tries the next type down the table before giving up on the spot.

### Ruined portals beside the ruins

**Three ruins in four** of every kind have a **ruined sky or dark portal**
standing beside them. It's a frame of mostly Cracked Mese with gaps, plain
or on a grand broken platform, sometimes with a chest of iron ingots. It's
built by `portal/portal_ruins.lua`; see `portal/SKY_PORTAL.md`, section 5b.

- **Where it stands:** on a ring round the ruin, clear of everything the ruin
  placed, at the first of 8 spots where the ground takes it. It looks well
  below the ruin's base, which can be a tree canopy.
- **Unloaded land:** if the land round the ruin isn't generated yet, it tries
  again a few seconds later.
- **When it can't:** a ruin that can't fit one logs
  `No room for a ruined portal beside the ...` with the reasons.
- **Building one alone:** `/spawn_ruin portal`.
- **Turning it off:** `lualore_portal_ruins = false`.

## How placement works

Same proven architecture as `villagers/systems/village_placement.lua`:

- The world is divided into a grid of `spacing × spacing` cells (default
  450). Each cell has **one** jittered candidate position (middle half of the
  cell), so ruins can never be closer than half the spacing.
- A cell spawns a ruin when it passes the `chance` roll, the biome maps to a
  theme, and enough of the required columns have ground within ±5 nodes of the
  base level (max spread 6, max 25% missing). Wall columns each follow their
  own local floor height, so ruins drape over gentle slopes.
- The whole ruin is **planned before a single block is written** and placed
  with one VoxelManip write. Unreadable (not yet generated) columns abort the
  attempt with a retry — failed attempts leave nothing behind.
- Ruins keep a 48-node distance from recorded villages. Water/lava columns are
  rejected (lake-shore ruins allow water around and under them — sunken ruins).
- Deterministic per cell from the world seed: the same spot always generates
  the same ruin.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `lualore_ruins` | `true` | Enable automatic placement. |
| `lualore_ruin_spacing` | `450` | Nodes between grid cells. Lower = more ruins. |
| `lualore_ruin_chance` | `0.75` | Fraction of cells that attempt a ruin. |
| `lualore_ruin_chests` | `true` | Allow treasure chests in ruins. |
| `lualore_ruin_y_max` | `200` | Top of the surface search band. |
| `lualore_ruin_y_min` | `-2` | Bottom of the surface search band. |

Settings apply to newly generated chunks; use `/spawn_ruin` for instant
previews.

## Commands

| Command | Privs | What it does |
| --- | --- | --- |
| `/spawn_ruin [portal\|castle\|tower\|walls\|stones]` | server | Builds a ruin at your feet (random type if omitted). |
| `/find_ruin [radius]` | — | Nearest recorded ruin (default radius 512). |
| `/clear_ruin_records` | server | Forgets placement records only. |

## Chests & loot

Ruins place a `default:chest` (or `default:chest_locked` if that is all the
game has). The existing loot system (`villagers/extras/loot.lua`) already
fills any chest by biome — via the LBM when the area loads and as a fallback
on first interaction — so ruin treasure needs no extra code. Disable with
`lualore_ruin_chests = false`.

## Themes (materials per biome)

| Theme | Biomes | Materials |
| --- | --- | --- |
| `grassland` | grassland | stonebrick / mossycobble / cobble / gravel, rare meselamp accents |
| `desert` | desert, mesa, everness:forsaken_desert | desert sandstone brick / block, sandstone, desert cobble, sand |
| `savanna` | savanna, prarie, naturalbiomes:outback | sandstone brick / sandstone, desert cobble, dry dirt |
| `ice` | icesheet, icesheet_ocean | stonebrick / ice / snowblock, gravel |
| `jungle` | rainforest, rainforest_swamp | mossycobble / stonebrick / junglewood, cobble |
| `lake` | *(forest shores & oceans, swamp_shore)* — allows water | mossycobble / cobble, clay, gravel |

Materials are validated at load: missing nodes are skipped and, if a whole
list is unavailable, the theme falls back to `default:stone` / `default:cobble`.

### Adding your own theme

```lua
lualore.register_ruin_theme("mymod:mushroom", {
    biomes = {"mymod:fungal_forest"},
    wall   = {"mymod:mushroom_brick"},
    floor  = {"mymod:mushroom_wood"},      -- optional, defaults to wall
    rubble = {"mymod:mushroom_stem"},      -- optional, defaults to wall
    glow   = {"mymod:glow_shroom"},        -- optional rare accents
    water_ok = false,                      -- allow water columns (sunken ruins)
})
```

Call it after this mod loads (e.g. in your mod's `init.lua` with
`lualore` in `depends.txt`); new chunks immediately use the theme.

## Public API

```lua
-- Build a ruin right now (for commands / other mods):
-- returns true/false/"retry"[, kind[, built[, base_y]]]
lualore.ruins.build_at(x, z, kind_or_nil, seed_or_nil)

-- All registered themes (sorted):
lualore.ruins.get_themes()
```

## Notes

- Configurable density and biome lists; ruins never touch villages.
- Everything is deterministic per world seed and cell, so multiplayer
  servers and singleplayer generate identical ruins.
- A ruin is written in one VoxelManip pass (typically a few hundred to ~1500
  nodes), only for cells the planner already validated — cheap enough for
  mapgen time.
