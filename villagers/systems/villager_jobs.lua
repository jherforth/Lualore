-- villager_jobs.lua
-- ===================================================================
-- VILLAGER JOBS - class identity, workstations and the working day
-- ===================================================================
-- Villagers had mood, feeding, trading and socialising, but no purpose:
-- they wandered, chatted and slept. This module gives each class a
-- workstation to claim and a place in the day's rhythm, so a village
-- reads as a working settlement rather than a set of idle mobs.
--
-- What lives here:
--   * CLASS IDENTITY. There was no `self.nv_class` anywhere - the class
--     was re-derived by matching on the entity name every time anything
--     needed it. `get_class` is now the single accessor.
--   * WORKSTATIONS. Each class has a list of nodes it can work at. A
--     villager claims the nearest free one to its bed and keeps it;
--     claims live in mod storage keyed by BED position, because beds
--     survive an unload and entity ids do not.
--   * THE SCHEDULE. `pick_state` weights working / socialising /
--     wandering by time of day. It is weighted rather than scripted so
--     a village does not look clockwork.
--
-- What does NOT live here: going home at dusk and sleeping. That is
-- villager_behaviors.lua's `is_home_time` path, which runs before the
-- state machine is reached, so the bed routine always wins over work.
--
-- Settings:
--   lualore_villager_jobs (bool, default true) - off restores exactly
--   the old two-state day, since `pick_state` then returns nil and the
--   behaviour module falls back to its original cycle.
-- ===================================================================

lualore = lualore or {}
lualore.jobs = {}

local storage = minetest.get_mod_storage()
local S = minetest.get_translator("lualore")

local ENABLED = minetest.settings:get_bool("lualore_villager_jobs", true)

-- How often a working villager's job tick runs. Everything expensive in
-- this module sits behind it; do_custom itself runs every server step.
local JOB_TICK = 2.0

-- A station must be within this of the villager's bed. This is not just
-- taste: check_stuck_and_recover (villager_behaviors.lua) teleports a
-- villager home once it is further than about 45 nodes away, so a
-- station inside 20 can never trigger it.
local STATION_RADIUS = 20
local STATION_Y = 8

-- Seconds before a villager that found nothing looks again.
local NO_STATION_RETRY = 300

-- Don't run job logic for villagers nobody can see.
local ACTIVE_RANGE = 40

-- ------------------------------------------------------------------
-- Class table
-- ------------------------------------------------------------------
-- `stations` is in priority order; the first node type with a free
-- instance near the bed wins. Names that no mod registered are dropped
-- at first use, so listing a node that only exists once Phase 2 lands
-- (the anvil, altar and field stake) is safe.
--
-- Classes absent from this table have no job at all and their tick is
-- untouched: witch (her whole tick belongs to witch_magic.lua), plus
-- hostile and raider, which are not villagers.
lualore.jobs.classes = {
	farmer = {
		stations = {"lualore:field_stake"},
		title = "Farmer",
	},
	blacksmith = {
		stations = {"lualore:anvil", "default:furnace"},
		title = "Blacksmith",
	},
	cleric = {
		stations = {"lualore:village_altar", "default:bookshelf"},
		title = "Cleric",
	},
	fisherman = {
		stations = {"lualore:fishtrap", "lualore:hangingfish"},
		title = "Fisherman",
	},
	jeweler = {
		stations = {"vessels:shelf", "lualore:grasslandbarrel"},
		title = "Jeweler",
	},
	entertainer = {
		stations = {
			"lualore:hookah", "lualore:sledge", "lualore:jungleshrine",
			"lualore:savannavshrine", "lualore:desertcrpet",
		},
		title = "Entertainer",
	},
	-- No station: these two work by walking, and arrive in a later phase.
	bum = {stations = {}, title = "Vagrant"},
	ranger = {stations = {}, title = "Ranger"},
}

-- Filter each station list against the node registry once, on first use.
local station_cache = {}

