-- lakebuildings.lua
-- Village palette for lake shores (stilt houses over the water).
-- The actual placement logic lives in systems/village_placement.lua;
-- this file only describes WHAT can be built here.

lualore = lualore or {}
lualore.village_palettes = lualore.village_palettes or {}

lualore.village_palettes.lake = {
	name = "lake",
	biomes = {
		"deciduous_forest_shore",
		"coniferous_forest_shore",
		"coniferous_forest_ocean",
		"deciduous_forest_ocean",
		"swamp_shore",
		"swamp",
		"marsh",
		"naturalbiomes:alderswamp",
	},
	surface = {
		"default:dirt", "default:sand", "default:clay",
		"default:dirt_with_grass",             -- swamp, marsh
		"naturalbiomes:alderswamp_litter",     -- alder swamp
	},
	offset = 0,      -- stilts are part of the schematics
	-- A shore is half water, half the forest behind it: the site vote in
	-- village_placement.lua takes a lake village on a quarter of the
	-- footprint, so long as its centre is on the shore.
	vote_share = 0.25,
	-- Ground dressing (villagers/systems/village_ground.lua): a shoreline
	-- of grass giving way to sand and gravel.
	ground = {
		accents = {
			{"default:dirt_with_grass", 12},
			{"default:sand", 8, bare = true},
			{"default:gravel", 3, bare = true},
		},
		worn = "default:sand",   -- a scuffed shoreline around the stilts
		path = "default:gravel",
	},
	plants = {
		density = 0.9,
		list = {
			{"default:grass_2", 6}, {"default:grass_3", 6},
			{"default:grass_4", 4}, {"default:grass_5", 3},
			{"default:junglegrass", 2},
			{"flowers:dandelion_white", 1}, {"flowers:viola", 1},
			{"flowers:mushroom_brown", 1},
		},
		bush = {stem = "default:bush_stem", leaves = "default:bush_leaves",
			chance = 0.01},
	},
	water_ok = true, -- houses may stand in shallow water
	y_min = -2,
	y_max = 4,
	houses = {
		"lakehouse1.mts",
		"lakehouse2.mts",
		"lakehouse3.mts",
		"lakehouse4.mts",
	},
	church = "lakechurch.mts",
	market = "lakemarket.mts",
	stable = "lakestable.mts",
}



