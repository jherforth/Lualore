# 🌀 Sky Portals

*Mese-framed portals, lit with an iron ingot, that carry you up to a sky
village and back.* `portal/sky_portal.lua`

They replace the obsidian door trials, which asked players to restore a
ruined shrine block-for-block before a boss arena opened. That was a lot of
machinery for one trip; a portal you build yourself is the familiar idea and
lets players choose where their way up starts.

---

## 1. Building one

- An **upright rectangle of `default:mese` blocks**, running along either the
  x or the z axis.
- The **interior must be at least 2 wide and 3 tall** — the classic nether
  portal shape, 4×5 from the outside.
- **There is no upper size limit.** The scan that recognises a frame walks
  the frame's own blocks, so it is bounded by them and stops the moment one
  is missing. `lualore_portal_max_size` (default 256) only stops it following
  an endless wall of mese; raise it if you ever build bigger.
- **Corners are optional**, as in Minecraft.
- The interior must be empty air. A frame of anything other than mese
  blocks is not a portal.

## 2. Lighting it

**Drop an iron ingot (`default:steel_ingot`) into the frame.** The moment the
ingot is inside, the frame takes it and the interior fills with a swirling,
see-through blue sheet. Drop a stack and only one ingot is used; the rest
fall back out.

The ingot is noticed by polling item entities within 12 nodes of each player
four times a second, not by hooking the item entity itself: three Asuna mods
re-register `__builtin:item` (`builtin_item` replaces it outright), so
anything wrapped onto it from this mod would vanish or survive depending on
load order. Polling is unaffected and ignites well inside `item_drop`'s
1-second pickup delay, so the ingot is not snatched back first.

Lighting respects protection: the frame must not be protected against the
player the ingot was noticed near (whoever is within 12 nodes of it).

## 3. Travelling

Stand in the sheet for **2 seconds** (`lualore_portal_delay`) and you are
carried through. You arrive standing in the far portal and must step out of
it before it will take you anywhere again, so nobody bounces back and forth.
Logging in inside a sheet counts as arriving.

The first trip through a portal may take a few seconds while the far end is
generated; the player gets a message saying the portal is reaching up (or
down). Anyone who walks off before it is ready stays where they are — the far
portal is still built and linked, so their next trip is instant.

### Mobs travel too

Any mob that stands in a sheet for **2 seconds longer than a player would**
(4 seconds by default) goes through: Wooden Guardians, villagers, Sky Folk,
valkyries, and other mods' mobs alike. A mob that just brushes past a sheet
isn't taken. Lead a guardian into a portal and it comes out on the far side.

- **Only through a portal a player has already opened.** A mob in a portal
  nobody has travelled through stays put, so a wandering villager can never
  raise a sky town or a castle.
