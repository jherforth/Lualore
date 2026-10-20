-- wooden_guardian.lua
-- ===================================================================
-- THE WOODEN GUARDIAN - a walking tree that keeps a village safe
-- ===================================================================
-- Every village gets one (village_workstations.lua places it), and a
-- player can wake another: stand four logs of any wood in a T, two
-- stacked with one either side of the upper, and set a Guardian Heart on
-- top. The heart is crafted (8 planks round a mese crystal), or forged by
-- throwing a crystal into a ring of 8 planks on the ground (see the end of
-- this file). The model and texture come from tools/make_wooden_guardian.py;
-- WOODEN_GUARDIAN.md has the player's view.
--
-- What it does:
--   * fights hostile mobs (mobs_redo's npc-attacks-monsters), and never
--     anything that lives in the village: see is_protected below
--   * turns on any player who hits a villager near it, for ALERT_TIME
--     seconds - its builder included
--   * walks a circuit of PATROL_POINTS round its home, pausing at each
--   * is mended with planks or logs, like the iron golem with iron
--   * answers a frightened villager, and if none is near enough, a
--     frightened villager raises one (villager_step, below)
--   * is carried by flowing water and cannot fight while it is
--   * drops the mese crystal its heart was made with
--
-- mobs_redo notes, learned the hard way elsewhere in this mod:
--   * it ignores a mob def's on_activate/get_staticdata, so state lives in
--     plain self._fields, which mobs_redo serialises for us
--   * do_custom runs before mobs_redo picks targets, so the filter also
--     goes in do_attack, which every path to a new target goes through
--   * lifetimer keeps an npc from being despawned
-- ===================================================================

lualore = lualore or {}
lualore.guardian = {}

local S = minetest.get_translator("lualore")

local NAME = "lualore:wooden_guardian"
local HEART = "lualore:guardian_heart"

local ALERT_RADIUS = 24     -- guardians this close see a villager struck
local ALERT_TIME = 30       -- seconds a guardian stays angry at a player
local PATROL_POINTS = 6
local PATROL_MIN, PATROL_MAX = 12, 18
local PAUSE_MIN, PAUSE_MAX = 3, 7
local STUCK_TIME = 12       -- give up on a patrol point after this long
local ARRIVE = 2.0
local REPAIR = {wood = 10, tree = 25}

-- Villager classes that are fair game when they have no bed.
local OUTLAWS = {hostile = true, raider = true}

-- Frightened villagers (villager_step)
local SCARE_TICK = 1        -- seconds between a villager's looks round
local SCARE_RADIUS = 8      -- a monster this close frightens a villager
local HURT_FEAR = 10        -- seconds a blow keeps a villager frightened
local ASSIST_RADIUS = 32    -- guardians this close come to a frightened villager
local ASSIST_TIME = 15      -- ...and keep coming this long after the last call
local SUMMON_RADIUS = 8     -- where a frightened villager raises a guardian
local SUMMON_COOLDOWN = math.max(1, tonumber(
	minetest.settings:get("lualore_guardian_summon_cooldown")) or 30)

local PUSH_SPEED = 2.0      -- how fast flowing water carries a guardian

-- ------------------------------------------------------------------
-- Who is never a target
-- ------------------------------------------------------------------
-- mobs_redo chooses targets by type alone, and some villagers are
-- "monster" type: the witch, a villager a player provoked, and the Sky
-- Folk under the valkyries. So the guardian asks about the entity itself.
function lualore.guardian.is_protected(ent)
	if not ent then
		return false
	end
	if ent.name == NAME or ent.name == "lualore:sky_folk" then
		return true
	end
	if ent.nv_house_pos then
		return true -- lives in a village bed, whatever its class
	end
	if ent.nv_class and not OUTLAWS[ent.nv_class] then
		return true
	end
	return false
end

local function protected_object(obj)
	if not obj or obj:is_player() then
		return false
	end
	return lualore.guardian.is_protected(obj:get_luaentity())
end

local function now()
	return minetest.get_gametime() or 0
end

-- ------------------------------------------------------------------
-- Retaliation
-- ------------------------------------------------------------------
local function anger(ent, player)
	local name = player and player:is_player() and player:get_player_name()
	if not name or name == "" then
		return
	end
	ent._angry = ent._angry or {}
	ent._angry[name] = now() + ALERT_TIME
end

-- A player struck a villager at pos: every guardian in range comes for
-- them. Called from the villager do_punch.
function lualore.guardian.alert(pos, player)
	if not (pos and player and player:is_player()) then
		return 0
	end
	local n = 0
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, ALERT_RADIUS)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == NAME then
			anger(ent, player)
			n = n + 1
		end
	end
	return n
