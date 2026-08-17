local core = core or minetest

airliner = {}

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

function airliner.spawn(pos, owner)
    local obj = core.add_entity(pos, "airliner:airliner")
    if obj then
        local ent = obj:get_luaentity()
        if ent then
            ent.owner = owner
            ent:_save_state()
        end
    end
    return obj
end

function airliner.get_airliner(obj)
    if not obj then return nil end
    local ent = obj:get_luaentity()
    if ent and ent.name == "airliner:airliner" then
        return ent
    end
    return nil
end

function airliner.takeoff(obj)
    local ent = airliner.get_airliner(obj)
    if ent then
        ent:_start_takeoff()
    end
end

function airliner.land(obj)
    local ent = airliner.get_airliner(obj)
    if ent then
        ent:_force_landing()
    end
end

function airliner.add_waypoint(obj, pos)
    local ent = airliner.get_airliner(obj)
    if ent then
        table.insert(ent.waypoints, {x = pos.x, y = pos.y, z = pos.z})
        ent:_save_state()
    end
end

function airliner.clear_waypoints(obj)
    local ent = airliner.get_airliner(obj)
    if ent then
        ent.waypoints = {}
        ent.target_waypoint = nil
        ent:_save_state()
    end
end

function airliner.stop(obj)
    local ent = airliner.get_airliner(obj)
    if ent then
        if ent.state == "cruise" or ent.state == "takeoff" or ent.state == "landing" then
            -- Force a safe stop if flying. Will drop it straight down or land at current pos.
            ent:_force_landing()
        else
            ent.object:set_velocity({x=0, y=0, z=0})
            ent.state = "ground"
            ent:_save_state()
        end
    end
end

