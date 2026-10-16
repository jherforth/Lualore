-- village_workstations.lua
-- ===================================================================
-- FURNISHING A VILLAGE - anvil, altar and farm plots
-- ===================================================================
-- No building schematic in this mod contains an anvil, an altar or a
-- single tilled block, so the blacksmith, the cleric and the farmer had
-- nowhere to work. This module puts those three into a village.
--
-- It runs in two situations and has to cope with both:
--
--   * At GENERATION, called from village_placement.lua once the
--     buildings are up and the ground has been dressed. There it is
--     handed the site: the exact list of columns the terraformer
--     re-laid, and the footprints of every building. That is the good
--     case, and it is why the call sits after dressing rather than
--     before - the dressing pass plants over every free column and
--     would bury anything placed earlier.
--
--   * For an EXISTING village, through /furnish_village. There is no
--     site data at all, so the ground is read back out of the world.
--
-- Either way the final placement test reads the world, so the retrofit
-- path is no less safe than the generation one.
--
-- Settings: lualore_village_workstations (bool, default true)
-- ===================================================================

lualore = lualore or {}
lualore.workstations = {}

local S = minetest.get_translator("lualore")

local ENABLED = minetest.settings:get_bool("lualore_village_workstations", true)

-- A farm plot is PLOT_SIZE square, with a water source in the middle so
-- minetest_game's soil ABM keeps the ground wet (dry soil reverts to
-- plain dirt and the crops die with it), and the stake on one corner.
local PLOT_SIZE = 5
local PLOT_HALF = math.floor(PLOT_SIZE / 2)

-- Palettes whose ground should never be tilled. A wheat field on an ice
-- sheet reads as a mistake; deserts get one on purpose, as an oasis.
local NO_FARM = {ice = true}

-- ------------------------------------------------------------------
-- Ground knowledge
-- ------------------------------------------------------------------
local function col_key(x, z)
	return x .. ":" .. z
end

-- Map of column -> surface height. From the site when we have one,
-- otherwise read back out of the world.
local function column_map(site)
	local map = {}
	if site.columns and #site.columns > 0 then
		for _, col in ipairs(site.columns) do
			map[col_key(col.x, col.z)] = col.y
		end
		return map
	end

	local radius = site.radius or 34
	local floor_y = site.floor_y
	for x = site.cx - radius, site.cx + radius do
		for z = site.cz - radius, site.cz + radius do
			local dx, dz = x - site.cx, z - site.cz
			if dx * dx + dz * dz <= radius * radius then
				for y = floor_y + 4, floor_y - 4, -1 do
					local name = minetest.get_node({x = x, y = y, z = z}).name
					if name == "ignore" then
						break
					end
					local def = minetest.registered_nodes[name]
					if def and def.walkable then
						map[col_key(x, z)] = y
						break
					end
				end
			end
		end
	end
	return map
end

-- Is this column open sky above natural ground - not a floor inside a
-- building, not under an overhang, nothing already standing on it?
local function column_free(x, y, z)
	local here = minetest.get_node({x = x, y = y, z = z})
	local def = minetest.registered_nodes[here.name]
	if not def or not def.walkable then
		return false
	end
	if minetest.get_item_group(here.name, "lualore_workstation") > 0 then
		return false
	end
	for dy = 1, 3 do
		if minetest.get_node({x = x, y = y + dy, z = z}).name ~= "air" then
			return false
		end
	end
	return true
end

-- Every column of a square must be level, open, and clear of buildings.
local function area_free(map, plans, cx, cz, half, margin)
	local y0 = map[col_key(cx, cz)]
	if not y0 then
		return nil
	end
	for x = cx - half, cx + half do
		for z = cz - half, cz + half do
			if map[col_key(x, z)] ~= y0 then
				return nil
			end
			if not column_free(x, y0, z) then
				return nil
			end
		end
	end
	-- Keep clear of the buildings themselves.
	margin = margin or 1
	for _, box in ipairs(plans or {}) do
		if cx + half + margin >= box.minx and box.maxx + margin >= cx - half
				and cz + half + margin >= box.minz and box.maxz + margin >= cz - half then
			return nil
		end
	end
	return y0
end

-- Walk outwards from the centre looking for somewhere a structure fits.
-- Deterministic: the same village furnishes the same way every time.
local function find_spot(site, map, half, r_min, r_max, pr, margin)
	for _ = 1, 60 do
		local angle = pr:next(0, 62831) / 10000
		local radius = pr:next(r_min, r_max)
		local x = site.cx + math.floor(math.cos(angle) * radius + 0.5)
		local z = site.cz + math.floor(math.sin(angle) * radius + 0.5)
		local y = area_free(map, site.plans, x, z, half, margin)
		if y then
			return x, y, z
		end
	end
	return nil
end

