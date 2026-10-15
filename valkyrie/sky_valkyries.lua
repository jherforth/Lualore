local S = minetest.get_translator("lualore")

-- Import only the functions we need for spawning/attaching
local attach_wings = lualore.sky_wings.attach_wings
-- We NO LONGER need remove_wings as an import → we handle cleanup internally

lualore.sky_valkyries = {}

local spawned_valkyries = {}
local storage = minetest.get_mod_storage()

local function load_spawned_valkyries()
    local data = storage:get_string("spawned_valkyries")
    if data and data ~= "" then
        spawned_valkyries = minetest.deserialize(data) or {}
    end
end

local save_timer = 0
minetest.register_globalstep(function(dtime)
    save_timer = save_timer + dtime
    if save_timer >= 60 then
        save_timer = 0
        storage:set_string("spawned_valkyries", minetest.serialize(spawned_valkyries))
    end
end)

load_spawned_valkyries()

local valkyrie_types = {
    {
        name = "blue_valkyrie",
        display_name = "Blue Valkyrie (Fury Sentinel)",
        texture = "blue_valkyrie.png",
        wing_texture = "blue_valkyrie_wings.png",
        drops = {
            {name = "default:mese_crystal", chance = 1, min = 2, max = 5},
            {name = "default:diamond", chance = 1, min = 1, max = 3},
            {name = "lualore:blue_wings", chance = 1, min = 1, max = 1}
        }
    },
    {
        name = "violet_valkyrie",
        display_name = "Violet Valkyrie (Gale Sentinel)",
        texture = "violet_valkyrie.png",
        wing_texture = "violet_valkyrie_wings.png",
        drops = {
            {name = "default:mese_crystal", chance = 1, min = 2, max = 5},
            {name = "default:diamond", chance = 1, min = 1, max = 3},
            {name = "lualore:violet_wings", chance = 1, min = 1, max = 1}
        }
    },
    {
        name = "gold_valkyrie",
        display_name = "Gold Valkyrie (Thunder Sentinel)",
        texture = "gold_valkyrie.png",
        wing_texture = "gold_valkyrie_wings.png",
        drops = {
            {name = "default:mese_crystal", chance = 1, min = 2, max = 5},
            {name = "default:diamond", chance = 1, min = 1, max = 3},
            {name = "default:gold_lump", chance = 1, min = 3, max = 7},
            {name = "lualore:gold_wings", chance = 1, min = 1, max = 1}
        }
    },
    {
        name = "green_valkyrie",
        display_name = "Green Valkyrie (Eclipse Sentinel)",
        texture = "green_valkyrie.png",
        wing_texture = "green_valkyrie_wings.png",
        drops = {
            {name = "default:mese_crystal", chance = 1, min = 2, max = 5},
            {name = "default:diamond", chance = 1, min = 1, max = 3},
            {name = "default:obsidian", chance = 1, min = 2, max = 5},
            {name = "lualore:green_wings", chance = 1, min = 1, max = 1}
        }
    }
}

local function broadcast_sky_folk_alert(pos)
    local objects = minetest.get_objects_inside_radius(pos, 40)
    for _, obj in ipairs(objects) do
        local ent = obj:get_luaentity()
        if ent and ent.name and ent.name:match("lualore:.*_valkyrie") then
            if ent.enraged ~= true then
                ent.enraged = true
                ent.rage_timer = 10
                local current_speed = ent.run_velocity or 3.5
                ent.run_velocity = current_speed * 1.5
                ent.damage = (ent.damage or 8) + 2
                minetest.chat_send_all(S("A Valkyrie has been enraged by harm to the Sky Folk!"))
            end
        end
    end
end

lualore.sky_valkyries.broadcast_alert = broadcast_sky_folk_alert

