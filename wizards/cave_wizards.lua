-- cave_wizards.lua
-- Boss wizard entities for cave castle
-- Four wizards spawn together as a boss fight

local S = minetest.get_translator("lualore")

-- Cave castle placement, statue detection and wizard spawn bookkeeping all
-- live in cavebuildings.lua; this file only defines the wizard mobs and
-- their commands.

--------------------------------------------------------------------
-- WIZARD ENTITY DEFINITIONS
--------------------------------------------------------------------

local wizard_types = {
	{
		name = "redwizard",
		texture = "redwizard.png",
		armor_item = "3d_armor:chestplate_bronze",
		wand_item = "lualore:red_wand",
		do_custom = lualore.wizard_magic.red_do_custom,
		drops = {
			{name = "default:mese_crystal", chance = 1, min = 2, max = 5},
			{name = "default:diamond", chance = 1, min = 1, max = 3},
			{name = "lualore:red_wand", chance = 1, min = 1, max = 1}
		}
	},
	{
		name = "whitewizard",
		texture = "whitewizard.png",
		armor_item = "3d_armor:chestplate_steel",
		wand_item = "lualore:white_wand",
		do_custom = lualore.wizard_magic.white_do_custom,
		drops = {
			{name = "default:mese_crystal", chance = 1, min = 2, max = 5},
			{name = "default:diamond", chance = 1, min = 1, max = 3},
			{name = "lualore:white_wand", chance = 1, min = 1, max = 1}
		}
	},
	{
		name = "goldwizard",
		texture = "goldwizard.png",
		armor_item = "3d_armor:chestplate_gold",
		wand_item = "lualore:gold_wand",
		do_custom = lualore.wizard_magic.gold_do_custom,
		drops = {
			{name = "default:mese_crystal", chance = 1, min = 2, max = 5},
			{name = "default:diamond", chance = 1, min = 1, max = 3},
			{name = "default:gold_lump", chance = 1, min = 3, max = 7},
			{name = "lualore:gold_wand", chance = 1, min = 1, max = 1}
		}
	},
	{
		name = "blackwizard",
		texture = "blackwizard.png",
		armor_item = "3d_armor:chestplate_mithril",
		wand_item = "lualore:black_wand",
		do_custom = lualore.wizard_magic.black_do_custom,
		drops = {
			{name = "default:mese_crystal", chance = 1, min = 2, max = 5},
			{name = "default:diamond", chance = 1, min = 1, max = 3},
			{name = "default:obsidian", chance = 1, min = 2, max = 5},
			{name = "lualore:black_wand", chance = 1, min = 1, max = 1}
		}
	}
}

-- Helper function to update wizard armor visual based on HP
local function update_wizard_armor(self, wizard_texture, armor_item)
	if not self or not self.object then return end

	-- Calculate armor visibility based on HP percentage
	local hp = self.health or 0
	local max_hp = self.hp_max or 150
	local hp_percent = hp / max_hp

	-- Show armor only if HP is above 30% (armor "breaks" when wizard is low health)
	-- the armour overlay is 3d_armor's own texture, so only with 3d_armor
	if hp_percent > 0.3 and armor_item and minetest.registered_items[armor_item] then
		-- Get armor texture from item name
		-- Format: 3d_armor:chestplate_type -> 3d_armor_chestplate_type.png
		local armor_texture = armor_item:gsub(":", "_") .. ".png"

		-- Combine wizard texture with armor overlay
		self.object:set_properties({
			textures = {wizard_texture .. "^" .. armor_texture},
			wield_item = self.wizard_wand or ""
		})
	else
		-- No armor - just base texture (armor broke or depleted)
		self.object:set_properties({
			textures = {wizard_texture},
			wield_item = self.wizard_wand or ""
		})
	end
end

