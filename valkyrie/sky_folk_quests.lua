-- sky_folk_quests.lua
local S = minetest.get_translator("lualore")

lualore.sky_folk_quests = {}

local sky_folk_sounds = {"skyfolk1", "skyfolk2", "skyfolk3", "skyfolk4"}

--------------------------------------------------------------------
-- QUEST POOL
-- Each quest: name, description, required_items (exactly 3),
--             rewards (table of ItemStacks given on fulfillment)
--------------------------------------------------------------------

local quest_pool = {
	{
		-- The way to the wizards' castles: a crystal set on a mese portal's
		-- roof turns it black (portal/sky_portal.lua). It is offered by
		-- freed Sky Folk because wizard castles are deep and hard to find.
		name = "The Shadow Gate",
		description = "Far below the world, the wizards keep their castles in the dark. Set this crystal on the roof of a mese portal and the portal will burn black and carry you down to them. Bring me what I ask and it is yours.",
		required_items = {
			{name = "default:obsidian",            count = 6},
			{name = "default:mese_crystal",        count = 2},
			{name = "default:gold_ingot",          count = 3},
		},
		reward_sets = {
			{ {name = "everness:crystal_purple",   count = 1} },
			{ {name = "everness:crystal_orange",   count = 1} },
			{ {name = "everness:crystal_cyan",     count = 1} },
		},
	},
	{
		name = "The Wanderer's Debt",
		description = "I have traveled far and lost my provisions. Bring me sustenance and I shall part with something precious.",
		required_items = {
			{name = "farming:bread",               count = 4},
			{name = "default:apple",               count = 6},
			{name = "farming:string",              count = 3},
		},
		reward_sets = {
			{ {name = "3d_armor:chestplate_bronze",  count = 1} },
			{ {name = "3d_armor:helmet_bronze",      count = 1}, {name = "default:gold_ingot", count = 3} },
			{ {name = "3d_armor:boots_bronze",       count = 1}, {name = "3d_armor:leggings_bronze", count = 1} },
		},
	},
	{
		name = "Forge of the Sky",
		description = "The forges of the sky realm require rare earthly metals. Gather them and I will reward you with something forged in starlight.",
		required_items = {
			{name = "default:steel_ingot",         count = 5},
			{name = "default:bronze_ingot",        count = 3},
			{name = "default:coal_lump",           count = 8},
		},
		reward_sets = {
			{ {name = "3d_armor:chestplate_steel",   count = 1} },
			{ {name = "3d_armor:helmet_steel",       count = 1}, {name = "3d_armor:boots_steel", count = 1} },
			{ {name = "default:diamond",             count = 2}, {name = "3d_armor:leggings_steel", count = 1} },
		},
	},
	{
		name = "The Crystal Accord",
		description = "Ancient sky contracts demand crystals as payment. Bring me what I ask and ancient power shall be yours.",
		required_items = {
			{name = "default:mese_crystal",        count = 2},
			{name = "default:mese_crystal_fragment", count = 5},
			{name = "default:obsidian",            count = 4},
		},
		reward_sets = {
			{ {name = "3d_armor:chestplate_gold",    count = 1} },
			{ {name = "3d_armor:helmet_gold",        count = 1}, {name = "3d_armor:leggings_gold", count = 1} },
			{ {name = "default:mese_sword",          count = 1} },
		},
	},
	{
		name = "The Ice Ritual",
		description = "A ritual demands the cold gifts of the arctic. Provide them and my gratitude will be armored in gold.",
		required_items = {
			{name = "default:ice",                 count = 10},
			{name = "default:snowball",            count = 8},
			{name = "default:flint",               count = 5},
		},
		reward_sets = {
			{ {name = "3d_armor:chestplate_gold",    count = 1} },
			{ {name = "3d_armor:boots_gold",         count = 1}, {name = "default:gold_ingot", count = 5} },
			{ {name = "3d_armor:helmet_gold",        count = 1}, {name = "3d_armor:leggings_bronze", count = 1} },
		},
	},
	{
		name = "Echoes of the Deep Jungle",
		description = "The jungle holds secrets the sky folk long for. Bring me its essence and receive a weapon worthy of legend.",
		required_items = {
			{name = "default:junglewood",          count = 8},
			{name = "default:vine",                count = 5},
			{name = "default:obsidian",            count = 3},
		},
		reward_sets = {
			{ {name = "default:diamond_sword",       count = 1} },
			{ {name = "default:mese_sword",          count = 1}, {name = "default:mese_crystal", count = 1} },
			{ {name = "default:diamond_sword",       count = 1}, {name = "default:diamond", count = 1} },
		},
	},
	{
		name = "The Golden Offering",
		description = "Gold gleams like captured sunlight — a worthy tribute to one of the sky. Offer enough and I shall match your generosity.",
		required_items = {
			{name = "default:gold_ingot",          count = 5},
			{name = "default:gold_lump",           count = 4},
			{name = "default:diamond",             count = 1},
		},
		reward_sets = {
			{ {name = "3d_armor:chestplate_gold",    count = 1}, {name = "3d_armor:helmet_gold", count = 1} },
			{ {name = "3d_armor:leggings_gold",      count = 1}, {name = "3d_armor:boots_gold",  count = 1} },
			{ {name = "default:diamond_sword",       count = 1}, {name = "default:gold_ingot",   count = 8} },
		},
	},
	{
		name = "Mithril Pact",
		description = "I carry knowledge of mithril crafting, but I lack the earthly components to begin. Help me and I shall share the fruits of the work.",
		required_items = {
			{name = "default:steel_ingot",         count = 8},
			{name = "default:mese_crystal",        count = 3},
			{name = "default:diamond",             count = 2},
		},
		reward_sets = {
			{ {name = "3d_armor:chestplate_mithril", count = 1} },
			{ {name = "3d_armor:helmet_mithril",     count = 1}, {name = "3d_armor:boots_mithril", count = 1} },
			{ {name = "3d_armor:leggings_mithril",   count = 1} },
		},
	},
	{
		name = "The Fisher's Boon",
		description = "The sky rivers speak of abundance. Bring gifts of the water lands and walk away with something no smith could easily forge.",
		required_items = {
			{name = "default:clay_lump",           count = 6},
			{name = "default:papyrus",             count = 5},
			{name = "farming:string",              count = 4},
		},
		reward_sets = {
			{ {name = "3d_armor:helmet_steel",       count = 1}, {name = "default:steel_sword", count = 1} },
			{ {name = "3d_armor:chestplate_bronze",  count = 1}, {name = "default:bronze_ingot", count = 5} },
			{ {name = "default:mese_sword",          count = 1} },
		},
	},
	{
		name = "Desert Blood Debt",
		description = "The desert took something precious from my kin. With earthly gold and desert stone I will settle the debt — and gift you for helping.",
		required_items = {
			{name = "default:gold_lump",           count = 5},
			{name = "default:desert_stone",        count = 10},
			{name = "default:cactus",              count = 6},
		},
		reward_sets = {
			{ {name = "3d_armor:chestplate_gold",    count = 1} },
			{ {name = "3d_armor:leggings_gold",      count = 1}, {name = "default:gold_ingot", count = 4} },
			{ {name = "default:diamond_sword",       count = 1}, {name = "default:diamond", count = 2} },
		},
	},
	{
		name = "Wings of Remembrance",
		description = "I seek to build a monument to the fallen. Stone, wood, and feathers are all I need. The reward is older than the sky villages.",
		required_items = {
			{name = "default:feather",             count = 6},
			{name = "default:obsidian",            count = 5},
			{name = "default:mese_crystal_fragment", count = 8},
		},
		reward_sets = {
			{ {name = "3d_armor:chestplate_mithril", count = 1}, {name = "3d_armor:helmet_gold", count = 1} },
			{ {name = "default:diamond_sword",       count = 1}, {name = "default:diamond", count = 3} },
			{ {name = "3d_armor:leggings_mithril",   count = 1}, {name = "3d_armor:boots_mithril", count = 1} },
		},
	},
}