end

local function stop_fight(self)
	self.attack = nil
	self.state = "stand"
	if self.set_velocity then
		self:set_velocity(0)
	end
	if self.set_animation then
		self:set_animation("stand")
	end
end

-- Keep the attack on whoever the guardian is angry at, and drop it when
-- the anger runs out. Returns true while the guardian has a grudge to
-- settle.
local function grudge_step(self)
	local angry = self._angry or {}
	local t = now()
	local pos = self.object:get_pos()
	local found
	for name, expiry in pairs(angry) do
		local player = minetest.get_player_by_name(name)
		if t >= expiry or not player or (player:get_hp() or 0) <= 0 then
			angry[name] = nil
		elseif not found and pos and vector.distance(pos, player:get_pos())
				<= (self.view_range or 16) + 8 then
			found = player
		end
	end
	if next(angry) == nil then
		self._angry = nil
	end
	if found then
		if self.attack ~= found then
			self.attack = found
			self.state = "attack"
		end
		return true
	end
	-- The anger ran out, or mobs_redo picked up a player by itself (the
	-- punch handler does): either way, players are only fought on a grudge.
	if self.attack and self.attack.is_player and self.attack:is_player() then
		stop_fight(self)
	end
	return false
end

-- ------------------------------------------------------------------
-- Patrol
-- ------------------------------------------------------------------
local function patrol_point(self, i)
	local home = self._home
	local angle = (i - 1) / PATROL_POINTS * 2 * math.pi + (self._patrol_phase or 0)
	-- alternate the radius, so the circuit weaves between houses
	local r = (i % 2 == 0) and PATROL_MAX or PATROL_MIN
	return {x = home.x + math.cos(angle) * r, y = home.y, z = home.z + math.sin(angle) * r}
end

-- mobs_redo's walk state moves the mob along its yaw; we only steer
local function walk_toward(self, target)
	local pos = self.object:get_pos()
	local yaw = math.atan2(target.z - pos.z, target.x - pos.x) - math.pi / 2
	if self.set_yaw then
		self:set_yaw(yaw, 6)
	else
		self.object:set_yaw(yaw)
	end
	if self.state ~= "walk" then
		self.state = "walk"
		if self.set_animation then
			self:set_animation("walk")
		end
	end
	if self.set_velocity then
		self:set_velocity(self.walk_velocity or 1)
	end
end

-- A frightened villager called (villager_step): go to it. Once there,
-- mobs_redo's own targeting finds the monster. Returns true while going.
local function assist_step(self)
	if not (self._assist_pos and self._assist_until) then
		return false
	end
	if now() >= self._assist_until then
		self._assist_pos, self._assist_until = nil, nil
		return false
	end
	local pos = self.object:get_pos()
	local p = self._assist_pos
	if pos and math.hypot(p.x - pos.x, p.z - pos.z) > ARRIVE + 2 then
		walk_toward(self, p)
	elseif self.state == "walk" then
		stop_fight(self)
	end
	return true
end

local function patrol_step(self, dtime)
	local pos = self.object:get_pos()
	if not (pos and self._home) then
		return
	end
	self._patrol_i = self._patrol_i or 1
	local target = patrol_point(self, self._patrol_i)
	local dx, dz = target.x - pos.x, target.z - pos.z
	local dist = math.sqrt(dx * dx + dz * dz)

	if (self._pause or 0) > 0 then
		self._pause = self._pause - dtime
		if self.state ~= "stand" then
			stop_fight(self)
		end
		return
	end

	self._leg_time = (self._leg_time or 0) + dtime
	if dist <= ARRIVE or self._leg_time > STUCK_TIME then
		self._patrol_i = self._patrol_i % PATROL_POINTS + 1
		self._leg_time = 0
		self._pause = math.random(PAUSE_MIN, PAUSE_MAX)
		self._visited = (self._visited or 0) + 1
		stop_fight(self)
		return
	end

	walk_toward(self, target)
end

-- Where this guardian keeps watch: the nearest recorded village, else the
-- spot it woke on.
local function find_home(pos)
	if lualore.villages and lualore.villages.find_near then
		local rec = lualore.villages.find_near(pos, 90)
		if rec then
			return {x = rec.x, y = rec.y or pos.y, z = rec.z}
		end
	end
	return {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5)}
end

