-- aliases.lua
-- ===================================================================
-- VILLAGE PROPS - legacy aliases and the biome marker map
-- ===================================================================
-- This mod grew out of the Native Villages mod, and the .mts schematics
-- still carry that mod's node names. Every village prop baked into a
-- building - the barrels, hookahs, sledges, fish traps and shrines - is
-- stored as `nativevillages:<name>`, while this mod registers them as
-- `lualore:<name>`. With nothing mapping one to the other, every single
-- prop generated as an unknown node, and three things broke with it:
--
--   1. The props did not render at all.
--   2. Biome detection (see the marker map below) looks for props near a
--      bed to decide which biome's villagers to spawn. It never found
--      one, so EVERY village in EVERY biome spawned grassland villagers.
--   3. Anything that wants to use a prop as a workstation had nothing to
--      attach to.
--
-- minetest.register_alias is the right fix rather than re-saving 53
-- schematics: the engine resolves aliases both when place_schematic
-- reads the file AND when an already-generated mapblock is loaded, so
-- existing worlds heal themselves as the player walks around. It is also
-- safe if the original nativevillages mod happens to be installed -
-- Luanti ignores an alias whose name is already a registered item.
--
-- One of these is a rename, not just a namespace swap: the jungle prop
-- was `cannibalshrine` and is now `lualore:jungleshrine`.
-- ===================================================================

lualore = lualore or {}

local PROP_ALIASES = {
	cannibalshrine  = "lualore:jungleshrine",   -- renamed, not just renamespaced
	desertcrpet     = "lualore:desertcrpet",    -- the typo is in the node id itself
	fishtrap        = "lualore:fishtrap",
	grasslandbarrel = "lualore:grasslandbarrel",
	hangingfish     = "lualore:hangingfish",
	hookah          = "lualore:hookah",
	savannavshrine  = "lualore:savannavshrine", -- double v, also in the node id
	sledge          = "lualore:sledge",
}

local alias_count = 0
for old_name, new_name in pairs(PROP_ALIASES) do
	minetest.register_alias("nativevillages:" .. old_name, new_name)
	alias_count = alias_count + 1
end

-- ------------------------------------------------------------------
-- Biome markers
-- ------------------------------------------------------------------
-- Which prop signals which biome's villagers. house_spawning.lua and
-- village_commands.lua both search for these near a bed; they used to
-- carry their own copies of this table, and both copies listed three
-- nodes that do not exist (`grasslandaltar` is registered nowhere,
-- `desertcarpet` and `savannashrine` are misspellings of the real node
-- ids). One table, one place to fix.
--
-- Grassland is still the right default when nothing is found: the only
-- grassland marker is the barrel, which appears solely in the market and
-- the stable, and both of those are rolled per village - so plenty of
-- grassland villages legitimately have no marker at all.
lualore.village_markers = {
	["lualore:grasslandbarrel"] = "grassland",
	["lualore:hookah"]          = "desert",
	["lualore:desertcrpet"]     = "desert",
	["lualore:sledge"]          = "ice",
	["lualore:fishtrap"]        = "lake",
	["lualore:hangingfish"]     = "lake",
	["lualore:savannavshrine"]  = "savanna",
	["lualore:jungleshrine"]    = "jungle",
}

-- Flat list of the same keys, for find_nodes_in_area.
lualore.village_marker_list = {}
for node_name in pairs(lualore.village_markers) do
	lualore.village_marker_list[#lualore.village_marker_list + 1] = node_name
end
table.sort(lualore.village_marker_list) -- stable order, easier to log

minetest.log("action", string.format(
	"[lualore] Village props: %d legacy aliases, %d biome markers",
	alias_count, #lualore.village_marker_list))

-- Decorations a few schematics carry from mods this one does not need. They
-- are listed in optional_depends so that, when installed, they load first
-- and are used; when not, the node quietly becomes air instead of an
-- "unknown node" block in the middle of a church or a castle.
for _, name in ipairs({
	"bottles:bottle_of_crystal_cave_dirt_with_moss",   -- cave castle shelves
	"bottles:bottle_of_mineral_lava_stone_with_moss",
	"bottles:bottle_of_crystal_cave_dirt",
	"butterflies:hidden_butterfly_red",                -- grassland church
	"butterflies:butterfly_white",
	"wielded_light:10",                                -- grassland house 4 (an invisible light)
	"ethereal:illumishroom3",                          -- cave castle
}) do
	if not minetest.registered_items[name] then
		minetest.register_alias(name, "air")
	end
end
