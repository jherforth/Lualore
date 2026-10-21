-- ruins/ruins.lua
-- ===================================================================
-- PROCEDURAL RUINS - broken castles, ruined towers, collapsed walls
-- and ancient stone circles, scattered across specific biomes.
-- ===================================================================
-- Unlike the village buildings (fixed schematics), ruins are generated
-- node by node with a deterministic random generator, which lets them
-- look truly "ruined": walls crumble towards their tops, whole sections
-- collapse, rubble scatters around the walls and the structures follow
-- the terrain instead of demanding a perfect flat spot.
--
-- Placement uses the same proven grid approach as village_placement.lua:
--
--   * The world is divided into `spacing` x `spacing` cells (450 nodes
--     by default). Each cell has ONE candidate position, jittered in the
--     middle half of the cell, so ruins can never crowd each other.
--   * A cell spawns a ruin when it passes the `chance` roll, the biome
--     at the candidate maps to a ruin theme (materials per biome, see
--     below), and the terrain is acceptable for the chosen ruin type.
--   * Each ruin is PLANNED completely (all nodes decided) before a single
--     block is written, using a VoxelManip. Unreadable (not yet
--     generated) nodes abort with a retry, so failed attempts leave
--     nothing behind.
--   * Ruins keep a respectful distance from recorded villages and often
--     hide a chest that the existing loot system fills by biome.
--
-- Tuning (minetest.conf / settingtypes.txt):
--   lualore_ruins           (bool,  default true)
--   lualore_ruin_spacing    (int,   default 450)
--   lualore_ruin_chance     (float, default 0.75)
--   lualore_ruin_chests     (bool,  default true)
--   lualore_ruin_y_max      (int,   default 200)
--   lualore_ruin_y_min      (int,   default -2)
--
-- Themes can be extended by other mods via:
--   lualore.register_ruin_theme("mymod:mushroom", {
--       biomes = {"mymod:fungal_forest"},
--       wall   = {"mymod:mushroom_brick"},
--       floor  = {"mymod:mushroom_wood"},
--       rubble = {"mymod:mushroom_stem"},
--   })
-- ===================================================================

local S = minetest.get_translator("lualore")

lualore = lualore or {}
lualore.ruin_themes = lualore.ruin_themes or {}

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

local ENABLED    = minetest.settings:get_bool("lualore_ruins", true)
local SPACING    = clamp(math.floor(setting_number("lualore_ruin_spacing", 450)), 200, 5000)
local CHANCE     = clamp(setting_number("lualore_ruin_chance", 0.75), 0.0, 1.0)
local WANT_CHESTS = minetest.settings:get_bool("lualore_ruin_chests", true)
local Y_MAX      = math.floor(setting_number("lualore_ruin_y_max", 200))
local Y_MIN      = math.floor(setting_number("lualore_ruin_y_min", -2))
if Y_MIN > Y_MAX then
	Y_MIN, Y_MAX = Y_MAX, Y_MIN
end

local MODPATH = minetest.get_modpath("lualore")

-- Mod storage reference, fetched at load time: calling
-- minetest.get_mod_storage() later (on_generated, commands, ...)
-- returns nil on some engines, so it is cached once here.
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

-- Trees are walkable too, but a ruin should never base itself on a tree top.
local function is_treeish(name)
	return string.find(name, "wood", 1, true) ~= nil
		or string.find(name, "tree", 1, true) ~= nil
		or string.find(name, "trunk", 1, true) ~= nil
		or string.find(name, "stem", 1, true) ~= nil
end

local function passable(name, water_ok)
	return name == "air" or (water_ok and is_liquid(name))
end

