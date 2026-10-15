# 🛠️ Villager Jobs

Villagers claim a workstation near their bed and spend their working day at it, returning
home at dusk. Implemented in `villagers/systems/villager_jobs.lua`, with the WORKING state
itself living alongside the other behaviour states in `villager_behaviors.lua`.

## The working day

| Period | Working | Socialising | Wandering |
| --- | --- | --- | --- |
| Morning (6–8am) | 70% | 10% | 20% |
| Afternoon (8am–4pm) | 55% | 20% | 25% |
| Evening (4–6pm) | 15% | 50% | 35% |

These are weights rolled at each state change, not a script, so a village never looks
clockwork — some villagers are always out and about. Dusk (7pm) onwards is not in the table
at all: going home is handled earlier in the behaviour update than the state machine, so the
bed routine always wins over work, mid-shift or not.

A villager with no workstation behaves exactly as it always did.

## Workstations

| Class | Works at |
| --- | --- |
| Blacksmith | `lualore:anvil`, `default:furnace` |
| Cleric | `lualore:village_altar`, `default:bookshelf` |
| Fisherman | `lualore:fishtrap`, `lualore:hangingfish` |
| Jeweler | `vessels:shelf`, `lualore:grasslandbarrel` |
| Entertainer | `lualore:hookah`, `lualore:sledge`, `lualore:jungleshrine`, `lualore:savannavshrine`, `lualore:desertcrpet` |
| Farmer | `lualore:field_stake` (see below) |
| Bum, Ranger | nothing — their work is walking, and arrives in a later phase |
| Witch | deliberately has no job; her whole tick belongs to `witch_magic.lua` |

Listed in priority order: the first type with a free instance near the bed wins. Node names
that no mod registered are dropped at first use and logged, so a class whose workstation
does not exist yet simply has no job rather than erroring.

### Where the workstations come from

Most of them a village already contains. Three did not exist anywhere — no building
schematic in this mod holds an anvil, an altar or a single tilled block — so they are
defined in `villagers/blocks/workstations.lua` and placed by
`villagers/systems/village_workstations.lua`:

| Node | Placed | Craftable |
| --- | --- | --- |
| `lualore:anvil` | with a `default:furnace` beside it, 6–16 nodes out | 8 steel ingots |
| `lualore:village_altar` | two nodes clear of the church, else near the centre | 8 stone brick + a mese crystal |
| `lualore:field_stake` | on the corner of each tilled plot, 12–26 nodes out | 2 sticks + wood |

A **farm plot** is 5×5: a water source in the middle so minetest_game's soil ABM keeps the
ground wet (dry soil reverts to dirt and takes the crops with it), the stake on one corner,
and `farming:soil_wet` with a wheat crop on the other 23 columns. Villages get one plot, or
two on a third of seeds. Ice villages get none — a wheat field on an ice sheet reads as a
mistake — but deserts do, as an oasis.

Nothing is placed unless the ground is level, open to the sky, clear of every building
footprint and free of anything already standing there. A village with no room simply gets
nothing rather than an anvil in somebody's front room.

Placement runs **after** the ground-dressing pass, because dressing plants over every free
column and would otherwise bury the lot.

### Who lives in a village

Beds used to pick a class uniformly at random, which left a six-house village with a better
than even chance of having no blacksmith, and nothing stopped it rolling four farmers. A
village now deals from a tiered deck:

1. **farmer, blacksmith, cleric** — shuffled, so every village of three houses or more has
   all three
2. **fisherman, jeweler, entertainer, ranger** — if there is room
3. **farmer, bum, farmer, bum, witch** — filler

Measured over 400 villages: three- and six-house villages get no duplicate trades at all and
always have a smith and a farmer; twelve-house villages hold one of everything with at most
three farmers. The overall spread stays farmer 25%, bum 16%, everything else 8%.

`/populate_village` deals from the same deck.

- A villager searches **once**, on entering the working state, within **20 nodes** of its
  bed. That radius is not arbitrary: `check_stuck_and_recover` teleports a villager home
  once it strays past roughly 45 nodes, so a station inside 20 can never trigger it.
- Finding nothing, it waits 5 minutes before looking again, so an unhoused villager never
  loops on the search.
