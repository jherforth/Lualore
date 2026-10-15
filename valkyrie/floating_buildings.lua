-- floating_buildings.lua
-- ===================================================================
-- SKY SITES - deterministic grid placement on the floating islands
-- ===================================================================
-- The sky buildings used to be four schematic decorations (skycastle +
-- three skyhouses) sharing two noises. That packs them together and
-- stacks them on top of each other, for the same reasons the ground
-- villages did before villagers/systems/village_placement.lua replaced
-- them:
--
--   1. The engine places `sidelen^2 * noise_value` decorations per
--      sidelen division at RANDOM positions. With sidelen 120 and a
--      noise scale of 0.0018 that is up to ~26 sky houses inside one
--      120x120 division (and ~9 castles per 100x100 division) - every
--      one of them blitted with force_placement, so they overwrite each
--      other into a single mound of walls.
--   2. There is no spacing rule and no footprint test, so nothing stops
--      two buildings sharing a spot, and nothing checks that the island
--      underneath is big enough to hold them.
--   3. The castle rolled from its own noise at the same density as the
--      houses, so the building that holds the valkyrie chests was not
--      rare at all.
--
-- This replaces all of that with the village placer's approach:
--
--   * The sky is divided into a grid of `spacing` x `spacing` cells.
--     Each cell has ONE candidate position, jittered in the middle half
--     of the cell, so two sky sites can never be closer than half the
--     spacing.
--   * A cell builds when it passes the `chance` roll and the candidate
--     stands on a crystal island with enough solid ground around it.
--     Islands are read ONCE with a VoxelManip into a height grid, which
--     is then used for the support test, the footprint tests, the
--     foundations and the dressing.
--   * The layout is PLANNED COMPLETELY before anything is placed: the
--     castle (when a site rolls one) at the centre, then houses on a
--     ring whose radius follows an organic outline borrowed from
--     villagers/systems/village_ground.lua. Footprints may never
--     overlap and must sit on solid island.
--   * The castle is rolled separately and rarely (`castle_chance`), so
--     most sites are plain hamlets and the single valkyrie chest - now
--     placed ONLY inside the castle's own footprint, and always closed -
--     becomes a real find.
--   * Sites are recorded in mod storage, so a cell that already built
--     is not built again after a restart (sky islands span several
--     vertical chunks, any of which could otherwise trigger it).
--
-- All tuning lives in minetest.conf / settingtypes.txt:
--   lualore_sky_buildings        (bool,  default true)
--   lualore_sky_spacing          (int,   default 360)
--   lualore_sky_chance           (float, default 0.8)
--   lualore_sky_castle_chance    (float, default 0.15)
--   lualore_sky_houses_min       (int,   default 2)
--   lualore_sky_houses_max       (int,   default 6)
--   lualore_sky_radius           (int,   default 30)
--   lualore_sky_dressing         (bool,  default true)
--   lualore_sky_y_min            (int,   default 500)
--   lualore_sky_y_max            (int,   default 31000)
-- ===================================================================

local S = minetest.get_translator("lualore")

lualore = lualore or {}
lualore.floating_buildings = {}

local storage = minetest.get_mod_storage()
local MODPATH = minetest.get_modpath("lualore")
local ROTATIONS = {0, 90, 180, 270}

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

local ENABLED = minetest.settings:get_bool("lualore_sky_buildings", true)
local SPACING = clamp(math.floor(setting_number("lualore_sky_spacing", 360)), 160, 5000)
local CHANCE  = clamp(setting_number("lualore_sky_chance", 0.8), 0.0, 1.0)
local CASTLE_CHANCE = clamp(setting_number("lualore_sky_castle_chance", 0.15), 0.0, 1.0)
local HOUSES_MIN = clamp(math.floor(setting_number("lualore_sky_houses_min", 2)), 1, 12)
local HOUSES_MAX = clamp(math.floor(setting_number("lualore_sky_houses_max", 6)), 1, 12)
if HOUSES_MAX < HOUSES_MIN then
	HOUSES_MAX = HOUSES_MIN
end
local RADIUS  = clamp(math.floor(setting_number("lualore_sky_radius", 30)), 14, 60)
local DRESSING = minetest.settings:get_bool("lualore_sky_dressing", true)
local Y_MIN   = math.floor(setting_number("lualore_sky_y_min", 500))
local Y_MAX   = math.floor(setting_number("lualore_sky_y_max", 31000))
if Y_MIN > Y_MAX then
	Y_MIN, Y_MAX = Y_MAX, Y_MIN
end

-- How far a footprint's corners may sit from the site floor, and how
-- much of the cluster area has to be island for a site to be worth it.
local FOOTPRINT_SLACK = 2
local SUPPORT_SLACK   = 4
local SUPPORT_RATIO   = 0.5
-- Island reach needed for a hamlet at all, and for a castle site. The
-- castle alone is 22x22, so it needs room for a ring of houses outside it.
local MIN_EXTENT      = 12
local CASTLE_EXTENT   = 26

