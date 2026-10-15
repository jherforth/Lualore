local S = minetest.get_translator("lualore")

local function is_open(pos)
	local name = minetest.get_node(pos).name
	return name == "air" or minetest.get_item_group(name, "liquid") > 0
end

-- Somewhere a valkyrie fits (two nodes of open space) near `offset` from
-- the chest. A chest in a cramped room used to leave the valkyrie whose
-- spot was blocked unspawned - and a fight that could never be won.
local function open_spot(chest, offset)
	local tries = {offset}
	for _, up in ipairs({1, 2, 3}) do
		tries[#tries + 1] = {x = offset.x, y = offset.y + up, z = offset.z}
	end
	for r = 1, 3 do
		for dx = -r, r do
			for dz = -r, r do
				if math.max(math.abs(dx), math.abs(dz)) == r then
					tries[#tries + 1] = {x = dx, y = 1, z = dz}
					tries[#tries + 1] = {x = dx, y = 2, z = dz}
				end
			end
		end
	end
	for _, off in ipairs(tries) do
		local p = vector.add(chest, off)
		if is_open(p) and is_open({x = p.x, y = p.y + 1, z = p.z}) then
			return p
		end
	end
	return nil
end

minetest.register_node("lualore:valkyrie_chest", {
	description = S("Valkyrie Chest"),
	tiles = {
		"lualore_chest_front.png",
		"lualore_chest_top.png",
		"lualore_chest_side.png"
	},
	drawtype = "mesh",
	mesh = "everness_chest_closed.obj",
	paramtype = "light",
	paramtype2 = "facedir",
	groups = {cracky = 2, oddly_breakable_by_hand = 2},
	is_ground_content = false,
	sounds = minetest.global_exists("default") and default.node_sound_wood_defaults(),
	light_source = 5,

	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		if not clicker or not clicker:is_player() then
			return itemstack
		end

		local meta = minetest.get_meta(pos)
		local opened = meta:get_int("opened")

		if opened == 1 then
			minetest.chat_send_player(clicker:get_player_name(), S("This chest has already been opened."))
			return itemstack
		end

		meta:set_int("opened", 1)
		meta:set_int("won", 0)

		minetest.swap_node(pos, {
			name = "lualore:valkyrie_chest_opened",
			param2 = node.param2
		})

		local valkyrie_types = {"blue", "violet", "gold", "green"}
		local spawn_offsets = {
			{x = 2, y = 1, z = 0},
			{x = -2, y = 1, z = 0},
			{x = 0, y = 1, z = 2},
			{x = 0, y = 1, z = -2}
		}

		-- The fight is tracked (valkyrie_fight.lua): leave, or lose a
		-- valkyrie, and it starts over; beat all four and the town is free.
		local fight = lualore.valkyrie_fight
		local fight_id = fight and fight.start(pos, valkyrie_types,
			clicker:get_player_name())

		for i = 1, 4 do
			minetest.after(i * 0.3, function()
				local chosen_type = valkyrie_types[i]
				local spawn_pos = open_spot(pos, spawn_offsets[i])
				local obj = spawn_pos and minetest.add_entity(spawn_pos,
					"lualore:" .. chosen_type .. "_valkyrie")
				local ent = obj and obj:get_luaentity()
				if not ent then
					-- no room for it: not one the player has to defeat
					if fight then
						fight.drop(pos, chosen_type)
					end
					minetest.log("warning", "[lualore] Valkyrie chest at " ..
						minetest.pos_to_string(pos) .. " had no room for its " ..
						chosen_type .. " valkyrie")
					return
				end
				if fight then
					fight.tag(ent, pos, fight_id, chosen_type)
				end
				minetest.add_particlespawner({
					amount = 30,
					time = 1,
					minpos = vector.subtract(spawn_pos, {x=0.5, y=0.5, z=0.5}),
					maxpos = vector.add(spawn_pos, {x=0.5, y=0.5, z=0.5}),
					minvel = {x=-1, y=0, z=-1},
					maxvel = {x=1, y=2, z=1},
					minacc = {x=0, y=-2, z=0},
					maxacc = {x=0, y=-2, z=0},
					minexptime = 0.5,
					maxexptime = 1.5,
					minsize = 1,
					maxsize = 3,
					texture = "lualore_particle_star.png",
					glow = 14,
				})
				minetest.log("action", "[lualore] Valkyrie chest spawned " .. chosen_type ..
					" valkyrie at " .. minetest.pos_to_string(spawn_pos))
			end)
		end

		minetest.after(1.5, function()
			if clicker and clicker:is_player() then
				minetest.chat_send_player(clicker:get_player_name(),
					S("The Valkyrie Chest has been opened!"))
			end
		end)

		minetest.sound_play("magic", {
			pos = pos,
			gain = 1.0,
			max_hear_distance = 32,
		}, true)

		return itemstack
	end,
})

minetest.register_node("lualore:valkyrie_chest_opened", {
	description = S("Opened Valkyrie Chest"),
	tiles = {
		"lualore_chest_front.png",
		"lualore_chest_top.png",
		"lualore_chest_side.png"
	},
	drawtype = "mesh",
	mesh = "everness_chest_opened.obj",
	paramtype = "light",
	paramtype2 = "facedir",
	groups = {cracky = 2, oddly_breakable_by_hand = 2, not_in_creative_inventory = 1},
	is_ground_content = false,
	sounds = minetest.global_exists("default") and default.node_sound_wood_defaults(),
	drop = "",
	light_source = 3,

	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		if not (clicker and clicker:is_player()) then
			return itemstack
		end
		local name = clicker:get_player_name()
		local fight = lualore.valkyrie_fight
		if fight and fight.active(pos) then
			minetest.chat_send_player(name, S("The valkyries are loose! Defeat all four."))
			return itemstack
		end
		-- no fight going: either it was won, or it was abandoned (and the
		-- chest closes now rather than waiting to be reloaded)
		if fight and fight.settle_open_chest then
			fight.settle_open_chest(pos)
		end
		if minetest.get_node(pos).name == "lualore:valkyrie_chest" then
			minetest.chat_send_player(name, S("The chest snaps shut. " ..
				"Open it again to face the valkyries."))
		else
			minetest.chat_send_player(name, S("This chest's valkyries are " ..
				"defeated, and its Sky Folk are free."))
		end
		return itemstack
	end,
})

-- ------------------------------------------------------------------
-- Chests that generated already open
-- ------------------------------------------------------------------
-- skycastle.mts has a valkyrie chest baked into it, saved in the opened
-- state, so every castle built before this generated its prize already
-- looted. This shuts those without touching one a player has actually
-- opened: opening sets `opened` in the node's metadata, and a chest
-- placed by a schematic has no metadata at all. So an opened chest that
-- does not know it was opened was never opened by anybody.
minetest.register_lbm({
	label = "Close valkyrie chests that generated open",
	name = "lualore:close_unlooted_valkyrie_chests",
	nodenames = {"lualore:valkyrie_chest_opened"},
	run_at_every_load = false,
	action = function(pos, node)
		local meta = minetest.get_meta(pos)
		if meta:get_int("opened") == 1 then
			return -- somebody earned this one
		end
		minetest.set_node(pos, {
			name = "lualore:valkyrie_chest",
			param2 = node.param2,
		})
		minetest.get_meta(pos):set_int("opened", 0)
	end,
})

minetest.log("action", "[lualore] Valkyrie chest system loaded")
