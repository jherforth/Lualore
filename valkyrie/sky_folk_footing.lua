--[[
	Keeping Sky Folk on their islands.

	Sky Folk kept walking off the edge. mobs_redo's own fear_height check
	only covers its walk state, and plenty else moves them: Sky Folk set
	their own velocity in do_custom (heading for doorways at night, for each
	other when socialising), they chase players, they get knocked back when
	hit, and they jump. None of that looks at the ground ahead, and an
	island edge is a drop of hundreds of nodes.

	So this works on what is actually happening to the mob, whatever moved
	it, in two layers:

	  1. Prevention. A Sky Folk moving towards a drop deeper than 3 nodes
	     (the drop it is allowed to step down, its fear_height) is stopped
	     and turned round.
	  2. Rescue. One that goes over anyway is caught as soon as it is
	     falling with no ground within 4 nodes below, and put back on the
	     last solid ground it stood on well inside its island.

	lualore.sky_folk_footing.step(self, dtime) runs at the top of the Sky
	Folk's do_custom. It returns "halted" when it has just stopped or
	rescued one, and do_custom then returns false so mobs_redo skips its own
	movement for that step.
]]

lualore.sky_folk_footing = {}

local STEP_DOWN = 3        -- deepest drop a Sky Folk may step down (fear_height)
local FALL_GROUND = 4      -- falling with no ground this close below: off an edge
local FALL_SPEED = -3      -- faster than this downwards counts as falling
local LOOK_AHEAD = 0.9     -- how far ahead of its feet it checks for ground
local SAFE_EVERY = 1.0     -- seconds between updates of its last safe footing
local INSIDE = 2           -- safe footing has ground this far out on all sides

local function walkable(x, y, z)
	local node = minetest.get_node_or_nil({x = x, y = y, z = z})
	if not node then
		return true -- not loaded: assume ground rather than "rescue" a mob
	end
	local def = minetest.registered_nodes[node.name]
	return def ~= nil and def.walkable == true
end

-- Ground within `depth` nodes below the feet at (x, feet_y, z)? The feet
-- of a mob standing on node y are at y + 0.5.
local function ground_within(x, feet_y, z, depth)
	local y = math.floor(feet_y) -- the node at or just below the feet
	for i = 0, depth - 1 do
		if walkable(x, y - i, z) then
			return true
		end
	end
	return false
end

-- Footing worth returning to: standing on ground, with ground INSIDE nodes
-- out on all four sides, so a rescued mob is not put straight back on the
-- lip it fell from.
local function well_inside(pos)
	if not ground_within(pos.x, pos.y, pos.z, 1) then
		return false
	end
	for _, d in ipairs({{INSIDE, 0}, {-INSIDE, 0}, {0, INSIDE}, {0, -INSIDE}}) do
		if not ground_within(pos.x + d[1], pos.y, pos.z + d[2], 2) then
			return false
		end
	end
	return true
end

local function halt(self)
	self.state = "stand"
	if type(self.set_animation) == "function" then
		pcall(self.set_animation, self, "stand")
	end
end

-- Face directly away from (dx, dz).
local function turn_from(self, dx, dz)
	local yaw = math.atan2(-dx, dz) + math.pi
	self.object:set_yaw(yaw)
	if type(self.set_yaw) == "function" then
		pcall(self.set_yaw, self, yaw, 0)
	end
end

function lualore.sky_folk_footing.step(self, dtime)
	local obj = self.object
	local pos = obj and obj:get_pos()
	if not pos then
		return
	end
	local vel = obj:get_velocity() or {x = 0, y = 0, z = 0}

	-- 1. Gone over: put it back.
	if vel.y < FALL_SPEED and not ground_within(pos.x, pos.y, pos.z, FALL_GROUND) then
		local back = self.sf_safe_pos
		if back then
			obj:set_pos({x = back.x, y = back.y + 0.1, z = back.z})
			obj:set_velocity({x = 0, y = 0, z = 0})
			halt(self)
			self.sf_rescues = (self.sf_rescues or 0) + 1
			return "halted"
		end
		return
	end

	-- 2. Heading for a drop: stop and turn round.
	local speed = math.sqrt(vel.x * vel.x + vel.z * vel.z)
	if speed > 0.2 then
		local dx, dz = vel.x / speed, vel.z / speed
		if not ground_within(pos.x + dx * LOOK_AHEAD, pos.y, pos.z + dz * LOOK_AHEAD,
				STEP_DOWN) then
			obj:set_velocity({x = 0, y = vel.y, z = 0})
			turn_from(self, dx, dz)
			halt(self)
			return "halted"
		end
	end

	-- 3. Remember good footing.
	self.sf_safe_timer = (self.sf_safe_timer or 0) + dtime
	if self.sf_safe_timer >= SAFE_EVERY then
		self.sf_safe_timer = 0
		if well_inside(pos) then
			self.sf_safe_pos = {x = pos.x, y = pos.y, z = pos.z}
		end
	end
end