-- ------------------------------------------------------------------
-- Palette: what a sky site is built from. Same shape as the village
-- palettes in villagers/buildings/*.lua, so a second sky biome would
-- only need another table like this one.
-- ------------------------------------------------------------------
local SKY_PALETTE = {
	name = "sky",
	-- Island tops a site may stand on.
	surface = {
		"everness:dirt_with_crystal_grass",
		"everness:crystal_stone",
		"everness:crystal_sandstone",
		"everness:crystal_sand",
	},
	offset = -5,            -- schematic base is sunk 5 nodes into the island
	fill = "everness:crystal_stone", -- foundation under overhanging corners
	castle = "skycastle.mts",
	houses = {"skyhouse1.mts", "skyhouse2.mts", "skyhouse3.mts"},
	-- Ground dressing, handled by villagers/systems/village_ground.lua.
	ground = {
		base = "everness:dirt_with_crystal_grass",
		accents = {
			{"everness:crystal_stone", 5, bare = true},
			{"everness:crystal_sand", 3, bare = true},
		},
		worn = "everness:crystal_stone",
		path = "everness:crystal_sandstone_brick", -- laid paths between houses
	},
	plants = {
		density = 0.5, -- the islands already carry Everness' own growth
		list = {
			{"everness:sparkling_crystal_grass", 6},
			{"everness:ngrass_1", 5},
			{"everness:ngrass_2", 3},
			{"everness:crystal_bush", 1},
		},
	},
}

local SURFACE_SET = {}
for _, name in ipairs(SKY_PALETTE.surface) do
	SURFACE_SET[name] = true
end

-- ------------------------------------------------------------------
-- Node helpers
-- ------------------------------------------------------------------
local function get_name(pos)
	return minetest.get_node(pos).name
end

local function is_unknown(name)
	return name == "ignore" or name == "unknown"
end

local function is_walkable(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.walkable == true
end

-- Crystal trees are not ground: a site bases on the island under them.
local TREEISH_PARTS = {"tree", "wood", "trunk", "stem", "log", "leaves"}

local function is_treeish(name)
	for _, part in ipairs(TREEISH_PARTS) do
		if name:find(part, 1, true) then
			return true
		end
	end
	return false
end

-- Content ids are stable for the life of the server, so each one only
-- has to be classified once.
local CID_AIR = minetest.get_content_id("air")
local CID_IGNORE = minetest.get_content_id("ignore")
local class_cache = {}

local function classify(id)
	local c = class_cache[id]
	if c then
		return c
	end
	if id == CID_AIR then
		c = "air"
	elseif id == CID_IGNORE then
		c = "ignore"
	else
		local name = minetest.get_name_from_content_id(id)
		if is_treeish(name) then
			c = "tree"
		elseif is_walkable(name) then
			c = "solid"
		else
			c = "soft" -- grass, flowers, vines: stand on the node below
		end
	end
	class_cache[id] = c
	return c
end

-- ------------------------------------------------------------------
-- Schematic sizes (read once, then cached)
-- ------------------------------------------------------------------
local size_cache = {}

local function get_size(file)
	if size_cache[file] ~= nil then
		return size_cache[file] or nil
	end
	local path = MODPATH .. "/schematics/" .. file
	local ok, schem = pcall(minetest.read_schematic, path, {write_yslice_prob = "none"})
	if ok and type(schem) == "table" and type(schem.size) == "table" then
		local size = {x = schem.size.x, y = schem.size.y, z = schem.size.z}
		size_cache[file] = size
		return size
	end
	size_cache[file] = false
	minetest.log("warning", "[lualore] Could not read sky schematic " .. file)
	return nil
end

local function rotated_extent(size, rot)
	if rot == 90 or rot == 270 then
		return size.z, size.x
	end
	return size.x, size.z
end

local function placement_origin(cx, cz, size, rot)
	if rot == 90 or rot == 270 then
		return cx - math.floor((size.z - 1) / 2), cz - math.floor((size.x - 1) / 2)
	end
	return cx - math.floor((size.x - 1) / 2), cz - math.floor((size.z - 1) / 2)
end

local function boxes_overlap(a, b)
	return a.minx - 1 <= b.maxx and b.minx - 1 <= a.maxx
		and a.minz - 1 <= b.maxz and b.minz - 1 <= a.maxz
end

-- ------------------------------------------------------------------
-- Deterministic hashing (stable per world seed)
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
	world_salt = (salt * 31 + 761298345) % 2147483647
	return world_salt
end

local function hash_mix(n, value)
	return (n * 48271 + (value % 2147483647)) % 2147483647
end

local function cell_hash(cell_x, cell_z, salt)
	local h = hash_mix(get_world_salt(), cell_x)
	h = hash_mix(h, cell_z)
	return hash_mix(h, salt)
end

local function cell_candidate(cell_x, cell_z)
	local h = cell_hash(cell_x, cell_z, 41)
	if h > CHANCE * 2147483647 then
		return nil
	end
	local margin = math.floor(SPACING / 4)
	local span = math.max(1, SPACING - 2 * margin)
	local jitter_x = margin + (hash_mix(h, 131) % span)
	local jitter_z = margin + (hash_mix(h, 241) % span)
	return cell_x * SPACING + jitter_x, cell_z * SPACING + jitter_z,
		cell_hash(cell_x, cell_z, 1031)
end

-- ------------------------------------------------------------------
-- Island reading
-- ------------------------------------------------------------------
-- Topmost island surface in a column, scanning a y window with plain
-- node reads. Only used for the candidate column itself.
-- Returns y, or nil + "retry" when the column is not generated yet.
local function find_island_top(x, z, top, bottom)
	for y = top, bottom, -1 do
		local name = get_name({x = x, y = y, z = z})
		if is_unknown(name) then
			return nil, "retry"
		end
		if is_walkable(name) and not is_treeish(name) then
			return y, nil, name
		end
	end
	return nil
end

-- One VoxelManip read of the whole cluster area, reduced to a height
-- grid: grid[i] = surface y of that column, or nil for open sky. This
-- is what every later test reads, so the island is only ever touched
-- once. Returns grid, span, or nil + "retry".
local function read_island(cx, cz, floor_y, radius)
	-- Kept deliberately shallow: sky columns are mostly air, so every
	-- extra y level costs a full pass over the whole cluster area. The
	-- window only has to straddle the island's own surface - anything
	-- standing higher is a crystal tree or a spire the schematics
	-- overwrite anyway.
	local y_lo = floor_y - 14
	local y_hi = floor_y + 12
	local minp = {x = cx - radius, y = y_lo, z = cz - radius}
	local maxp = {x = cx + radius, y = y_hi, z = cz + radius}

	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})

	local span = radius * 2 + 1
	local grid = {}
	local unreadable, solid = 0, 0

	for dx = -radius, radius do
		for dz = -radius, radius do
			local x, z = cx + dx, cz + dz
			local top = nil
			local blocked = false
			for y = y_hi, y_lo, -1 do
				local class = classify(data[area:index(x, y, z)])
				if class == "ignore" then
					blocked = true
					break
				elseif class == "solid" then
					top = y
					break
				end
				-- air, soft plants and crystal trees: keep looking down
			end
			if blocked then
				unreadable = unreadable + 1
			elseif top then
				solid = solid + 1
				grid[(dx + radius) * span + (dz + radius) + 1] = top
			end
		end
	end

	if unreadable > span * span * 0.2 then
		return nil, "retry" -- island not fully generated yet
	end
	return grid, span, solid
end

local function grid_get(grid, span, radius, dx, dz)
	if dx < -radius or dx > radius or dz < -radius or dz > radius then
		return nil
	end
	return grid[(dx + radius) * span + (dz + radius) + 1]
end

-- How far the island reaches around the candidate: the widest ring that
-- is still mostly solid ground near the site floor. Fitting the cluster
-- to this rather than demanding a fixed disc matters - Everness islands
-- are small and ragged, and a fixed demand would simply refuse most of
-- them. Rings are sampled, not filled, so this stays cheap.
local function island_extent(grid, span, radius, floor_y)
	local best = 0
	for r = 6, radius, 2 do
		local hits = 0
		for a = 0, 23 do
			local ang = a * math.pi / 12
			local dx = math.floor(math.cos(ang) * r + 0.5)
			local dz = math.floor(math.sin(ang) * r + 0.5)
			local y = grid_get(grid, span, radius, dx, dz)
			if y and math.abs(y - floor_y) <= SUPPORT_SLACK then
				hits = hits + 1
			end
		end
		-- no break: one ring cut by a bay should not end the measurement
		if hits >= 24 * SUPPORT_RATIO then
			best = r
		end
	end
	return best
end

-- A footprint must stand on solid island: its corners, its centre and
-- its edge midpoints all near the site floor.
local function footprint_ok(grid, span, radius, cx, cz, minx, minz, ext_x, ext_z, floor_y)
	local maxx, maxz = minx + ext_x - 1, minz + ext_z - 1
	local midx = minx + math.floor((ext_x - 1) / 2)
	local midz = minz + math.floor((ext_z - 1) / 2)
	local checks = {
		{minx, minz}, {maxx, minz}, {minx, maxz}, {maxx, maxz},
		{midx, midz}, {midx, minz}, {midx, maxz}, {minx, midz}, {maxx, midz},
	}
	for _, c in ipairs(checks) do
		local y = grid_get(grid, span, radius, c[1] - cx, c[2] - cz)
		if not y or math.abs(y - floor_y) > FOOTPRINT_SLACK then
			return false
		end
	end
	return true
end

-- ------------------------------------------------------------------
-- Foundations: islands are ragged, so any footprint column left hanging
-- over air gets a short plug of island stone rather than a floating
-- corner. Nothing is carved away - only air is filled.
-- ------------------------------------------------------------------
local function pour_foundation(plan, fill_name)
	if not minetest.registered_nodes[fill_name] then
		return 0
	end
	local positions = {}
	local base = plan.base_y
	for x = plan.minx, plan.maxx do
		for z = plan.minz, plan.maxz do
			local depth = 0
			for y = base - 1, base - 5, -1 do
				local name = get_name({x = x, y = y, z = z})
				if name ~= "air" then
					break
				end
				positions[#positions + 1] = {x = x, y = y, z = z}
				depth = depth + 1
				if depth >= 4 then
					break
				end
			end
		end
	end
	if #positions == 0 then
		return 0
	end
	if minetest.bulk_set_node then
		minetest.bulk_set_node(positions, {name = fill_name})
	else
		for _, pos in ipairs(positions) do
			minetest.set_node(pos, {name = fill_name})
		end
	end
	return #positions
end

-- ------------------------------------------------------------------
-- The valkyrie chest. ONE per castle: opening it releases four
-- valkyries at once, so four chests meant sixteen.
--
-- The castle schematic carries four plain everness:mineral_torch nodes
-- as candidate anchors (its wall torches are mineral_torch_wall and are
-- left alone). Only torches INSIDE the castle footprint are considered,
-- so the chest belongs to the castle alone - skyhouse1 carries eight
-- plain torches of its own and used to swallow the chests whenever the
-- old radius search reached it first.
--
-- The chest is always placed as lualore:valkyrie_chest, the closed node.
-- set_node drops any metadata at the position, and the `opened` flag is
-- then written as 0 explicitly, so a freshly generated chest can never
-- start out already opened - its right-click has to be what starts the
-- fight.
-- ------------------------------------------------------------------
local CHEST_CLOSED = "lualore:valkyrie_chest"

local function set_closed_chest(pos)
	-- facing derived from the position, so a regenerated world puts the
	-- chest back exactly as it was
	local facing = (math.abs(pos.x * 7 + pos.z * 13)) % 4
	minetest.set_node(pos, {name = CHEST_CLOSED, param2 = facing})
	minetest.get_meta(pos):set_int("opened", 0)
end

local function place_castle_chest(plan)
	local size = get_size(plan.file)
	if not size then
		return 0
	end
	local minp = {x = plan.minx, y = plan.base_y, z = plan.minz}
	local maxp = {x = plan.maxx, y = plan.base_y + size.y + 2, z = plan.maxz}

	-- The schematic itself carries a valkyrie chest, and it was saved
	-- OPENED - whoever built the castle had opened it before the
	-- schematic was taken, so every castle generated with its prize
	-- already looted. That is the chest the designer meant to be there,
	-- in the room they meant it in, so it is the one to use: shut it and
	-- leave it. Any others are cleared, since opening one releases four
	-- valkyries and a castle only needs the one fight.
	local existing = minetest.find_nodes_in_area(minp, maxp,
		{"lualore:valkyrie_chest", "lualore:valkyrie_chest_opened"})
	if #existing > 0 then
		set_closed_chest(existing[1])
		for i = 2, #existing do
			minetest.set_node(existing[i], {name = "air"})
		end
		return 1
	end

	-- No chest in the schematic: fall back to the mineral torches it
	-- carries as anchors.
	local torches = minetest.find_nodes_in_area(minp, maxp, {"everness:mineral_torch"})

	-- Lowest anchor wins, nearest the middle of the castle on a tie: the
	-- chest belongs on a floor the player walks onto, not up in a tower.
	local mid_x = (plan.minx + plan.maxx) / 2
	local mid_z = (plan.minz + plan.maxz) / 2
	local best, best_key
	for _, pos in ipairs(torches) do
		if get_name({x = pos.x, y = pos.y - 1, z = pos.z}) ~= "air" then
			local dx, dz = pos.x - mid_x, pos.z - mid_z
			-- y dominates; distance breaks ties; coordinates settle the rest
			local key = pos.y * 100000 + (dx * dx + dz * dz) * 10
				+ (pos.x % 7) + (pos.z % 11) / 100
			if not best_key or key < best_key then
				best, best_key = pos, key
			end
		end
	end
	if not best then
		return 0
	end
	set_closed_chest(best)
	return 1
end

-- ------------------------------------------------------------------
-- Dressing: hand the island top around the buildings to the village
-- ground module, which scatters crystal grass, lays the paths between
-- the houses and roughens the bare ground the schematics leave behind.
-- ------------------------------------------------------------------
local function dress_site(cx, cz, floor_y, seed, grid, span, radius, cluster_r, plans)
	local ground = lualore.village_ground
	if not (DRESSING and ground) then
		return 0
	end
	local columns = {}
	for dx = -cluster_r, cluster_r do
		for dz = -cluster_r, cluster_r do
			if dx * dx + dz * dz <= cluster_r * cluster_r then
				local y = grid_get(grid, span, radius, dx, dz)
				if y and math.abs(y - floor_y) <= SUPPORT_SLACK then
					local name = get_name({x = cx + dx, y = y, z = cz + dz})
					if SURFACE_SET[name] then
						columns[#columns + 1] = {x = cx + dx, y = y, z = cz + dz}
					end
				end
			end
		end
	end
	if #columns == 0 then
		return 0
	end
	local ok, first, planted = pcall(ground.dress, {
		cx = cx,
		cz = cz,
		floor_y = floor_y,
		palette = SKY_PALETTE,
		seed = seed,
		columns = columns,
		plans = plans,
	})
	if not ok then
		minetest.log("warning", "[lualore] Sky dressing failed: " .. tostring(first))
		return 0
	end
	return planted or 0
end

-- ------------------------------------------------------------------
-- Building one site
-- ------------------------------------------------------------------
-- Returns false (nothing here), "retry" (island not generated yet), or
-- true, houses, castle_placed, floor_y, chest (0/1), planted.
local function build_site(cx, cz, seed, scan_top, scan_bottom, opts)
	opts = opts or {}
	local top = math.min(Y_MAX, scan_top or Y_MAX)
	local bottom = math.max(Y_MIN, scan_bottom or Y_MIN)
	if opts.any_height then
		top, bottom = scan_top or Y_MAX, scan_bottom or Y_MIN
	end
	if top < bottom then
		return false
	end

	local floor_y, err, floor_name = find_island_top(cx, cz, top, bottom)
	if err == "retry" then
		return "retry"
	end
	if not floor_y or not SURFACE_SET[floor_name] then
		return false -- open sky, or a rock that is not a crystal island
	end

	local pr = PcgRandom(seed)
	local target = pr:next(HOUSES_MIN, HOUSES_MAX)
	if opts.houses then
		target = opts.houses -- a founded village asks for its size
	end
	local want_castle = opts.force_castle
		or (not opts.no_castle and pr:next(0, 9999) < CASTLE_CHANCE * 10000)

	local cluster_r = math.min(RADIUS + math.max(0, target - 3) * 2,
		opts.max_radius or 46)
	if want_castle then
		cluster_r = cluster_r + 6 -- room for the castle in the middle
	end
	local read_r = cluster_r + 4

	local grid, span, solid = read_island(cx, cz, floor_y, read_r)
	if not grid then
		return "retry"
	end
	if not solid or solid == 0 then
		return false
	end

	-- Fit the cluster to the island instead of demanding the island fit
	-- the cluster. Too small for even a hamlet and nothing is built; too
	-- small for a fortress and the site stays a hamlet.
	local extent = island_extent(grid, span, read_r, floor_y)
	if extent < MIN_EXTENT then
		return false
	end
	if want_castle and extent < CASTLE_EXTENT then
		want_castle = false
	end
	cluster_r = math.min(cluster_r, extent)

	local plans = {}
	local castle_plan = nil

	-- 1. The castle takes the middle when the site rolled one. If the
	--    island cannot hold its 22x22 footprint the site stays a hamlet
	--    rather than dropping a castle over the edge.
	if want_castle and SKY_PALETTE.castle then
		local size = get_size(SKY_PALETTE.castle)
		if size then
			for _, off in ipairs({{0, 0}, {0, -6}, {6, 0}, {0, 6}, {-6, 0}}) do
				local bx, bz = cx + off[1], cz + off[2]
				local rot = ROTATIONS[pr:next(1, 4)]
				local minx, minz = placement_origin(bx, bz, size, rot)
				local ext_x, ext_z = rotated_extent(size, rot)
				if footprint_ok(grid, span, read_r, cx, cz, minx, minz,
						ext_x, ext_z, floor_y) then
					castle_plan = {
						minx = minx, maxx = minx + ext_x - 1,
						minz = minz, maxz = minz + ext_z - 1,
						file = SKY_PALETTE.castle, rot = rot,
						base_y = floor_y + (SKY_PALETTE.offset or 0),
						castle = true,
					}
					plans[#plans + 1] = castle_plan
					break
				end
			end
		end
	end

	-- 2. Houses on a ring around the middle. The ring radius follows the
	--    village module's organic outline, so the hamlet is a lobed
	--    scatter rather than a wheel of houses at one radius.
	local ground = lualore.village_ground
	local shape = ground and ground.new_shape(seed + 5171, cluster_r * 0.78,
		cluster_r * 0.55, 4) or nil
	-- Clear of the castle's 22x22 footprint plus the widest house's half
	-- extent, so the ring does not spend its tries bumping into the middle.
	-- On a small island the inner radius has to give way to the outer one.
	local r_in = castle_plan and 21 or math.min(10, math.max(4, cluster_r - 8))
	local base_angle = pr:next(0, 9999) / 10000 * math.pi * 2
	local house_count = 0

	for i = 1, target do
		local slot = base_angle + (i - 1) * (math.pi * 2 / target)
			+ (pr:next(-50, 50) / 100)
		for _ = 1, opts.tries or 8 do
			local cosa, sina = math.cos(slot), math.sin(slot)
			local r_out = cluster_r
			if shape then
				r_out = math.max(r_in + 2, (shape:profile(cosa, sina)))
			end
			local radius = r_in + pr:next(0, math.max(1, math.floor(r_out - r_in)))
			local bx = cx + math.floor(cosa * radius + 0.5)
			local bz = cz + math.floor(sina * radius + 0.5)
			local file = SKY_PALETTE.houses[pr:next(1, #SKY_PALETTE.houses)]
			local size = get_size(file)
			if size then
				local rot = ROTATIONS[pr:next(1, 4)]
				local minx, minz = placement_origin(bx, bz, size, rot)
				local ext_x, ext_z = rotated_extent(size, rot)
				local box = {
					minx = minx, maxx = minx + ext_x - 1,
					minz = minz, maxz = minz + ext_z - 1,
				}
				local clear = true
				for _, other in ipairs(plans) do
					if boxes_overlap(box, other) then
						clear = false
						break
					end
				end
				if clear and footprint_ok(grid, span, read_r, cx, cz, minx, minz,
						ext_x, ext_z, floor_y) then
					box.file = file
					box.rot = rot
					box.base_y = floor_y + (SKY_PALETTE.offset or 0)
					plans[#plans + 1] = box
					house_count = house_count + 1
					break
				end
			end
			slot = slot + 0.55 -- nudge along the ring and try again
		end
	end

	if #plans == 0 then
		return false
	end

	-- 3. Executing a fully validated plan can no longer fail.
	for _, plan in ipairs(plans) do
		minetest.place_schematic(
			{x = plan.minx, y = plan.base_y, z = plan.minz},
			MODPATH .. "/schematics/" .. plan.file,
			tostring(plan.rot), nil, true)
	end
	for _, plan in ipairs(plans) do
		pour_foundation(plan, SKY_PALETTE.fill)
	end

	local chest = 0
	if castle_plan then
		chest = place_castle_chest(castle_plan)
	end

	local planted = dress_site(cx, cz, floor_y, seed, grid, span, read_r,
		cluster_r, plans)

	return true, house_count, castle_plan ~= nil, floor_y, chest, planted
end

-- ------------------------------------------------------------------
-- Records (persistent: a cell that built once never builds again)
-- ------------------------------------------------------------------
local function load_records()
	local data = storage:get_string("sky_sites")
	if data ~= "" then
		local records = minetest.deserialize(data)
		if type(records) == "table" then
			return records
		end
	end
	return {}
end

local records = load_records()

local function record_site(cell_key, x, y, z, houses, castle, chest, extra)
	records[cell_key] = {
		x = x, y = y, z = z,
		houses = houses,
		castle = castle and 1 or 0,
		chest = chest,
	}
	for k, v in pairs(extra or {}) do
		records[cell_key][k] = v
	end
	storage:set_string("sky_sites", minetest.serialize(records))
end

-- ------------------------------------------------------------------
-- Placement driver
-- ------------------------------------------------------------------
local attempted = {} -- "cellx:cellz:chunky" -> true (one try per vertical chunk)
local pending = {}   -- same key -> remaining retry budget

local function spawn_founders(pos, cell_key)
	if lualore.sky_villages and lualore.sky_villages.spawn_sky_folk then
		lualore.sky_villages.spawn_sky_folk(pos, "sky_site_" .. cell_key)
	end
end

local function attempt_cell(cell_x, cell_z, minp, maxp)
	local cell_key = cell_x .. ":" .. cell_z
	if records[cell_key] then
		return -- this cell already has its site
	end
	local chunk_key = cell_key .. ":" .. math.floor(minp.y / 80)
	local is_retry = pending[chunk_key] ~= nil
	if attempted[chunk_key] and not is_retry then
		return
	end

	local cx, cz, seed = cell_candidate(cell_x, cell_z)
	if not cx then
		attempted[chunk_key] = true
		return
	end
	if not is_retry and (cx < minp.x or cx > maxp.x or cz < minp.z or cz > maxp.z) then
		return
	end
	attempted[chunk_key] = true

	local result, houses, castle, floor_y, chest, planted =
		build_site(cx, cz, seed, maxp.y, minp.y)

	if result == "retry" then
		local left = (pending[chunk_key] or 25) - 1
		if left > 0 then
			pending[chunk_key] = left
			minetest.after(0.7, function()
				attempt_cell(cell_x, cell_z, minp, maxp)
			end)
		else
			pending[chunk_key] = nil
		end
		return
	end

	pending[chunk_key] = nil
	if result then
		record_site(cell_key, cx, floor_y, cz, houses, castle, chest)
		spawn_founders({x = cx, y = floor_y, z = cz}, cell_key)
		minetest.log("action", string.format(
			"[lualore] Sky site built at %d,%d,%d - %d houses, %s, %s, %d plants",
			cx, floor_y, cz, houses,
			castle and "CASTLE" or "no castle",
			(chest or 0) > 0 and "chest" or "no chest", planted or 0))
	end
end

if ENABLED then
	minetest.register_on_generated(function(minp, maxp, blockseed)
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
-- Adding a castle to a standing site
-- ------------------------------------------------------------------
-- Is the space above the floor open - nothing but air and plants? The
-- island grid alone cannot tell: inside a house the first solid node down
-- from the read window is the house's own floor, which looks like island.
local function volume_open(minx, maxx, minz, maxz, y_lo, y_hi)
	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map({x = minx, y = y_lo, z = minz},
		{x = maxx, y = y_hi, z = maxz})
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	for z = minz, maxz do
		for y = y_lo, y_hi do
			for x = minx, maxx do
				local class = classify(data[area:index(x, y, z)])
				if class ~= "air" and class ~= "soft" then
					return false
				end
			end
		end
	end
	return true
end

-- Give a standing site its castle. A portal town must have one - opening
-- its valkyrie chest starts the fight that frees the Sky Folk - and a town
-- that was built without one already has houses standing, with no record
-- of where. So the castle goes wherever the island has open ground for its
-- whole footprint and height: the middle first, then rings outward. With
-- opts.at = {x = , z = } only that spot is tried (a rock raised beside the
-- town for it). Returns true once the site has a castle, false if nowhere
-- fits. The area must already be loaded.
local function add_castle(key, opts)
	opts = opts or {}
	local site = records[key]
	if not site then
		return false
	end
	if site.castle == 1 then
		return true
	end
	local size = get_size(SKY_PALETTE.castle)
	if not size then
		return false
	end
	local floor_y = site.y
	local cx = opts.at and opts.at.x or site.x
	local cz = opts.at and opts.at.z or site.z
	local read_r = opts.at and 24 or 72
	local grid, span = read_island(cx, cz, floor_y, read_r)
	if not grid then
		return false
	end

	local spots = {{0, 0}}
	if not opts.at then
		for r = 8, read_r - 12, 6 do
			local n = math.max(8, math.floor(r / 2))
			for i = 0, n - 1 do
				local a = i * 2 * math.pi / n
				spots[#spots + 1] = {math.floor(math.cos(a) * r + 0.5),
					math.floor(math.sin(a) * r + 0.5)}
			end
		end
	end

	local base_y = floor_y + (SKY_PALETTE.offset or 0)
	local top_y = base_y + size.y - 1
	local ext_x, ext_z = rotated_extent(size, 0)
	for _, off in ipairs(spots) do
		local minx, minz = placement_origin(cx + off[1], cz + off[2], size, 0)
		local maxx, maxz = minx + ext_x - 1, minz + ext_z - 1
		if footprint_ok(grid, span, read_r, cx, cz, minx, minz, ext_x, ext_z, floor_y)
				and volume_open(minx, maxx, minz, maxz, floor_y + 1, top_y) then
			local plan = {
				minx = minx, maxx = maxx, minz = minz, maxz = maxz,
				file = SKY_PALETTE.castle, rot = 0,
				base_y = base_y, castle = true,
			}
			minetest.place_schematic({x = minx, y = base_y, z = minz},
				MODPATH .. "/schematics/" .. plan.file, "0", nil, true)
			pour_foundation(plan, SKY_PALETTE.fill)
			site.castle = 1
			site.chest = place_castle_chest(plan)
			storage:set_string("sky_sites", minetest.serialize(records))
			minetest.log("action", string.format(
				"[lualore] Skycastle added to sky site %s at %d,%d,%d (%s)",
				key, cx + off[1], floor_y, cz + off[2],
				site.chest > 0 and "chest" or "NO CHEST"))
			return true
		end
	end
	return false
end

-- ------------------------------------------------------------------
-- Public API
-- ------------------------------------------------------------------
lualore.floating_buildings = {
	build_at = function(x, z, opts)
		return build_site(x, z, opts and opts.seed
			or (get_world_salt() + os.time() % 100000),
			opts and opts.top, opts and opts.bottom, opts)
	end,
	palette = SKY_PALETTE,
	records = function()
		return records
	end,
	-- Build a site at (x, z) and register it like a grid-built one, Sky Folk
	-- and all. Sky portals use this to found a village where none exists.
	-- It is recorded under the grid cell it stands in when that cell is
	-- still free, so the grid never builds a second site beside it; a cell
	-- that already has a site keeps it, and this one gets a key of its own.
	-- opts: top/bottom (the island top's height window), seed, and for a
	-- bigger village houses, max_radius and tries (see build_site); big =
	-- true marks the record and spreads more Sky Folk around the ring.
	-- Returns true, record, key; or whatever build_site returned
	-- (false / "retry").
	found_at = function(x, z, opts)
		opts = opts or {}
		local cell_key = math.floor(x / SPACING) .. ":" .. math.floor(z / SPACING)
		local key = cell_key
		if records[cell_key] then
			key = "founded:" .. x .. ":" .. z
			if records[key] then
				return false, "taken"
			end
		end
		local seed = opts.seed or
			(get_world_salt() + x * 73856093 + z * 19349663) % 2147483647
		local result, houses, castle, floor_y, chest, planted =
			build_site(x, z, seed, opts.top, opts.bottom, opts)
		if result ~= true then
			return result
		end
		record_site(key, x, floor_y, z, houses, castle, chest,
			opts.big and {big = 1} or nil)
		spawn_founders({x = x, y = floor_y, z = z}, key)
		-- Founders arrive around the middle; a big village also gets a group
		-- for every six houses out on its ring, or its edges stand empty.
		local groups = opts.big and math.floor(houses / 6) or 0
		local ring = math.floor((opts.max_radius or 46) * 0.55)
		for i = 1, groups do
			local a = (i - 1) * 2 * math.pi / groups
			spawn_founders({
				x = x + math.floor(math.cos(a) * ring + 0.5),
				y = floor_y,
				z = z + math.floor(math.sin(a) * ring + 0.5),
			}, key .. ":" .. i)
		end
		minetest.log("action", string.format(
			"[lualore] Sky site founded at %d,%d,%d - %d houses, %s, %d plants",
			x, floor_y, z, houses, castle and "CASTLE" or "no castle",
			planted or 0))
		return true, records[key], key
	end,
	-- Give a standing site its castle (see add_castle above).
	add_castle = add_castle,
	-- Write the records back after changing one in place.
	save = function()
		storage:set_string("sky_sites", minetest.serialize(records))
	end,
	enabled = ENABLED,
	spacing = SPACING,
	y_min = Y_MIN,
	y_max = Y_MAX,
	surface = SKY_PALETTE.ground.base,
}

-- ------------------------------------------------------------------
-- Commands
-- ------------------------------------------------------------------
minetest.register_chatcommand("spawn_skysite", {
	params = "[castle|hamlet]",
	description = S("Build a sky site on the island you are standing on " ..
		"(castle = force the skycastle, hamlet = houses only)."),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local opts = {
			any_height = true,
			top = math.floor(pos.y) + 8,
			bottom = math.floor(pos.y) - 40,
		}
		if param == "castle" then
			opts.force_castle = true
		elseif param == "hamlet" then
			opts.no_castle = true
		end
		local result, houses, castle, floor_y, chest, planted =
			lualore.floating_buildings.build_at(
				math.floor(pos.x), math.floor(pos.z), opts)
		if result == "retry" then
			return false, S("Island is not fully generated yet - try again in a second.")
		end
		if not result then
			return false, S("No crystal island with enough room here.")
		end
		return true, string.format(
			"Sky site built at y=%d: %d houses, %s, %s, %d plants.",
			floor_y, houses, castle and "castle" or "no castle",
			(chest or 0) > 0 and "1 closed chest" or "no chest", planted or 0)
	end,
})

minetest.register_chatcommand("find_skysite", {
	params = "[radius]",
	description = S("Find the nearest recorded sky site (default radius 2000)."),
	privs = {},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local radius = tonumber(param) or 2000
		local best, best_dist
		for _, rec in pairs(records) do
			if type(rec) == "table" and rec.x then
				local dist = vector.distance(pos,
					{x = rec.x, y = rec.y or pos.y, z = rec.z})
				if dist <= radius and (best_dist == nil or dist < best_dist) then
					best, best_dist = rec, dist
				end
			end
		end
		if not best then
			return false, S("No recorded sky site within @1 nodes.", radius)
		end
		return true, string.format(
			"Nearest sky site: %d,%d,%d (%d nodes away) - %d houses, %s%s",
			best.x, best.y or 0, best.z, math.floor(best_dist), best.houses or 0,
			(best.castle == 1) and "castle" or "no castle",
			(best.chest or 0) > 0 and " with a chest" or "")
	end,
})

-- Repair tool for castles built before the placer existed (or before
-- chests became castle-only). Places ONE closed chest, on the mineral
-- torch nearest the player, so the admin decides which room gets it.
minetest.register_chatcommand("place_fortress_chests", {
	params = "",
	description = S("Place one closed valkyrie chest on the nearest mineral " ..
		"torch (repair tool for older worlds)"),
	privs = {give = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, S("Player not found")
		end

		local pos = player:get_pos()
		local torch_positions = minetest.find_nodes_in_area(
			vector.subtract(pos, {x = 50, y = 25, z = 50}),
			vector.add(pos, {x = 50, y = 25, z = 50}),
			{"everness:mineral_torch"}
		)

		if #torch_positions == 0 then
			return false, S("No fortress torches found nearby. Stand closer to a sky fortress.")
		end

		local best, best_dist
		for _, torch_pos in ipairs(torch_positions) do
			if get_name({x = torch_pos.x, y = torch_pos.y - 1, z = torch_pos.z}) ~= "air" then
				local dist = vector.distance(pos, torch_pos)
				if not best_dist or dist < best_dist then
					best, best_dist = torch_pos, dist
				end
			end
		end
		if not best then
			return false, S("The torches nearby have nothing to stand on.")
		end

		set_closed_chest(best)
		return true, string.format(
			"Closed valkyrie chest placed at %s (%d nodes away).",
			minetest.pos_to_string(best), math.floor(best_dist))
	end,
})

minetest.log("action", string.format(
	"[lualore] Sky sites %s (spacing %d, chance %.2f, castle chance %.2f)",
	ENABLED and "enabled" or "disabled", SPACING, CHANCE, CASTLE_CHANCE))