- Claims are stored in mod storage under `job_stations`, keyed by **bed** position — beds
  survive an unload, entity ids do not, so a villager re-adopts its own workplace after a
  restart. The claimed node also carries a `lualore_station` meta field and an infotext, so
  you can see whose workplace it is by looking at it.
- Claims are released when the villager dies.

## The trades

Each class fills in its own entry in `lualore.jobs.classes`, in its own file
(`villagers/systems/job_*.lua`). A class with no file simply has no mechanic and still walks
to its workstation.

| Trade | At work | What you get |
| --- | --- | --- |
| **Farmer** | Works the rows of his field — harvests, sows, tends | A share of the harvest; the plot is real farmland you can work yourself |
| **Blacksmith** | Hammers ingots and tools out at the anvil | **Repairs worn tools** at his anvil for steel, priced by wear and your standing |
| **Cleric** | Heals and cheers villagers around his altar | Lay a **mese crystal** on the altar and the village becomes where you respawn, plus a 4-minute blessing |
| **Fisherman** | Works a trap that must have water near it | Catfish, string, clay and the occasional pearl |
| **Jeweler** | Turns out small valuables at his shelf | Pieces drawn from **the village's own biome loot table** — desert villages deal in gold, jungle ones in emerald |
| **Entertainer** | Performs at the biome prop, turning on the spot | Everyone nearby cheers up; watching earns standing, at most once every 90s |
| **Vagrant** | No workstation — he loiters and begs | **Feed him and he tells you where something is** |
| **Ranger** | Walks a six-point circuit of the village bounds | An armed villager out where trouble arrives |

### The vagrant is the interesting one

He has nothing to sell. What he has is knowing the country: feed him and he marks a ruin, a
village or a sky site you have not seen, as a waypoint, with a line about
which way to go. Everything he knows already existed — the village placer, the ruins and
the sky sites each keep records for their own `/find_` commands, and he
reads those. He holds off once you are carrying three unvisited marks, and skips anything
within 60 nodes as not worth mentioning.

### Blacksmith repairs

Cost is in steel ingots, from `BASE_COST + wear`, multiplied by your tier (Stranger ×1.5 down
to Kin ×0.5) and **capped at 4**. The cap matters: the price is in steel whatever the tool is
made of, so without it a stranger could be quoted more for mending a steel pick than building
a new one. As it stands, mending a diamond or mese tool is a bargain and a steel one is
roughly a wash — which is the nudge towards building standing.

An anvil with no smith within 6 nodes is a cold lump of steel, and the altar with no cleric
is just stone. Both are craftable, so you can set up your own — but you still need the
villager.

## The farmer

The first class with a real mechanic. He works the plot his field stake describes:

- **Harvests** anything ripe into his stock and puts the ground straight back to seed.
- **Sows** bare tilled ground — so a field you have stripped yourself fills back in.
- **Tends** what is still growing, nudging a crop on a stage roughly one time in three.

Growth itself is left to the farming mod's own ABM. The tending nudge is what makes him
look busy; it is deliberately too slow to race a field to ripeness, and a plot keeps working
with no farmer anywhere near it. The plot is ordinary farmland: harvest it, extend it, or
ignore him entirely.

**Right-click him with an empty hand** and he hands over a share of what he has gathered —
how much depends on your standing with the village — once per in-game day. Ask again the same day and he tells you so; his stock keeps building in the
meantime. Stock is capped at eight kinds of item and 99 of each, so nothing accumulates
without bound while you are away.

Farmers use a tighter `work_reach` (1.2 nodes) than the default 2 that suits standing at an
anvil, so they walk the rows properly instead of reaching half the field from one spot.

Digging up the stake stops the job cleanly — he writes nothing and goes back to wandering.

## Trading

Sneak and right-click a villager to open their counter. Each one keeps a short list of
standing offers — so much of this for so much of that — rolled from their bed position, so a
villager always deals in the same things and two of the same trade in one village deal in
different ones.

How many offers they show you depends on how they feel and how well you are known: two to
begin with, one more if they are happy or content, one more again at Friend standing, four at
most. Offers you cannot afford are shown greyed with what you are holding, so you can see
what to go and fetch. Each villager will do **four trades a day**, which is what stops a
village being an infinite goods machine and gives you a reason to know more than one of them.