-- ------------------------------------------------------------------
-- Themes (material sets per biome family)
-- ------------------------------------------------------------------
local function resolve(list, fallback)
	local out = {}
	for _, name in ipairs(list or {}) do
		if minetest.registered_nodes[name] then
			out[#out + 1] = name
		end
	end
	if #out == 0 and fallback and minetest.registered_nodes[fallback] then
		out[1] = fallback
	end
	return out
end

local ordered_themes = nil

function lualore.register_ruin_theme(name, def)
	if not name or type(def) ~= "table" then
		return
	end
	ordered_themes = nil
	lualore.ruin_themes[name] = {
		name = name,
		biomes = def.biomes or {},
		water_ok = def.water_ok == true,
		wall = resolve(def.wall or {}, "default:stone"),
		floor = resolve(def.floor or def.wall or {}, "default:cobble"),
		rubble = resolve(def.rubble or def.wall or {}, "default:cobble"),
		glow = resolve(def.glow or {}, nil),
	}
end

lualore.register_ruin_theme("grassland", {
	biomes = {
		"grassland", "grassytwo", "deciduous_forest", "coniferous_forest",
		"grove", "dorwinion", "naturalbiomes:mediterranean", "naturalbiomes:heath",
	},
	wall = {"default:stonebrick", "default:mossycobble", "default:stonebrick"},
	floor = {"default:stonebrick", "default:cobble", "default:mossycobble"},
	rubble = {"default:cobble", "default:mossycobble", "default:gravel"},
	glow = {"default:meselamp"},
})

lualore.register_ruin_theme("desert", {
	biomes = {"desert", "mesa", "sandstone_desert", "badland", "everness:forsaken_desert"},
	wall = {"default:desert_sandstone_brick", "default:sandstonebrick", "default:desert_sandstone"},
	floor = {"default:desert_sandstone_block", "default:desert_sandstone_brick", "default:sandstonebrick"},
	rubble = {"default:desert_cobble", "default:sand", "default:desert_sand"},
	glow = {"default:meselamp"},
})

lualore.register_ruin_theme("savanna", {
	biomes = {
		"savanna", "prarie", "prairie", "plains",
		"naturalbiomes:outback", "naturalbiomes:bushland",
	},
	wall = {"default:sandstonebrick", "default:desert_sandstone_brick", "default:sandstone"},
	floor = {"default:sandstonebrick", "default:sandstone"},
	rubble = {"default:sandstone", "default:desert_cobble", "default:dry_dirt"},
	glow = {},
})

lualore.register_ruin_theme("ice", {
	biomes = {
		"icesheet", "icesheet_ocean", "glacier", "frost_land", "tundra",
		"tundra_highland", "frost", "everness:forsaken_tundra", "everness:frosted_icesheet",
	},
	wall = {"default:stonebrick", "default:ice", "default:snowblock"},
	floor = {"default:stonebrick", "default:ice"},
	rubble = {"default:snowblock", "default:ice", "default:gravel"},
	glow = {},
})

lualore.register_ruin_theme("jungle", {
	biomes = {
		"rainforest", "rainforest_swamp", "bamboo", "everness:bamboo_forest",
		"japaneseforest", "livingjungle:jungle",
	},
	wall = {"default:mossycobble", "default:stonebrick", "default:junglewood"},
	floor = {"default:mossycobble", "default:cobble"},
	rubble = {"default:cobble", "default:mossycobble", "default:junglewood"},
	glow = {"default:meselamp"},
})

lualore.register_ruin_theme("lake", {
	biomes = {
		"deciduous_forest_shore",
		"coniferous_forest_shore",
		"coniferous_forest_ocean",
		"deciduous_forest_ocean",
		"swamp_shore",
		"swamp",
		"marsh",
		"naturalbiomes:alderswamp",
	},
	water_ok = true, -- sunken ruins are fine at lake shores
	wall = {"default:mossycobble", "default:cobble"},
	floor = {"default:cobble", "default:clay"},
	rubble = {"default:cobble", "default:gravel", "default:clay"},
	glow = {},
})

local function get_themes()
	if ordered_themes then
		return ordered_themes
	end
	ordered_themes = {}
	local names = {}
	for name in pairs(lualore.ruin_themes) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		ordered_themes[#ordered_themes + 1] = lualore.ruin_themes[name]
	end
	return ordered_themes
end

-- Biome names can be namespaced ("mod:biome"); match the full name first,
-- then the part after the ":" so "grassland" also matches "everness:grassland".
local function biome_matches(pattern, biome)
	if pattern == biome then
		return true
	end
	local a = pattern:match(":([^:]+)$") or pattern
	local b = biome:match(":([^:]+)$") or biome
	return a == b
end

local function theme_for_pos(x, z)
	local data = minetest.get_biome_data({x = x, y = 64, z = z})
	if not data then
		return nil
	end
	local biome = minetest.get_biome_name(data.biome)
	if not biome then
		return nil
	end
	for _, theme in ipairs(get_themes()) do
		for _, name in ipairs(theme.biomes) do
			if biome_matches(name, biome) then
				return theme
			end
		end
	end
	return nil
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
	world_salt = (salt * 31 + 556677889) % 2147483647
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
	local h = cell_hash(cell_x, cell_z, 41)
	if h > CHANCE * 2147483647 then
		return nil
	end
	local margin = math.floor(SPACING / 4)
	local span = math.max(1, SPACING - 2 * margin)
	local jitter_x = margin + (hash_mix(h, 137) % span)
	local jitter_z = margin + (hash_mix(h, 269) % span)
	return cell_x * SPACING + jitter_x, cell_z * SPACING + jitter_z,
		cell_hash(cell_x, cell_z, 1013)
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
-- Build context
-- ------------------------------------------------------------------
local CHEST_NODE = nil
if minetest.registered_nodes["default:chest"] then
	CHEST_NODE = "default:chest"
elseif minetest.registered_nodes["default:chest_locked"] then
	CHEST_NODE = "default:chest_locked"
end

local function pick(pr, list)
	if not list or #list == 0 then
		return nil
	end
	return list[pr:next(1, #list)]
end

-- Floor of a column relative to the ruin base, plus min/max tracking.
-- Returns y, or nil, or nil + "retry" when the area is not generated.
local function ctx_floor(ctx, x, z)
	local key = x .. ":" .. z
	local cached = ctx.cache[key]
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
	end

	local y, err = find_floor_near(x, z, ctx.base, 5, ctx.top, ctx.bottom)
	if err == "retry" then
		return nil, "retry"
	end

	if y then
		local above = get_name({x = x, y = y + 1, z = z})
		if is_unknown(above) then
			return nil, "retry"
		end
		if is_lava(above) then
			ctx.invalid = true
		end
		if is_liquid(above) and not ctx.theme.water_ok then
			y = nil -- underwater columns only count for water themes
		end
	end

	ctx.cache[key] = y or false
	if y then
		ctx.min_floor = math.min(ctx.min_floor, y)
		ctx.max_floor = math.max(ctx.max_floor, y)
	end
	return y
end

-- Validate a list of required columns (list of {x, z}).
local function validate_columns(ctx, cols)
	local seen = {}
	local total, missing = 0, 0
	for _, c in ipairs(cols) do
		local key = c[1] .. ":" .. c[2]
		if not seen[key] then
			seen[key] = true
			total = total + 1
			local y, err = ctx_floor(ctx, c[1], c[2])
			if err == "retry" then
				return "retry"
			end
			if not y then
				missing = missing + 1
			end
		end
	end
	if ctx.invalid then
		return false
	end
	if total == 0 or missing > total * 0.25 then
		return false
	end
	if ctx.max_floor - ctx.min_floor > 6 then
		return false
	end
	return true
end

local function put(ctx, x, y, z, mat)
	ctx.plan[#ctx.plan + 1] = {x = x, y = y, z = z, m = mat}
end

-- A wall height profile along a line of cells: random walk with collapse.
local function profile(pr, n, hmin, hmax, collapse)
	local out = {}
	local h = pr:next(hmin, hmax)
	for i = 1, n do
		h = math.max(1, math.min(hmax + 2, h + pr:next(-1, 1)))
		if pr:next(1, 100) <= collapse then
			out[i] = 0 -- collapsed section
		else
			out[i] = h
		end
	end
	return out
end

local function write_wall_column(ctx, x, z, y, h, mat, crumble)
	if h <= 0 then
		return
	end
	for dy = 1, h do
		if dy >= h - 1 and ctx.pr:next(1, 100) <= crumble then
			break -- the top crumbles away
		end
		local use = mat
		if #ctx.theme.glow > 0 and ctx.pr:next(1, 160) == 1 then
			use = ctx.theme.glow[ctx.pr:next(1, #ctx.theme.glow)]
		end
		put(ctx, x, y + dy, z, use)
	end
end

-- ------------------------------------------------------------------
-- Ruin generators
-- ------------------------------------------------------------------

-- Broken castle: outer walls with a gate, corner towers, inner keep,
-- flagstone patches and rubble.
local function gen_castle(ctx)
	local pr = ctx.pr
	local S = 19 + 2 * pr:next(0, 4)
	local half = math.floor(S / 2)
	local minx, minz = ctx.x - half, ctx.z - half
	local maxx, maxz = minx + S - 1, minz + S - 1

	-- Perimeter cells (ordered, with a coordinate->index map)
	local perimeter, index_of = {}, {}
	local function add_p(x, z)
		perimeter[#perimeter + 1] = {x, z}
		index_of[x .. ":" .. z] = #perimeter
	end
	for i = 0, S - 1 do add_p(minx + i, minz) end
	for i = 1, S - 1 do add_p(maxx, minz + i) end
	for i = S - 2, 0, -1 do add_p(minx + i, maxz) end
	for i = S - 2, 1, -1 do add_p(minx, minz + i) end

	-- Gate: 2-cell gap in the middle of one side (+ taller pillars beside it)
	local mid = math.floor(S / 2)
	local gate_side = pr:next(1, 4)
	local gate_cells = {}
	local pillar_cells = {}
	if gate_side == 1 then
		gate_cells = {{minx + mid - 1, minz}, {minx + mid, minz}}
		pillar_cells = {{minx + mid - 2, minz}, {minx + mid + 1, minz}}
	elseif gate_side == 2 then
		gate_cells = {{maxx, minz + mid - 1}, {maxx, minz + mid}}
		pillar_cells = {{maxx, minz + mid - 2}, {maxx, minz + mid + 1}}
	elseif gate_side == 3 then
		gate_cells = {{minx + mid - 1, maxz}, {minx + mid, maxz}}
		pillar_cells = {{minx + mid - 2, maxz}, {minx + mid + 1, maxz}}
	else
		gate_cells = {{minx, minz + mid - 1}, {minx, minz + mid}}
		pillar_cells = {{minx, minz + mid - 2}, {minx, minz + mid + 1}}
	end
	local gate_set = {}
	for _, c in ipairs(gate_cells) do
		gate_set[c[1] .. ":" .. c[2]] = true
	end

	-- Corner towers: 3x3 rings centred on the castle corners
	local corners = {{minx, minz}, {maxx, minz}, {minx, maxz}, {maxx, maxz}}
	local tower_cells = {}
	for _, corner in ipairs(corners) do
		for dx = -1, 1 do
			for dz = -1, 1 do
				if dx ~= 0 or dz ~= 0 then
					tower_cells[#tower_cells + 1] = {corner[1] + dx, corner[2] + dz}
				end
			end
		end
	end
	local towers = {}
	for _, corner in ipairs(corners) do
		local ring = {}
		for dx = -1, 1 do
			for dz = -1, 1 do
				if not (dx == 0 and dz == 0) then
					ring[#ring + 1] = {corner[1] + dx, corner[2] + dz}
				end
			end
		end
		towers[#towers + 1] = ring
	end

	-- Inner keep (5x5 ring) when the castle is big enough
	local has_keep = S >= 21
	local keep_cells = {}
	if has_keep then
		for dx = -2, 2 do
			for dz = -2, 2 do
				if math.abs(dx) == 2 or math.abs(dz) == 2 then
					keep_cells[#keep_cells + 1] = {ctx.x + dx, ctx.z + dz}
				end
			end
		end
	end

	-- Validate every cell that needs ground
	local needed = {}
	for _, c in ipairs(perimeter) do needed[#needed + 1] = c end
	for _, c in ipairs(tower_cells) do needed[#needed + 1] = c end
	for _, c in ipairs(keep_cells) do needed[#needed + 1] = c end
	needed[#needed + 1] = {ctx.x, ctx.z}
	local ok = validate_columns(ctx, needed)
	if ok ~= true then
		return ok -- false or "retry"
	end

	-- Plan the walls
	local heights = profile(pr, #perimeter, 3, 6, 8)
	for _, c in ipairs(pillar_cells) do
		local idx = index_of[c[1] .. ":" .. c[2]]
		if idx then
			heights[idx] = math.max(heights[idx] or 0, 5 + pr:next(0, 2))
		end
	end
	local wall_mat = pick(pr, ctx.theme.wall)
	for i, c in ipairs(perimeter) do
		local key = c[1] .. ":" .. c[2]
		if not gate_set[key] then
			local y = ctx_floor(ctx, c[1], c[2])
			if y then
				write_wall_column(ctx, c[1], c[2], y, heights[i], wall_mat, 25)
			end
		end
	end

	-- Towers
	for _, ring in ipairs(towers) do
		local ring_heights = profile(pr, #ring, 4, 7, 12)
		for j, c in ipairs(ring) do
			local y = ctx_floor(ctx, c[1], c[2])
			if y then
				local h = math.max(ring_heights[j] or 0, 3)
				write_wall_column(ctx, c[1], c[2], y, h, wall_mat, 30)
			end
		end
	end

	-- Keep
	if has_keep then
		local keep_mat = pick(pr, ctx.theme.wall)
		local keep_heights = profile(pr, #keep_cells, 2, 4, 15)
		for j, c in ipairs(keep_cells) do
			local y = ctx_floor(ctx, c[1], c[2])
			if y then
				write_wall_column(ctx, c[1], c[2], y, keep_heights[j], keep_mat, 20)
			end
		end
		-- flagstones inside the keep
		for dx = -1, 1 do
			for dz = -1, 1 do
				if pr:next(1, 100) <= 60 then
					local y = ctx_floor(ctx, ctx.x + dx, ctx.z + dz)
					if y then
						put(ctx, ctx.x + dx, y, ctx.z + dz, pick(pr, ctx.theme.floor))
					end
				end
			end
		end
	end

	-- Courtyard flagstones
	local floor_mat = pick(pr, ctx.theme.floor)
	for _ = 1, pr:next(12, 26) do
		local rx = minx + pr:next(2, S - 3)
		local rz = minz + pr:next(2, S - 3)
		local y = ctx_floor(ctx, rx, rz)
		if y and not (math.abs(rx - ctx.x) <= 2 and math.abs(rz - ctx.z) <= 2) then
			put(ctx, rx, y, rz, floor_mat)
		end
	end

	-- Interior rubble
	for _ = 1, pr:next(6, 12) do
		local rx = minx + pr:next(2, S - 3)
		local rz = minz + pr:next(2, S - 3)
		local y = ctx_floor(ctx, rx, rz)
		if y and not (math.abs(rx - ctx.x) <= 2 and math.abs(rz - ctx.z) <= 2) then
			put(ctx, rx, y + 1, rz, pick(pr, ctx.theme.rubble))
		end
	end

	-- Exterior rubble, thinning out with distance
	for d = 1, 4 do
		local p = 14 - d * 3
		for x = minx - d, maxx + d do
			for _, z in ipairs({minz - d, maxz + d}) do
				if pr:next(1, 100) <= p then
					local y = ctx_floor(ctx, x, z)
					if y then
						put(ctx, x, y + 1, z, pick(pr, ctx.theme.rubble))
					end
				end
			end
		end
		for z = minz - d + 1, maxz + d - 1 do
			for _, x in ipairs({minx - d, maxx + d}) do
				if pr:next(1, 100) <= p then
					local y = ctx_floor(ctx, x, z)
					if y then
						put(ctx, x, y + 1, z, pick(pr, ctx.theme.rubble))
					end
				end
			end
		end
	end

	-- Treasure in the keep / courtyard centre
	if ctx.chest_node then
		local y = ctx_floor(ctx, ctx.x, ctx.z)
		if y then
			put(ctx, ctx.x, y + 1, ctx.z, ctx.chest_node)
		end
	end

	return true
end

-- Ruined tower: hollow square tower with a crumbled top.
local function gen_tower(ctx)
	local pr = ctx.pr
	local S = 7 + 2 * pr:next(0, 1)
	local half = math.floor(S / 2)
	local minx, minz = ctx.x - half, ctx.z - half

	local ring = {}
	for dx = 0, S - 1 do
		for dz = 0, S - 1 do
			if dx == 0 or dz == 0 or dx == S - 1 or dz == S - 1 then
				ring[#ring + 1] = {minx + dx, minz + dz}
			end
		end
	end

	local needed = {}
	for _, c in ipairs(ring) do needed[#needed + 1] = c end
	needed[#needed + 1] = {ctx.x, ctx.z}
	local ok = validate_columns(ctx, needed)
	if ok ~= true then
		return ok
	end

	local heights = profile(pr, #ring, 4, 9, 12)
	local wall_mat = pick(pr, ctx.theme.wall)
	for i, c in ipairs(ring) do
		local y = ctx_floor(ctx, c[1], c[2])
		if y then
			write_wall_column(ctx, c[1], c[2], y, heights[i], wall_mat, 35)
		end
	end

	-- Rubble inside and around the base
	for _ = 1, pr:next(3, 6) do
		local rx = ctx.x + pr:next(-half + 1, half - 1)
		local rz = ctx.z + pr:next(-half + 1, half - 1)
		local y = ctx_floor(ctx, rx, rz)
		if y then
			put(ctx, rx, y + 1, rz, pick(pr, ctx.theme.rubble))
		end
	end
	for _ = 1, pr:next(4, 8) do
		local rx = ctx.x + pr:next(-half - 3, half + 3)
		local rz = ctx.z + pr:next(-half - 3, half + 3)
		if math.abs(rx - ctx.x) > half or math.abs(rz - ctx.z) > half then
			local y = ctx_floor(ctx, rx, rz)
			if y then
				put(ctx, rx, y + 1, rz, pick(pr, ctx.theme.rubble))
			end
		end
	end

	-- Chest at the base (35%)
	if ctx.chest_node and pr:next(1, 100) <= 35 then
		local y = ctx_floor(ctx, ctx.x, ctx.z)
		if y then
			put(ctx, ctx.x, y + 1, ctx.z, ctx.chest_node)
		end
	end

	return true
end

-- Collapsed wall: a long broken wall fragment, optionally with taller ends.
local function gen_walls(ctx)
	local pr = ctx.pr
	local L = 12 + pr:next(0, 8)
	local horizontal = pr:next(0, 1) == 0

	local cells = {}
	for i = 0, L - 1 do
		if horizontal then
			cells[#cells + 1] = {ctx.x + i, ctx.z}
		else
			cells[#cells + 1] = {ctx.x, ctx.z + i}
		end
	end
	local ok = validate_columns(ctx, cells)
	if ok ~= true then
		return ok
	end

	local heights = profile(pr, L, 1, 4, 22)
	heights[1] = math.max(heights[1] or 0, 3 + pr:next(0, 2))
	heights[L] = math.max(heights[L] or 0, 3 + pr:next(0, 2))
	local wall_mat = pick(pr, ctx.theme.wall)
	for i, c in ipairs(cells) do
		local y = ctx_floor(ctx, c[1], c[2])
		if y then
			write_wall_column(ctx, c[1], c[2], y, heights[i], wall_mat, 30)
		end
	end

	-- A little rubble around the fragment
	for i = 1, L do
		if pr:next(1, 100) <= 25 then
			local c = cells[i]
			local off_x = horizontal and 0 or pr:next(1, 2)
			local off_z = horizontal and pr:next(1, 2) or 0
			local y = ctx_floor(ctx, c[1] + off_x, c[2] + off_z)
			if y then
				put(ctx, c[1] + off_x, y + 1, c[2] + off_z, pick(pr, ctx.theme.rubble))
			end
		end
	end

	-- Chest at the middle (10%)
	if ctx.chest_node and pr:next(1, 100) <= 10 then
		local c = cells[math.floor(L / 2) + 1]
		local off_x = horizontal and 0 or 1
		local off_z = horizontal and 1 or 0
		local y = ctx_floor(ctx, c[1] + off_x, c[2] + off_z)
		if y then
			put(ctx, c[1] + off_x, y + 1, c[2] + off_z, ctx.chest_node)
		end
	end

	return true
end

-- Ancient stone circle: standing stones around an altar.
local function gen_stones(ctx)
	local pr = ctx.pr
	local r = 4 + pr:next(0, 3)
	local n = 8 + pr:next(0, 6)

	local cells, seen = {}, {}
	for i = 1, n do
		local a = (i - 1) * (math.pi * 2 / n)
		local x = ctx.x + math.floor(math.cos(a) * r + 0.5)
		local z = ctx.z + math.floor(math.sin(a) * r + 0.5)
		local key = x .. ":" .. z
		if not seen[key] then
			seen[key] = true
			cells[#cells + 1] = {x, z}
		end
	end
	table.insert(cells, {ctx.x, ctx.z})
	local ok = validate_columns(ctx, cells)
	if ok ~= true then
		return ok
	end

	local wall_mat = pick(pr, ctx.theme.wall)
	for i = 1, #cells - 1 do
		local c = cells[i]
		local y = ctx_floor(ctx, c[1], c[2])
		if y then
			local roll = pr:next(1, 100)
			local h = 1
			if roll <= 55 then
				h = 2
			elseif roll <= 75 then
				h = 3
			end
			for dy = 1, h do
				put(ctx, c[1], y + dy, c[2], wall_mat)
			end
		end
	end

	-- Altar stone in the middle (sometimes glowing)
	local cy = ctx_floor(ctx, ctx.x, ctx.z)
	local altar_placed = false
	if cy and pr:next(1, 100) <= 55 then
		local mat = wall_mat
		if #ctx.theme.glow > 0 and pr:next(1, 100) <= 15 then
			mat = ctx.theme.glow[pr:next(1, #ctx.theme.glow)]
		end
		put(ctx, ctx.x, cy + 1, ctx.z, mat)
		altar_placed = true
	end

	-- Rubble scatter
	for _ = 1, pr:next(3, 7) do
		local a = pr:next(1, 628) / 100
		local rr = pr:next(2, r + 2)
		local rx = ctx.x + math.floor(math.cos(a) * rr + 0.5)
		local rz = ctx.z + math.floor(math.sin(a) * rr + 0.5)
		local y = ctx_floor(ctx, rx, rz)
		if y then
			put(ctx, rx, y + 1, rz, pick(pr, ctx.theme.rubble))
		end
	end

	-- Chest (25%), beside the altar if one was placed
	if ctx.chest_node and pr:next(1, 100) <= 25 then
		local ox = altar_placed and 1 or 0
		local y = ctx_floor(ctx, ctx.x + ox, ctx.z)
		if y then
			put(ctx, ctx.x + ox, y + 1, ctx.z, ctx.chest_node)
		end
	end

	return true
end

-- "portal" is a ruined sky or dark portal on its own (portal/portal_ruins.lua);
-- it is only built when asked for (/spawn_ruin portal). Ruins of every
-- other kind get one beside them PORTAL_SHARE percent of the time
-- (attach_portal, below).
local TYPE_ORDER = {"portal", "castle", "tower", "walls", "stones"}
local TYPE_INDEX = {portal = 1, castle = 2, tower = 3, walls = 4, stones = 5}
local TYPE_NAME = {
	portal = "ruined portal",
	castle = "broken castle",
	tower = "ruined tower",
	walls = "broken wall",
	stones = "stone circle",
}
local GENERATORS = {castle = gen_castle, tower = gen_tower, walls = gen_walls, stones = gen_stones}

local function portals_enabled()
	return lualore.portal_ruins ~= nil and lualore.portal_ruins.build_at ~= nil
		and lualore.portal_ruins.enabled ~= false
end

local function pick_type(pr)
	local r = pr:next(1, 100)
	if r <= 40 then
		return 2
	elseif r <= 70 then
		return 3
	elseif r <= 88 then
		return 4
	end
	return 5
end

-- ------------------------------------------------------------------
-- A ruined portal beside the ruin
-- ------------------------------------------------------------------
-- Most ruins have a dead portal standing near them: the hint at what can
-- be built. It goes on a ring round the ruin, clear of everything the ruin
-- placed (a portal's footprint reaches about 7 nodes from its middle), at
-- the first of 8 spots round the ring where the ground will take it. Each
-- spot looks well below the ruin's base for ground, since the base can be
-- a tree canopy. If the land round the ruin is not all generated yet, it
-- tries again a little later.
local PORTAL_SHARE = 75     -- percent of ruins with a ruined portal
local PORTAL_REACH = 7      -- how far a portal ruin's footprint spreads
local PORTAL_TRIES = 10     -- later attempts while land is still missing

local function plan_box(plan)
	local b = {minx = math.huge, maxx = -math.huge, minz = math.huge, maxz = -math.huge}
	for _, n in ipairs(plan) do
		b.minx, b.maxx = math.min(b.minx, n.x), math.max(b.maxx, n.x)
		b.minz, b.maxz = math.min(b.minz, n.z), math.max(b.maxz, n.z)
	end
	return b
end

local function attach_portal(kind, box, base, seed, tries_left)
	local pr = PcgRandom(seed + 4243)
	local cx, cz = (box.minx + box.maxx) / 2, (box.minz + box.maxz) / 2
	local half = math.max(box.maxx - box.minx, box.maxz - box.minz) / 2
	-- a ring whose spots clear the ruin's box by a node or two at any angle:
	-- both boxes are squares, so both diagonals count
	local r = (half + PORTAL_REACH) * math.sqrt(2) + 1
	local start = pr:next(0, 359)
	local reasons, missing_land = {}, false
	for k = 0, 7 do
		local a = math.rad(start + k * 45)
		local x = math.floor(cx + math.cos(a) * r + 0.5)
		local z = math.floor(cz + math.sin(a) * r + 0.5)
		local plan, why = lualore.portal_ruins.build_at(x, z, seed + k * 131, nil,
			base + 10, base - 24)
		if plan then
			return plan
		end
		reasons[#reasons + 1] = tostring(why)
		if why == "retry" then
			missing_land = true
		end
	end
	if missing_land and (tries_left or PORTAL_TRIES) > 0 then
		minetest.after(3, attach_portal, kind, box, base, seed, (tries_left or PORTAL_TRIES) - 1)
		return nil
	end
	minetest.log("action", string.format(
		"[lualore] No room for a ruined portal beside the %s at %d,%d (%s)",
		TYPE_NAME[kind] or kind, cx, cz, table.concat(reasons, ", ")))
	return nil
end

local function maybe_attach_portal(kind, ctx, seed)
	if not portals_enabled() or #ctx.plan == 0 then
		return nil
	end
	if PcgRandom(seed + 9157):next(1, 100) > PORTAL_SHARE then
		return nil
	end
	return attach_portal(kind, plan_box(ctx.plan), ctx.base, seed)
end

-- ------------------------------------------------------------------
-- Execution (VoxelManip write)
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

local function execute_plan(ctx)
	local plan = ctx.plan
	if #plan == 0 then
		return false
	end

	local minx, maxx = plan[1].x, plan[1].x
	local miny, maxy = plan[1].y, plan[1].y
	local minz, maxz = plan[1].z, plan[1].z
	for _, n in ipairs(plan) do
		minx = math.min(minx, n.x)
		maxx = math.max(maxx, n.x)
		miny = math.min(miny, n.y)
		maxy = math.max(maxy, n.y)
		minz = math.min(minz, n.z)
		maxz = math.max(maxz, n.z)
	end

	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(
		{x = minx - 1, y = miny - 1, z = minz - 1},
		{x = maxx + 1, y = maxy + 1, z = maxz + 1})
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})

	for _, n in ipairs(plan) do
		if area:containsp(n) then
			local id = content_id(n.m)
			if id then
				data[area:indexp(n)] = id
			end
		end
	end

	vm:set_data(data)
	vm:write_to_map(true)
	vm:update_liquids()
	return true
end

-- ------------------------------------------------------------------
-- Village proximity guard
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
-- Build orchestrator
-- ------------------------------------------------------------------
local function build_ruin(cx, cz, theme, seed, force_type, scan_top, scan_bottom)
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
		-- A clipped window means the real surface lives in another chunk
		if scan_top or scan_bottom then
			return "retry"
		end
		return false
	end
	local above = get_name({x = cx, y = base + 1, z = cz})
	if is_unknown(above) then
		return "retry"
	end

	local ctx = {
		x = cx, z = cz, base = base, top = top, bottom = bottom,
		theme = theme, pr = nil, plan = {}, cache = {},
		min_floor = base, max_floor = base, invalid = false,
		chest_node = WANT_CHESTS and CHEST_NODE or nil,
	}

	local first = force_type and TYPE_INDEX[force_type] or nil
	local pr = PcgRandom(seed)
	ctx.pr = pr
	if not first then
		first = pick_type(pr)
	end

	for idx = first, #TYPE_ORDER do
		ctx.pr = PcgRandom(seed + idx * 77) -- each type gets its own stable roll
		ctx.plan = {}
		ctx.cache = {}
		ctx.min_floor = base
		ctx.max_floor = base
		ctx.invalid = false
		local kind = TYPE_ORDER[idx]
		if kind == "portal" then
			-- it finds its own footing, looking well below the ground found
			-- here (which can be a tree canopy)
			if portals_enabled() then
				local plan, why = lualore.portal_ruins.build_at(cx, cz, seed, nil,
					base + 10, base - 24)
				if plan then
					return true, kind, true, base
				end
				if why == "retry" then
					return "retry"
				end
			end
		else
			local result = GENERATORS[kind](ctx)
			if result == "retry" then
				return "retry"
			end
			if result then
				local built = execute_plan(ctx)
				local portal = built and maybe_attach_portal(kind, ctx, seed) or nil
				return true, kind, built, base, portal
			end
		end
	end

	return false
end

-- ------------------------------------------------------------------
-- Records (for /find_ruin and debugging)
-- ------------------------------------------------------------------
local function load_records()
	local data = storage:get_string("ruins")
	if data ~= "" then
		local records = minetest.deserialize(data)
		if type(records) == "table" then
			return records
		end
	end
	return {}
end

local function record_ruin(x, y, z, theme, kind)
	local records = load_records()
	records[minetest.pos_to_string({x = x, y = y, z = z})] = {
		x = x, y = y, z = z,
		theme = theme.name or "?",
		kind = kind,
	}
	storage:set_string("ruins", minetest.serialize(records))
end

-- ------------------------------------------------------------------
-- Placement driver
-- ------------------------------------------------------------------
local tried = {}
local pending = {}

local function attempt_cell(cell_x, cell_z, minp, maxp)
	local key = cell_x .. ":" .. cell_z
	if tried[key] then
		return
	end

	local cx, cz, seed = cell_candidate(cell_x, cell_z)
	if not cx then
		tried[key] = true
		return
	end

	local is_retry = pending[key] ~= nil
	if not is_retry and (cx < minp.x or cx > maxp.x or cz < minp.z or cz > maxp.z) then
		return
	end

	local theme = theme_for_pos(cx, cz)
	if not theme then
		tried[key] = true
		return
	end

	if not is_retry and too_close_to_village(cx, cz) then
		tried[key] = true
		minetest.log("info", "[lualore] Ruin cell " .. key .. " skipped (village nearby)")
		return
	end

	local result, kind, built, base_y = build_ruin(cx, cz, theme, seed, nil, maxp.y, minp.y)
	if result == "retry" then
		local left = (pending[key] or 40) - 1
		if left > 0 then
			pending[key] = left
			minetest.after(0.7, function()
				attempt_cell(cell_x, cell_z, minp, maxp)
			end)
		else
			pending[key] = nil
			-- Leave the cell undecided: if the missing chunks generate later,
			-- their own on_generated will pick the ruin up again.
			minetest.log("info", "[lualore] Ruin cell " .. key .. " postponed")
		end
		return
	end

	pending[key] = nil
	tried[key] = true
	if result and built then
		record_ruin(cx, base_y or maxp.y, cz, theme, kind)
		minetest.log("action", string.format(
			"[lualore] Ruin built (%s, %s) near %d,%d",
			TYPE_NAME[kind] or kind, theme.name or "?", cx, cz))
	end
end

if ENABLED then
	minetest.register_on_generated(function(minp, maxp, blockseed)
		if next(lualore.ruin_themes) == nil then
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
lualore.ruins = {
	-- Build a ruin at (x, z) right now. Returns
	-- true/false/"retry"[, kind[, built]].
	build_at = function(x, z, kind, seed)
		local theme = theme_for_pos(x, z)
		if not theme then
			return false
		end
		return build_ruin(x, z, theme, seed or (get_world_salt() + os.time() % 100000),
			kind)
	end,
	get_themes = get_themes,
}

-- ------------------------------------------------------------------
-- Chat commands (tuning / debugging)
-- ------------------------------------------------------------------
minetest.register_chatcommand("spawn_ruin", {
	params = "[portal|castle|tower|walls|stones]",
	description = S("Build a ruin at your position (tuning aid). Default: random type."),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local kind
		if param and param ~= "" then
			kind = param
			if not TYPE_INDEX[kind] then
				return false, "Unknown ruin type '" .. param ..
					"' (use: portal, castle, tower, walls, stones)"
			end
		end
		local theme = theme_for_pos(pos.x, pos.z)
		if not theme then
			return false, "No ruin theme for this biome."
		end
		local result, built_kind, built, base_y = lualore.ruins.build_at(
			math.floor(pos.x), math.floor(pos.z), kind)
		if result == "retry" then
			return false, "Area is not fully generated yet - try again in a second."
		end
		if not result or not built then
			return false, "No suitable spot found here."
		end
		record_ruin(math.floor(pos.x), base_y or math.floor(pos.y), math.floor(pos.z),
			theme, built_kind)
		return true, string.format("Built a %s (%s theme).",
			TYPE_NAME[built_kind] or built_kind, theme.name or "?")
	end,
})

minetest.register_chatcommand("find_ruin", {
	params = "[radius]",
	description = S("Find the nearest recorded ruin (default radius 512)."),
	privs = {},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local radius = tonumber(param) or 512
		local records = load_records()
		local best, best_dist
		for _, rec in pairs(records) do
			if type(rec) == "table" and rec.x then
				local dist = vector.distance(pos, {x = rec.x, y = rec.y or pos.y, z = rec.z})
				if dist <= radius and (best_dist == nil or dist < best_dist) then
					best, best_dist = rec, dist
				end
			end
		end
		if not best then
			return false, "No recorded ruin within " .. radius .. " nodes."
		end
		return true, string.format(
			"Nearest ruin: %s at %d,%d,%d (%.0f nodes away, %s theme)",
			TYPE_NAME[best.kind] or best.kind or "ruin",
			best.x, best.y, best.z, best_dist, best.theme or "?")
	end,
})

minetest.register_chatcommand("clear_ruin_records", {
	params = "",
	description = S("Forget ruin placement records (does not remove built ruins)."),
	privs = {server = true},
	func = function(name, param)
		local records = load_records()
		local count = 0
		for _ in pairs(records) do
			count = count + 1
		end
		storage:set_string("ruins", "")
		return true, "Cleared " .. count .. " ruin records."
	end,
})

-- done
