-- job_bum.lua
-- ===================================================================
-- THE VAGRANT - knows where things are, and trades it for a meal
-- ===================================================================
-- He has no workstation and nothing to sell. What he has is knowing the
-- country: feed him and he tells you about somewhere worth going, and
-- marks it on your view.
--
-- Everything he knows already exists. The village placer, the ruins and
-- the sky sites each keep a record of what they have built, for their
-- own /find_ commands. He reads those, skips anything you have already
-- been told about, and picks the nearest thing you have not seen.
--
-- That makes him the one villager who connects the rest of the mod
-- together, which is worth more than any item he could hand over.
-- ===================================================================

local S = minetest.get_translator("lualore")

local bum = lualore.jobs and lualore.jobs.classes and lualore.jobs.classes.bum
if not bum then
	minetest.log("warning", "[lualore] job_bum: no bum class to attach to")
	return
end

local storage = minetest.get_mod_storage()

-- How far out he will talk about, and how near a thing has to be before
-- it is not worth mentioning.
local KNOWS_WITHIN = 2000
local TOO_CLOSE = 60

-- ------------------------------------------------------------------
-- What he knows
-- ------------------------------------------------------------------
-- Every record system in this mod stores {x, y, z, ...} keyed by a
-- position string, in the mod's own storage, so they can all be read
-- the same way.
local function records_from(key)
	local raw = storage:get_string(key)
	if not raw or raw == "" then
		return {}
	end
	local ok, data = pcall(minetest.deserialize, raw)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function gather_secrets()
	local out = {}

	local function collect(records, kind, label, colour)
		for _, rec in pairs(records or {}) do
			if type(rec) == "table" and rec.x and rec.z then
				out[#out + 1] = {
					pos = {x = rec.x, y = rec.y or 0, z = rec.z},
					kind = kind,
					label = label,
					colour = colour,
					detail = rec.kind or rec.theme or rec.palette,
				}
			end
		end
	end

	collect(records_from("ruins"), "ruin", "Ruin", 0xBBAA88)
	collect(records_from("villages"), "village", "Village", 0x88FF88)

	if lualore.floating_buildings and lualore.floating_buildings.records then
		local ok, recs = pcall(lualore.floating_buildings.records)
		if ok then
			collect(recs, "sky", "Sky site", 0x88DDFF)
		end
	end

	return out
end

-- How he describes a direction, because "340 metres bearing 87" is not
-- how a man who sleeps under a hedge talks.
local function compass(from, to)
	local dx, dz = to.x - from.x, to.z - from.z
	local ns = (dz > 0) and "north" or "south"
	local ew = (dx > 0) and "east" or "west"
	if math.abs(dx) > math.abs(dz) * 2 then
		return ew
	end
	if math.abs(dz) > math.abs(dx) * 2 then
		return ns
	end
	return ns .. "-" .. ew
end

local FLAVOUR = {
	ruin = "\"Old stones out @1 of here, half fallen. Nobody's picked them clean.\"",
	village = "\"There's folk living @1 of here. Might be they'd trade.\"",
	sky = "\"Look up, @1 of here. There's houses in the clouds, I swear it.\"",
}

-- ------------------------------------------------------------------
-- Being fed
-- ------------------------------------------------------------------
bum.on_fed = function(self, player)
	if not (lualore.pins and lualore.pins.set) then
		return
	end
	local player_name = player:get_player_name()
	local pos = player:get_pos()

	-- Only one secret per feeding, and not more than a handful at a time
	-- or the screen fills with markers.
	if lualore.pins.count(player_name) >= 3 then
		minetest.chat_send_player(player_name,
			S("The vagrant eats gratefully. \"I've told you all I know for now - go and look.\""))
		return
	end

	local known = lualore.pins.list(player_name)
	local best, best_dist
	for _, secret in ipairs(gather_secrets()) do
		local id = secret.kind .. ":" .. minetest.pos_to_string(secret.pos)
		if not known[id] then
			local dist = vector.distance(pos, secret.pos)
			if dist > TOO_CLOSE and dist <= KNOWS_WITHIN
					and (not best_dist or dist < best_dist) then
				best, best_dist = secret, dist
			end
		end
	end

	if not best then
		minetest.chat_send_player(player_name,
			S("The vagrant eats gratefully. \"Can't think of anywhere worth your trouble hereabouts.\""))
		return
	end

	local id = best.kind .. ":" .. minetest.pos_to_string(best.pos)
	lualore.pins.set(player, id, best.pos, best.label, best.colour)

	local line = FLAVOUR[best.kind] or "\"Something worth seeing @1 of here.\""
	minetest.chat_send_player(player_name,
		S(line, compass(pos, best.pos)))
	minetest.chat_send_player(player_name, minetest.colorize("#FFDD88",
		S("@1 marked, about @2 nodes away.", best.label,
			math.floor(best_dist))))
end

-- ------------------------------------------------------------------
-- Asking him with nothing in hand
-- ------------------------------------------------------------------
bum.on_interact = function(self, player)
	local player_name = player:get_player_name()
	local hungry = (self.nv_hunger or 0) > 50
	if hungry then
		minetest.chat_send_player(player_name,
			S("The vagrant eyes your hands. \"Spare a bite? I've seen things worth telling.\""))
	else
		minetest.chat_send_player(player_name,
			S("The vagrant nods at you. \"Feed me again sometime and I'll tell you where to look.\""))
	end
	return true
end

minetest.log("action", "[lualore] Vagrant job loaded")
