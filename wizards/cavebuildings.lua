-- cavebuildings.lua
-- ===================================================================
-- CAVE CASTLES - deterministic grid placement + crypt carving
-- ===================================================================
-- This used to be a single schematic decoration with an ultra-rare noise
-- (scale 0.00001) and the "all_floors" flag. Two problems made cave
-- castles effectively broken:
--
--   1. With "all_floors" the engine tries the schematic on EVERY cave
--      floor of one random column picked per mapchunk. Because the noise
--      is all-or-nothing at that rarity, a chunk either placed nothing
--      at all, or placed castles on many cave floors at once - mostly
--      stacked vertically in the same column. Intervals between castles
--      were therefore unreasonable.
--
--   2. The schematic stores interiors as air with placement probability
--      0 ("never place"). Air is never written when a schematic is
--      blitted, so the crypt holding caverealms:dm_statue stays buried
--      in rock. The wizard boss group (which needs air around the
--      statue) could therefore never spawn.
--
-- The replacement below works like this:
--
--   * The world is divided into a grid of `spacing` x `spacing` cells
--     (400 nodes by default). Each cell has exactly ONE candidate
--     position, jittered inside the middle half of the cell, so two
--     castles can never be closer than half the spacing.
--   * For every candidate, we scan downward for the first cave floor
--     with enough open space above it (and no lava nearby) and place
--     the castle there exactly once.
--   * After placement, the crypt (interior air below the plaza) is
--     carved with a VoxelManip, so the statue room and its stairwell
--     are always reachable, then the four wizards spawn around the
--     statue.
--
-- All tuning lives in minetest.conf / settingtypes.txt:
--   lualore_cave_castles               (bool,   default true)
--   lualore_cave_castle_spacing        (int,    default 400)
--   lualore_cave_castle_chance         (float,  default 1.0)
--   lualore_cave_castle_y_top          (int,    default -120)
--   lualore_cave_castle_y_bottom       (int,    default -1200)
--   lualore_cave_castle_carve          (bool,   default true)
-- ===================================================================

local S = minetest.get_translator("lualore")

lualore = lualore or {}

-- ------------------------------------------------------------------
-- Configuration
-- ------------------------------------------------------------------
local function setting_number(key, default)
	local value = tonumber(minetest.settings:get(key))
	if value == nil then
		return default
	end
	return value
end

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local ENABLED  = minetest.settings:get_bool("lualore_cave_castles", true)
local CHANCE   = clamp(setting_number("lualore_cave_castle_chance", 1.0), 0.0, 1.0)
local SPACING  = clamp(math.floor(setting_number("lualore_cave_castle_spacing", 400)), 200, 5000)
local Y_TOP    = math.floor(setting_number("lualore_cave_castle_y_top", -120))
local Y_BOTTOM = math.floor(setting_number("lualore_cave_castle_y_bottom", -1200))
local DO_CARVE = minetest.settings:get_bool("lualore_cave_castle_carve", true)
if Y_BOTTOM > Y_TOP then
	Y_TOP, Y_BOTTOM = Y_BOTTOM, Y_TOP
end

local MODPATH   = minetest.get_modpath("lualore")
local SCHEMATIC = MODPATH .. "/schematics/cavecastle.mts"

local ROTATIONS = {0, 90, 180, 270}
local WIZARD_NAMES = {"redwizard", "whitewizard", "goldwizard", "blackwizard"}

-- Air nodes required above the chosen cave floor (the castle rises 9 nodes
-- above its plaza, so this leaves a healthy margin).
local CLEARANCE = 12

-- Fallback geometry for schematics/cavecastle.mts, used only if
-- minetest.read_schematic() fails for some reason.
local DEFAULT_GEOMETRY = {
	size = {x = 45, y = 35, z = 45},
	plaza = 7,                    -- y=7 is the mossy plaza slab
	statue = {x = 23, y = 4, z = 22}, -- caverealms:dm_statue cell
	carve = {},
	read_ok = false,
}

-- ------------------------------------------------------------------
-- Schematic geometry (statue position, plaza layer, carve mask)
-- ------------------------------------------------------------------
local geometry = nil

