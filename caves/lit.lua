--[[
	caves/lit.lua

	"The Lit" - a lone, wandering flame creature found in caves at almost
	any depth. Common enough that you will run across them while exploring.

	Behavior:
	  * Passive until attacked. It ignores everything until it is hurt.
	  * Surrounding illumination: it carries its own glow with it wherever
	    it walks (a light node that follows above its flame).
	  * When first attacked it rolls one of two personalities (50/50):
	      - FIGHT: chases the player and hurls fire bolts that set the
	        player on fire for a few seconds. Panics and switches to flight
	        when badly wounded.
	      - FLIGHT: runs away. If cornered or pursued too closely it drills
	        straight down through the floor to escape into a deeper cavern.
	    Re-attacking a fleeing Lit encourages it to burrow even sooner.
	  * Drops: a torch, coal and flint when defeated.

	Model: models/lit_combined.gltf - generated from models/lit.gltf with
	tools/combine_gltf_animations.py. Luanti (<= 5.14) supports only ONE
	animation per glTF model and uses glTF timestamps (seconds) as frame
	numbers, so the original three clips are concatenated into a single
	timeline and played through frame ranges (speed 1.0):
	    0.00 -  5.92  idle   (original "animation.standing.golbo")
	    6.17 - 12.17  walk   (original "animation.walking.golbo")
	   12.42 - 13.63  drill  (original "animation.mining.golbo")
	The combiner does three things the raw export does not, so take the
	ranges above from what it prints rather than setting them by hand:
	  * One channel per bone. glTF allows a bone to be driven once per
	    animation; concatenating the clips naively gave some bones three
	    channels, which is invalid and left the winning pose up to the
	    renderer. It also meant a bone animated in only one clip held that
	    clip's pose during the others, because samplers clamp outside their
	    own key range - the legs stood in mid-stride through the whole idle.
	    Bones a clip does not touch now hold their rest pose instead.
	  * A guard gap between clips, so no frame belongs to two of them and
	    looping one cannot flash the next one's opening pose.
	  * Closed loops and baked easing. The walk was six one-second strides
	    cut off three-quarters through the sixth, so every loop lurched; it
	    now ends on the pose it starts from. Easing is resampled into denser
	    LINEAR keys because Luanti reads LINEAR samplers only.
	If lit.gltf is ever re-exported, regenerate the combined model with:
	    python tools/combine_gltf_animations.py models/lit.gltf ^
	        models/lit_combined.gltf animation.standing.golbo ^
	        animation.walking.golbo animation.mining.golbo

	Size note: the engine renders entity meshes at 10 units per node
	(the model is 20 units tall, so 2.0 nodes at scale 1); VISUAL_SIZE
	1.25 renders it at ~2.5 nodes tall - twice its original size.
	Adjust VISUAL_SIZE below to taste.
]]

local S = minetest.get_translator("lualore")

lualore = lualore or {}

local LIGHT_NODE = "lualore:lit_light"
local BOLT = "lualore:lit_fire_bolt"

-- Animation ranges (seconds == frames) and sizes
local ANIM = {
	idle = {0.0, 5.917},
	walk = {6.167, 12.167},
	mine = {12.417, 13.625},
}
-- Entities render meshes at 10 units per node, so the 20-unit model is
-- 2.0 nodes tall at scale 1; 1.25 renders it at ~2.5 nodes tall
-- (twice the previous size).
local VISUAL_SIZE = 1.25

-- Combat / movement tuning
local BURN_TIME = 4        -- seconds a fire bolt keeps burning the player
local BURN_DAMAGE = 1      -- damage per second while burning
local BOLT_DAMAGE = 6      -- direct fire bolt hit (fleshy damage group)
local BOLT_SPEED = 14
local CHASE_SPEED = 1.9    -- fight mode movement speed
local RUN_SPEED = 3.2      -- flight mode movement speed
local DRILL_STEP_TIME = 0.28 -- seconds per floor block removed while burrowing
local DRILL_SINK_SPEED = 3.0 -- downward speed while burrowing
local DRILL_MAX_DEPTH = 24   -- give up if no open space within this many blocks
local WANDER_SPEED = 1.0     -- relaxed wandering speed

lualore.lit = { anim = ANIM }

-- All glow nodes placed by the Lit are tracked here so stray lights can be
-- swept up even when the creature is removed without a chance to tidy up
-- (world unload, active mob limit, /clear_mobs, ...).
local lit_lights = {}

local function track_lit_light(pos)
	lit_lights[minetest.pos_to_string(pos)] = {x = pos.x, y = pos.y, z = pos.z}
