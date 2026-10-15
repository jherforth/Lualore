# Lua Lore

A villager and lore mod for Luanti that adds living villages across multiple biomes with NPCs that have moods, trades, and unique behaviors. Explore floating sky cities, discover underground wizard castles, and interact with diverse communities.

## Features

### 🏘️ Biome Villages

Villages generate naturally in six distinct biomes:

- **Grassland** - Farming communities with traditional architecture
- **Desert** - Oasis settlements with markets and exotic trades
- **Savanna** - Tribal villages with ceremonial shrines
- **Lake** - Fishing communities built near water
- **Ice** - Hardy settlements in frozen tundra
- **Jungle** - Tribal communities with unique customs

Villages are placed deterministically: one candidate per grid cell (spacing and chance settings), with houses laid out on a ring around the centre and central buildings (church, market, stable) beside it — buildings can never overlap. The site is levelled into an irregular, lobed clearing rather than a disc, then dressed with patchy ground, trodden paths between the houses and biome-appropriate grass, flowers and shrubs. Density is fully tunable in the settings; see `villagers/VILLAGE_PLACEMENT.md`.

### 👥 Villager Types

Villages are populated with different NPCs, each with their own trades and behaviors:

- **Farmers** - Trade crops and food
- **Blacksmiths** - Trade tools and weapons
- **Jewelers** - Trade gems and metals
- **Fishermen** - Trade fish and aquatic items
- **Clerics** - Trade mystical items
- **Rangers** - Protect villages from monsters
- **Entertainers** - Add atmosphere to villages
- **Witches** - Hostile magic users with teleportation abilities
- **Raiders & Hostile NPCs** - Dangerous enemies

### 🎭 Villager Moods

NPCs have emotions that affect their behavior. They display mood icons above their heads and make sounds based on how they feel. Villagers can be happy, content, neutral, sad, angry, hungry, lonely, or scared.

Feed them bread or apples to keep them happy, and trade with them to reduce their loneliness.

### 💱 Trading

Hold an item a villager wants and approach them. They'll show a trade icon when interested. Right-click while sneaking or punch with the trade item to complete the trade.

### 🧙 Cave Wizards

Deep underground, cave castles generate at regular intervals (roughly every 400 nodes of newly explored caves). Each one holds powerful wizards of four colors:

- **Black Wizards** - Wield dark magic
- **White Wizards** - Channel pure energy
- **Red Wizards** - Command fire magic
- **Gold Wizards** - Master precious magic

Defeat them to obtain their magical wands, which grant you powerful abilities. Each wand type has unique magical properties for combat and exploration.

### �️ The Lit — Cave Wanderers

A lone flame creature wanders the caves, carrying its own soft glow wherever it goes. Lits are fairly common — just about any cave can have one — and completely passive: they ignore players until attacked. Strike one, though, and it rolls its personality (50/50):

- **Fight** — chases you and hurls fire bolts that set you ablaze for a few seconds. Badly wounded, it panics and switches to flight.
- **Flight** — runs away; when cornered or chased too closely it drills straight down through the floor to escape into a deeper cavern.

Defeated Lits drop a **torch**, **coal** and **flint**. See `caves/LIT.md` for details and tuning.

### �🛡️ Valkyries & Sky Folk

High above the clouds, floating sky villages hold an ancient secret. Valkyries of four colors guard imprisoned Sky Folk:

- **Blue Valkyries**
- **Green Valkyries**
- **Violet Valkyries**
- **Gold Valkyries**

Defeat the Valkyries to free the Sky Folk. Once liberated, they'll mark the location of other captive Sky Folk with magical pins and send you on quests to free their companions. Free enough Sky Folk and earn special rewards.

Sky buildings are placed on the floating crystal islands by the same deterministic grid the ground villages use: one site per cell, planned before anything is placed, so houses never overlap and never hang off the island. Most sites are small hamlets — the **skycastle**, which holds the single valkyrie chest, is rolled rarely on top of that. The chest always generates closed; opening it releases four Valkyries at once. Defeat all four and the chest stays open and the town is freed for good — every Sky Folk in it, including any that were out of range or arrive later. If you die and respawn elsewhere, leave, or a Valkyrie goes missing mid-fight, the survivors withdraw into the chest and it closes, ready for you to try again. Tuning and commands (`/spawn_skysite`, `/find_skysite`) are in `valkyrie/SKY_SITES.md`.

### 🧑‍🌾 Villagers at Work

Every villager claims a workstation near their bed and works it through the day, heading home
at dusk. Each trade does something you can use: the **blacksmith** mends worn tools at his
anvil, the **cleric** will make a village your respawn point for a mese crystal, the **farmer**
works a real field you can also harvest, the **fisherman** fills his trap, the **jeweler**
turns out valuables drawn from the local biome, the **entertainer** keeps the village's spirits
up, and the **vagrant** — who has nothing to sell — will tell you where to find a ruin, a village
or a sky site in exchange for a meal.

Villages remember you. Feeding, trading and using what villagers make builds **standing**, and
a village that knows you shares more of what it makes. It can only go up. See
`villagers/VILLAGER_JOBS.md`.