local function stations_for(class)
	local cached = station_cache[class]
	if cached then
		return cached
	end
	local def = lualore.jobs.classes[class]
	local list = {}
	if def then
		for _, name in ipairs(def.stations) do
			if minetest.registered_nodes[name] then
				list[#list + 1] = name
			elseif name:find("lualore:", 1, true) == 1 then
				-- ours and missing means a later phase has not landed yet
				minetest.log("info", "[lualore] jobs: " .. class ..
					" station " .. name .. " not registered yet")
			else
				minetest.log("action", "[lualore] jobs: " .. class ..
					" station " .. name .. " is not available in this game")
			end
		end
	end
	station_cache[class] = list
	return list
end

-- ------------------------------------------------------------------
-- Class identity
-- ------------------------------------------------------------------
-- Mobs are registered as lualore:<biome>_<class>, so the class is the
-- last underscore-separated segment. villagers.lua now stamps nv_class
-- on activation; the match is the fallback for anything that predates
-- that, and the result is cached either way.
function lualore.jobs.get_class(self)
	if self.nv_class then
		return self.nv_class
	end
	local name = self.name
	if type(name) ~= "string" then
		return nil
	end
	self.nv_class = name:match("_([^_]+)$")
	return self.nv_class
end

-- The trade item list for a class. villagers.lua owns the class table
-- and exports it; npcmood.lua used to keep a second, already-diverged
-- copy of this data.
function lualore.jobs.trade_items_for(class)
	local classes = lualore.villager_classes
	local def = classes and classes[class]
	if def and def.trade_items and #def.trade_items > 0 then
		return def.trade_items
	end
	return nil
end

-- ------------------------------------------------------------------
-- Station claims
-- ------------------------------------------------------------------
-- Authoritative store: mod storage key "job_stations", a map of
-- position string -> {class, bed, at}. `by_bed` is a derived index so a
-- villager coming back from an unload can re-adopt the station its bed
-- already owns.
local claims = {}
local by_bed = {}
local claims_dirty = false

local function pos_key(pos)
	return minetest.pos_to_string(vector.round(pos))
end

local function reindex()
	by_bed = {}
	for key, rec in pairs(claims) do
		if rec.bed then
			by_bed[rec.bed] = key
		end
	end
end

local function load_claims()
	local raw = storage:get_string("job_stations")
	if raw and raw ~= "" then
		local ok, data = pcall(minetest.deserialize, raw)
		if ok and type(data) == "table" then
			claims = data
		end
	end
	reindex()
end

local function save_claims()
	if not claims_dirty then
		return
	end
	claims_dirty = false
	storage:set_string("job_stations", minetest.serialize(claims))
end

load_claims()

local save_timer = 0
minetest.register_globalstep(function(dtime)
	save_timer = save_timer + dtime
	if save_timer >= 60 then
		save_timer = 0
		save_claims()
	end
end)

-- A crash between flushes used to lose up to a minute of claims.
minetest.register_on_shutdown(save_claims)

local function bed_key(self)
	local bed = self.nv_house_pos
	return bed and pos_key(bed) or nil
end

-- Is this node still a workstation this class can use?
local function station_valid(pos, class)
	local name = minetest.get_node(pos).name
	if name == "ignore" then
		return true -- unloaded, assume it is still there
	end
	for _, want in ipairs(stations_for(class)) do
		if name == want then
			return true
		end
	end
	return false
end

local function release_claim(key)
	local rec = claims[key]
	if not rec then
		return
	end
	claims[key] = nil
	if rec.bed and by_bed[rec.bed] == key then
		by_bed[rec.bed] = nil
	end
	claims_dirty = true
	local pos = minetest.string_to_pos(key)
	if pos and minetest.get_node(pos).name ~= "ignore" then
		local meta = minetest.get_meta(pos)
		if meta:get_string("lualore_station") ~= "" then
			meta:set_string("lualore_station", "")
			meta:set_string("infotext", "")
		end
	end
end

function lualore.jobs.release_station(self)
	-- Release the station this villager actually holds. Looking it up by
	-- bed alone is wrong when the bed index is stale or shared - it would
	-- happily free somebody else's workplace.
	if self.nv_work_pos then
		release_claim(pos_key(self.nv_work_pos))
		self.nv_work_pos = nil
		return
	end
	local bed = bed_key(self)
	local key = bed and by_bed[bed]
	if key then
		release_claim(key)
	end
end

local function claim_station(self, pos, class)
	local key = pos_key(pos)
	local bed = bed_key(self)
	claims[key] = {class = class, bed = bed, at = minetest.get_gametime()}
	if bed then
		by_bed[bed] = key
	end
	claims_dirty = true

	local meta = minetest.get_meta(pos)
	meta:set_string("lualore_station", class)
	local def = lualore.jobs.classes[class]
	meta:set_string("infotext", (def and def.title or class) .. "'s workplace")

	self.nv_work_pos = vector.round(pos)
	self.nv_no_station_until = nil
	return self.nv_work_pos
end

-- Find and claim a workstation, or return nil. Only ever called on a
-- state transition, never on a tick - find_nodes_in_area is not cheap.
local function search_station(self, class)
	local bed = self.nv_house_pos
	if not bed then
		return nil
	end
	local wanted = stations_for(class)
	if #wanted == 0 then
		return nil
	end

	local minp = {x = bed.x - STATION_RADIUS, y = bed.y - STATION_Y,
		z = bed.z - STATION_RADIUS}
	local maxp = {x = bed.x + STATION_RADIUS, y = bed.y + STATION_Y,
		z = bed.z + STATION_RADIUS}
	local found = minetest.find_nodes_in_area(minp, maxp, wanted)

	-- Nearest to the bed that nobody else has taken.
	local best, best_dist
	local mine = bed_key(self)
	for _, pos in ipairs(found) do
		local key = pos_key(pos)
		local held = claims[key]
		if not held or held.bed == mine then
			local dist = vector.distance(bed, pos)
			if not best_dist or dist < best_dist then
				best, best_dist = pos, dist
			end
		end
	end

	if not best then
		self.nv_no_station_until = minetest.get_gametime() + NO_STATION_RETRY
		return nil
	end
	return claim_station(self, best, class)
end

-- The station this villager should walk to, claiming one if needed.
function lualore.jobs.ensure_station(self)
	if not ENABLED then
		return nil
	end
	local class = lualore.jobs.get_class(self)
	if not class or not lualore.jobs.classes[class] then
		return nil
	end

	-- Already have one, and it is still a workstation.
	if self.nv_work_pos then
		if station_valid(self.nv_work_pos, class) then
			return self.nv_work_pos
		end
		lualore.jobs.release_station(self)
	end

	-- Our bed may already own one from a previous session.
	local bed = bed_key(self)
	local key = bed and by_bed[bed]
	if key then
		local pos = minetest.string_to_pos(key)
		if pos and station_valid(pos, class) then
			self.nv_work_pos = pos
			return pos
		end
		release_claim(key)
	end

	-- Classes that work by walking rather than at a node - the ranger on
	-- his round - take their own doorstep as the anchor. Nothing is
	-- claimed; the job moves nv_work_spot about from there.
	local def = lualore.jobs.classes[class]
	if def and def.patrol and #stations_for(class) == 0 then
		self.nv_work_pos = self.nv_house_pos
		return self.nv_work_pos
	end

	local until_time = self.nv_no_station_until
	if until_time and minetest.get_gametime() < until_time then
		return nil
	end

	return search_station(self, class)
end

-- The nearest villager of a given class to a position. Node-side
-- interactions use it: an anvil is only a forge while a smith is at it.
function lualore.jobs.villager_near(pos, class, radius)
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, radius or 6)) do
		local ent = obj:get_luaentity()
		if ent and ent.name and ent.name:find("lualore:", 1, true) == 1 then
			if lualore.jobs.get_class(ent) == class then
				return ent
			end
		end
	end
	return nil