-- A guardian that came out of a portal keeps watch over wherever it came
-- out (portal/sky_portal.lua), instead of trying to walk home.
function lualore.guardian.rehome(ent)
	local pos = ent.object and ent.object:get_pos()
	if pos then
		lualore.guardian.setup(ent, find_home(pos), ent._builder)
		ent._pause, ent._leg_time = 0, 0
	end
end

function lualore.guardian.setup(ent, home, builder)
	ent._home = home
	ent._builder = builder
	ent._patrol_phase = math.random() * 2 * math.pi
	ent._patrol_i = 1
end

-- ------------------------------------------------------------------
-- Carried by flowing water
-- ------------------------------------------------------------------
-- The engine moves nothing with flowing water - not players, mobs or
-- dropped items - and mobs_redo only slows a mob in it. But every flowing
-- liquid node holds its level in param2 (bits 0-2, lower further from the
-- source; bit 3 set while it falls), so the current can be read from any
-- game's ordinary liquids: it runs from higher levels to lower, and out
-- into open space. No liquids of our own.
local HORIZONTAL = {{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}

-- How full a neighbour is, as the current sees it: a source 8, the same
-- liquid flowing its level, open space -1 (the water runs into it), and
-- nil for walls and other liquids, which take no part.
local function level_of(node, family)
	local def = minetest.registered_nodes[node.name]
	if not def then
		return nil
	end
	if family[node.name] then
		if def.liquidtype == "source" or node.param2 >= 8 then
			return 8
		end
		return node.param2 % 8
	end
	if (def.liquidtype or "none") == "none" and not def.walkable
			and (node.name == "air" or def.buildable_to or def.floodable) then
		return -1
	end
	return nil
end

-- The direction flowing water at pos (a mob's feet) runs in, as a unit
-- vector, or nil if there is no current there: still water, sources and
-- water falling straight down carry nothing sideways.
function lualore.guardian.flow_at(pos)
	for dy = 0, 1 do
		local p = {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.6) + dy,
			z = math.floor(pos.z + 0.5)}
		local node = minetest.get_node(p)
		local def = minetest.registered_nodes[node.name]
		if def and def.liquidtype == "flowing" and node.param2 < 8 then
			local family = {[node.name] = true}
			for _, alt in ipairs({def.liquid_alternative_source, def.liquid_alternative_flowing}) do
				if alt and alt ~= "" then
					family[alt] = true
				end
			end
			local own = node.param2 % 8
			local fx, fz = 0, 0
			for _, d in ipairs(HORIZONTAL) do
				local lv = level_of(minetest.get_node({x = p.x + d.x, y = p.y, z = p.z + d.z}), family)
				if lv then
					fx = fx + d.x * (own - lv)
					fz = fz + d.z * (own - lv)
				end
			end
			local len = math.sqrt(fx * fx + fz * fz)
			if len > 0 then
				return {x = fx / len, y = 0, z = fz / len}
			end
		end
	end
	return nil
end

-- Caught in a current: carried along it, and no fighting or patrolling
-- until it is out. Returns true while carried.
local function current_step(self)
	local pos = self.object:get_pos()
	local flow = pos and lualore.guardian.flow_at(pos)
	if not flow then
		return false
	end
	local v = self.object:get_velocity() or {x = 0, y = 0, z = 0}
	self.object:set_velocity({x = flow.x * PUSH_SPEED, y = v.y, z = flow.z * PUSH_SPEED})
	if self.attack or self.state ~= "stand" then
		self.attack = nil
		self.state = "stand"
		if self.set_animation then
			self:set_animation("stand")
		end
	end
	return true
end

-- ------------------------------------------------------------------
-- Repair
-- ------------------------------------------------------------------
-- mobs_redo keeps the maximum on the object's properties (scaled by the
-- server's mob difficulty), not on the entity.
local function max_hp(self)
	local prop = self.prop or (self.object and self.object:get_properties())
	return prop and prop.hp_max or 150
end

local function repair(self, clicker)
	local stack = clicker:get_wielded_item()
	local item = stack:get_name()
	local heal
	if minetest.get_item_group(item, "tree") > 0 then
		heal = REPAIR.tree
	elseif minetest.get_item_group(item, "wood") > 0 then
		heal = REPAIR.wood
	end
	if not heal then
		return false
	end
	local max = max_hp(self)
	if (self.health or 0) >= max then
		minetest.chat_send_player(clicker:get_player_name(),
			S("The guardian is already whole."))
		return true
	end
	self.health = math.min(max, (self.health or 0) + heal)
	self.object:set_hp(self.health)
	if not minetest.is_creative_enabled(clicker:get_player_name()) then
		stack:take_item()
		clicker:set_wielded_item(stack)
	end
	local pos = self.object:get_pos()
	if pos then
		minetest.add_particlespawner({
			amount = 12, time = 0.4,
			minpos = vector.add(pos, {x = -0.6, y = 1.0, z = -0.6}),
			maxpos = vector.add(pos, {x = 0.6, y = 2.6, z = 0.6}),
			minvel = {x = -0.3, y = 0.4, z = -0.3}, maxvel = {x = 0.3, y = 1.2, z = 0.3},
			minexptime = 0.6, maxexptime = 1.2, minsize = 1, maxsize = 2,
			texture = "default_leaves.png",
		})
		minetest.sound_play("default_place_node", {pos = pos, gain = 0.8}, true)
	end
	return true
end

-- ------------------------------------------------------------------
-- The mob
-- ------------------------------------------------------------------
mobs:register_mob(NAME, {
	type = "npc",
	passive = false,
	attack_type = "dogfight",
	attack_monsters = true,
	attacks_monsters = true,
	attack_npcs = false,
	attack_animals = false,
	attack_players = false,
	group_attack = true,
	damage = 8,
	reach = 3,
	hp_min = 75,
	hp_max = 75,
	armor = 70,
	knock_back = false,
	blood_amount = 0,
	lifetimer = 20000,
	collisionbox = {-0.7, 0, -0.7, 0.7, 3.1, 0.7},
	visual = "mesh",
	mesh = "wooden_guardian.gltf",
	textures = {"wooden_guardian.png"},
	visual_size = {x = 1, y = 1},
	makes_footstep_sound = true,
	sounds = {
		attack = "default_dig_choppy",
		damage = "default_dig_choppy",
		death = "default_dug_node",
	},
	walk_velocity = 1.2,
	run_velocity = 2.4,
	stepheight = 1.1,
	jump = true,
	jump_height = 4,
	fear_height = 3,
	floats = 0,
	water_damage = 0,
	lava_damage = 8,
	fire_damage = 4,
	light_damage = 0,
	view_range = 16,
	-- patrol_step does the walking; mobs_redo only wanders if we let it
	walk_chance = 0,
	stand_chance = 0,
	randomly_turn = false,
	-- the mese crystal its heart was made with, like the iron golem's iron;
	-- a sapling of its wood can drop too (on_die)
	drops = {
		{name = "default:mese_crystal", chance = 1, min = 1, max = 1},
		{name = "default:stick", chance = 1, min = 2, max = 4},
		{name = "default:wood", chance = 1, min = 1, max = 3},
		{name = "default:apple", chance = 3, min = 1, max = 1},
	},
	animation = {
		speed_normal = 1,
		stand_start = 0, stand_end = 2, stand_speed = 1,
		walk_start = 2.5, walk_end = 3.5, walk_speed = 1,
		run_start = 2.5, run_end = 3.5, run_speed = 1.6,
		punch_start = 4.0, punch_end = 4.8, punch_speed = 1,
	},

	on_die = function(self, pos)
		local sapling = self._sapling
		if pos and sapling and minetest.registered_nodes[sapling] and math.random(6) == 1 then
			minetest.add_item(pos, sapling)
		end
		return false -- mobs_redo finishes the death as usual
	end,

	-- hit it and it hits back, for as long as a struck villager would make it
	do_punch = function(self, hitter)
		if hitter and hitter:is_player() then
			anger(self, hitter)
		end
	end,

	on_rightclick = function(self, clicker)
		if not (clicker and clicker:is_player()) then
			return
		end
		if repair(self, clicker) then
			return
		end
		local who = self._builder
		local msg = who and S("Wooden Guardian, woken by @1. Health @2 of @3.",
				who, math.floor(self.health or 0), max_hp(self))
			or S("Wooden Guardian of the village. Health @1 of @2.",
				math.floor(self.health or 0), max_hp(self))
		minetest.chat_send_player(clicker:get_player_name(), msg)
	end,

	do_custom = function(self, dtime)
		if not self.object then
			return
		end
		self.lifetimer = 20000
		-- it cannot fight the current: no AI at all while carried
		if current_step(self) then
			return false
		end
		if not self._home then
			local pos = self.object:get_pos()
			if pos then
				lualore.guardian.setup(self, find_home(pos))
			end
		end

		-- never fight a villager, whatever mobs_redo thinks of its type
		if self.attack and protected_object(self.attack) then
			stop_fight(self)
		end

		if grudge_step(self) then
			return true
		end
		if self.state == "attack" and self.attack then
			return true -- a monster: let mobs_redo fight it
		end
		if assist_step(self) then
			return true
		end
		patrol_step(self, dtime)
		return true
	end,
})

-- Every new target goes through do_attack, so refusing protected ones
-- here keeps the guardian from taking even one swing at a villager.
do
	local proto = minetest.registered_entities[NAME]
	local base = proto and proto.do_attack
	if base then
		proto.do_attack = function(self, obj, ...)
			if protected_object(obj) then
				return
			end
			return base(self, obj, ...)
		end
	end
end

mobs:register_egg(NAME, S("Wooden Guardian"), "lualore_guardian_heart.png", 0)

-- ------------------------------------------------------------------
-- Spawning one
-- ------------------------------------------------------------------
-- The sapling a guardian may drop: its village's tree, or (for one woken
-- from a T) the tree its logs came from.
local SAPLING_BY_PALETTE = {
	grassland = "default:sapling", jungle = "default:junglesapling",
	savanna = "default:acacia_sapling", ice = "default:pine_sapling",
	lake = "default:aspen_sapling",
}

