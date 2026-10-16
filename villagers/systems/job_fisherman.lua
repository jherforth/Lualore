-- job_fisherman.lua
-- ===================================================================
-- THE FISHERMAN - works a trap at the water's edge
-- ===================================================================
-- His trap has to be near open water to be worth anything. He tends it
-- through the day and the catch builds up; ask him and he shares it.
--
-- The catch is mostly catfish, with the occasional pearl - an item this
-- mod has always registered and never once used.
-- ===================================================================

local S = minetest.get_translator("lualore")

local fisher = lualore.jobs and lualore.jobs.classes and lualore.jobs.classes.fisherman
if not fisher then
	minetest.log("warning", "[lualore] job_fisherman: no fisherman class to attach to")
	return
end

-- How far from the trap water may be, and how much of it he wants.
local WATER_RANGE = 6
local WATER_NEEDED = 4

local CATCH_EVERY = 12 -- seconds between hauls
local CATCH = {
	{name = "lualore:catfish_raw", weight = 60, min = 1, max = 2},
	{name = "farming:string", weight = 15, min = 1, max = 1},
	{name = "lualore:pearl", weight = 6, min = 1, max = 1},
	{name = "default:clay_lump", weight = 12, min = 1, max = 2},
}

local function pick_catch()
	local total, available = 0, {}
	for _, entry in ipairs(CATCH) do
		if minetest.registered_items[entry.name] then
			available[#available + 1] = entry
			total = total + entry.weight
		end
	end
	if total == 0 then
		return nil
	end
	local roll, acc = math.random(total), 0
	for _, entry in ipairs(available) do
		acc = acc + entry.weight
		if roll <= acc then
			return entry
		end
	end
	return available[#available]
end

-- Cached per trap position: checking for water is a node search, and the
-- shoreline does not move.
local water_at = {}

local function has_water(pos)
	local key = minetest.pos_to_string(pos)
	local known = water_at[key]
	if known ~= nil then
		return known
	end
	local found = minetest.find_nodes_in_area(
		{x = pos.x - WATER_RANGE, y = pos.y - 3, z = pos.z - WATER_RANGE},
		{x = pos.x + WATER_RANGE, y = pos.y + 2, z = pos.z + WATER_RANGE},
		{"group:water"})
	local ok = #found >= WATER_NEEDED
	water_at[key] = ok
	if not ok then
		minetest.log("info", "[lualore] fisherman: trap at " .. key ..
			" has no water near it")
	end
	return ok
end

local function ripples(pos)
	minetest.add_particlespawner({
		amount = 8,
		time = 0.5,
		minpos = {x = pos.x - 0.4, y = pos.y + 0.2, z = pos.z - 0.4},
		maxpos = {x = pos.x + 0.4, y = pos.y + 0.6, z = pos.z + 0.4},
		minvel = {x = -0.3, y = 0.5, z = -0.3},
		maxvel = {x = 0.3, y = 1.2, z = 0.3},
		minacc = {x = 0, y = -3, z = 0},
		maxacc = {x = 0, y = -3, z = 0},
		minexptime = 0.3,
		maxexptime = 0.8,
		minsize = 0.5,
		maxsize = 1.2,
		texture = "default_water.png^[opacity:140",
	})
end

fisher.on_work = function(self, job_def, pos)
	local trap = self.nv_work_pos
	if not trap or not has_water(trap) then
		return
	end

	local now = minetest.get_gametime()
	if (self.nv_catch_at or 0) > now then
		return
	end
	self.nv_catch_at = now + CATCH_EVERY

	local entry = pick_catch()
	if entry then
		lualore.jobs.add_stock(self, entry.name, math.random(entry.min, entry.max))
		ripples(trap)
		minetest.sound_play("default_water_footstep",
			{pos = trap, gain = 0.3, max_hear_distance = 10}, true)
	end
end

fisher.on_interact = function(self, player)
	return lualore.jobs.share_interact(self, player, {
		empty = S("The fisherman shrugs at his empty trap. \"Nothing's run into it yet.\""),
		already = S("The fisherman shakes his head. \"You've had today's catch.\""),
		gave = function(items) return S("The fisherman hands you @1.", items) end,
		withheld = S("He keeps the rest for the village pot."),
	})
end

minetest.log("action", "[lualore] Fisherman job loaded")