### 🏗️ Village Buildings

Each biome has unique structures: houses, churches, markets, stables and more. A village plan is computed first (flat ground, no overlapping footprints) and only then placed, so buildings always form a clean hamlet instead of scattering or overwriting each other.

Building density is controlled by settings such as `lualore_village_spacing`, `lualore_village_houses_min/max` and `lualore_village_central_chance` — see `villagers/VILLAGE_PLACEMENT.md`. In-game helpers: `/spawn_village [biome]` places one at your feet for previews, `/find_village` points you to the nearest recorded village.

### 🏚️ Procedural Ruins

Broken castles, ruined towers, collapsed wall fragments and ancient stone circles rise from the landscape in the six village biomes — now fully procedural, so every ruin is unique:

- Walls crumble towards their tops, whole sections have collapsed, gates stand bereft of doors and rubble scatters around the foundations.
- Ruins follow the terrain, use biome-appropriate materials (mossy stone in grasslands and jungles, sandstone in deserts and savannas, ice and snow up north, soggy stone at lake shores) and mossy flagstones show where courtyards once were.
- Many ruins hide a treasure chest; the existing loot system fills it with biome-appropriate loot when you find it.

Placement uses a deterministic grid (`lualore_ruin_spacing`, `lualore_ruin_chance` settings) and keeps a respectful distance from villages. `/spawn_ruin` builds one at your feet, `/find_ruin` locates the nearest — see `ruins/RUINS.md` for tuning and how to add your own ruin themes.

### 🌀 Sky Portals

Build an upright rectangle of **mese blocks** — at least 2 wide and 3 tall inside, like a nether portal, and as large as you like beyond that — then **drop an iron ingot into it**. The frame drinks the ingot and fills with a swirling blue sheet. Stand in it for a moment and you are carried up to a **sky village**; a portal built up there takes you back down.

- Each portal leads to a **sky town** of 18 houses with its Sky Folk and **one skycastle**. Opening the castle's valkyrie chest starts the fight that frees them; it is the only way. If there isn't one within 800 nodes, the first trip raises a crystal island overhead and founds one there. Later portals nearby lead to the same town, which is kept at 40 Sky Folk. Sky Folk no longer walk off island edges.
- Every portal gets its own portal in the town and leads back to the right base, so two players' homes never share a way back.
- Break any frame block and the sheet goes out. Relight it with another ingot and it keeps its link.
- Luanti has no separate dimensions, so the sky islands are the floatlands of the same world — the portal is a way up, not a way out. Mind the edges.

**Mirror Sentinels** — hovering obelisk constructs that cast blinding curses — wander the sky islands. They drop mese, which is what the next portal frame is made of. `/sky_portals` lists the portals near you and where each one leads — see `portal/SKY_PORTAL.md` for the full guide.

### 🚪 Smart Doors

Villagers open the door they are about to walk through and close it behind them once they are on the other side — so at dusk they head home, let themselves in and settle by their bed, and in the morning they come back out and the house is shut up again. Doors from any mod are handled, whichever way the hinge faces. On top of that, the village sweeps its doors open at 6AM and closed at 10PM for a bit of daily rhythm.

## Installation

1. Download or clone this repository
2. Place the folder in your Luanti mods directory
3. Enable the mod in your world settings

## Dependencies

- **mobs** (mobs_redo), **default**, **farming**, **3d_armour** - Required
- **caverealms**, **everness**, **ethereal** - Required for biome support
- **intllib** - Optional (for translations)
- **OR** play on an **Asuna**, which includes all dependencies

## Usage

- **Right-click** - Interact with villagers
- **Right-click + Sneak** - Trade with held item
- **Right-click with food** - Feed villagers
- Some villagers can be tamed and will follow you

## Credits

Built upon contributions from the Luanti modding community:

- FreeLikeGNU's Witches
- Shaft's Automatic Door Opening
- Liil's Native Villages (forked from)
- Bosapara's Emoji

## License

See LICENSE file for details.

## Contributing

Contributions are welcome! Please follow existing code conventions, test in multiple biomes, and document new features.

---

**Personal Note**: Why was this created? The short story is that I have three adopted children who came to me obsessed with MCraft. I host my own services at home and came across Luanti, and instantly saw the vast potential for endless adventures. I wanted to avoid an outright clone, or outright familiar experience, so we landed on Asuna, which is an awesome blank slate to really build the world you desire. We craved something beyond adding in hostile mobs (which we did, and love what the community has built), and something a bit more than just some random villages. What I hope this mod does is inspire the building of lore for Luanti's games. I'd love to see the community embrace, or add, Lore Jams, and not just the neat Game Jams that everyone looks forward too. The community has really built something awesome, and I think creating more wonder and lore for users to install and interact with will really add a sense of wonder and curiosity to one of the best open world experiences that exists.

**Acknowledgement**: This game was built on the Bolt.new/Bolt.diy platform using Claude Code. AI is a fantastic tool to help unlock the ideas of those who lack the ability, bring those ideas to life. It certainly helps to have some technical and coding background, as it helps you "speak dev" in a more efficient way with AI. 
