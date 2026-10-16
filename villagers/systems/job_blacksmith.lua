-- job_blacksmith.lua
-- ===================================================================
-- THE BLACKSMITH - works the anvil, and will mend your tools
-- ===================================================================
-- He hammers at his anvil through the working day, turning out ingots
-- and the occasional tool into his stock. Ask him and he shares what he
-- has made, like any other villager.
--
-- The reason to seek him out, though, is the anvil itself: bring a worn
-- tool and he will put an edge back on it for steel. What it costs
-- depends on how badly worn the tool is and on how well the village
-- knows you - kin pay a quarter of what a stranger does.
--
-- The anvil only works while its smith is at it. A player can craft and
-- place their own anvil, but without a smith nearby it is a lump of
-- steel.
-- ===================================================================

local S = minetest.get_translator("lualore")

local smith = lualore.jobs and lualore.jobs.classes and lualore.jobs.classes.blacksmith
if not smith then
	minetest.log("warning", "[lualore] job_blacksmith: no blacksmith class to attach to")
	return
end

-- What comes off the anvil, and how often. Weighted: mostly ingots.
local OUTPUT = {
	{name = "default:steel_ingot", weight = 50, min = 1, max = 2},
	{name = "default:bronze_ingot", weight = 12, min = 1, max = 1},
	{name = "default:steel_axe", weight = 5, min = 1, max = 1},
	{name = "default:steel_pick", weight = 5, min = 1, max = 1},
	{name = "default:steel_shovel", weight = 5, min = 1, max = 1},
}

-- Only so many swings produce something; the rest are just work.
local PRODUCE_CHANCE = 4 -- one in four job ticks

-- Repair prices, in steel ingots. Kept deliberately low: the cost is in
-- steel whatever the tool is made of, so mending a diamond or mese tool
-- is a bargain while mending a steel one is roughly a wash. Pricing it
-- any higher made a stranger pay six ingots to repair a pick that costs
-- three to build, which is no offer at all.
local BASE_COST = 1
local WEAR_COST = 2    -- a tool worn to nothing costs BASE + WEAR
local TIER_MULTIPLIER = {Stranger = 1.5, Guest = 1.25, Friend = 1.0, Kin = 0.5}