function airliner.attach(child, airliner_obj, offset, rotation)
    local ent = airliner.get_airliner(airliner_obj)
    if not ent then return false end
    if child == airliner_obj then return false end -- Prevent attaching to itself

    if ent.state ~= "ground" and ent.state ~= "arrived" then
        if child:is_player() then
            core.chat_send_player(child:get_player_name(), "Cannot board while the airliner is flying.")
        end
        return false
    end

    -- Ensure passengers list exists
    ent.passengers = ent.passengers or {}

    -- Check if already attached
    if ent.pilot == child then return false end
    for _, p in ipairs(ent.passengers) do
        if p == child then return false end
    end

    -- Try to attach as pilot first
    if not ent.pilot then
        ent.pilot = child
        if child:is_player() and not ent.owner then
            ent.owner = child:get_player_name()
        end
        local attach_offset = offset or {x = 0, y = 15, z = 0}
        child:set_attach(airliner_obj, "", {x=attach_offset.x/20, y=attach_offset.y/20, z=attach_offset.z/20}, rotation or {x = 0, y = 0, z = 0})
        child:set_properties({visual_size = {x=1/20, y=1/20, z=1/20}})
        ent:_save_state()
        return true
    end

    -- Try to attach as passenger (max 9 passengers, total 10 players)
    if #ent.passengers < 9 then
        table.insert(ent.passengers, child)
        -- Provide an offset for passengers so they don't overlap with the pilot
        local p_offset = offset or {x = 0, y = 15, z = -10 - (#ent.passengers * 5)}
        child:set_attach(airliner_obj, "", {x=p_offset.x/20, y=p_offset.y/20, z=p_offset.z/20}, rotation or {x = 0, y = 0, z = 0})
        child:set_properties({visual_size = {x=1/20, y=1/20, z=1/20}})
        ent:_save_state()
        return true
    else
        if child:is_player() then
            core.chat_send_player(child:get_player_name(), "The airliner is full (10 players max).")
        end
        return false
    end
end

function airliner.detach(child, force)
    if not child then return end

    local parent = child:get_attach()
    if not parent then return end

    local ent = airliner.get_airliner(parent)
    if ent then
        if not force and (ent.state ~= "ground" and ent.state ~= "arrived") then
            if child:is_player() then
                core.chat_send_player(child:get_player_name(), "Cannot detach while the airliner is flying.")
            end
            return false
        end

        if ent.pilot == child then
            ent.pilot = nil
        end

        if ent.passengers then
            for i, p in ipairs(ent.passengers) do
                if p == child then
                    table.remove(ent.passengers, i)
                    break
                end
            end
        end
    end

    child:set_detach()
    child:set_properties({visual_size = {x=1, y=1, z=1}})
    if ent then ent:_save_state() end
    return true
end

function airliner.get_state(obj)
    local ent = airliner.get_airliner(obj)
    if ent then
        return ent.state
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- Airliner Entity
-- ----------------------------------------------------------------------------

local vec_add = vector.add
local vec_sub = vector.subtract
local vec_mul = vector.multiply
local vec_normalize = vector.normalize
local vec_distance = vector.distance

local CRUISE_SPEED = 30
local CLIMB_SPEED = 10
local CRUISE_ALTITUDE = 100

core.register_entity("airliner:airliner", {
    initial_properties = {
        physical = false,
        collisionbox = {-4 * 20, -2 * 20, -4 * 20, 4 * 20, 4 * 20, 4 * 20},
        selectionbox = {-4 * 20, -2 * 20, -4 * 20, 4 * 20, 4 * 20, 4 * 20},
        visual = "mesh",
        mesh = "airliner.obj",
        textures = {"airliner.png"},
        visual_size = {x = 20, y = 20, z = 20},
        backface_culling = false,
        static_save = true,
        pointable = true,
    },

    state = "ground",
    waypoints = {},
    target_waypoint = nil,
    owner = nil,
    pilot = nil,
    aux1_held = false,

    on_activate = function(self, staticdata)
        self.object:set_armor_groups({immortal = 1})
        self.waypoints = {}
        if staticdata and staticdata ~= "" then
            local data = core.deserialize(staticdata)
            if data then
                self.state = data.state or "ground"
                self.waypoints = data.waypoints or {}
                self.target_waypoint = data.target_waypoint
                self.owner = data.owner
            end
        end
    end,

    get_staticdata = function(self)
        return core.serialize({
            state = self.state,
            waypoints = self.waypoints,
            target_waypoint = self.target_waypoint,
            owner = self.owner
        })
    end,

    _save_state = function(self)
        -- Trigger static save by Minetest
        -- Staticdata is saved automatically when unloaded
    end,

    _start_takeoff = function(self)
        if self.state ~= "ground" and self.state ~= "arrived" then return end

        if #self.waypoints > 0 then
            self.target_waypoint = table.remove(self.waypoints, 1)
        else
            -- Create fallback waypoint 1000 nodes ahead and at CRUISE_ALTITUDE
            local dir = core.yaw_to_dir(self.object:get_yaw() or 0)
            local pos = self.object:get_pos()
            self.target_waypoint = vec_add(pos, vec_add(vec_mul(dir, 1000), {x=0, y=CRUISE_ALTITUDE, z=0}))
        end

        self.state = "takeoff"
        core.log("action", "[Airliner] Commencing takeoff sequence.")
        local f = io.open(core.get_worldpath() .. "/airliner_debug.txt", "a")
        if f then f:write("[Airliner] Commencing takeoff sequence.\n") f:close() end
        self:_save_state()
    end,

    _force_landing = function(self)
        self.object:set_velocity({x = 0, y = -10, z = 0})
        self.state = "landing"
        core.log("action", "[Airliner] Force landing initiated.")
        local f = io.open(core.get_worldpath() .. "/airliner_debug.txt", "a")
        if f then f:write("[Airliner] Force landing initiated.\n") f:close() end
        self.target_waypoint = self.object:get_pos()
        self.target_waypoint.y = self.target_waypoint.y - 100 -- Arbitrary ground target
        self:_save_state()
    end,

    on_step = function(self, dtime)
        if self.state == "ground" or self.state == "arrived" then
            self.object:set_velocity({x=0, y=0, z=0})
            return
        end

        if not self.target_waypoint then
            self.state = "ground"
            return
        end

        local pos = self.object:get_pos()
        local dist = vec_distance(pos, self.target_waypoint)

        if self.state == "descending" then
            -- We are descending to the ground. Check node below collision box.
            -- Collision box goes down to -2 * 20 = -40. Let's check a bit further down, e.g. pos.y - 42.
            local ground_y = pos.y - 42
            local node = core.get_node({x=pos.x, y=ground_y, z=pos.z})
            local nodedef = core.registered_nodes[node.name]

            if nodedef and node.name ~= "air" and node.name ~= "ignore" and (nodedef.walkable or nodedef.liquidtype ~= "none") then
                self.object:set_velocity({x=0, y=0, z=0})
                self.state = "arrived"
                self.target_waypoint = nil
                core.log("action", "[Airliner] Reached ground. Landing complete.")
                local f = io.open(core.get_worldpath() .. "/airliner_debug.txt", "a")
                if f then f:write("[Airliner] Reached ground. Landing complete.\n") f:close() end
                self:_save_state()
            else
                self.object:set_velocity({x=0, y=-CLIMB_SPEED, z=0})
            end
            return
        end

        local h_dist = vec_distance({x=pos.x, y=0, z=pos.z}, {x=self.target_waypoint.x, y=0, z=self.target_waypoint.z})

        if dist < 5 or (self.state == "landing" and h_dist < 5) then
            -- Arrived at waypoint (or close horizontally while landing)
            if #self.waypoints > 0 then
                self.target_waypoint = table.remove(self.waypoints, 1)
                self.state = "takeoff" -- Continue to the next waypoint
                core.log("action", "[Airliner] Reached waypoint, continuing to next waypoint.")
                local f = io.open(core.get_worldpath() .. "/airliner_debug.txt", "a")
                if f then f:write("[Airliner] Reached waypoint, continuing to next waypoint.\n") f:close() end
            else
                -- Stop horizontally, start descending
                self.object:set_velocity({x=0, y=-CLIMB_SPEED, z=0})
                self.object:set_pos({x=self.target_waypoint.x, y=pos.y, z=self.target_waypoint.z})
                self.state = "descending"
                core.log("action", "[Airliner] Reached final destination X/Z. Starting descent.")
                local f = io.open(core.get_worldpath() .. "/airliner_debug.txt", "a")
                if f then f:write("[Airliner] Reached final destination X/Z. Starting descent.\n") f:close() end
            end
            self:_save_state()
            return
        end

        local dir = vec_normalize(vec_sub(self.target_waypoint, pos))
        self.object:set_yaw(core.dir_to_yaw(dir))

        if self.state == "takeoff" then
            if pos.y < CRUISE_ALTITUDE and math.abs(CRUISE_ALTITUDE - pos.y) > 10 then
                -- Climb to CRUISE_ALTITUDE before focusing on reaching the waypoint
                local climb_dir = vec_normalize({x=dir.x, y=1, z=dir.z})
                self.object:set_velocity(vec_mul(climb_dir, CLIMB_SPEED))
            else
                self.state = "cruise"
                core.log("action", "[Airliner] Reached cruising altitude. State: cruise.")
                local f = io.open(core.get_worldpath() .. "/airliner_debug.txt", "a")
                if f then f:write("[Airliner] Reached cruising altitude. State: cruise.\n") f:close() end
            end
        elseif self.state == "cruise" then
            if h_dist < 30 then
                self.state = "landing"
                core.log("action", "[Airliner] Approaching target. State: landing.")
                local f = io.open(core.get_worldpath() .. "/airliner_debug.txt", "a")
                if f then f:write("[Airliner] Approaching target. State: landing.\n") f:close() end
            else
                local vel_dir = vec_normalize({x=dir.x, y=0, z=dir.z})
                self.object:set_velocity(vec_mul(vel_dir, CRUISE_SPEED))
            end
        elseif self.state == "landing" then
            -- Guide it towards the waypoint, both horizontally and vertically
            self.object:set_velocity(vec_mul(dir, CLIMB_SPEED))
        end
    end,
})

-- Hook right-click for attachment
local original_entity = core.registered_entities["airliner:airliner"]
original_entity.on_rightclick = function(self, clicker)
    if not clicker or not clicker:is_player() then return end

    if self.state ~= "ground" and self.state ~= "arrived" then
        core.chat_send_player(clicker:get_player_name(), "Cannot board while the airliner is flying.")
        return
    end

    if self.pilot then
        if self.pilot == clicker then
            airliner.detach(clicker, false)
            return
        end
        -- Allow boarding as passenger if already a pilot
    end

    airliner.attach(clicker, self.object)
end

-- Hook globalstep for AUX1 (E) detection
core.register_globalstep(function(dtime)
    for _, player in pairs(core.get_connected_players()) do
        local parent = player:get_attach()
        if parent then
            local ent = airliner.get_airliner(parent)
            if ent and ent.pilot == player then
                local controls = player:get_player_control()
                if controls and controls.aux1 then
                    if not ent.aux1_held then
                        ent.aux1_held = true

                        -- Initiate takeoff if grounded
                        if ent.state == "ground" or ent.state == "arrived" then
                            ent:_start_takeoff()
                        end
                    end
                else
                    if ent.aux1_held then
                        ent.aux1_held = false
                    end
                end
            end
        end
    end
end)

-- ----------------------------------------------------------------------------
-- Items & Nodes
-- ----------------------------------------------------------------------------

core.register_craftitem("airliner:airliner_spawner", {
    description = "Airliner Spawner",
    inventory_image = "airliner_item.png",
    on_place = function(itemstack, placer, pointed_thing)
        if pointed_thing.type ~= "node" then return itemstack end

        local pos = pointed_thing.above
        if core.is_protected(pos, placer:get_player_name()) then
            core.record_protection_violation(pos, placer:get_player_name())
            return itemstack
        end

        local owner = placer:get_player_name()
        local obj = airliner.spawn(pos, owner)
        if obj then
            local yaw = placer:get_look_horizontal()
            obj:set_yaw(yaw)

            if not core.is_creative_enabled(owner) then
                itemstack:take_item()
            end
        end

        return itemstack
    end,
})

core.register_node("airliner:waypoint_beacon", {
    description = "Airliner Waypoint Beacon",
    tiles = {"airliner_waypoint.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 3},
    after_place_node = function(pos, placer, itemstack, pointed_thing)
        local meta = core.get_meta(pos)
        meta:set_string("owner", placer:get_player_name())
        meta:set_string("infotext", "Waypoint Beacon (Owned by " .. placer:get_player_name() .. ")")
    end,
})

if core.get_modpath("default") then
    core.register_craft({
        output = "airliner:airliner_spawner",
        recipe = {
            {"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"},
            {"default:glass", "default:steel_ingot", "default:glass"},
            {"", "default:steel_ingot", ""}
        }
    })
end


-- ----------------------------------------------------------------------------
-- Commands
-- ----------------------------------------------------------------------------

local function find_owned_airliner(name)
    local player = core.get_player_by_name(name)
    if not player then return nil end

    -- Check if attached
    local parent = player:get_attach()
    if parent then
        local ent = airliner.get_airliner(parent)
        if ent and (ent.owner == name or core.check_player_privs(name, {protection_bypass=true})) then
            return ent
        end
    end

    -- Otherwise, find nearest
    local p_pos = player:get_pos()
    local nearest = nil
    local min_dist = math.huge

    for _, obj in pairs(core.object_refs) do
        local ent = airliner.get_airliner(obj)
        if ent and (ent.owner == name or core.check_player_privs(name, {protection_bypass=true})) then
            local dist = vector.distance(p_pos, obj:get_pos())
            if dist < min_dist then
                min_dist = dist
                nearest = ent
            end
        end
    end

    return nearest
end

core.register_chatcommand("airliner_spawn", {
    description = "Spawns an airliner in front of the player.",
    func = function(name, param)
        local player = core.get_player_by_name(name)
        if not player then return false, "Player not found." end

        local dir = player:get_look_dir()
        local pos = player:get_pos()
        local spawn_pos = vector.add(pos, vector.multiply(dir, 5))
        spawn_pos.y = spawn_pos.y + 1

        if core.is_protected(spawn_pos, name) then
            return false, "Cannot spawn here (protected area)."
        end

        local obj = airliner.spawn(spawn_pos, name)
        if obj then
            obj:set_yaw(player:get_look_horizontal())
            return true, "Airliner spawned."
        end
        return false, "Failed to spawn airliner."
    end
})

core.register_chatcommand("airliner_waypoint", {
    description = "Adds a waypoint to the attached or nearest owned airliner (Usage: x,y,z).",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        local x, y, z = string.match(param, "^([%d.-]+),([%d.-]+),([%d.-]+)$")
        if not x or not y or not z then
            return false, "Invalid format. Use: x,y,z"
        end

        local pos = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
        airliner.add_waypoint(ent.object, pos)
        return true, "Waypoint added."
    end
})

core.register_chatcommand("airliner_waypoint_here", {
    description = "Adds the player's current position as a waypoint.",
    func = function(name, param)
        local player = core.get_player_by_name(name)
        if not player then return false, "Player not found." end

        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        airliner.add_waypoint(ent.object, player:get_pos())
        return true, "Waypoint added at your location."
    end
})

core.register_chatcommand("airliner_clear", {
    description = "Clears all waypoints from the attached or nearest owned airliner.",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        airliner.clear_waypoints(ent.object)
        return true, "Waypoints cleared."
    end
})

core.register_chatcommand("airliner_stop", {
    description = "Stops the airliner safely.",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        airliner.stop(ent.object)
        return true, "Airliner stop command issued."
    end
})

core.register_chatcommand("airliner_remove", {
    description = "Removes the attached or nearest owned airliner.",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        if ent.pilot then
            airliner.detach(ent.pilot, true)
        end

        ent.object:remove()
        return true, "Airliner removed."
    end
})

-- ----------------------------------------------------------------------------
-- Cleanup on player disconnect
-- ----------------------------------------------------------------------------
core.register_on_leaveplayer(function(player)
    local parent = player:get_attach()
    if parent then
        local ent = airliner.get_airliner(parent)
        if ent then
            if ent.pilot == player then
                ent.pilot = nil
            end
            if ent.passengers then
                for i, p in ipairs(ent.passengers) do
                    if p == player then
                        table.remove(ent.passengers, i)
                        break
                    end
                end
            end
            ent:_save_state()
        end
    end
end)