for _, valkyrie in ipairs(valkyrie_types) do
    local valkyrie_name = valkyrie.name
    local valkyrie_texture = valkyrie.texture
    local valkyrie_wing_texture = valkyrie.wing_texture
    local valkyrie_drops = valkyrie.drops
    local valkyrie_display = valkyrie.display_name

    local mob_name = "lualore:" .. valkyrie_name

    mobs:register_mob(mob_name, {
        type = "monster",
        passive = false,
        damage = 8,
        attack_type = "dogfight",
        attacks_monsters = false,
        attack_npcs = false,
        attack_players = true,
        owner_loyal = false,
        pathfinding = true,
        hp_min = 100,
        hp_max = 150,
        armor = 150,
        reach = 2,
        collisionbox = {-0.35, 0.0, -0.35, 0.35, 1.8, 0.35},
        stepheight = 1.1,
        visual = "mesh",
        mesh = "character.b3d",
        textures = {{valkyrie_texture}},
        visual_size = {x=1.1, y=1.1},
        makes_footstep_sound = true,
        sounds = {},
        walk_velocity = 2.0,
        walk_chance = 30,
        run_velocity = 3.5,
        jump = true,
        jump_height = 6,
        fly = true,
        fly_in = {"air"},
        drops = valkyrie_drops,
        water_damage = 0,
        lava_damage = 4,
        light_damage = 0,
        follow = {},
        view_range = 20,
        fear_height = 0,
        animation = {
            speed_normal = 30,
            stand_start = 0,
            stand_end = 79,
            walk_start = 168,
            walk_end = 187,
            punch_start = 189,
            punch_end = 198,
            die_start = 162,
            die_end = 166,
            die_speed = 15,
            die_loop = false,
            die_rotate = true,
        },

        on_activate = function(self, staticdata, dtime_s)
            local color = self.name:match("lualore:(%w+)_valkyrie")
            if not color then
                minetest.log("error", "[lualore] Could not extract color from " .. self.name)
                return
            end

            self.valkyrie_base_texture = valkyrie_texture
            self.valkyrie_wing_texture = valkyrie_wing_texture

            if not self.assigned_strikes then
                self.assigned_strikes = lualore.valkyrie_strikes.assign_random_strikes()
                minetest.log("action", "[lualore] Valkyrie assigned " .. #self.assigned_strikes .. " strikes")
            end

            self.current_strike = 1
            self.strike_timer = 0
            self.strike_interval = 2.5
            self.hover_timer = 0
            self.hover_offset = math.random() * 2 * math.pi
            self.wing_flap_timer = 0
            self.just_spawned = true
            self.spawn_fly_timer = 5

            -- Set base texture only (wings handled by attached entity)
            self.object:set_properties({ textures = {valkyrie_texture} })

            -- Attach wing sprite
            attach_wings(self.object, color)

            -- Start in flight mode
            minetest.after(0.1, function()
                if self and self.object then
                    self.object:set_velocity({x=0, y=2, z=0})
                end
            end)
        end,

        -- Reliable cleanup: Find and remove attached wing entity on death
        on_die = function(self)
            if not self.object then return end

            local pos = self.object:get_pos()
            if not pos then return end

            -- Look for nearby wing_visual entities and remove them
            local objects = minetest.get_objects_inside_radius(pos, 4)  -- generous radius
            for _, obj in ipairs(objects) do
                local ent = obj:get_luaentity()
                if ent and ent.name == "lualore:wing_visual" then
                    obj:remove()
                end
            end

            -- Clear all valkyrie strike effects from nearby players
            if lualore.valkyrie_strikes and lualore.valkyrie_strikes.clear_all_player_effects then
                local players = minetest.get_objects_inside_radius(pos, 50)
                for _, obj in ipairs(players) do
                    if obj:is_player() then
                        lualore.valkyrie_strikes.clear_all_player_effects(obj)
                    end
                end
                minetest.log("action", "[lualore] Cleared valkyrie strike effects from nearby players on valkyrie death")
            end

            -- A chest valkyrie counts towards its chest's fight, and the
            -- fight frees the town when all four are down (valkyrie_fight.lua).
            -- Any other valkyrie keeps the old rule: when none are left
            -- nearby, the Sky Folk around are freed.
            if lualore.valkyrie_fight and lualore.valkyrie_fight.defeated(self) then
                return
            end
            if lualore.sky_liberation then
                minetest.after(0.5, function()
                    lualore.sky_liberation.check_and_liberate(pos)
                end)
            end
        end,

        do_custom = function(self, dtime)
            -- A chest valkyrie reports in to its fight; one whose fight is
            -- over has removed itself (valkyrie_fight.lua).
            if lualore.valkyrie_fight
                    and lualore.valkyrie_fight.heartbeat(self) == "gone" then
                return false
            end
            local success, err = pcall(function()
                if self.enraged and self.rage_timer then
                    self.rage_timer = self.rage_timer - dtime
                    if self.rage_timer <= 0 then
                        self.enraged = false
                        self.run_velocity = 3.5
                        self.damage = 8
                    end
                end

                if not self.assigned_strikes then
                    self.assigned_strikes = lualore.valkyrie_strikes.assign_random_strikes()
                    self.current_strike = 1
                end

                local pos = self.object:get_pos()
                if not pos then return end

                local target = self.attack
                if not target or not target:is_player() then
                    for _, player in ipairs(minetest.get_connected_players()) do
                        local player_pos = player:get_pos()
                        if player_pos and pos and vector.distance(pos, player_pos) <= self.view_range then
                            self.attack = player
                            target = player
                            minetest.log("action", "[lualore] Valkyrie acquired target: " .. player:get_player_name())
                            break
                        end
                    end
                end

                self.hover_timer = (self.hover_timer or 0) + dtime
                self.wing_flap_timer = (self.wing_flap_timer or 0) + dtime

                if self.spawn_fly_timer then
                    self.spawn_fly_timer = self.spawn_fly_timer - dtime
                    if self.spawn_fly_timer <= 0 then
                        self.spawn_fly_timer = nil
                        self.just_spawned = false
                    end
                end

                local hover_y = math.sin((self.hover_timer + (self.hover_offset or 0)) * 2) * 0.4
                local wing_angle = math.sin(self.wing_flap_timer * 8) * 20

                local vel = self.object:get_velocity()
                local is_moving = false
                local in_flight = false

                if vel and vel.x and vel.y and vel.z then
                    is_moving = math.abs(vel.x) > 0.5 or math.abs(vel.z) > 0.5 or math.abs(vel.y) > 0.5
                end

                -- Stay in flight during spawn period or when in combat
                if self.just_spawned or (target and target:is_player()) then
                    in_flight = true
                    if vel and vel.x and vel.y and vel.z then
                        if self.just_spawned then
                            if vel.y < 0 then
                                self.object:set_velocity({x=vel.x * 0.8, y=hover_y + 0.5, z=vel.z * 0.8})
                            end
                        elseif math.abs(vel.x) < 0.5 and math.abs(vel.z) < 0.5 then
                            self.object:set_velocity({x=vel.x, y=hover_y, z=vel.z})
                        elseif vel.y < -2 then
                            self.object:set_velocity({x=vel.x, y=vel.y * 0.7, z=vel.z})
                        end
                    end
                else
                    -- No target and spawn period over - descend to ground if airborne
                    if pos and pos.x and pos.y and pos.z then
                        local below_pos = {x=pos.x, y=pos.y - 0.5, z=pos.z}
                        local node_below = minetest.get_node(below_pos)

                        -- Check if there's solid ground below
                        if node_below.name == "air" or node_below.name == "ignore" then
                            -- Still airborne, apply gentle descent velocity
                            if vel and vel.x and vel.z then
                                self.object:set_velocity({x=vel.x * 0.8, y=-1.5, z=vel.z * 0.8})
                            end
                        end
                    end
                end

                if self.object.set_bone_position then
                    if in_flight and is_moving then
                        -- Flight mode: Rotate for head-first belly-down flying
                        self.object:set_bone_position("Body", {x=0, y=6.3, z=0}, {x=-90, y=180, z=0})
                        self.object:set_bone_position("Head", {x=0, y=6.3, z=0}, {x=90, y=0, z=0})
                        self.object:set_bone_position("Arm_Left", {x=-3, y=6.3, z=1}, {x=0, y=0, z=180 + wing_angle})
                        self.object:set_bone_position("Arm_Right", {x=3, y=6.3, z=1}, {x=0, y=0, z=-180 - wing_angle})
                    else
                        -- Ground mode: Normal standing/walking pose
                        self.object:set_bone_position("Body", {x=0, y=6.3, z=0}, {x=0, y=0, z=0})
                        self.object:set_bone_position("Head", {x=0, y=6.3, z=0}, {x=0, y=0, z=0})
                        self.object:set_bone_position("Arm_Left", {x=-3, y=6.3, z=1}, {x=0, y=0, z=10 + wing_angle})
                        self.object:set_bone_position("Arm_Right", {x=3, y=6.3, z=1}, {x=0, y=0, z=-10 - wing_angle})
                    end
                end

                if target and target:is_player() then
                    local player_pos = target:get_pos()
                    if not player_pos or not pos then
                        return
                    end

                    local self_pos = pos
                    local distance = vector.distance(player_pos, self_pos)

                    if not self.strike_timer then self.strike_timer = 0 end
                    if not self.strike_interval then self.strike_interval = 2.5 end

                    self.strike_timer = self.strike_timer + dtime

                    if distance >= 4 and distance <= 20 and self.strike_timer >= self.strike_interval then
                        if not self.assigned_strikes or #self.assigned_strikes == 0 then
                            minetest.log("error", "[lualore] Valkyrie has no assigned strikes!")
                            self.assigned_strikes = lualore.valkyrie_strikes.assign_random_strikes()
                            self.current_strike = 1
                        end

                        local strike_func = self.assigned_strikes[self.current_strike]
                        if strike_func and type(strike_func) == "function" then
                            minetest.log("action", "[lualore] Attempting strike " .. self.current_strike .. " at distance " .. math.floor(distance))

                            local strike_id = lualore.valkyrie_strikes.get_strike_id(strike_func)
                            local success = lualore.valkyrie_strikes.use_strike(self, strike_func, target)

                            if success then
                                if strike_id then
                                    lualore.valkyrie_strikes.spawn_npc_trail(self, target, strike_id)
                                    lualore.valkyrie_strikes.spawn_player_trail(target, strike_id)
                                end
                                self.current_strike = self.current_strike % #self.assigned_strikes + 1
                                minetest.chat_send_player(target:get_player_name(), S("Valkyrie unleashes a powerful strike!"))
                                minetest.log("action", "[lualore] Valkyrie successfully used strike on " .. target:get_player_name())
                                self.strike_timer = 0
                            else
                                minetest.log("warning", "[lualore] Strike " .. self.current_strike .. " failed - on cooldown or player has effect")
                                self.current_strike = self.current_strike % #self.assigned_strikes + 1
                                strike_func = self.assigned_strikes[self.current_strike]
                                strike_id = lualore.valkyrie_strikes.get_strike_id(strike_func)
                                success = lualore.valkyrie_strikes.use_strike(self, strike_func, target)
                                if success then
                                    if strike_id then
                                        lualore.valkyrie_strikes.spawn_npc_trail(self, target, strike_id)
                                        lualore.valkyrie_strikes.spawn_player_trail(target, strike_id)
                                    end
                                    self.current_strike = self.current_strike % #self.assigned_strikes + 1
                                    minetest.chat_send_player(target:get_player_name(), S("Valkyrie unleashes a powerful strike!"))
                                    minetest.log("action", "[lualore] Valkyrie fallback to strike " .. self.current_strike .. " on " .. target:get_player_name())
                                else
                                    minetest.log("warning", "[lualore] Fallback strike also failed")
                                end
                                self.strike_timer = 0
                            end
                        else
                            minetest.log("error", "[lualore] Strike function is nil or not a function!")
                        end
                    elseif distance < 4 then
                        local dir = vector.direction(player_pos, self_pos)
                        self.object:set_velocity(vector.multiply(dir, 2))
                    elseif distance > 8 and distance <= 20 then
                        local dir = vector.direction(self_pos, player_pos)
                        dir.y = dir.y + 0.2
                        local dash_vel = vector.multiply(dir, 5)
                        self.object:set_velocity(dash_vel)
                    end
                end

                -- Wing tip particles
                if pos and pos.x and pos.y and pos.z then
                    local wing_left = vector.add(pos, {x=-0.5, y=0.8, z=0})
                    local wing_right = vector.add(pos, {x=0.5, y=0.8, z=0})

                    minetest.add_particlespawner({
                        amount = 2,
                        time = 0.1,
                        minpos = vector.subtract(wing_left, {x=0.1, y=0.1, z=0.1}),
                        maxpos = vector.add(wing_left, {x=0.1, y=0.1, z=0.1}),
                        minvel = {x=-1, y=-0.5, z=-0.5},
                        maxvel = {x=-0.5, y=0, z=0.5},
                        minacc = {x=0, y=-0.2, z=0},
                        maxacc = {x=0, y=-0.2, z=0},
                        minexptime = 0.3,
                        maxexptime = 0.8,
                        minsize = 1.5,
                        maxsize = 2.5,
                        texture = "lualore_particle_star.png^[colorize:#FFFFFF:220",
                        glow = 12
                    })

                    minetest.add_particlespawner({
                        amount = 2,
                        time = 0.1,
                        minpos = vector.subtract(wing_right, {x=0.1, y=0.1, z=0.1}),
                        maxpos = vector.add(wing_right, {x=0.1, y=0.1, z=0.1}),
                        minvel = {x=0.5, y=-0.5, z=-0.5},
                        maxvel = {x=1, y=0, z=0.5},
                        minacc = {x=0, y=-0.2, z=0},
                        maxacc = {x=0, y=-0.2, z=0},
                        minexptime = 0.3,
                        maxexptime = 0.8,
                        minsize = 1.5,
                        maxsize = 2.5,
                        texture = "lualore_particle_star.png^[colorize:#FFFFFF:220",
                        glow = 12
                    })
                end
            end)

            if not success then
                minetest.log("error", "[lualore] Valkyrie do_custom error: " .. tostring(err))
            end
        end,
    })

    minetest.log("action", "[lualore] Registered " .. valkyrie_display)
end

-- Chat commands (unchanged)
minetest.register_chatcommand("spawn_valkyrie", {
    params = "<type>",
    description = S("Spawn a Valkyrie (blue, violet, gold, or green)"),
    privs = {give = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, S("Player not found") end

        local valkyrie_type = param:lower()
        local valid_types = {blue = true, violet = true, gold = true, green = true}
        if not valid_types[valkyrie_type] then
            return false, S("Invalid type. Use: blue, violet, gold, or green")
        end

        local pos = player:get_pos()
        local spawn_pos = vector.add(pos, {x=math.random(-3,3), y=1, z=math.random(-3,3)})

        local mob_name = "lualore:" .. valkyrie_type .. "_valkyrie"
        local obj = minetest.add_entity(spawn_pos, mob_name)

        if obj then
            local ent = obj:get_luaentity()
            if ent and ent.assigned_strikes then
                minetest.chat_send_player(name, S("Valkyrie assigned strikes: @1", #ent.assigned_strikes))
            end
            return true, S("Spawned @1 Valkyrie", valkyrie_type)
        end
        return false, S("Failed to spawn Valkyrie")
    end
})

minetest.register_chatcommand("valkyrie_info", {
    params = "",
    description = S("Get info about nearby Valkyries"),
    privs = {give = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, S("Player not found") end

        local pos = player:get_pos()
        local objects = minetest.get_objects_inside_radius(pos, 30)
        local found = false

        for _, obj in ipairs(objects) do
            local ent = obj:get_luaentity()
            if ent and ent.name and ent.name:match("lualore:.*_valkyrie") then
                found = true
                local distance = vector.distance(pos, obj:get_pos())
                local strikes = ent.assigned_strikes and #ent.assigned_strikes or 0
                local current = ent.current_strike or 0
                local timer = ent.strike_timer or 0

                minetest.chat_send_player(name, S("Valkyrie: @1", ent.name))
                minetest.chat_send_player(name, S("  Distance: @1", math.floor(distance)))
                minetest.chat_send_player(name, S("  Strikes: @1", strikes))
                minetest.chat_send_player(name, S("  Current Strike: @1", current))
                minetest.chat_send_player(name, S("  Timer: @1", math.floor(timer * 10) / 10))
            end
        end

        if not found then
            return false, S("No Valkyries nearby")
        end
        return true
    end
})

function lualore.sky_valkyries.spawn_at_fortress(fortress_pos, fortress_hash)
    if spawned_valkyries[fortress_hash] then
        return false
    end

    local valkyrie_types_list = {"blue", "violet", "gold", "green"}
    local chosen_type = valkyrie_types_list[math.random(1, #valkyrie_types_list)]

    local spawn_pos = vector.add(fortress_pos, {x=0, y=2, z=0})
    local mob_name = "lualore:" .. chosen_type .. "_valkyrie"

    local obj = minetest.add_entity(spawn_pos, mob_name)

    if obj then
        spawned_valkyries[fortress_hash] = chosen_type
        storage:set_string("spawned_valkyries", minetest.serialize(spawned_valkyries))
        minetest.log("action", "[lualore] Spawned " .. chosen_type .. " Valkyrie at fortress " .. fortress_hash)
        return true
    end

    return false
end

minetest.log("action", "[lualore] Sky Valkyrie system loaded")
