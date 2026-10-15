-- init.lua
-- lualore — Final perfected version

lualore = {}

local modname = minetest.get_current_modname()
local modpath = minetest.get_modpath(modname)

-- Internationalization
local S
if minetest.get_translator then
    S = minetest.get_translator("lualore")
else
    S = dofile(modpath .. "/intllib.lua")
end
mobs.intllib = S

-- Global serialization safety net (keeps your world from corrupting on rare bugs)
local original_serialize = minetest.serialize
minetest.serialize = function(data)
    local success, result = pcall(original_serialize, data)
    if success then
        return result
    else
        minetest.log("error", "[lualore] Serialization failed: " .. result)
        return original_serialize({})
    end
end

-- Check for custom spawn file
local spawn_file = io.open(modpath .. "/spawn.lua", "r")
if spawn_file then
    mobs.custom_spawn_lualore = true
    spawn_file:close()
end

-- ===================================================================
-- LOAD ORDER (critical for dependencies and noise sharing)
-- ===================================================================

-- 1. Nodes & blocks (must come first)
--    aliases.lua first: it maps the legacy nativevillages: names baked
--    into the schematics onto this mod's nodes, and owns the one shared
--    biome-marker table that house_spawning and village_commands read.
dofile(modpath .. "/villagers/blocks/aliases.lua")
dofile(modpath .. "/villagers/blocks/workstations.lua")
dofile(modpath .. "/villagers/blocks/jungleblocks.lua")
dofile(modpath .. "/villagers/blocks/savannablocks.lua")
dofile(modpath .. "/villagers/blocks/arcticblocks.lua")
dofile(modpath .. "/villagers/blocks/grasslandblocks.lua")
dofile(modpath .. "/villagers/blocks/lakeblocks.lua")
dofile(modpath .. "/villagers/blocks/desertblocks.lua")

-- 2. Legacy village noise (kept for compatibility; village placement is
--    now deterministic - see village_placement.lua)
dofile(modpath .. "/villagers/systems/village_noise.lua")

-- 3. Buildings (village palettes, consumed by village_placement.lua)
dofile(modpath .. "/villagers/buildings/junglebuildings.lua")
dofile(modpath .. "/villagers/buildings/icebuildings.lua")
dofile(modpath .. "/villagers/buildings/grasslandbuildings.lua")
dofile(modpath .. "/villagers/buildings/lakebuildings.lua")
dofile(modpath .. "/villagers/buildings/desertbuildings.lua")
dofile(modpath .. "/villagers/buildings/savannabuildings.lua")
dofile(modpath .. "/wizards/cavebuildings.lua")

-- 3b. Village ground dressing (organic outlines, texture, vegetation)
dofile(modpath .. "/villagers/systems/village_ground.lua")

-- 3c. Deterministic village placement (grid + planned layouts)
dofile(modpath .. "/villagers/systems/village_workstations.lua")
dofile(modpath .. "/villagers/systems/village_placement.lua")

-- 4. Systems (villagers, mood, spawning)
dofile(modpath .. "/villagers/systems/npcmood.lua")
dofile(modpath .. "/villagers/systems/villager_behaviors.lua")
dofile(modpath .. "/villagers/systems/villager_pins.lua")
dofile(modpath .. "/villagers/systems/villager_path.lua")
dofile(modpath .. "/villagers/systems/villager_jobs.lua")
dofile(modpath .. "/villagers/systems/villager_trade.lua")
--    One file per trade, each filling in its own entry in
--    lualore.jobs.classes. A class with no file here simply has no
--    mechanic and still walks to its workstation.
dofile(modpath .. "/villagers/systems/job_farmer.lua")
dofile(modpath .. "/villagers/systems/job_blacksmith.lua")
dofile(modpath .. "/villagers/systems/job_cleric.lua")
dofile(modpath .. "/villagers/systems/job_fisherman.lua")
dofile(modpath .. "/villagers/systems/job_jeweler.lua")
dofile(modpath .. "/villagers/systems/job_entertainer.lua")
dofile(modpath .. "/villagers/systems/job_bum.lua")
dofile(modpath .. "/villagers/systems/job_ranger.lua")
dofile(modpath .. "/villagers/systems/smart_doors.lua")
dofile(modpath .. "/villagers/systems/witch_magic.lua")
dofile(modpath .. "/wizards/wizard_magic.lua")
dofile(modpath .. "/wizards/wizard_wands.lua")
dofile(modpath .. "/villagers/systems/villagers.lua")
dofile(modpath .. "/villagers/systems/house_spawning.lua")
dofile(modpath .. "/villagers/systems/village_standing.lua")
dofile(modpath .. "/villagers/systems/village_commands.lua")
dofile(modpath .. "/wizards/cave_wizards.lua")

-- 4b. Abandoned villages around cave castles (sculpts the cave ground)
dofile(modpath .. "/wizards/castle_village.lua")

-- 5. Cave dwellers
dofile(modpath .. "/caves/lit.lua")

-- 6. Optional/fun extras
dofile(modpath .. "/villagers/extras/explodingtoad.lua")
dofile(modpath .. "/villagers/extras/loot.lua")

-- 6b. Procedural ruins (broken castles, towers, walls, stone circles)
dofile(modpath .. "/ruins/ruins.lua")

-- 7. Valkyrie and Sky Folk systems
dofile(modpath .. "/valkyrie/valkyrie_strikes.lua")
dofile(modpath .. "/valkyrie/sky_folk_pins.lua")
dofile(modpath .. "/valkyrie/sky_folk_tracker.lua")
dofile(modpath .. "/valkyrie/sky_folk_quests.lua")
dofile(modpath .. "/valkyrie/sky_folk_mood.lua")
dofile(modpath .. "/valkyrie/sky_folk_compass.lua")
dofile(modpath .. "/valkyrie/sky_liberation.lua")
dofile(modpath .. "/valkyrie/sky_blocks.lua")
dofile(modpath .. "/valkyrie/sky_valkyries.lua")
dofile(modpath .. "/valkyrie/valkyrie_fight.lua")
dofile(modpath .. "/valkyrie/valkyrie_chest.lua")
dofile(modpath .. "/valkyrie/sky_folk_footing.lua")
dofile(modpath .. "/valkyrie/sky_town_folk.lua")
dofile(modpath .. "/valkyrie/sky_folk.lua")
dofile(modpath .. "/valkyrie/sky_villages.lua")
dofile(modpath .. "/valkyrie/floating_buildings.lua")
dofile(modpath .. "/valkyrie/mirror_sentinel.lua")

-- 7b. Sky portals (mese frames lit with an iron ingot; lead to the sky
--     islands and back). legacy_doors rescues players left on the old
--     obsidian door mirror islands.
dofile(modpath .. "/portal/sky_portal.lua")
dofile(modpath .. "/portal/legacy_doors.lua")

-- 8. Custom mob spawning (if exists)
if mobs.custom_spawn_lualore then
    dofile(modpath .. "/spawn.lua")
end

-- ===================================================================
-- Final message
-- ===================================================================

minetest.log("action", "[lualore] Successfully loaded — " ..
    "6 biomes | perfect villages | villagers | cave wizards | cave lits | procedural ruins | sky portals | sky valkyries | sky folk | exploding toads")
print(S("[MOD] lualore loaded — a living world awaits you"))
