-- village_standing.lua
-- ===================================================================
-- VILLAGE STANDING - how well a village knows you
-- ===================================================================
-- Without this, every villager mechanic is a vending machine: walk up,
-- take the thing, walk away. Standing turns it into a relationship with
-- a particular village - feed its people, trade with them, use what
-- they make, and they give you more of it.
--
-- Deliberately EARN ONLY. There are no penalties for hurting a villager.
-- A player defending themselves near a village, or caught by a stray
-- explosion, should not find a settlement permanently colder to them,
-- and a reputation you can only lose by accident is a tax rather than a
-- mechanic. Hooking losses in later is a two-line change if you want
-- them: call `lualore.standing.earn` with a negative amount.
--
-- Standing is per PLAYER per VILLAGE, keyed by the same string
-- village_placement.lua records villages under, so /find_village and
-- this system always agree about which village you are in.
--
-- Settings: lualore_village_standing (bool, default true)
-- ===================================================================

lualore = lualore or {}
lualore.standing = {}

local S = minetest.get_translator("lualore")
local storage = minetest.get_mod_storage()

local ENABLED = minetest.settings:get_bool("lualore_village_standing", true)

-- How near a village you must be for your deeds to count towards it.
local VILLAGE_RANGE = 80

-- Most you can earn with one village in a single in-game day, so
-- standing is built over time rather than farmed in an afternoon.
local DAILY_CAP = 12

local MAX_STANDING = 100

-- What each kind of deed is worth.
local EARN = {
	feed = 1,      -- fed a hungry villager
	trade = 2,     -- completed a trade
	job = 1,       -- used what a villager makes
	show = 1,      -- watched an entertainer perform
	commission = 2, -- delivered materials for a new house
}

-- ------------------------------------------------------------------
-- Tiers
-- ------------------------------------------------------------------
lualore.standing.tiers = {
	{min = 0,  name = "Stranger", share = 0.4},
	{min = 20, name = "Guest",    share = 0.6},
	{min = 50, name = "Friend",   share = 0.8},
	{min = 80, name = "Kin",      share = 1.0},
}

function lualore.standing.tier(value)
	local tiers = lualore.standing.tiers
	local found = tiers[1]
	for _, tier in ipairs(tiers) do
		if (value or 0) >= tier.min then
			found = tier
		end
	end
	return found
end

-- ------------------------------------------------------------------
-- Storage
-- ------------------------------------------------------------------
-- record[player_name][village_key] = {value, day, today}
local records = {}
local dirty = false

local function load_records()
	local raw = storage:get_string("village_standing")
	if raw and raw ~= "" then
		local ok, data = pcall(minetest.deserialize, raw)
		if ok and type(data) == "table" then
			records = data
		end
	end
end

local function save_records()
	if not dirty then
		return
	end
	dirty = false
	storage:set_string("village_standing", minetest.serialize(records))
end

load_records()

local save_timer = 0
minetest.register_globalstep(function(dtime)
	save_timer = save_timer + dtime
	if save_timer >= 60 then
		save_timer = 0
		save_records()
	end
end)

minetest.register_on_shutdown(save_records)

-- ------------------------------------------------------------------
-- Which village are we talking about?
-- ------------------------------------------------------------------
-- The recorded village key when there is one. Villages built before the
-- record system existed - and hand-built hamlets - fall back to a coarse
-- grid cell, so standing still means something there rather than
-- silently going nowhere.
function lualore.standing.village_at(pos)
	if lualore.villages and lualore.villages.find_near then
		local rec, key = lualore.villages.find_near(pos, VILLAGE_RANGE)
		if key then
			return key, rec
		end
	end
	return string.format("area:%d,%d",
		math.floor(pos.x / 128), math.floor(pos.z / 128)), nil
end

-- ------------------------------------------------------------------
-- Reading and earning
-- ------------------------------------------------------------------
function lualore.standing.get(player_name, pos)
	local key = lualore.standing.village_at(pos)
	local per_player = records[player_name]
	local entry = per_player and per_player[key]
	local value = entry and entry.value or 0
	return value, lualore.standing.tier(value), key
end

