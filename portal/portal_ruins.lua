-- portal_ruins.lua
-- ===================================================================
-- RUINED PORTALS - the hint at what can be built
-- ===================================================================
-- Old portals stand here and there in the world, long dead: a mese frame
-- of the right shape, but cracked and broken, so a player who finds one
-- learns what a portal looks like and what it needs. There is one kind of
-- portal; very rarely a ruin still wears its crystal on the roof, the
-- hint that a crystal turns a portal dark.
--
-- Two styles:
--
--   * plain: just the frame, sunk in the ground on a stone foundation;
--   * grand: a larger frame on a worn platform between two broken pillars,
--     in weathered stone or obsidian.
--
-- The ring itself is only ever mese: mostly Cracked Mese, which looks like
-- mese but has lost its power (it drops only fragments, and no portal is
-- lit through it), with 1-3 blocks of real mese. To make one work, replace
-- the cracked blocks and fill the gaps with real mese; the shape is already
-- right. Some have a chest with iron ingots (what lights a portal).
--
-- A ruin is broken the way a stone ring breaks: the roof fallen in, one
-- side snapped off part way up with the roof hanging from the other, both,
-- or a chip out of the roof. Whatever is left must still reach the ground
-- through the ring, so nothing floats.
--
-- Three ruins in four (ruins/ruins.lua) have one standing beside them, so
-- they turn up wherever ruins do. /spawn_ruin portal builds one alone.
--
-- Settings: lualore_portal_ruins (bool): whether ruins get portals
-- ===================================================================

lualore = lualore or {}
lualore.portal_ruins = {}

local S = minetest.get_translator("lualore")
local storage = minetest.get_mod_storage()

lualore.portal_ruins.enabled = minetest.settings:get_bool("lualore_portal_ruins", true)
local Y_MIN, Y_MAX = -2, 200

local MESE = "default:mese"
local CRACKED = "lualore:cracked_mese"
local CHEST = "default:chest"
local CRYSTALS = {"everness:crystal_purple", "everness:crystal_orange", "everness:crystal_cyan"}