end

local function untrack_lit_light(pos)
	lit_lights[minetest.pos_to_string(pos)] = nil
end

-- ------------------------------------------------------------------
-- Glow node: what makes the Lit illuminate its surroundings
-- ------------------------------------------------------------------

minetest.register_node("lualore:lit_light", {
	description = S("Lit's glow"),
	drawtype = "airlike",
	paramtype = "light",
	light_source = minetest.LIGHT_MAX,
	sunlight_propagates = true,
	walkable = false,
	pointable = false,
	buildable_to = true,
	floodable = false,
	is_ground_content = false,
	groups = {not_in_creative_inventory = 1},
	drop = "",
})

local function clear_lit_light(self)
	local pos = self._lit_light_pos
	if not pos then
		return
	end
	self._lit_light_pos = nil
	untrack_lit_light(pos)
	local node = minetest.get_node_or_nil(pos)
	if node and node.name == LIGHT_NODE then
		minetest.remove_node(pos)
	end
end

local function update_lit_light(self, dtime)
	if (self.health or 1) <= 0 then
		-- dying or dead: take the glow with it
		clear_lit_light(self)
		return
	end

	self._lit_glow_timer = (self._lit_glow_timer or 0) + dtime
	if self._lit_glow_timer < 0.35 then
		return
	end
	self._lit_glow_timer = 0

	local pos = self.object:get_pos()
	if not pos then
		return
	end

	-- ambient embers drifting off the creature
	minetest.add_particlespawner({
		amount = 3,
		time = 0.5,
		minpos = {x = pos.x - 0.2, y = pos.y + 0.3, z = pos.z - 0.2},
		maxpos = {x = pos.x + 0.2, y = pos.y + 2.2, z = pos.z + 0.2},
		minvel = {x = -0.25, y = 0.3, z = -0.25},
		maxvel = {x = 0.25, y = 0.9, z = 0.25},
		minacc = {x = 0, y = 0.1, z = 0},
		maxacc = {x = 0, y = 0.3, z = 0},
		minexptime = 0.4,
		maxexptime = 0.9,
		minsize = 0.8,
		maxsize = 1.6,
		texture = "lualore_particle_blob.png^[colorize:#FFB030:150",
		glow = 10,
	})

	local target = {
		x = math.floor(pos.x + 0.5),
		y = math.floor(pos.y + 1.5),
		z = math.floor(pos.z + 0.5),
	}
	local old = self._lit_light_pos
	if old and old.x == target.x and old.y == target.y and old.z == target.z then
		return
	end

	if old then
		untrack_lit_light(old)
		local node = minetest.get_node_or_nil(old)
		if node and node.name == LIGHT_NODE then
			minetest.remove_node(old)
		end
		self._lit_light_pos = nil
	end

	local node = minetest.get_node_or_nil(target)
	if node and node.name == "air" then
		minetest.set_node(target, {name = LIGHT_NODE})
		self._lit_light_pos = target
		track_lit_light(target)
	end
end

-- Safety sweep: remove tracked glow nodes that no longer belong to a living
-- Lit (e.g. after world unload, despawning or external removal).
local lit_sweep_timer = 0

minetest.register_globalstep(function(dtime)
	if next(lit_lights) == nil then
		return
	end
	lit_sweep_timer = lit_sweep_timer + dtime
	if lit_sweep_timer < 8 then
		return
	end
	lit_sweep_timer = 0

	local players = minetest.get_connected_players()
	for key, pos in pairs(lit_lights) do
		local near_player = false
		for _, player in ipairs(players) do
			local ppos = player:get_pos()
			if ppos and vector.distance(ppos, pos) < 48 then
				near_player = true
				break
			end
		end
		if near_player then
			local node = minetest.get_node_or_nil(pos)
			if node and node.name ~= LIGHT_NODE then
				-- the world replaced it; forget about it
				lit_lights[key] = nil
			elseif node then
				local owner_near = false
				for _, obj in ipairs(minetest.get_objects_inside_radius(pos, 3)) do
					local ent = obj:get_luaentity()
					if ent and ent.name == "lualore:lit" then
						owner_near = true
						break
					end
				end
				if not owner_near then
					minetest.remove_node(pos)
					lit_lights[key] = nil
				end
			end
		end
	end
end)

-- ------------------------------------------------------------------
-- Burning: damage over time after a fire bolt connects
-- ------------------------------------------------------------------

local burning = {}

local function set_player_burning(player, seconds)
	local name = player:get_player_name()
	local now = minetest.get_gametime()
	burning[name] = {
		until_time = now + seconds,
		next_tick = now + 1,
	}