-- ------------------------------------------------------------------
-- The structures
-- ------------------------------------------------------------------
local function place_altar(site, map, pr)
	if not minetest.registered_nodes["lualore:village_altar"] then
		return 0
	end
	-- Near the church when the village has one, otherwise near the middle.
	local church = nil
	for _, box in ipairs(site.plans or {}) do
		if box.file and box.file:find("church", 1, true) then
			church = box
			break
		end
	end

	local x, y, z
	if church then
		-- Two nodes clear of one of the church's four sides, centred.
		local mid_x = math.floor((church.minx + church.maxx) / 2)
		local mid_z = math.floor((church.minz + church.maxz) / 2)
		for _, spot in ipairs({
			{mid_x, church.maxz + 2},
			{mid_x, church.minz - 2},
			{church.maxx + 2, mid_z},
			{church.minx - 2, mid_z},
		}) do
			local ty = area_free(map, site.plans, spot[1], spot[2], 0, 1)
			if ty then
				x, y, z = spot[1], ty, spot[2]
				break
			end
		end
	end
	if not x then
		x, y, z = find_spot(site, map, 0, 4, 12, pr, 1)
	end
	if not x then
		return 0
	end

	minetest.set_node({x = x, y = y + 1, z = z}, {name = "lualore:village_altar"})
	return 1, {x = x, y = y + 1, z = z}
end

local function place_forge(site, map, pr)
	local placed = 0
	local anvil_ok = minetest.registered_nodes["lualore:anvil"] ~= nil
	local furnace_ok = minetest.registered_nodes["default:furnace"] ~= nil
	if not anvil_ok and not furnace_ok then
		return 0
	end

	-- Two adjacent free columns: anvil and forge side by side.
	local x, y, z = find_spot(site, map, 1, 6, 16, pr, 1)
	if not x then
		return 0
	end

	if anvil_ok then
		minetest.set_node({x = x, y = y + 1, z = z}, {name = "lualore:anvil"})
		placed = placed + 1
	end
	if furnace_ok then
		local fx, fz = x + 1, z
		if area_free(map, site.plans, fx, fz, 0, 1) then
			minetest.set_node({x = fx, y = y + 1, z = fz},
				{name = "default:furnace"})
			placed = placed + 1
		end
	end
	return placed, {x = x, y = y + 1, z = z}
end

-- A tilled plot: soil everywhere, water in the middle to keep it wet,
-- the stake on a corner, and a crop on every soil column.
local function place_farm(site, map, pr, r_min, r_max)
	local soil = minetest.registered_nodes["farming:soil_wet"] and "farming:soil_wet"
	local crop = minetest.registered_nodes["farming:wheat_1"] and "farming:wheat_1"
	local stake_ok = minetest.registered_nodes["lualore:field_stake"] ~= nil
	if not stake_ok then
		return 0
	end

	local x, y, z = find_spot(site, map, PLOT_HALF, r_min or 12, r_max or 26, pr, 2)
	if not x then
		return 0
	end

	local minx, maxx = x - PLOT_HALF, x + PLOT_HALF
	local minz, maxz = z - PLOT_HALF, z + PLOT_HALF
	local stake_x, stake_z = minx, minz

	for px = minx, maxx do
		for pz = minz, maxz do
			local is_stake = (px == stake_x and pz == stake_z)
			local is_water = (px == x and pz == z)
			if is_stake then
				-- leave the corner as ordinary ground; the post goes on top
			elseif is_water then
				minetest.set_node({x = px, y = y, z = pz},
					{name = "default:water_source"})
			elseif soil then
				minetest.set_node({x = px, y = y, z = pz}, {name = soil})
				if crop then
					minetest.set_node({x = px, y = y + 1, z = pz}, {name = crop})
				end
			end
		end
	end

	local stake_pos = {x = stake_x, y = y + 1, z = stake_z}
	minetest.set_node(stake_pos, {name = "lualore:field_stake"})
	if lualore.field_plot then
		-- record the crop so the farmer re-sows the right thing
		local crop_base = crop and crop:match("^(.*)_%d+$") or nil
		lualore.field_plot.set_bounds(stake_pos, minx, minz, maxx, maxz, y, crop_base)
	end

	if not soil then
		minetest.log("action", "[lualore] workstations: farming:soil_wet is not " ..
			"available, field stake placed without a plot")
	end
	return 1, stake_pos
end

-- The village notice board, where houses are commissioned
-- (village_commissions.lua). One per village, near the middle.
local BOARD = "lualore:notice_board"

local function place_board(site, map, pr)
	if not minetest.registered_nodes[BOARD] then
		return 0
	end
	local r = site.radius or 34
	if #minetest.find_nodes_in_area(
			{x = site.cx - r, y = site.floor_y - 6, z = site.cz - r},
			{x = site.cx + r, y = site.floor_y + 10, z = site.cz + r}, {BOARD}) > 0 then
		return 0 -- already has one
	end
	local x, y, z = find_spot(site, map, 0, 3, 10, pr, 1)
	if not x then
		return 0
	end
	local pos = {x = x, y = y + 1, z = z}
	-- face the middle of the village
	local dir = {x = site.cx - x, y = 0, z = site.cz - z}
	local param2 = (dir.x ~= 0 or dir.z ~= 0) and minetest.dir_to_facedir(dir) or 0
	minetest.set_node(pos, {name = BOARD, param2 = param2})
	return 1, pos
