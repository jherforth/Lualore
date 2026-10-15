# ☁️ Sky Sites (floating buildings)

The buildings on the floating crystal islands are placed by
`valkyrie/floating_buildings.lua`. It follows the same design as the ground
villages (`villagers/VILLAGE_PLACEMENT.md`) and reuses their ground module.

## Why the old system was replaced

The sky buildings used to be four schematic **decorations** — `skycastle`
plus three `skyhouse` variants — sharing two noises:

1. **Density was enormous.** The engine places `sidelen² × noise_value`
   decorations per `sidelen` division at *random* positions. With
   `sidelen = 120` and a noise scale of `0.0018` that allows up to **~26 sky
   houses inside one 120×120 division**, and up to ~9 castles per 100×100
   division.
2. **No spacing rule, no footprint test.** Every building blits with
   `force_placement`, so as soon as a division rolled more than one they
   overwrote each other into a mound of walls — and nothing checked that the
   island underneath was big enough to hold them.
3. **The castle was not rare.** It rolled from its own noise at roughly the
   same density as the houses, so the building that holds the valkyrie
   chests turned up constantly.
4. **Chests landed in the wrong building, and there were four of them.**
   The generator looked for `everness:mineral_torch` within 40 nodes of any
   crystal-grass blob and converted the first four. The castle carries
   exactly four of those torches as anchors — but `skyhouse1` carries
   eight, so houses regularly swallowed the chests. Four chests also meant
   sixteen valkyries, since opening one releases four.

## How it works now

- The sky is divided into a grid of `spacing × spacing` cells. Each cell has
  **one** candidate position, jittered in the middle half of the cell, so two
  sky sites can never be closer than half the spacing.
- A cell builds when it passes the `chance` roll and its candidate stands on
  a **crystal island** — the surface node decides, so no biome-name matching
  is involved.
- The island is read **once** with a VoxelManip into a height grid. That grid
  answers every later question: is there enough island for a cluster, does
  this footprint sit on solid ground, and which columns get dressed.
- The layout is **planned completely before anything is placed**: the castle
  (when the site rolled one) in the middle, then houses on a ring whose
  radius follows an organic outline borrowed from
  `villagers/systems/village_ground.lua`. Footprints may never overlap and
  must stand on island, so nothing is ever built on top of anything else.
- Any footprint column still hanging over air gets a short plug of island
  stone. Nothing is ever carved away — only air is filled.
- The cluster is **fitted to the island**, not the other way round: the
  placer measures how far solid ground reaches around the candidate and
  shrinks the layout to match. Islands reaching less than 12 nodes get
  nothing at all; below 26 nodes a site stays a hamlet even if it rolled a
  castle. Measured on test islands: radius 11 and under build nothing,
  14–22 give hamlets of 2–3 houses, 30 and up give a castle with 4 houses
  around it. An island just over the castle threshold may hold the castle
  alone, which is a fine look for a fortress island.
- **The castle is rolled separately and rarely.** Most sites are plain
  hamlets of 2–6 houses.
- **One valkyrie chest, in the castle only.** Opening it releases four
  valkyries at once, so a single chest is the whole fight.
- **The chest is the one the schematic ships.** `skycastle.mts` carries a
  valkyrie chest at its own offset (11,19,10) — and it was saved *opened*,
  so every castle generated with its prize already looted. The placer shuts
  that one and leaves it where the designer put it, rather than putting a
  second chest somewhere else. If a schematic ever ships without a chest, it
  falls back to the mineral torches the castle carries as anchors. Either
  way the torches in `skyhouse1` stay lit torches.
- **Castles that generated before this fix repair themselves.** An LBM shuts
  any valkyrie chest that is open but has no `opened` flag in its metadata:
  opening one sets that flag, and a schematic-placed node has no metadata at
  all, so an opened chest that does not know it was opened was never opened
  by anybody. A chest a player actually looted is left alone.
- **The chest is always generated closed.** It is placed as
  `lualore:valkyrie_chest` (the closed node, never `..._opened`), `set_node`
  drops any metadata at that position, and the `opened` flag is then written
  as `0` explicitly. Right-clicking it is what starts the battle.
