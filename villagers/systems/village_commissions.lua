-- village_commissions.lua
-- ===================================================================
-- GROWING A VILLAGE - commissioning a new house
-- ===================================================================
-- Every village has a notice board near its middle. A player in good
-- standing commissions a house there and chooses who will live in it -
-- a farmer, a smith, a cleric and so on. The village picks a plot on its
-- edge, posts a bill of materials taken from the very house it means to
-- build, and once players have delivered it, the house goes up layer by
-- layer. When it is finished a newcomer of the chosen trade walks in from
-- the edge of the village, takes the new bed and gets a workstation of
-- their own beside the house.
--
-- * The bill comes from the house itself: the schematic is read, its
--   above-ground blocks counted, and a quarter of the commonest few are
--   asked for (more for each house the village has already been given).
--   So every palette - and any palette added later - asks for its own
--   materials without a table to maintain.
-- * The plot is found the way the workstation placer finds room: open,
--   level-enough ground under open sky, clear of houses, paths, water and
--   trees, as close to the village as there is room.
-- * Anyone can deliver, and delivering earns standing.
-- * A village grows by at most lualore_village_max_commissions houses.
--   The first two need Guest standing, the next three Friend, the rest Kin.
--
-- Settings: lualore_village_commissions (bool), lualore_village_max_commissions
--           (int), lualore_commission_cost (float)
-- ===================================================================

lualore = lualore or {}
lualore.commissions = {}

local S = minetest.get_translator("lualore")
local F = minetest.formspec_escape
local storage = minetest.get_mod_storage()

local ENABLED = minetest.settings:get_bool("lualore_village_commissions", true)
local MAX_COMMISSIONS = math.max(0, math.floor(tonumber(
	minetest.settings:get("lualore_village_max_commissions")) or 8))
local COST_GROWTH = math.max(0, tonumber(
	minetest.settings:get("lualore_commission_cost")) or 0.25)

local BOARD = "lualore:notice_board"
local BASE_SHARE = 0.25     -- the bill asks for this share of the house's blocks
local BILL_ITEMS = 5        -- at most this many different materials
local LAYER_SECONDS = 30    -- one layer of the house per this many seconds
local BUILD_RANGE = 96      -- ...while a player is this close
local SEARCH_MIN, SEARCH_MAX = 14, 90 -- plot search rings around the village
local MARGIN = 3            -- open ground kept round a new house
local LEVEL_SLACK = 2       -- plot ground may be this far off the village floor
local SCAFFOLD = "default:fence_wood"

-- Trades a newcomer can have, in the order the board lists them.
local TRADES = {"farmer", "blacksmith", "cleric", "fisherman", "jeweler",
	"entertainer", "ranger"}

-- ------------------------------------------------------------------
-- The notice board
-- ------------------------------------------------------------------
local WOOD = "default_wood.png"
local FACE = "lualore_notice_board.png"

minetest.register_node(BOARD, {
	description = S("Village Notice Board"),
	drawtype = "nodebox",
	tiles = {WOOD, WOOD, WOOD, WOOD, FACE, FACE},
	paramtype = "light",
	paramtype2 = "facedir",
	node_box = {
		type = "fixed",
		fixed = {
			{-0.45, -0.5, -0.05, -0.35, 0.5, 0.05},  -- posts
			{0.35, -0.5, -0.05, 0.45, 0.5, 0.05},
			{-0.5, -0.1, -0.0625, 0.5, 0.5, 0.0625}, -- the board
		},
	},
	selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.1, 0.5, 0.5, 0.1}},
	groups = {choppy = 2, oddly_breakable_by_hand = 2, lualore_workstation = 1},
	sounds = minetest.global_exists("default") and default.node_sound_wood_defaults() or nil,
	on_rightclick = function(pos, node, clicker)
		if clicker and clicker:is_player() then
			lualore.commissions.show(clicker, pos)
		end
	end,
})

minetest.register_craft({
	output = BOARD,
	recipe = {
		{"group:wood", "default:paper", "group:wood"},
		{"group:wood", "default:paper", "group:wood"},
		{"group:stick", "", "group:stick"},
	},
})