local function village_sapling(pos)
	local rec = lualore.villages and lualore.villages.find_near
		and lualore.villages.find_near(pos, 90)
	return rec and SAPLING_BY_PALETTE[rec.palette] or nil
end

-- default:tree -> default:sapling, default:pine_tree -> default:pine_sapling,
-- ethereal:willow_trunk -> ethereal:willow_sapling; else the plain sapling
function lualore.guardian.sapling_of_log(log)
	for _, part in ipairs({"tree", "trunk"}) do
		local guess = log:gsub(part, "sapling", 1)
		if guess ~= log and minetest.registered_nodes[guess] then
			return guess
		end
	end
	return "default:sapling"
end

-- pos is where its feet go. Returns the entity, or nil.
function lualore.guardian.spawn(pos, home, builder)
	local obj = minetest.add_entity(pos, NAME)
	local ent = obj and obj:get_luaentity()
	if not ent then
		return nil
	end
	lualore.guardian.setup(ent, home or find_home(pos), builder)
	ent._sapling = village_sapling(pos)
	return ent
end

-- Is there a guardian within r of pos already?
function lualore.guardian.near(pos, r)
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, r)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == NAME then
			return true
		end
	end
	return false
end

-- ------------------------------------------------------------------
-- The Guardian Heart, and the T of logs it wakes
-- ------------------------------------------------------------------
local function is_log(pos)
	return minetest.get_item_group(minetest.get_node(pos).name, "tree") > 0