Villagers buy raw and sell worked — iron for steel, wheat for bread, pearls for diamonds — so
trading in circles between them does not pay. Any offer naming an item the game does not have
is dropped at load.

The old path is still there: punching a villager while holding something they want trades it
directly, without opening anything.

## Getting about

Villagers used to navigate by pointing at their goal and walking, because mobs_redo only
pathfinds while a mob is attacking. A wall between a villager and its bed meant a villager
stuck against a wall until the stuck timer teleported it home.

They now use the engine's own A* (`minetest.find_path`) — there is no custom pathfinder here,
just something driving that one and keeping the result on the villager. Searches are rationed
to about one every two seconds per villager and only for goals within 48 nodes; in practice a
villager crossing a village runs **two searches** for the whole trip. If no route can be
found it walks straight at the goal, which is exactly what it did before, so a villager that
cannot path is never worse off.

**Doorways are handled by hand, and have to be.** The engine's pathfinder asks whether a node
is `walkable`, and a door node is — open or shut, because what actually swings aside is the
door's collision box, not its walkability. A bed inside a house is therefore *unreachable* as
far as A* is concerned, so a trip indoors is walked as an ordered journey:

1. **To the door** — path to the square outside the doorway. Ordinary A*, and it works,
   because that square is outside the building.
2. **Through it** — line up with the gap, wait for the door to actually be open, then step to
   the square on the far side. Two nodes, no pathing: A* cannot describe this step.
3. **To the goal** — path from inside to the bed. Ordinary A* again.

Leaving in the morning is the same journey in reverse and falls out of the same code.

Three things in there are less obvious than they look, and each one was a bug first:

- **Which way a doorway runs is read off the world** — the axis whose two opposite neighbours
  are both standable — never from the direction the villager is coming from. Derive it from
  the villager's heading and a diagonal approach puts the "square outside the door" inside a
  wall.
- **Which side the villager is on is decided by A*, not by distance.** Stand west of a house
  whose door faces south and the square *inside* the door is nearer to you than the one
  outside, because the wall between does not count towards a straight-line measurement. That
  sent villagers to the wrong side of their own front door.
- **Getting through is measured by which side of the door the villager is on**, not by
  reaching the far square. Waiting to arrive somewhere exactly is what left them shuffling on
  the threshold, and distances to a threshold are measured flat, ignoring height, because a
  house floor is rarely level with the ground outside it.
- **The crossing itself is walked for them.** Everywhere else only sets a direction and lets
  mobs_redo move the mob, which is fine over open ground — a wobble of a few degrees does not
  matter ten nodes out. A doorway is one node wide and mobs_redo changes a walking mob's
  course at random, so over the two nodes of a threshold that wobble is the difference between
  going through and shouldering the frame. Only while mid-crossing, only along an axis already
  shown clear on both sides, only while the door is open.
- **Route corners are aimed at one at a time.** A route is a chain of adjacent nodes; a
  generous "close enough" radius skips two or three at once and the villager ends up aiming
  diagonally across a corner, into the corner block.

Villagers **sleep on their beds**. One that has reached its bed lies down on it, in the middle
of the pair and along its length, using frames 162–166 of `character.b3d` — the model's lay
pose, which this mod's animation table happens to call "die", which is why a dying villager
appears to lie down. Holding the pose takes a small trick: mobs_redo sets the animation from
the mob's state every step, but its setter returns early when asked for the animation already
current, so the villager reports "standing", lets mobs_redo record that, and then sets the lay
frames straight on the object. Waking asks mobs_redo for "walk", which clears the cache and
takes the model back. Position is re-asserted each tick while asleep, because mobs_redo still
rolls its walk chance from the stand state and would otherwise nudge a sleeper out of bed by
morning. No bed there any more and it just stands by where the bed was.

Doors are opened once per crossing and shut once it is finished — never on a timer. An
earlier version also shut a door after ten seconds, so a villager that opened one and failed
to get through would have it shut again, walk back up, open it again, and clatter away
indefinitely. A villager that wanders off leaves the door open instead; the village sweep
shuts everything at 10pm. Several villagers can share one doorway: the first opens it, the
rest walk through, and nobody shuts it on anybody.

## Village standing

