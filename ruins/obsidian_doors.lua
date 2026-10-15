-- ruins/obsidian_doors.lua
-- ===================================================================
-- THE OBSIDIAN DOOR TRIALS
-- Broken obsidian door shrines that the player must restore, opening
-- the way to a mirror door guarded by a boss on a floating island.
-- ===================================================================
-- The three obsidiandoor schematics (3x3x3 obsidian cubes with a
-- two-tall door on the front face, a small niche behind it and a
-- single everness crystal on top) are placed in dry, rugged biomes as
-- RUINS: a share of the frame blocks is missing, inviting the player
-- to finish the schematic with the exact same materials.
--
-- Restoring every frame block of a shrine awakens it. Walking up to
-- its door then teleports the player to a floating island (built on
-- demand, far above the everness sky layer), where the same door has
-- been placed mirrored and fully restored. A generated boss - the
-- Mirror Sentinel - guards it. Defeating the Sentinel is rewarded
-- with a chest (filled by the existing loot system) and the Sentinel
-- itself drops the variant's crystal.
--
-- The mirror door returns the player home; it opens for everyone once
-- the Sentinel is gone, or automatically after a short grace period
-- (no softlocks).
--
-- Placement uses the proven deterministic grid from ruins.lua:
-- one candidate per spacing x spacing cell in the middle half of the
-- cell, biome gate limited to the dry ruin themes (desert, savanna
-- families), village distance guard, retry-aware builds.
--
-- Tuning (minetest.conf / settingtypes.txt):
--   lualore_obsidian_doors (bool,  default true)
--   lualore_door_spacing   (int,   default 450)
--   lualore_door_chance    (float, default 0.7)
--   lualore_door_missing   (float, default 0.5)
--   lualore_door_boss      (bool,  default true)
--   lualore_door_y_max     (int,   default 200)
--   lualore_door_y_min     (int,   default -2)
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

local ENABLED      = minetest.settings:get_bool("lualore_obsidian_doors", true)
local SPACING      = clamp(math.floor(setting_number("lualore_door_spacing", 450)), 200, 5000)
local CHANCE       = clamp(setting_number("lualore_door_chance", 0.7), 0.0, 1.0)
local MISSING_FRAC = clamp(setting_number("lualore_door_missing", 0.5), 0.1, 0.9)
local WANT_BOSS    = minetest.settings:get_bool("lualore_door_boss", true)
local Y_MAX        = math.floor(setting_number("lualore_door_y_max", 200))
local Y_MIN        = math.floor(setting_number("lualore_door_y_min", -2))
if Y_MIN > Y_MAX then
	Y_MIN, Y_MAX = Y_MAX, Y_MIN
end

local MODPATH = minetest.get_modpath("lualore")

local SCHEMATIC_FILES = {
	"obsidiandoor1.mts",
	"obsidiandoor2.mts",
	"obsidiandoor3.mts",
}

-- First schematic layer sits this many nodes above the floor node.
local DOOR_BASE_OFFSET = 1

-- Floating island parameters (safely below the everness sky layer,
-- which starts at y = 500).
local ISLAND_Y       = 300
local ISLAND_RADIUS  = 16
local ESCAPE_SECONDS = 45

-- The shrine themes to use (dry / rugged biome families only). These
-- refer to themes registered by ruins.lua, which loads before us.
local DRY_THEMES = {desert = true, savanna = true}

-- Storage keys.
local RECORD_STORAGE = "obsidian_doors"
local RETURN_STORAGE = "obsidian_door_returns"

-- Mod storage reference. Must be fetched at load time: calling
-- minetest.get_mod_storage() later (e.g. from a globalstep) returns
-- nil on some engines.
local storage = minetest.get_mod_storage()

-- ------------------------------------------------------------------
-- Node helpers
-- ------------------------------------------------------------------
local function get_name(pos)
	return minetest.get_node(pos).name
end

local function is_unknown(name)
	return name == "ignore" or name == "unknown"
end

