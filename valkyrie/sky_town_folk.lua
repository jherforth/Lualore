--[[
	Sky towns: their people, and their freedom.

	A portal town (see portal/SKY_PORTAL.md) should feel lived in. Its
	founders arrive in a few groups when it is built; after that, whenever a
	player steps out of a portal into the town, it is topped up to
	lualore_portal_village_folk Sky Folk (40 by default), so it fills up on
	the first visit and recovers from losses on later ones. Town folk keep
	(see their lifetimer in sky_folk.lua), so a top-up only makes good the
	ones that died or fell. New arrivals are
	put on open ground outdoors, well inside the island - never inside a
	house or the castle, never on the rim.

	Freedom is remembered per town. The valkyrie fight frees the Sky Folk
	near it, but only the ones that are loaded: Luanti keeps entities active
	about 64 nodes around a player, and a town is wider than that, so folk
	across the town would never hear the news. When the fight is won the
	town itself is marked free, and any Sky Folk that wakes up in a free
	town - unloaded at the time, or arriving later - is free too.
]]

lualore.sky_town = {}

local TARGET = math.max(0, math.floor(tonumber(
	minetest.settings:get("lualore_portal_village_folk")) or 40))

local COUNT_R = 64        -- Sky Folk this close to the middle count as residents
local SPAWN_R = 44        -- newcomers arrive within this of the middle
local SPAWN_MIN_R = 6     -- ...and not right on top of the castle door
local REFILL_EVERY = 120  -- seconds between top-ups of one town
local TOWN_REACH = 130    -- a portal town reaches this far (castle rock included)
local HAMLET_REACH = 60

local function builder()
	local fb = lualore.floating_buildings
	if fb and fb.records then
		return fb
	end
	return nil
end

local function walkable(x, y, z)
	local node = minetest.get_node_or_nil({x = x, y = y, z = z})
	local def = node and minetest.registered_nodes[node.name]
	return def ~= nil and def.walkable == true
end

-- The town (sky site record) a position belongs to, if any.
function lualore.sky_town.town_at(pos)
	local fb = builder()
	if not fb then
		return nil
	end
	local ok, sites = pcall(fb.records)
	if not ok or type(sites) ~= "table" then
		return nil
	end
	local best, best_key, best_d
	for key, site in pairs(sites) do
		if type(site) == "table" and site.x and site.y and site.z
				and math.abs(pos.y - site.y) <= 48 then
			local reach = site.big == 1 and TOWN_REACH or HAMLET_REACH
			local d = math.hypot(pos.x - site.x, pos.z - site.z)
			if d <= reach and (not best_d or d < best_d) then
				best, best_key, best_d = site, key, d
			end
		end
	end
	return best, best_key
end

-- Has this Sky Folk's town been freed?
function lualore.sky_town.freed_at(pos)
	local site = lualore.sky_town.town_at(pos)
	return site ~= nil and site.liberated == 1
end

-- The valkyrie fight was won at `pos`: every town it belongs to is free.
function lualore.sky_town.mark_freed(pos)
	local fb = builder()
	if not fb then
		return
	end
	local ok, sites = pcall(fb.records)
	if not ok or type(sites) ~= "table" then
		return
	end
	local changed = false
	for key, site in pairs(sites) do
		if type(site) == "table" and site.x and site.z and site.liberated ~= 1 then
			local reach = site.big == 1 and TOWN_REACH or HAMLET_REACH
			if math.hypot(pos.x - site.x, pos.z - site.z) <= reach
					and math.abs((pos.y or site.y) - site.y) <= 64 then
				site.liberated = 1
				changed = true
				minetest.log("action", "[lualore] Sky town " .. key .. " is free")
			end
		end
	end
	if changed and fb.save then
		fb.save()
	end
end

-- Somewhere a newcomer can stand: on the island's floor near `floor_y`,
-- two nodes of headroom, open sky above (outdoors, not in a house or the
-- castle), and ground two nodes out on every side (not on the rim).
local function standing_spot(x, floor_y, z)
	for y = floor_y + 3, floor_y - 3, -1 do
		if walkable(x, y, z) and not walkable(x, y + 1, z)
				and not walkable(x, y + 2, z) then
			for above = y + 3, y + 10 do
				if walkable(x, above, z) then
					return nil -- under a roof
				end
			end
			for _, d in ipairs({{2, 0}, {-2, 0}, {0, 2}, {0, -2}}) do
				if not (walkable(x + d[1], y, z + d[2])
						or walkable(x + d[1], y - 1, z + d[2])) then
					return nil -- too near an edge
				end
			end
			return y
		end
	end
	return nil
end

-- Bring a town up to its full headcount. Returns how many arrived.
function lualore.sky_town.populate(key)
	local fb = builder()
	local site = fb and fb.records()[key]
	if not site or site.big ~= 1 or TARGET == 0 then
		return 0
	end
	local now = os.time()
	if site.folk_at and now - site.folk_at < REFILL_EVERY then
		return 0
	end

	local centre = {x = site.x, y = site.y + 1, z = site.z}
	local residents = 0
	for _, obj in ipairs(minetest.get_objects_inside_radius(centre, COUNT_R)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "lualore:sky_folk" then
			residents = residents + 1
		end
	end

	local want = TARGET - residents
	local arrived, tries = 0, 0
	while arrived < want and tries < want * 12 do
		tries = tries + 1
		local a = math.random() * 2 * math.pi
		local r = SPAWN_MIN_R + math.random() * (SPAWN_R - SPAWN_MIN_R)
		local x = math.floor(site.x + math.cos(a) * r + 0.5)
		local z = math.floor(site.z + math.sin(a) * r + 0.5)
		-- the band holds for the whole node, not just before rounding
		local d = math.hypot(x - site.x, z - site.z)
		local y = d >= SPAWN_MIN_R and d <= SPAWN_R and standing_spot(x, site.y, z)
		if y then
			local obj = minetest.add_entity({x = x, y = y + 0.5, z = z}, "lualore:sky_folk")
			local ent = obj and obj:get_luaentity()
			if ent then
				arrived = arrived + 1
				if site.liberated == 1 and lualore.sky_liberation
						and lualore.sky_liberation.free then
					lualore.sky_liberation.free(ent, true)
				end
			end
		end
	end

	site.folk_at = now
	if fb.save then
		fb.save()
	end
	if arrived > 0 then
		minetest.log("action", string.format(
			"[lualore] Sky town %s: %d residents, %d more arrived", key,
			residents, arrived))
	end
	return arrived
end
