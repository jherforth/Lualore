# The Wooden Guardian

A walking tree that keeps a village safe: Lua Lore's answer to the iron
golem. It is about three nodes tall, against the player's two, with a broad
bark trunk, a crown of moss across its shoulders, long arms ending in
knotted fists, and two amber knot-eyes in a carved face.

## Where they come from

- **Every village has one.** It is placed when the village is built, on
  open ground a little way out from the middle. For villages that were
  built before the guardian existed, run `/furnish_village` while standing
  in one (needs the `server` privilege). It adds a guardian only if none is
  about, so running it twice never gives you two.
- **You can wake your own**, from any kind of wood:
  1. Craft a **Guardian Heart**: eight planks of any wood round a mese
     crystal.

     ```
     planks  planks  planks
     planks  mese    planks
     planks  planks  planks
     ```
  2. Stand four logs of any kind (they don't need to match) in a **T**: two
     logs stacked, and one log either side of the upper one. The arms can
     run east–west or north–south.

     ```
     log  log  log
          log
     ```
  3. Set the heart on top of the middle log. The logs and the heart are
     taken, and the guardian rises in a burst of bark and leaves.

  It keeps watch over the nearest village (within 90 nodes), or over the
  spot where you built it if there isn't one.

## What it does

- **Patrols.** It walks a circuit of six points round its village, 12 to 18
  nodes from the middle, and pauses at each one.
- **Fights monsters.** It goes after hostile mobs within 16 nodes, swings
  both arms down for heavy damage (8 a blow, with a long reach), and isn't
  knocked back. It has 120–150 HP.
- **Never harms a villager.** That covers anyone who lives in a village
  bed, whatever their trade, the witch included. It also spares a villager
  you've provoked into fighting you, the Sky Folk, and other guardians.
  Raiders and hostile villagers with no bed are fair game.
- **Retaliates.** Strike a villager within 24 nodes of a guardian and it
  comes for you for 30 seconds. That goes for everyone, including the
  player who built it. Hitting the guardian itself has the same effect.
  It gives up early if you die or get well out of its reach.
- **Can be repaired.** Right-click it with planks (+10 HP) or a log
  (+25 HP). Right-click with an empty hand to see its health and who woke
  it.
- **When it falls,** it drops sticks and planks, and its heart one time in
  four.

## Settings

| Setting                     | Default | Effect                                   |
|-----------------------------|---------|------------------------------------------|
| `lualore_village_guardians` | true    | Place a guardian in every village.  Players can still build their own when this is off. |

A spawn egg, *Wooden Guardian*, is in the creative inventory for testing.

## For modders

`villagers/extras/wooden_guardian.lua` publishes `lualore.guardian`:

- `spawn(pos, home, builder)`: spawn a guardian with its feet at `pos`,
  keeping watch over `home`.
- `alert(pos, player)`: every guardian within 24 nodes turns on `player`.
- `is_protected(luaentity)`: whether a guardian will never fight this
  entity.
- `near(pos, r)`: whether a guardian is within `r` of `pos`.
- `find_t(pos)`: the five nodes of a valid T with the heart at `pos`, or
  nil.

The model and textures come from `tools/make_wooden_guardian.py`. Run it
from the mod root, and add `--preview DIR` to render front and side views
of its poses. The idle, walk and attack clips sit on one timeline at
0–2, 2.5–3.5 and 4.0–4.8, because Luanti plays only one glTF animation.