local function pick_output()
	local total = 0
	local available = {}
	for _, entry in ipairs(OUTPUT) do
		if minetest.registered_items[entry.name] then
			available[#available + 1] = entry
			total = total + entry.weight
		end
	end
	if total == 0 then
		return nil
	end
	local roll = math.random(total)
	local acc = 0
	for _, entry in ipairs(available) do
		acc = acc + entry.weight
		if roll <= acc then
			return entry
		end
	end
	return available[#available]
end

local function sparks(pos)
	minetest.add_particlespawner({
		amount = 10,
		time = 0.3,
		minpos = {x = pos.x - 0.2, y = pos.y + 0.6, z = pos.z - 0.2},
		maxpos = {x = pos.x + 0.2, y = pos.y + 0.9, z = pos.z + 0.2},
		minvel = {x = -1.5, y = 1, z = -1.5},
		maxvel = {x = 1.5, y = 2.5, z = 1.5},
		minacc = {x = 0, y = -6, z = 0},
		maxacc = {x = 0, y = -6, z = 0},
		minexptime = 0.2,
		maxexptime = 0.5,
		minsize = 0.5,
		maxsize = 1.2,
		texture = "default_item_smoke.png^[colorize:#ffcc44:200",
		glow = 12,
	})
end

-- ------------------------------------------------------------------
-- Working
-- ------------------------------------------------------------------
smith.on_work = function(self, job_def, pos)
	local anvil = self.nv_work_pos
	if not anvil then
		return
	end

	minetest.sound_play("default_dig_cracky",
		{pos = anvil, gain = 0.35, max_hear_distance = 14}, true)
	sparks(anvil)

	if math.random(PRODUCE_CHANCE) ~= 1 then
		return
	end
	local entry = pick_output()
	if entry then
		lualore.jobs.add_stock(self, entry.name,
			math.random(entry.min, entry.max))
	end
end

smith.on_interact = function(self, player)
	return lualore.jobs.share_interact(self, player, {
		empty = S("The smith wipes his hands. \"Nothing finished yet. Come back when the fire's been up a while.\""),
		already = S("The smith shakes his head. \"You've had what I can spare today.\""),
		gave = function(items) return S("The smith hands you @1.", items) end,
		withheld = S("He sets the rest aside - the village keeps its own in stock."),
	})
end

-- ------------------------------------------------------------------
-- Repairs, at the anvil
-- ------------------------------------------------------------------
local function tier_name(player, pos)
	if not (lualore.standing and lualore.standing.get) then
		return "Friend"
	end
	local _, tier = lualore.standing.get(player:get_player_name(), pos)
	return tier.name
end

-- Never worth more than this, whatever the tool or the standing: the
-- price is in steel regardless of what the tool is made of, so a cap
-- keeps a stranger from being quoted more for mending a steel pick than
-- building a new one, while a diamond or mese tool stays a bargain.
local MAX_COST = 4

local function repair_cost(wear, player, pos)
	-- wear runs 0 (pristine) to 65535 (about to break)
	local base = BASE_COST + math.floor((wear / 65535) * WEAR_COST + 0.5)
	local mult = TIER_MULTIPLIER[tier_name(player, pos)] or 1.0
	local cost = math.floor(base * mult + 0.5)
	return math.max(1, math.min(MAX_COST, cost))
end

local PAYMENT = "default:steel_ingot"

if minetest.registered_nodes["lualore:anvil"] then
	minetest.override_item("lualore:anvil", {
		on_rightclick = function(pos, node, clicker, itemstack)
			if not clicker or not clicker:is_player() then
				return itemstack
			end
			local player_name = clicker:get_player_name()

			local nearby = lualore.jobs and lualore.jobs.villager_near
				and lualore.jobs.villager_near(pos, "blacksmith", 6)
			if not nearby then
				minetest.chat_send_player(player_name,
					S("The anvil is cold. There is no smith here."))
				return itemstack
			end

			if itemstack:is_empty() then
				minetest.chat_send_player(player_name,
					S("The smith looks up. \"Bring me something worn and I'll see to it.\""))
				return itemstack
			end

			local def = itemstack:get_definition()
			if not def or not def.tool_capabilities then
				minetest.chat_send_player(player_name,
					S("The smith turns it over. \"I work metal, not that.\""))
				return itemstack
			end

			local wear = itemstack:get_wear()
			if wear == 0 then
				minetest.chat_send_player(player_name,
					S("The smith laughs. \"There's nothing wrong with it.\""))
				return itemstack
			end

			local cost = repair_cost(wear, clicker, pos)
			local held = lualore.inv.count(clicker, PAYMENT)
			if held < cost and not (mobs and mobs.is_creative
					and mobs.is_creative(player_name)) then
				minetest.chat_send_player(player_name, S(
					"The smith names his price: @1 steel ingots. You have @2.",
					cost, held))
				return itemstack
			end

			if not (mobs and mobs.is_creative and mobs.is_creative(player_name)) then
				lualore.inv.take(clicker, PAYMENT, cost)
			end
			itemstack:set_wear(0)

			sparks(pos)
			minetest.sound_play("default_dig_cracky",
				{pos = pos, gain = 0.6, max_hear_distance = 14}, true)
			minetest.chat_send_player(player_name,
				S("The smith works your @1 back to true for @2 steel.",
					def.description and def.description:match("^([^\n]+)")
						or itemstack:get_name(), cost))

			if lualore.mood and lualore.mood.on_interact then
				lualore.mood.on_interact(nearby, clicker)
			end
			if lualore.standing and lualore.standing.earn then
				lualore.standing.earn(clicker, nearby, "job")
			end
			return itemstack
		end,
	})
end

minetest.log("action", "[lualore] Blacksmith job loaded")