end

minetest.register_globalstep(function(dtime)
	if next(burning) == nil then
		return
	end
	local now = minetest.get_gametime()
	for name, data in pairs(burning) do
		local player = minetest.get_player_by_name(name)
		if not player or now >= data.until_time or player:get_hp() <= 0 then
			burning[name] = nil
		elseif now >= data.next_tick then
			data.next_tick = now + 1
			local pos = player:get_pos()
			local head = minetest.get_node({x = pos.x, y = pos.y + 1, z = pos.z}).name
			if minetest.get_item_group(head, "water") ~= 0 then
				-- jumps into water to douse the flames
				burning[name] = nil
			else
				player:set_hp(math.max(player:get_hp() - BURN_DAMAGE, 0))
				minetest.add_particlespawner({
					amount = 6,
					time = 0.7,
					minpos = {x = pos.x - 0.3, y = pos.y + 0.2, z = pos.z - 0.3},
					maxpos = {x = pos.x + 0.3, y = pos.y + 1.5, z = pos.z + 0.3},
					minvel = {x = -0.4, y = 0.4, z = -0.4},
					maxvel = {x = 0.4, y = 1.2, z = 0.4},
					minexptime = 0.3,
					maxexptime = 0.7,
					minsize = 1,
					maxsize = 2,
					texture = "lualore_firebolt.png",
					glow = 12,
				})
			end
		end
	end
end)

-- ------------------------------------------------------------------
-- Fire bolt projectile
-- ------------------------------------------------------------------

local function bolt_burst(pos, big)
	minetest.add_particlespawner({
		amount = big and 18 or 8,
		time = 0.4,
		minpos = {x = pos.x - 0.2, y = pos.y - 0.2, z = pos.z - 0.2},
		maxpos = {x = pos.x + 0.2, y = pos.y + 0.2, z = pos.z + 0.2},
		minvel = {x = -2, y = -1, z = -2},
		maxvel = {x = 2, y = 2, z = 2},
		minexptime = 0.3,
		maxexptime = 0.8,
		minsize = 1,
		maxsize = 2.4,
		texture = "lualore_firebolt.png",
		glow = 12,
	})
	minetest.add_particlespawner({
		amount = big and 10 or 4,
		time = 0.6,
		minpos = {x = pos.x - 0.2, y = pos.y - 0.2, z = pos.z - 0.2},
		maxpos = {x = pos.x + 0.2, y = pos.y + 0.2, z = pos.z + 0.2},
		minvel = {x = -0.5, y = 0.3, z = -0.5},
		maxvel = {x = 0.5, y = 1, z = 0.5},
		minexptime = 0.5,
		maxexptime = 1.2,
		minsize = 1.4,
		maxsize = 2.6,
		texture = "lualore_particle_blob.png^[colorize:#333333:140",
	})
end

minetest.register_entity(BOLT, {
	initial_properties = {
		visual = "sprite",
		textures = {"lualore_firebolt.png"},
		visual_size = {x = 0.6, y = 0.6},
		collisionbox = {-0.08, -0.08, -0.08, 0.08, 0.08, 0.08},
		physical = false,
		pointable = false,
		collide_with_objects = false,
		glow = 12,
	},
	velocity = {x = 0, y = 0, z = 0},
	damage = BOLT_DAMAGE,
	burn_time = BURN_TIME,
	lifetime = 0,
	on_step = function(self, dtime)
		local pos = self.object:get_pos()
		if not pos then
			self.object:remove()
			return
		end

		self.lifetime = (self.lifetime or 0) + dtime
		if self.lifetime > 4 then
			bolt_burst(pos, false)
			self.object:remove()
			return
		end

		-- short trail behind the bolt
		self.trail_timer = (self.trail_timer or 0) + dtime
		if self.trail_timer >= 0.09 then
			self.trail_timer = 0
			minetest.add_particlespawner({
				amount = 2,
				time = 0.25,
				minpos = pos,
				maxpos = pos,
				minvel = {x = -0.2, y = -0.2, z = -0.2},
				maxvel = {x = 0.2, y = 0.2, z = 0.2},
				minexptime = 0.2,
				maxexptime = 0.4,
				minsize = 0.7,
				maxsize = 1.4,
				texture = "lualore_firebolt.png",
				glow = 10,
			})
		end

		-- integrate manually so fast bolts never tunnel through targets
		local step = vector.multiply(self.velocity, dtime)
		local substeps = math.max(1, math.ceil(vector.length(step) / 0.5))
		for _ = 1, substeps do
			pos = vector.add(pos, vector.multiply(step, 1 / substeps))

			local player_hit = nil
			for _, obj in ipairs(minetest.get_objects_inside_radius(pos, 0.9)) do
				if obj:is_player() then
					player_hit = obj
					break
				end
			end
			if player_hit then
				player_hit:punch(self.object, 1.0, {
					full_punch_interval = 1.0,
					damage_groups = {fleshy = self.damage or BOLT_DAMAGE},
				}, self.velocity)
				set_player_burning(player_hit, self.burn_time or BURN_TIME)
				bolt_burst(pos, true)
				self.object:remove()
				return
			end

			local name = minetest.get_node(pos).name
			if name ~= "air" and name ~= "ignore" and name ~= LIGHT_NODE then
				local def = minetest.registered_nodes[name]
				local liquid = def and def.liquidtype and def.liquidtype ~= "none"
				if not liquid then
					bolt_burst(pos, true)
					self.object:remove()
					return
				end
			end
		end
		self.object:set_pos(pos)
	end,
})

