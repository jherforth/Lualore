local S = minetest.get_translator("lualore")

lualore.sky_folk = {}

local humming_sounds = {"skyfolk1", "skyfolk2", "skyfolk3", "skyfolk4"}

local function play_humming_sound(self)
	if not self.sound_timer then
		self.sound_timer = 0
	end

	if self.sound_timer <= 0 then
		local sound_name = humming_sounds[math.random(1, #humming_sounds)]
		local pos = self.object:get_pos()

		if pos then
			minetest.sound_play(sound_name, {
				pos = pos,
				gain = 0.2,
				max_hear_distance = 10
			})
		end

		self.sound_timer = math.random(15, 30)
	end
end

local function broadcast_damage_alert(self, pos)
	if lualore.sky_valkyries and lualore.sky_valkyries.broadcast_alert then
		lualore.sky_valkyries.broadcast_alert(pos)
	end
end

mobs:register_mob("lualore:sky_folk", {
	type = "monster",
	passive = false,
	damage = 4,
	attack_type = "dogfight",
	attacks_monsters = false,
	attack_npcs = false,
	attack_players = true,
	owner_loyal = false,
	pathfinding = true,
	hp_min = 20,
	hp_max = 30,
	armor = 50,
	reach = 1.5,
	collisionbox = {-0.35, 0.0, -0.35, 0.35, 1.8, 0.35},
	stepheight = 1.1,
	visual = "mesh",
	mesh = "character.b3d",
	textures = {{"sky_folk.png"}},
	visual_size = {x=1.0, y=1.0},
	makes_footstep_sound = true,
	sounds = {
		random = "skyfolk",
		distance = 10,
	},
	walk_velocity = 2.0,
	walk_chance = 50,
	run_velocity = 2.5,
	jump = true,
	jump_height = 3,
	drops = {
		{name = "farming:bread", chance = 1, min = 1, max = 3},
		{name = "default:feather", chance = 1, min = 1, max = 2},
		{name = "default:mese_crystal_fragment", chance = 3, min = 1, max = 1}
	},
	water_damage = 0,
	lava_damage = 4,
	light_damage = 0,
	follow = {},
	view_range = 15,
	fear_height = 3,
	-- mobs_redo deletes any monster that is not mid-attack when its area
	-- unloads ("remove_far_mobs", on by default), and unfreed Sky Folk are
	-- monsters, so a town emptied every time its players left. A lifetimer
	-- of 20000 or more is mobs_redo's own way of keeping a mob.
	lifetimer = 20000,
	animation = {
		speed_normal = 30,
		stand_start = 0,
		stand_end = 79,
		walk_start = 168,
		walk_end = 187,
		punch_start = 189,
		punch_end = 198,
		die_start = 162,
		die_end = 166,
		die_speed = 15,
		die_loop = false,
		die_rotate = true,
	},

	on_activate = function(self, staticdata, dtime_s)
		self.sound_timer = math.random(10, 20)
		self.last_hp = self.health or 20

		if staticdata and staticdata ~= "" then
			local data = minetest.deserialize(staticdata)
			if data and lualore.sky_liberation then
				lualore.sky_liberation.deserialize_sky_folk_data(self, data)
			end
		end
	end,

	get_staticdata = function(self)
		if lualore.sky_liberation then
			local data = lualore.sky_liberation.serialize_sky_folk_data(self)
			return minetest.serialize(data)
		end
		return ""
	end,

	on_rightclick = function(self, clicker)
		if not self.liberated then return end
		if not clicker or not clicker:is_player() then return end

		if lualore.sky_folk_quests then
			lualore.sky_folk_quests.show_quest_formspec(clicker, self)
		end
	end,

	on_punch = function(self, hitter, tflp, tool_capabilities, dir)
		local pos = self.object:get_pos()
		if pos then
			broadcast_damage_alert(self, pos)

			minetest.add_particlespawner({
				amount = 20,
				time = 0.5,
				minpos = vector.subtract(pos, {x=0.3, y=0.5, z=0.3}),
				maxpos = vector.add(pos, {x=0.3, y=1.5, z=0.3}),
				minvel = {x=-1, y=0, z=-1},
				maxvel = {x=1, y=2, z=1},
				minacc = {x=0, y=-0.5, z=0},
				maxacc = {x=0, y=-0.5, z=0},
				minexptime = 0.5,
				maxexptime = 1.5,
				minsize = 1,
				maxsize = 2,
				texture = "lualore_particle_x.png^[colorize:#FF0000:180",
				glow = 8
			})

			local sound_name = humming_sounds[math.random(1, #humming_sounds)]
			minetest.sound_play(sound_name, {
				pos = pos,
				gain = 0.2,
				max_hear_distance = 16
			})
		end
	end,

	do_custom = function(self, dtime)
		local success, result = pcall(function()
			-- Keep to the island, whatever is moving them (sky_folk_footing.lua).
			-- When it has just stopped or rescued one, skip mobs_redo's own
			-- movement this step, so nothing carries it on over the edge.
			if lualore.sky_folk_footing
					and lualore.sky_folk_footing.step(self, dtime) == "halted" then
				return false
			end

			-- A town is freed as a whole (sky_town_folk.lua). A Sky Folk who
			-- was not loaded when its valkyries fell, or who arrived since,
			-- finds out here. (mobs_redo never calls a mob's own on_activate,
			-- so this cannot be done on waking up.)
			if not self.liberated and lualore.sky_town and lualore.sky_liberation
					and lualore.sky_liberation.free then
				self.sf_town_timer = (self.sf_town_timer or 0) + dtime
				if self.sf_town_timer >= 5 then
					self.sf_town_timer = 0
					local here = self.object:get_pos()
					if here and lualore.sky_town.freed_at(here) then
						lualore.sky_liberation.free(self, true)
					end
				end
			end

			if self.liberated then
				if lualore.sky_folk_mood then
					lualore.sky_folk_mood.update_mood(self, dtime)
				end

				local pos = self.object:get_pos()
				if pos then
					-- Initialize spawn position (home base for wandering)
					if not self.nv_spawn_pos then
						self.nv_spawn_pos = vector.new(pos.x, pos.y, pos.z)
					end

					if not self.sf_home_pos then
						self.sf_home_pos = vector.new(pos.x, pos.y, pos.z)
					end

					-- Initialize state machine
					if not self.sf_behavior_state then
						self.sf_behavior_state = "wandering"
						self.sf_state_timer = 0
						self.sf_target_reached = false
					end

					-- Update state timer
					self.sf_state_timer = (self.sf_state_timer or 0) + dtime

					-- State durations
					local state_durations = {
						wandering = 50,
						socializing = 40,
						observing = 30,
					}

					-- Check for state transition
					local current_duration = state_durations[self.sf_behavior_state] or 50
					if self.sf_state_timer >= current_duration then
						-- Cycle to next state
						if self.sf_behavior_state == "wandering" then
							self.sf_behavior_state = "socializing"
						elseif self.sf_behavior_state == "socializing" then
							self.sf_behavior_state = "observing"
						else
							self.sf_behavior_state = "wandering"
						end
						self.sf_state_timer = 0
						self.sf_target_reached = false
					end

					local function has_ground_below(check_pos)
						local below = {x = check_pos.x, y = check_pos.y - 1, z = check_pos.z}
						local node = minetest.get_node(below)
						return node and node.name ~= "air" and node.name ~= "ignore"
					end

					-- Handle state-specific behavior
					if self.sf_behavior_state == "socializing" and not self.sf_target_reached then
						-- Look for nearby Sky Folk
						local nearby_objects = minetest.get_objects_inside_radius(pos, 15)
						local closest_sky_folk = nil
						local closest_dist = 999

						for _, obj in ipairs(nearby_objects) do
							if obj ~= self.object then
								local ent = obj:get_luaentity()
								if ent and ent.name == "lualore:sky_folk" and ent.liberated then
									local other_pos = obj:get_pos()
									if other_pos then
										local dist = vector.distance(pos, other_pos)
										if dist > 3 and dist < closest_dist then
											closest_dist = dist
											closest_sky_folk = other_pos
										end
									end
								end
							end
						end

						-- Move towards other Sky Folk
						if closest_sky_folk then
							if closest_dist <= 4 then
								-- Close enough, stop moving
								self.sf_target_reached = true
								self.object:set_velocity({x = 0, y = self.object:get_velocity().y, z = 0})
							else
								local dir = vector.direction(pos, closest_sky_folk)
								self.object:set_velocity({
									x = dir.x * 1.5,
									y = self.object:get_velocity().y,
									z = dir.z * 1.5,
								})
							end
						end
					elseif self.sf_behavior_state == "observing" then
						-- Stand still
						self.object:set_velocity({x = 0, y = self.object:get_velocity().y, z = 0})
					end

					-- Edges are handled by sky_folk_footing.lua at the top of do_custom.

					if has_ground_below(pos) then
						self.sf_home_pos = vector.new(pos.x, pos.y, pos.z)
					end
				end

				return
			end

			if not self.sound_timer then
				self.sound_timer = 0
			end

			self.sound_timer = self.sound_timer - dtime

			if self.sound_timer <= 0 then
				play_humming_sound(self)
			end

			local current_hp = self.health or 20
			local max_hp = self.hp_max or 30
			local hp_percent = current_hp / max_hp

			if hp_percent < 0.5 and not self.alert_sent then
				local pos = self.object:get_pos()
				if pos then
					broadcast_damage_alert(self, pos)
					self.alert_sent = true
				end
			end

			local pos = self.object:get_pos()
			if pos then
				local time_of_day = minetest.get_timeofday()

				if time_of_day > 0.75 or time_of_day < 0.25 then
					local nearby_objects = minetest.get_objects_inside_radius(pos, 10)
					for _, obj in ipairs(nearby_objects) do
						local node_name = minetest.get_node(obj:get_pos()).name
						if node_name and (node_name:match("door") or node_name:match("hut")) then
							local dir = vector.direction(pos, obj:get_pos())
							self.object:set_velocity(vector.multiply(dir, 2))
							break
						end
					end
				end
			end
		end)

		if not success then
			minetest.log("error", "[lualore] Sky Folk do_custom error: " .. tostring(result))
			return
		end
		return result
	end,

	on_die = function(self, pos)
		if lualore.sky_folk_mood then
			lualore.sky_folk_mood.cleanup_indicator(self)
		end
	end,
})

minetest.register_chatcommand("spawn_skyfolk", {
	params = "",
	description = S("Spawn a Sky Folk NPC"),
	privs = {give = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, S("Player not found")
		end

		local pos = player:get_pos()
		local spawn_pos = vector.add(pos, {x=math.random(-3, 3), y=1, z=math.random(-3, 3)})

		local obj = minetest.add_entity(spawn_pos, "lualore:sky_folk")

		if obj then
			return true, S("Spawned Sky Folk")
		else
			return false, S("Failed to spawn Sky Folk")
		end
	end
})

minetest.log("action", "[lualore] Sky Folk system loaded")
