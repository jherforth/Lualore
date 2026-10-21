-- portal_ruins.lua
-- ===================================================================
-- RUINED PORTALS - the hint at what can be built
-- ===================================================================
-- Old portals stand here and there in the world, long dead: a mese frame
-- of the right shape, but cracked and broken, so a player who finds one
-- learns what a portal looks like and what it needs. Two kinds:
--
--   * sky ruins, in weathered stone, like the blue portals to the sky;
--   * dark ruins, in obsidian, like the black portals to the wizard
--     castles. Very rarely one still wears its crystal on the roof.
--
-- and two styles:
--
--   * plain: just the frame, sunk in the ground, a few blocks gone;
--   * grand: the frame on a stone platform between two broken pillars,
--     with more of it missing.
--
-- A ruin never works. Most of its frame is Cracked Mese, which looks like
-- mese but has lost its power: it drops only fragments, and no portal is
-- lit through it. To make one work, replace the cracked blocks and fill
-- the gaps with real mese; the shape is already right. Each ruin keeps
-- 1-3 real mese blocks, and some have a chest with iron ingots (what
-- lights a portal) and a little more.
--
-- Placement is the grid used by the ruins and villages: one candidate per
-- SPACING x SPACING cell, kept with probability CHANCE, on fairly level
-- dry ground away from villages. Defaults make about one ruin per
-- 1000 x 1000 nodes.
--
-- Settings: lualore_portal_ruins (bool), lualore_portal_ruin_spacing (int),
--           lualore_portal_ruin_chance (float)
-- ===================================================================

lualore = lualore or {}
lualore.portal_ruins = {}

local S = minetest.get_translator("lualore")
local storage = minetest.get_mod_storage()

local function setting_number(key, default)
	local v = tonumber(minetest.settings:get(key))
	return v == nil and default or v
end

local ENABLED = minetest.settings:get_bool("lualore_portal_ruins", true)
local SPACING = math.max(200, math.floor(setting_number("lualore_portal_ruin_spacing", 700)))
local CHANCE = math.max(0, math.min(1, setting_number("lualore_portal_ruin_chance", 0.5)))
local Y_MIN, Y_MAX = -2, 200

local MESE = "default:mese"
local CRACKED = "lualore:cracked_mese"
local CHEST = "default:chest"
local CRYSTALS = {"everness:crystal_purple", "everness:crystal_orange", "everness:crystal_cyan"}

local DARK_SHARE = 40       -- percent of ruins that are dark
local GRAND_SHARE = 35      -- percent that are grand
local CRYSTAL_ODDS = 8      -- one dark ruin in this many keeps its crystal
local CHEST_PLAIN, CHEST_GRAND = 40, 60 -- percent with a chest

-- ------------------------------------------------------------------
-- Cracked Mese
-- ------------------------------------------------------------------
minetest.register_node(CRACKED, {
	description = S("Cracked Mese") .. "\n" ..
		S("Its power is spent. A portal frame needs whole mese."),
	tiles = {"default_mese_block.png^[colorize:#2a2416:130^lualore_cracks.png"},
	groups = {cracky = 1, level = 2},
	light_source = 2,
	drop = {
		max_items = 1,
		items = {
			{items = {"default:mese_crystal_fragment 3"}, rarity = 3},
			{items = {"default:mese_crystal_fragment 2"}, rarity = 2},
			{items = {"default:mese_crystal_fragment"}},
		},
	},
	sounds = minetest.global_exists("default") and default.node_sound_stone_defaults() or nil,
})