-- ------------------------------------------------------------------
-- AI helpers
-- ------------------------------------------------------------------

-- Play a clip of the combined timeline directly on the object.
local function set_raw_anim(self, clip)
	local r = ANIM[clip]
	if r and self.object then
		self.object:set_animation({x = r[1], y = r[2]}, 1.0, 0, true)
	end
end

local function return_to_wander(self)
	self._lit_mode = "wander"
	self._lit_target = nil
	self._lit_drill = nil
	self._lit_close_timer = 0
	self._lit_stuck = 0
	self._lit_shot_timer = 0
	self.walk_velocity = WANDER_SPEED
	self.state = "stand"
	-- show the idle clip; keep mobs_redo's animation cache in sync
	set_raw_anim(self, "idle")
	self.current_animation = "stand"
end

local function resolve_target(self)
	local target = self._lit_target
	if not target or not target:is_valid() or not target:is_player() then
		return nil
	end
	if target:get_hp() <= 0 then
		return nil
	end
	if minetest.get_player_by_name(target:get_player_name()) ~= target then
		return nil
	end
	local tpos = target:get_pos()
	local mpos = self.object and self.object:get_pos() or nil
	if not tpos or not mpos then
		return nil
	end
	local dist = vector.distance(mpos, tpos)
	if dist > 36 then
		return nil
	end
	return target, tpos, mpos, dist
end

-- Called whenever the Lit is hurt by a player: decides (once) whether it
-- fights or flees and switches accordingly.
local function lit_on_attacked(self, hitter)
	if not self.object or not hitter or not hitter:is_player() then
		return
	end
	if self.health and self.health <= 0 then
		return
	end

	-- roll the personality once, on the first hit
	if not self._lit_personality then
		self._lit_personality = (math.random(2) == 1) and "fight" or "flee"
	end

	self._lit_target = hitter
	self._lit_aggro_time = minetest.get_gametime()
	self._lit_calm_timer = 0
	self._lit_close_timer = 0

	if self._lit_personality == "flee" then
		self._lit_mode = "flee"
		self._lit_drill_cooldown = 0 -- freshly provoked: allow burrowing again
		if not self._lit_drill then
			self._lit_flee_sub = "run"
		end
	else
		self._lit_mode = "fight"
		if (self._lit_shot_timer or 0) < 1.2 then
			self._lit_shot_timer = 1.2 -- first bolt shortly after being hit
		end
	end

	-- sparks fly when it is struck
	local pos = self.object:get_pos()
	if pos then
		minetest.add_particlespawner({
			amount = 12,
			time = 0.4,
			minpos = {x = pos.x - 0.3, y = pos.y + 0.2, z = pos.z - 0.3},
			maxpos = {x = pos.x + 0.3, y = pos.y + 2.0, z = pos.z + 0.3},
			minvel = {x = -1.5, y = 0.5, z = -1.5},
			maxvel = {x = 1.5, y = 2.5, z = 1.5},
			minexptime = 0.3,
			maxexptime = 0.7,
			minsize = 1,
			maxsize = 2,
			texture = "lualore_firebolt.png",
			glow = 12,
		})
	end
end