-- ------------------------------------------------------------------
-- Records
-- ------------------------------------------------------------------
-- commissions[village_key] = {state = "open"|"building", class, file, rot,
--   minx, minz, ext_x, ext_z, size = {x,y,z}, floor_y, base_y, below,
--   layer, last_layer, bill = {[item] = n}, delivered = {[item] = n},
--   commissioner, contributors = {[name] = n}, board = {x,y,z}}
local commissions

local function load()
	local data = storage:get_string("village_commissions")
	local parsed = data ~= "" and minetest.deserialize(data) or nil
	commissions = type(parsed) == "table" and parsed or {}
end

local function save()
	storage:set_string("village_commissions", minetest.serialize(commissions))
end

load()

local function village_of(pos)
	if lualore.villages and lualore.villages.find_near then
		local rec, key = lualore.villages.find_near(pos, 90)
		return rec, key
	end
	return nil, nil
end

local function palette_of(rec)
	return rec and lualore.village_palettes and lualore.village_palettes[rec.palette]
end

-- Standing needed for the next commission in a village with `done` so far.
local function standing_needed(done)
	if done >= 5 then
		return 80, "Kin"
	elseif done >= 2 then
		return 50, "Friend"
	end
	return 20, "Guest"
end

local function title_of(class)
	local def = lualore.jobs and lualore.jobs.classes and lualore.jobs.classes[class]
	return def and def.title or (class:sub(1, 1):upper() .. class:sub(2))
end

-- ------------------------------------------------------------------
-- The house: its schematic and its bill of materials
-- ------------------------------------------------------------------
local MODPATH = minetest.get_modpath("lualore")
local schem_cache = {}

local function read_house(file)
	if schem_cache[file] ~= nil then
		return schem_cache[file] or nil
	end
	local ok, schem = pcall(minetest.read_schematic,
		MODPATH .. "/schematics/" .. file, {write_yslice_prob = "none"})
	if ok and type(schem) == "table" and schem.size and schem.data then
		schem_cache[file] = schem
		return schem
	end
	schem_cache[file] = false
	return nil
end

-- What a player should be asked for in place of a schematic's block, or
-- nil for blocks the village supplies itself (beds, doors, its own props)
-- or that cannot be gathered.
local function material_for(name)
	name = minetest.registered_aliases[name] or name
	if name == "air" or name == "ignore" or name:find("^doors:") then
		return nil
	end
	if name:find("^lualore:") or name:find("^nativevillages:") then
		return nil -- the village's own furnishings
	end
	local def = minetest.registered_nodes[name]
	if not def then
		return nil
	end
	-- a placed form (default:torch_wall, xpanes:pane_flat) is paid for in
	-- the item it drops, which is what a player actually carries
	if type(def.drop) == "string" and def.drop ~= "" and def.drop ~= name then
		local dropped = def.drop:match("^(%S+)")
		if minetest.registered_items[dropped] then
			name = dropped
			def = minetest.registered_nodes[name] or def
		end
	end
	local groups = def.groups or {}
	if groups.bed or groups.door or groups.leaves or groups.flora or groups.plant
			or groups.sapling or (def.liquidtype and def.liquidtype ~= "none") then
		return nil
	end
	-- Stairs, slabs and slopes (the thatch of the grassland houses is
	-- stairs:slope_straw) are paid for in the block they are cut from,
	-- from whichever mod provides it.
	local base = name:match("^stairs:[a-z]+_inner_(.+)$")
		or name:match("^stairs:[a-z]+_outer_(.+)$")
		or name:match("^stairs:[a-z]+_(.+)$")
	if base then
		for _, mod in ipairs({"default", "farming", "ethereal", "everness", "moreblocks"}) do
			if minetest.registered_nodes[mod .. ":" .. base] then
				name = mod .. ":" .. base
				break
			end
		end
	end
	-- natural ground in a schematic is landscaping, not building material
	if name:find("^default:dirt") or name:find("^default:dry_dirt")
			or name == "default:sand" or name == "default:desert_sand"
			or name == "default:gravel" then
		return nil
	end
	def = minetest.registered_items[name]
	if not def or (def.groups and def.groups.not_in_creative_inventory) then
		return nil
	end
	return name
end