-- Register each wizard as a mob
for _, wizard in ipairs(wizard_types) do
	-- Capture wizard values in local variables to avoid closure issues
	local wizard_name = wizard.name
	local wizard_texture = wizard.texture
	local wizard_armor = wizard.armor_item
	local wizard_wand = wizard.wand_item
	local wizard_do_custom = wizard.do_custom
	local wizard_drops = wizard.drops

	local mob_name = "lualore:" .. wizard_name

	mobs:register_mob(mob_name, {
		type = "monster",
		passive = false,
		damage = 3,
		attack_type = "dogfight",
		attacks_monsters = false,
		attack_npcs = true,
		attack_players = true,
		owner_loyal = false,
		pathfinding = true,
		hp_min = 100,
		hp_max = 150,
		armor = 150,
		reach = 1,
		collisionbox = {-0.35, 0.0, -0.35, 0.35, 1.8, 0.35},
		stepheight = 1.1,
		visual = "mesh",
		mesh = "character.b3d",
		textures = {{wizard_texture}},
		visual_size = {x=1.1, y=1.1},
		makes_footstep_sound = true,
		sounds = {},
		walk_velocity = 1.5,
		walk_chance = 30,
		run_velocity = 3.5,
		jump = true,
		drops = wizard_drops,
		water_damage = 0,
		lava_damage = 4,
		light_damage = 0,
		follow = {},
		view_range = 20,
		fear_height = 0,
		wield_item = wizard_wand,
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
			-- Store wizard texture and armor info using local captured variables
			self.wizard_base_texture = wizard_texture
			self.wizard_armor_item = wizard_armor
			self.wizard_wand = wizard_wand

			-- Initialize armor visual
			update_wizard_armor(self, wizard_texture, wizard_armor)

			-- Set wield_item using multiple methods to ensure it works
			if wizard_wand then
				-- Method 1: Set directly on entity (mobs_redo way)
				self.wield_item = wizard_wand

				-- Method 2: Set via properties
				self.object:set_properties({
					wield_item = wizard_wand
				})

				minetest.log("action", "[lualore] Set wield_item for " .. wizard_name .. " to " .. wizard_wand)

				-- Also set with delay to ensure it sticks
				minetest.after(0.1, function()
					if self and self.object then
						self.wield_item = wizard_wand
						self.object:set_properties({
							wield_item = wizard_wand
						})
					end
				end)
			end
		end,

		on_punch = function(self, hitter, tflp, tool_capabilities, dir)
			-- Call the default on_punch behavior first
			if self.object then
				-- Update armor visual after taking damage
				minetest.after(0.1, function()
					if self and self.object then
						update_wizard_armor(self, wizard_texture, wizard_armor)
					end
				end)
			end
		end,

		do_custom = function(self, dtime)
			local success, err = pcall(function()
				-- Ensure wand is set
				if not self.wizard_wand then
					self.wizard_wand = wizard_wand
				end

				-- Force wand to be visible always using both methods
				if self.wizard_wand then
					-- Set both ways to maximize compatibility
					self.wield_item = self.wizard_wand
					self.object:set_properties({
						wield_item = self.wizard_wand
					})
				end

				-- Always try to cast spells first
				wizard_do_custom(self, dtime)

				-- Periodically update armor visual (every 2 seconds)
				if not self.armor_update_timer then
					self.armor_update_timer = 0
				end

				self.armor_update_timer = self.armor_update_timer + dtime
				if self.armor_update_timer >= 2 then
					self.armor_update_timer = 0
					update_wizard_armor(self, wizard_texture, wizard_armor)
				end

				-- Keep distance from target
				if self.attack then
					local pos = self.object:get_pos()
					local target_pos = self.attack:get_pos()

					if pos and target_pos then
						local distance = vector.distance(pos, target_pos)

						-- If too close, back away
						if distance < 6 then
							local direction = vector.direction(target_pos, pos)
							local velocity = vector.multiply(direction, 2)
							self.object:set_velocity(velocity)
						elseif distance > 18 then
							-- If too far, move closer slowly
							local direction = vector.direction(pos, target_pos)
							local velocity = vector.multiply(direction, 1)
							self.object:set_velocity(velocity)
						end
					end
				end
			end)
			if not success then
				minetest.log("warning", "[lualore] wizard do_custom error: " .. tostring(err))
			end
		end,

		on_die = function(self, pos)
			if self.object then
				-- Death particles
				minetest.add_particlespawner({
					amount = 100,
					time = 1,
					minpos = {x = pos.x - 0.5, y = pos.y, z = pos.z - 0.5},
					maxpos = {x = pos.x + 0.5, y = pos.y + 2, z = pos.z + 0.5},
					minvel = {x = -2, y = 0, z = -2},
					maxvel = {x = 2, y = 3, z = 2},
					minacc = {x = 0, y = -5, z = 0},
					maxacc = {x = 0, y = -5, z = 0},
					minexptime = 0.5,
					maxexptime = 2,
					minsize = 1,
					maxsize = 3,
					collisiondetection = false,
					texture = "default_cloud.png^[colorize:purple:200",
					glow = 14,
				})

				self.object:remove()
			end
			return true
		end,
	})

	-- Register spawn egg
	local display_name = wizard_name:gsub("^%l", string.upper)
	mobs:register_egg(mob_name,
		S(display_name),
		wizard_texture)