local function shoot_fire_bolt(self, target_pos)
	local pos = self.object:get_pos()
	if not pos then
		return
	end
	local start = {x = pos.x, y = pos.y + 1.6, z = pos.z}
	local dir = vector.direction(start, target_pos)
	if vector.length(dir) == 0 then
		return
	end

	local bolt = minetest.add_entity(start, BOLT)
	if not bolt then
		return
	end
	local ent = bolt:get_luaentity()
	if ent then
		ent.velocity = vector.multiply(dir, BOLT_SPEED)
		ent.damage = BOLT_DAMAGE
		ent.burn_time = BURN_TIME
	end

	-- muzzle flash
	minetest.add_particlespawner({
		amount = 8,
		time = 0.3,
		minpos = start,
		maxpos = start,
		minvel = {x = -1, y = -1, z = -1},
		maxvel = {x = 1, y = 1, z = 1},
		minexptime = 0.2,
		maxexptime = 0.5,
		minsize = 1,
		maxsize = 2,
		texture = "lualore_firebolt.png",
		glow = 12,
	})
end

local function fight_step(self, dtime, target, tpos, mpos, dist)
	-- badly wounded: panic and switch to flight
	if self.health and self.hp_max and self.health <= self.hp_max * 0.3 then
		self._lit_personality = "flee"
		self._lit_mode = "flee"
		self._lit_flee_sub = "run"
		self._lit_close_timer = 0
		return
	end

	self.walk_velocity = CHASE_SPEED

	local dir = vector.direction(mpos, tpos)
	dir.y = 0
	local has_dir = vector.length(dir) > 0.001
	if has_dir then
		dir = vector.normalize(dir)
	end

	local vel = self.object:get_velocity() or {x = 0, y = 0, z = 0}
	local move = {x = 0, y = vel.y, z = 0}
	if has_dir then
		if dist > 8 then
			move.x = dir.x * CHASE_SPEED
			move.z = dir.z * CHASE_SPEED
		elseif dist < 3.5 then
			move.x = -dir.x * CHASE_SPEED * 0.6
			move.z = -dir.z * CHASE_SPEED * 0.6
		end
	end

	local moving = (move.x ~= 0 or move.z ~= 0)
	if moving then
		-- hop over obstacles when not getting anywhere
		local cpos = {x = mpos.x, y = mpos.y, z = mpos.z}
		local last = self._lit_last_pos
		if last and vector.distance(cpos, last) < 0.08 then
			self._lit_stuck = (self._lit_stuck or 0) + dtime
			if self._lit_stuck > 0.7 then
				move.y = 4.5
				self._lit_stuck = 0
			end
		else
			self._lit_stuck = 0
		end
		self._lit_last_pos = {x = mpos.x, y = mpos.y, z = mpos.z}
	end

	self.object:set_velocity(move)
	if has_dir then
		self.object:set_yaw(minetest.dir_to_yaw(dir))
	end
	if moving then
		self.state = "walk"
		self:set_animation("walk")
	else
		self.state = "stand"
		self:set_animation("stand")
	end

	-- hurl fire bolts at the player
	self._lit_shot_timer = (self._lit_shot_timer or 0) + dtime
	if dist <= 20 and self._lit_shot_timer >= 2.0 then
		local eye = {x = mpos.x, y = mpos.y + 1.6, z = mpos.z}
		local aim = {x = tpos.x, y = tpos.y + 1.2, z = tpos.z}
		if minetest.line_of_sight(eye, aim) then
			self._lit_shot_timer = 0
			shoot_fire_bolt(self, aim)
		end
	end
end

-- Start burrowing straight down through the floor. Returns true if the
-- Lit found a valid escape route and began drilling.
local function start_drill(self)
	if (self._lit_drill_cooldown or 0) > 0 then
		return false
	end
	local pos = self.object:get_pos()
	if not pos then
		return false
	end

	local cx = math.floor(pos.x)
	local cz = math.floor(pos.z)
	local support_y = math.floor(pos.y - 0.5)

	-- scan what is below: it must be diggable, unprotected, and there must
	-- be open space within DRILL_MAX_DEPTH blocks
	local dig_count = 0
	for k = 0, DRILL_MAX_DEPTH - 1 do
		local p = {x = cx, y = support_y - k, z = cz}
		local name = minetest.get_node(p).name
		if name == "air" then
			break
		end
		if name == "ignore" or name == "unknown" then
			return false
		end
		local def = minetest.registered_nodes[name]
		if not def or def.diggable == false
				or (def.liquidtype and def.liquidtype ~= "none") then
			return false
		end
		if minetest.is_protected(p, "") then
			return false
		end
		dig_count = dig_count + 1
	end

	if dig_count < 2 or dig_count >= DRILL_MAX_DEPTH then
		return false
	end

	self._lit_drill = {x = cx, z = cz, timer = 0, smoke_timer = 0, depth = 0}
	self._lit_flee_sub = "drill"
	-- "drill" is not a state mobs_redo knows, which conveniently keeps its
	-- per-second state machine from touching our animation or velocity
	self.state = "drill"
	self.current_animation = "drill"
	set_raw_anim(self, "mine")

	-- dust puff as it starts burrowing
	local node = minetest.get_node({x = cx, y = support_y, z = cz})
	local def = minetest.registered_nodes[node.name] or {}
	local tiles = def.tiles
	local tex = tiles and tiles[1] or "lualore_particle_x.png"
	if type(tex) == "table" then
		tex = tex[1]
	end
	minetest.add_particlespawner({
		amount = 14,
		time = 0.6,
		minpos = {x = cx - 0.3, y = support_y + 0.1, z = cz - 0.3},
		maxpos = {x = cx + 0.3, y = support_y + 0.6, z = cz + 0.3},
		minvel = {x = -1, y = 0.5, z = -1},
		maxvel = {x = 1, y = 1.5, z = 1},
		minexptime = 0.4,
		maxexptime = 0.9,
		minsize = 1,
		maxsize = 2,
		texture = tostring(tex),
	})
	return true
