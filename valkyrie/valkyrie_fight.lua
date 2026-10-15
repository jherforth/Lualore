--[[
	The valkyrie chest fight.

	Opening a valkyrie chest releases its four valkyries, and defeating all
	four is the only way to free the Sky Folk of that town. That made two
	ways to lose a town for good:

	  * Valkyries are monsters, and mobs_redo deletes any monster that is not
	    mid-attack when its area unloads. Die and respawn somewhere else, or
	    simply leave, and they were gone - with the chest left open.
	  * Any valkyrie that went missing in the middle of the fight left the
	    chest open with nothing left to defeat.

	So each chest's fight is now tracked, and a fight that is abandoned
	starts over:

	  * Opening the chest starts a fight: its four valkyries are tagged with
	    the chest and the fight, and the fight remembers which are left.
	  * Every living valkyrie of the fight reports in from its do_custom.
	  * If no player has been within 64 nodes of the chest for 20 seconds
	    (the opener died and respawned elsewhere, or everyone left), or a
	    valkyrie still to be defeated has not reported in for 12 seconds
	    while players are there (it has gone missing), the fight is called
	    off: the valkyries still loaded are drawn back into the chest, and
	    the chest closes. Open it again to fight again - all four, from the
	    start.
	  * A valkyrie that belonged to a fight that is over removes itself
	    when it next wakes, so a reopened chest never meets stragglers.
	  * When the last of the four falls, the chest stays open for good and
	    the town is freed: every Sky Folk loaded nearby straight away, the
	    rest as they wake (valkyrie/sky_town_folk.lua).

	Chests opened before this was tracked (and left open, their valkyries
	long gone) are closed again when they next load, unless their town is
	already free.
]]

local S = minetest.get_translator("lualore")
local storage = minetest.get_mod_storage()

lualore.valkyrie_fight = {}

local CHEST = "lualore:valkyrie_chest"
local CHEST_OPENED = "lualore:valkyrie_chest_opened"

local FIGHT_RANGE = 64    -- a player this close to the chest is in the fight
local AWAY_GRACE = 20     -- seconds with nobody in range before it is called off
local MISSING_AFTER = 12  -- seconds a valkyrie may go unseen while players are there
local SETTLE = 10         -- ...but not in the first seconds while they spawn
local TICK = 2            -- seconds between checks
local RECALL_RANGE = 128  -- how far a recalled valkyrie may have wandered
local TOWN_REACH = 130    -- Sky Folk freed at once when the fight is won

local fights

local function load()
	local data = storage:get_string("valkyrie_fights")
	local parsed = data ~= "" and minetest.deserialize(data) or nil
	fights = type(parsed) == "table" and parsed or {}
end

local function save()
	storage:set_string("valkyrie_fights", minetest.serialize(fights))
end

load()

local function key_of(pos)
	return minetest.pos_to_string(vector.round(pos))
end

local function chest_pos(fight)
	return {x = fight.x, y = fight.y, z = fight.z}
end