- Like a player, a mob comes out in the far portal (anywhere along its
  floor, so a crowd doesn't stack up) and has to step out before it can
  travel again.
- Mobs are only watched within 32 nodes of a player, which is about as far
  as the server keeps them active anyway. Mobs being ridden or carried
  don't travel on their own.
- **A Wooden Guardian** keeps watch where it comes out: it patrols the
  nearest village there, or round the portal it came out of.
- **Sky Folk** brought down to the ground forget the island footing they
  were kept on.
- **A valkyrie from a chest fight** can be led through, and the fight
  carries on: it still counts when it is defeated on the other side.
- Turn it all off with `lualore_portal_mobs`.

## 4. Where it goes: a sky village

Luanti has no separate dimensions. The sky islands are Asuna's floatlands,
part of the same world and scattered through **y = 287 to 28,000**. A
portal's direction is set by its height:

| Portal is... | It leads... |
|---|---|
| below `lualore_portal_sky_y` (290) | up, to a **sky village** |
| at or above it | down, to the ground below |

### Going up

A ground portal leads to a **portal village**: a town of 18 sky houses by
default, against the 2–6 of a hamlet the sky-site grid builds on its own.

1. **A portal village within reach.** If a portal-founded village lies
   within 800 nodes (`lualore_portal_village_reach`), the portal goes there.
   The grid's own small hamlets don't count, because a portal should lead
   to a town.
2. **Otherwise it founds one** directly overhead. The player is told *"Far
   above, an island gathers itself out of the clouds..."* while it happens:
   - It picks a height in the sky-site band, trying 560, 640, 720, 800 and
     880 in turn until it finds open sky. The floatlands are scattered
     through every height, so one may already fill the first choice.
   - It raises a **crystal island** there the way Everness builds its
     crystal forest: crystal grass over crystal dirt over crystal stone.
     The outline is lobed (from the village ground module), and the
     underside tapers from up to 28 nodes deep in the middle to a thin rim. The island
     is sized to the town: a mean radius of 66 nodes for 18 houses.
     Only air is filled; nothing already there is carved away.
   - It has the sky-site builder (`valkyrie/floating_buildings.lua`) put the
     town on it: **one skycastle in the middle**, always, with the houses on
     a lobed ring around it and paths and planting between them.
   - The village is recorded like any grid-built site, flagged `big`. If its
     grid cell is still free it takes that cell, so the grid never builds a
     hamlet beside it.
   - **Sky Folk** arrive around the middle as usual, plus a group for every
     six houses out on the ring (three more groups for 18 houses), so the
     edges aren't empty.
3. **Every town has its castle.** The castle's valkyrie chest is the only
   way to free the Sky Folk — opening it starts the valkyrie fight — so a
   town without one could never be freed. Towns founded by this version
   always get one. A town built before this rule gets its castle the next
   time a portal leads there, including a portal already linked to it:
   - The castle goes on the town's own island if any open ground fits its
     whole 22×22 footprint and height. The middle is tried first, then rings
     outward.
   - If the houses fill the island, the castle is put on a rock raised
     beside the town. The rock overlaps the rim by a third of its width, so
     you can walk across with no gap to jump.
   - The castle ships with its chest saved open in the schematic; the
     builder closes it, so it is always ready to start the fight.
4. **The portal is built in the village**, on open ground as near the middle
   as possible. Height counts heavily in that search: a flat house roof in
   the middle loses to the ground a few houses out.

**Every ground portal gets its own portal in the village.** Two bases never
share a way home: each village portal leads back to the ground portal that
made it.

If the village has no open ground left near its middle, or no village can
be founded (sky buildings switched off with `lualore_sky_buildings`, or no
open sky at any of the five heights), the portal falls back to the bare sky
overhead. It searches a 48×48 column from y 290 to 610 for any island with
room. If none has room, it builds a **small obsidian platform** at y 350, so
a trip never fails for lack of land.

### Going down

A portal built in the sky searches a 48×48 column for the highest open
ground below the floatlands. Columns of water or under trees are passed
over; over open sea it builds the platform on the water.

If a ground portal already stands within 24 nodes, it is **reused** as the
far end. That ground portal keeps its own link back to its village portal,
so a portal you build in the sky never takes over someone's way home.

### Either way

The far portal is built sunk into the ground so you can walk straight out,
and the two portals are **linked**. Later trips go straight to the linked
portal.

If the far portal has been broken, the next trip notices, forgets it and
searches afresh. Landing spots inside a protected area are passed over, and
a trip that could only end in one fails with a message instead.

The trip is a shortcut, not a way out of the world: the floatlands are open
sky, and falling off an island means falling a long way.

## 4b. The dark portal: to the wizard castles

Wizard castles sit deep underground, between y -120 and -1200, and are hard
to find. A **crystal on the roof** of a mese portal turns it into a way
there:

- Set any Everness crystal (`everness:crystal_purple`, `_orange` or
  `_cyan`) on top of the frame's roof. A frame lit while wearing one burns
  **black**, swirling with grey smoke (not violet, which reads as the
  Nether), and so does an already-lit portal the moment the crystal is
  placed. Taking the crystal off turns it blue again. Either way the
  portal forgets its old link, since it now leads somewhere else.
- **Where it leads:**
  - The nearest recorded wizard castle within 1500 nodes
    (`lualore_portal_castle_reach`).
  - If there is none, it raises one in the caves below. It looks for a
    cave floor a castle fits on in the 400 nodes under the castle band's
    top, and if there's no such cave it digs the castle into the rock. It
    is built by the normal castle builder: crypt, abandoned village, and
    four wizards around the statue.
- **Arrival:** you step out **on top of the castle**, through a dark portal
  of its own that leads back to the one you came through. It stands on the
  highest part of the roof where a frame fits, as near the middle as it
  can. If the cave is too low over the castle for that, a small obsidian
  landing is laid on the roof's highest point and the rock above it is
  cleared. (Only if the castle has no roof to find at all does it land on
  the floor beside the castle.)
- **The way home:** the castle's portal is dark because of where it
  stands, so it needs no crystal on its roof and always leads back. Every
  dark portal gets its own castle portal, even when several of them lead
  to the same castle, and each one takes you back to where you came from.
  Castle portals made before this, which turned blue and lost their way
  home, mend themselves the next time someone steps in.
- **The wizards:** a castle whose wizards are all gone **gathers a new
  group** a few seconds after someone arrives, at most once an hour per
  castle. That way the trip is always a fight, without becoming a farm for
  wizard drops.

**Getting a crystal:** freed Sky Folk can offer the quest *The Shadow Gate*
(6 obsidian, 2 mese crystals, 3 gold ingots). The reward is one crystal of
a random colour, and its description says what to do with it. Crystals
also grow in Everness's crystal forests.

## 5. Putting one out

Digging any frame block puts the whole sheet out at once. Frames broken some
other way — explosions, WorldEdit — are caught by an ABM every 7 seconds that
checks each sheet node still has sheet or frame on every side. The sheet
itself cannot be dug, blasted, built into or flowed into.

Relight a repaired frame with another ingot. A portal relit with the same
size in the same place keeps its link.

## 5b. Ruined portals

Dead portals stand here and there in the world, as a hint at what can be
built: a frame of the right shape, cracked and broken. **Three ruins in
four** (`ruins/RUINS.md`) have one standing beside them, so you find them
wherever you find ruins. They're on dry ground and never in a village.

- **Two kinds.** Sky ruins are in weathered stone and mossy cobble. Dark
  ruins are in obsidian, like the black portals to the wizard castles.
  About 4 in 10 ruins are dark. Very rarely (one dark ruin in 8) a dark
  ruin still wears its crystal on the roof.
- **Two styles.**
  - **Plain:** just the frame, sunk in the ground, with 2–4 blocks gone.
  - **Grand:** a larger frame (3 × 4 inside) on a worn platform between two
    broken pillars, with 3–5 blocks gone.
- **They never work.** Most of the frame is **Cracked Mese**: it looks
  like mese but its power is spent. It drops only 1–3 mese fragments, and
  no portal lights through it. Each ruin keeps 1–3 blocks of real mese. To
  make one work, replace the cracked blocks and fill the gaps with real
  mese, then throw in an iron ingot. The shape is already right. The
  corners are stone, since a frame doesn't need them.
- **Chests.** About half the ruins have a chest at the foot of the frame
  with 3–8 iron ingots (what lights a portal) and 2–5 mese fragments,
  sometimes with an obsidian shard or a few torches. It isn't filled with
  the biome loot village chests get.

## 6. Mirror Sentinels

The former boss of the door trials is now an ordinary hostile of the sky
islands (`valkyrie/mirror_sentinel.lua`).

| | Then (boss) | Now |
|---|---|---|
| HP | 220–260 | **40–55** |
| Armour | 140 | 100 |
| Damage | 5 | 3 |
| Behaviour | tethered over its island | **wanders**, drifting no more than 20 nodes from where it spawned |
| Drops | 2–4 crystals, 3–6 mese, 2–4 diamonds, a chest | 1–3 mese fragments, a mese crystal (1 in 3), a purple crystal (1 in 6) |

For scale: a Lit has 16–24 HP and a valkyrie 100–150.

It still hovers, keeps its distance in a fight and casts the black wizard's
blindness curse (one spell every 4 seconds at most). It spawns on any natural
floatland surface above `lualore_portal_sky_y`, day or night, at most two
per area. It drops mese because that is what portal frames are made of:
hunting Sentinels up there pays for the next portal down here.

The spawn egg is still in the creative inventory
(`/giveme lualore:mirror_sentinel`); one placed from the egg treats that spot
as home.

### Regenerating the Sentinel model

```sh
python tools/make_mirror_sentinel.py     # model + texture
python tools/model_extents.py models/mirror_sentinel.gltf   # sanity check
```

The model is 28 units tall (2.8 nodes at 10 units per node); the mob renders
it at `visual_size 0.85`. The generator self-checks face winding, index ranges
and buffer bounds, and emits a single 4-second `idle` animation.

## 7. Settings

| Setting | Default | Meaning |
|---|---|---|
| `lualore_sky_portals` | true | Portals light and carry players. When off, existing portals stay visible but inert. |
| `lualore_portal_delay` | 2.0 | Seconds in the sheet before travelling. |
| `lualore_portal_mobs` | true | Mobs go through portals a player has opened (after 2 more seconds than a player). |
| `lualore_portal_sky_y` | 290 | Where the sky begins: portals above lead down, below lead up. |
| `lualore_portal_village_reach` | 800 | Go to a portal village this close instead of founding one. |
| `lualore_portal_village_houses` | 18 | Houses in a village a portal founds (6–30). The island grows to fit. |
| `lualore_portal_max_size` | 256 | Largest interior side the frame scan follows. |
| `lualore_mirror_sentinels` | true | Sentinels spawn on the sky islands. |
| `lualore_portal_ruins` | true | Three ruins in four get a ruined portal beside them. Their frequency follows the ruins' own settings (`lualore_ruin_spacing`, `lualore_ruin_chance`). |

## 8. Commands

| Command | Priv | Purpose |
|---|---|---|
| `/sky_portals [radius]` | — | Portals within the radius (default 128): ground or sky, size, position and where each one leads. |
| `/spawn_portal_ruin [sky\|dark] [plain\|grand] [crystal]` | server | Raise a ruined portal a few nodes from you, for testing. |
| `/find_portal_ruin` | server | The nearest recorded ruined portal. |

## 9. What happened to the obsidian doors

The shrine generator, the restoration puzzle, the mirror islands and their
commands are gone, along with the three `obsidiandoor*.mts` schematics. The
system registered no nodes of its own, so worlds that already have shrines
and mirror islands keep them as ordinary blocks — nothing turns into an
unknown node.

`portal/legacy_doors.lua` rescues anyone who logged out standing on an old
mirror island: on joining they are sent back to the shrine they came
through, read from the `obsidian_doors` and `obsidian_door_returns` records
the old system left in mod storage. Nothing else reads those records. Delete
the file once no world in use still has players parked on a mirror island.

## 10. Implementation notes

- **Records** live in mod storage under `sky_portals`, keyed by the
  interior's bottom cell at the low end of the axis plus the axis:
  `x,y,z,axis` → `{x, y, z, axis, w, h, sky, link}`. Resizing a frame gives it
  a new key, so a rebuilt-bigger portal finds a new far end.
- **The landing search** reads one VoxelManip over the box and classifies each
  content ID once: *solid* (walkable, not leaves or trunk), *clear* (air, or
  something a node can replace, like grass) or *other*. Every second column
  is scanned; a candidate needs solid ground under a 4×3 footprint and clear
  space 4 high above it.
- **The texture** is generated by `tools/make_sky_portal_texture.py`: 32
  frames of 16×16, a vortex twisted about each tile's centre over a scrolling
  wave pattern. Every term is periodic in both the tile and the loop, so the
  sheet tiles with no seams and the animation loops with no jump.
- **Testing.** Everything was exercised offline under LuaJIT against a
  stubbed world (70 checks): the frame scan, ignition, collapse, both
  directions of travel, a destroyed far end, the platform fallbacks, the
  walk-away case, storage, and the villages. The village checks cover:
  founding a town and raising its island, a second ground portal getting
  its own village portal (and the right way home), reusing a ground portal
  without stealing its link, moving up when a floatland blocks the first
  height, ignoring small hamlets, using an existing town 700 nodes away,
  and falling back when sky buildings are off. The sky-site builder was
  stubbed in those checks.

  A second suite loads the **real** `floating_buildings.lua` (16 checks;
  only `place_schematic` is a stand-in, building hollow shells and dropping
  an open valkyrie chest into the castle the way the real schematic does).
  It shows:
  - A portal-founded town gets all 18 houses and exactly one castle, with
    one closed chest.
  - The castle comes with the founding, not from the retrofit, in five towns
    out of five (the plain 15% roll would manage that about once in
    thirteen thousand tries).
  - A castle-less town gets its castle on its own island when there is room.
  - A crowded castle-less town gets its castle on a rock joined to the rim.

  Mutations removing the forced castle and the retrofit were each caught.

  A third suite (37 checks) runs the real `valkyrie_chest.lua`,
  `valkyrie_fight.lua`, `sky_liberation.lua`, `sky_town_folk.lua`,
  `sky_folk.lua` and `sky_folk_footing.lua` on a simulated clock. It covers:
  - Sky Folk footing: rim, edge, a fall and a two-node step.
  - Towns freeing their folk.
  - A town filled to 40 on open ground and topped up after losses, with
    newcomers to a freed town arriving free.
  - The whole chest fight:
    - called off after 20 s away
    - restarted with all four
    - stragglers removed
    - called off after 12 s with a valkyrie missing
    - won
    - won chests left alone
    - old open chests closed, or kept if already freed
    - a boxed-in chest still releasing all four

  Six mutations were each caught: no rescue, no absence reset, ignoring
  missing valkyries, keeping stragglers, folk never learning their town is
  free, and no search for a spawn spot. With missing valkyries ignored, the
  chest stays open and killing the other three never frees the town, which
  is the bug players hit. Five mutations were each caught, the last only after the test
  was made to watch every tick:
  - a 2-tall minimum frame
  - counting small hamlets as villages
  - letting reuse overwrite a back-link
  - weighing height lightly in a village (the portal then landed on a house
    roof at y 568.5)
  - a missing step-out guard