end

local function drill_step(self, dtime)
	local drill = self._lit_drill
	local pos = self.object:get_pos()
	if not pos then
		self._lit_drill = nil
		return
	end

	-- pull toward the centre of the shaft and sink downwards
	local cx = drill.x + 0.5
	local cz = drill.z + 0.5
	self.object:set_velocity({
		x = (cx - pos.x) * 5,
		y = -DRILL_SINK_SPEED,
		z = (cz - pos.z) * 5,
	})

	-- make sure the burrow clip keeps playing even if something else
	-- re-set the animation in the meantime
	if self.current_animation ~= "drill" then
		self.current_animation = "drill"
		set_raw_anim(self, "mine")
	end

	drill.timer = drill.timer + dtime
	drill.smoke_timer = (drill.smoke_timer or 0) + dtime
	if drill.smoke_timer >= 0.6 then
		drill.smoke_timer = 0
		minetest.add_particlespawner({
			amount = 4,
			time = 0.4,
			minpos = {x = cx - 0.2, y = pos.y, z = cz - 0.2},
			maxpos = {x = cx + 0.2, y = pos.y + 0.8, z = cz + 0.2},
			minvel = {x = -0.3, y = 0.5, z = -0.3},
			maxvel = {x = 0.3, y = 1.2, z = 0.3},
			minexptime = 0.4,
			maxexptime = 1.0,
			minsize = 1.2,
			maxsize = 2.4,
			texture = "lualore_particle_blob.png^[colorize:#444444:140",
		})
	end

	if drill.timer < DRILL_STEP_TIME then
		return
	end
	drill.timer = 0

	local support_y = math.floor(pos.y - 0.5)
	local dig_pos = {x = drill.x, y = support_y, z = drill.z}
	local node = minetest.get_node(dig_pos)
	local name = node.name

	if name == "air" then
		-- broke through into open space: escape successful
		self._lit_drill = nil
		self._lit_flee_sub = "run"
		self._lit_drill_cooldown = 2.5
		self.state = "walk"
		self:set_animation("walk")
		return
	end

	local def = minetest.registered_nodes[name]
	local can_dig = def and def.diggable
		and (not def.liquidtype or def.liquidtype == "none")
		and not minetest.is_protected(dig_pos, "")
	if not can_dig then
		-- bedrock / protected ground: give up and run instead
		self._lit_drill = nil
		self._lit_flee_sub = "run"
		self._lit_drill_cooldown = 3.0
		self.state = "walk"
		self:set_animation("walk")
		bolt_burst({x = cx, y = support_y + 0.5, z = cz}, false)
		return
	end

	minetest.remove_node(dig_pos)
	drill.depth = (drill.depth or 0) + 1

	-- particles in the colour of the removed node
	local tiles = def.tiles
	local tex = tiles and tiles[1] or "lualore_particle_x.png"
	if type(tex) == "table" then
		tex = tex[1]
	end
	minetest.add_particlespawner({
		amount = 10,
		time = 0.5,
		minpos = {x = drill.x + 0.1, y = support_y + 0.1, z = drill.z + 0.1},
		maxpos = {x = drill.x + 0.9, y = support_y + 0.9, z = drill.z + 0.9},
		minvel = {x = -0.5, y = 0.3, z = -0.5},
		maxvel = {x = 0.5, y = 1.2, z = 0.5},
		minexptime = 0.3,
		maxexptime = 0.7,
		minsize = 1,
		maxsize = 2,
		texture = tostring(tex),
	})

	if drill.depth >= DRILL_MAX_DEPTH then
		-- dug far enough for one attempt; keep running
		self._lit_drill = nil
		self._lit_flee_sub = "run"
		self._lit_drill_cooldown = 3.0
		self.state = "walk"
		self:set_animation("walk")
	end