local function get_geometry()
	if geometry then
		return geometry
	end
	geometry = table.copy(DEFAULT_GEOMETRY)

	local ok, schem = pcall(minetest.read_schematic, SCHEMATIC, {write_yslice_prob = "none"})
	if not ok or type(schem) ~= "table" or type(schem.size) ~= "table"
			or type(schem.data) ~= "table" then
		minetest.log("warning", "[lualore] Could not read " .. SCHEMATIC ..
			" - falling back to built-in cave castle geometry")
		return geometry
	end

	local sx, sy, sz = schem.size.x, schem.size.y, schem.size.z
	geometry.size = {x = sx, y = sy, z = sz}
	geometry.read_ok = true

	local function node_at(x, y, z)
		return schem.data[1 + x + sx * (y + sy * z)]
	end

	-- Locate the statue; it is the anchor the wizards spawn around.
	local found = false
	for z = 0, sz - 1 do
		if found then break end
		for y = 0, sy - 1 do
			if found then break end
			for x = 0, sx - 1 do
				local node = node_at(x, y, z)
				if node and node.name == "caverealms:dm_statue" then
					geometry.statue = {x = x, y = y, z = z}
					found = true
					break
				end
			end
		end
	end

	-- The plaza is the layer with the most solid nodes (the big mossy slab
	-- that roofs the crypt).
	local layer_solids = {}
	local plaza = 0
	for y = 0, sy - 1 do
		local count = 0
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				local node = node_at(x, y, z)
				if node and node.name ~= "air" then
					count = count + 1
				end
			end
		end
		layer_solids[y] = count
		if count > layer_solids[plaza] then
			plaza = y
		end
	end
	geometry.plaza = plaza

	-- The crypt is the small stack of air cells just below the plaza whose
	-- columns are sandwiched between structure above and below (floor slab,
	-- walls, stairwell, plaza). Carve those so the crypt is always open.
	local carve_top = plaza
	local carve_bottom = math.max(0, plaza - 4)
	local carve = {}
	for z = 0, sz - 1 do
		for x = 0, sx - 1 do
			local solids = 0
			for y = 0, carve_top do
				local node = node_at(x, y, z)
				if node and node.name ~= "air" then
					solids = solids + 1
				end
			end
			if solids >= 2 then
				for y = carve_bottom, carve_top do
					local node = node_at(x, y, z)
					if node and node.name == "air" then
						carve[#carve + 1] = {x = x, y = y, z = z}
					end
				end
			end
		end
	end
	geometry.carve = carve

	minetest.log("action", string.format(
		"[lualore] Cave castle schematic loaded (%dx%dx%d, plaza y=%d, %d carve cells, statue at %d,%d,%d)",
		sx, sy, sz, plaza, #carve, geometry.statue.x, geometry.statue.y, geometry.statue.z))
	return geometry
end

-- ------------------------------------------------------------------
-- Rotation helpers
-- ------------------------------------------------------------------
-- Inverse of the engine's schematic blit rotation (src/mapgen/mg_schematic.cpp).
-- Maps a schematic-local (x, z) cell to its world offset from the
-- bottom-left corner of the rotated bounding box.
local function rotated_delta(rot, x, z, sx, sz)
	if rot == 90 then
		return z, (sx - 1) - x
	elseif rot == 180 then
		return (sx - 1) - x, (sz - 1) - z
	elseif rot == 270 then
		return (sz - 1) - z, x
	end
	return x, z
end

-- Bounding box of the rotated schematic placed with
-- "place_center_x, place_center_z" around `center` (base layer = center.y).
local function castle_bounds(center, rot)
	local g = get_geometry()
	local sx, sy, sz = g.size.x, g.size.y, g.size.z
	local ext_x, ext_z = sx, sz
	if rot == 90 or rot == 270 then
		ext_x, ext_z = sz, sx
	end
	local minx = center.x - math.floor((ext_x - 1) / 2)
	local minz = center.z - math.floor((ext_z - 1) / 2)
	return {
		minx = minx, miny = center.y, minz = minz,
		maxx = minx + ext_x - 1,
		maxy = center.y + sy - 1,
		maxz = minz + ext_z - 1,
		ext_x = ext_x,
		ext_z = ext_z,
	}
end

-- ------------------------------------------------------------------
-- Deterministic hashing (stable across restarts thanks to the world seed)
-- ------------------------------------------------------------------
local world_salt = nil

local function get_world_salt()
	if world_salt then
		return world_salt
	end
	local salt = 0
	local seed = minetest.get_mapgen_setting("seed") or ""
	for i = 1, #seed do
		salt = (salt * 131 + string.byte(seed, i)) % 2147483647
	end
	world_salt = (salt * 31 + 987654321) % 2147483647
	return world_salt
end

local function hash_mix(n, value)
	return (n * 48271 + (value % 2147483647)) % 2147483647
end

local function cell_hash(cell_x, cell_z, salt)
	local h = hash_mix(get_world_salt(), cell_x)
	h = hash_mix(h, cell_z)
	h = hash_mix(h, salt)
	return h
end

-- Candidate position of a grid cell. Returns nil if the cell lost the
-- spawn chance roll, otherwise x, z and a hash used for the rotation.
local function cell_candidate(cell_x, cell_z)
	local h = cell_hash(cell_x, cell_z, 17)
	if h > CHANCE * 2147483647 then
		return nil
	end
	local margin = math.floor(SPACING / 4)
	local span = math.max(1, SPACING - 2 * margin)
	local jitter_x = margin + (hash_mix(h, 101) % span)
	local jitter_z = margin + (hash_mix(h, 211) % span)
	return cell_x * SPACING + jitter_x, cell_z * SPACING + jitter_z,
		cell_hash(cell_x, cell_z, 307)
end

-- ------------------------------------------------------------------
-- Cave floor search
-- ------------------------------------------------------------------
local SAMPLE_OFFSETS = {
	{0, 0}, {10, 0}, {-10, 0}, {0, 10}, {0, -10},
	{10, 10}, {-10, -10}, {10, -10}, {-10, 10},
}

local function get_name(pos)
	return minetest.get_node(pos).name
end

local function is_unknown_name(name)
	return name == "ignore" or name == "unknown"
end

local function is_walkable_name(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.walkable == true
end

local function is_lava_name(name)
	return string.find(name, "lava", 1, true) ~= nil
end

-- Check the castle footprint for open space and forbidden nodes (lava).
-- Returns true, false, or "retry" when the area is not generated yet.
local function footprint_ok(x, z, floor_y)
	local good = 0
	for _, off in ipairs(SAMPLE_OFFSETS) do
		local px, pz = x + off[1], z + off[2]
		local air = 0
		local unknown = false
		for dy = 1, 6 do
			local name = get_name({x = px, y = floor_y + dy, z = pz})
			if is_unknown_name(name) then
				unknown = true
				break
			end
			if name == "air" then
				air = air + 1
			end
		end
		if not unknown then
			for dy = 1, 8 do
				local name = get_name({x = px, y = floor_y - dy, z = pz})
				if is_unknown_name(name) then
					unknown = true
					break
				end
				if is_lava_name(name) then
					return false
				end
			end
		end
		if unknown then
			return "retry"
		end
		if air >= 4 then
			good = good + 1
		end
	end
	return good >= 7
end

-- Find the first (topmost) walkable surface below Y_TOP that the castle
-- can sit on, scanning from `scan_top` down to `scan_bottom` (both default
-- to the full band). The caller passes the triggering chunk's y range so
-- the scan only ever reads terrain that is actually loaded - scanning from
-- Y_TOP while the player is deep would hit unloaded nodes and "retry"
-- forever.
-- Returns floor_y, or nil + "retry"/"none".
local function find_castle_floor(x, z, scan_top, scan_bottom)
	scan_top = math.min(scan_top or Y_TOP, Y_TOP)
	scan_bottom = math.max(scan_bottom or Y_BOTTOM, Y_BOTTOM)
	local y = scan_top
	while y >= scan_bottom do
		local name = get_name({x = x, y = y, z = z})
		if is_unknown_name(name) then
			return nil, "retry"
		end
		if is_walkable_name(name) then
			local clearance = 0
			local probe = y + 1
			while clearance < CLEARANCE do
				local above = get_name({x = x, y = probe, z = z})
				if is_unknown_name(above) then
					return nil, "retry"
				end
				if above ~= "air" then
					break
				end
				clearance = clearance + 1
				probe = probe + 1
			end
			if clearance >= CLEARANCE then
				local ok = footprint_ok(x, z, y)
				if ok == "retry" then
					return nil, "retry"
				end
				if ok then
					return y
				end
			end
		end
		y = y - 1
	end
	if scan_bottom > Y_BOTTOM then
		-- The deeper half of the band has not been checked yet; a later
		-- chunk generation will trigger another scan further down.
		return nil, "retry"
	end
	return nil, "none"
end

-- ------------------------------------------------------------------
-- Crypt carving
-- ------------------------------------------------------------------
local function carve_crypt(center, rot)
	local g = get_geometry()
	if #g.carve == 0 then
		return
	end
	local bounds = castle_bounds(center, rot)
	local minp = {x = bounds.minx, y = bounds.miny, z = bounds.minz}
	local maxp = {x = bounds.maxx, y = bounds.maxy, z = bounds.maxz}

	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local c_air = minetest.get_content_id("air")

	local changed = false
	for _, cell in ipairs(g.carve) do
		local dx, dz = rotated_delta(rot, cell.x, cell.z, g.size.x, g.size.z)
		local pos = {x = bounds.minx + dx, y = bounds.miny + cell.y, z = bounds.minz + dz}
		if area:containsp(pos) then
			local vi = area:indexp(pos)
			if data[vi] ~= c_air then
				data[vi] = c_air
				changed = true
			end
		end
	end

	if changed then
		vm:set_data(data)
		vm:write_to_map(true)
		vm:update_liquids()
	end
end

-- ------------------------------------------------------------------
-- Wizard spawning
-- ------------------------------------------------------------------
local function can_stand_at(pos)
	local feet = get_name(pos)
	if feet ~= "air" then
		return false
	end
	local head = get_name({x = pos.x, y = pos.y + 1, z = pos.z})
	if head ~= "air" then
		return false
	end
	local floor = get_name({x = pos.x, y = pos.y - 1, z = pos.z})
	if is_unknown_name(floor) or not is_walkable_name(floor) then
		return false
	end
	-- Never stack a spawn on top of an existing entity (e.g. on retries)
	return #minetest.get_objects_inside_radius(pos, 1.5) == 0
end

local function find_spawn_spots(center, base_levels, radius)
	local spots = {}
	local seen = {}
	local function try_add(x, y, z)
		local key = x .. ":" .. y .. ":" .. z
		if seen[key] then
			return
		end
		seen[key] = true
		local pos = {x = x, y = y, z = z}
		if can_stand_at(pos) then
			spots[#spots + 1] = pos
		end
	end

	-- Ring positions around the centre first (nice, symmetric formation)
	for _, r in ipairs({4, 6, 8}) do
		for i = 0, 7 do
			local angle = (i / 8) * math.pi * 2
			local dx = math.floor(math.cos(angle) * r + 0.5)
			local dz = math.floor(math.sin(angle) * r + 0.5)
			for _, y in ipairs(base_levels) do
				try_add(center.x + dx, y, center.z + dz)
			end
		end
	end

	-- Fallback: scan the whole room
	for dx = -radius, radius do
		for dz = -radius, radius do
			for _, y in ipairs(base_levels) do
				try_add(center.x + dx, y, center.z + dz)
			end
		end
	end
	return spots
end

-- Greedily pick up to `want` spots that are at least `min_dist` apart.
local function pick_spawn_spots(spots, want, min_dist)
	local picked = {}
	for _, spot in ipairs(spots) do
		local ok = true
		for _, other in ipairs(picked) do
			if vector.distance(spot, other) < min_dist then
				ok = false
				break
			end
		end
		if ok then
			picked[#picked + 1] = spot
			if #picked == want then
				break
			end
		end
	end
	return picked
end

local function spawn_group(chosen)
	local spawned = 0
	for i = 1, math.min(#chosen, #WIZARD_NAMES) do
		local mob = "lualore:" .. WIZARD_NAMES[i]
		if minetest.registered_entities[mob] then
			local obj = minetest.add_entity(chosen[i], mob)
			if obj then
				local ent = obj:get_luaentity()
				if ent then
					-- Castle bosses must survive chunk unloads. The mobs API
					-- removes untamed monsters when their map area unloads,
					-- so mark them tamed (still attacks players) and stack
					-- the lifetimer as a second line of defense, and make the
					-- engine keep their staticdata on deactivation.
					ent.tamed = true
					ent.lifetimer = 20000
					obj:set_properties({static_save = true})
				end
				spawned = spawned + 1
			end
		end
	end
	return spawned
end

local WIZARD_MOB_NAMES = {}
for _, n in ipairs(WIZARD_NAMES) do
	WIZARD_MOB_NAMES["lualore:" .. n] = true
end

-- How many of the four boss wizards are actually alive near `pos`.
local function count_wizards_near(pos, radius)
	local count = 0
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, radius)) do
		if not obj:is_player() then
			local ent = obj:get_luaentity()
			if ent and WIZARD_MOB_NAMES[ent.name] then
				count = count + 1
			end
		end
	end
	return count
end

-- Rescue carve used by the chat commands for castles generated before this
-- system existed, which still have a buried crypt around the statue.
local function unseal_around(pos, radius)
	local minp = {x = pos.x - radius, y = pos.y - 1, z = pos.z - radius}
	local maxp = {x = pos.x + radius, y = pos.y + 2, z = pos.z + radius}

	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local c_air = minetest.get_content_id("air")
	local changed = false

	for z = minp.z, maxp.z do
		for y = minp.y, maxp.y do
			for x = minp.x, maxp.x do
				local pos_here = {x = x, y = y, z = z}
				local is_statue_cell = (x == pos.x and y == pos.y and z == pos.z)
				if not is_statue_cell and area:containsp(pos_here) then
					local name = get_name(pos_here)
					if name ~= "air" and not is_unknown_name(name)
							and string.find(name, "statue", 1, true) == nil then
						local vi = area:indexp(pos_here)
						if data[vi] ~= c_air then
							data[vi] = c_air
							changed = true
						end
					end
				end
			end
		end
	end

	if changed then
		vm:set_data(data)
		vm:write_to_map(true)
		vm:update_liquids()
	end
end

local function spawn_wizards_around_statue(statue_pos, opts)
	opts = opts or {}
	local base_levels = {statue_pos.y - 1, statue_pos.y, statue_pos.y + 1}
	local spots = find_spawn_spots(statue_pos, base_levels, 9)
	local chosen = pick_spawn_spots(spots, 4, 4)

	if #chosen < 4 and opts.unseal then
		unseal_around(statue_pos, 5)
		spots = find_spawn_spots(statue_pos, base_levels, 9)
		chosen = pick_spawn_spots(spots, 4, 4)
	end

	return spawn_group(chosen)
end
lualore.spawn_wizards_around_statue = spawn_wizards_around_statue

-- Generic helper: spawn the four-wizard group around any position
-- (used by /spawn_wizards).
function lualore.spawn_wizards_at_position(pos)
	pos = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)}
	local base_levels = {pos.y - 1, pos.y, pos.y + 1}
	local spots = find_spawn_spots(pos, base_levels, 10)
	local chosen = pick_spawn_spots(spots, 4, 4)
	if #chosen < 4 then
		local relaxed = pick_spawn_spots(spots, 4, 2)
		if #relaxed > #chosen then
			chosen = relaxed
		end
	end
	return spawn_group(chosen)
end

-- ------------------------------------------------------------------
-- Castle records (mod storage)
-- ------------------------------------------------------------------
local storage = minetest.get_mod_storage()
local castles = {}
local castles_loaded = false

local function load_castles()
	if castles_loaded then
		return
	end
	local raw = storage:get_string("cave_castles")
	if raw ~= "" then
		castles = minetest.deserialize(raw) or {}
	end
	castles_loaded = true
end

local function save_castles()
	storage:set_string("cave_castles", minetest.serialize(castles))
end

-- ------------------------------------------------------------------
-- Placement
-- ------------------------------------------------------------------
local function find_statue(center, rot)
	local g = get_geometry()
	local bounds = castle_bounds(center, rot)
	local dx, dz = rotated_delta(rot, g.statue.x, g.statue.z, g.size.x, g.size.z)
	local expected = {x = bounds.minx + dx, y = bounds.miny + g.statue.y, z = bounds.minz + dz}
	if get_name(expected) == "caverealms:dm_statue" then
		return expected
	end

	-- Fallback: search the whole castle volume (covers unexpected layouts)
	local statues = minetest.find_nodes_in_area(
		{x = bounds.minx, y = bounds.miny, z = bounds.minz},
		{x = bounds.maxx, y = bounds.maxy, z = bounds.maxz},
		{"caverealms:dm_statue"}
	)
	if #statues > 0 then
		return statues[1]
	end
	return nil
end

local function spawn_castle_wizards(record, opts)
	opts = opts or {}
	if (record.wizards or 0) >= 4 then
		return 0, "already_spawned"
	end
	local center = {x = record.x, y = record.y, z = record.z}
	local statue = find_statue(center, record.rot)
	if not statue then
		return 0, "no_statue"
	end
	return spawn_wizards_around_statue(statue, opts), nil
end

local function place_castle(center, rot, opts)
	opts = opts or {}
	local success = minetest.place_schematic(
		{x = center.x, y = center.y, z = center.z},
		SCHEMATIC,
		tostring(rot),
		nil,   -- no replacements
		true,  -- force placement
		"place_center_x, place_center_z"
	)
	if success == nil or success == false then
		minetest.log("warning", "[lualore] Failed to place cave castle at " ..
			minetest.pos_to_string(center))
		return false
	end

	if DO_CARVE then
		carve_crypt(center, rot)
	end

	-- Abandoned village with sculpted cave ground around the castle
	-- (castle_village.lua registers lualore.build_castle_village).
	if opts.village ~= false and lualore.build_castle_village then
		local ok, err = pcall(lualore.build_castle_village, center, rot, opts)
		if not ok then
			minetest.log("warning", "[lualore] Castle village failed at " ..
				minetest.pos_to_string(center) .. ": " .. tostring(err))
		end
	end

	load_castles()
	local key = minetest.pos_to_string(center)
	local record = castles[key]
	if not record then
		record = {x = center.x, y = center.y, z = center.z, rot = rot, wizards = 0}
		castles[key] = record
		save_castles()
	end

	minetest.log("action", string.format("[lualore] Cave castle placed (%s) at %s",
		opts.source or "mapgen", key))

	local attempts = 0
	local function try_spawn()
		attempts = attempts + 1
		local spawned, reason = spawn_castle_wizards(record, opts)
		if spawned > 0 then
			record.wizards = math.min(4, (record.wizards or 0) + spawned)
			save_castles()
			minetest.log("action", string.format("[lualore] Cave castle %s: spawned %d/4 wizards",
				key, record.wizards))
		end
		if (record.wizards or 0) < 4 and attempts < 3 then
			-- Retry a few times: the chunk may still be settling or the
			-- crypt carve may have to finish first.
			minetest.after(15 * attempts, try_spawn)
		elseif (record.wizards or 0) < 4 then
			minetest.log("warning", string.format(
				"[lualore] Cave castle %s: only %d/4 wizards spawned (%s)",
				key, record.wizards or 0, tostring(reason)))
		end
	end
	minetest.after(1.0, try_spawn)

	return true
end
lualore.place_cave_castle = place_castle

-- A castle whose wizards are all gone gathers a new group when someone
-- arrives, but no more than once in this many seconds, so a castle is a
-- fight worth travelling to rather than a wizard farm.
local REGATHER_EVERY = 3600

local WIZARD_SET = {}
for _, colour in ipairs({"red", "white", "gold", "black"}) do
	WIZARD_SET["lualore:" .. colour .. "wizard"] = true
end

local function regather(record)
	if not record then
		return 0
	end
	local center = {x = record.x, y = record.y, z = record.z}
	local statue = find_statue(center, record.rot)
	if not statue then
		return 0
	end
	for _, obj in ipairs(minetest.get_objects_inside_radius(statue, 48)) do
		local ent = obj:get_luaentity()
		if ent and WIZARD_SET[ent.name] then
			return 0 -- the wizards are still here
		end
	end
	local now = os.time()
	if record.regather_at and now - record.regather_at < REGATHER_EVERY
			and (record.wizards or 0) >= 4 then
		return 0
	end
	record.regather_at = now
	local spawned = spawn_wizards_around_statue(statue, {})
	record.wizards = 4
	save_castles()
	minetest.log("action", "[lualore] Wizards gathered again at cave castle " ..
		minetest.pos_to_string(center) .. " (" .. tostring(spawned) .. ")")
	return spawned
end

-- Shared helpers (used by castle_village.lua, the dark portal and
-- debugging commands).
lualore.cave_castle = {
	get_geometry = get_geometry,
	castle_bounds = castle_bounds,
	get_records = function()
		load_castles()
		return castles
	end,
	-- A cave floor a castle fits on in column (x, z), or nil, reason.
	find_floor = find_castle_floor,
	band = {top = Y_TOP, bottom = Y_BOTTOM},
	regather = regather,
	key_of = function(center)
		return minetest.pos_to_string(center)
	end,
}

-- ------------------------------------------------------------------
-- Mapgen hook
-- ------------------------------------------------------------------
if ENABLED then
	local processed_cells = {}
	local pending_cells = {}
	local logged_first_scan = false

	local function handle_candidate(cell_x, cell_z, minp, maxp)
		local cell_key = cell_x .. ":" .. cell_z
		if processed_cells[cell_key] then
			return
		end

		local x, z, h = cell_candidate(cell_x, cell_z)
		if not x then
			-- this cell lost the spawn chance roll
			processed_cells[cell_key] = true
			return
		end

		-- Only the chunk column that contains the candidate handles it
		if x < minp.x or x > maxp.x or z < minp.z or z > maxp.z then
			return
		end

		local floor_y, reason = find_castle_floor(x, z, maxp.y, minp.y)
		if floor_y then
			processed_cells[cell_key] = true
			local rot = ROTATIONS[(h % 4) + 1]
			local center = {x = x, y = floor_y - get_geometry().plaza, z = z}
			-- Wait for the chunk to finish writing before touching it;
			-- retry briefly if it got unloaded in the meantime.
			local place_attempts = 0
			local function try_place()
				place_attempts = place_attempts + 1
				if minetest.get_node_or_nil({x = x, y = floor_y, z = z}) then
					place_castle(center, rot, {source = "mapgen"})
				elseif place_attempts < 3 then
					minetest.after(10 * place_attempts, try_place)
				else
					-- Spot could not be read back in time; let a later chunk
					-- generation pick this cell up again.
					processed_cells[cell_key] = nil
				end
			end
			minetest.after(0.5, try_place)
		elseif reason == "none" then
			-- No suitable cave floor in this column; give up on this cell
			processed_cells[cell_key] = true
		else
			-- Terrain in this window is not readable/suitable yet. Try a few
			-- times shortly after (the chunk may still be settling), and if
			-- that fails, leave the cell undecided so a later chunk
			-- generation (deeper, or when the player returns) picks it up.
			local left = (pending_cells[cell_key] or 6) - 1
			if left > 0 then
				pending_cells[cell_key] = left
				minetest.after(2.0, function()
					handle_candidate(cell_x, cell_z, minp, maxp)
				end)
			else
				pending_cells[cell_key] = nil
				minetest.log("info", "[lualore] Cave castle cell " .. cell_key ..
					" postponed (no readable floor in window yet)")
			end
		end
	end

	minetest.register_on_generated(function(minp, maxp, blockseed)
		-- Cave castles only live underground
		if maxp.y < Y_BOTTOM or minp.y > Y_TOP then
			return
		end

		if not logged_first_scan then
			logged_first_scan = true
			minetest.log("action", string.format(
				"[lualore] Cave castle scan active (chunk y %d..%d, band %d..%d)",
				minp.y, maxp.y, Y_TOP, Y_BOTTOM))
		end

		local cell_x0 = math.floor(minp.x / SPACING)
		local cell_x1 = math.floor(maxp.x / SPACING)
		local cell_z0 = math.floor(minp.z / SPACING)
		local cell_z1 = math.floor(maxp.z / SPACING)
		for cell_x = cell_x0, cell_x1 do
			for cell_z = cell_z0, cell_z1 do
				handle_candidate(cell_x, cell_z, minp, maxp)
			end
		end
	end)
end

-- ------------------------------------------------------------------
-- Chat commands (serverside debugging)
-- ------------------------------------------------------------------
minetest.register_chatcommand("spawn_cavecastle", {
	params = "",
	description = "Place a cave castle at your position (debug)",
	privs = {server = true},
	func = function(name)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local pos = player:get_pos()
		local center = {
			x = math.floor(pos.x),
			y = math.floor(pos.y) - get_geometry().plaza,
			z = math.floor(pos.z),
		}
		local rot = ROTATIONS[math.random(4)]
		if place_castle(center, rot, {source = "command", unseal = true}) then
			return true, "Cave castle placed at " .. minetest.pos_to_string(center)
		end
		return false, "Failed to place cave castle (see log)"
	end,
})

minetest.register_chatcommand("find_castle", {
	params = "[radius]",
	description = "Find the nearest recorded cave castle (default 512 nodes)",
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		load_castles()
		local pos = player:get_pos()
		local radius = tonumber(param) or 512
		local nearest = nil
		local nearest_dist = nil
		for _, record in pairs(castles) do
			local dist = vector.distance(pos, {x = record.x, y = record.y, z = record.z})
			if dist <= radius and (nearest_dist == nil or dist < nearest_dist) then
				nearest = record
				nearest_dist = dist
			end
		end
		if not nearest then
			return false, string.format(
				"No recorded cave castle within %d nodes (only castles placed after this update are tracked)",
				radius)
		end
		return true, string.format("Nearest cave castle at %s - %d nodes away (wizards %d/4)",
			minetest.pos_to_string({x = nearest.x, y = nearest.y, z = nearest.z}),
			math.floor(nearest_dist), nearest.wizards or 0)
	end,
})

minetest.register_chatcommand("spawn_castle_wizards", {
	params = "[radius]",
	description = "Spawn/respawn the wizard group at the nearest cave castle (default 256 nodes)",
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		load_castles()
		local pos = player:get_pos()
		local radius = tonumber(param) or 256

		local nearest = nil
		local nearest_dist = nil
		for _, record in pairs(castles) do
			local dist = vector.distance(pos, {x = record.x, y = record.y, z = record.z})
			if dist <= radius and (nearest_dist == nil or dist < nearest_dist) then
				nearest = record
				nearest_dist = dist
			end
		end

		if nearest then
			-- The record only tracks bookkeeping; verify the wizards are
			-- actually alive (older spawns were removed when the castle's
			-- chunks unloaded) and respawn the missing ones.
			local center = {x = nearest.x, y = nearest.y, z = nearest.z}
			local statue = find_statue(center, nearest.rot)
			local probe = statue or center
			local alive = count_wizards_near(probe, 48)
			if alive >= 4 then
				return true, "All 4 wizards are alive at this castle."
			end
			nearest.wizards = math.min(alive, 4)
			local spawned, reason = spawn_castle_wizards(nearest, {unseal = true})
			if spawned > 0 then
				nearest.wizards = math.min(4, (nearest.wizards or 0) + spawned)
				save_castles()
				return true, string.format("Spawned %d wizard(s) at cave castle %s (now %d/4)",
					spawned, minetest.pos_to_string(center), nearest.wizards)
			end
			return false, "Found the castle but could not spawn wizards (" ..
				tostring(reason) .. ")"
		end

		-- Fallback: look for a statue directly (castles placed by earlier
		-- versions are not recorded anywhere).
		local statues = minetest.find_nodes_in_area(
			{x = pos.x - radius, y = pos.y - radius, z = pos.z - radius},
			{x = pos.x + radius, y = pos.y + radius, z = pos.z + radius},
			{"caverealms:dm_statue"}
		)
		if #statues == 0 then
			return false, "No cave castle within " .. radius .. " nodes"
		end
		local statue = statues[1]
		local min_dist = vector.distance(pos, statue)
		for _, candidate in ipairs(statues) do
			local dist = vector.distance(pos, candidate)
			if dist < min_dist then
				min_dist = dist
				statue = candidate
			end
		end
		local spawned = spawn_wizards_around_statue(statue, {unseal = true})
		if spawned > 0 then
			return true, string.format("Spawned %d/4 wizards at %s", spawned,
				minetest.pos_to_string(statue))
		end
		return false, "Found a statue but could not spawn wizards (see log)"
	end,
})

minetest.register_chatcommand("clear_castle_records", {
	params = "",
	description = "Reset wizard spawn records so wizard groups can spawn again",
	privs = {server = true},
	func = function(name)
		load_castles()
		local count = 0
		for _, record in pairs(castles) do
			record.wizards = 0
			count = count + 1
		end
		save_castles()
		return true, string.format("Reset wizard records for %d cave castles", count)
	end,
})

minetest.register_chatcommand("castle_probe", {
	params = "[radius]",
	description = S("Diagnose cave castle placement around you (default 1000)."),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Player not found."
		end
		local pos = player:get_pos()
		local px, pz = math.floor(pos.x), math.floor(pos.z)
		local radius = tonumber(param) or 1000
		radius = math.max(100, math.min(radius, 3000))

		-- Same kind of depth window the mapgen scan uses near you: a fresh
		-- chunk triggers a scan of its own y range, not the whole band.
		local scan_hi = math.min(Y_TOP, math.floor(pos.y) + 160)
		local scan_lo = math.max(Y_BOTTOM, math.floor(pos.y) - 160)

		local cells, cand, floor_ok, floor_none, floor_retry = 0, 0, 0, 0, 0
		local example

		local c0x = math.floor((px - radius) / SPACING) - 1
		local c1x = math.floor((px + radius) / SPACING) + 1
		local c0z = math.floor((pz - radius) / SPACING) - 1
		local c1z = math.floor((pz + radius) / SPACING) + 1

		for cell_x = c0x, c1x do
			for cell_z = c0z, c1z do
				cells = cells + 1
				local x, z = cell_candidate(cell_x, cell_z)
				if x then
					local dx, dz = x - px, z - pz
					if dx * dx + dz * dz <= radius * radius then
						cand = cand + 1
						local floor_y, reason = find_castle_floor(x, z, scan_hi, scan_lo)
						if floor_y then
							floor_ok = floor_ok + 1
							if not example then
								example = string.format("(%d,%d) floor y=%d", x, z, floor_y)
							end
						elseif reason == "none" then
							floor_none = floor_none + 1
						else
							floor_retry = floor_retry + 1
						end
					end
				end
			end
		end

		local rec_count = 0
		load_castles()
		for _ in pairs(castles) do
			rec_count = rec_count + 1
		end

		local my_floor, my_reason = find_castle_floor(px, pz, scan_hi, scan_lo)
		local my_line
		if my_floor then
			my_line = "your column: suitable floor at y=" .. my_floor .. " (castle could sit here)"
		elseif my_reason == "none" then
			my_line = "your column: no suitable cave floor down to the band bottom"
		else
			my_line = "your column: no readable/suitable floor in this window"
		end

		local lines = {
			string.format("[castle_probe] %s spacing=%d chance=%.2f band=%d..%d | records=%d",
				ENABLED and "enabled" or "DISABLED", SPACING, CHANCE, Y_TOP, Y_BOTTOM, rec_count),
			string.format("scan window here: y %d..%d", scan_hi, scan_lo),
			my_line,
			string.format("cells=%d candidates=%d | floorOk=%d floorNone=%d retryUnloaded=%d",
				cells, cand, floor_ok, floor_none, floor_retry),
		}
		if example then
			lines[#lines + 1] = "a castle could sit at " .. example
		elseif cand > 0 then
			lines[#lines + 1] = "No candidate in range has a suitable cave floor."
		end
		return true, table.concat(lines, "\n")
	end,
})

-- One startup log line so the server log shows which config is live.
minetest.log("action", string.format(
	"[lualore] Cave castles %s: spacing=%d chance=%.2f band=%d..%d",
	ENABLED and "enabled" or "DISABLED", SPACING, CHANCE, Y_TOP, Y_BOTTOM))

print(S("[MOD] Lualore - Cave castles loaded (grid placement + crypt carving)"))