-- ------------------------------------------------------------------
-- Themes
-- ------------------------------------------------------------------
local function first_registered(list)
	for _, name in ipairs(list) do
		if minetest.registered_nodes[name] then
			return name
		end
	end
	return list[#list]
end

local THEMES = {
	sky = {
		base = {"default:stonebrick", "default:cobble"},
		accent = {"default:mossycobble", "default:cobble"},
		floor = {"default:stonebrick", "default:cobble"},
		corner = {"default:stonebrick", "default:cobble"},
	},
	dark = {
		base = {"default:obsidianbrick", "default:obsidian"},
		accent = {"default:obsidian", "default:obsidianbrick"},
		floor = {"default:obsidianbrick", "default:obsidian"},
		corner = {"default:obsidian", "default:obsidianbrick"},
	},
}

local function theme_node(kind, part)
	return first_registered(THEMES[kind][part])
end

-- ------------------------------------------------------------------
-- Ground
-- ------------------------------------------------------------------
local function def_of(name)
	return minetest.registered_nodes[name]
end

local function is_open(name)
	if name == "air" then
		return true
	end
	local def = def_of(name)
	return def ~= nil and not def.walkable and (def.liquidtype or "none") == "none"
end

local function is_plantish(name)
	local def = def_of(name)
	local g = def and def.groups or {}
	return (g.tree or 0) > 0 or (g.leaves or 0) > 0
end

-- The ground in a column: the first solid node down from `top`, if open
-- space lies over it. Returns y, or nil plus why: "covered" (solid at the
-- very top, so the ground is higher), "water", "none" (no ground in the
-- window) or "retry" (not generated).
local function ground_at(x, z, top, bottom)
	for y = top, bottom, -1 do
		local name = minetest.get_node({x = x, y = y, z = z}).name
		if name == "ignore" then
			return nil, "retry"
		end
		if not is_open(name) and not is_plantish(name) then
			local def = def_of(name)
			if def and (def.liquidtype or "none") ~= "none" then
				return nil, "water"
			end
			if y == top then
				return nil, "covered"
			end
			return y
		end
	end
	return nil, "none"
end

-- Every column of a w x d footprint within `slack` of gy, and dry.
local function level_enough(x0, z0, x1, z1, gy, slack)
	for x = x0, x1 do
		for z = z0, z1 do
			local y, why = ground_at(x, z, gy + slack + 1, gy - slack - 1)
			if why == "retry" then
				return "retry"
			end
			if not y or math.abs(y - gy) > slack then
				return false
			end
		end
	end
	return true
end

-- ------------------------------------------------------------------
-- Planning a ruin
-- ------------------------------------------------------------------
-- frame cell (i, j) of a frame whose interior bottom-left is `a` along `axis`
local function cell(a, axis, i, j, d)
	d = d or 0
	if axis == "x" then
		return {x = a.x + i, y = a.y + j, z = a.z + d}
	end
	return {x = a.x + d, y = a.y + j, z = a.z + i}
end

-- The frame cells of a w x h interior, split into sides and corners.
local function frame_cells(w, h)
	local sides, corners = {}, {}
	for i = -1, w do
		for j = -1, h do
			local edge_i, edge_j = i == -1 or i == w, j == -1 or j == h
			if edge_i and edge_j then
				corners[#corners + 1] = {i, j}
			elseif edge_i or edge_j then
				sides[#sides + 1] = {i, j}
			end
		end
	end
	return sides, corners
end

local function shuffle(pr, list)
	for i = #list, 2, -1 do
		local j = pr:next(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- Decide every node. Returns a plan: {nodes = {{pos, name}...}, chest =
-- pos|nil, crystal = pos|nil, frame = {anchor, axis, w, h}}.
local function plan_ruin(gx, gy, gz, opts, pr)
	local kind, style = opts.kind, opts.style
	local axis = pr:next(0, 1) == 0 and "x" or "z"
	local w, h = 2, 3
	if style == "grand" then
		w, h = 3, 4
	end
	-- the frame's bottom row is sunk into the ground, the interior over it
	local a = {x = gx - math.floor((w - 1) / 2), y = gy + 1, z = gz}
	if axis == "z" then
		a = {x = gx, y = gy + 1, z = gz - math.floor((w - 1) / 2)}
	end
	local nodes, set = {}, {}
	local function put(p, name)
		local k = p.x .. "," .. p.y .. "," .. p.z
		if set[k] then
			nodes[set[k]][2] = name
		else
			nodes[#nodes + 1] = {p, name}
			set[k] = #nodes
		end
	end

	local base, accent = theme_node(kind, "base"), theme_node(kind, "accent")
	local floor, corner = theme_node(kind, "floor"), theme_node(kind, "corner")
	local plan = {frame = {anchor = a, axis = axis, w = w, h = h}, kind = kind, style = style}

	-- clear the space the ruin stands in (grass, a sapling, a bump)
	local pad = style == "grand" and 3 or 1
	for i = -pad - 1, w + pad do
		for d = -2, 2 do
			for j = 0, h + 3 do
				put(cell(a, axis, i, j, d), "air")
			end
		end
	end

	if style == "grand" then
		-- a platform, its edges worn away here and there, propped up below
		for i = -4, w + 3 do
			for d = -2, 2 do
				local edge = i == -4 or i == w + 3 or d == -2 or d == 2
				if not (edge and pr:next(1, 100) <= 30) then
					put(cell(a, axis, i, -1, d), pr:next(1, 100) <= 20 and accent or floor)
					for j = -3, -2 do
						put(cell(a, axis, i, j, d), floor)
					end
				end
			end
		end
		-- broken pillars either side
		for _, i in ipairs({-3, w + 2}) do
			local top = h + 2 - pr:next(0, 3)
			for j = 0, top do
				put(cell(a, axis, i, j, 0), (j == top and pr:next(1, 100) <= 50) and accent or base)
			end
		end
	end

	-- the frame: sides cracked, some gone, a few still whole; corners in
	-- the theme's stone (a frame does not need them)
	local sides, corners = frame_cells(w, h)
	for _, c in ipairs(corners) do
		if pr:next(1, 100) <= 70 then
			put(cell(a, axis, c[1], c[2]), corner)
		end
	end
	-- a dark ruin, very rarely, still wears its crystal; the roof block it
	-- sits on is kept (cracked), so it is never one of the gaps
	local mid = math.floor((w - 1) / 2)
	local crystal = kind == "dark" and opts.crystal and first_registered(CRYSTALS)
	if crystal and minetest.registered_nodes[crystal] then
		for n, c in ipairs(sides) do
			if c[1] == mid and c[2] == h then
				table.remove(sides, n)
				break
			end
		end
		put(cell(a, axis, mid, h), CRACKED)
		put(cell(a, axis, mid, h + 1), crystal)
		plan.crystal = cell(a, axis, mid, h + 1)
	end
	shuffle(pr, sides)
	local missing = style == "grand" and pr:next(3, 5) or pr:next(2, 4)
	local whole = pr:next(1, 3)
	plan.missing, plan.whole = {}, {}
	for n, c in ipairs(sides) do
		local p = cell(a, axis, c[1], c[2])
		if n <= missing then
			put(p, c[2] == -1 and floor or "air") -- a gap in the ground row shows as stone
			plan.missing[#plan.missing + 1] = p
		elseif n <= missing + whole then
			put(p, MESE)
			plan.whole[#plan.whole + 1] = p
		else
			put(p, CRACKED)
		end
	end

	-- pieces that fell, and stone strewn about
	for _ = 1, pr:next(1, 2) do
		local i = pr:next(-2, w + 1)
		local d = pr:next(0, 1) == 0 and -2 or 2
		put(cell(a, axis, i, 0, d), CRACKED)
	end
	for _ = 1, pr:next(3, 6) do
		local i, d = pr:next(-pad - 1, w + pad), pr:next(-2, 2)
		if math.abs(d) >= 1 then
			put(cell(a, axis, i, -1, d), accent)
		end
	end

	-- a chest at the foot of the frame
	if opts.chest then
		local d = pr:next(0, 1) == 0 and -1 or 1
		local p = cell(a, axis, style == "grand" and -2 or -1, 0, d)
		put(p, CHEST)
		plan.chest = p
	end

	plan.nodes = nodes
	return plan
end

-- ------------------------------------------------------------------
-- The chest
-- ------------------------------------------------------------------
local function stock_chest(pos, pr)
	local def = minetest.registered_nodes[CHEST]
	if def and def.on_construct then
		def.on_construct(pos)
	end
	local meta = minetest.get_meta(pos)
	meta:set_string("lualore_loot_filled", "true") -- not the biome loot
	local inv = meta:get_inventory()
	if inv:get_size("main") == 0 then
		inv:set_size("main", 32)
	end
	local items = {
		"default:steel_ingot " .. pr:next(3, 8),
		"default:mese_crystal_fragment " .. pr:next(2, 5),
	}
	if pr:next(1, 100) <= 30 then
		items[#items + 1] = "default:obsidian_shard " .. pr:next(1, 2)
	end
	if pr:next(1, 100) <= 30 then
		items[#items + 1] = "default:torch " .. pr:next(2, 6)
	end
	for _, item in ipairs(items) do
		if minetest.registered_items[ItemStack(item):get_name()] then
			inv:add_item("main", item)
		end
	end
	return items
end

-- ------------------------------------------------------------------
-- Building
-- ------------------------------------------------------------------
local function roll_opts(pr, opts)
	opts = opts or {}
	local out = {}
	out.kind = opts.kind or (pr:next(1, 100) <= DARK_SHARE and "dark" or "sky")
	out.style = opts.style or (pr:next(1, 100) <= GRAND_SHARE and "grand" or "plain")
	if opts.crystal ~= nil then
		out.crystal = opts.crystal
	else
		out.crystal = out.kind == "dark" and pr:next(1, CRYSTAL_ODDS) == 1
	end
	if opts.chest ~= nil then
		out.chest = opts.chest
	else
		out.chest = pr:next(1, 100) <= (out.style == "grand" and CHEST_GRAND or CHEST_PLAIN)
	end
	return out
end

local function load_records()
	local data = storage:get_string("portal_ruins")
	local t = data ~= "" and minetest.deserialize(data) or nil
	return type(t) == "table" and t or {}
end

local function record(plan, gx, gy, gz)
	local records = load_records()
	records[gx .. "," .. gy .. "," .. gz] = {x = gx, y = gy, z = gz,
		kind = plan.kind, style = plan.style, crystal = plan.crystal and true or nil}
	storage:set_string("portal_ruins", minetest.serialize(records))
end

-- Build a ruin on the ground at (x, z), surface searched between top and
-- bottom. opts may fix kind ("sky"|"dark"), style ("plain"|"grand"),
-- crystal and chest; the rest is rolled from seed. Returns the plan, or
-- nil plus why ("retry" when the ground is not generated yet).
function lualore.portal_ruins.build_at(x, z, seed, opts, top, bottom)
	local pr = PcgRandom(seed or (x * 73856093 + z * 19349663))
	local o = roll_opts(pr, opts)
	local gy, why = ground_at(x, z, top or Y_MAX, bottom or Y_MIN)
	if not gy then
		return nil, why
	end
	if gy < Y_MIN or gy > Y_MAX then
		return nil, "height"
	end
	local r = o.style == "grand" and 5 or 3
	local ok = level_enough(x - r, z - r, x + r, z + r, gy, o.style == "grand" and 2 or 1)
	if ok ~= true then
		return nil, ok == "retry" and "retry" or "uneven"
	end
	if lualore.villages and lualore.villages.find_near
			and lualore.villages.find_near({x = x, y = gy, z = z}, 80) then
		return nil, "village"
	end
	local plan = plan_ruin(x, gy, z, o, pr)
	for _, n in ipairs(plan.nodes) do
		minetest.set_node(n[1], {name = n[2]})
	end
	if plan.chest then
		plan.loot = stock_chest(plan.chest, pr)
	end
	record(plan, x, gy, z)
	minetest.log("action", string.format("[lualore] Ruined %s portal (%s%s) at %d,%d,%d",
		plan.kind, plan.style, plan.crystal and ", with its crystal" or "", x, gy, z))
	return plan
end

-- ------------------------------------------------------------------
-- Placement in new chunks
-- ------------------------------------------------------------------
local function world_salt()
	local seed = tostring(minetest.get_mapgen_setting("seed") or "")
	local h = 5381
	for i = 1, #seed do
		h = (h * 33 + seed:byte(i)) % 2147483647
	end
	return h
end
local SALT

local function cell_candidate(cx, cz)
	SALT = SALT or world_salt()
	local pr = PcgRandom((cx * 73856093 + cz * 19349663 + SALT * 83492791 + 9137) % 2147483647)
	if pr:next(0, 999) >= CHANCE * 1000 then
		return nil
	end
	local quarter = math.floor(SPACING / 4)
	local x = cx * SPACING + quarter + pr:next(0, SPACING - 2 * quarter)
	local z = cz * SPACING + quarter + pr:next(0, SPACING - 2 * quarter)
	return x, z, pr:next(1, 2147483646)
end

local tried, pending = {}, {}

local function attempt(cx, cz, minp, maxp)
	local key = cx .. ":" .. cz
	if tried[key] then
		return
	end
	local x, z, seed = cell_candidate(cx, cz)
	if not x then
		tried[key] = true
		return
	end
	local plan, why = lualore.portal_ruins.build_at(x, z, seed, nil,
		math.min(maxp.y, Y_MAX), math.max(minp.y, Y_MIN))
	if plan then
		tried[key], pending[key] = true, nil
	elseif why == "retry" then
		-- part of the footprint is in a chunk not generated yet
		local left = (pending[key] or 20) - 1
		pending[key] = left > 0 and left or nil
		if left > 0 then
			minetest.after(1, attempt, cx, cz, minp, maxp)
		end
	elseif why == "covered" or why == "none" then
		-- the ground is in another chunk of this column: it will try then
	else
		tried[key] = true -- water, too steep, a village: no ruin here
	end
end

if ENABLED then
	minetest.register_on_generated(function(minp, maxp)
		if maxp.y < Y_MIN or minp.y > Y_MAX then
			return
		end
		for cx = math.floor(minp.x / SPACING), math.floor(maxp.x / SPACING) do
			for cz = math.floor(minp.z / SPACING), math.floor(maxp.z / SPACING) do
				local x, z = cell_candidate(cx, cz)
				if x and x >= minp.x and x <= maxp.x and z >= minp.z and z <= maxp.z then
					minetest.after(0.5, attempt, cx, cz, minp, maxp)
				end
			end
		end
	end)
end

-- ------------------------------------------------------------------
-- Commands
-- ------------------------------------------------------------------
minetest.register_chatcommand("spawn_portal_ruin", {
	params = "[sky|dark] [plain|grand] [crystal]",
	description = S("Raise a ruined portal where you stand"),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local opts = {}
		for word in param:gmatch("%S+") do
			if word == "sky" or word == "dark" then
				opts.kind = word
			elseif word == "plain" or word == "grand" then
				opts.style = word
			elseif word == "crystal" then
				opts.crystal = true
			end
		end
		local p = vector.round(player:get_pos())
		local plan, why = lualore.portal_ruins.build_at(p.x + 4, p.z, os.time(), opts,
			p.y + 8, p.y - 8)
		if not plan then
			return false, "No ruin here: " .. tostring(why)
		end
		return true, string.format("Ruined %s portal (%s) built.", plan.kind, plan.style)
	end,
})

minetest.register_chatcommand("find_portal_ruin", {
	description = S("Show the nearest recorded ruined portal"),
	privs = {server = true},
	func = function(name)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local best, best_d
		for _, r in pairs(load_records()) do
			local d = vector.distance(pos, r)
			if not best_d or d < best_d then
				best, best_d = r, d
			end
		end
		if not best then
			return true, "No ruined portals recorded yet."
		end
		return true, string.format("Nearest ruined portal: %s %s at %d,%d,%d (%d nodes away)",
			best.kind, best.style, best.x, best.y, best.z, best_d)
	end,
})