How well a particular village knows you, per player, 0–100. It is **earn only** — nothing
you do lowers it. A reputation you can only lose by accident is a tax rather than a
mechanic, and a player defending themselves near a village should not find the place
permanently colder to them. (If you ever want losses, call `lualore.standing.earn` with a
negative amount; that is the whole change.)

| Tier | Standing | Share of what villagers make |
| --- | --- | --- |
| Stranger | 0–19 | 40% |
| Guest | 20–49 | 60% |
| Friend | 50–79 | 80% |
| Kin | 80–100 | 100% |

Earned by feeding a villager (+1), completing a trade (+2), and using what a villager makes
(+1) — capped at **12 a day per village**, so standing is built over time rather than farmed
in an afternoon. Crossing a tier is announced once.

Standing is keyed by the same string `village_placement.lua` records villages under, so
`/find_village` and this system always agree about which village you are in. Villages with
no record — hand-built hamlets, or anything from before the record system — fall back to a
coarse grid cell, so standing still means something there instead of silently going nowhere.

What is withheld is **kept in the villager's basket**, not destroyed: come back as a Friend
and it is still there.

`/standing` reports where you stand, what share that earns you, what is left to the next
tier, and how much of today's allowance you have used.

## Commands

| Command | Privs | What it does |
| --- | --- | --- |
| `/jobs [radius]` | server | Lists nearby villagers with their class, behaviour state, distance and claimed workstation (default radius 40). |
| `/standing` | — | How well the village you are standing in knows you. |
| `/jobs [radius]` (see above) | server | Also shows which trade each villager has. |
| `/furnish_village [radius]` | server | Adds the anvil, forge, altar and farm plots to the village you are standing in (default radius 34). Needed for villages that already exist — new ones are furnished as they generate. |

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `lualore_villager_jobs` | `true` | Off restores the original wander/socialise day exactly: the schedule defers to the old two-state cycle and the job tick becomes a no-op. |
| `lualore_village_workstations` | `true` | Off stops new villages being furnished. `/furnish_village` still works. |
| `lualore_village_standing` | `true` | Off disables standing entirely; villagers then share everything with anyone. |

## Notes

- Villagers now carry `nv_class` on the entity. Everything used to re-derive the class by
  matching on the entity name; `lualore.jobs.get_class(self)` is the single accessor, and
  still falls back to the name match for anything that predates the field.
- `nv_trade_items` and `drops` come off the mob prototype, which is **shared by every
  instance of a class across all six biomes**. Never mutate them in place — a villager takes
  a private copy of its trade list on activation. Job output goes in `nv_stock`, never in
  `drops`.
- The job tick runs at most every 2 seconds, with its phase staggered per villager so a
  village does not tick as one block, and skips entirely when no player is within 40 nodes.
  The shared player-position list is refreshed by a single globalstep rather than per mob.
- Job state (`nv_class`, `nv_work_pos`, `nv_stock`) is saved with the villager. It must stay
  plain data: `get_staticdata` returns an empty string if serialisation throws, and an empty
  staticdata silently costs the villager its bed *and* its mood.

## Prerequisites that shipped with this

Three bugs made any of this impossible, and were hurting the mod on their own:

1. **Village props were unknown nodes.** Every `.mts` schematic stores the prop names under
   the old `nativevillages:` namespace. `villagers/blocks/aliases.lua` maps all eight onto
   this mod's nodes (`cannibalshrine` is a rename to `lualore:jungleshrine`, the rest are
   namespace swaps). Existing worlds heal themselves as mapblocks reload.
2. **Every village in every biome spawned grassland villagers.** Biome detection looks for a
   prop near the bed; it was looking for `lualore:` names the schematics never place, three
   of which matched no registered node at all. There is now one marker table, in
   `aliases.lua`, that both `house_spawning.lua` and `village_commands.lua` read.
3. **`lualore:catfish_raw` was never registered**, so the fisherman's only drop and trade
   reward was an unknown item. Raw and cooked catfish now exist in `lakeblocks.lua`, with a
   cooking recipe. They borrow the hanging-fish artwork until proper textures exist.

Also folded in: the two duplicated copies of the trade code became one, which is what finally
called `lualore.mood.on_trade` — a function that had never run, so trades gave no hunger
relief and never played the trade sound.