end

-- The heart sits at hpos. Below it the T: an upper log, a lower log under
-- that, and an arm either side of the upper one along x or along z.
-- Returns the five positions to clear (heart first), or nil.
function lualore.guardian.find_t(hpos)
	local upper = {x = hpos.x, y = hpos.y - 1, z = hpos.z}
	local lower = {x = hpos.x, y = hpos.y - 2, z = hpos.z}
	if not (is_log(upper) and is_log(lower)) then
		return nil
	end
	for _, axis in ipairs({{x = 1, z = 0}, {x = 0, z = 1}}) do
		local a = {x = upper.x + axis.x, y = upper.y, z = upper.z + axis.z}
		local b = {x = upper.x - axis.x, y = upper.y, z = upper.z - axis.z}
		if is_log(a) and is_log(b) then
			return {hpos, upper, lower, a, b}
		end
	end
	return nil
end

local function wake(hpos, placer)
	local parts = lualore.guardian.find_t(hpos)
	if not parts then
		return false
	end
	local log = minetest.get_node(parts[3]).name -- the lower log
	for _, p in ipairs(parts) do
		minetest.remove_node(p)
	end
	local feet = {x = hpos.x, y = hpos.y - 2.5, z = hpos.z}
	local name = placer and placer:is_player() and placer:get_player_name() or nil
	local ent = lualore.guardian.spawn(feet, find_home(feet), name)
	if ent then
		ent._sapling = lualore.guardian.sapling_of_log(log)
	end
	minetest.add_particlespawner({
		amount = 60, time = 0.6,
		minpos = {x = hpos.x - 1.2, y = hpos.y - 2.5, z = hpos.z - 1.2},
		maxpos = {x = hpos.x + 1.2, y = hpos.y + 0.5, z = hpos.z + 1.2},
		minvel = {x = -2, y = 0.5, z = -2}, maxvel = {x = 2, y = 3, z = 2},
		minacc = {x = 0, y = -6, z = 0}, maxacc = {x = 0, y = -6, z = 0},
		minexptime = 0.6, maxexptime = 1.4, minsize = 1.5, maxsize = 3,
		texture = "default_tree.png",
	})
	minetest.add_particlespawner({
		amount = 40, time = 0.6,
		minpos = {x = hpos.x - 1.2, y = hpos.y - 1, z = hpos.z - 1.2},
		maxpos = {x = hpos.x + 1.2, y = hpos.y + 1, z = hpos.z + 1.2},
		minvel = {x = -1.5, y = 0.5, z = -1.5}, maxvel = {x = 1.5, y = 2, z = 1.5},
		minexptime = 1, maxexptime = 2, minsize = 1, maxsize = 2.5,
		texture = "default_leaves.png",
	})
	minetest.sound_play("default_dig_choppy", {pos = hpos, gain = 1.0}, true)
	if name then
		minetest.chat_send_player(name, S("The Wooden Guardian wakes."))
	end
	return ent ~= nil