local GRAND_SHARE = 35      -- percent of ruins that are grand
local OBSIDIAN_SHARE = 40   -- percent built round in obsidian rather than stone
local CRYSTAL_ODDS = 20     -- one ruin in this many still wears its crystal
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
-- What is built round the ring (never the ring itself)
-- ------------------------------------------------------------------
local function first_registered(list)
	for _, name in ipairs(list) do
		if minetest.registered_nodes[name] then
			return name
		end
	end
	return list[#list]
end

local SETTINGS = {
	stone = {
		base = {"default:stonebrick", "default:cobble"},
		accent = {"default:mossycobble", "default:cobble"},
		floor = {"default:stonebrick", "default:cobble"},
	},
	obsidian = {
		base = {"default:obsidianbrick", "default:obsidian"},
		accent = {"default:obsidian", "default:obsidianbrick"},
		floor = {"default:obsidianbrick", "default:obsidian"},
	},
}

local function setting_node(setting, part)
	return first_registered(SETTINGS[setting][part])
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
-- Breaking the ring
-- ------------------------------------------------------------------
-- frame cell (i, j) of a frame whose interior bottom-left is `a` along `axis`
local function cell(a, axis, i, j, d)
	d = d or 0
	if axis == "x" then
		return {x = a.x + i, y = a.y + j, z = a.z + d}
	end
	return {x = a.x + d, y = a.y + j, z = a.z + i}
end

local function ck(i, j)
	return i .. ":" .. j
end

-- Every cell of the ring round a w x h interior, corners included.
local function ring_cells(w, h)
	local out = {}
	for i = -1, w do
		for j = -1, h do
			if i == -1 or i == w or j == -1 or j == h then
				out[#out + 1] = {i, j}
			end
		end
	end
	return out
end

local function is_corner(c, w, h)
	return (c[1] == -1 or c[1] == w) and (c[2] == -1 or c[2] == h)
end

-- Decide which ring cells survive. Returns a set keyed by ck(i, j).
-- `keep_roof_mid` (a crystal ruin) keeps the roof whole: only a post breaks.
local function break_ring(pr, w, h, keep_roof_mid)
	local keep = {}
	for _, c in ipairs(ring_cells(w, h)) do
		keep[ck(c[1], c[2])] = true
	end
	local function drop(i, j)
		keep[ck(i, j)] = nil
	end
	local function drop_post(i, from)
		for j = from, h - 1 do
			drop(i, j)
		end
	end
	local side = pr:next(0, 1) == 0 and -1 or w     -- the side that breaks
	local other = side == -1 and w or -1

	local pattern
	if keep_roof_mid then
		pattern = "post"
	else
		local r = pr:next(1, 100)
		pattern = r <= 30 and "roofless" or r <= 60 and "side" or r <= 85 and "both" or "chip"
	end

	if pattern == "roofless" then
		for i = -1, w do
			drop(i, h)
		end
		-- the posts weathered down a little from the top
		drop_post(-1, h - pr:next(0, 1))
		drop_post(w, h - pr:next(0, 1))
	elseif pattern == "side" or pattern == "both" then
		-- one post snapped off part way up, its top corner gone with it
		drop_post(side, pr:next(0, h - 2))
		drop(side, h)
		-- the roof still hangs from the other post, partly or (for "both")
		-- hardly at all
		local reach = pattern == "both" and pr:next(0, 1) or pr:next(1, w)
		local step = other == -1 and 1 or -1
		for n = 0, w + 1 do
			local i = other + step * n
			if n > reach then
				drop(i, h)
			end
		end
	elseif pattern == "chip" then
		-- a piece out of the roof; each half still rests on its post
		local i0 = pr:next(0, w - 1)
		drop(i0, h)
		if pr:next(1, 100) <= 50 and i0 + 1 <= w - 1 then
			drop(i0 + 1, h)
		end
		if pr:next(1, 100) <= 40 then
			drop(side, h - 1)
		end
	else -- "post": a crystal ruin; only the top of one post is gone
		drop_post(side, h - pr:next(1, math.max(1, h - 1)))
	end

	-- now and then a block of the ground row is gone too (not under a post)
	if pr:next(1, 100) <= 30 then
		drop(pr:next(0, w - 1), -1)
	end

	-- Nothing floats: whatever cannot reach the ground row through the
	-- ring (orthogonally) falls away.
	local reached, queue = {}, {}
	for i = -1, w do
		if keep[ck(i, -1)] then
			reached[ck(i, -1)] = true
			queue[#queue + 1] = {i, -1}
		end
	end
	while #queue > 0 do
		local c = table.remove(queue)
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local k = ck(c[1] + d[1], c[2] + d[2])
			if keep[k] and not reached[k] then
				reached[k] = true
				queue[#queue + 1] = {c[1] + d[1], c[2] + d[2]}
			end
		end
	end
	return reached, pattern
end

-- ------------------------------------------------------------------
-- Planning a ruin
-- ------------------------------------------------------------------
-- Decide every node. Returns a plan: {nodes = {{pos, name}...}, chest =
-- pos|nil, crystal = pos|nil, frame = {anchor, axis, w, h}, ring = {...}}.
local function plan_ruin(gx, gy, gz, opts, pr)
	local style, setting = opts.style, opts.setting
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
	-- the ground under a spot, as it will be once the site is cleared
	-- (cleared ground is never higher than gy)
	local function floor_y(p)
		local y = ground_at(p.x, p.z, gy + 3, gy - 4)
		return math.min(y or gy, gy)
	end

	local base, accent = setting_node(setting, "base"), setting_node(setting, "accent")
	local floor = setting_node(setting, "floor")
	local plan = {frame = {anchor = a, axis = axis, w = w, h = h}, style = style,
		setting = setting}

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
					for j = -4, -2 do
						put(cell(a, axis, i, j, d), floor)
					end
				end
			end
		end
		-- broken pillars either side, each standing on the platform
		for _, i in ipairs({-3, w + 2}) do
			local top = h + 2 - pr:next(0, 3)
			for j = 0, top do
				put(cell(a, axis, i, j, 0), (j == top and pr:next(1, 100) <= 50) and accent or base)
			end
		end
	else
		-- a foundation under the frame, so a dip in the ground never shows
		-- daylight under it
		for i = -1, w do
			for j = -3, -2 do
				put(cell(a, axis, i, j), floor)
			end
		end
	end

	-- the ring: mese only, broken so that nothing floats
	local mid = math.floor((w - 1) / 2)
	local crystal = opts.crystal and first_registered(CRYSTALS) or nil
	if crystal and not minetest.registered_nodes[crystal] then
		crystal = nil
	end
	local keep, pattern = break_ring(pr, w, h, crystal ~= nil)
	plan.pattern = pattern
	local kept = {}
	for _, c in ipairs(ring_cells(w, h)) do
		if keep[ck(c[1], c[2])] then
			kept[#kept + 1] = c
		else
			put(cell(a, axis, c[1], c[2]), "air")
		end
	end
	-- 1-3 of what is left is still whole mese, the rest is cracked
	for n = #kept, 2, -1 do
		local m = pr:next(1, n)
		kept[n], kept[m] = kept[m], kept[n]
	end
	local whole = math.min(#kept, pr:next(1, 3))
	plan.whole = whole
	for n, c in ipairs(kept) do
		put(cell(a, axis, c[1], c[2]), n <= whole and MESE or CRACKED)
	end
	if crystal and keep[ck(mid, h)] then
		put(cell(a, axis, mid, h + 1), crystal)
		plan.crystal = cell(a, axis, mid, h + 1)
	end

	-- what fell lies on the ground nearby, and stone is strewn about
	for _ = 1, pr:next(1, 3) do
		local p = cell(a, axis, pr:next(-2, w + 1), 0, pr:next(0, 1) == 0 and -2 or 2)
		p.y = floor_y(p) + 1
		put(p, CRACKED)
	end
	for _ = 1, pr:next(3, 6) do
		local p = cell(a, axis, pr:next(-pad - 1, w + pad), 0, pr:next(1, 2) * (pr:next(0, 1) == 0 and -1 or 1))
		p.y = floor_y(p)
		put(p, accent)
	end

	-- a chest at the foot of the frame, on the ground (or the platform)
	if opts.chest then
		local p = cell(a, axis, style == "grand" and -2 or -1, 0, pr:next(0, 1) == 0 and -1 or 1)
		if style ~= "grand" then
			p.y = floor_y(p) + 1
		end
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
	out.style = opts.style or (pr:next(1, 100) <= GRAND_SHARE and "grand" or "plain")
	out.setting = opts.setting or (pr:next(1, 100) <= OBSIDIAN_SHARE and "obsidian" or "stone")
	if opts.crystal ~= nil then
		out.crystal = opts.crystal
	else
		out.crystal = pr:next(1, CRYSTAL_ODDS) == 1
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
		style = plan.style, crystal = plan.crystal and true or nil}
	storage:set_string("portal_ruins", minetest.serialize(records))
end

-- Build a ruin on the ground at (x, z), surface searched between top and
-- bottom. opts may fix style ("plain"|"grand"), setting ("stone"|
-- "obsidian"), crystal and chest; the rest is rolled from seed. Returns
-- the plan, or nil plus why ("retry" when the ground is not generated yet).
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
	-- The ground only has to be level-ish where the ruin stands: the frame
	-- gets a foundation and the platform is propped up, and bumps are cut
	-- away, so a little roughness never shows.
	local r = o.style == "grand" and 4 or 2
	local ok = level_enough(x - r, z - r, x + r, z + r, gy, o.style == "grand" and 3 or 2)
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
	minetest.log("action", string.format("[lualore] Ruined portal (%s, %s, %s%s) at %d,%d,%d",
		plan.style, plan.setting, plan.pattern, plan.crystal and ", with its crystal" or "",
		x, gy, z))
	return plan
end

-- for tests: which ring cells are left, and what the pattern was
lualore.portal_ruins.ring_cells = ring_cells
lualore.portal_ruins.break_ring = break_ring

-- ------------------------------------------------------------------
-- Commands
-- ------------------------------------------------------------------
minetest.register_chatcommand("spawn_portal_ruin", {
	params = "[plain|grand] [stone|obsidian] [crystal]",
	description = S("Raise a ruined portal where you stand"),
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local opts = {}
		for word in param:gmatch("%S+") do
			if word == "plain" or word == "grand" then
				opts.style = word
			elseif word == "stone" or word == "obsidian" then
				opts.setting = word
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
		return true, string.format("Ruined portal (%s, %s, %s) built.",
			plan.style, plan.setting, plan.pattern)
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
		return true, string.format("Nearest ruined portal: %s at %d,%d,%d (%d nodes away)%s",
			best.style or "?", best.x, best.y, best.z, best_d,
			best.crystal and ", still wearing its crystal" or "")
	end,
})
