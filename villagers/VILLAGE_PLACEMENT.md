# 🏘️ Village Placement & Density

Villages are placed by `villagers/systems/village_placement.lua`. The six
`villagers/buildings/*.lua` files only define **palettes** (which biomes,
which surface nodes, which schematics per biome).

## Why the old system was replaced

Villages used to be schematic **decorations**: 4 houses + church + market +
stable registered separately for 6 biomes, all sharing one global noise. That
made building density nearly impossible to tune:

1. **Density was multiplied.** The engine places `sidelen² × noise_value`
   decorations per `sidelen` division, at *random* positions — and the noise
   is sampled only once per division (at its centre). Each of the 42
   decorations rolled this independently, so a single `scale` tweak moved
   seven stacked scatter systems at once, in coarse integer steps.
2. **No spacing rule.** As soon as a division rolled 2+ buildings they
   overlapped and overwrote each other (all blits use `force_placement`).
   More density produced mush; less produced lone houses, not villages.
3. **`all_floors`** made every matching floor of the chosen column a
   candidate — houses could land in caves or on ledges.

## How it works now

- The world is divided into a grid of `spacing × spacing` cells. Each cell has
  **one** candidate position, jittered in the middle half of the cell — two
  villages can never be closer than half the spacing.
- A cell spawns a village when it passes the `chance` roll and its
  **footprint agrees on a palette**. Seventeen columns vote: the centre, six
  at 12 nodes out and ten at 24. Each column votes by its biome, or by its
  ground block if the biome is unknown. Open water and neutral ground
  (sand, bare dirt, clay, gravel) abstain. One palette needs 70% of the
  votes cast, from at least six columns. A site on a biome border gets no
  village, so a desert village can't land in a meadow because its centre
  hit a sandy patch. A palette can ask for less with `vote_share`, which
  counts only when the centre votes for it. Lake villages use 0.25, since a
  shore is half water and half the forest behind it. `/village_probe`
  prints the vote for the column you're standing on.
- The site is **terraformed** before anything is built
  (`lualore_village_terraform`): the village floor is levelled to the
  palette's ground block (dips filled, hills cut, up to
  `lualore_village_terraform_max` nodes of relief; plants and trees are
  cleared and lighting is refreshed). Around the flat core a ramp band lets
  the terrain step one node per block back up or down - a bowl rising into
  a hillside, or a lens falling away over a dip - so the village blends
  into the landscape. Water is left alone, cliffs beyond the band stay
  cliffs, and nothing is ever half-terraformed (unreadable surroundings
  retry without writing).
- The levelled area is **not a circle**: its outline is built from a few
  angular harmonics rolled per village, so every site is a different lobed
  blob and the ramp band breathes in and out around it. The outline is
  radial, so it is always one closed area and never dips inside the house
  ring. See `villagers/systems/village_ground.lua`.
- Once the buildings stand, the bare floor is **dressed**: coherent noise
  patches of accent ground blocks, trodden earth against the walls, faint
  paths from each building to the centre, then grass, flowers and shrubs
  thickening away from the doorsteps. Only columns the terraformer actually
  re-laid are dressed, so natural ground keeps whatever the mapgen grew
  there.
- The layout is **planned completely before anything is placed**: church,
  market and stable first (rolled separately), then houses evenly spread on a
  ring around the centre, each nudged until it fits without overlapping any
  other footprint. Unreadable (not yet generated) nodes abort with a retry —
  a failed attempt can never leave a half-built village.
- Once the ground is dressed the village is **furnished** with the
  workstations no schematic contains - an anvil and forge, the cleric's
  altar, and one or two tilled fields with water at their centre. Nothing
  is placed unless the ground is level, open and clear of every building.
  See `villagers/VILLAGER_JOBS.md`; `/furnish_village` retrofits a village
  that already exists.
- Villagers still spawn from the beds inside the placed schematics
  (`house_spawning.lua`), unchanged except for a slightly longer delay so it
  always runs after placement. Which trade each bed gets is now dealt from
  a tiered deck per village, so every village has a farmer, a smith and a
  cleric rather than whatever six uniform rolls happened to produce.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `lualore_villages` | `true` | Enable automatic placement. |
| `lualore_village_spacing` | `320` | Nodes between grid cells. Lower = more villages. |
| `lualore_village_chance` | `0.9` | Fraction of cells that attempt a village. |
| `lualore_village_terraform` | `true` | Level the ground around each village site. |
| `lualore_village_terraform_max` | `8` | Nodes of slope that may be cut/filled. |
| `lualore_village_organic` | `true` | Lobed, irregular site outline instead of a circle. |
| `lualore_village_ground_noise` | `true` | Accent-block patches over the levelled floor. |
| `lualore_village_vegetation` | `true` | Grass, flowers and shrubs around the buildings. |
| `lualore_village_plant_density` | `0.22` | How thickly they grow (each palette scales this). |
| `lualore_village_paths` | `true` | Trodden paths from each building to the centre. |
| `lualore_village_houses_min` | `5` | Minimum houses per village. |
| `lualore_village_houses_max` | `20` | Maximum houses per village (bigger targets widen the layout and terraced area automatically). |
| `lualore_village_radius` | `22` | Base scattering radius; grows with the rolled village size. |
| `lualore_village_central_chance` | `0.45` | Chance per central building (church/market/stable). |
| `lualore_village_y_max` | `200` | Top of the surface search band. |
| `lualore_village_y_min` | `-2` | Bottom of the surface search band. |

Tuning recipes:

- **More villages:** lower `lualore_village_spacing` (280, 220) and/or raise
  `lualore_village_chance` to `1.0`. The defaults (320 / 0.9) already favour
  density over sparseness.
- **Smaller compact villages:** lower `lualore_village_houses_max` (6-8).
- **Bigger villages:** the default range is 5-20 houses and the layout
  widens automatically with the target; raise `lualore_village_radius`
  for even more spread at the top end.
- **Fewer fancy buildings:** lower `lualore_village_central_chance`.
- **Wilder / tidier villages:** raise `lualore_village_plant_density` (0.35+)
  for overgrown hamlets, lower it (0.08) for swept ones. Set
  `lualore_village_ground_noise` to `false` for the old uniform floor, or
  `lualore_village_organic` to `false` to go back to circular sites.
- **Bigger terraces / more hilly sites:** raise
  `lualore_village_terraform_max` (10–12) - more hills become village sites
  at the cost of bigger earthworks. Set `lualore_village_terraform` to
  `false` for strict "flat spots only" placement.
- Settings apply to **newly generated chunks** only. Use `/spawn_village`
  to preview changes immediately.
- If you see no villages at all, run `/village_probe` and check the startup
  log line `[lualore] Villages enabled: ... palettes: ...`. Both tell you
  whether the driver is live, what biome you are in, and where placement
  stops. Already-generated terrain never gets retroactive villages.

## Commands

| Command | Privs | What it does |
| --- | --- | --- |
| `/spawn_village [palette]` | server | Builds a village at your position right now (palette = grassland, desert, ice, jungle, lake, savanna; guessed from the biome if omitted). |
| `/find_village [radius]` | — | Nearest recorded village (default radius 512). |
| `/village_probe [radius]` | server | Diagnoses placement around you (default radius 1000): shows your biome vs palette, and counts candidates that fail at each stage (no palette / no floor / unloaded / not flat) vs how many would build. |
| `/clear_village_records` | server | Forgets placement records (does not remove built villages). |
| `/populate_village [radius]` | server | Existing bed-based villager repopulation (unchanged). |

## Palettes

Each palette in `villagers/buildings/*.lua` has:

```lua
lualore.village_palettes.grassland = {
    name = "grassland",
    biomes = {"grassland"},                      -- biome names that select it
    surface = {"default:dirt_with_grass", ...},  -- natural ground nodes
    offset = -6,          -- schematic base sunk into the ground (foundation)
    y_min = ..., y_max = ...,                    -- optional search band override
    water_ok = false,     -- lake shores allow water around them
    vote_share = nil,     -- optional: share of the site vote it needs when
                          -- the centre votes for it (lake: 0.25)
    ground = {            -- optional: how the levelled floor is textured
        accents = {                              -- {node, percent of the site}
            {"default:dirt", 7},
            {"default:gravel", 2, bare = true},  -- `bare` = nothing grows here
        },
        worn = "default:dirt",                   -- trodden strip along the walls
        path = "default:dirt",                   -- the paths to the centre
    },
    plants = {            -- optional: what grows between the houses
        density = 1.0,                           -- scales lualore_village_plant_density
        list = {{"default:grass_3", 7}, {"flowers:rose", 1}},   -- {node, weight}
        bush = {stem = "default:bush_stem", leaves = "default:bush_leaves",
                chance = 0.014},
    },
    houses = {"grasslandhouse1.mts", ...},
    church = "grasslandchurch.mts",
    market = "grasslandmarket.mts",
    stable = "grasslandstable.mts",
}
```

Adding a biome is just adding a table like this (or extra entries to an
existing `houses` list). Every node named in `ground`/`plants` is checked
against the node registry the first time the palette is used, so a palette
may freely name blocks from mods a given world might not have - unknown
ones are simply dropped. Leave both tables out and the site gets a generic
dirt/gravel-and-grass dressing.

One trap when picking ground nodes: minetest_game's "Grass spread" ABM turns
any lit, uncovered `default:dirt` into whichever spreading dirt type sits
next to it, so a path or a worn yard paved with plain dirt looks right for a
few minutes and is then grassed back over. The palettes here use nodes the
ABM leaves alone — gravel, sand, permafrost and the `_with_` surface
variants (those are spreading types themselves, so they stay put).

## Notes

- A palette can list several biome names, and namespaced names match their
  last segment (`"grassland"` also matches `everness:grassland`). If your
  game renames a biome (for example `grassland` -> `grassytwo`), add the new
  name to the relevant `biomes` list. The server log prints
  `[lualore] Villages: no palette for biome 'X'` the first time an
  unrecognized biome gets a candidate, so renames never fail silently.
- When a biome has no palette at all, the column falls back to its ground
  block (the same "spawn on these nodes" idea the old decoration system
  used): the first palette whose `surface` list contains that block gets
  the vote, logged once per biome. Neutral ground (`default:sand`, `dirt`,
  `clay`, `gravel`) never votes this way, and neither does the bed of a lake
  or river. Tree parts (trunks, leaves,
  wood) are never treated as ground - villages base on the soil beneath
  trees, and houses replace whatever stands inside their footprint.
- Already-generated terrain keeps whatever it had before this system (old
  decoration buildings stay where they are); the new placer only affects
  newly generated chunks.
- Lake palettes use a narrow search band (`-2..4`) and allow water around the
  village, so the stilt houses stay near the waterline as before.
- The legacy noise definitions in `villagers/systems/village_noise.lua` are
  no longer used by village placement (kept only so nothing that references
  `lualore.global_village_noise` breaks).