end
lualore.guardian.wake = wake

minetest.register_node(HEART, {
	description = S("Guardian Heart") .. "\n" ..
		S("Set it on a T of four logs: two stacked, one either side of the upper."),
	tiles = {
		"lualore_guardian_heart_top.png", "lualore_guardian_heart_top.png",
		"lualore_guardian_heart_side.png", "lualore_guardian_heart_side.png",
		"lualore_guardian_heart_side.png", "lualore_guardian_heart.png",
	},
	paramtype2 = "facedir",
	light_source = 4,
	groups = {choppy = 2, oddly_breakable_by_hand = 1},
	sounds = default.node_sound_wood_defaults(),
	after_place_node = function(pos, placer)
		wake(pos, placer)
	end,
})

minetest.register_craft({
	output = HEART,
	recipe = {
		{"group:wood", "group:wood", "group:wood"},
		{"group:wood", "default:mese_crystal", "group:wood"},
		{"group:wood", "group:wood", "group:wood"},
	},
})

-- ------------------------------------------------------------------
-- Forging a heart in the world
-- ------------------------------------------------------------------
-- The same recipe, laid out on the ground: a ring of eight planks round
-- an empty middle, and a mese crystal thrown into the hole. The planks
-- are used up and the heart pops out of the hole. Watched for the way the
-- sky portal watches for its iron ingot (portal/sky_portal.lua).
local CRYSTAL = "default:mese_crystal"
local FORGE_RADIUS = 10
local FORGE_EVERY = 0.5

local function is_plank(pos)
	return minetest.get_item_group(minetest.get_node(pos).name, "wood") > 0
end