local function players_near(pos, range)
	local out = {}
	for _, player in ipairs(minetest.get_connected_players()) do
		local p = player:get_pos()
		if p and math.abs(p.y - pos.y) <= range
				and math.hypot(p.x - pos.x, p.z - pos.z) <= range then
			out[#out + 1] = player
		end
	end
	return out
end

local function tell_near(pos, msg)
	for _, player in ipairs(players_near(pos, FIGHT_RANGE)) do
		minetest.chat_send_player(player:get_player_name(), msg)
	end
end

-- ------------------------------------------------------------------
-- Starting a fight
-- ------------------------------------------------------------------
-- Called when a closed chest is opened. Returns the fight's id.
function lualore.valkyrie_fight.start(pos, colours, opener)
	local key = key_of(pos)
	local now = os.time()
	local left, seen = {}, {}
	for _, colour in ipairs(colours) do
		left[colour] = true
		seen[colour] = now
	end
	local id = now .. ":" .. math.random(100000, 999999)
	fights[key] = {
		id = id, x = pos.x, y = pos.y, z = pos.z,
		started = now, left = left, seen = seen, away = 0,
		opener = opener,
	}
	save()
	return id
end

-- Mark a freshly spawned valkyrie as one of this chest's fight.
function lualore.valkyrie_fight.tag(ent, pos, id, colour)
	ent.lualore_chest = key_of(pos)
	ent.lualore_fight = id
	ent.lualore_colour = colour
end

-- A valkyrie that never made it out (no room to spawn it) is not one the
-- player has to defeat.
function lualore.valkyrie_fight.drop(pos, colour)
	local fight = fights[key_of(pos)]
	if fight then
		fight.left[colour] = nil
		fight.seen[colour] = nil
		save()
	end
end

function lualore.valkyrie_fight.active(pos)
	return fights[key_of(pos)] ~= nil
end

-- ------------------------------------------------------------------
-- Ending a fight
-- ------------------------------------------------------------------
local function remove_valkyrie(obj)
	local p = obj:get_pos()
	if p then
		-- its wings are an entity of their own
		for _, other in ipairs(minetest.get_objects_inside_radius(p, 4)) do
			local ent = other:get_luaentity()
			if ent and ent.name == "lualore:wing_visual" then
				other:remove()
			end
		end
		minetest.add_particlespawner({
			amount = 24, time = 0.6,
			minpos = vector.subtract(p, {x = 0.4, y = 0, z = 0.4}),
			maxpos = vector.add(p, {x = 0.4, y = 1.8, z = 0.4}),
			minvel = {x = -0.5, y = 0.5, z = -0.5},
			maxvel = {x = 0.5, y = 2, z = 0.5},
			minexptime = 0.4, maxexptime = 1.0,
			minsize = 1, maxsize = 2.5,
			texture = "lualore_particle_star.png", glow = 14,
		})
	end
	obj:remove()
end

local function close_chest(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then
		return false -- not loaded; it closes when it next loads (see the LBM)
	end
	if node.name == CHEST_OPENED then
		minetest.swap_node(pos, {name = CHEST, param2 = node.param2})
	end
	local meta = minetest.get_meta(pos)
	meta:set_int("opened", 0)
	meta:set_int("won", 0)
	return true
end

-- Call a fight off: valkyries back into the chest, chest closed.
local function call_off(key, why)
	local fight = fights[key]
	if not fight then
		return
	end
	local pos = chest_pos(fight)
	fights[key] = nil
	save()

	local recalled = 0
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, RECALL_RANGE)) do
		local ent = obj:get_luaentity()
		if ent and ent.lualore_chest == key then
			remove_valkyrie(obj)
			recalled = recalled + 1
		end
	end
	if lualore.valkyrie_strikes and lualore.valkyrie_strikes.clear_all_player_effects then
		for _, player in ipairs(players_near(pos, FIGHT_RANGE)) do
			lualore.valkyrie_strikes.clear_all_player_effects(player)
		end
	end
	close_chest(pos)

	local msg = S("The valkyries withdraw into their chest, and it snaps shut. " ..
		"Open it again to face all four.")
	tell_near(pos, msg)
	local opener = fight.opener and minetest.get_player_by_name(fight.opener)
	if opener and #players_near(pos, FIGHT_RANGE) == 0 then
		minetest.chat_send_player(fight.opener, msg)
	end
	minetest.log("action", "[lualore] Valkyrie fight at " .. key ..
		" called off (" .. why .. "), " .. recalled .. " valkyries recalled")
end

local function win(key)
	local fight = fights[key]
	local pos = chest_pos(fight)
	fights[key] = nil
	save()

	local node = minetest.get_node_or_nil(pos)
	if node then
		if node.name == CHEST then
			minetest.swap_node(pos, {name = CHEST_OPENED, param2 = node.param2})
		end
		local meta = minetest.get_meta(pos)
		meta:set_int("opened", 1)
		meta:set_int("won", 1)
	end

	-- The town is free: the Sky Folk loaded now at once, the rest as they
	-- wake.
	if lualore.sky_town and lualore.sky_town.mark_freed then
		lualore.sky_town.mark_freed(pos)
	end
	local freed = 0
	if lualore.sky_liberation and lualore.sky_liberation.free then
		for _, obj in ipairs(minetest.get_objects_inside_radius(pos, TOWN_REACH)) do
			local ent = obj:get_luaentity()
			if ent and ent.name == "lualore:sky_folk" and not ent.liberated then
				if lualore.sky_liberation.free(ent) then
					freed = freed + 1
				end
			end
		end
	end
	tell_near(pos, S("All four valkyries are defeated! The Sky Folk are free!"))
	minetest.log("action", "[lualore] Valkyrie fight at " .. key ..
		" won; " .. freed .. " Sky Folk freed at once")