end

--------------------------------------------------------------------
-- WIZARD GROUP SPAWNING
--------------------------------------------------------------------
-- Cave castle placement, statue detection and the spawn bookkeeping all
-- live in cavebuildings.lua. These thin wrappers keep the chat commands
-- below working.

local function spawn_wizard_boss_group(pos)
	if not lualore.spawn_wizards_at_position then
		return 0
	end
	return lualore.spawn_wizards_at_position(pos)
end

-- Chat command to manually spawn wizard boss group (for testing)
minetest.register_chatcommand("spawn_wizards", {
	params = "",
	description = "Spawn the wizard boss group near you",
	privs = {give = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then return false, "Player not found" end

		local pos = player:get_pos()

		-- Log attempt
		minetest.log("action", "[lualore] " .. name .. " attempting to spawn wizard boss group at " .. minetest.pos_to_string(pos))

		local spawned = spawn_wizard_boss_group(pos)

		if spawned > 0 then
			return true, string.format("Spawned %d/4 wizards!", spawned)
		end
		return false, "Failed to spawn wizard boss group - check debug.txt for details"
	end,
})

-- Alternative simpler command that spawns individual wizards
minetest.register_chatcommand("spawn_wizard", {
	params = "<wizard_type>",
	description = "Spawn a single wizard (red, white, gold, or black)",
	privs = {give = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then return false, "Player not found" end

		local wizard_map = {
			red = "redwizard",
			white = "whitewizard",
			gold = "goldwizard",
			black = "blackwizard"
		}

		local wizard_name = wizard_map[param:lower()]
		if not wizard_name then
			return false, "Invalid wizard type. Use: red, white, gold, or black"
		end

		local pos = player:get_pos()
		pos.y = pos.y + 1

		local obj = minetest.add_entity(pos, "lualore:" .. wizard_name)
		if obj then
			local ent = obj:get_luaentity()
			if ent then
				-- Keep parity with the castle group: wizards survive chunk unloads
				ent.tamed = true
				ent.lifetimer = 20000
				obj:set_properties({static_save = true})
			end
			return true, wizard_name .. " spawned!"
		else
			return false, "Failed to spawn " .. wizard_name
		end
	end,
})

-- Spawn wizards at nearest statue
minetest.register_chatcommand("spawn_wizards_at_statue", {
	params = "<radius>",
	description = "Spawn wizard boss group at nearest statue (default radius: 100)",
	privs = {give = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then return false, "Player not found" end

		local pos = player:get_pos()
		local radius = tonumber(param) or 100

		local statues = minetest.find_nodes_in_area(
			{x = pos.x - radius, y = pos.y - radius, z = pos.z - radius},
			{x = pos.x + radius, y = pos.y + radius, z = pos.z + radius},
			{"caverealms:dm_statue"}
		)

		if #statues == 0 then
			return false, "No statues found within " .. radius .. " nodes"
		end

		local statue_pos = statues[1]
		local min_dist = vector.distance(pos, statue_pos)
		for _, candidate in ipairs(statues) do
			local dist = vector.distance(pos, candidate)
			if dist < min_dist then
				min_dist = dist
				statue_pos = candidate
			end
		end

		local spawned = lualore.spawn_wizards_around_statue(statue_pos, {unseal = true})
		if spawned > 0 then
			return true, string.format("Spawned %d/4 wizards at statue %s", spawned,
				minetest.pos_to_string(statue_pos))
		end
		return false, "Failed to spawn wizard boss group at statue"
	end,
})

print(S("[MOD] Lualore - Cave wizards loaded"))