end

function lualore.jobs.has_station(self)
	return self.nv_work_pos ~= nil
end

-- ------------------------------------------------------------------
-- The working day
-- ------------------------------------------------------------------
-- Weights per time period, read by pick_state. Dusk onwards is handled
-- entirely by the behaviour module's go-home path, which runs before
-- the state machine, so there is no "night" row here.
local SCHEDULE = {
	morning   = {working = 70, socializing = 10, wandering = 20},
	afternoon = {working = 55, socializing = 20, wandering = 25},
	evening   = {working = 15, socializing = 50, wandering = 35},
	night     = {working = 0,  socializing = 30, wandering = 70},
}

-- Returns the next behaviour state, or nil to let the behaviour module
-- use its own cycle (jobs disabled, or this class has no job).
function lualore.jobs.pick_state(self, current)
	if not ENABLED then
		return nil
	end
	local states = lualore.behaviors and lualore.behaviors.states
	if not states then
		return nil
	end
	local class = lualore.jobs.get_class(self)
	if not class or not lualore.jobs.classes[class] then
		return nil
	end

	local period = lualore.behaviors.get_time_period()
	local weights = SCHEDULE[period] or SCHEDULE.afternoon

	-- Only offer work if there is somewhere to do it. This is the one
	-- place a station search can happen, and state changes are minutes
	-- apart, so the cost is negligible.
	local work_weight = weights.working
	if work_weight > 0 and not lualore.jobs.ensure_station(self) then
		work_weight = 0
	end

	local total = work_weight + weights.socializing + weights.wandering
	if total <= 0 then
		return states.WANDERING
	end
	local roll = math.random(total)
	if roll <= work_weight then
		return states.WORKING
	end
	if roll <= work_weight + weights.socializing then
		return states.SOCIALIZING
	end
	return states.WANDERING
