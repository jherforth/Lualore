local S = minetest.get_translator("lualore")

lualore.sky_liberation = {}

local function spawn_liberation_particles(pos)
	minetest.add_particlespawner({
		amount = 100,
		time = 2,
		minpos = vector.subtract(pos, {x=0.5, y=0, z=0.5}),
		maxpos = vector.add(pos, {x=0.5, y=2.0, z=0.5}),
		minvel = {x=-2, y=1, z=-2},
		maxvel = {x=2, y=4, z=2},
		minacc = {x=0, y=-0.5, z=0},
		maxacc = {x=0, y=-0.5, z=0},
		minexptime = 1.5,
		maxexptime = 3.0,
		minsize = 1.5,
		maxsize = 3.0,
		texture = "lualore_particle_star.png^[colorize:#FFFF00:150",
		glow = 14
	})

	minetest.add_particlespawner({
		amount = 50,
		time = 2,
		minpos = vector.subtract(pos, {x=0.5, y=0, z=0.5}),
		maxpos = vector.add(pos, {x=0.5, y=2.0, z=0.5}),
		minvel = {x=-1, y=0.5, z=-1},
		maxvel = {x=1, y=2, z=1},
		minacc = {x=0, y=0, z=0},
		maxacc = {x=0, y=0, z=0},
		minexptime = 2.0,
		maxexptime = 4.0,
		minsize = 2.0,
		maxsize = 4.0,
		texture = "lualore_particle_circle.png^[colorize:#FFFFFF:200",
		glow = 12
	})
end

-- quiet: no particles and no log line, for Sky Folk who wake up (or
-- arrive) in a town that was freed while they were not loaded.
local function free_sky_folk(sky_folk_entity, quiet)
	if not sky_folk_entity or not sky_folk_entity.object then
		return false
	end

	if sky_folk_entity.liberated then
		return false
	end

	sky_folk_entity.type = "npc"
	sky_folk_entity.passive = true
	sky_folk_entity.attack_players = false
	sky_folk_entity.attack = nil
	sky_folk_entity.liberated = true

	sky_folk_entity.base_texture = {"sky_folk_freed.png"}
	sky_folk_entity.textures = {"sky_folk_freed.png"}

	sky_folk_entity.object:set_properties({
		textures = {"sky_folk_freed.png"}
	})

	minetest.after(0.1, function()
		if sky_folk_entity and sky_folk_entity.object then
			sky_folk_entity.object:set_properties({
				textures = {"sky_folk_freed.png"}
			})
		end
	end)

	local pos = sky_folk_entity.object:get_pos()
	if pos and not quiet then
		spawn_liberation_particles(pos)
	end

	if lualore.sky_folk_mood then
		lualore.sky_folk_mood.init_npc(sky_folk_entity)
	end

	if not quiet and pos then
		minetest.log("action", "[lualore] Sky Folk liberated at " .. minetest.pos_to_string(pos))
	end
	return true
end

lualore.sky_liberation.free = free_sky_folk

function lualore.sky_liberation.check_and_liberate(death_pos)
	local search_radius = 100

	local objects = minetest.get_objects_inside_radius(death_pos, search_radius)

	local valkyries_found = false
	local sky_folk_to_free = {}

	for _, obj in ipairs(objects) do
		local ent = obj:get_luaentity()
		if ent and ent.name then
			if ent.name:match("lualore:.*_valkyrie") then
				valkyries_found = true
				break
			elseif ent.name == "lualore:sky_folk" and not ent.liberated then
				table.insert(sky_folk_to_free, ent)
			end
		end
	end

	if not valkyries_found and #sky_folk_to_free > 0 then
		minetest.log("action", "[lualore] All valkyries defeated! Liberating " .. #sky_folk_to_free .. " Sky Folk")

		for _, sky_folk in ipairs(sky_folk_to_free) do
			free_sky_folk(sky_folk)
		end

		-- Only loaded Sky Folk were freed just now; a town is wider than
		-- the area Luanti keeps loaded. Mark the town itself free, so the
		-- rest are freed as they wake (lualore.sky_town).
		if lualore.sky_town and lualore.sky_town.mark_freed then
			lualore.sky_town.mark_freed(death_pos)
		end

		local players = minetest.get_connected_players()
		for _, player in ipairs(players) do
			local player_pos = player:get_pos()
			if player_pos and vector.distance(player_pos, death_pos) <= search_radius then
				minetest.chat_send_player(player:get_player_name(),
					S("The Valkyries have been defeated! The Sky Folk are free!"))
			end
		end

		return true
	end

	return false
end

function lualore.sky_liberation.serialize_sky_folk_data(self)
	local data = {
		liberated = self.liberated or false
	}

	if self.liberated and lualore.sky_folk_mood then
		local mood_data = lualore.sky_folk_mood.get_staticdata_extra(self)
		for k, v in pairs(mood_data) do
			data[k] = v
		end
	end

	if self.liberated then
		if self.sf_quest then
			data.sf_quest = self.sf_quest
		end
		if self.nv_has_active_quest then
			data.nv_has_active_quest = true
		end
		if self.sf_home_pos then
			data.sf_home_pos = self.sf_home_pos
		end
	end

	return data
end

function lualore.sky_liberation.deserialize_sky_folk_data(self, data)
	if not data then return end

	if data.liberated then
		self.liberated = true
		self.type = "npc"
		self.passive = true
		self.attack_players = false
		self.attack = nil

		self.base_texture = {"sky_folk_freed.png"}
		self.textures = {"sky_folk_freed.png"}

		self.object:set_properties({
			textures = {"sky_folk_freed.png"}
		})

		minetest.after(0.1, function()
			if self and self.object then
				self.object:set_properties({
					textures = {"sky_folk_freed.png"}
				})
			end
		end)

		if lualore.sky_folk_mood then
			lualore.sky_folk_mood.on_activate_extra(self, data)
		end

		if data.sf_quest then
			self.sf_quest = data.sf_quest
		end
		if data.nv_has_active_quest then
			self.nv_has_active_quest = true
		end
		if data.sf_home_pos then
			self.sf_home_pos = data.sf_home_pos
		end

		minetest.log("action", "[lualore] Sky Folk restored as liberated")
	end
end

minetest.log("action", "[lualore] Sky Liberation system loaded")