--------------------------------------------------------------------
-- Assign a random quest to a Sky Folk (ephemeral, not persisted)
--------------------------------------------------------------------
function lualore.sky_folk_quests.assign_quest(self)
	local quest = quest_pool[math.random(1, #quest_pool)]
	local reward_set = quest.reward_sets[math.random(1, #quest.reward_sets)]

	self.sf_quest = {
		name          = quest.name,
		description   = quest.description,
		required_items = quest.required_items,
		rewards       = reward_set,
	}
end

--------------------------------------------------------------------
-- Check if a player has all required items for a quest
--------------------------------------------------------------------
local function player_has_quest_items(player, required_items)
	local inv = player:get_inventory()
	local main = inv:get_list("main")

	for _, req in ipairs(required_items) do
		local total = 0
		for _, stack in ipairs(main) do
			if stack:get_name() == req.name then
				total = total + stack:get_count()
			end
		end
		if total < req.count then
			return false, req.name, req.count, total
		end
	end
	return true
end

--------------------------------------------------------------------
-- Remove required items from player inventory
--------------------------------------------------------------------
local function remove_quest_items(player, required_items)
	local inv = player:get_inventory()
	for _, req in ipairs(required_items) do
		local remaining = req.count
		for i, stack in ipairs(inv:get_list("main")) do
			if stack:get_name() == req.name and remaining > 0 then
				local take = math.min(stack:get_count(), remaining)
				stack:set_count(stack:get_count() - take)
				inv:set_stack("main", i, stack)
				remaining = remaining - take
			end
		end
	end
end

--------------------------------------------------------------------
-- Give reward items to player (drop at feet if inventory full)
--------------------------------------------------------------------
local function give_rewards(player, rewards)
	local inv = player:get_inventory()
	local pos = player:get_pos()

	for _, reward in ipairs(rewards) do
		local stack = ItemStack(reward.name .. " " .. reward.count)
		local leftover = inv:add_item("main", stack)
		if leftover and leftover:get_count() > 0 then
			minetest.add_item(pos, leftover)
		end
	end
end

--------------------------------------------------------------------
-- Format a short item display name
--------------------------------------------------------------------
local function item_display_name(item_name)
	local def = minetest.registered_items[item_name]
	if def and def.description and def.description ~= "" then
		local desc = def.description
		local first_line = desc:match("^([^\n]+)") or desc
		return first_line
	end
	local short = item_name:match(":(.+)$") or item_name
	return short:gsub("_", " "):gsub("^%l", string.upper)
end

--------------------------------------------------------------------
-- Build and show the quest formspec
--------------------------------------------------------------------
function lualore.sky_folk_quests.show_quest_formspec(player, sky_folk_entity)
	if not sky_folk_entity.sf_quest then
		lualore.sky_folk_quests.assign_quest(sky_folk_entity)
	end

	local quest = sky_folk_entity.sf_quest
	if not quest then return end

	local player_name = player:get_player_name()

	local inv = player:get_inventory()
	local r1 = quest.required_items[1]
	local r2 = quest.required_items[2]
	local r3 = quest.required_items[3]

	local function count_in_inv(item_name, needed)
		local total = 0
		for _, stack in ipairs(inv:get_list("main")) do
			if stack:get_name() == item_name then
				total = total + stack:get_count()
			end
		end
		return math.min(total, needed)
	end

	local have1 = count_in_inv(r1.name, r1.count)
	local have2 = count_in_inv(r2.name, r2.count)
	local have3 = count_in_inv(r3.name, r3.count)

	local ready = (have1 >= r1.count and have2 >= r2.count and have3 >= r3.count)

	local function item_row_color(have, need)
		if have >= need then return "#88FF88" else return "#FF8888" end
	end

	local reward_items_fs = ""
	local reward_x = 0.4
	for _, rw in ipairs(quest.rewards) do
		reward_items_fs = reward_items_fs ..
			"item_image[" .. reward_x .. ",9.2;0.9,0.9;" .. rw.name .. " " .. rw.count .. "]" ..
			"label[" .. (reward_x + 1.0) .. ",9.55;" .. item_display_name(rw.name) ..
				(rw.count > 1 and (" x" .. rw.count) or "") .. "]"
		reward_x = reward_x + 4.2
	end

	local cta_text, accept_label, decline_label
	if ready then
		cta_text = minetest.colorize("#88FF88", "You have exactly what I need! Will you accept these as a thanks?")
		accept_label = "Accept & Fulfill"
		decline_label = "Decline"
	else
		cta_text = minetest.colorize("#FFCC66",
			"You are missing items. Accept this quest and return for this\nhandsome reward — or decline and lose this offer forever.")
		accept_label = "Accept Quest"
		decline_label = "Decline Forever"
	end

	local fs =
		"formspec_version[3]" ..
		"size[10.5,13.5]" ..

		"background9[0,0;10.5,13.5;lualore_mood_bg.png;false;2]" ..
		"box[0,0;10.5,0.7;#1a2a3a]" ..

		"label[0.3,0.4;Quest Offer]" ..

		"box[0,0.75;10.5,0.05;#334455]" ..

		"label[0.3,1.1;" .. minetest.formspec_escape(quest.name) .. "]" ..

		"textarea[0.3,1.35;9.9,1.55;;;" .. minetest.formspec_escape(quest.description) .. "]" ..

		"box[0,3.05;10.5,0.05;#334455]" ..

		"label[0.3,3.35;Items Requested:]" ..

		"item_image[0.3,3.65;1.0,1.0;" .. r1.name .. "]" ..
		"label[1.45,4.0;" .. minetest.formspec_escape(item_display_name(r1.name)) .. " x" .. r1.count .. "]" ..
		"label[7.8,4.0;Have: ]" ..
		"label[8.6,4.0;" .. minetest.colorize(item_row_color(have1, r1.count), have1 .. " / " .. r1.count) .. "]" ..

		"item_image[0.3,4.85;1.0,1.0;" .. r2.name .. "]" ..
		"label[1.45,5.2;" .. minetest.formspec_escape(item_display_name(r2.name)) .. " x" .. r2.count .. "]" ..
		"label[7.8,5.2;Have: ]" ..
		"label[8.6,5.2;" .. minetest.colorize(item_row_color(have2, r2.count), have2 .. " / " .. r2.count) .. "]" ..

		"item_image[0.3,6.05;1.0,1.0;" .. r3.name .. "]" ..
		"label[1.45,6.4;" .. minetest.formspec_escape(item_display_name(r3.name)) .. " x" .. r3.count .. "]" ..
		"label[7.8,6.4;Have: ]" ..
		"label[8.6,6.4;" .. minetest.colorize(item_row_color(have3, r3.count), have3 .. " / " .. r3.count) .. "]" ..

		"box[0,7.15;10.5,0.05;#334455]" ..

		"label[0.3,7.45;Reward Offered:]" ..

		reward_items_fs ..

		"box[0,10.6;10.5,0.05;#334455]" ..

		"textarea[0.3,10.8;9.9,1.4;;;" .. cta_text .. "]" ..

		"button[2.6,12.5;3.6,0.8;fulfill_quest;" .. minetest.formspec_escape(accept_label) .. "]" ..
		"button[6.4,12.5;3.6,0.8;decline_quest;" .. minetest.formspec_escape(decline_label) .. "]"

	minetest.show_formspec(player_name, "lualore:sky_folk_quest", fs)

	lualore.sky_folk_quests._open_quests = lualore.sky_folk_quests._open_quests or {}
	lualore.sky_folk_quests._open_quests[player_name] = sky_folk_entity

	sky_folk_entity.nv_has_active_quest = true
	if lualore.sky_folk_mood then
		lualore.sky_folk_mood.update_indicator(sky_folk_entity)
	end
end

--------------------------------------------------------------------
-- Handle formspec field submissions
--------------------------------------------------------------------
minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "lualore:sky_folk_quest" then return false end

	local player_name = player:get_player_name()
	lualore.sky_folk_quests._open_quests = lualore.sky_folk_quests._open_quests or {}
	local sky_folk_entity = lualore.sky_folk_quests._open_quests[player_name]

	-- X button / ESC: treat same as closing without accepting or declining (quest stays)
	if fields.quit then
		if sky_folk_entity then
			sky_folk_entity.nv_has_active_quest = false
			if lualore.sky_folk_mood then
				lualore.sky_folk_mood.update_indicator(sky_folk_entity)
			end
		end
		lualore.sky_folk_quests._open_quests[player_name] = nil
		if lualore.sky_folk_compass then
			lualore.sky_folk_compass.stop(player_name)
		end
		return true
	end

	-- Decline: permanently forfeit this quest offer
	if fields.decline_quest then
		if sky_folk_entity then
			sky_folk_entity.sf_quest = nil
			sky_folk_entity.nv_has_active_quest = false
			if lualore.sky_folk_mood then
				lualore.sky_folk_mood.update_indicator(sky_folk_entity)
			end
		end
		lualore.sky_folk_quests._open_quests[player_name] = nil
		if lualore.sky_folk_pins then
			lualore.sky_folk_pins.clear(player_name)
		end
		if lualore.sky_folk_tracker then
			lualore.sky_folk_tracker.hide(player)
		end
		minetest.close_formspec(player_name, "lualore:sky_folk_quest")
		minetest.chat_send_player(player_name,
			S("The Sky Folk nods solemnly. The offer is gone."))
		return true
	end

	if fields.fulfill_quest then
		if not sky_folk_entity or not sky_folk_entity.sf_quest then
			minetest.chat_send_player(player_name, S("The Sky Folk has moved on."))
			minetest.close_formspec(player_name, "lualore:sky_folk_quest")
			return true
		end

		local quest = sky_folk_entity.sf_quest

		local ok = player_has_quest_items(player, quest.required_items)
		if not ok then
			-- Accept quest but player doesn't have items yet — drop a pin and show tracker icon
			sky_folk_entity.nv_has_active_quest = true
			lualore.sky_folk_quests._open_quests[player_name] = sky_folk_entity
			if lualore.sky_folk_mood then
				lualore.sky_folk_mood.update_indicator(sky_folk_entity)
			end
			local sf_pos = sky_folk_entity.object and sky_folk_entity.object:get_pos()
			if sf_pos and lualore.sky_folk_pins then
				lualore.sky_folk_pins.set(player, sf_pos, quest)
			end
			if lualore.sky_folk_tracker then
				lualore.sky_folk_tracker.show(player)
			end
			minetest.close_formspec(player_name, "lualore:sky_folk_quest")
			minetest.chat_send_player(player_name,
				S("Quest accepted! A waypoint marks this location. Gather the items and return — use /quest to review what you need."))
			return true
		end

		remove_quest_items(player, quest.required_items)
		give_rewards(player, quest.rewards)

		sky_folk_entity.sf_quest = nil
		sky_folk_entity.sf_quest_fulfilled = true
		sky_folk_entity.nv_has_active_quest = false
		lualore.sky_folk_quests._open_quests[player_name] = nil
		if lualore.sky_folk_mood then
			lualore.sky_folk_mood.update_indicator(sky_folk_entity)
		end
		if lualore.sky_folk_pins then
			lualore.sky_folk_pins.clear(player_name)
		end
		if lualore.sky_folk_tracker then
			lualore.sky_folk_tracker.hide(player)
		end

		minetest.close_formspec(player_name, "lualore:sky_folk_quest")
		minetest.chat_send_player(player_name,
			S("The Sky Folk bows graciously and offers you their gift."))

		if sky_folk_entity.object then
			local pos = sky_folk_entity.object:get_pos()
			if pos then
				local sound_name = sky_folk_sounds[math.random(1, #sky_folk_sounds)]
				minetest.sound_play(sound_name, {
					pos = pos,
					gain = 0.6,
					max_hear_distance = 16
				})

				minetest.add_particlespawner({
					amount = 40,
					time = 1.5,
					minpos = vector.subtract(pos, {x=0.4, y=0, z=0.4}),
					maxpos = vector.add(pos, {x=0.4, y=2.0, z=0.4}),
					minvel = {x=-1, y=1, z=-1},
					maxvel = {x=1, y=3, z=1},
					minacc = {x=0, y=-0.3, z=0},
					maxacc = {x=0, y=-0.3, z=0},
					minexptime = 1.0,
					maxexptime = 2.5,
					minsize = 1.5,
					maxsize = 3.0,
					texture = "lualore_particle_star.png^[colorize:#FFDD44:180",
					glow = 14
				})
			end
		end

		if lualore.sky_folk_mood then
			lualore.sky_folk_mood.on_trade(sky_folk_entity, player)
		end

		return true
	end

	return false
end)

--------------------------------------------------------------------
-- Check if a player is carrying any quest-relevant items
-- (used by the mood system to show the quest desire indicator)
--------------------------------------------------------------------
function lualore.sky_folk_quests.player_nearby_has_quest_item(self)
	if not self.sf_quest then return false end
	if not self.object then return false end

	local pos = self.object:get_pos()
	if not pos then return false end

	local objects = minetest.get_objects_inside_radius(pos, 4)
	for _, obj in ipairs(objects) do
		if obj:is_player() then
			local inv = obj:get_inventory()
			for _, req in ipairs(self.sf_quest.required_items) do
				for _, stack in ipairs(inv:get_list("main")) do
					if stack:get_name() == req.name and stack:get_count() > 0 then
						return true
					end
				end
			end
		end
	end
	return false
end

minetest.log("action", "[lualore] Sky Folk quest system loaded")
