--[[
	Leftovers from the obsidian door trials, which sky portals replaced.

	The doors' shrines and mirror islands are ordinary blocks and stay in
	worlds that already have them, but nothing makes them work any more. A
	player who logged out standing on a mirror island - y ~300, hundreds of
	nodes from home, the way back through a door that no longer opens -
	would be stranded. On joining, such a player is sent back to the shrine
	they came through, using the records the old system left in mod storage.

	Nothing else reads those records. Once no world in use still has players
	parked on a mirror island, this file can be deleted.
]]

local S = minetest.get_translator("lualore")
local storage = minetest.get_mod_storage()

local function load(key)
	local data = storage:get_string(key)
	local parsed = data ~= "" and minetest.deserialize(data) or nil
	return type(parsed) == "table" and parsed or {}
end

-- the old island was a 16-node disc; allow for wandering to its rim
local ISLAND_REACH = 24

minetest.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	minetest.after(1, function()
		local who = minetest.get_player_by_name(name)
		if not who then
			return
		end
		local doors = load("obsidian_doors")
		if next(doors) == nil then
			return
		end
		local p = who:get_pos()
		for _, rec in pairs(doors) do
			local island = type(rec) == "table" and rec.island
			if island and island.x
					and math.hypot(p.x - island.x, p.z - island.z) <= ISLAND_REACH
					and math.abs(p.y - island.y) <= ISLAND_REACH then
				-- the shrine this player came through, else this island's own
				local home = doors[load("obsidian_door_returns")[name] or ""] or rec
				local target = home.spawn
					or {x = home.x, y = home.y + 2, z = home.z}
				who:set_pos(target)
				minetest.chat_send_player(name, S("The mirror island has " ..
					"gone quiet. You are returned to the shrine you came from."))
				minetest.log("action", "[lualore] Returned " .. name ..
					" from an old mirror island to " ..
					minetest.pos_to_string(target))
				return
			end
		end
	end)
end)