- Sites are recorded in mod storage, so a cell that has already built is
  never built again — important in the sky, where an island can straddle
  several vertical chunks that each trigger generation.
- Sky Folk are spawned once per built site (`sky_villages.spawn_sky_folk`),
  at the site centre rather than at a random patch of crystal grass.

## Villages founded by sky portals

Sky portals (`portal/SKY_PORTAL.md`) lead to a sky village, and found one
when none is in reach, through `lualore.floating_buildings.found_at(x, z,
opts)`. That runs the same `build_site` as the grid, with three options the
grid never passes:

- `houses`: how many houses to aim for (a portal asks for 18; the grid rolls
  2-6).
- `max_radius`: the cluster radius cap (the grid's is 46).
- `tries`: placement attempts per house (the grid uses 8).

A grid-built site comes out exactly as before: the house roll still runs,
and is only overridden when `houses` is passed.

A founded site is recorded like any other, with `big = 1`. It takes its grid
cell's key when the cell is free, so the grid never builds a hamlet beside
it; in a cell that already has a site it is recorded as `founded:x:z`. Sky
Folk arrive around its middle as usual, and a big village also gets a group
for every six houses out on its ring.

Portals only count `big` villages as destinations, so the grid's own
hamlets stay quiet places to find by flying.

A portal town always has a skycastle: the portal founds it with
`force_castle`, because the castle's valkyrie chest is the only way to
free the Sky Folk. For a town that was built without one,
`lualore.floating_buildings.add_castle(key, opts)` places a castle into the
standing town:
- It looks for open ground first: the middle, then rings outward.
- It checks the castle's whole volume is open air, not just its floor. The
  island height grid alone would take a house's own floor for island.
- With `opts.at = {x = , z = }` it tries one spot only. The portal uses
  that for a rock it raises beside a town with no room left.
- It closes the valkyrie chest and records `castle = 1`.

## Sky Folk

**Population.** A portal town is topped up to `lualore_portal_village_folk`
Sky Folk (default 40) a few seconds after a player steps out of a portal
there, once the town is active around them. The top-up runs at most once
every 30 seconds per town, so a return trip always finds the town full.
Each top-up also sets every Sky Folk in town to the state its castle's
valkyrie chest shows: free if the chest is open and its fight won,
captive while it is closed. Newcomers are placed (`valkyrie/sky_town_folk.lua`):
- on open island ground with two nodes of headroom,
- under open sky, so never inside a house or the castle,
- with ground two nodes out on every side, so never on the rim,
- between 6 and 44 nodes from the middle.

Sky Folk carry `lifetimer = 20000`. Unfreed Sky Folk are monsters, and
mobs_redo deletes any monster that isn't mid-attack when its area unloads,
so before this a hostile town emptied whenever its players left. Until its
valkyries are defeated, a town's Sky Folk are hostile, so a large population
makes an unfreed town dangerous.

**Edges** (`valkyrie/sky_folk_footing.lua`). Sky Folk used to walk off
islands because most of what moves them never looks at the ground:
- their own `do_custom` sets their velocity directly,
- they chase players,
- they get knocked back,
- they jump.

So the guard works on what is actually happening to the mob, whatever moved
it:
- One moving towards a drop deeper than 3 nodes is stopped and turned
  round, and mobs_redo's own movement is skipped for that step.
- One that goes over anyway is caught once it is falling with no ground
  within 4 nodes, and is put back on the last ground it stood on well
  inside the island.

**Freedom is per town.** Luanti only keeps entities active about 64 nodes
around a player, and a town is wider than that, so a radius check alone
never reaches the far side. When a town's valkyries are defeated, the town
record is marked `liberated = 1`. Any Sky Folk of that town that wakes up
later, or arrives through a top-up, is free too: it checks every five
seconds.

## The valkyrie chest fight

`valkyrie/valkyrie_fight.lua`. Opening a chest starts a tracked fight with
its four valkyries.

| What happens | Result |
|---|---|
| All four are defeated | The chest stays open for good (`won = 1`) and the town is freed. |
| No player within 64 nodes for 20 seconds (died and respawned elsewhere, or left) | The fight is called off. |
| A valkyrie still to be defeated goes unseen for 12 seconds while players are there (mobs_redo deleted it, or it is lost) | The fight is called off. |

**Called off** means the valkyries still loaded are drawn back into the
chest and the chest closes. The player who opened it is told. Opening it
again is a fresh fight against all four.

**Stragglers.** Every valkyrie carries its chest and fight id, and reports
in from its `do_custom`. One that wakes up after its fight is over removes
itself, so a reopened chest never meets stragglers.

**Spawning.** A chest in a cramped room used to leave a valkyrie unspawned
when its spot was blocked, and that fight could never be won. Each valkyrie
now searches nearby for room. One with no room at all is dropped from the
fight rather than left as one the player can't defeat.

**Chests left open.** An open chest with no fight going and no victory
behind it closes when it next loads; a load-time check also clears chests
opened before this was tracked, whose valkyries are long gone. A chest whose
town is already free stays open and is marked won. That includes towns
freed under the old rules, recognised by freed Sky Folk standing nearby.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `lualore_sky_buildings` | `true` | Enable automatic placement. |
| `lualore_sky_spacing` | `360` | Nodes between grid cells. Lower = more sites. |
| `lualore_sky_chance` | `0.8` | Fraction of cells that attempt a site. |
| `lualore_sky_castle_chance` | `0.15` | Chance a site is built around a skycastle. |
| `lualore_sky_houses_min` | `2` | Minimum houses per site. |
| `lualore_sky_houses_max` | `6` | Maximum houses per site. |
| `lualore_sky_radius` | `30` | Base cluster radius; grows with the house count and again for castle sites. |
| `lualore_sky_dressing` | `true` | Crystal grass and paths between the buildings. |
| `lualore_sky_y_min` | `500` | Bottom of the sky search band. |
| `lualore_sky_y_max` | `31000` | Top of the sky search band. |

Tuning recipes:

- **Rarer castles (rarer chests):** lower `lualore_sky_castle_chance` to
  `0.08`. At the defaults a castle turns up roughly once per 1250×1250
  nodes of sky *that actually has islands*.
- **More sky hamlets:** lower `lualore_sky_spacing` (280, 240). Remember
  that cells whose candidate finds no island build nothing, so the real
  density is set as much by how common the islands are as by this number.
- **Bigger hamlets:** raise `lualore_sky_houses_max`; the cluster radius
  widens automatically.
- Settings apply to **newly generated chunks** only. Use `/spawn_skysite`
  to preview changes immediately.

## Commands

| Command | Privs | What it does |
| --- | --- | --- |
| `/spawn_skysite [castle\|hamlet]` | server | Builds a sky site on the island you are standing on. `castle` forces the skycastle, `hamlet` forbids it. |
| `/find_skysite [radius]` | — | Nearest recorded sky site (default radius 2000), and whether it has a castle. |
| `/place_fortress_chests` | give | Repair tool for older worlds: places **one** closed valkyrie chest on the mineral torch nearest you, so you choose the room. |
| `/spawn_skyvillage` | give | Unchanged: spawns Sky Folk and a valkyrie as *entities*, builds nothing. |

## The palette

`SKY_PALETTE` at the top of `floating_buildings.lua` has the same shape as a
village palette (`villagers/buildings/*.lua`): which nodes count as island
`surface`, the schematic `offset`, the `fill` used for foundations, the
`castle` and `houses` schematics, and the `ground`/`plants` tables the
dressing pass reads. Adding a second sky biome means adding another table
like it. Unknown node names are dropped at first use, so the palette may
name blocks a given world does not have.

## Notes

- Already-generated sky chunks keep whatever they had before this system;
  the new placer only affects newly generated chunks. Old overlapping
  clusters stay where they are.
- `house_spawning.lua` clamps its bed scan to `y ≤ 80`, so its crystal-forest
  branch never fires on real sky islands. Sky Folk up there come from the
  per-site spawn described above, not from beds.
- The old generator scanned a 51×21×51 box of `get_node` calls (≈54,000 per
  triggered chunk, on 15% of all sky chunks) just to find a crystal-grass
  blob. That scan is gone.
