# 🌀 Sky Portals

*Mese-framed portals, lit with an iron ingot, that carry you up to the sky
islands and back.* `portal/sky_portal.lua`

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

## 4. Where it goes — and the lack of dimensions

Luanti has no separate dimensions. The sky islands are Asuna's floatlands —
the same world, scattered through **y = 287 to 28,000**. So a portal leads
**straight up or straight down from where it stands**:

| Portal is... | It leads... |
|---|---|
| below `lualore_portal_sky_y` (290) | up, to the sky islands overhead |
| at or above it | down, to the ground below |

**Going up**, the first trip:

1. If a recorded **sky site** (a hamlet or castle from
   `valkyrie/floating_buildings.lua`) lies within 160 nodes, it aims for that
   island. A site with no room for a frame falls back to step 2 rather than
   clearing a platform among its houses.
2. Otherwise it searches a 48×48 column from y 290 to 610 for island
   surface with room for a 4×5 frame and somewhere to step out on both sides,
   preferring the spot closest to straight overhead at about y 350 — which
   favours the lowest islands.
3. If no island has room, it builds a **small obsidian platform** at y 350
   and puts the portal on that, so a trip never fails for lack of land.

**Going down** searches a 48×48 column for the highest open ground below the
floatlands. Columns of water or under trees are passed over; over open sea it
builds the platform on the water.

**Either way**, the far portal is built sunk into the ground so you can walk
straight out, and the two portals are **linked**. Later trips go straight to
the linked portal. A portal lit within 24 nodes of an existing far end
**reuses** it instead of building a second one beside it — the classic
behaviour, so two ground portals close together can share one sky portal (it
then leads back to whichever of them used it last).

If the far portal has been broken, the next trip notices, forgets it and
searches afresh. Landing spots inside a protected area are passed over,
and a trip that could only end in one fails with a message instead.

The trip is a shortcut, not a way out of the world: the floatlands are open
sky, and falling off an island means falling a long way.

## 5. Putting one out

Digging any frame block puts the whole sheet out at once. Frames broken some
other way — explosions, WorldEdit — are caught by an ABM every 7 seconds that
checks each sheet node still has sheet or frame on every side. The sheet
itself cannot be dug, blasted, built into or flowed into.

Relight a repaired frame with another ingot. A portal relit with the same
size in the same place keeps its link.

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
| `lualore_portal_sky_y` | 290 | Where the sky begins: portals above lead down, below lead up. |
| `lualore_portal_max_size` | 256 | Largest interior side the frame scan follows. |
| `lualore_mirror_sentinels` | true | Sentinels spawn on the sky islands. |

## 8. Commands

| Command | Priv | Purpose |
|---|---|---|
| `/sky_portals [radius]` | — | Portals within the radius (default 128): ground or sky, size, position and where each one leads. |

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
- **Testing.** The frame scan, ignition, collapse, both directions of travel,
  reuse, a destroyed far end, the platform fallbacks, the walk-away case and
  the storage round trip were exercised offline under LuaJIT against a
  stubbed world (47 checks). Two mutations — a 2-tall minimum and a missing
  step-out guard — were each caught, the second only after the test was made
  to watch every tick rather than the end position, since a bounce down and
  back up again ends where it started.