end

local function flee_step(self, dtime, target, tpos, mpos, dist)
	-- calm back down when the danger is gone
	if dist > 20 then
		self._lit_calm_timer = (self._lit_calm_timer or 0) + dtime
		if self._lit_calm_timer > 4 then
			return_to_wander(self)
			return
		end
	else
		self._lit_calm_timer = 0
	end

	self.walk_velocity = RUN_SPEED

	self._lit_drill_cooldown = math.max(0, (self._lit_drill_cooldown or 0) - dtime)

	-- currently burrowing through the floor
	if self._lit_drill then
		drill_step(self, dtime)
		return
	end

	-- run away from the player
	local dir = vector.direction(tpos, mpos)
	dir.y = 0
	local has_dir = vector.length(dir) > 0.001
	if has_dir then
		dir = vector.normalize(dir)
	end

	local vel = self.object:get_velocity() or {x = 0, y = 0, z = 0}
	local move = {x = 0, y = vel.y, z = 0}
	if has_dir then
		move.x = dir.x * RUN_SPEED
		move.z = dir.z * RUN_SPEED

		-- cornered or pursued closely for a while?
		local cpos = {x = mpos.x, y = mpos.y, z = mpos.z}
		local last = self._lit_last_pos
		if last and vector.distance(cpos, last) < 0.08 then
			self._lit_stuck = (self._lit_stuck or 0) + dtime
		else
			self._lit_stuck = 0
		end
		self._lit_last_pos = cpos

		if dist < 6 then
			self._lit_close_timer = (self._lit_close_timer or 0) + dtime
		else
			self._lit_close_timer = 0
		end

		if (self._lit_stuck or 0) > 0.7 or (self._lit_close_timer or 0) > 2.2 then
			if start_drill(self) then
				return
			end
			-- no way down here: jump and keep running
			self._lit_drill_cooldown = 3.0
			self._lit_close_timer = 0
			self._lit_stuck = 0
			move.y = 4.6
		end
	end

	self.object:set_velocity(move)
	if has_dir then
		self.object:set_yaw(minetest.dir_to_yaw(dir))
		self.state = "walk"
		self:set_animation("walk")
	else
		self.state = "stand"
		self:set_animation("stand")
	end
end

local function wander_step(self, dtime)
	local vel = self.object:get_velocity() or {x = 0, y = 0, z = 0}

	-- pick a new wander direction (or rest for a bit) every few seconds
	self._lit_wander_timer = (self._lit_wander_timer or 0) - dtime
	if self._lit_wander_timer <= 0 then
		self._lit_wander_timer = math.random(5, 11)
		if math.random() < 0.6 then
			local angle = math.random() * math.pi * 2
			self._lit_wander_dir = {x = math.sin(angle), z = math.cos(angle)}
			self._lit_wander_time = math.random(2, 5)
		else
			self._lit_wander_dir = nil
			self._lit_wander_time = math.random(2, 4)
		end
	end

	if self._lit_wander_dir then
		self._lit_wander_time = (self._lit_wander_time or 0) - dtime
		if self._lit_wander_time > 0 then
			local dir = self._lit_wander_dir
			self.object:set_velocity({
				x = dir.x * WANDER_SPEED,
				y = vel.y,
				z = dir.z * WANDER_SPEED,
			})
			self.object:set_yaw(minetest.dir_to_yaw(dir))
			self.state = "walk"
			self:set_animation("walk")
			return
		end
		self._lit_wander_dir = nil
	end

	-- rest in place
	self.object:set_velocity({x = 0, y = vel.y, z = 0})
	self.state = "stand"
	self:set_animation("stand")
end

-- ------------------------------------------------------------------
-- Mob registration
-- ------------------------------------------------------------------