local function is_liquid(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.liquidtype ~= nil and def.liquidtype ~= "none"
end

local function is_lava(name)
	return string.find(name, "lava", 1, true) ~= nil
end

local function is_walkable(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.walkable == true
end

local function is_treeish(name)
	return string.find(name, "wood", 1, true) ~= nil
		or string.find(name, "tree", 1, true) ~= nil
		or string.find(name, "trunk", 1, true) ~= nil
		or string.find(name, "stem", 1, true) ~= nil
end

local function contains_door(name)
	return string.find(name, "door", 1, true) ~= nil
end

-- A "real" door node (as opposed to doors:hidden or other door-ish
-- nodes): contains the substring ":door".
local function is_door_node(name)
	return string.find(name, ":door", 1, true) ~= nil
end

-- ------------------------------------------------------------------
-- Deterministic hashing (stable per world seed) - same scheme as
-- ruins.lua and village_placement.lua, with door-specific salts.
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
	world_salt = (salt * 31 + 778899001) % 2147483647
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

local function cell_candidate(cell_x, cell_z)
	local h = cell_hash(cell_x, cell_z, 57)
	if h > CHANCE * 2147483647 then
		return nil
	end
	local margin = math.floor(SPACING / 4)
	local span = math.max(1, SPACING - 2 * margin)
	local jitter_x = margin + (hash_mix(h, 137) % span)
	local jitter_z = margin + (hash_mix(h, 269) % span)
	return cell_x * SPACING + jitter_x, cell_z * SPACING + jitter_z,
		cell_hash(cell_x, cell_z, 1213)
end

-- ------------------------------------------------------------------
-- Terrain scanning
-- ------------------------------------------------------------------
local function find_floor(x, z, top, bottom)
	for y = top, bottom, -1 do
		local name = get_name({x = x, y = y, z = z})
		if is_unknown(name) then
			return nil, "retry"
		end
		if is_walkable(name) and not is_treeish(name) then
			return y
		end
	end
	return nil
end

local function find_floor_near(x, z, ref, slack, top, bottom)
	local hi = math.min(ref + slack, top)
	local lo = math.max(ref - slack, bottom)
	return find_floor(x, z, hi, lo)
end

-- ------------------------------------------------------------------
-- Biome gate: dry / rugged ruins themes only
-- (desert, mesa, forsaken desert + savanna, prarie, outback)
-- ------------------------------------------------------------------
-- Biome names can be namespaced ("mod:biome"); match the full name first,
-- then the part after the ":" so "desert" also matches "everness:desert".
local function biome_matches(pattern, biome)
	if pattern == biome then
		return true
	end
	local a = pattern:match(":([^:]+)$") or pattern
	local b = biome:match(":([^:]+)$") or biome
	return a == b
end

local function theme_for_pos(x, z)
	if not (lualore.ruins and lualore.ruins.get_themes) then
		return nil
	end
	local data = minetest.get_biome_data({x = x, y = 64, z = z})
	if not data then
		return nil
	end
	local biome = minetest.get_biome_name(data.biome)
	if not biome then
		return nil
	end
	for _, theme in ipairs(lualore.ruins.get_themes()) do
		if DRY_THEMES[theme.name] then
			for _, name in ipairs(theme.biomes) do
				if biome_matches(name, biome) then
					return theme
				end
			end
		end
	end
	return nil
end

-- ------------------------------------------------------------------
-- Schematics: load once, classify every cell.
-- ------------------------------------------------------------------
local schematic_cache = nil

local function get_entry(variant)
	local cache = schematic_cache
	if not cache then
		return nil
	end
	return cache[variant]
end

local function load_schematics()
	if schematic_cache then
		return schematic_cache
	end
	schematic_cache = {}

	for index, file in ipairs(SCHEMATIC_FILES) do
		local path = MODPATH .. "/schematics/" .. file
		local sch = minetest.read_schematic(path, {write_yslice_prob = "none"})
		if not sch or not sch.size or not sch.data then
			minetest.log("warning", "[lualore] Could not read " .. file ..
				" - obsidian door variant " .. index .. " disabled")
		else
			local sx, sy, sz = sch.size.x, sch.size.y, sch.size.z
			local entry = {
				file = file,
				path = path,
				size = sch.size,
				requirable = {},  -- every solid, non-door cell
				doors = {},       -- actual door halves (bottom door node)
				materials = {},   -- unique frame materials (for rubble)
				crystal = nil,    -- the accent crystal on top
			}

			for i, node in ipairs(sch.data) do
				local name = node.name
				local k = i - 1
				local x = k % sx
				local y = math.floor(k / sx) % sy
				local z = math.floor(k / (sx * sy))

				if name and name ~= "air" and name ~= "ignore" then
					if contains_door(name) then
						if is_door_node(name) then
							entry.doors[#entry.doors + 1] =
								{x = x, y = y, z = z, name = name}
						end
					else
						entry.requirable[#entry.requirable + 1] =
							{x = x, y = y, z = z, name = name}
						entry.materials[name] = true
						if string.find(name, "crystal", 1, true) then
							entry.crystal = name
						end
					end
				end
			end

			local mats = {}
			for name in pairs(entry.materials) do
				mats[#mats + 1] = name
			end
			table.sort(mats)
			entry.materials = mats

			if #entry.requirable == 0 or #entry.doors == 0 then
				minetest.log("warning", "[lualore] " .. file ..
					" has no restorable cells - obsidian door variant " ..
					index .. " disabled")
			else
				schematic_cache[index] = entry
			end
		end
	end

	return schematic_cache
end

-- ------------------------------------------------------------------
-- Records (mod storage, cached)
-- ------------------------------------------------------------------
local records_cache = nil

local function load_records()
	local data = storage:get_string(RECORD_STORAGE)
	if data ~= "" then
		local records = minetest.deserialize(data)
		if type(records) == "table" then
			return records
		end
	end
	return {}
end

local function get_records()
	if not records_cache then
		records_cache = load_records()
	end
	return records_cache
end

local function save_records()
	storage:set_string(RECORD_STORAGE,
		minetest.serialize(records_cache or {}))
end

local function record_door(rec)
	get_records()[rec.key] = rec
	save_records()
end

-- Per-player return map (player name -> door record key).
local returns_cache = nil

local function get_returns()
	if not returns_cache then
		returns_cache = {}
		local data = storage:get_string(RETURN_STORAGE)
		if data ~= "" then
			local parsed = minetest.deserialize(data)
			if type(parsed) == "table" then
				returns_cache = parsed
			end
		end
	end
	return returns_cache
end

local function save_returns()
	storage:set_string(RETURN_STORAGE,
		minetest.serialize(returns_cache or {}))
end

-- ------------------------------------------------------------------
-- Village distance guard (same radius as ruins.lua)
-- ------------------------------------------------------------------
local function too_close_to_village(x, z)
	local data = storage:get_string("villages")
	if data == "" then
		return false
	end
	local records = minetest.deserialize(data)
	if type(records) ~= "table" then
		return false
	end
	for _, rec in pairs(records) do
		if type(rec) == "table" and rec.x
			and math.abs(rec.x - x) <= 48 and math.abs(rec.z - z) <= 48 then
			return true
		end
	end
	return false
end

-- ------------------------------------------------------------------
-- Rotation helpers (verified against the engine's schematic blit)
--   rot90 : (x, z) -> (z, sx-1-x)
--   rot180: (x, z) -> (sx-1-x, sz-1-z)
--   rot270: (x, z) -> (sz-1-z, x)
-- Relative direction vectors rotate as:
--   rot90 : (rx, rz) -> (rz, -rx)
--   rot180: (rx, rz) -> (-rx, -rz)
--   rot270: (rx, rz) -> (-rz, rx)
-- ------------------------------------------------------------------
local function rotated_delta(rot, x, z, sx, sz)
	if rot == 90 then
		return z, sx - 1 - x
	elseif rot == 180 then
		return sx - 1 - x, sz - 1 - z
	elseif rot == 270 then
		return sz - 1 - z, x
	end
	return x, z
end

local function rotated_dir(rot, rx, rz)
	if rot == 90 then
		return rz, -rx
	elseif rot == 180 then
		return -rx, -rz
	elseif rot == 270 then
		return -rz, rx
	end
	return rx, rz
end

-- World position of a schematic cell for a placed site.
local function cell_world(origin, rot, entry, cell)
	local dx, dz = rotated_delta(rot, cell.x, cell.z,
		entry.size.x, entry.size.z)
	return {x = origin.x + dx, y = origin.y + cell.y, z = origin.z + dz}
end

-- ------------------------------------------------------------------
-- Missing-cell selection (deterministic per site seed)
-- ------------------------------------------------------------------
local function choose_missing(entry, seed)
	local pr = PcgRandom(seed)
	local list = {}
	for i, cell in ipairs(entry.requirable) do
		list[i] = cell
	end
	-- Fisher-Yates shuffle, then take the first k as "missing".
	for i = #list, 2, -1 do
		local j = pr:next(1, i)
		list[i], list[j] = list[j], list[i]
	end
	local n = #list
	local k = clamp(math.floor(n * MISSING_FRAC), 1, math.max(1, n - 2))
	local missing = {}
	for i = 1, k do
		missing[list[i]] = true
	end
	return missing
end

-- ------------------------------------------------------------------
-- Site building
-- ------------------------------------------------------------------
local cid_cache = {}

local function content_id(name)
	local id = cid_cache[name]
	if id == nil then
		id = minetest.get_content_id(name)
		cid_cache[name] = id
	end
	return id
end

local function hollow_cells(positions)
	if #positions == 0 then
		return
	end
	local minp = {x = positions[1].x, y = positions[1].y, z = positions[1].z}
	local maxp = {x = positions[1].x, y = positions[1].y, z = positions[1].z}
	for _, p in ipairs(positions) do
		minp.x = math.min(minp.x, p.x)
		minp.y = math.min(minp.y, p.y)
		minp.z = math.min(minp.z, p.z)
		maxp.x = math.max(maxp.x, p.x)
		maxp.y = math.max(maxp.y, p.y)
		maxp.z = math.max(maxp.z, p.z)
	end
	minp.x, minp.y, minp.z = minp.x - 1, minp.y - 1, minp.z - 1
	maxp.x, maxp.y, maxp.z = maxp.x + 1, maxp.y + 1, maxp.z + 1

	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local air = minetest.get_content_id("air")

	for _, p in ipairs(positions) do
		if area:containsp(p) then
			data[area:indexp(p)] = air
		end
	end

	vm:set_data(data)
	vm:write_to_map(true)
	vm:update_liquids()
end

local function pick_from(pr, list)
	if not list or #list == 0 then
		return nil
	end
	return list[pr:next(1, #list)]
end

-- Sprinkle two pillar stubs and some rubble around the shrine.
local function decorate_site(cx, cz, base_y, theme, entry, pr, top, bottom)
	local corner_offsets = {
		{x = -3, z = -3}, {x = 3, z = -3}, {x = -3, z = 3}, {x = 3, z = 3},
	}
	-- two pillar stubs at random corners
	for i = 1, 2 do
		local pick_index = pr:next(1, #corner_offsets)
		local off = table.remove(corner_offsets, pick_index)
		if off then
			local px, pz = cx + off.x, cz + off.z
			local floor_y, err = find_floor_near(px, pz, base_y, 3, top, bottom)
			if floor_y and not err then
				local above = get_name({x = px, y = floor_y + 1, z = pz})
				if above == "air" then
					local height = pr:next(1, 3)
					for dy = 1, height do
						minetest.set_node({x = px, y = floor_y + dy, z = pz},
							{name = theme.wall[pr:next(1, #theme.wall)]})
					end
				end
			end
		end
	end

	-- rubble
	for _ = 1, 9 do
		local dx = pr:next(-5, 5)
		local dz = pr:next(-5, 5)
		if math.abs(dx) > 1 or math.abs(dz) > 1 then
			local rx, rz = cx + dx, cz + dz
			local floor_y, err = find_floor_near(rx, rz, base_y, 3, top, bottom)
			if floor_y and not err then
				local above = get_name({x = rx, y = floor_y + 1, z = rz})
				local def = minetest.registered_nodes[above]
				if above == "air" or (def and def.buildable_to) then
					local mat
					if pr:next(1, 100) <= 60 then
						mat = pick_from(pr, theme.rubble)
					else
						mat = pick_from(pr, entry.materials)
					end
					if mat then
						minetest.set_node({x = rx, y = floor_y + 1, z = rz},
							{name = mat})
					end
				end
			end
		end
	end
end

-- Build one shrine. Returns "retry", false, or true[, rec].
local function build_site(cx, cz, scan_top, scan_bottom, forced_seed)
	local variants = load_schematics()
	if not variants or next(variants) == nil then
		return false
	end

	local theme = theme_for_pos(cx, cz)
	if not theme then
		return false
	end

	local top = math.min(Y_MAX, scan_top or Y_MAX)
	local bottom = math.max(Y_MIN, scan_bottom or Y_MIN)
	if top < bottom then
		return "retry"
	end

	local base, err = find_floor(cx, cz, top, bottom)
	if err == "retry" then
		return "retry"
	end
	if not base then
		if scan_top or scan_bottom then
			return "retry"
		end
		return false
	end

	local above = get_name({x = cx, y = base + 1, z = cz})
	if is_unknown(above) then
		return "retry"
	end
	if is_lava(above) or is_liquid(above) then
		return false
	end

	-- Flatness: the nine footprint columns must all be reachable and
	-- near the same height; four further samples may be missing.
	local min_floor, max_floor = base, base
	for dx = -1, 1 do
		for dz = -1, 1 do
			local y, ferr = find_floor_near(cx + dx, cz + dz, base, 2,
				top, bottom)
			if ferr == "retry" then
				return "retry"
			end
			if not y then
				return false
			end
			min_floor = math.min(min_floor, y)
			max_floor = math.max(max_floor, y)
		end
	end
	local extra_missing = 0
	for _, off in ipairs({{x = 2, z = 0}, {x = -2, z = 0},
		{x = 0, z = 2}, {x = 0, z = -2}}) do
		local y, ferr = find_floor_near(cx + off.x, cz + off.z, base, 2,
			top, bottom)
		if ferr == "retry" then
			return "retry"
		end
		if y then
			min_floor = math.min(min_floor, y)
			max_floor = math.max(max_floor, y)
		else
			extra_missing = extra_missing + 1
		end
	end
	if extra_missing > 2 or max_floor - min_floor > 4 then
		return false
	end

	-- Pick variant and rotation.
	local seed = forced_seed or
		cell_hash(math.floor(cx / SPACING), math.floor(cz / SPACING), 31337)
	local pr = PcgRandom(seed)

	local variant_keys = {}
	for key in pairs(variants) do
		variant_keys[#variant_keys + 1] = key
	end
	table.sort(variant_keys)
	local variant = variant_keys[pr:next(1, #variant_keys)]
	local entry = variants[variant]
	local rot = ({0, 90, 180, 270})[pr:next(1, 4)]

	local origin = {
		x = cx - math.floor(entry.size.x / 2),
		y = base + DOOR_BASE_OFFSET,
		z = cz - math.floor(entry.size.z / 2),
	}

	-- Place the intact schematic (the engine handles rotation and the
	-- door param2), then hollow out the missing share.
	local placed = minetest.place_schematic(origin, entry.path,
		tostring(rot), nil, true)
	if placed == nil then
		return false
	end

	local missing = choose_missing(entry, seed)
	local holes = {}
	for _, cell in ipairs(entry.requirable) do
		if missing[cell] then
			holes[#holes + 1] = cell_world(origin, rot, entry, cell)
		end
	end
	hollow_cells(holes)

	-- Door position and the spot in front of it (outward = the niche
	-- direction rotated).
	local door_cell = entry.doors[1]
	local door_world = cell_world(origin, rot, entry, door_cell)
	local out_x, out_z = rotated_dir(rot, 0, -1)
	local spawn = {x = door_world.x, y = door_world.y, z = door_world.z}
	local sx = door_world.x + out_x * 3
	local sz = door_world.z + out_z * 3
	local floor_y, ferr = find_floor_near(sx, sz, base, 2, top, bottom)
	if floor_y and not ferr then
		spawn.x, spawn.y, spawn.z = sx, floor_y + 1, sz
	else
		spawn.x, spawn.z = sx, sz
		spawn.y = base + DOOR_BASE_OFFSET
	end

	decorate_site(cx, cz, base, theme, entry, pr, top, bottom)

	local key = cx .. ":" .. cz
	local rec = {
		key = key,
		variant = variant,
		rot = rot,
		x = cx, y = base, z = cz,
		origin = origin,
		door = door_world,
		spawn = spawn,
		seed = seed,
		active = false,
	}
	record_door(rec)
	return true, rec
end

-- ------------------------------------------------------------------
-- Completion checking / awakening
-- ------------------------------------------------------------------
-- Counts cells whose node does not match the schematic. Returns nil
-- when part of the area is not loaded yet.
local function count_wrong_cells(rec)
	local entry = get_entry(rec.variant)
	if not entry then
		return nil
	end
	local wrong = 0
	for _, cell in ipairs(entry.requirable) do
		local p = cell_world(rec.origin, rec.rot, entry, cell)
		local name = get_name(p)
		if is_unknown(name) then
			return nil
		end
		if name ~= cell.name then
			wrong = wrong + 1
		end
	end
	return wrong
end

local hint_time = {}

local function door_particles(pos, amount)
	minetest.add_particlespawner({
		amount = amount,
		time = 1.2,
		minpos = {x = pos.x - 1.5, y = pos.y, z = pos.z - 1.5},
		maxpos = {x = pos.x + 1.5, y = pos.y + 2.5, z = pos.z + 1.5},
		minvel = {x = -0.4, y = 0.4, z = -0.4},
		maxvel = {x = 0.4, y = 1.2, z = 0.4},
		minacc = {x = 0, y = 0.2, z = 0},
		maxacc = {x = 0, y = 0.6, z = 0},
		minexptime = 1.0,
		maxexptime = 2.5,
		minsize = 1,
		maxsize = 2.5,
		collisiondetection = false,
		texture = "lualore_particle_blob.png^[colorize:#B090FF:160",
		glow = 12,
	})
end

local function activate_door(rec, player)
	rec.active = true
	save_records()
	door_particles(rec.door, 60)
	local name = player:get_player_name()
	minetest.chat_send_player(name,
		S("The obsidian doorway awakens! Step close to pass through."))
	minetest.log("action", "[lualore] Obsidian door awakened at " .. rec.key)
end

-- ------------------------------------------------------------------
-- Floating island (lazy build + mirror door)
-- ------------------------------------------------------------------
local function area_has_unknown(minp, maxp)
	for x = minp.x, maxp.x, 4 do
		for z = minp.z, maxp.z, 4 do
			for y = minp.y, maxp.y, 4 do
				if is_unknown(get_name({x = x, y = y, z = z})) then
					return true
				end
			end
		end
	end
	return false
end

local function build_island(rec, island)
	local entry = get_entry(rec.variant)
	if not entry then
		return false
	end

	local r = ISLAND_RADIUS
	local pr = PcgRandom(rec.seed + 7777)

	local minp = {x = island.x - r - 2, y = island.y - 9, z = island.z - r - 2}
	local maxp = {x = island.x + r + 2, y = island.y + 2, z = island.z + r + 2}

	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})

	local stone_ids = {}
	local stone_names = {}
	for _, name in ipairs(entry.materials) do
		if string.find(name, "crystal", 1, true) == nil then
			stone_ids[#stone_ids + 1] = content_id(name)
			stone_names[#stone_names + 1] = name
		end
	end
	if #stone_ids == 0 then
		return false
	end
	local glow_id = content_id("caverealms:glow_obsidian")

	for dx = -r, r do
		for dz = -r, r do
			local d = math.sqrt(dx * dx + dz * dz)
			if d <= r then
				local depth = math.max(1, math.floor(1 + (r - d) / 3))
				for dy = 0, depth - 1 do
					local p = {x = island.x + dx, y = island.y - dy,
						z = island.z + dz}
					if area:containsp(p) then
						local id
						if dy == 0 and pr:next(1, 100) <= 8 then
							id = glow_id  -- glowing rim accents
						else
							id = stone_ids[pr:next(1, #stone_ids)]
						end
						data[area:indexp(p)] = id
					end
				end
				-- clear the air above the disc
				local air = minetest.get_content_id("air")
				for dy = 1, 2 do
					local p = {x = island.x + dx, y = island.y + dy,
						z = island.z + dz}
					if area:containsp(p) then
						data[area:indexp(p)] = air
					end
				end
			end
		end
	end

	vm:set_data(data)
	vm:write_to_map(true)
	vm:update_liquids()

	-- Mirror door: the same schematic, rotated half a turn, intact.
	local rot2 = (rec.rot + 180) % 360
	local origin = {
		x = island.x - math.floor(entry.size.x / 2),
		y = island.y + 1,
		z = island.z - math.floor(entry.size.z / 2),
	}
	minetest.place_schematic(origin, entry.path, tostring(rot2), nil, true)

	local door_cell = entry.doors[1]
	local door_world = cell_world(origin, rot2, entry, door_cell)
	local out_x, out_z = rotated_dir(rot2, 0, -1)
	local arrival = {
		x = door_world.x + out_x * 3.5,
		y = island.y + 1,
		z = door_world.z + out_z * 3.5,
	}

	-- Broken pillars ringing the island.
	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2 + pr:next(0, 40) / 100
		local rad = 10 + pr:next(0, 4)
		local px = island.x + math.floor(math.cos(angle) * rad)
		local pz = island.z + math.floor(math.sin(angle) * rad)
		local height = pr:next(2, 5)
		for dy = 1, height do
			if not (dy == height and pr:next(1, 100) <= 30) then
				minetest.set_node({x = px, y = island.y + dy, z = pz},
					{name = stone_names[pr:next(1, #stone_names)]})
			end
		end
	end

	island.built = true
	island.door = door_world
	island.arrival = arrival
	island.outward = {x = out_x, z = out_z}
	island.chest_placed = false
	island.sentinel_dead = false
	island.first_entry = nil
	save_records()
	return true
end

-- Returns island table, or nil plus an error.
local function ensure_island(rec)
	local island = rec.island
	if island and island.built then
		return island
	end

	if not island then
		local pr = PcgRandom(rec.seed + 4242)
		local angle = pr:next(0, 359) * math.pi / 180
		local dist = 400 + pr:next(0, 500)
		local ix = rec.x + math.floor(math.cos(angle) * dist)
		local iz = rec.z + math.floor(math.sin(angle) * dist)
		-- Keep the island inside the mapgen limits, or the area would
		-- never finish generating.
		local ok, minp, maxp = pcall(minetest.get_mapgen_edges)
		if ok and type(minp) == "table" and type(maxp) == "table" then
			ix = clamp(ix, minp.x + 80, maxp.x - 80)
			iz = clamp(iz, minp.z + 80, maxp.z - 80)
		end
		island = {
			x = ix,
			y = ISLAND_Y + pr:next(0, 39),
			z = iz,
			built = false,
		}
		rec.island = island
		save_records()
	end

	local r = ISLAND_RADIUS + 3
	local minp = {x = island.x - r, y = island.y - 10, z = island.z - r}
	local maxp = {x = island.x + r, y = island.y + 4, z = island.z + r}
	if area_has_unknown(minp, maxp) then
		minetest.emerge_area(minp, maxp)
		return nil, "retry"
	end

	if not build_island(rec, island) then
		return nil, "no_schematic"
	end
	minetest.log("action", string.format(
		"[lualore] Obsidian mirror island built for door %s at %d,%d",
		rec.key, island.x, island.z))
	return island
end

-- ------------------------------------------------------------------
-- Mirror Sentinel (the boss)
-- ------------------------------------------------------------------
local function find_island_record(pos, radius)
	for _, rec in pairs(get_records()) do
		if type(rec) == "table" and rec.island and rec.island.built then
			local cx = rec.island.x
			local cz = rec.island.z
			local dx = pos.x - cx
			local dz = pos.z - cz
			if dx * dx + dz * dz <= radius * radius then
				return rec
			end
		end
	end
	return nil
end

local function warden_alive(island)
	local center = {x = island.x, y = island.y + 2, z = island.z}
	for _, obj in ipairs(minetest.get_objects_inside_radius(center, 120)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "lualore:mirror_sentinel" then
			return true
		end
	end
	return false
end

local function spawn_sentinel(rec, island)
	if not WANT_BOSS or island.sentinel_dead then
		return
	end
	if warden_alive(island) then
		return
	end
	local spawn_pos = {x = island.x, y = island.y + 5, z = island.z}
	local obj = minetest.add_entity(spawn_pos, "lualore:mirror_sentinel")
	if obj then
		local function tag_sentinel()
			local ent = obj:get_luaentity()
			if ent then
				ent.island_key = rec.key
				ent.island_pos = {x = island.x, y = island.y + 3, z = island.z}
			end
		end
		tag_sentinel()
		minetest.after(0.2, tag_sentinel)
		minetest.log("action", "[lualore] Mirror Sentinel awakened for " ..
			rec.key)
	end
end

local function sentinel_drops(...)
	local pos, island_key
	for _, arg in ipairs({...}) do
		if type(arg) == "table" then
			if arg.x and arg.y and arg.z and not arg.object then
				pos = arg
			end
			if arg.island_key then
				island_key = arg.island_key
			end
		end
	end

	local crystal = "everness:crystal_purple"
	local rec
	if island_key then
		rec = get_records()[island_key]
	elseif pos then
		rec = find_island_record(pos, 80)
	end
	if rec then
		local entry = get_entry(rec.variant)
		if entry and entry.crystal then
			crystal = entry.crystal
		end
	end

	return {
		{name = crystal,              chance = 1, min = 2, max = 4},
		{name = "default:mese_crystal", chance = 1, min = 3, max = 6},
		{name = "default:diamond",    chance = 1, min = 2, max = 4},
	}
end

local function warden_on_died(self, pos)
	local rec = nil
	if self and self.island_key then
		rec = get_records()[self.island_key]
	end
	if not rec and pos then
		rec = find_island_record(pos, 80)
	end
	if not rec or not rec.island then
		return
	end
	local island = rec.island
	island.sentinel_dead = true

	-- Fade-out burst.
	if pos then
		minetest.add_particlespawner({
			amount = 80,
			time = 1.5,
			minpos = {x = pos.x - 1, y = pos.y - 1, z = pos.z - 1},
			maxpos = {x = pos.x + 1, y = pos.y + 2, z = pos.z + 1},
			minvel = {x = -2, y = -1, z = -2},
			maxvel = {x = 2, y = 2, z = 2},
			minacc = {x = 0, y = -2, z = 0},
			maxacc = {x = 0, y = -0.5, z = 0},
			minexptime = 1.0,
			maxexptime = 2.2,
			minsize = 1.5,
			maxsize = 3,
			collisiondetection = false,
			texture = "lualore_particle_blob.png^[colorize:#B090FF:170",
			glow = 12,
		})
	end

	-- Treasure chest beside the mirror door.
	if not island.chest_placed and island.door then
		local candidates = {
			{x = island.door.x + 1, y = island.door.y, z = island.door.z},
			{x = island.door.x - 1, y = island.door.y, z = island.door.z},
			{x = island.door.x, y = island.door.y, z = island.door.z + 1},
			{x = island.door.x, y = island.door.y, z = island.door.z - 1},
		}
		for _, cand in ipairs(candidates) do
			local here = get_name(cand)
			local below = get_name({x = cand.x, y = cand.y - 1, z = cand.z})
			if here == "air" and is_walkable(below)
				and minetest.registered_nodes["default:chest"] then
				minetest.set_node(cand, {name = "default:chest"})
				island.chest_placed = true
				-- Reuse the existing loot system to fill it right away.
				for _, lbm in pairs(minetest.registered_lbms or {}) do
					if lbm.name == "lualore:initialize_village_chests"
						and lbm.action then
						local ok, err = pcall(lbm.action, cand,
							minetest.get_node(cand))
						if not ok then
							minetest.log("warning",
								"[lualore] Chest fill failed: " .. tostring(err))
						end
						break
					end
				end
				break
			end
		end
	end

	save_records()

	if pos then
		for _, player in ipairs(minetest.get_connected_players()) do
			if vector.distance(player:get_pos(), pos) <= 96 then
				minetest.chat_send_player(player:get_player_name(),
					S("The Mirror Sentinel shatters! Its treasure appears beside the mirror door."))
			end
		end
	end
end

-- Movement/combat brain. Reuses the black wizard's spellcasting
-- mechanically (blindness curses at range), but keeps to the air and
-- prefers to float around its island instead of wandering off.
local function sentinel_do_custom(self, dtime)
	if not self.object then
		return
	end
	local pos = self.object:get_pos()
	if not pos then
		return
	end

	if self.attack and self.state == "attack" then
		local target = self.attack:get_pos()
		if target then
			local dist = vector.distance(pos, target)
			local dir = vector.direction(pos, target)
			if dist < 3.0 then
				self.object:set_velocity(vector.multiply(dir, -2.0))
			elseif dist > 14.0 then
				self.object:set_velocity(vector.multiply(dir, 2.0))
			end
		end
	elseif self.island_pos then
		local dist = vector.distance(pos, self.island_pos)
		if dist > 10 then
			local dir = vector.direction(pos, self.island_pos)
			self.object:set_velocity({x = dir.x * 1.2, y = 0, z = dir.z * 1.2})
		end
	end

	if lualore.wizard_magic and lualore.wizard_magic.black_do_custom then
		pcall(lualore.wizard_magic.black_do_custom, self, dtime)
	end
end

mobs:register_mob("lualore:mirror_sentinel", {
	type = "monster",
	passive = false,
	damage = 5,
	attack_type = "dogfight",
	attacks_monsters = false,
	attack_npcs = false,
	attack_players = true,
	owner_loyal = false,
	pathfinding = false,
	hp_min = 220,
	hp_max = 260,
	armor = 140,
	reach = 1.5,
	collisionbox = {-0.8, -0.5, -0.8, 0.8, 1.9, 0.8},
	stepheight = 1.1,
	visual = "mesh",
	mesh = "mirror_sentinel.gltf",
	textures = {"mirror_sentinel.png"},
	visual_size = {x = 0.85, y = 0.85},
	makes_footstep_sound = false,
	sounds = {},
	glow = 9,
	walk_velocity = 1.6,
	walk_chance = 0,
	stand_chance = 0,
	randomly_turn = false,
	run_velocity = 2.6,
	jump = false,
	jump_height = 0,
	fly = true,
	fly_in = {"air", "ignore"},
	drops = sentinel_drops,
	water_damage = 0,
	lava_damage = 0,
	fire_damage = 0,
	light_damage = 0,
	follow = {},
	view_range = 20,
	fear_height = 0,
	animation = {
		speed_normal = 1,
		stand_start = 0,
		stand_end = 4,
		stand_speed = 1,
		walk_start = 0,
		walk_end = 4,
		walk_speed = 1,
		run_start = 0,
		run_end = 4,
		run_speed = 1,
		punch_start = 0,
		punch_end = 4,
		punch_speed = 1,
	},
	on_activate = function(self, staticdata, dtime_s)
		if self.object then
			self.object:set_properties({glow = 9})
		end
	end,
	do_custom = sentinel_do_custom,
	on_die = warden_on_died,
})

-- Spawn egg, for looking at the boss without hunting down a shrine. A
-- sentinel spawned this way has no island_key or island_pos, which the
-- code already allows for: do_custom only tethers when island_pos is set,
-- sentinel_drops falls back to the default crystal, and warden_on_died
-- returns early rather than marking some unrelated island cleared. So it
-- flies and fights exactly as it does on a shrine, it simply does not
-- guard anything. Note it is a boss - 220-260 HP, armor 140, 5 damage a
-- hit - so spawn it somewhere you do not mind fighting.
mobs:register_egg("lualore:mirror_sentinel", S("Mirror Sentinel"),
	"amirror_sentinel.png", 0)

-- ------------------------------------------------------------------
-- Teleports
-- ------------------------------------------------------------------
local tp_cooldown = {}
local TP_COOLDOWN = 4
local mirror_hint_time = {}

local function near_door(player, door)
	local pos = player:get_pos()
	if not pos then
		return false
	end
	local dx = pos.x - (door.x + 0.5)
	local dz = pos.z - (door.z + 0.5)
	if dx * dx + dz * dz > 1.7 * 1.7 then
		return false
	end
	return pos.y >= door.y - 1.5 and pos.y <= door.y + 3.5
end

local function look_at(player, target)
	local pos = player:get_pos()
	if not pos then
		return
	end
	local dir = vector.direction(pos, target)
	if dir.x ~= 0 or dir.z ~= 0 then
		player:set_look_horizontal(minetest.dir_to_yaw(dir))
	end
end

local function mirror_door_active(rec, island)
	if not WANT_BOSS or island.sentinel_dead then
		return true
	end
	if island.first_entry and
		(minetest.get_gametime() - island.first_entry) >= ESCAPE_SECONDS then
		return true
	end
	return not warden_alive(island)
end

local function teleport_to_island(player, rec)
	local name = player:get_player_name()
	tp_cooldown[name] = minetest.get_gametime()

	local island, err = ensure_island(rec)
	if not island then
		if err == "retry" then
			minetest.chat_send_player(name,
				S("The way is still forming... try again in a moment."))
		else
			minetest.chat_send_player(name,
				S("The doorway is silent. (Schematic unavailable)"))
		end
		return false
	end

	door_particles(rec.door, 30)
	player:set_pos(island.arrival)
	look_at(player, {x = island.door.x + 0.5, y = island.door.y + 1,
		z = island.door.z + 0.5})

	get_returns()[name] = rec.key
	save_returns()
	tp_cooldown[name] = minetest.get_gametime()

	if not island.first_entry then
		island.first_entry = minetest.get_gametime()
		save_records()
	end

	spawn_sentinel(rec, island)

	minetest.chat_send_player(name,
		S("The mirror door hums behind you. The Mirror Sentinel stirs..."))
	return true
end

local function teleport_home(player)
	local name = player:get_player_name()
	local key = get_returns()[name]
	local rec = key and get_records()[key] or nil

	if not rec then
		-- Fall back to the nearest recorded door.
		local pos = player:get_pos()
		local best, best_dist
		for _, candidate in pairs(get_records()) do
			if type(candidate) == "table" and candidate.x then
				local d = vector.distance(pos,
					{x = candidate.x, y = pos.y, z = candidate.z})
				if not best_dist or d < best_dist then
					best, best_dist = candidate, d
				end
			end
		end
		rec = best
	end

	if not rec then
		return false
	end

	local target = rec.spawn or
		{x = rec.x, y = rec.y + DOOR_BASE_OFFSET + 1, z = rec.z}
	if rec.island and rec.island.door then
		door_particles(rec.island.door, 30)
	end
	player:set_pos(target)
	look_at(player, {x = rec.door.x + 0.5, y = rec.door.y + 1,
		z = rec.door.z + 0.5})
	tp_cooldown[name] = minetest.get_gametime()

	minetest.chat_send_player(name,
		S("You step back through the mirror door."))
	return true
end

-- ------------------------------------------------------------------
-- Global step: awakening scan, hints, ambient FX and teleport checks
-- ------------------------------------------------------------------
local scan_timer = 0
local fx_time = {}

minetest.register_globalstep(function(dtime)
	scan_timer = scan_timer + dtime
	if scan_timer < 1 then
		return
	end
	scan_timer = 0

	local players = minetest.get_connected_players()
	if #players == 0 then
		return
	end
	local now = minetest.get_gametime()

	for _, rec in pairs(get_records()) do
		if type(rec) == "table" and rec.door then
			-- find a player interested in this door
			for _, player in ipairs(players) do
				local ppos = player:get_pos()
				if ppos then
					local pname = player:get_player_name()
					local dist = vector.distance(ppos, rec.door)

					if not rec.active and dist <= 32 then
						local wrong = count_wrong_cells(rec)
						if wrong == 0 then
							activate_door(rec, player)
						elseif wrong and wrong > 0 and dist <= 8 then
							local hkey = pname .. ";" .. rec.key
							local last = hint_time[hkey] or 0
							if now - last >= 300 then
								hint_time[hkey] = now
								minetest.chat_send_player(pname,
									S("The obsidian doorway hums faintly... (@1 blocks remaining)",
										wrong))
							end
						end
					end

					-- Awakened doors emit an occasional shimmer.
					if rec.active and dist <= 48 then
						local fkey = rec.key
						local last_fx = fx_time[fkey] or 0
						if now - last_fx >= 12 then
							fx_time[fkey] = now
							door_particles(rec.door, 6)
						end
					end

					-- Source door teleport.
					if rec.active and near_door(player, rec.door) then
						local last = tp_cooldown[pname] or 0
						if now - last >= TP_COOLDOWN then
							teleport_to_island(player, rec)
							break
						end
					end
				end
			end

			-- Mirror door (return trip).
			local island = rec.island
			if island and island.built and island.door then
				for _, player in ipairs(players) do
					local pname = player:get_player_name()
					if near_door(player, island.door) then
						local last = tp_cooldown[pname] or 0
						if now - last >= TP_COOLDOWN then
							if mirror_door_active(rec, island) then
								teleport_home(player)
								break
							else
								local mkey = pname .. ";mirror;" .. rec.key
								local last_hint = mirror_hint_time[mkey] or 0
								if now - last_hint >= 15 then
									mirror_hint_time[mkey] = now
									minetest.chat_send_player(pname,
										S("The Mirror Sentinel bars the way back!"))
								end
							end
						end
					end
				end
			end
		end
	end
end)

-- ------------------------------------------------------------------
-- Placement driver (deterministic grid, same retry pattern as ruins)
-- ------------------------------------------------------------------
local tried = {}
local pending = {}

local function attempt_cell(cell_x, cell_z, minp, maxp)
	local key = cell_x .. ":" .. cell_z
	if tried[key] then
		return
	end

	local cx, cz = cell_candidate(cell_x, cell_z)
	if not cx then
		tried[key] = true
		return
	end

	local is_retry = pending[key] ~= nil
	if not is_retry
		and (cx < minp.x or cx > maxp.x or cz < minp.z or cz > maxp.z) then
		return
	end

	local theme = theme_for_pos(cx, cz)
	if not theme then
		tried[key] = true
		return
	end

	if not is_retry and too_close_to_village(cx, cz) then
		tried[key] = true
		minetest.log("info", "[lualore] Obsidian door cell " .. key ..
			" skipped (village nearby)")
		return
	end

	local result, rec = build_site(cx, cz, maxp.y, minp.y)
	if result == "retry" then
		local left = (pending[key] or 40) - 1
		if left > 0 then
			pending[key] = left
			minetest.after(0.7, function()
				attempt_cell(cell_x, cell_z, minp, maxp)
			end)
		else
			pending[key] = nil
			minetest.log("info", "[lualore] Obsidian door cell " .. key ..
				" postponed")
		end
		return
	end

	pending[key] = nil
	tried[key] = true
	if result and rec then
		minetest.log("action", string.format(
			"[lualore] Obsidian door shrine built (variant %s) near %d,%d",
			tostring(rec.variant), cx, cz))
	end
end

if ENABLED then
	minetest.register_on_generated(function(minp, maxp, blockseed)
		local variants = load_schematics()
		if not variants or next(variants) == nil then
			return
		end
		if maxp.y < Y_MIN or minp.y > Y_MAX then
			return
		end

		local c0x = math.floor((minp.x - SPACING * 3 / 4) / SPACING)
		local c1x = math.floor((maxp.x - SPACING / 4) / SPACING)
		local c0z = math.floor((minp.z - SPACING * 3 / 4) / SPACING)
		local c1z = math.floor((maxp.z - SPACING / 4) / SPACING)
		for cell_x = c0x, c1x do
			for cell_z = c0z, c1z do
				attempt_cell(cell_x, cell_z, minp, maxp)
			end
		end
	end)
end

-- ------------------------------------------------------------------
-- Public API
-- ------------------------------------------------------------------
lualore.obsidian_doors = {
	-- Build a shrine at (x, z) right now. Returns true/false/"retry".
	build_at = function(x, z, seed)
		local theme = theme_for_pos(x, z)
		if not theme then
			return false
		end
		local ok = build_site(x, z, nil, nil, seed)
		return ok
	end,
	get_records = get_records,
	get_island = function(key)
		local rec = get_records()[key]
		return rec and rec.island or nil
	end,
}

-- ------------------------------------------------------------------
-- Chat commands (tuning / debugging)
-- ------------------------------------------------------------------
minetest.register_chatcommand("spawn_obsidian_door", {
	params = "",
	description = S("Build an obsidian door shrine at your position (tuning aid)."),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local theme = theme_for_pos(pos.x, pos.z)
		if not theme then
			return false,
				"No dry/rugged ruin theme for this biome (desert/savanna only)."
		end
		local result, rec = build_site(math.floor(pos.x), math.floor(pos.z))
		if result == "retry" then
			return false, "Area is not fully generated yet - try again in a second."
		end
		if not result or not rec then
			return false, "No suitable spot found here."
		end
		return true, string.format(
			"Built an obsidian door shrine (variant %s, rotation %d).",
			tostring(rec.variant), rec.rot)
	end,
})

minetest.register_chatcommand("find_obsidian_door", {
	params = "[radius]",
	description = S("Find the nearest recorded obsidian door (default radius 512)."),
	privs = {},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local radius = tonumber(param) or 512
		local best, best_dist
		for _, rec in pairs(get_records()) do
			if type(rec) == "table" and rec.x then
				local dist = vector.distance(pos,
					{x = rec.x, y = rec.y or pos.y, z = rec.z})
				if dist <= radius and (not best_dist or dist < best_dist) then
					best, best_dist = rec, dist
				end
			end
		end
		if not best then
			return false, "No recorded obsidian door within " .. radius ..
				" nodes."
		end
		return true, string.format(
			"Nearest obsidian door: variant %s at %d,%d,%d (%.0f nodes away, %s)",
			tostring(best.variant), best.x, best.y, best.z, best_dist,
			best.active and "awakened" or "dormant")
	end,
})

minetest.register_chatcommand("clear_obsidian_door_records", {
	params = "",
	description = S("Forget obsidian door records (does not remove built shrines)."),
	privs = {server = true},
	func = function(name, param)
		local count = 0
		for _ in pairs(get_records()) do
			count = count + 1
		end
		records_cache = {}
		save_records()
		returns_cache = {}
		save_returns()
		return true, "Cleared " .. count .. " obsidian door records."
	end,
})

-- done