-- The bill for building `schem` above ground (layers from `below` up),
-- in a village that has had `done` commissions already.
local function bill_for(schem, below, done)
	local sx, sy, sz = schem.size.x, schem.size.y, schem.size.z
	local counts = {}
	for z = 0, sz - 1 do
		for y = below, sy - 1 do
			for x = 0, sx - 1 do
				local entry = schem.data[(z * sy + y) * sx + x + 1]
				if entry and (entry.prob == nil or entry.prob > 0) then
					local item = material_for(entry.name)
					if item then
						counts[item] = (counts[item] or 0) + 1
					end
				end
			end
		end
	end
	local list = {}
	for item, n in pairs(counts) do
		list[#list + 1] = {item = item, n = n}
	end
	table.sort(list, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		return a.item < b.item
	end)
	local scale = BASE_SHARE * (1 + COST_GROWTH * done)
	local bill = {}
	for i = 1, math.min(BILL_ITEMS, #list) do
		bill[list[i].item] = math.max(1, math.ceil(list[i].n * scale))
	end
	return bill
end

lualore.commissions.bill_for = bill_for
lualore.commissions.material_for = material_for

-- ------------------------------------------------------------------
-- Finding a plot
-- ------------------------------------------------------------------
local class_cache = {}
local function class_of(cid)
	local c = class_cache[cid]
	if c then
		return c
	end
	local name = minetest.get_name_from_content_id(cid)
	local def = minetest.registered_nodes[name]
	if name == "air" then
		c = "clear"
	elseif name == "ignore" or not def then
		c = "unknown"
	elseif def.liquidtype and def.liquidtype ~= "none" then
		c = "water"
	elseif def.buildable_to and not def.walkable then
		c = "clear" -- grass, flowers
	else
		local g = def.groups or {}
		if g.tree or g.leaves or g.bed or g.door
				or minetest.get_item_group(name, "lualore_workstation") > 0 then
			c = "blocked"
		elseif def.walkable then
			c = "solid:" .. name
		else
			c = "blocked"
		end
	end
	class_cache[cid] = c
	return c
end

-- The ground a new house could stand on: the surface of each column, if it
-- is open sky above natural ground near the village floor.
local function ground_reader(rec, palette)
	local floor_y = rec.y
	local r = SEARCH_MAX + 24
	local minp = {x = rec.x - r, y = floor_y - 8, z = rec.z - r}
	local maxp = {x = rec.x + r, y = floor_y + 16, z = rec.z + r}
	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data = vm:get_data()
	local path = palette and palette.ground and palette.ground.path
	local cache = {}
	return function(x, z)
		local k = x .. ":" .. z
		local hit = cache[k]
		if hit ~= nil then
			return hit
		end
		hit = false
		if x >= minp.x and x <= maxp.x and z >= minp.z and z <= maxp.z then
			for y = maxp.y, minp.y, -1 do
				local c = class_of(data[area:index(x, y, z)])
				if c ~= "clear" then
					if c:sub(1, 6) == "solid:" and math.abs(y - floor_y) <= LEVEL_SLACK
							and c:sub(7) ~= path then
						hit = y
					end
					break
				end
			end
		end
		cache[k] = hit
		return hit
	end
end

local ROTATIONS = {0, 90, 180, 270}

local function extent(size, rot)
	if rot == 90 or rot == 270 then
		return size.z, size.x
	end
	return size.x, size.z
end

-- Choose the house and where it goes. Returns a plot table or nil, reason.
local function find_plot(rec, key, palette)
	if not (palette and palette.houses and #palette.houses > 0) then
		return nil, "no_houses"
	end
	local done = rec.commissioned or 0
	local seed = 0
	for i = 1, #key do
		seed = (seed * 31 + key:byte(i)) % 2147483647
	end
	local pr = PcgRandom(seed + done * 7717)
	local file = palette.houses[pr:next(1, #palette.houses)]
	local schem = read_house(file)
	if not schem then
		return nil, "no_schematic"
	end
	local rot = ROTATIONS[pr:next(1, 4)]
	local ext_x, ext_z = extent(schem.size, rot)
	local ground = ground_reader(rec, palette)
	local spin = pr:next(0, 6283) / 1000

	for r = SEARCH_MIN, SEARCH_MAX, 3 do
		local n = math.max(12, math.floor(2 * math.pi * r / 6))
		for i = 0, n - 1 do
			local a = spin + i * 2 * math.pi / n
			local cx = rec.x + math.floor(math.cos(a) * r + 0.5)
			local cz = rec.z + math.floor(math.sin(a) * r + 0.5)
			local minx = cx - math.floor((ext_x - 1) / 2)
			local minz = cz - math.floor((ext_z - 1) / 2)
			local ok = true
			for x = minx - MARGIN, minx + ext_x - 1 + MARGIN do
				for z = minz - MARGIN, minz + ext_z - 1 + MARGIN do
					if not ground(x, z) then
						ok = false
						break
					end
				end
				if not ok then
					break
				end
			end
			if ok and not minetest.is_protected({x = cx, y = rec.y, z = cz}, "") then
				local below = math.max(0, -(palette.offset or 0))
				return {
					file = file, rot = rot,
					minx = minx, minz = minz, ext_x = ext_x, ext_z = ext_z,
					size = {x = schem.size.x, y = schem.size.y, z = schem.size.z},
					floor_y = rec.y, base_y = rec.y + (palette.offset or 0),
					below = below,
				}
			end
		end
	end
	return nil, "no_room"
end

lualore.commissions.find_plot = find_plot

-- ------------------------------------------------------------------
-- Building
-- ------------------------------------------------------------------
local function centre_of(c)
	return {x = c.minx + math.floor(c.ext_x / 2), y = c.floor_y + 1,
		z = c.minz + math.floor(c.ext_z / 2)}
end

-- Level the plot and the ring of ground round it to the village floor.
local function level_plot(c)
	local fy = c.floor_y
	local top = minetest.get_node({x = c.minx, y = fy, z = c.minz}).name
	local def = minetest.registered_nodes[top]
	if not (def and def.walkable) then
		top = "default:dirt_with_grass"
	end
	for x = c.minx - MARGIN, c.minx + c.ext_x - 1 + MARGIN do
		for z = c.minz - MARGIN, c.minz + c.ext_z - 1 + MARGIN do
			for y = fy + 1, fy + 6 do
				local p = {x = x, y = y, z = z}
				if minetest.get_node(p).name ~= "air" then
					minetest.remove_node(p)
				end
			end
			for y = fy - 3, fy - 1 do
				local p = {x = x, y = y, z = z}
				if minetest.get_node(p).name == "air" then
					minetest.set_node(p, {name = "default:dirt"})
				end
			end
			minetest.set_node({x = x, y = fy, z = z}, {name = top})
		end
	end
end

-- One horizontal slice of the house, placed with the same rotation the
-- whole schematic would get, so a house built layer by layer comes out
-- exactly as one placed at once.
local function place_layer(c, i)
	local schem = read_house(c.file)
	if not schem then
		return false
	end
	local sx, sy, sz = schem.size.x, schem.size.y, schem.size.z
	local slice = {}
	for z = 0, sz - 1 do
		for x = 0, sx - 1 do
			slice[z * sx + x + 1] = schem.data[(z * sy + i) * sx + x + 1]
		end
	end
	minetest.place_schematic({x = c.minx, y = c.base_y + i, z = c.minz},
		{size = {x = sx, y = 1, z = sz}, data = slice}, tostring(c.rot), nil, true)
	return true
end

local function scaffold_columns(c)
	local x0, x1 = c.minx - 1, c.minx + c.ext_x
	local z0, z1 = c.minz - 1, c.minz + c.ext_z
	return {{x0, z0}, {x1, z0}, {x0, z1}, {x1, z1}}
end

local function raise_scaffold(c, up_to)
	for _, col in ipairs(scaffold_columns(c)) do
		for y = c.floor_y + 1, up_to do
			local p = {x = col[1], y = y, z = col[2]}
			if minetest.get_node(p).name == "air" then
				minetest.set_node(p, {name = SCAFFOLD})
			end
		end
	end
end

local function clear_scaffold(c)
	local top = c.base_y + c.size.y
	for _, col in ipairs(scaffold_columns(c)) do
		for y = c.floor_y + 1, top do
			local p = {x = col[1], y = y, z = col[2]}
			if minetest.get_node(p).name == SCAFFOLD then
				minetest.remove_node(p)
			end
		end
	end
end

local function tell_near(pos, range, msg)
	for _, player in ipairs(minetest.get_connected_players()) do
		local p = player:get_pos()
		if p and vector.distance(p, pos) <= range then
			minetest.chat_send_player(player:get_player_name(), msg)
		end
	end
end

local function start_building(key, c)
	c.state = "building"
	level_plot(c)
	for i = 0, c.below - 1 do
		place_layer(c, i) -- the foundation goes in at once
	end
	c.layer = c.below
	c.last_layer = os.time()
	raise_scaffold(c, c.floor_y + 2)
	save()
	local where = centre_of(c)
	tell_near(where, 64, minetest.colorize("#FFDD88",
		S("Everything is delivered. Work begins on the @1's house!", title_of(c.class))))
	local who = c.commissioner and minetest.get_player_by_name(c.commissioner)
	if who and lualore.pins and lualore.pins.set then
		lualore.pins.set(who, "commission:" .. key, where,
			S("The @1's house", title_of(c.class)), 0xFFCC66)
	end
	minetest.log("action", "[lualore] Commission at " .. key .. ": building " ..
		c.file .. " for a " .. c.class)
end

-- A spot on the village's edge beyond the house, on open ground, for the
-- newcomer to arrive at.
local function arrival_spot(rec, house)
	local dx, dz = house.x - rec.x, house.z - rec.z
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1 then
		dx, dz, len = 1, 0, 1
	end
	for extra = 14, 30, 4 do
		local x = math.floor(house.x + dx / len * extra + 0.5)
		local z = math.floor(house.z + dz / len * extra + 0.5)
		for y = rec.y + 6, rec.y - 6, -1 do
			local def = minetest.registered_nodes[minetest.get_node({x = x, y = y, z = z}).name]
			if def and def.walkable then
				if minetest.get_node({x = x, y = y + 1, z = z}).name == "air"
						and minetest.get_node({x = x, y = y + 2, z = z}).name == "air" then
					return {x = x, y = y + 0.5, z = z}
				end
				break
			end
		end
	end
	return nil
end

local function complete(key, c)
	clear_scaffold(c)
	local rec = village_of(centre_of(c))
	local minp = {x = c.minx, y = c.floor_y - 2, z = c.minz}
	local maxp = {x = c.minx + c.ext_x - 1, y = c.base_y + c.size.y, z = c.minz + c.ext_z - 1}
	local beds = minetest.find_nodes_in_area(minp, maxp, {"group:bed"})
	local newcomer
	if beds[1] and lualore.villager_deck and lualore.villager_deck.reserve
			and lualore.house_spawning and lualore.house_spawning.populate then
		lualore.villager_deck.reserve(beds[1], c.class)
		lualore.house_spawning.populate(minp, maxp)
		for _, obj in ipairs(minetest.get_objects_inside_radius(beds[1], 12)) do
			local ent = obj:get_luaentity()
			if ent and ent.nv_house_pos and vector.equals(vector.round(ent.nv_house_pos),
					vector.round(beds[1])) then
				newcomer = obj
				break
			end
		end
	end
	-- they come in along the road rather than appearing in the house
	if newcomer and rec then
		local spot = arrival_spot(rec, centre_of(c))
		if spot then
			newcomer:set_pos(spot)
		end
	end

	local palette = palette_of(rec)
	if lualore.workstations and lualore.workstations.place_for then
		local mid = centre_of(c)
		lualore.workstations.place_for({
			cx = mid.x, cz = mid.z, floor_y = c.floor_y, radius = 22,
			seed = mid.x * 31 + mid.z, palette = palette,
			plans = {{minx = c.minx, maxx = c.minx + c.ext_x - 1,
				minz = c.minz, maxz = c.minz + c.ext_z - 1}},
		}, c.class)
	end

	if lualore.villages and lualore.villages.update then
		lualore.villages.update(key, function(r)
			r.houses = (r.houses or 0) + 1
			r.commissioned = (r.commissioned or 0) + 1
		end)
	end

	local mid = centre_of(c)
	minetest.add_particlespawner({
		amount = 80, time = 2,
		minpos = {x = c.minx, y = c.floor_y + 1, z = c.minz},
		maxpos = {x = c.minx + c.ext_x, y = c.floor_y + 8, z = c.minz + c.ext_z},
		minvel = {x = -0.5, y = 1, z = -0.5}, maxvel = {x = 0.5, y = 3, z = 0.5},
		minexptime = 1, maxexptime = 2.5, minsize = 1, maxsize = 3,
		texture = "lualore_particle_star.png", glow = 12,
	})
	minetest.sound_play("villager_fed", {pos = mid, gain = 1.0, max_hear_distance = 48}, true)
	tell_near(mid, 96, minetest.colorize("#FFDD88",
		S("The @1's house is finished, and a newcomer is on the road to the village!",
			title_of(c.class))))
	local who = c.commissioner and minetest.get_player_by_name(c.commissioner)
	if who then
		minetest.chat_send_player(c.commissioner, S("The new @1 calls out: " ..
			"\"You must be @2 - thank you for my house!\"", title_of(c.class), c.commissioner))
		if lualore.pins and lualore.pins.clear then
			lualore.pins.clear(who, "commission:" .. key)
		end
	end
	minetest.log("action", "[lualore] Commission at " .. key .. " finished: a " ..
		c.class .. (newcomer and " moved in" or " house with no newcomer"))
	commissions[key] = nil
	save()
end

local function advance(key, c, now)
	if now - (c.last_layer or 0) < LAYER_SECONDS then
		return
	end
	local mid = centre_of(c)
	if not minetest.get_node_or_nil(mid) then
		return -- not loaded
	end
	local near = false
	for _, player in ipairs(minetest.get_connected_players()) do
		local p = player:get_pos()
		if p and vector.distance(p, mid) <= BUILD_RANGE then
			near = true
			break
		end
	end
	if not near then
		return
	end
	if c.layer >= c.size.y then
		return complete(key, c)
	end
	place_layer(c, c.layer)
	c.layer = c.layer + 1
	c.last_layer = now
	raise_scaffold(c, math.min(c.base_y + c.layer, c.base_y + c.size.y - 1))
	minetest.sound_play("default_dig_choppy", {pos = mid, gain = 0.6, max_hear_distance = 32}, true)
	minetest.add_particlespawner({
		amount = 20, time = 1,
		minpos = {x = c.minx, y = c.base_y + c.layer - 1, z = c.minz},
		maxpos = {x = c.minx + c.ext_x, y = c.base_y + c.layer, z = c.minz + c.ext_z},
		minvel = {x = -0.3, y = 0.2, z = -0.3}, maxvel = {x = 0.3, y = 0.8, z = 0.3},
		minexptime = 0.5, maxexptime = 1.2, minsize = 0.8, maxsize = 1.6,
		texture = "default_wood.png",
	})
	save()
end

local clock = 0
minetest.register_globalstep(function(dtime)
	clock = clock + dtime
	if clock < 1 then
		return
	end
	clock = 0
	local now = os.time()
	for key, c in pairs(commissions) do
		if c.state == "building" then
			advance(key, c, now)
		end
	end
end)

-- ------------------------------------------------------------------
-- Commissioning and delivering
-- ------------------------------------------------------------------
local function trades_for(rec, palette)
	local out = {}
	local biome = rec and rec.palette or "grassland"
	local water = #minetest.find_nodes_in_area(
		{x = rec.x - 32, y = rec.y - 4, z = rec.z - 32},
		{x = rec.x + 32, y = rec.y + 2, z = rec.z + 32}, {"group:water"}) > 0
	for _, class in ipairs(TRADES) do
		if minetest.registered_entities["lualore:" .. biome .. "_" .. class]
				and (class ~= "fisherman" or water) then
			out[#out + 1] = class
		end
	end
	return out
end

-- Start a commission. Returns true or false, message.
function lualore.commissions.open(player, board_pos, class)
	local name = player:get_player_name()
	local rec, key = village_of(board_pos)
	if not rec then
		return false, S("This board does not belong to a village.")
	end
	if commissions[key] then
		return false, S("This village already has a house in hand.")
	end
	local done = rec.commissioned or 0
	if done >= MAX_COMMISSIONS then
		return false, S("This village has grown as large as it will.")
	end
	local need, need_name = standing_needed(done)
	local have = lualore.standing and lualore.standing.get(name, board_pos) or 100
	if have < need then
		return false, S("The village would rather a @1 asked for this.", need_name)
	end
	local palette = palette_of(rec)
	local plot, why = find_plot(rec, key, palette)
	if not plot then
		return false, why == "no_room"
			and S("There is no open ground left around the village for another house.")
			or S("The village cannot plan a house here.")
	end
	local schem = read_house(plot.file)
	plot.state = "open"
	plot.class = class
	plot.bill = bill_for(schem, plot.below, done)
	plot.delivered = {}
	plot.commissioner = name
	plot.contributors = {}
	plot.board = {x = board_pos.x, y = board_pos.y, z = board_pos.z}
	commissions[key] = plot
	save()
	minetest.log("action", "[lualore] " .. name .. " commissioned a " .. class ..
		"'s house at " .. key .. " (" .. plot.file .. ")")
	return true
end

local function remaining(c)
	local left = 0
	for item, n in pairs(c.bill) do
		left = left + math.max(0, n - (c.delivered[item] or 0))
	end
	return left
end

-- Take whatever the player carries towards the bill.
function lualore.commissions.deliver(player, board_pos)
	local rec, key = village_of(board_pos)
	local c = key and commissions[key]
	if not c or c.state ~= "open" then
		return 0
	end
	local name = player:get_player_name()
	local inv = player:get_inventory()
	local given = 0
	for item, n in pairs(c.bill) do
		local want = n - (c.delivered[item] or 0)
		if want > 0 then
			local taken = inv:remove_item("main", ItemStack(item .. " " .. want)):get_count()
			if taken > 0 then
				c.delivered[item] = (c.delivered[item] or 0) + taken
				given = given + taken
			end
		end
	end
	if given > 0 then
		c.contributors[name] = (c.contributors[name] or 0) + given
		if lualore.standing and lualore.standing.earn then
			lualore.standing.earn(player, board_pos, "commission")
		end
		if remaining(c) == 0 then
			start_building(key, c)
		else
			save()
		end
	end
	return given
end

function lualore.commissions.cancel(player, board_pos)
	local rec, key = village_of(board_pos)
	local c = key and commissions[key]
	if c and c.state == "open" and c.commissioner == player:get_player_name()
			and next(c.delivered) == nil then
		commissions[key] = nil
		save()
		return true
	end
	return false
end

-- ------------------------------------------------------------------
-- The board's form
-- ------------------------------------------------------------------
local contexts = {} -- player name -> board pos

local function form(player, board_pos)
	local name = player:get_player_name()
	local rec, key = village_of(board_pos)
	local fs = {"formspec_version[3]", "size[10,9]",
		"label[0.4,0.5;" .. F(S("Village Notice Board")) .. "]"}
	if not rec then
		fs[#fs + 1] = "label[0.4,1.3;" .. F(S("This board does not belong to a village.")) .. "]"
		return table.concat(fs)
	end
	local value, tier = 0, {name = "Stranger"}
	if lualore.standing then
		value, tier = lualore.standing.get(name, board_pos)
	end
	local done = rec.commissioned or 0
	fs[#fs + 1] = "label[0.4,1.0;" .. F(S("Your standing here: @1 (@2). Houses commissioned: @3 of @4.",
		tier.name, value, done, MAX_COMMISSIONS)) .. "]"

	local c = commissions[key]
	if not c then
		if done >= MAX_COMMISSIONS then
			fs[#fs + 1] = "label[0.4,2;" .. F(S("This village has grown as large as it will.")) .. "]"
			return table.concat(fs)
		end
		local need, need_name = standing_needed(done)
		fs[#fs + 1] = "label[0.4,1.8;" .. F(S("Commission a new house. Who should live in it?")) .. "]"
		fs[#fs + 1] = "label[0.4,2.3;" .. F(S("(Needs @1 standing or better.)", need_name)) .. "]"
		local trades = trades_for(rec, palette_of(rec))
		for i, class in ipairs(trades) do
			local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
			fs[#fs + 1] = string.format("button[%.1f,%.1f;4.4,0.8;trade_%s;%s]",
				0.4 + col * 4.8, 2.9 + row * 1.0, class, F(S("A @1", title_of(class))))
		end
		return table.concat(fs)
	end

	fs[#fs + 1] = "label[0.4,1.8;" .. F(S("A house for a @1, commissioned by @2.",
		title_of(c.class), c.commissioner or "?")) .. "]"
	if c.state == "building" then
		local total = math.max(1, c.size.y - c.below)
		local made = math.max(0, c.layer - c.below)
		fs[#fs + 1] = "label[0.4,2.6;" .. F(S("It is going up: @1 of @2 layers built.", made, total)) .. "]"
		fs[#fs + 1] = "label[0.4,3.2;" .. F(S("The work goes on while someone is nearby.")) .. "]"
		return table.concat(fs)
	end

	fs[#fs + 1] = "label[0.4,2.4;" .. F(S("Materials still needed:")) .. "]"
	local row = 0
	local items = {}
	for item in pairs(c.bill) do
		items[#items + 1] = item
	end
	table.sort(items)
	for _, item in ipairs(items) do
		local y = 2.8 + row * 0.9
		local got, want = c.delivered[item] or 0, c.bill[item]
		local label = lualore.inv and lualore.inv.display_name and lualore.inv.display_name(item)
			or item
		fs[#fs + 1] = string.format("item_image[0.4,%.1f;0.8,0.8;%s]", y, item)
		fs[#fs + 1] = string.format("label[1.4,%.1f;%s]", y + 0.4,
			F(string.format("%s: %d / %d%s", label, got, want, got >= want and "  (done)" or "")))
		row = row + 1
	end
	fs[#fs + 1] = "button[0.4,7.8;4.4,0.8;deliver;" .. F(S("Deliver what I carry")) .. "]"
	if c.commissioner == name and next(c.delivered) == nil then
		fs[#fs + 1] = "button[5.2,7.8;4.4,0.8;cancel;" .. F(S("Withdraw the commission")) .. "]"
	end
	return table.concat(fs)
end

function lualore.commissions.show(player, board_pos)
	if not ENABLED then
		minetest.chat_send_player(player:get_player_name(),
			S("The village is not taking commissions."))
		return
	end
	contexts[player:get_player_name()] = vector.new(board_pos)
	minetest.show_formspec(player:get_player_name(), "lualore:notice_board",
		form(player, board_pos))
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "lualore:notice_board" then
		return false
	end
	local name = player:get_player_name()
	local pos = contexts[name]
	if not pos or fields.quit then
		contexts[name] = nil
		return true
	end
	-- the board must still be within reach
	local p = player:get_pos()
	if not p or vector.distance(p, pos) > 8 then
		return true
	end
	for field in pairs(fields) do
		local class = field:match("^trade_(.+)$")
		if class then
			local ok, msg = lualore.commissions.open(player, pos, class)
			if not ok and msg then
				minetest.chat_send_player(name, msg)
			end
		end
	end
	if fields.deliver then
		local given = lualore.commissions.deliver(player, pos)
		minetest.chat_send_player(name, given > 0
			and S("You hand over @1 items for the house.", given)
			or S("You are not carrying anything the house still needs."))
	end
	if fields.cancel then
		lualore.commissions.cancel(player, pos)
	end
	lualore.commissions.show(player, pos)
	return true
end)

minetest.register_on_leaveplayer(function(player)
	contexts[player:get_player_name()] = nil
end)

-- ------------------------------------------------------------------
-- Admin
-- ------------------------------------------------------------------
minetest.register_chatcommand("village_commission", {
	params = "[rush]",
	description = S("Show the house being commissioned in this village; " ..
		"'rush' finishes it now (testing aid)."),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local rec, key = village_of(player:get_pos())
		if not rec then
			return false, S("You are not in a village.")
		end
		local c = commissions[key]
		if not c then
			return true, S("No house in hand here (@1 commissioned so far).", rec.commissioned or 0)
		end
		if param == "rush" then
			if c.state == "open" then
				c.delivered = table.copy(c.bill)
				start_building(key, c)
			end
			while commissions[key] and c.layer < c.size.y do
				place_layer(c, c.layer)
				c.layer = c.layer + 1
			end
			complete(key, c)
			return true, S("Finished.")
		end
		return true, string.format("%s's house for a %s: %s, layer %s of %d at (%d,%d)",
			c.commissioner or "?", c.class, c.state, tostring(c.layer or "-"),
			c.size.y, c.minx, c.minz)
	end,
})

lualore.commissions.all = function()
	return commissions
end

minetest.log("action", "[lualore] Village commissions loaded")
