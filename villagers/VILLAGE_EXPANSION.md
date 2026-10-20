# 🏗️ Growing a Village: Commissions

`villagers/systems/village_commissions.lua`

A village is no longer fixed at the size it generated. Players commission
new houses at the village's **notice board**, choose who will live in them,
supply the materials, and watch the house go up. When it is finished a
newcomer of that trade walks in from the edge of the village and settles.

## For players

### Filling an empty bed first

Villages rarely have one villager per bed: some beds are left empty when a
village is settled, and a bed is freed when its villager dies. While the
village has an empty bed, the notice board offers **Invite a settler**
instead of a commission:

- It needs only **10 standing**, so a Stranger who has made a start can
  use it. No materials are needed.
- Choose the trade; a settler of that trade walks in from the road and
  takes the empty bed nearest the board.
- If there is no workstation for that trade within reach of the bed, one
  is built nearby.

**Commissions open only once every bed is taken.** Then the only way to
bring someone new in is to build them a house.

A bed freed by a death is marked *vacant*. The automatic settler leaves it
alone, so a death isn't silently undone, and only an invitation fills it.
Before this, a dead villager's bed stayed marked as taken forever.

### Commissioning a house

1. **Find the notice board** near the middle of the village. Villages
   generated from now on have one. For an existing village, a server admin
   runs `/furnish_village` standing in it. The board is also craftable:
   wood and paper.
2. **Right-click it and choose a trade**: farmer, blacksmith, cleric,
   fisherman (only in villages near water), jeweler, entertainer or ranger.
   You need **Guest** standing in that village.
3. The village **chooses a plot** on its edge, plans one of its own house
   designs and posts a **bill of materials**. If there's no level ground
   left, it builds on a **terrace**: higher or lower ground nearby, cut and
   filled flat.
4. **Deliver** with *Deliver what I carry*. It takes only what the house
   still needs, never more. Anyone can help, and each delivery earns
   standing.
5. Once everything is in, **building starts**:
   - The plot is levelled and the foundation laid.
   - Scaffolding goes up at the corners.
   - A layer rises every 30 seconds while someone is within 96 nodes.
   - A pin marks it for whoever commissioned it.
6. When it is done:
   - The scaffolding comes down.
   - The newcomer arrives on the road beyond the house, thanks you by
     name, and moves into the new bed.
   - A workstation for their trade is built beside the house: a forge,
     altar, farm plot, fish trap, shelf or stage prop.

A village takes **one commission at a time**, and at most **8** in all:

| House | Standing needed | Cost |
|---|---|---|
| 1st and 2nd | Guest | ×1.00, ×1.25 |
| 3rd to 5th | Friend | ×1.50 to ×2.00 |
| 6th to 8th | Kin | ×2.25 to ×2.75 |

The commissioner can withdraw a commission until the first delivery.

## How it works

- **The bill comes from the house itself.** The chosen schematic is read
  and its above-ground blocks are counted. The commonest five materials are
  asked for at a quarter of their count, multiplied by
  `1 + 0.25 × houses commissioned so far`. Some blocks are converted or
  left out:
  - **Converted:**
    - stairs, slabs and slopes become the block they're cut from (the
      grassland thatch is `stairs:slope_straw`, so it asks for
      `farming:straw`);
    - placed forms become the item they drop (`default:torch_wall` becomes
      `default:torch`, `xpanes:pane_flat` becomes `xpanes:pane`).
  - **Left out:**
    - natural ground: dirt, sand, gravel;
    - beds, doors, plants and liquids;
    - the village's own `lualore:` props;
    - anything not obtainable.

  So every palette asks for its own materials with no table to maintain.
  For example:
  - **Grassland house:** straw, stone brick, wood, glass panes, a torch.
  - **Desert house:** 54 sandstone brick, 22 wood, pine wood, silver
    sandstone brick, fence.
- **The plot.** One VoxelManip read covers the area around the village.
  Rings are searched outward from 14 to 90 nodes for a footprint, plus a
  3-node margin, on open ground within 2 nodes of the village floor. Each
  column of that ground must also be:
  - under open sky;
  - not a path, house, tree or workstation;
  - not water;
  - not protected.

  The plot and its margin are levelled to the village floor.
- **Terraces.** A village hemmed in by hills, slopes or water gets a second
  search over the same rings, used only when no level plot exists anywhere.
  A terrace can stand on ground up to **10 nodes above or below** the
  village floor. Its floor is the height of the ground at its middle, and
  every column of the plot and its margin must be within **4 nodes** of
  that. Higher ground is cut away and hollows are filled. A gentle slope
  (1 in 2) or a lumpy hillside can be terraced; a cliff or anything steeper
  can't. A plateau well above the village isn't part of it.
- **Building layer by layer.** Each layer is a one-high slice of the
  schematic, placed with `place_schematic` and the house's rotation, so a
  house built a layer at a time is identical to one placed at once. That
  was checked block by block in all four rotations. The layers sunk below
  ground (the palette's `offset`) are laid together as the foundation.
- **The newcomer.** The house's bed is reserved for the chosen trade
  (`lualore.villager_deck.reserve`), then `house_spawning.populate`
  settles the house. A reserved bed skips the usual 28% chance of staying
  empty, and is drawn from its reservation, not the deck. So the newcomer
  arrives through the same path as every other villager: bed claim, job
  station, schedule and sleep all work unchanged. Other beds in the house
  settle as usual, so a house can bring a family.
- **Records.** Commissions are stored in mod storage under
  `village_commissions`, keyed by the village's record key, and they
  survive restarts mid-build. The village record counts `commissioned` and
  `houses`.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `lualore_village_commissions` | true | Boards take commissions. |
| `lualore_village_max_commissions` | 8 | Most houses one village can be given. |
| `lualore_commission_cost` | 0.25 | How much more each commission costs than the last. |

## Commands

| Command | Priv | Purpose |
|---|---|---|
| `/village_commission` | server | Show the commission in hand in this village. |
| `/village_commission rush` | server | Deliver, build and finish it now (testing aid). |
| `/furnish_village` | server | Adds the notice board (and missing workstations) to an existing village. |

## Testing

Checked offline under LuaJIT with real schematic data:
- **Bills:** a bill for every one of the 24 village houses (1–5
  obtainable materials each, with the right conversions), and the cost
  growth.
- **Plot finder:** on a synthetic village with houses, a path, a hill, a
  tree and a pond, it chose a clear plot 17 nodes out.
- **A full commission:**
  - the standing gate;
  - one commission at a time;
  - partial and over-supplied deliveries;
  - standing earned;
  - nothing built before the 30-second interval;
  - every layer placed once, bottom to top;
  - scaffolding removed;
  - the bed reserved and settled;
  - a workstation placed;
  - the record updated;
  - the pin set and cleared;
  - Friend and Kin gates, withdrawal, and the cap of 8.
- **Layers:** layer-by-layer building matches a whole placement in all
  four rotations.
- **The real `house_spawning.lua`:** a reserved bed is settled despite a
  forced empty-bed roll, by the reserved trade, exactly once.

Not yet run in game.