-- The eight planks round hole, or nil.
function lualore.guardian.find_ring(hole)
	if minetest.get_node(hole).name ~= "air" then
		return nil
	end
	local ring = {}
	for dx = -1, 1 do
		for dz = -1, 1 do
			if dx ~= 0 or dz ~= 0 then
				local p = {x = hole.x + dx, y = hole.y, z = hole.z + dz}
				if not is_plank(p) then
					return nil
				end
				ring[#ring + 1] = p
			end
		end
	end
	return ring
end

local function forge(hole, obj, stack, player_name)
	local ring = lualore.guardian.find_ring(hole)
	if not ring then
		return false
	end
	if minetest.is_protected(hole, player_name) then
		minetest.record_protection_violation(hole, player_name)
		return false
	end
	local pos = obj:get_pos()
	obj:remove()
	if stack:get_count() > 1 then -- one crystal is enough; return the rest
		stack:take_item(1)
		minetest.add_item(pos, stack)
	end
	for _, p in ipairs(ring) do
		minetest.remove_node(p)
	end
	local heart = minetest.add_item({x = hole.x, y = hole.y + 0.2, z = hole.z}, HEART)
	if heart then
		heart:set_velocity({x = 0, y = 3, z = 0})
	end
	minetest.add_particlespawner({
		amount = 40, time = 0.5,
		minpos = {x = hole.x - 1.4, y = hole.y - 0.4, z = hole.z - 1.4},
		maxpos = {x = hole.x + 1.4, y = hole.y + 0.6, z = hole.z + 1.4},
		minvel = {x = -0.5, y = 1, z = -0.5}, maxvel = {x = 0.5, y = 2.5, z = 0.5},
		minexptime = 0.6, maxexptime = 1.2, minsize = 1, maxsize = 2.5,
		texture = "default_wood.png",
	})
	minetest.sound_play("default_place_node", {pos = hole, gain = 1.0}, true)
	minetest.log("action", "[lualore] " .. player_name .. " forged a Guardian Heart at "
		.. minetest.pos_to_string(hole))
	return true
end

local function check_dropped_crystals(player)
	local name = player:get_player_name()
	for _, obj in ipairs(minetest.get_objects_inside_radius(player:get_pos(), FORGE_RADIUS)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "__builtin:item" and type(ent.itemstring) == "string" then
			local stack = ItemStack(ent.itemstring)
			local pos = stack:get_name() == CRYSTAL and obj:get_pos()
			if pos then
				local p = vector.round(pos)
				local h = minetest.hash_node_position(p)
				-- only look again once the crystal has moved to a new cell
				if ent._lualore_forge_seen ~= h then
					ent._lualore_forge_seen = h
					forge(p, obj, stack, name)
				end
			end
		end
	end
end

local forge_timer = 0
minetest.register_globalstep(function(dtime)
	forge_timer = forge_timer + dtime
	if forge_timer < FORGE_EVERY then
		return
	end
	forge_timer = 0
	for _, player in ipairs(minetest.get_connected_players()) do
		check_dropped_crystals(player)
	end
end)

-- ------------------------------------------------------------------
-- Frightened villagers
-- ------------------------------------------------------------------
-- A villager is frightened by a monster within SCARE_RADIUS (seen or not:
-- a zombie behind glass is still a zombie), or for HURT_FEAR seconds after
-- a blow. While frightened it:
--   * shows the scared mood;
--   * calls every guardian within ASSIST_RADIUS to it;
--   * with none in reach, raises one within SUMMON_RADIUS of itself - at
--     most one per village every SUMMON_COOLDOWN seconds. Kill that one
--     while the villager is still frightened and, after the cooldown,
--     another rises: that is a guardian farm, and a fair price for a mese
--     crystal a time;
--   * runs from a monster (but not from a player it has been provoked into
--     fighting), toward its bed if it has one.
-- villager_step runs from the villager's do_custom (villagers.lua) and
-- returns true while the villager is running, so its job and behaviours
-- stay out of the way.

local last_summon = {} -- village key -> game time of its last summoning

local function is_villager(ent)
	return ent ~= nil and ent.nv_class ~= nil and not OUTLAWS[ent.nv_class]
end

local function threat_near(pos)
	local best, best_d
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, SCARE_RADIUS)) do
		local ent = not obj:is_player() and obj:get_luaentity()
		if ent and ent._cmi_is_mob and ent.type == "monster" and (ent.health or 1) > 0
				and not lualore.guardian.is_protected(ent) then
			local d = vector.distance(pos, obj:get_pos())
			if not best_d or d < best_d then
				best, best_d = obj, d
			end
		end
	end
	return best
end

-- The village a summoning counts against: the recorded village, or a
-- 64-node patch of ground outside one.
local function village_key(pos)
	if lualore.villages and lualore.villages.find_near then
		local rec, key = lualore.villages.find_near(pos, 96)
		if rec then
			return key, rec
		end
	end
	return "cell:" .. math.floor(pos.x / 64) .. ":" .. math.floor(pos.z / 64)
end

local function walkable_at(x, y, z)
	local def = minetest.registered_nodes[minetest.get_node({x = x, y = y, z = z}).name]
	return def ~= nil and def.walkable == true
end

local function open_at(x, y, z)
	local name = minetest.get_node({x = x, y = y, z = z}).name
	if name == "air" then
		return true
	end
	local def = minetest.registered_nodes[name]
	return def ~= nil and not def.walkable and def.buildable_to == true
		and (def.liquidtype or "none") == "none"
end

-- Ground within SUMMON_RADIUS a guardian can stand on: a solid floor with
-- four open, dry nodes over it.
local function summon_spot(pos)
	local cx, cy, cz = math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5)
	for _ = 1, 24 do
		local x = cx + math.random(-SUMMON_RADIUS, SUMMON_RADIUS)
		local z = cz + math.random(-SUMMON_RADIUS, SUMMON_RADIUS)
		if (x - pos.x) ^ 2 + (z - pos.z) ^ 2 <= SUMMON_RADIUS ^ 2 then
			for y = cy + 4, cy - 5, -1 do
				if walkable_at(x, y, z) then
					if open_at(x, y + 1, z) and open_at(x, y + 2, z)
							and open_at(x, y + 3, z) and open_at(x, y + 4, z) then
						return {x = x, y = y + 0.5, z = z}
					end
					break
				end
			end
		end
	end
	return nil
end

