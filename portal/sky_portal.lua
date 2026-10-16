--[[
	Sky portals.

	A rectangular frame of mese blocks, standing upright, with an empty
	interior at least 2 wide and 3 tall - the classic nether portal shape.
	There is no upper size limit: the scan that recognises a frame is bounded
	by the frame's own blocks, so it costs what the frame costs and stops the
	moment a wall, floor or roof block is missing. Corners are not required.

	Throw (drop) an iron ingot into the frame and it lights: the ingot is
	consumed and the interior fills with a swirling blue sheet. Stand in the
	sheet for a moment and you are carried to the sky islands - or, from a
	portal built up there, back down to the ground.

	Luanti has no dimensions, so "the sky islands" are the floatlands of this
	same world, which Asuna generates between y = 287 and y = 28000. A portal
	built on the ground leads up to a SKY VILLAGE - a hamlet of sky houses
	with its Sky Folk and always one skycastle:

	  * If a sky village already stands within reach (600 nodes by default,
	    never less than one sky-site grid cell), the portal goes there.
	  * If none does, it founds one: it raises a crystal island overhead and
	    has the sky-site builder (valkyrie/floating_buildings.lua) put a
	    village on it. The village is recorded under its grid cell like any
	    other, so the grid never builds a second one beside it.
	  * The far portal is built in the village, as near the middle as there
	    is open ground, and the two portals are linked. Later trips go
	    straight to the linked portal.
	  * Every ground portal gets its own portal in the village, so two bases
	    never share a way home.
	  * A portal built in the sky leads down to open ground below; if a
	    ground portal already stands close by it is reused (without taking
	    over that portal's own way back).
	  * If the far portal has been broken, the next trip searches afresh.
	  * With sky buildings switched off, or if no village can be founded, a
	    portal falls back to the nearest island overhead with room, and
	    failing that a small obsidian platform, so a trip never fails.

	Breaking any frame block puts the sheet out. Relight it with another
	ingot; a portal relit in the same place keeps its link.

	See portal/SKY_PORTAL.md.
]]

local S = minetest.get_translator("lualore")
local storage = minetest.get_mod_storage()

lualore = lualore or {}

local function setting_number(name, default)
	return tonumber(minetest.settings:get(name)) or default
end

local ENABLED = minetest.settings:get_bool("lualore_sky_portals", true)

local FRAME = "default:mese"
local IGNITER = "default:steel_ingot"
local PORTAL = "lualore:sky_portal"
-- A portal crowned with a crystal - any of Everness's three, set on the
-- frame's roof - burns black and leads to a wizard castle instead.
local DARK = "lualore:dark_portal"
local CRYSTALS = {
	["everness:crystal_purple"] = true,
	["everness:crystal_orange"] = true,
	["everness:crystal_cyan"] = true,
}
-- Go to a recorded wizard castle this close rather than raising a new one.
local CASTLE_REACH = math.floor(tonumber(
	minetest.settings:get("lualore_portal_castle_reach")) or 1500)

local MIN_W, MIN_H = 2, 3

-- Only a sanity bound for the frame scan; see the header.
local MAX_SPAN = math.max(3, math.floor(
	setting_number("lualore_portal_max_size", 256)))

-- Anything at or above this height counts as the sky. Asuna's floatlands
-- begin at y = 287, so this sits just above their base.
local SKY_Y = math.floor(setting_number("lualore_portal_sky_y", 290))

-- Seconds a player has to stand in the sheet before it carries them.
local TRAVEL_DELAY = setting_number("lualore_portal_delay", 2.0)

-- Go to an existing portal village this close rather than founding a new
-- one.
local VILLAGE_REACH = math.floor(setting_number("lualore_portal_village_reach", 800))

-- A portal village is a town, not a hamlet: the sky-site grid builds 2-6
-- houses, a portal village this many. Its cluster radius follows the
-- grid's own rule (30, plus 2 per house beyond three) and its island is a
-- little wider than that.
local VILLAGE_HOUSES = math.max(6, math.min(30, math.floor(
	setting_number("lualore_portal_village_houses", 18))))
local VILLAGE_RADIUS = math.min(70, 30 + (VILLAGE_HOUSES - 3) * 2)

local TICK = 0.25          -- watcher interval (ingots and travellers)
local IGNITE_RADIUS = 12   -- how far from a player a dropped ingot is noticed
local REUSE_RADIUS = 24    -- going down, reuse a ground portal within this
local SEARCH_RADIUS = 24   -- half-width of the box searched for a landing
local VILLAGE_SEARCH = 32  -- ...and around a village, which is wider
local SKY_SEARCH = 320     -- how far above SKY_Y to look for a bare island
local SKY_AIM = SKY_Y + 60 -- the height a bare-island search prefers
local SITE_BAND = 48       -- vertical half-height searched around a village
local GROUND_FLOOR = -48   -- bottom of the box searched for ground
local PLATFORM = "default:obsidian"

-- Every portal town has exactly one skycastle. Its valkyrie chest is the
-- only way to free the Sky Folk - opening it starts the valkyrie fight - so
-- a town without one would be a town nobody could ever free.
--
-- A founded village's island: wide enough for the castle in the middle,
-- the ring of houses round it and a rim to walk on, and deep enough to look
-- like it has weight.
local ISLAND_R = VILLAGE_RADIUS + 12
local ISLAND_DEPTH = 26    -- deepest point of its underside
-- A town built without a castle, with no room left on its island, gets a
-- rock of this size joined to its rim to put the castle on.
local CASTLE_ROCK_R = 22
local CASTLE_ROCK_DEPTH = 16
local ISLAND_HEADROOM = 28 -- open air wanted above it for the houses
-- Heights tried for a founded village, above the sky-site band's floor, in
-- order, until one has open sky; the floatlands overhead may be in the way.
local VILLAGE_HEIGHTS = {60, 140, 220, 300, 380}

-- ------------------------------------------------------------------
-- The portal node
-- ------------------------------------------------------------------
-- Always registered, even when portals are switched off, so that portals
-- already standing in a world never turn into unknown nodes.
local SHEET = {
	name = "lualore_sky_portal.png",
	backface_culling = false,
	animation = {
		type = "vertical_frames",
		aspect_w = 16,
		aspect_h = 16,
		length = 2.4,
	},
}

local SHEET_DEF = {
	description = S("Sky Portal"),
	drawtype = "nodebox",
	tiles = {SHEET, SHEET, SHEET, SHEET, SHEET, SHEET},
	use_texture_alpha = "blend",
	paramtype = "light",
	-- facedir 0: the sheet spans x and y (a frame running along x);
	-- facedir 1: rotated a quarter turn, spanning z and y.
	paramtype2 = "facedir",
	node_box = {
		type = "fixed",
		fixed = {-0.5, -0.5, -0.1, 0.5, 0.5, 0.1},
	},
	sunlight_propagates = true,
	light_source = 11,
	walkable = false,
	pointable = false,
	diggable = false,
	buildable_to = false,
	floodable = false,
	is_ground_content = false,
	drop = "",
	post_effect_color = {a = 150, r = 30, g = 80, b = 220},
	groups = {not_in_creative_inventory = 1},
	on_blast = function() end,
}
minetest.register_node(PORTAL, SHEET_DEF)

local DARK_SHEET = table.copy(SHEET)
DARK_SHEET.name = "lualore_dark_portal.png"
local DARK_DEF = table.copy(SHEET_DEF)
DARK_DEF.description = S("Dark Portal")
DARK_DEF.tiles = {DARK_SHEET, DARK_SHEET, DARK_SHEET, DARK_SHEET, DARK_SHEET, DARK_SHEET}
DARK_DEF.light_source = 4
DARK_DEF.post_effect_color = {a = 210, r = 12, g = 0, b = 28}
minetest.register_node(DARK, DARK_DEF)

local function is_sheet(name)
	return name == PORTAL or name == DARK
end

lualore.sky_portal = {}

-- ------------------------------------------------------------------
-- Geometry
-- ------------------------------------------------------------------
-- A frame is {anchor, axis, w, h}: anchor is the bottom cell of the
-- interior at the low end of the axis, axis is "x" or "z" (the direction
-- the frame's floor runs), and w/h are the interior's width and height.

local function step_of(axis)
	if axis == "x" then
		return 1, 0
	end
	return 0, 1
end

local function cell(anchor, axis, i, j)
	local dx, dz = step_of(axis)
	return {x = anchor.x + dx * i, y = anchor.y + j, z = anchor.z + dz * i}
end

local function node_name(pos)
	return minetest.get_node(pos).name
end

local function is_open(name)
	return name == "air" or is_sheet(name)
end

local function param2_of(axis)
	return axis == "x" and 0 or 1
end

local function axis_of(param2)
	return (param2 % 4 == 1 or param2 % 4 == 3) and "z" or "x"
end

-- Recognise a frame around `seed` with its floor running along `axis`.
-- Every loop below is bounded by the frame's own blocks: the row walk ends
-- at a wall (or fails where the floor stops), the climb ends at the roof (or
-- fails where a wall stops). MAX_SPAN only guards against a pathological
-- wall of mese with no end in sight.
local function scan_frame(seed, axis, name_at)
	name_at = name_at or node_name
	if not is_open(name_at(seed)) then
		return nil
	end
	local dx, dz = step_of(axis)

	-- down to the floor
	local fy = seed.y - 1
	while is_open(name_at({x = seed.x, y = fy, z = seed.z})) do
		if seed.y - fy > MAX_SPAN then
			return nil
		end
		fy = fy - 1
	end
	if name_at({x = seed.x, y = fy, z = seed.z}) ~= FRAME then
		return nil
	end
	local y0 = fy + 1

	-- along the bottom row to each wall
	local function walk(sign)
		local n = 0
		while true do
			local p = {x = seed.x + dx * sign * (n + 1), y = y0,
				z = seed.z + dz * sign * (n + 1)}
			local name = name_at(p)
			if name == FRAME then
				return n
			end
			if not is_open(name)
					or name_at({x = p.x, y = y0 - 1, z = p.z}) ~= FRAME then
				return nil
			end
			n = n + 1
			if n > MAX_SPAN then
				return nil
			end
		end
	end
	local left = walk(-1)
	local right = left and walk(1)
	if not right then
		return nil
	end
	local w = left + right + 1
	if w < MIN_W then
		return nil
	end
	local anchor = {x = seed.x - dx * left, y = y0, z = seed.z - dz * left}

	for i = 0, w - 1 do
		if name_at(cell(anchor, axis, i, -1)) ~= FRAME then
			return nil
		end
	end

	-- up to the roof, checking both walls on the way
	local h = 0
	while true do
		local mese, open = 0, 0
		for i = 0, w - 1 do
			local name = name_at(cell(anchor, axis, i, h))
			if name == FRAME then
				mese = mese + 1
			elseif is_open(name) then
				open = open + 1
			else
				return nil
			end
		end
		if mese == w then
			break -- a complete roof
		end
		if mese > 0 then
			return nil -- a roof with holes in it
		end
		if name_at(cell(anchor, axis, -1, h)) ~= FRAME
				or name_at(cell(anchor, axis, w, h)) ~= FRAME then
			return nil
		end
		h = h + 1
		if h > MAX_SPAN then
			return nil
		end
	end
	if h < MIN_H then
		return nil
	end
	return {anchor = anchor, axis = axis, w = w, h = h}
end

local function find_frame(seed, name_at)
	return scan_frame(seed, "x", name_at) or scan_frame(seed, "z", name_at)
end

local function interior(frame)
	local out = {}
	for j = 0, frame.h - 1 do
		for i = 0, frame.w - 1 do
			out[#out + 1] = cell(frame.anchor, frame.axis, i, j)
		end
	end
	return out
end

local function light(frame, dark)
	minetest.bulk_set_node(interior(frame),
		{name = dark and DARK or PORTAL, param2 = param2_of(frame.axis)})
end

-- Is there a crystal on the frame's roof?
local function crowned(frame)
	for i = -1, frame.w do
		local p = cell(frame.anchor, frame.axis, i, frame.h + 1)
		if CRYSTALS[node_name(p)] then
			return true
		end
	end
	return false
end

local function centre_of(frame)
	return cell(frame.anchor, frame.axis, (frame.w - 1) / 2, (frame.h - 1) / 2)
end

-- Put out every portal node connected to `pos`.
local function collapse(pos)
	local start = minetest.get_node(pos)
	if not is_sheet(start.name) then
		return
	end
	local axis = axis_of(start.param2)
	local dx, dz = step_of(axis)
	local seen, queue, found = {}, {pos}, {}
	local limit = MAX_SPAN * MAX_SPAN
	while #queue > 0 and #found < limit do
		local p = table.remove(queue)
		local h = minetest.hash_node_position(p)
		if not seen[h] then
			seen[h] = true
			if node_name(p) == start.name then
				found[#found + 1] = p
				queue[#queue + 1] = {x = p.x + dx, y = p.y, z = p.z + dz}
				queue[#queue + 1] = {x = p.x - dx, y = p.y, z = p.z - dz}
				queue[#queue + 1] = {x = p.x, y = p.y + 1, z = p.z}
				queue[#queue + 1] = {x = p.x, y = p.y - 1, z = p.z}
			end
		end
	end
	if #found > 0 then
		minetest.bulk_set_node(found, {name = "air"})
		minetest.sound_play("fire_extinguish_flame",
			{pos = pos, gain = 0.6, max_hear_distance = 16}, true)
	end
end

-- ------------------------------------------------------------------
-- Records and links
-- ------------------------------------------------------------------
local records

local function load_records()
	local data = storage:get_string("sky_portals")
	local parsed = data ~= "" and minetest.deserialize(data) or nil
	records = type(parsed) == "table" and parsed or {}
end

local function save_records()
	storage:set_string("sky_portals", minetest.serialize(records))
end

load_records()

local function key_of(frame)
	local a = frame.anchor
	return a.x .. "," .. a.y .. "," .. a.z .. "," .. frame.axis
end

local function frame_of(rec)
	return {anchor = {x = rec.x, y = rec.y, z = rec.z}, axis = rec.axis,
		w = rec.w, h = rec.h}
end

local function remember(frame)
	local key = key_of(frame)
	local rec = records[key]
	if not rec then
		rec = {}
		records[key] = rec
	end
	rec.x, rec.y, rec.z = frame.anchor.x, frame.anchor.y, frame.anchor.z
	rec.axis, rec.w, rec.h = frame.axis, frame.w, frame.h
	rec.sky = frame.anchor.y >= SKY_Y
	if frame.dark ~= nil then
		rec.dark = frame.dark or nil
	end
	save_records()
	return key, rec
end

-- `from` now leads to `to`. `to` leads back to `from` unless it already
-- leads somewhere that still exists: a ground portal reused by a sky portal
-- keeps its own way home rather than having it taken over.
local function link(from, to)
	records[from].link = to
	local back = records[to].link
	if not (back and records[back]) then
		records[to].link = from
	end
	save_records()
end

-- Drop a portal that no longer exists. Several portals can lead to one
-- (a nearby portal reuses an existing far end), so clear every link to it,
-- not just its partner's.
local function forget(key)
	records[key] = nil
	for _, rec in pairs(records) do
		if rec.link == key then
			rec.link = nil
		end
	end
	save_records()
end

local function nearest_record(target, sky, radius, except)
	local best, best_key, best_d
	for key, rec in pairs(records) do
		if key ~= except and rec.sky == sky then
			local d = math.hypot(rec.x - target.x, rec.z - target.z)
			if d <= radius and (not best_d or d < best_d) then
				best, best_key, best_d = rec, key, d
			end
		end
	end
	return best_key, best
end

-- ------------------------------------------------------------------
-- Effects
-- ------------------------------------------------------------------
local function swirl(frame, amount)
	local c = centre_of(frame)
	local dx, dz = step_of(frame.axis)
	local half_w, half_h = frame.w / 2, frame.h / 2
	minetest.add_particlespawner({
		amount = amount,
		time = 1.2,
		minpos = {x = c.x - dx * half_w, y = c.y - half_h, z = c.z - dz * half_w},
		maxpos = {x = c.x + dx * half_w, y = c.y + half_h, z = c.z + dz * half_w},
		minvel = {x = -0.6, y = -0.2, z = -0.6},
		maxvel = {x = 0.6, y = 1.0, z = 0.6},
		minexptime = 0.8,
		maxexptime = 1.8,
		minsize = 1.0,
		maxsize = 2.4,
		glow = 12,
		texture = "lualore_sky_portal.png^[verticalframe:32:0",
	})
end

-- ------------------------------------------------------------------
-- Ignition
-- ------------------------------------------------------------------
local function ignite(frame, obj, stack, player_name)
	if minetest.is_protected(frame.anchor, player_name) then
		minetest.record_protection_violation(frame.anchor, player_name)
		return false
	end
	local pos = obj:get_pos()
	obj:remove()
	-- one ingot lights it; give back the rest of a dropped stack
	if stack:get_count() > 1 then
		stack:take_item(1)
		minetest.add_item(pos, stack)
	end
	frame.dark = crowned(frame)
	light(frame, frame.dark)
	local key = remember(frame)
	swirl(frame, 40 + frame.w * frame.h)
	minetest.sound_play("fire_flint_and_steel",
		{pos = centre_of(frame), gain = 1.0, max_hear_distance = 24}, true)
	minetest.log("action", "[lualore] Sky portal lit at " .. key ..
		" (" .. frame.w .. "x" .. frame.h .. ") by " .. player_name)
	return true
end

local function check_dropped_ingots(player)
	local name = player:get_player_name()
	for _, obj in ipairs(minetest.get_objects_inside_radius(player:get_pos(),
			IGNITE_RADIUS)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "__builtin:item"
				and type(ent.itemstring) == "string" then
			local stack = ItemStack(ent.itemstring)
			local pos = stack:get_name() == IGNITER and obj:get_pos()
			if pos then
				local p = vector.round(pos)
				local h = minetest.hash_node_position(p)
				-- only rescan when the ingot has moved to a new cell
				if ent._lualore_portal_seen ~= h then
					ent._lualore_portal_seen = h
					if node_name(p) == "air" then
						local frame = find_frame(p)
						if frame then
							ignite(frame, obj, stack, name)
						end
					end
				end
			end
		end
	end
end

-- ------------------------------------------------------------------
-- Finding somewhere to arrive
-- ------------------------------------------------------------------
local class_cache = {}

-- "solid" ground to build on or stand on, "clear" space (air or something
-- a node can replace, like grass), or "other" (liquid, leaves, trunks...)
local function class_of(cid)
	local c = class_cache[cid]
	if c then
		return c
	end
	local name = minetest.get_name_from_content_id(cid)
	local def = minetest.registered_nodes[name]
	if name == "air" then
		c = "clear"
	elseif not def or name == "ignore" then
		c = "other"
	elseif def.liquidtype and def.liquidtype ~= "none" then
		c = "other"
	elseif def.buildable_to and not def.walkable then
		c = "clear"
	elseif def.walkable and not def.buildable_to
			and (def.groups or {}).leaves == nil
			and (def.groups or {}).tree == nil then
		c = "solid"
	else
		c = "other"
	end
	class_cache[cid] = c
	return c
end

-- A new portal is the smallest frame: 2 wide, 3 tall inside, 4x5 outside.
local NEW_W, NEW_H = MIN_W, MIN_H

-- Would a new frame fit with its floor sunk into the ground at `ground_y`,
-- starting at column (x, z) and running along `axis`? It needs solid ground
-- under the frame and on both sides of it to step out onto, and open space
-- for the frame itself and the people standing either side.
local function fits(get, x, ground_y, z, axis)
	local dx, dz = step_of(axis)
	local nx, nz = dz, dx -- across the sheet
	for i = -1, NEW_W do
		for d = -1, 1 do
			local cx = x + dx * i + nx * d
			local cz = z + dz * i + nz * d
			if get(cx, ground_y, cz) ~= "solid" then
				return false
			end
			for j = 1, NEW_H + 1 do
				if get(cx, ground_y + j, cz) ~= "clear" then
					return false
				end
			end
		end
	end
	return true
end

-- The box to search for a landing: around a village's floor, the bare sky
-- overhead, or the ground below the floatlands.
local function search_box(target, going_up, village)
	local r = (village and VILLAGE_SEARCH or SEARCH_RADIUS) + 3
	local minp = {x = target.x - r, z = target.z - r}
	local maxp = {x = target.x + r, z = target.z + r}
	if village then
		minp.y, maxp.y = target.y - SITE_BAND, target.y + SITE_BAND
	elseif going_up then
		minp.y, maxp.y = SKY_Y, SKY_Y + SKY_SEARCH
	else
		minp.y, maxp.y = GROUND_FLOOR, SKY_Y - 8
	end
	return minp, maxp
end

-- Search a loaded box for the best place to build a portal. Going up, the
-- best is the closest to `target` in three dimensions: in a village that is
-- open ground near its middle, and height counts heavily so that a flat
-- house roof in the middle loses to the ground a few houses out; over bare
-- sky it favours the low islands straight overhead. Going down only the
-- horizontal distance counts, and only the highest ground in each column is
-- a candidate, so a cave floor never beats the surface above it.
local function find_spot(minp, maxp, target, going_up, protected_by, village)
	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data = vm:get_data()

	local function get(x, y, z)
		if x < emin.x or x > emax.x or y < emin.y or y > emax.y
				or z < emin.z or z > emax.z then
			return "other"
		end
		return class_of(data[area:index(x, y, z)])
	end

	local best, best_score
	local reach = village and VILLAGE_SEARCH or SEARCH_RADIUS
	local weight = village and 2.0 or 0.5
	for oz = -reach, reach, 2 do
		for ox = -reach, reach, 2 do
			local x, z = target.x + ox, target.z + oz
			local y = maxp.y - NEW_H - 2
			while y > minp.y do
				if get(x, y, z) == "solid" and get(x, y + 1, z) == "clear" then
					for _, axis in ipairs({"x", "z"}) do
						if fits(get, x, y, z, axis) then
							local dy = going_up and (y - target.y) * weight or 0
							local score = ox * ox + oz * oz + dy * dy
							if not best_score or score < best_score then
								local anchor = {x = x, y = y + 1, z = z}
								if not minetest.is_protected(anchor, protected_by) then
									best_score = score
									best = {anchor = anchor, axis = axis,
										w = NEW_W, h = NEW_H, ground = true}
								end
							end
						end
					end
					if not going_up then
						break -- the first ground down from the top is the surface
					end
				elseif not going_up and get(x, y, z) ~= "clear" then
					break -- water, trees: this column has no ground to offer
				end
				y = y - 1
			end
		end
	end
	return best
end

-- Nowhere suitable: build a small obsidian platform to arrive on.
local function platform_at(target, going_up, minp, maxp)
	local y
	if going_up then
		y = target.y
	else
		-- on top of whatever is highest in the target column (often water)
		y = minp.y
		for cy = maxp.y, minp.y, -1 do
			if node_name({x = target.x, y = cy, z = target.z}) ~= "air" then
				y = cy + 1
				break
			end
		end
	end
	local frame = {anchor = {x = target.x, y = y + 1, z = target.z},
		axis = "x", w = NEW_W, h = NEW_H}
	local floor, clear = {}, {}
	for i = -2, NEW_W + 1 do
		for d = -2, 2 do
			floor[#floor + 1] = {x = target.x + i, y = y, z = target.z + d}
			for j = 1, NEW_H + 2 do
				clear[#clear + 1] = {x = target.x + i, y = y + j, z = target.z + d}
			end
		end
	end
	minetest.bulk_set_node(clear, {name = "air"})
	minetest.bulk_set_node(floor, {name = PLATFORM})
	return frame
end

local function build(frame)
	local mese = {}
	for i = -1, frame.w do
		for j = -1, frame.h do
			if i == -1 or i == frame.w or j == -1 or j == frame.h then
				mese[#mese + 1] = cell(frame.anchor, frame.axis, i, j)
			end
		end
	end
	minetest.bulk_set_node(mese, {name = FRAME})
	light(frame, frame.dark)
	if frame.dark then
		-- the castle end wears its crystal too
		local top = cell(frame.anchor, frame.axis, math.floor((frame.w - 1) / 2), frame.h + 1)
		if node_name(top) == "air" then
			minetest.set_node(top, {name = "everness:crystal_purple"})
		end
	end
end

-- ------------------------------------------------------------------
-- Travel plumbing
-- ------------------------------------------------------------------
local travellers = {} -- player name -> {timer, must_leave, busy}

local function traveller(name)
	local t = travellers[name]
	if not t then
		t = {timer = 0}
		travellers[name] = t
	end
	return t
end

local function emerge_then(minp, maxp, fn)
	minetest.emerge_area(minp, maxp, function(_, _, remaining)
		if remaining == 0 then
			fn()
		end
	end)
end

local function around(frame, pad)
	local a = frame.anchor
	local dx, dz = step_of(frame.axis)
	local far = cell(a, frame.axis, frame.w, frame.h)
	return {x = math.min(a.x, far.x) - pad - dz, y = a.y - pad,
			z = math.min(a.z, far.z) - pad - dx},
		{x = math.max(a.x, far.x) + pad + dz, y = far.y + pad,
			z = math.max(a.z, far.z) + pad + dx}
end

-- Search the box around `target` for a landing spot, loading it first.
local function search(target, going_up, village, protected_by, fn)
	local minp, maxp = search_box(target, going_up, village)
	emerge_then(minp, maxp, function()
		fn(find_spot(minp, maxp, target, going_up, protected_by, village),
			minp, maxp)
	end)
end

-- ------------------------------------------------------------------
-- Sky villages
-- ------------------------------------------------------------------
-- The sky-site builder, if sky buildings are switched on.
local function sky_builder()
	local fb = lualore.floating_buildings
	if fb and fb.enabled and fb.found_at and fb.records then
		return fb
	end
	return nil
end

-- The nearest portal village. Only villages a portal founded count: the
-- grid's own hamlets are small, and a portal should lead to a town.
local function nearest_village(fb, near)
	local reach = VILLAGE_REACH
	local ok, sites = pcall(fb.records)
	if not ok or type(sites) ~= "table" then
		return nil
	end
	local best, best_key, best_d
	for site_key, site in pairs(sites) do
		if type(site) == "table" and site.big == 1
				and site.x and site.y and site.z then
			local d = math.hypot(site.x - near.x, site.z - near.z)
			if d <= reach and (not best_d or d < best_d) then
				best, best_key, best_d = site, site_key, d
			end
		end
	end
	return best, best_key
end

local function island_box(cx, y, cz, radius, depth)
	local r = (radius or ISLAND_R) + 6 -- the outline bulges past its mean
	return {x = cx - r, y = y - (depth or ISLAND_DEPTH) - 3, z = cz - r},
		{x = cx + r, y = y + ISLAND_HEADROOM, z = cz + r}
end

-- Is there open sky for an island and its houses here? The floatlands are
-- scattered through every height, so one may already fill the spot.
local function island_clear(minp, maxp)
	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data = vm:get_data()
	local c_air = minetest.get_content_id("air")
	local taken, total = 0, 0
	for z = minp.z, maxp.z do
		for y = minp.y, maxp.y do
			for x = minp.x, maxp.x do
				total = total + 1
				if data[area:index(x, y, z)] ~= c_air then
					taken = taken + 1
				end
			end
		end
	end
	return taken <= total * 0.02
end

-- Raise a crystal island with its top at `y`, made the way Everness makes
-- its crystal forest: crystal grass over crystal dirt over crystal stone.
-- The outline comes from the village ground module, so it is lobed rather
-- than round, and the underside tapers to a rough point. Only air is
-- filled; anything already there stays.
local function raise_island(cx, y, cz, seed, radius, depth_max)
	radius = radius or ISLAND_R
	depth_max = depth_max or ISLAND_DEPTH
	local ground = lualore.village_ground
	local shape = ground and ground.new_shape
		and ground.new_shape(seed, radius, radius * 0.8, 0)
	local minp, maxp = island_box(cx, y, cz, radius, depth_max)
	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data = vm:get_data()
	local c_air = minetest.get_content_id("air")
	local c_top = minetest.get_content_id("everness:dirt_with_crystal_grass")
	local c_dirt = minetest.get_content_id("everness:crystal_dirt")
	local c_stone = minetest.get_content_id("everness:crystal_stone")
	local roughness = minetest.get_perlin({offset = 0, scale = 1,
		spread = {x = 9, y = 9, z = 9}, seed = seed % 65536,
		octaves = 2, persist = 0.5})
	local reach = maxp.x - cx
	for z = cz - reach, cz + reach do
		for x = cx - reach, cx + reach do
			local dx, dz = x - cx, z - cz
			local d = math.sqrt(dx * dx + dz * dz)
			local r = radius
			if shape and d > 0 then
				r = (shape:profile(dx, dz))
			end
			if d <= r then
				local edge = 1 - d / r
				local n = roughness:get_2d({x = x, y = z})
				local depth = 2 + math.floor(depth_max * edge ^ 0.75
					* (0.8 + 0.25 * n) + 0.5)
				depth = math.min(depth, depth_max + 2)
				for yy = y - depth, y do
					local i = area:index(x, yy, z)
					if data[i] == c_air then
						if yy == y then
							data[i] = c_top
						elseif yy >= y - 2 then
							data[i] = c_dirt
						else
							data[i] = c_stone
						end
					end
				end
			end
		end
	end
	vm:set_data(data)
	vm:write_to_map(true)
end

-- Found a village above `column`: try each height in turn until one has
-- open sky, raise an island there and have the sky-site builder put a
-- village on it, castle and all. Calls done(site, key) or done(nil).
local function found_village(fb, column, protected_by, done)
	local base = fb.y_min or 500
	local seed = (column.x * 73856093 + column.z * 19349663) % 2147483647
	local i = 0
	local function try_next()
		i = i + 1
		local height = VILLAGE_HEIGHTS[i]
		if not height then
			return done(nil)
		end
		local y = base + height
		if minetest.is_protected({x = column.x, y = y, z = column.z},
				protected_by) then
			return try_next()
		end
		local minp, maxp = island_box(column.x, y, column.z)
		emerge_then(minp, maxp, function()
			if not island_clear(minp, maxp) then
				return try_next()
			end
			raise_island(column.x, y, column.z, seed)
			local ok, site, site_key = fb.found_at(column.x, column.z, {
				top = y + 1, bottom = y - 1, seed = seed,
				big = true,
				force_castle = true,
				houses = VILLAGE_HOUSES,
				max_radius = VILLAGE_RADIUS,
				tries = 16, -- a crowded ring needs more goes per house
			})
			if ok == true and type(site) == "table" then
				return done(site, site_key)
			end
			minetest.log("warning", "[lualore] Sky portal raised an island at " ..
				minetest.pos_to_string({x = column.x, y = y, z = column.z}) ..
				" but no village could be built on it")
			return done(nil)
		end)
	end
	try_next()
end

-- How far the town's island reaches from its middle along angle `a`, by
-- walking out along its floor until the floor stops.
local function rim_along(site, a)
	local reach = 0
	for r = 4, ISLAND_R * 2 do
		local x = site.x + math.floor(math.cos(a) * r + 0.5)
		local z = site.z + math.floor(math.sin(a) * r + 0.5)
		local name = node_name({x = x, y = site.y, z = z})
		if name == "air" or name == "ignore" then
			break
		end
		reach = r
	end
	return reach
end

-- Is a box nothing but air and plants? (the castle's volume, before any
-- rock is raised for it)
local function volume_clear(minp, maxp)
	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data = vm:get_data()
	for z = minp.z, maxp.z do
		for y = minp.y, maxp.y do
			for x = minp.x, maxp.x do
				if class_of(data[area:index(x, y, z)]) ~= "clear" then
					return false
				end
			end
		end
	end
	return true
end

-- Every portal town has its castle. A town founded with one already does;
-- a town built before that rule gets one now - on its own island if any
-- open ground fits it, otherwise on a rock raised for it and joined to the
-- island's rim, beyond the houses. Calls done() either way.
local function ensure_castle(fb, key, site, done)
	if site.castle == 1 or not (fb.add_castle and key) then
		return done()
	end
	local r = ISLAND_R + CASTLE_ROCK_R * 2 + 8
	local minp = {x = site.x - r, y = site.y - ISLAND_DEPTH - 4, z = site.z - r}
	local maxp = {x = site.x + r, y = site.y + 24, z = site.z + r}
	emerge_then(minp, maxp, function()
		if fb.add_castle(key) then
			return done()
		end
		local seed = (site.x * 19349663 + site.z * 83492791) % 2147483647
		for i = 0, 7 do
			local a = i * math.pi / 4
			-- overlap the rim by a third of the rock, so the two are joined
			local d = rim_along(site, a) + math.floor(CASTLE_ROCK_R * 2 / 3)
			local cx = site.x + math.floor(math.cos(a) * d + 0.5)
			local cz = site.z + math.floor(math.sin(a) * d + 0.5)
			if volume_clear({x = cx - 12, y = site.y + 1, z = cz - 12},
					{x = cx + 12, y = site.y + 20, z = cz + 12}) then
				raise_island(cx, site.y, cz, seed + i, CASTLE_ROCK_R,
					CASTLE_ROCK_DEPTH)
				if fb.add_castle(key, {at = {x = cx, z = cz}}) then
					return done()
				end
			end
		end
		minetest.log("warning", "[lualore] Sky town " .. key ..
			" has no castle and no room for one")
		return done()
	end)
end

-- ------------------------------------------------------------------
-- Wizard castles (the dark portal)
-- ------------------------------------------------------------------
local to_castle

local function nearest_castle(cc, near)
	local best, best_key, best_d
	for key, castle in pairs(cc.get_records()) do
		if type(castle) == "table" and castle.x and castle.z then
			local d = math.hypot(castle.x - near.x, castle.z - near.z)
			if d <= CASTLE_REACH and (not best_d or d < best_d) then
				best, best_key, best_d = castle, key, d
			end
		end
	end
	return best_key, best
end

-- Raise a wizard castle in the caves below `column`: on the first cave
-- floor big enough for one, or dug into the rock if there is none.
local function found_castle(cc, column, done)
	local band = cc.band or {top = -120, bottom = -1200}
	local top = band.top
	local bottom = math.max(band.bottom, top - 400)
	local plaza = (cc.get_geometry and cc.get_geometry().plaza) or 7
	local r = 48
	local function place(x, floor_y, z)
		local center = {x = x, y = floor_y - plaza, z = z}
		local rot = ({0, 90, 180, 270})[math.random(1, 4)]
		if not lualore.place_cave_castle(center, rot, {source = "dark portal"}) then
			return done(nil)
		end
		local key = cc.key_of(center)
		return done(key, cc.get_records()[key])
	end
	emerge_then({x = column.x - r, y = bottom, z = column.z - r},
		{x = column.x + r, y = top + 40, z = column.z + r}, function()
			for _, off in ipairs({{0, 0}, {24, 0}, {-24, 0}, {0, 24}, {0, -24}}) do
				local floor_y = cc.find_floor(column.x + off[1], column.z + off[2], top, bottom)
				if floor_y then
					return place(column.x + off[1], floor_y, column.z + off[2])
				end
			end
			return place(column.x, top - 80, column.z) -- no cave: dig it in
		end)
end

-- Where a dark portal leads: the nearest wizard castle, or a new one.
-- The far end is a dark portal of its own, crowned, at the castle.
to_castle = function(column, ctx, settle, done)
	local cc = lualore.cave_castle
	if not (cc and cc.get_records and cc.find_floor and lualore.place_cave_castle) then
		return done(nil)
	end
	local plaza = (cc.get_geometry and cc.get_geometry().plaza) or 7
	local function land(castle_key, castle)
		if not castle then
			return done(nil)
		end
		local floor = castle.y + plaza
		local target = {x = castle.x, y = floor, z = castle.z}
		search(target, true, true, ctx.name, function(frame, minp, maxp)
			if not frame then
				-- no open floor about the castle: hollow out a landing beside it
				local b = cc.castle_bounds and cc.castle_bounds(
					{x = castle.x, y = castle.y, z = castle.z}, castle.rot)
				local side = {x = (b and b.maxx or castle.x + 20) + 6, y = floor, z = castle.z}
				frame = platform_at(side, true, minp, maxp)
			end
			frame.dark = true
			return settle(frame, nil, castle_key)
		end)
	end
	local castle_key, castle = nearest_castle(cc, column)
	if castle then
		return land(castle_key, castle)
	end
	if ctx.say then
		ctx.say(S("Far below, something old stirs in the rock..."))
	end
	found_castle(cc, column, land)
end

-- ------------------------------------------------------------------
-- Resolving a destination
-- ------------------------------------------------------------------
-- Every failed check below forgets a record before retrying, so this
-- cannot loop; the limit only stops a world full of stale records from
-- making one trip take forever.
local MAX_RETRIES = 8

-- Work out where the portal `key` leads, building the far end if need be,
-- then call done(dest_key) - or done(nil) if there is nowhere to go.
-- `ctx` is {name = player name (for protection), say = function(msg)}.
local function resolve(key, ctx, done, depth)
	depth = depth or 0
	local rec = records[key]
	if not rec or depth > MAX_RETRIES then
		return done(nil)
	end

	-- already linked: load the far end and make sure it still stands
	if rec.link and records[rec.link] then
		local dest_key, dest = rec.link, records[rec.link]
		local anchor = {x = dest.x, y = dest.y, z = dest.z}
		local minp, maxp = around(frame_of(dest), 2)
		return emerge_then(minp, maxp, function()
			if node_name(anchor) == "ignore" then
				return done(nil) -- not loaded after all; try again later
			end
			local frame = scan_frame(anchor, dest.axis)
			if frame and frame.w == dest.w and frame.h == dest.h then
				light(frame, dest.dark) -- relight it in case it was put out and repaired
				-- A village portal's town must have its castle. Checked on
				-- every trip in, not just the first: portals linked to a
				-- town built before every town had one would otherwise
				-- never bring it one. Costs nothing once the castle stands.
				local fb = dest.village and sky_builder()
				local site, site_key
				if fb then
					site, site_key = nearest_village(fb, dest)
				end
				if site then
					return ensure_castle(fb, site_key, site, function()
						done(dest_key)
					end)
				end
				return done(dest_key)
			end
			-- the far end is gone; forget it and look again
			forget(dest_key)
			return resolve(key, ctx, done, depth + 1)
		end)
	end

	local going_up = not rec.sky
	local here = centre_of(frame_of(rec))
	local column = {x = math.floor(here.x + 0.5), z = math.floor(here.z + 0.5),
		y = going_up and SKY_AIM or 0}

	local function settle(frame, village, castle_key)
		build(frame)
		local dest_key, dest = remember(frame)
		dest.village = village or nil
		dest.castle = castle_key
		link(key, dest_key)
		minetest.log("action", "[lualore] Sky portal " .. key ..
			" linked to new portal " .. dest_key ..
			(village and " in a sky village" or ""))
		return done(dest_key)
	end

	-- The bare sky overhead (or the ground below), and failing that a
	-- platform: what a portal does when there is no village to go to.
	local function fall_back_to_column()
		search(column, going_up, false, ctx.name, function(frame, minp, maxp)
			if frame then
				return settle(frame)
			end
			if minetest.is_protected(column, ctx.name) then
				return done(nil)
			end
			return settle(platform_at(column, going_up, minp, maxp))
		end)
	end

	-- Make sure the town has its castle, then land on open ground as near
	-- its middle as possible. A village whose ground is all taken sends the
	-- portal to the column search instead of clearing a platform among its
	-- houses.
	local function land_in_village(fb, site, site_key)
		ensure_castle(fb, site_key, site, function()
			search({x = site.x, y = site.y, z = site.z}, true, true, ctx.name,
				function(frame)
					if frame then
						return settle(frame, true)
					end
					return fall_back_to_column()
				end)
		end)
	end

	if rec.dark then
		return to_castle(column, ctx, settle, done)
	end

	if not going_up then
		-- a ground portal already standing close by serves as the far end
		local near_key = nearest_record(column, false, REUSE_RADIUS, key)
		if near_key then
			link(key, near_key)
			return resolve(key, ctx, done, depth + 1)
		end
		return fall_back_to_column()
	end

	local fb = sky_builder()
	if not fb then
		return fall_back_to_column()
	end
	local site, site_key = nearest_village(fb, column)
	if site then
		return land_in_village(fb, site, site_key)
	end
	if ctx.say then
		ctx.say(S("Far above, an island gathers itself out of the clouds..."))
	end
	found_village(fb, column, ctx.name, function(new_site, new_key)
		if new_site then
			return land_in_village(fb, new_site, new_key)
		end
		return fall_back_to_column()
	end)
end

local function arrive(player, dest_key)
	local dest = records[dest_key]
	local frame = frame_of(dest)
	local spot = cell(frame.anchor, frame.axis, math.floor((frame.w - 1) / 2), 0)
	local dx, dz = step_of(frame.axis)
	-- the sheet's centre, feet on the frame's floor
	player:set_pos({x = spot.x + dx * ((frame.w - 1) % 2) * 0.5,
		y = spot.y - 0.5, z = spot.z + dz * ((frame.w - 1) % 2) * 0.5})
	-- face out of the sheet
	player:set_look_horizontal(frame.axis == "x" and 0 or math.pi * 1.5)
	swirl(frame, 30)
	minetest.sound_play("magic",
		{pos = centre_of(frame), gain = 0.8, max_hear_distance = 20}, true)
	if dest.castle then
		minetest.chat_send_player(player:get_player_name(),
			S("You step out beneath the earth, into the wizards' domain."))
		-- an emptied castle gathers its wizards again (once an hour at most)
		local cc = lualore.cave_castle
		if cc and cc.regather then
			minetest.after(5, function()
				cc.regather(cc.get_records()[dest.castle])
			end)
		end
	elseif dest.village then
		minetest.chat_send_player(player:get_player_name(),
			S("You step out into a sky village. Mind the edge."))
		-- Fill the town up to its headcount. Wait a few seconds first: the
		-- town only becomes active around the player once they are there,
		-- and counting its people before that would count none of them.
		local fb = sky_builder()
		local _, town_key = fb and nearest_village(fb, dest)
		if town_key and lualore.sky_town and lualore.sky_town.populate then
			minetest.after(4, lualore.sky_town.populate, town_key)
		end
	elseif dest.sky then
		minetest.chat_send_player(player:get_player_name(),
			S("You step out among the sky islands. Mind the edge."))
	end
end

-- Is this player still standing in (or right beside) the portal they
-- started from? Nobody is whisked away after they have walked off.
local function still_at(player, frame)
	local c = centre_of(frame)
	local p = player:get_pos()
	return math.abs(p.y + 1 - c.y) <= frame.h / 2 + 1.5
		and math.hypot(p.x - c.x, p.z - c.z) <= frame.w / 2 + 1.5
end

-- A crystal set on (or taken off) a lit portal's roof turns the sheet
-- black (or blue) at once. It now leads somewhere else, so this end forgets
-- its link and finds its new far end on the next trip.
local function sync_crown(frame, node)
	local dark = crowned(frame)
	if dark == (node.name == DARK) then
		return false
	end
	frame.dark = dark
	light(frame, dark)
	local _, rec = remember(frame)
	rec.link = nil
	save_records()
	swirl(frame, 20 + frame.w * frame.h)
	return true
end

local function recrown_near(pos)
	-- the sheet is two below the crystal, or diagonally so if the crystal
	-- sits over a wall or corner
	for dx = -1, 1 do
		for dz = -1, 1 do
			local p = {x = pos.x + dx, y = pos.y - 2, z = pos.z + dz}
			local node = minetest.get_node(p)
			if is_sheet(node.name) then
				local frame = scan_frame(p, axis_of(node.param2))
				if frame then
					sync_crown(frame, node)
				end
				return
			end
		end
	end
end

minetest.register_on_placenode(function(pos, newnode)
	if CRYSTALS[newnode.name] then
		recrown_near(pos)
	end
end)

local function depart(player, portal_pos)
	local name = player:get_player_name()
	local t = traveller(name)
	local node = minetest.get_node(portal_pos)
	local frame = is_sheet(node.name)
		and scan_frame(portal_pos, axis_of(node.param2))
	if not frame then
		t.must_leave = true
		return
	end
	-- crowned or uncrowned since it was lit, by something that did not
	-- tell us (WorldEdit, another mod): catch up now
	sync_crown(frame, node)
	frame.dark = crowned(frame)
	local key = remember(frame)
	t.busy = true
	if not records[key].link then
		minetest.chat_send_player(name, records[key].dark
			and S("The dark portal reaches down into the deep...")
			or records[key].sky
			and S("The portal reaches down toward the ground...")
			or S("The portal reaches up toward the sky islands..."))
	end
	local ctx = {
		name = name,
		say = function(msg)
			minetest.chat_send_player(name, msg)
		end,
	}
	resolve(key, ctx, function(dest_key)
		t.busy = false
		t.must_leave = true
		local who = minetest.get_player_by_name(name)
		if not who then
			return
		end
		if not dest_key then
			minetest.chat_send_player(name,
				S("The portal flickers, but finds nowhere to open."))
			return
		end
		if still_at(who, frame) then
			arrive(who, dest_key)
		end
	end)
end

local function portal_under(player)
	local p = player:get_pos()
	local feet = vector.round({x = p.x, y = p.y + 0.1, z = p.z})
	if is_sheet(node_name(feet)) then
		return feet
	end
	local head = {x = feet.x, y = feet.y + 1, z = feet.z}
	if is_sheet(node_name(head)) then
		return head
	end
	return nil
end

local function check_traveller(player, dtime)
	local t = traveller(player:get_player_name())
	local pos = portal_under(player)
	if not pos then
		t.timer = 0
		t.must_leave = false
		return
	end
	if t.must_leave or t.busy then
		return
	end
	t.timer = t.timer + dtime
	if t.timer >= TRAVEL_DELAY then
		t.timer = 0
		depart(player, pos)
	end
end

-- ------------------------------------------------------------------
-- Upkeep
-- ------------------------------------------------------------------
local DIRS = {
	{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0},
	{x = 0, y = 1, z = 0}, {x = 0, y = -1, z = 0},
	{x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1},
}

-- Taking a frame block out puts the sheet out at once.
minetest.register_on_dignode(function(pos, oldnode)
	if CRYSTALS[oldnode.name] then
		recrown_near(pos) -- the crown came off: the sheet turns blue again
		return
	end
	if oldnode.name ~= FRAME then
		return
	end
	for _, d in ipairs(DIRS) do
		local p = vector.add(pos, d)
		if is_sheet(node_name(p)) then
			collapse(p)
		end
	end
end)

-- Backstop for frames broken some other way (explosions, WorldEdit): a
-- sheet node whose in-plane neighbours are neither sheet nor frame has lost
-- its frame.
minetest.register_abm({
	label = "Lualore sky portal frame check",
	nodenames = {PORTAL, DARK},
	interval = 7,
	chance = 1,
	catch_up = false,
	action = function(pos, node)
		local dx, dz = step_of(axis_of(node.param2))
		for _, d in ipairs({{dx, 0, dz}, {-dx, 0, -dz}, {0, 1, 0}, {0, -1, 0}}) do
			local name = node_name({x = pos.x + d[1], y = pos.y + d[2],
				z = pos.z + d[3]})
			if not is_sheet(name) and name ~= FRAME then
				collapse(pos)
				return
			end
		end
	end,
})

if ENABLED then
	local clock = 0
	minetest.register_globalstep(function(dtime)
		clock = clock + dtime
		if clock < TICK then
			return
		end
		local step = clock
		clock = 0
		for _, player in ipairs(minetest.get_connected_players()) do
			check_dropped_ingots(player)
			check_traveller(player, step)
		end
	end)

	-- Logging in inside a sheet should not fling anyone straight off.
	minetest.register_on_joinplayer(function(player)
		traveller(player:get_player_name()).must_leave = true
	end)

	minetest.register_on_leaveplayer(function(player)
		travellers[player:get_player_name()] = nil
	end)
end

-- ------------------------------------------------------------------
-- API and commands
-- ------------------------------------------------------------------
lualore.sky_portal.find_frame = find_frame
lualore.sky_portal.scan_frame = scan_frame
lualore.sky_portal.records = function()
	return records
end
lualore.sky_portal.SKY_Y = SKY_Y

minetest.register_chatcommand("sky_portals", {
	params = "[radius]",
	description = S("List sky portals near you and where they lead " ..
		"(default radius 128)."),
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false
		end
		local pos = player:get_pos()
		local radius = tonumber(param) or 128
		local lines = {}
		for key, rec in pairs(records) do
			local d = vector.distance(pos, {x = rec.x, y = rec.y, z = rec.z})
			if d <= radius then
				local dest = rec.link and records[rec.link]
				lines[#lines + 1] = string.format(
					"%s portal %dx%d at (%d,%d,%d), %d m away - %s",
					rec.dark and "Dark" or rec.sky and "Sky" or "Ground", rec.w, rec.h,
					rec.x, rec.y, rec.z, math.floor(d),
					dest and string.format("leads to (%d,%d,%d)",
						dest.x, dest.y, dest.z) or "not linked yet")
			end
		end
		if #lines == 0 then
			return true, S("No sky portals within @1 nodes.", radius)
		end
		table.sort(lines)
		return true, table.concat(lines, "\n")
	end,
})
