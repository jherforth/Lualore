-- job_jeweler.lua
-- ===================================================================
-- THE JEWELER - turns out small valuables at his shelf
-- ===================================================================
-- He works whatever the country around him yields, so what he produces
-- comes from the village's own biome loot table - desert villages deal
-- in gold and glass, jungle ones in emerald and obsidian. Better
-- standing buys a larger share, as with any villager.
-- ===================================================================

local S = minetest.get_translator("lualore")

local jeweler = lualore.jobs and lualore.jobs.classes and lualore.jobs.classes.jeweler
if not jeweler then
	minetest.log("warning", "[lualore] job_jeweler: no jeweler class to attach to")
	return
end

local APPRAISE_EVERY = 25 -- seconds between finished pieces

-- What he makes when there is no biome loot table to draw on.
local FALLBACK = {
	{name = "default:gold_lump", weight = 30, min = 1, max = 1},
	{name = "lualore:pearl", weight = 12, min = 1, max = 1},
	{name = "default:mese_crystal_fragment", weight = 20, min = 1, max = 2},
	{name = "default:diamond", weight = 4, min = 1, max = 1},
}

local function gleam(pos)
	minetest.add_particlespawner({
		amount = 10,
		time = 0.6,
		minpos = {x = pos.x - 0.3, y = pos.y + 0.6, z = pos.z - 0.3},
		maxpos = {x = pos.x + 0.3, y = pos.y + 1.2, z = pos.z + 0.3},
		minvel = {x = -0.1, y = 0.2, z = -0.1},
		maxvel = {x = 0.1, y = 0.6, z = 0.1},
		minacc = {x = 0, y = 0, z = 0},
		maxacc = {x = 0, y = 0, z = 0},
		minexptime = 0.5,
		maxexptime = 1.2,
		minsize = 0.4,
		maxsize = 1.0,
		texture = "lualore_particle_star.png",
		glow = 14,
	})
end

local function fallback_pick()
	local total, available = 0, {}
	for _, entry in ipairs(FALLBACK) do
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
			return {name = entry.name, count = math.random(entry.min, entry.max)}
		end
	end
	return nil
end

jeweler.on_work = function(self, job_def, pos)
	local now = minetest.get_gametime()
	if (self.nv_appraise_at or 0) > now then
		return
	end
	self.nv_appraise_at = now + APPRAISE_EVERY

	gleam(self.nv_work_pos or pos)

	-- The village's own biome table first, so a jeweler deals in what
	-- the country around him actually holds.
	local rolled
	if lualore.loot and lualore.loot.for_pos and lualore.loot.roll then
		local table_for_here = lualore.loot.for_pos(pos)
		if table_for_here then
			local picks = lualore.loot.roll(table_for_here, 1)
			rolled = picks and picks[1]
		end
	end
	rolled = rolled or fallback_pick()
	if rolled then
		lualore.jobs.add_stock(self, rolled.name, rolled.count or 1)
	end
end

jeweler.on_interact = function(self, player)
	return lualore.jobs.share_interact(self, player, {
		empty = S("The jeweler holds up an empty hand. \"Nothing finished. These things take patience.\""),
		already = S("The jeweler smiles thinly. \"You have had a piece from me today.\""),
		gave = function(items) return S("The jeweler parts with @1.", items) end,
		withheld = S("The rest stays in the case - you are not that well known here."),
	})
end

minetest.log("action", "[lualore] Jeweler job loaded")