-- `who` may be a villager entity or a position.
function lualore.standing.earn(player, who, reason)
	if not ENABLED or not player or not player.get_player_name then
		return
	end
	local amount = EARN[reason]
	if not amount then
		return
	end

	local pos
	if who and who.object and who.object.get_pos then
		pos = who.object:get_pos()
	elseif who and who.x then
		pos = who
	else
		pos = player:get_pos()
	end
	if not pos then
		return
	end

	local player_name = player:get_player_name()
	local key = lualore.standing.village_at(pos)
	records[player_name] = records[player_name] or {}
	local entry = records[player_name][key]
	if not entry then
		entry = {value = 0, day = -1, today = 0}
		records[player_name][key] = entry
	end

	local today = minetest.get_day_count and minetest.get_day_count() or 0
	if entry.day ~= today then
		entry.day = today
		entry.today = 0
	end
	if entry.today >= DAILY_CAP then
		return
	end
	amount = math.min(amount, DAILY_CAP - entry.today)

	local before = lualore.standing.tier(entry.value)
	entry.value = math.min(MAX_STANDING, entry.value + amount)
	entry.today = entry.today + amount
	dirty = true

	local after = lualore.standing.tier(entry.value)
	if after.name ~= before.name then
		minetest.chat_send_player(player_name, minetest.colorize("#FFDD88",
			S("The village now counts you a @1.", after.name)))
		minetest.sound_play("villager_fed",
			{pos = player:get_pos(), gain = 0.5, max_hear_distance = 8}, true)
	end
	return entry.value
end

-- What share of a villager's goods this player has earned, 0..1.
-- Anything that hands over produce should scale by this.
function lualore.standing.share(player, pos)
	if not ENABLED then
		return 1.0
	end
	if not player or not player.get_player_name then
		return lualore.standing.tiers[1].share
	end
	local _, tier = lualore.standing.get(player:get_player_name(),
		pos or player:get_pos())
	return tier.share
end

-- ------------------------------------------------------------------
-- Hooks into the existing interactions
-- ------------------------------------------------------------------
-- Trading: villagers.lua calls this after a successful exchange.
lualore.on_villager_trade = function(self, player, item_name)
	lualore.standing.earn(player, self, "trade")
end

-- Feeding: npcmood.lua's on_feed is the one place every feeding path
-- goes through, so it is wrapped rather than hooked at each call site.
if lualore.mood and lualore.mood.on_feed then
	local plain_on_feed = lualore.mood.on_feed
	lualore.mood.on_feed = function(self, clicker, food_value)
		plain_on_feed(self, clicker, food_value)
		if clicker and clicker.get_player_name then
			lualore.standing.earn(clicker, self, "feed")
		end
	end
else
	minetest.log("warning",
		"[lualore] standing: mood module missing, feeding will not count")
end

-- ------------------------------------------------------------------
-- Command
-- ------------------------------------------------------------------
minetest.register_chatcommand("standing", {
	params = "",
	description = S("How well the village you are in knows you."),
	privs = {},
	func = function(name)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		if not ENABLED then
			return true, S("Village standing is switched off on this server.")
		end

		local pos = player:get_pos()
		local value, tier, key = lualore.standing.get(name, pos)
		local rec = select(2, lualore.standing.village_at(pos))

		local where = rec and string.format("the village at %s",
			minetest.pos_to_string({x = rec.x, y = rec.y or 0, z = rec.z}))
			or "this area"

		-- What is left to reach the next tier?
		local next_tier
		for _, t in ipairs(lualore.standing.tiers) do
			if t.min > value then
				next_tier = t
				break
			end
		end

		local lines = {
			string.format("Standing with %s: %s (%d/%d)",
				where, tier.name, value, MAX_STANDING),
			string.format("They share %d%% of what they make with you.",
				math.floor(tier.share * 100 + 0.5)),
		}
		if next_tier then
			lines[#lines + 1] = string.format("%d more to become %s.",
				next_tier.min - value, next_tier.name)
		else
			lines[#lines + 1] = "They could not think more of you."
		end

		local entry = records[name] and records[name][key]
		local today = minetest.get_day_count and minetest.get_day_count() or 0
		local earned = (entry and entry.day == today) and entry.today or 0
		lines[#lines + 1] = string.format("Earned today: %d of %d.",
			earned, DAILY_CAP)

		return true, table.concat(lines, "\n")
	end,
})

minetest.log("action", "[lualore] Village standing " ..
	(ENABLED and "enabled" or "disabled"))