end

-- ------------------------------------------------------------------
-- Job tick
-- ------------------------------------------------------------------
-- One shared list of player positions, refreshed by a single
-- globalstep, so forty villagers do not each ask the engine who is
-- online.
local player_positions = {}
local player_timer = 0

minetest.register_globalstep(function(dtime)
	player_timer = player_timer + dtime
	if player_timer < 2 then
		return
	end
	player_timer = 0
	player_positions = {}
	for _, player in ipairs(minetest.get_connected_players()) do
		local pos = player:get_pos()
		if pos then
			player_positions[#player_positions + 1] = pos
		end
	end
end)

local function anyone_near(pos, radius)
	for _, ppos in ipairs(player_positions) do
		if vector.distance(pos, ppos) <= radius then
			return true
		end
	end
	return false
end

function lualore.jobs.init(self)
	if self.nv_stock == nil then
		self.nv_stock = {}
	end
	if self.nv_job_timer == nil then
		-- Stagger the phase so a village does not tick as one block.
		self.nv_job_timer = -math.random() * JOB_TICK
	end
end

function lualore.jobs.update(self, dtime, job_def)
	if not ENABLED or not self.object then
		return
	end
	lualore.jobs.init(self)

	self.nv_job_timer = self.nv_job_timer + dtime
	if self.nv_job_timer < JOB_TICK then
		return
	end
	self.nv_job_timer = 0

	-- Tell the behaviour module how close this job needs to get.
	self.nv_work_reach = job_def and job_def.work_reach or nil

	if not self.nv_at_station then
		return
	end
	local pos = self.object:get_pos()
	if not pos or not anyone_near(pos, ACTIVE_RANGE) then
		return
	end

	-- Look busy: a short swing every couple of seconds. mobs_redo resets
	-- the animation to stand on its next step, which is exactly the
	-- flicker of a work motion.
	if self.state == "stand" and self.set_animation then
		self:set_animation("punch")
	end

	if job_def and job_def.on_work then
		job_def.on_work(self, job_def, pos)
	end
end

-- ------------------------------------------------------------------
-- Player inventory
-- ------------------------------------------------------------------
-- Counting, taking and giving. Small, but it had already been written
-- twice (the smith's repairs and the quest system) with a third copy
-- about to appear for trading, so it lives in one place.
lualore.inv = {}

function lualore.inv.count(player, item_name)
	local inv = player and player:get_inventory()
	if not inv then
		return 0
	end
	local total = 0
	for _, stack in ipairs(inv:get_list("main") or {}) do
		if stack:get_name() == item_name then
			total = total + stack:get_count()
		end
	end
	return total
end

-- Takes only if the whole amount is there, so a half-paid trade is not
-- possible.
function lualore.inv.take(player, item_name, count)
	if lualore.inv.count(player, item_name) < count then
		return false
	end
	local inv = player:get_inventory()
	local remaining = count
	for i, stack in ipairs(inv:get_list("main") or {}) do
		if remaining <= 0 then
			break
		end
		if stack:get_name() == item_name then
			local take = math.min(stack:get_count(), remaining)
			stack:set_count(stack:get_count() - take)
			inv:set_stack("main", i, stack)
			remaining = remaining - take
		end
	end
	return true
end

-- Into the inventory where it fits, at the player's feet where it does
-- not, so a full pack never silently eats a reward.
function lualore.inv.give(player, item_name, count)
	local stack = ItemStack(item_name .. " " .. count)
	local inv = player:get_inventory()
	local leftover = inv and inv:add_item("main", stack) or stack
	if leftover and not leftover:is_empty() then
		minetest.add_item(player:get_pos(), leftover)
	end
end

function lualore.inv.display_name(item_name)
	local def = minetest.registered_items[item_name]
	if def and def.description and def.description ~= "" then
		return def.description:match("^([^\n]+)") or def.description
	end
	return (item_name:match(":(.+)$") or item_name):gsub("_", " ")
end

-- ------------------------------------------------------------------
-- Stock: what a villager has made and not yet given away
-- ------------------------------------------------------------------
-- Never put job output in self.drops. That table is the death loot AND
-- the trade reward, and it lives on the mob prototype shared by every
-- villager of the class.
local STOCK_STACK_CAP = 99
local STOCK_KIND_CAP = 8

function lualore.jobs.add_stock(self, item_name, count)
	if not item_name or count == nil or count <= 0 then
		return
	end
	self.nv_stock = self.nv_stock or {}
	local held = self.nv_stock[item_name]
	if not held then
		local kinds = 0
		for _ in pairs(self.nv_stock) do
			kinds = kinds + 1
		end
		if kinds >= STOCK_KIND_CAP then
			return -- already carrying as much variety as it can
		end
		held = 0
	end
	self.nv_stock[item_name] = math.min(held + count, STOCK_STACK_CAP)
end

function lualore.jobs.stock_count(self)
	local total = 0
	for _, count in pairs(self.nv_stock or {}) do
		total = total + count
	end
	return total
end

-- Hand the stock over, into the inventory where it fits and at the
-- player's feet where it does not. `share` is the fraction the player
-- has earned (see village_standing.lua); the rest stays in the basket
-- rather than vanishing, so it is there next time.
function lualore.jobs.give_stock(self, player, share)
	local stock = self.nv_stock
	if not stock then
		return {}
	end
	share = math.max(0, math.min(1, share or 1))
	local inv = player:get_inventory()
	local pos = player:get_pos()
	local given = {}
	for name, count in pairs(stock) do
		if count > 0 and minetest.registered_items[name] then
			-- always at least one of anything held, or a Stranger with a
			-- single item would be given nothing at all
			local hand_over = math.max(1, math.floor(count * share))
			hand_over = math.min(hand_over, count)
			local stack = ItemStack(name .. " " .. hand_over)
			local leftover = inv and inv:add_item("main", stack) or stack
			if leftover and not leftover:is_empty() then
				minetest.add_item(pos, leftover)
			end
			given[#given + 1] = {name = name, count = hand_over}
			local kept = count - hand_over
			stock[name] = (kept > 0) and kept or nil
		end
	end
	return given
end

-- One gift per villager per in-game day.
function lualore.jobs.can_share(self)
	local today = minetest.get_day_count and minetest.get_day_count() or 0
	return (self.nv_last_share_day or -1) ~= today
end

function lualore.jobs.mark_shared(self)
	self.nv_last_share_day = minetest.get_day_count
		and minetest.get_day_count() or 0
end

-- The interaction most working villagers share: ask, and they hand over
-- a share of what they have made. `lines` carries the class's own
-- flavour, so a fisherman does not talk like a smith.
function lualore.jobs.share_interact(self, player, lines)
	local player_name = player:get_player_name()

	if lualore.jobs.stock_count(self) <= 0 then
		minetest.chat_send_player(player_name, lines.empty)
		return true
	end
	if not lualore.jobs.can_share(self) then
		minetest.chat_send_player(player_name, lines.already)
		return true
	end

	local share = (lualore.standing and lualore.standing.share)
		and lualore.standing.share(player, self.object:get_pos()) or 1
	local given = lualore.jobs.give_stock(self, player, share)
	lualore.jobs.mark_shared(self)

	local parts = {}
	for _, entry in ipairs(given) do
		local def = minetest.registered_items[entry.name]
		local label = def and def.description
			and def.description:match("^([^\n]+)") or entry.name
		parts[#parts + 1] = entry.count .. " " .. label
	end
	if #parts == 0 then
		minetest.chat_send_player(player_name, lines.empty)
		return true
	end

	-- `gave` takes the list and translates with it: a template translated
	-- with its @1 still empty is an error in current Luanti, not a warning.
	minetest.chat_send_player(player_name, lines.gave(table.concat(parts, ", ")))
	if lines.withheld and share < 1 and lualore.jobs.stock_count(self) > 0 then
		minetest.chat_send_player(player_name, lines.withheld)
	end

	if lualore.mood and lualore.mood.on_interact then
		lualore.mood.on_interact(self, player)
	end
	if lualore.standing and lualore.standing.earn then
		lualore.standing.earn(player, self, "job")
	end
	return true
end

-- ------------------------------------------------------------------
-- Player interaction, dispatched to the class
-- ------------------------------------------------------------------
-- Called from villagers.lua when a player right-clicks a villager with
-- an empty hand. Returns true when the class handled it.
function lualore.jobs.on_interact(self, player)
	if not ENABLED or not player then
		return false
	end
	local class = lualore.jobs.get_class(self)
	local def = class and lualore.jobs.classes[class]
	if def and def.on_interact then
		return def.on_interact(self, player) == true
	end
	return false
end

-- Being fed. Wraps the mood module's on_feed, which is the one place
-- every feeding path already goes through. village_standing.lua wraps
-- the same function for its own purposes; the wrappers compose, each
-- calling the one it replaced.
function lualore.jobs.on_fed(self, player)
	if not ENABLED or not player then
		return
	end
	local class = lualore.jobs.get_class(self)
	local def = class and lualore.jobs.classes[class]
	if def and def.on_fed then
		def.on_fed(self, player)
	end
end

if lualore.mood and lualore.mood.on_feed then
	local plain_on_feed = lualore.mood.on_feed
	lualore.mood.on_feed = function(self, clicker, food_value)
		plain_on_feed(self, clicker, food_value)
		if clicker and clicker.get_player_name then
			lualore.jobs.on_fed(self, clicker)
		end
	end
end

-- ------------------------------------------------------------------
-- Persistence
-- ------------------------------------------------------------------
-- Plain data only. villagers.lua's get_staticdata returns "" if
-- serialisation throws, and an empty staticdata silently costs the
-- villager its bed and its mood - so nothing but strings, numbers and
-- {x,y,z} tables may go in here.
function lualore.jobs.get_save_data(self)
	return {
		nv_class = self.nv_class,
		nv_work_pos = self.nv_work_pos,
		nv_stock = self.nv_stock,
		nv_no_station_until = self.nv_no_station_until,
		nv_last_share_day = self.nv_last_share_day,
	}
end

function lualore.jobs.on_activate_extra(self, data)
	if not data then
		return
	end
	self.nv_class = data.nv_class or self.nv_class
	self.nv_work_pos = data.nv_work_pos
	self.nv_stock = data.nv_stock or {}
	self.nv_no_station_until = data.nv_no_station_until
	self.nv_last_share_day = data.nv_last_share_day
end

-- ------------------------------------------------------------------
-- Diagnostics
-- ------------------------------------------------------------------
minetest.register_chatcommand("jobs", {
	params = "[radius]",
	description = S("List nearby villagers, their job and their workstation."),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local radius = tonumber(param) or 40
		local pos = player:get_pos()
		local lines = {}
		local counts = {}

		for _, obj in ipairs(minetest.get_objects_inside_radius(pos, radius)) do
			local ent = obj:get_luaentity()
			if ent and ent.name and ent.name:find("lualore:", 1, true) == 1
					and ent.nv_house_pos then
				local class = lualore.jobs.get_class(ent) or "?"
				counts[class] = (counts[class] or 0) + 1
				local epos = obj:get_pos()
				local station = "none"
				if ent.nv_work_pos then
					station = minetest.get_node(ent.nv_work_pos).name ..
						" @ " .. minetest.pos_to_string(ent.nv_work_pos) ..
						(ent.nv_at_station and " (at it)" or "")
				elseif ent.nv_no_station_until then
					station = "none found"
				end
				lines[#lines + 1] = string.format("%-12s %-11s %5.1fm  %s",
					class, ent.nv_behavior_state or "?",
					vector.distance(pos, epos), station)
			end
		end

		if #lines == 0 then
			return true, S("No villagers within @1 nodes.", radius)
		end
		table.sort(lines)
		local summary = {}
		for class, n in pairs(counts) do
			summary[#summary + 1] = class .. " x" .. n
		end
		table.sort(summary)
		return true, string.format("%s\n%-12s %-11s %5s  %s\n%s",
			table.concat(summary, ", "), "class", "state", "dist", "workstation",
			table.concat(lines, "\n"))
	end,
})

minetest.log("action", "[lualore] Villager jobs " ..
	(ENABLED and "enabled" or "disabled"))