end

-- ------------------------------------------------------------------
-- Hooks for the valkyries (sky_valkyries.lua)
-- ------------------------------------------------------------------
-- From the valkyrie's do_custom. Returns "gone" if it belonged to a fight
-- that is over and has removed itself.
function lualore.valkyrie_fight.heartbeat(self)
	local key = self.lualore_chest
	if not key then
		return nil -- not a chest valkyrie
	end
	local fight = fights[key]
	if not fight or fight.id ~= self.lualore_fight then
		if self.object then
			remove_valkyrie(self.object)
		end
		return "gone"
	end
	if self.lualore_colour then
		fight.seen[self.lualore_colour] = os.time()
	end
	return nil
end

-- From the valkyrie's on_die. Returns true if it was a chest valkyrie, in
-- which case the fight decides what is freed.
function lualore.valkyrie_fight.defeated(self)
	local key = self.lualore_chest
	if not key then
		return false
	end
	local fight = fights[key]
	if not fight or fight.id ~= self.lualore_fight then
		return true -- a straggler from a fight already over: frees nothing
	end
	if self.lualore_colour then
		fight.left[self.lualore_colour] = nil
		fight.seen[self.lualore_colour] = nil
	end
	save()
	if next(fight.left) == nil then
		win(key)
	end
	return true
end

-- ------------------------------------------------------------------
-- Watching for abandoned fights
-- ------------------------------------------------------------------
local function check_fights(step)
	local now = os.time()
	for key, fight in pairs(fights) do
		local pos = chest_pos(fight)
		if #players_near(pos, FIGHT_RANGE) == 0 then
			fight.away = (fight.away or 0) + step
			if fight.away >= AWAY_GRACE then
				call_off(key, "nobody near")
			end
		else
			fight.away = 0
			if now - fight.started >= SETTLE then
				for colour in pairs(fight.left) do
					if now - (fight.seen[colour] or fight.started) > MISSING_AFTER then
						call_off(key, colour .. " valkyrie missing")
						break
					end
				end
			end
		end
	end
end

local clock = 0
minetest.register_globalstep(function(dtime)
	clock = clock + dtime
	if clock < TICK then
		return
	end
	local step = clock
	clock = 0
	check_fights(step)
end)

minetest.register_on_shutdown(save)

-- ------------------------------------------------------------------
-- Chests left open
-- ------------------------------------------------------------------
-- An open chest with no fight going and no victory behind it is closed
-- when it loads: either its fight was called off while it was unloaded,
-- or it was opened before fights were tracked and its valkyries are long
-- gone. A chest whose town is already free keeps its victory.
local function settle_open_chest(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node or node.name ~= CHEST_OPENED then
		return
	end
	local meta = minetest.get_meta(pos)
	if meta:get_int("won") == 1 or fights[key_of(pos)] then
		return
	end
	if lualore.sky_town and lualore.sky_town.freed_at
			and lualore.sky_town.freed_at(pos) then
		meta:set_int("won", 1)
		return
	end
	-- Freed under the old rules, before towns remembered it? Then freed
	-- Sky Folk are standing about.
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, 48)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "lualore:sky_folk" and ent.liberated then
			meta:set_int("won", 1)
			if lualore.sky_town and lualore.sky_town.mark_freed then
				lualore.sky_town.mark_freed(pos)
			end
			return
		end
	end
	close_chest(pos)
	minetest.log("action", "[lualore] Closed a valkyrie chest left open at " ..
		key_of(pos))
end

minetest.register_lbm({
	label = "Close valkyrie chests whose fight was abandoned",
	name = "lualore:reset_abandoned_valkyrie_chests",
	nodenames = {CHEST_OPENED},
	run_at_every_load = true,
	action = function(pos)
		-- give the area's entities a moment to wake before judging
		minetest.after(3, settle_open_chest, vector.new(pos))
	end,
})

lualore.valkyrie_fight.settle_open_chest = settle_open_chest
lualore.valkyrie_fight.fights = function()
	return fights
end