mobs:register_mob("lualore:lit", {
	type = "animal",
	passive = true,
	hp_min = 16,
	hp_max = 24,
	armor = 50,
	blood_amount = 0, -- it is made of flame, not meat
	-- Twice as tall as the original build (matches the doubled model);
	-- the width stays narrow so the drill-down escape still fits the
	-- 1x1 shaft it digs.
	collisionbox = {-0.3, 0, -0.3, 0.3, 2.0, 0.3},
	visual = "mesh",
	mesh = "lit_combined.gltf",
	textures = {"lit.png"},
	visual_size = {x = VISUAL_SIZE, y = VISUAL_SIZE},
	glow = 10,
	makes_footstep_sound = false,
	sounds = {},
	stepheight = 1.1,
	walk_velocity = WANDER_SPEED,
	run_velocity = RUN_SPEED,
	jump_height = 0, -- movement and hopping are fully handled in do_custom
	floats = 1,
	water_damage = 0,
	lava_damage = 0,
	fire_damage = 0,
	light_damage = 0,
	fear_height = 0,
	view_range = 16,
	attack_npcs = false,
	attack_animals = false,
	-- keep mobs_redo's own state machine quiet; the AI below drives
	-- movement, turning and animation itself
	walk_chance = 0,
	stand_chance = 0,
	randomly_turn = false,
	drops = {
		{name = "default:torch", chance = 1, min = 1, max = 2},
		{name = "default:coal_lump", chance = 1, min = 1, max = 2},
		{name = "default:flint", chance = 1, min = 1, max = 1},
	},
	animation = {
		speed_normal = 1,
		stand_start = ANIM.idle[1],
		stand_end = ANIM.idle[2],
		stand_speed = 1,
		walk_start = ANIM.walk[1],
		walk_end = ANIM.walk[2],
		walk_speed = 1,
		run_start = ANIM.walk[1],
		run_end = ANIM.walk[2],
		run_speed = 1,
		punch_start = ANIM.mine[1],
		punch_end = ANIM.mine[2],
		punch_speed = 1,
	},

	-- do_punch is called by mobs_redo whenever the mob is damaged and is
	-- the reliable place to react to being attacked
	do_punch = function(self, hitter, tflp, tool_caps, dir, damage)
		lit_on_attacked(self, hitter)
	end,

	on_die = function(self, pos)
		-- take the glow along; returning false lets mobs_redo finish the
		-- normal removal (item drops already happened)
		clear_lit_light(self)
		return false
	end,

	on_deactivate = function(self, removal)
		clear_lit_light(self)
	end,

	do_custom = function(self, dtime)
		if not self.object then
			return
		end

		update_lit_light(self, dtime)

		-- Safety net: react to being hurt even if no punch hook fired
		-- (e.g. arrows or environmental damage dealt by a nearby player).
		local hp = self.health or 0
		if self._lit_last_hp and hp < self._lit_last_hp then
			local mpos = self.object:get_pos()
			if mpos then
				for _, obj in ipairs(minetest.get_objects_inside_radius(mpos, 8)) do
					local opos = obj:get_pos()
					if obj:is_player() and opos
							and minetest.line_of_sight(
								{x = mpos.x, y = mpos.y + 1.6, z = mpos.z},
								{x = opos.x, y = opos.y + 1.2, z = opos.z}) then
						lit_on_attacked(self, obj)
						break
					end
				end
			end
		end
		self._lit_last_hp = hp

		if self._lit_mode == "fight" or self._lit_mode == "flee" then
			local target, tpos, mpos, dist = resolve_target(self)
			if not target
					or minetest.get_gametime() - (self._lit_aggro_time or 0) > 45 then
				return_to_wander(self)
				return
			end
			if self._lit_mode == "fight" then
				fight_step(self, dtime, target, tpos, mpos, dist)
			else
				flee_step(self, dtime, target, tpos, mpos, dist)
			end
			return
		end

		wander_step(self, dtime)
	end,
})

-- ------------------------------------------------------------------
-- Spawning: fairly common, in just about any cave
-- ------------------------------------------------------------------

if not mobs.custom_spawn_lualore then
	mobs:spawn({
		name = "lualore:lit",
		-- Broad node groups so a Lit can turn up on almost any natural
		-- underground surface in any game or biome, plus explicit cave
		-- biome floors in case those use custom groups.
		nodes = {
			"group:stone", "group:cobble", "group:cracky",
			"group:crumbly", "group:sandstone",
			"caverealms:stone_with_moss", "caverealms:stone_with_lichen",
			"caverealms:stone_with_algae",
			"everness:mineral_cave_stone", "everness:crystal_stone",
		},
		min_light = 0,
		max_light = 12, -- any dim or torch-lit cave counts
		interval = 15,
		chance = 500,
		active_object_count = 3,
		min_height = -31000, -- any depth
		max_height = -8,      -- shallow tunnels included
	})
end

mobs:register_egg("lualore:lit", S("Lit"), "alit.png", 0)

mobs:alias_mob("lualore:lit", "lualore:lit") -- compatibility