local function summon(villager, pos, key, rec)
	local spot = summon_spot(pos)
	if not spot then
		return nil
	end
	local home = rec and {x = rec.x, y = rec.y or spot.y, z = rec.z}
		or {x = spot.x, y = spot.y, z = spot.z}
	local ent = lualore.guardian.spawn(spot, home)
	if not ent then
		return nil
	end
	last_summon[key] = now()
	ent._summoned = true
	-- a blow brought it: it comes for whoever struck
	local by = villager._lualore_hurt_by
	if by and now() - (villager._lualore_hurt_by_at or -math.huge) <= HURT_FEAR then
		local player = minetest.get_player_by_name(by)
		if player then
			anger(ent, player)
		end
	end
	minetest.add_particlespawner({
		amount = 50, time = 0.8,
		minpos = {x = spot.x - 1, y = spot.y, z = spot.z - 1},
		maxpos = {x = spot.x + 1, y = spot.y + 3, z = spot.z + 1},
		minvel = {x = -1.5, y = 0.5, z = -1.5}, maxvel = {x = 1.5, y = 2.5, z = 1.5},
		minexptime = 0.8, maxexptime = 1.6, minsize = 1, maxsize = 2.5,
		texture = "default_leaves.png",
	})
	minetest.sound_play("default_dig_choppy", {pos = spot, gain = 1.0}, true)
	for _, player in ipairs(minetest.get_connected_players()) do
		local p = player:get_pos()
		if p and vector.distance(p, spot) <= 32 then
			minetest.chat_send_player(player:get_player_name(),
				S("A frightened villager calls on the forest, and a Wooden Guardian rises!"))
		end
	end
	minetest.log("action", "[lualore] A frightened " .. tostring(villager.nv_class) ..
		" summoned a Wooden Guardian at " .. minetest.pos_to_string(vector.round(spot)))
	return ent
end

local function flee_step(self)
	if self.at_cliff then -- mobs_redo's own look at the drop ahead
		if self.set_velocity then
			self:set_velocity(0)
		end
		return true
	end
	self.object:set_yaw(self._lualore_flee_yaw)
	self.state = "walk"
	if self.set_animation then
		self:set_animation("walk")
	end
	if self.set_velocity then
		self:set_velocity(self.run_velocity or 2)
	end
	return true
end

function lualore.guardian.villager_step(self, dtime)
	if not (self.object and is_villager(self)) then
		return false
	end
	self._lualore_scare_timer = (self._lualore_scare_timer or 0) + (dtime or 0)
	if self._lualore_scare_timer < SCARE_TICK then
		return self._lualore_fleeing and flee_step(self) or false
	end
	self._lualore_scare_timer = 0

	local pos = self.object:get_pos()
	if not pos then
		return false
	end
	local threat = threat_near(pos)
	local hurt = now() - (self._lualore_hurt or -math.huge) <= HURT_FEAR
	if not (threat or hurt) then
		self._lualore_fleeing = nil
		return false
	end

	self.nv_fear = 100
	if self.nv_mood ~= "scared" then
		self.nv_mood = "scared"
		if lualore.mood and lualore.mood.update_indicator then
			pcall(lualore.mood.update_indicator, self)
		end
	end

	-- call the guardians in reach; with none, raise one
	local helpers = 0
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, ASSIST_RADIUS)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == NAME then
			ent._assist_pos = {x = pos.x, y = pos.y, z = pos.z}
			ent._assist_until = now() + ASSIST_TIME
			helpers = helpers + 1
		end
	end
	if helpers == 0 then
		local key, rec = village_key(pos)
		if now() - (last_summon[key] or -math.huge) >= SUMMON_COOLDOWN then
			summon(self, pos, key, rec)
		end
	end

	-- run from a monster: away from it, bending toward home
	if threat and self.type == "npc" and not self.nv_provoked then
		local tp = threat:get_pos()
		local ax, az = pos.x - tp.x, pos.z - tp.z
		local len = math.hypot(ax, az)
		if len < 0.01 then
			ax, az, len = 1, 0, 1
		end
		ax, az = ax / len, az / len
		local home = self.nv_house_pos
		if home then
			local hx, hz = home.x - pos.x, home.z - pos.z
			local hl = math.hypot(hx, hz)
			if hl > 1 then
				ax, az = ax + 0.5 * hx / hl, az + 0.5 * hz / hl
			end
		end
		self._lualore_flee_yaw = math.atan2(az, ax) - math.pi / 2
		self._lualore_fleeing = true
		return flee_step(self)
	end
	self._lualore_fleeing = nil
	return false
end

-- The time the village at pos last raised a guardian (for tests and
-- /commands), and a way to forget it.
function lualore.guardian.last_summon(pos)
	return last_summon[(village_key(pos))]
end
function lualore.guardian.reset_summons()
	last_summon = {}
end