end

-- A single station node near (cx, cz): for trades with no placer of their
-- own.
local function place_single(site, map, pr, node)
	if not (node and minetest.registered_nodes[node]) then
		return 0
	end
	local x, y, z = find_spot(site, map, 0, 3, 10, pr, 1)
	if not x then
		return 0
	end
	minetest.set_node({x = x, y = y + 1, z = z}, {name = node})
	return 1, {x = x, y = y + 1, z = z}
end

-- Workstations for the trades without a placer above, by palette where the
-- prop is biome-specific.
local ENTERTAINER_PROP = {
	desert = "lualore:desertcrpet", jungle = "lualore:jungleshrine",
	savanna = "lualore:savannavshrine", ice = "lualore:sledge",
}

-- ------------------------------------------------------------------
-- Public entry point
-- ------------------------------------------------------------------
-- `site` wants: cx, cz, floor_y, seed, and optionally palette, plans
-- and columns. Without columns the ground is read from the world, which
-- is what the retrofit command does.
function lualore.workstations.furnish(site)
	if not ENABLED or not site then
		return 0
	end
	local map = column_map(site)
	if next(map) == nil then
		return 0
	end

	local pr = PcgRandom((site.seed or 1) + 6151)
	local placed = 0
	local results = {}

	local n, pos = place_altar(site, map, pr)
	placed = placed + (n or 0)
	results.altar = pos

	n, pos = place_forge(site, map, pr)
	placed = placed + (n or 0)
	results.forge = pos

	n, pos = place_board(site, map, pr)
	placed = placed + (n or 0)
	results.board = pos

	local palette_name = site.palette and site.palette.name
	if not (palette_name and NO_FARM[palette_name]) then
		local farms = 1 + ((site.seed or 0) % 3 == 0 and 1 or 0)
		for _ = 1, farms do
			n, pos = place_farm(site, map, pr)
			placed = placed + (n or 0)
			if pos then
				results.farm = pos
			end
		end
	end

	return placed, results
end

-- A workstation for one trade, close to (site.cx, site.cz): the house a
-- commissioned newcomer moves into. Villagers claim a station within 20
-- nodes of their bed, so it is kept within about 14 of the house's middle.
-- Returns the number of nodes placed and the station's position.
function lualore.workstations.place_for(site, class)
	local map = column_map(site)
	if next(map) == nil then
		return 0
	end
	local pr = PcgRandom((site.seed or 1) + 7919)
	if class == "blacksmith" then
		return place_forge(site, map, pr)
	elseif class == "cleric" then
		return place_altar(site, map, pr)
	elseif class == "farmer" then
		return place_farm(site, map, pr, 7, 14)
	elseif class == "fisherman" then
		return place_single(site, map, pr, "lualore:fishtrap")
	elseif class == "jeweler" then
		local shelf = minetest.registered_nodes["vessels:shelf"] and "vessels:shelf"
			or "lualore:grasslandbarrel"
		return place_single(site, map, pr, shelf)
	elseif class == "entertainer" then
		local palette_name = site.palette and site.palette.name
		return place_single(site, map, pr,
			ENTERTAINER_PROP[palette_name] or "lualore:hookah")
	end
	return 0 -- the ranger needs no station
end

-- ------------------------------------------------------------------
-- Retrofit command
-- ------------------------------------------------------------------
minetest.register_chatcommand("furnish_village", {
	params = "[radius]",
	description = S("Add the missing workstations (anvil, forge, altar, " ..
		"farm plots) and the notice board to the village you are standing in."),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local radius = math.max(12, math.min(60, tonumber(param) or 34))

		-- Prefer the recorded village centre, so the layout is measured
		-- from the village rather than from wherever the player stands.
		local cx, cz, floor_y = math.floor(pos.x), math.floor(pos.z), math.floor(pos.y)
		local seed = cx * 31 + cz
		if lualore.villages and lualore.villages.find_near then
			local rec = lualore.villages.find_near(pos, radius * 2)
			if rec then
				cx, cz, floor_y = rec.x, rec.z, rec.y or floor_y
				seed = rec.x * 31 + rec.z
			end
		end

		local placed, results = lualore.workstations.furnish({
			cx = cx, cz = cz, floor_y = floor_y,
			seed = seed, radius = radius,
		})

		if not placed or placed == 0 then
			return false, S("Found no clear, level ground to build on. " ..
				"Stand nearer the middle of the village, or try a larger radius.")
		end
		local where = {}
		for what, p in pairs(results or {}) do
			if p then
				where[#where + 1] = what .. " " .. minetest.pos_to_string(p)
			end
		end
		table.sort(where)
		return true, string.format("Placed %d workstation nodes at %s: %s",
			placed, minetest.pos_to_string({x = cx, y = floor_y, z = cz}),
			table.concat(where, ", "))
	end,
})
