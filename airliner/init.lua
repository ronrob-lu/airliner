local core = core or minetest

airliner = {}

-- ----------------------------------------------------------------------------
-- Mod Storage for Global Beacons
-- ----------------------------------------------------------------------------
local storage = core.get_mod_storage()

local function get_all_beacons()
    local raw = storage:get_string("beacons")
    if raw and raw ~= "" then
        return core.deserialize(raw) or {}
    end
    return {}
end

local function save_all_beacons(beacons)
    storage:set_string("beacons", core.serialize(beacons))
end

local function add_beacon_record(name, pos, owner)
    local beacons = get_all_beacons()
    beacons[name] = {
        name = name,
        x = math.floor(pos.x),
        y = math.floor(pos.y),
        z = math.floor(pos.z),
        owner = owner or ""
    }
    save_all_beacons(beacons)
end

local function remove_beacon_record_by_pos(pos)
    local beacons = get_all_beacons()
    local found = nil
    for k, b in pairs(beacons) do
        if b.x == math.floor(pos.x) and b.y == math.floor(pos.y) and b.z == math.floor(pos.z) then
            found = k
            break
        end
    end
    if found then
        beacons[found] = nil
        save_all_beacons(beacons)
    end
end

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local CRUISE_SPEED      = 50   -- nodes/second horizontal cruise speed (airline speed)
local CLIMB_SPEED       = 15   -- nodes/second vertical climb
local CRUISE_ALT_OFFSET = 100  -- nodes above takeoff/landing for cruising
local MIN_CRUISE_Y      = 120  -- minimum absolute Y altitude for cruising (clear hills/trees)
local WAYPOINT_DIST     = 25   -- horizontal distance to advance intermediate waypoint
local LANDING_ALIGN_DIST = 4   -- horizontal distance to align directly above destination
local DESCEND_SPEED     = 10   -- nodes/second straight descent rate
local IDLE_TIMEOUT      = 300  -- 5 minutes in seconds before auto-return shuttle

-- Global tracking of all active airliners (even across long distances)
airliner.tracked_planes = {}

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

local vec_add       = vector.add
local vec_sub       = vector.subtract
local vec_mul       = vector.multiply
local vec_normalize = vector.normalize
local vec_distance  = vector.distance

--- Find solid ground Y below pos, ignoring leaves and air so we land on actual ground/runway
local function find_ground_y(pos, max_depth)
    max_depth = max_depth or 300
    for dy = 0, max_depth do
        local check = {x = math.floor(pos.x + 0.5), y = math.floor(pos.y - dy), z = math.floor(pos.z + 0.5)}
        local node = core.get_node_or_nil(check)
        if node then
            local def = core.registered_nodes[node.name]
            if def and node.name ~= "air" and node.name ~= "ignore" then
                if def.walkable and not (def.groups and def.groups.leaves) then
                    return check.y + 1
                elseif def.walkable then
                    -- If leaves or other walkable block, still usable if nothing below
                    return check.y + 1
                end
            end
        else
            return nil
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

function airliner.spawn(pos, owner)
    local obj = core.add_entity(pos, "airliner:airliner")
    if obj then
        local ent = obj:get_luaentity()
        if ent then
            ent.owner = owner
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
        return ent:_start_takeoff()
    end
    return false
end

function airliner.land(obj)
    local ent = airliner.get_airliner(obj)
    if ent then
        ent:_force_landing()
    end
end

function airliner.add_waypoint(obj, pos, name)
    local ent = airliner.get_airliner(obj)
    if ent then
        table.insert(ent.waypoints, {
            x = math.floor(pos.x),
            y = math.floor(pos.y),
            z = math.floor(pos.z),
            name = name or ("WP " .. (#ent.waypoints + 1))
        })
        -- Reset route if parked so it rebuilds full_route with new waypoints
        if ent.state == "ground" or ent.state == "arrived" then
            ent.full_route = {}
        end
        return true
    end
    return false
end

function airliner.clear_waypoints(obj)
    local ent = airliner.get_airliner(obj)
    if ent then
        ent.waypoints = {}
        ent.target_waypoint = nil
        ent.full_route = {}
        ent.route_direction = "forward"
        return true
    end
    return false
end

function airliner.stop(obj)
    local ent = airliner.get_airliner(obj)
    if ent then
        if ent.state == "cruise" or ent.state == "takeoff" or ent.state == "landing" or ent.state == "descending" then
            ent:_force_landing()
        else
            ent.state = "ground"
        end
    end
end

function airliner.attach(child, airliner_obj, offset, rotation)
    local ent = airliner.get_airliner(airliner_obj)
    if not ent then return false end
    if not child or not child:is_player() then return false end
    local p_name = child:get_player_name()

    if ent.state ~= "ground" and ent.state ~= "arrived" then
        core.chat_send_player(p_name, "[Airliner] Cannot board while the airliner is flying.")
        return false
    end

    ent.idle_timer = 0
    ent.passenger_names = ent.passenger_names or {}
    ent.passengers = ent.passengers or {}

    -- Already aboard?
    if ent.pilot_name == p_name or ent.passenger_names[p_name] then
        return false
    end

    -- Board as pilot if seat empty
    if not ent.pilot_name or ent.pilot_name == "" then
        ent.pilot_name = p_name
        ent.pilot = child
        if not ent.owner or ent.owner == "" then
            ent.owner = p_name
        end
        local attach_offset = offset or {x = 0, y = 15, z = 0}
        child:set_attach(airliner_obj, "", {x = attach_offset.x / 20, y = attach_offset.y / 20, z = attach_offset.z / 20}, rotation or {x = 0, y = 0, z = 0})
        child:set_properties({visual_size = {x = 1/20, y = 1/20, z = 1/20}})
        core.chat_send_player(p_name, "[Airliner] Boarded as Pilot. Press E (AUX1) to takeoff, or Shift+Right-Click parked airliner to open Flight Computer.")
        return true
    end

    -- Board as passenger (up to 9)
    local p_count = 0
    for _ in pairs(ent.passenger_names) do p_count = p_count + 1 end
    if p_count < 9 then
        ent.passenger_names[p_name] = true
        table.insert(ent.passengers, child)
        local p_offset = offset or {x = 0, y = 15, z = -10 - (p_count * 5)}
        child:set_attach(airliner_obj, "", {x = p_offset.x / 20, y = p_offset.y / 20, z = p_offset.z / 20}, rotation or {x = 0, y = 0, z = 0})
        child:set_properties({visual_size = {x = 1/20, y = 1/20, z = 1/20}})
        core.chat_send_player(p_name, "[Airliner] Boarded as Passenger. Right-click to dismount.")
        return true
    else
        core.chat_send_player(p_name, "[Airliner] The airliner is full (10 players max).")
        return false
    end
end

function airliner.detach(child, force)
    if not child or not child:is_player() then return false end
    local p_name = child:get_player_name()

    local parent = child:get_attach()
    local ent = airliner.get_airliner(parent)
    if not ent then
        for _, obj in pairs(core.object_refs) do
            local e = airliner.get_airliner(obj)
            if e and (e.pilot_name == p_name or (e.passenger_names and e.passenger_names[p_name])) then
                ent = e
                break
            end
        end
    end

    if ent then
        if not force and (ent.state ~= "ground" and ent.state ~= "arrived") then
            core.chat_send_player(p_name, "[Airliner] Cannot detach while the airliner is flying.")
            return false
        end

        if ent.pilot_name == p_name then
            ent.pilot_name = nil
            ent.pilot = nil
        end
        if ent.passenger_names and ent.passenger_names[p_name] then
            ent.passenger_names[p_name] = nil
        end
        if ent.passengers then
            for i = #ent.passengers, 1, -1 do
                if ent.passengers[i] and ent.passengers[i]:is_player() and ent.passengers[i]:get_player_name() == p_name then
                    table.remove(ent.passengers, i)
                end
            end
        end
    end

    child:set_detach()
    child:set_properties({visual_size = {x = 1, y = 1, z = 1}})

    -- Place the player safely on solid ground
    local child_pos = child:get_pos()
    if child_pos then
        local ground_y = find_ground_y(child_pos, 50)
        if ground_y then
            child:set_pos({x = child_pos.x, y = ground_y + 0.5, z = child_pos.z})
        end
    end

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

core.register_entity("airliner:airliner", {
    initial_properties = {
        physical = false,
        collisionbox = {-3, -1.5, -3, 3, 3, 3},
        selectionbox = {-3, -1.5, -3, 3, 3, 3},
        visual = "mesh",
        mesh = "airliner.obj",
        textures = {"airliner.png"},
        visual_size = {x = 20, y = 20, z = 20},
        backface_culling = false,
        static_save = true,
        pointable = true,
        hp_max = 100,
    },

    -- Instance fields
    state           = "ground",
    waypoints       = {},
    target_waypoint = nil,
    owner           = nil,
    pilot           = nil,
    passengers      = {},
    aux1_held       = false,
    takeoff_y       = 0,
    target_cruise_y = 120,
    idle_timer      = 0,
    full_route      = {},
    route_direction = "forward",

    -- -----------------------------------------------------------------------
    -- Lifecycle
    -- -----------------------------------------------------------------------

    on_activate = function(self, staticdata)
        self.object:set_armor_groups({fleshy = 100, cracky = 1, crumbly = 1, snappy = 1, choppy = 1})
        self.waypoints = {}
        self.passengers = {}
        self.full_route = {}
        self.idle_timer = 0
        self.route_direction = "forward"

        if staticdata and staticdata ~= "" then
            local data = core.deserialize(staticdata)
            if data then
                self.state           = data.state or "ground"
                self.waypoints       = data.waypoints or {}
                self.target_waypoint = data.target_waypoint
                self.owner           = data.owner
                self.takeoff_y       = data.takeoff_y or 0
                self.target_cruise_y = data.target_cruise_y or 120
                self.idle_timer      = data.idle_timer or 0
                self.full_route      = data.full_route or {}
                self.route_direction = data.route_direction or "forward"
                self.plane_id        = data.plane_id
            end
        end
    end,

    get_staticdata = function(self)
        return core.serialize({
            state           = self.state,
            waypoints       = self.waypoints,
            target_waypoint = self.target_waypoint,
            owner           = self.owner,
            takeoff_y       = self.takeoff_y,
            target_cruise_y = self.target_cruise_y,
            idle_timer      = self.idle_timer,
            full_route      = self.full_route,
            route_direction = self.route_direction,
            plane_id        = self.plane_id,
        })
    end,

    -- -----------------------------------------------------------------------
    -- Punch → take damage from pickaxes/tools, drop spawner at 0 HP
    -- -----------------------------------------------------------------------

    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
        local hp = self.object:get_hp()
        if puncher and puncher:is_player() then
            local p_name = puncher:get_player_name()
            core.chat_send_player(p_name, "[Airliner] HP: " .. math.max(0, hp) .. " / 100")
        end
        if hp <= 0 then
            if self.pilot then
                airliner.detach(self.pilot, true)
            end
            if self.passengers then
                for i = #self.passengers, 1, -1 do
                    airliner.detach(self.passengers[i], true)
                end
            end
            local drop_pos = self.object:get_pos()
            if puncher and puncher:is_player() then
                local inv = puncher:get_inventory()
                if inv then
                    local leftover = inv:add_item("main", "airliner:airliner_spawner")
                    if not leftover:is_empty() then
                        core.add_item(drop_pos, leftover)
                    end
                end
            else
                core.add_item(drop_pos, "airliner:airliner_spawner")
            end
            if self.plane_id then
                airliner.tracked_planes[self.plane_id] = nil
            end
            self.object:remove()
        end
    end,

    -- -----------------------------------------------------------------------
    -- Internal: takeoff / landing
    -- -----------------------------------------------------------------------

    _start_takeoff = function(self)
        if self.state ~= "ground" and self.state ~= "arrived" then return false end

        local pos = self.object:get_pos()
        self.takeoff_y = pos.y

        -- If no waypoints exist, auto-check placed beacons in the world
        if #self.waypoints == 0 and #self.full_route == 0 then
            local beacons = get_all_beacons()
            local beacon_list = {}
            for _, b in pairs(beacons) do
                -- Exclude beacon at current position
                local d = vector.distance(pos, {x = b.x, y = b.y, z = b.z})
                if d > 20 then
                    table.insert(beacon_list, b)
                end
            end
            if #beacon_list > 0 then
                -- Sort by distance from current pos
                table.sort(beacon_list, function(a, b)
                    return vector.distance(pos, {x = a.x, y = a.y, z = a.z}) < vector.distance(pos, {x = b.x, y = b.y, z = b.z})
                end)
                for _, b in ipairs(beacon_list) do
                    table.insert(self.waypoints, {x = b.x, y = b.y, z = b.z, name = b.name})
                end
                core.log("action", "[Airliner] Auto-loaded " .. #self.waypoints .. " beacon(s) into route.")
                if self.pilot and self.pilot:is_player() then
                    core.chat_send_player(self.pilot:get_player_name(), "[Airliner] Loaded " .. #self.waypoints .. " beacon destination(s) into flight plan.")
                end
            end
        end

        -- If STILL no waypoints, warn and do NOT take off into random wilderness!
        if #self.waypoints == 0 and #self.full_route == 0 then
            if self.pilot and self.pilot:is_player() then
                core.chat_send_player(self.pilot:get_player_name(), "[Airliner] No destination set! Place a Waypoint Beacon or use /airliner_waypoint x,y,z or Shift+Right-Click to open Flight Computer.")
            end
            return false
        end

        -- Capture full_route on the first departure
        if #self.waypoints > 0 and #self.full_route == 0 then
            self.full_route = {}
            table.insert(self.full_route, {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z), name = "Origin (Airport A)"})
            for _, wp in ipairs(self.waypoints) do
                table.insert(self.full_route, {x = wp.x, y = wp.y, z = wp.z, name = wp.name})
            end
            self.route_direction = "forward"
        end

        if #self.waypoints > 0 then
            self.target_waypoint = table.remove(self.waypoints, 1)
        end

        -- Compute safe cruising altitude
        local target_y = (self.target_waypoint and self.target_waypoint.y) or pos.y
        local max_y = math.max(pos.y, target_y)
        self.target_cruise_y = math.max(MIN_CRUISE_Y, max_y + CRUISE_ALT_OFFSET)

        self.state = "takeoff"
        self.idle_timer = 0
        local dest_name = (self.target_waypoint and (self.target_waypoint.name or "(" .. self.target_waypoint.x .. "," .. self.target_waypoint.z .. ")")) or "Unknown"
        core.log("action", "[Airliner] Takeoff initiated towards " .. dest_name .. " (Cruise Alt: " .. self.target_cruise_y .. ")")
        if self.pilot and self.pilot:is_player() then
            core.chat_send_player(self.pilot:get_player_name(), "[Airliner] Takeoff! Flying to " .. dest_name .. " at altitude Y=" .. self.target_cruise_y .. ".")
        end
        return true
    end,

    _force_landing = function(self)
        self.state = "descending"
        self.target_waypoint = nil
        core.log("action", "[Airliner] Force landing initiated.")
    end,

    _has_players = function(self)
        if self.pilot_name and self.pilot_name ~= "" then
            local p = core.get_player_by_name(self.pilot_name)
            if p and p:get_pos() then return true end
            self.pilot_name = nil
            self.pilot = nil
        end
        if self.passenger_names then
            local has_p = false
            for pname, _ in pairs(self.passenger_names) do
                local p = core.get_player_by_name(pname)
                if p and p:get_pos() then
                    has_p = true
                else
                    self.passenger_names[pname] = nil
                end
            end
            if has_p then return true end
        end
        return false
    end,

    -- -----------------------------------------------------------------------
    -- Auto-return shuttle: reverses route after 5 minutes idle
    -- -----------------------------------------------------------------------

    _auto_return = function(self)
        if #self.full_route < 2 then return end

        local pos = self.object:get_pos()
        self.takeoff_y = pos.y

        if self.route_direction == "forward" then
            self.route_direction = "reverse"
            self.waypoints = {}
            for i = #self.full_route - 1, 1, -1 do
                table.insert(self.waypoints, {
                    x = self.full_route[i].x,
                    y = self.full_route[i].y,
                    z = self.full_route[i].z,
                    name = self.full_route[i].name,
                })
            end
        else
            self.route_direction = "forward"
            self.waypoints = {}
            for i = 2, #self.full_route do
                table.insert(self.waypoints, {
                    x = self.full_route[i].x,
                    y = self.full_route[i].y,
                    z = self.full_route[i].z,
                    name = self.full_route[i].name,
                })
            end
        end

        if #self.waypoints > 0 then
            self.target_waypoint = table.remove(self.waypoints, 1)
            local target_y = self.target_waypoint.y or pos.y
            self.target_cruise_y = math.max(MIN_CRUISE_Y, math.max(pos.y, target_y) + CRUISE_ALT_OFFSET)
            self.state = "takeoff"
            self.idle_timer = 0
            local dest_name = self.target_waypoint.name or "(" .. self.target_waypoint.x .. "," .. self.target_waypoint.z .. ")"
            core.log("action", "[Airliner] Auto-return shuttle: taking off (" .. self.route_direction .. ") towards " .. dest_name)
        end
    end,

    -- -----------------------------------------------------------------------
    -- on_step: High-precision long-distance airline flight
    -- -----------------------------------------------------------------------

    on_step = function(self, dtime)
        if dtime > 0.5 then dtime = 0.5 end
        local pos = self.object:get_pos()
        if pos then
            if not self.plane_id or self.plane_id == "" then
                self.plane_id = "plane_" .. tostring(math.random(1000000, 9999999))
            end
            local t = airliner.tracked_planes[self.plane_id] or {}
            t.id = self.plane_id
            t.object = self.object
            t.owner = self.owner
            t.state = self.state
            t.pos = {x = pos.x, y = pos.y, z = pos.z}
            t.waypoints = self.waypoints
            t.full_route = self.full_route
            t.target_waypoint = self.target_waypoint
            t.route_direction = self.route_direction
            t.idle_timer = self.idle_timer
            t.target_cruise_y = self.target_cruise_y
            t.pilot_name = self.pilot_name
            t.passenger_names = self.passenger_names
            airliner.tracked_planes[self.plane_id] = t
        end

        -- ===== GROUND / ARRIVED =====
        if self.state == "ground" or self.state == "arrived" then
            if not self:_has_players() and #self.full_route >= 2 then
                self.idle_timer = self.idle_timer + dtime
                if self.idle_timer >= IDLE_TIMEOUT then
                    self:_auto_return()
                end
            else
                self.idle_timer = 0
            end
            return
        end

        -- ===== DESCENDING STRAIGHT DOWN ONTO TARGET =====
        if self.state == "descending" then
            local pos = self.object:get_pos()
            local target = self.target_waypoint

            -- Maintain exact horizontal alignment on target while descending
            local align_x = (target and target.x) or pos.x
            local align_z = (target and target.z) or pos.z

            local move_y = -DESCEND_SPEED * dtime
            local next_y = pos.y + move_y

            -- Find ground below current horizontal position
            local ground_y = find_ground_y({x = align_x, y = pos.y, z = align_z}, 300)
            local target_land_y = (target and target.y)

            -- Land when reaching ground level or target Y
            local final_ground = ground_y or target_land_y
            if final_ground and next_y <= final_ground + 1.0 then
                self.object:set_pos({x = align_x, y = final_ground + 0.5, z = align_z})
                self.state = "arrived"
                self.target_waypoint = nil
                self.idle_timer = 0
                if self.forceloaded_pos then
                    core.forceload_free_block(self.forceloaded_pos, true)
                    self.forceloaded_pos = nil
                end
                core.log("action", "[Airliner] Touched down at (" .. math.floor(align_x) .. ", " .. math.floor(final_ground) .. ", " .. math.floor(align_z) .. "). Landing complete.")
                if self.pilot_name and self.pilot_name ~= "" then
                    core.chat_send_player(self.pilot_name, "[Airliner] Landed safely at destination. Right-click to dismount.")
                end
            else
                self.object:set_pos({x = align_x, y = next_y, z = align_z})
            end
            return
        end

        -- ===== FLYING STATES =====
        if not self.target_waypoint then
            self.state = "ground"
            return
        end

        local pos = self.object:get_pos()
        local target = self.target_waypoint
        local cruise_y = self.target_cruise_y or (self.takeoff_y + CRUISE_ALT_OFFSET)

        -- Keep the current mapblock forceloaded so autonomous flight never unloads
        local mb_pos = {
            x = math.floor(pos.x / 16) * 16,
            y = math.floor(pos.y / 16) * 16,
            z = math.floor(pos.z / 16) * 16,
        }
        if not self.forceloaded_pos or self.forceloaded_pos.x ~= mb_pos.x or self.forceloaded_pos.z ~= mb_pos.z or self.forceloaded_pos.y ~= mb_pos.y then
            if self.forceloaded_pos then
                core.forceload_free_block(self.forceloaded_pos, true)
            end
            core.forceload_block(mb_pos, true)
            self.forceloaded_pos = mb_pos
        end

        local dx = target.x - pos.x
        local dz = target.z - pos.z
        local h_dist = math.sqrt(dx * dx + dz * dz)

        local h_dir
        if h_dist > 0.01 then
            h_dir = {x = dx / h_dist, y = 0, z = dz / h_dist}
        else
            h_dir = {x = 0, y = 0, z = 0}
        end

        -- Rotate aircraft towards flight direction
        if h_dist > 1 then
            self.object:set_yaw(math.atan2(-h_dir.x, h_dir.z))
        end

        -- ----- TAKEOFF: Climb to cruise altitude -----
        if self.state == "takeoff" then
            local alt_diff = cruise_y - pos.y
            if alt_diff > 1.5 then
                local fwd_speed = CRUISE_SPEED * 0.4
                local step_x = pos.x + h_dir.x * fwd_speed * dtime
                local step_y = pos.y + CLIMB_SPEED * dtime
                local step_z = pos.z + h_dir.z * fwd_speed * dtime
                self.object:set_pos({x = step_x, y = step_y, z = step_z})
            else
                self.state = "cruise"
                self.object:set_pos({x = pos.x, y = cruise_y, z = pos.z})
                core.log("action", "[Airliner] Reached cruise altitude (" .. math.floor(cruise_y) .. "m). Cruising at " .. CRUISE_SPEED .. "m/s.")
            end
            return
        end

        -- ----- CRUISE: Fly horizontally towards target -----
        if self.state == "cruise" then
            -- Are we close to the waypoint horizontally?
            if h_dist < WAYPOINT_DIST then
                if #self.waypoints > 0 then
                    -- Transition smoothly to next waypoint without losing altitude
                    local next_wp = table.remove(self.waypoints, 1)
                    self.target_waypoint = next_wp
                    local next_name = next_wp.name or ("WP (" .. next_wp.x .. "," .. next_wp.z .. ")")
                    core.log("action", "[Airliner] Reached intermediate waypoint. Next: " .. next_name)
                    if self.pilot and self.pilot:is_player() then
                        core.chat_send_player(self.pilot:get_player_name(), "[Airliner] Waypoint reached. Next stop: " .. next_name)
                    end
                else
                    -- Final destination: switch to landing approach
                    self.state = "landing"
                    core.log("action", "[Airliner] Approaching final destination (" .. math.floor(target.x) .. "," .. math.floor(target.z) .. "). Preparing descent.")
                end
            else
                -- Fly at cruise altitude directly toward destination
                local step_x = pos.x + h_dir.x * CRUISE_SPEED * dtime
                local step_z = pos.z + h_dir.z * CRUISE_SPEED * dtime
                self.object:set_pos({x = step_x, y = cruise_y, z = step_z})
            end
            return
        end

        -- ----- LANDING: Align directly above destination then descend -----
        if self.state == "landing" then
            if h_dist <= LANDING_ALIGN_DIST then
                -- Precisely aligned above destination! Begin vertical descent onto waypoint
                self.object:set_pos({x = target.x, y = pos.y, z = target.z})
                self.state = "descending"
                core.log("action", "[Airliner] Directly over destination runway/beacon. Descending vertically.")
            else
                -- Slow down and fly directly to exact target X/Z
                local approach_speed = math.max(8, math.min(CRUISE_SPEED * 0.5, h_dist * 2))
                local move_step = approach_speed * dtime
                if move_step >= h_dist then
                    self.object:set_pos({x = target.x, y = pos.y, z = target.z})
                    self.state = "descending"
                else
                    self.object:set_pos({
                        x = pos.x + h_dir.x * move_step,
                        y = pos.y,
                        z = pos.z + h_dir.z * move_step,
                    })
                end
            end
            return
        end
    end,
})

-- ----------------------------------------------------------------------------
-- Flight Computer GUI (Formspec)
-- ----------------------------------------------------------------------------

local function show_flight_computer(player, ent)
    local p_name = player:get_player_name()
    local beacons = get_all_beacons()
    local beacon_keys = {}
    for k, _ in pairs(beacons) do
        table.insert(beacon_keys, k)
    end
    table.sort(beacon_keys)

    local beacon_dropdown = ""
    for i, k in ipairs(beacon_keys) do
        local b = beacons[k]
        local entry = b.name .. " (" .. b.x .. "," .. b.y .. "," .. b.z .. ")"
        if i == 1 then
            beacon_dropdown = entry
        else
            beacon_dropdown = beacon_dropdown .. "," .. entry
        end
    end

    local wp_text = "Flight Plan (Waypoints):\n"
    if #ent.waypoints == 0 then
        wp_text = wp_text .. "  [No waypoints queued. Airliner will auto-detect beacons.]"
    else
        for i, wp in ipairs(ent.waypoints) do
            local wname = wp.name or ("Waypoint #" .. i)
            wp_text = wp_text .. "  " .. i .. ". " .. wname .. " -> (" .. wp.x .. ", " .. wp.y .. ", " .. wp.z .. ")\n"
        end
    end

    local status_line = "Status: " .. ent.state:upper()
    if #ent.full_route >= 2 then
        status_line = status_line .. " | Shuttle Route: " .. #ent.full_route .. " stops (" .. ent.route_direction .. ")"
    end

    local formspec = "size[9,9]" ..
        "label[0.3,0.3;=== AIRLINER FLIGHT COMPUTER ===]" ..
        "textarea[0.3,0.9;8.6,3.2;flight_plan;;" .. core.formspec_escape(wp_text) .. "]" ..
        "label[0.3,4.3;" .. core.formspec_escape(status_line) .. "]" ..
        "label[0.3,4.8;Add Destination Beacon:]" ..
        "dropdown[0.3,5.3;6.5;selected_beacon;" .. beacon_dropdown .. ";1]" ..
        "button[7.0,5.25;1.8,0.8;btn_add_beacon;Add]" ..
        "field[0.3,6.6;4.5,0.8;coord_input;Or Add Coordinate (X,Y,Z);]" ..
        "button[5.0,6.4;1.8,0.8;btn_add_coord;Add Coord]" ..
        "button[7.0,6.4;1.8,0.8;btn_clear;Clear Route]" ..
        "button[0.3,7.6;4.0,1.0;btn_takeoff;>>> TAKEOFF / LAUNCH <<<]" ..
        "button[4.7,7.6;4.0,1.0;btn_board;Board as Pilot]"

    core.show_formspec(p_name, "airliner:flight_computer", formspec)
end

core.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "airliner:flight_computer" then return end
    local p_name = player:get_player_name()

    -- Find nearest airliner
    local ent = nil
    local p_pos = player:get_pos()
    local min_d = 20
    for _, obj in pairs(core.object_refs) do
        local e = airliner.get_airliner(obj)
        if e then
            local d = vector.distance(p_pos, obj:get_pos())
            if d < min_d then
                min_d = d
                ent = e
            end
        end
    end

    if not ent then
        core.chat_send_player(p_name, "[Airliner] No nearby airliner found.")
        return
    end

    if fields.btn_add_beacon and fields.selected_beacon then
        local beacons = get_all_beacons()
        local b_name = string.match(fields.selected_beacon, "^(.-)%s%(")
        if b_name and beacons[b_name] then
            local b = beacons[b_name]
            airliner.add_waypoint(ent.object, {x = b.x, y = b.y, z = b.z}, b.name)
            core.chat_send_player(p_name, "[Airliner] Added beacon destination: " .. b.name .. " (" .. b.x .. "," .. b.y .. "," .. b.z .. ")")
            show_flight_computer(player, ent)
        end
    elseif fields.btn_add_coord and fields.coord_input and fields.coord_input ~= "" then
        local x, y, z = string.match(fields.coord_input, "^([%d.-]+),([%d.-]+),([%d.-]+)$")
        if x and y and z then
            local pos = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
            airliner.add_waypoint(ent.object, pos, "Coord (" .. pos.x .. "," .. pos.z .. ")")
            core.chat_send_player(p_name, "[Airliner] Added coordinate waypoint: (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")")
            show_flight_computer(player, ent)
        else
            core.chat_send_player(p_name, "[Airliner] Invalid format. Please use: X,Y,Z")
        end
    elseif fields.btn_clear then
        airliner.clear_waypoints(ent.object)
        core.chat_send_player(p_name, "[Airliner] Waypoints and shuttle route cleared.")
        show_flight_computer(player, ent)
    elseif fields.btn_takeoff then
        core.close_formspec(p_name, "airliner:flight_computer")
        ent:_start_takeoff()
    elseif fields.btn_board then
        core.close_formspec(p_name, "airliner:flight_computer")
        airliner.attach(player, ent.object)
    end
end)

-- ----------------------------------------------------------------------------
-- Right-click handler for boarding & flight computer
-- ----------------------------------------------------------------------------

local original_entity = core.registered_entities["airliner:airliner"]
original_entity.on_rightclick = function(self, clicker)
    if not clicker or not clicker:is_player() then return end

    local ctrl = clicker:get_player_control()
    -- Shift+Right-Click: Open Flight Computer GUI
    if ctrl and ctrl.sneak then
        show_flight_computer(clicker, self)
        return
    end

    local p_name = clicker:get_player_name()

    if self.state ~= "ground" and self.state ~= "arrived" then
        core.chat_send_player(p_name, "[Airliner] Cannot board while the airliner is flying.")
        return
    end

    -- If this player is already aboard (as pilot or passenger), detach them!
    if self.pilot_name == p_name or (self.passenger_names and self.passenger_names[p_name]) or (self.pilot and self.pilot == clicker) then
        airliner.detach(clicker, false)
        return
    end

    airliner.attach(clicker, self.object)
end

-- ----------------------------------------------------------------------------
-- Globalstep: Pilot Input & Autonomous Flight Simulator
-- ----------------------------------------------------------------------------

core.register_globalstep(function(dtime)
    if dtime > 0.5 then dtime = 0.5 end

    -- 1. Pilot AUX1 key detection
    for _, player in pairs(core.get_connected_players()) do
        local parent = player:get_attach()
        if parent then
            local ent = airliner.get_airliner(parent)
            local p_name = player:get_player_name()
            if ent and (ent.pilot_name == p_name or ent.pilot == player) then
                local controls = player:get_player_control()
                if controls and controls.aux1 then
                    if not ent.aux1_held then
                        ent.aux1_held = true
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

    -- 2. Autonomous Flight Simulator for unmanned / remote planes
    for plane_id, plane in pairs(airliner.tracked_planes) do
        local has_players = false
        if plane.pilot_name and plane.pilot_name ~= "" then has_players = true end
        if plane.passenger_names and next(plane.passenger_names) ~= nil then has_players = true end

        -- If plane is flying unmanned (no players inside)
        if not has_players and plane.target_waypoint and (plane.state == "takeoff" or plane.state == "cruise" or plane.state == "landing" or plane.state == "descending") then
            local pos = plane.pos
            local target = plane.target_waypoint
            local cruise_y = plane.target_cruise_y or 120

            local dx = target.x - pos.x
            local dz = target.z - pos.z
            local h_dist = math.sqrt(dx * dx + dz * dz)

            local h_dir
            if h_dist > 0.01 then
                h_dir = {x = dx / h_dist, y = 0, z = dz / h_dist}
            else
                h_dir = {x = 0, y = 0, z = 0}
            end

            -- Update simulated position
            if plane.state == "takeoff" then
                local alt_diff = cruise_y - pos.y
                if alt_diff > 1.5 then
                    local fwd_speed = CRUISE_SPEED * 0.4
                    pos.x = pos.x + h_dir.x * fwd_speed * dtime
                    pos.y = pos.y + CLIMB_SPEED * dtime
                    pos.z = pos.z + h_dir.z * fwd_speed * dtime
                else
                    pos.y = cruise_y
                    plane.state = "cruise"
                end
            elseif plane.state == "cruise" then
                if h_dist < WAYPOINT_DIST then
                    if plane.waypoints and #plane.waypoints > 0 then
                        plane.target_waypoint = table.remove(plane.waypoints, 1)
                    else
                        plane.state = "landing"
                    end
                else
                    pos.x = pos.x + h_dir.x * CRUISE_SPEED * dtime
                    pos.y = cruise_y
                    pos.z = pos.z + h_dir.z * CRUISE_SPEED * dtime
                end
            elseif plane.state == "landing" then
                if h_dist <= LANDING_ALIGN_DIST then
                    pos.x = target.x
                    pos.z = target.z
                    plane.state = "descending"
                else
                    local approach_speed = math.max(8, math.min(CRUISE_SPEED * 0.5, h_dist * 2))
                    local move_step = approach_speed * dtime
                    if move_step >= h_dist then
                        pos.x = target.x
                        pos.z = target.z
                        plane.state = "descending"
                    else
                        pos.x = pos.x + h_dir.x * move_step
                        pos.z = pos.z + h_dir.z * move_step
                    end
                end
            elseif plane.state == "descending" then
                local target_y = target.y or 10
                local next_y = pos.y - DESCEND_SPEED * dtime
                if next_y <= target_y + 1.0 then
                    pos.x = target.x
                    pos.y = target_y + 0.5
                    pos.z = target.z
                    plane.state = "arrived"
                    plane.target_waypoint = nil
                    plane.idle_timer = 0
                    core.log("action", "[Airliner] Global flight manager: Autonomous touchdown at (" .. math.floor(pos.x) .. "," .. math.floor(pos.y) .. "," .. math.floor(pos.z) .. ").")
                else
                    pos.y = next_y
                end
            end

            plane.pos = pos

            -- If the entity object is active in memory, update its position and rotation
            if plane.object and plane.object.get_pos and plane.object:get_pos() then
                plane.object:set_pos(pos)
                if h_dist > 1 then
                    plane.object:set_yaw(math.atan2(-h_dir.x, h_dir.z))
                end
            end
        end

        -- If plane is arrived and idle, tick the idle_timer in globalstep
        if not has_players and (plane.state == "arrived" or plane.state == "ground") and plane.full_route and #plane.full_route >= 2 then
            plane.idle_timer = (plane.idle_timer or 0) + dtime
            if plane.idle_timer >= IDLE_TIMEOUT then
                -- Launch auto return in globalstep
                plane.idle_timer = 0
                if plane.route_direction == "forward" then
                    plane.route_direction = "reverse"
                    plane.waypoints = {}
                    for i = #plane.full_route - 1, 1, -1 do
                        table.insert(plane.waypoints, {
                            x = plane.full_route[i].x,
                            y = plane.full_route[i].y,
                            z = plane.full_route[i].z,
                            name = plane.full_route[i].name,
                        })
                    end
                else
                    plane.route_direction = "forward"
                    plane.waypoints = {}
                    for i = 2, #plane.full_route do
                        table.insert(plane.waypoints, {
                            x = plane.full_route[i].x,
                            y = plane.full_route[i].y,
                            z = plane.full_route[i].z,
                            name = plane.full_route[i].name,
                        })
                    end
                end
                if #plane.waypoints > 0 then
                    plane.target_waypoint = table.remove(plane.waypoints, 1)
                    local target_y = plane.target_waypoint.y or plane.pos.y
                    plane.target_cruise_y = math.max(MIN_CRUISE_Y, math.max(plane.pos.y, target_y) + CRUISE_ALT_OFFSET)
                    plane.state = "takeoff"
                    core.log("action", "[Airliner] Global flight manager: Autonomous shuttle departing (" .. plane.route_direction .. ")")
                end
            end
        end

        -- 3. Proximity Spawner: Ensure 3D airliner entity appears when a player is within range
        local plane_has_obj = plane.object and plane.object.get_pos and (plane.object:get_pos() ~= nil)
        if not plane_has_obj and plane.pos then
            local should_spawn = false
            for _, player in pairs(core.get_connected_players()) do
                local p_pos = player:get_pos()
                if p_pos then
                    local dist = vec_distance(p_pos, plane.pos)
                    if dist < 120 then
                        should_spawn = true
                        break
                    end
                end
            end
            if should_spawn then
                local obj = core.add_entity(plane.pos, "airliner:airliner")
                if obj then
                    local ent = obj:get_luaentity()
                    if ent then
                        ent.state = plane.state
                        ent.owner = plane.owner
                        ent.waypoints = plane.waypoints or {}
                        ent.full_route = plane.full_route or {}
                        ent.target_waypoint = plane.target_waypoint
                        ent.route_direction = plane.route_direction or "forward"
                        ent.target_cruise_y = plane.target_cruise_y
                        ent.idle_timer = plane.idle_timer or 0
                        ent.plane_id = plane_id
                        plane.object = obj
                        core.log("action", "[Airliner] Rendered 3D airliner for player near (" .. math.floor(plane.pos.x) .. "," .. math.floor(plane.pos.y) .. "," .. math.floor(plane.pos.z) .. ").")
                    end
                end
            end
        end
    end
end)

-- ----------------------------------------------------------------------------
-- Waypoint Beacon Node with Auto-Registration
-- ----------------------------------------------------------------------------

core.register_node("airliner:waypoint_beacon", {
    description = "Airliner Waypoint Beacon (Airport / Runway Destination)",
    tiles = {"airliner_waypoint.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 3},
    
    after_place_node = function(pos, placer, itemstack, pointed_thing)
        local p_name = placer:get_player_name()
        local beacons = get_all_beacons()
        local count = 0
        for _ in pairs(beacons) do count = count + 1 end
        local default_name = "Airport #" .. (count + 1)
        
        local meta = core.get_meta(pos)
        meta:set_string("owner", p_name)
        meta:set_string("beacon_name", default_name)
        meta:set_string("infotext", "Waypoint Beacon: " .. default_name .. " at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")\nRight-click to configure.")
        
        add_beacon_record(default_name, pos, p_name)
        core.chat_send_player(p_name, "[Airliner] Waypoint Beacon placed: '" .. default_name .. "' at (" .. pos.x .. ", " .. pos.y .. ", " .. pos.z .. "). Airliners will auto-navigate here!")
    end,

    on_destruct = function(pos)
        remove_beacon_record_by_pos(pos)
    end,

    on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
        if not clicker or not clicker:is_player() then return end
        local p_name = clicker:get_player_name()
        local meta = core.get_meta(pos)
        local b_name = meta:get_string("beacon_name") or "Airport"
        
        local formspec = "size[6,4]" ..
            "label[0.3,0.3;=== WAYPOINT BEACON CONFIG ===]" ..
            "field[0.5,1.5;5.2,0.8;beacon_name;Beacon Name:;" .. core.formspec_escape(b_name) .. "]" ..
            "button_exit[0.5,2.6;5.0,0.9;btn_save;Save Beacon Name]"
            
        core.show_formspec(p_name, "airliner:beacon_config_" .. pos.x .. "_" .. pos.y .. "_" .. pos.z, formspec)
    end,
})

core.register_on_player_receive_fields(function(player, formname, fields)
    local x, y, z = string.match(formname, "^airliner:beacon_config_([%d-]+)_([%d-]+)_([%d-]+)$")
    if x and y and z and fields.btn_save and fields.beacon_name and fields.beacon_name ~= "" then
        local pos = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
        local new_name = fields.beacon_name
        local p_name = player:get_player_name()
        
        remove_beacon_record_by_pos(pos)
        add_beacon_record(new_name, pos, p_name)
        
        local meta = core.get_meta(pos)
        meta:set_string("beacon_name", new_name)
        meta:set_string("infotext", "Waypoint Beacon: " .. new_name .. " at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")")
        core.chat_send_player(p_name, "[Airliner] Beacon renamed to: '" .. new_name .. "'.")
    end
end)

-- ----------------------------------------------------------------------------
-- Items & Crafting
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
            core.chat_send_player(owner, "[Airliner] Airliner spawned! Right-click to board, or Shift+Right-Click to open Flight Computer.")
        end

        return itemstack
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
    core.register_craft({
        output = "airliner:waypoint_beacon",
        recipe = {
            {"default:steel_ingot", "default:glass", "default:steel_ingot"},
            {"default:glass", "default:torch", "default:glass"},
            {"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"}
        }
    })
end

-- ----------------------------------------------------------------------------
-- Commands
-- ----------------------------------------------------------------------------

local function find_owned_airliner(name)
    local player = core.get_player_by_name(name)
    if not player then return nil end

    local parent = player:get_attach()
    if parent then
        local ent = airliner.get_airliner(parent)
        if ent then return ent end
    end

    local p_pos = player:get_pos()
    local nearest = nil
    local min_dist = math.huge

    -- 1. Check all active in-memory object_refs
    for _, obj in pairs(core.object_refs) do
        local ent = airliner.get_airliner(obj)
        if ent then
            local is_owner = (ent.owner == name or ent.owner == nil or ent.owner == "" or core.check_player_privs(name, {protection_bypass = true}))
            if is_owner then
                local dist = vector.distance(p_pos, obj:get_pos())
                if dist < min_dist then
                    min_dist = dist
                    nearest = ent
                end
            end
        end
    end

    if nearest then return nearest end

    -- 2. If plane has flown far away, query the global tracker!
    for _, plane_info in pairs(airliner.tracked_planes) do
        local is_owner = (plane_info.owner == name or plane_info.owner == nil or plane_info.owner == "" or core.check_player_privs(name, {protection_bypass = true}))
        if is_owner then
            return plane_info
        end
    end

    -- 3. Fallback to any tracked plane in singleplayer
    for _, plane_info in pairs(airliner.tracked_planes) do
        return plane_info
    end

    return nil
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
            return false, "Invalid format. Use: /airliner_waypoint x,y,z"
        end

        local pos = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
        airliner.add_waypoint(ent.object, pos, "WP (" .. pos.x .. "," .. pos.z .. ")")
        return true, "Waypoint added at (" .. pos.x .. ", " .. pos.y .. ", " .. pos.z .. ")."
    end
})

core.register_chatcommand("airliner_waypoint_here", {
    description = "Adds the player's current position as a waypoint.",
    func = function(name, param)
        local player = core.get_player_by_name(name)
        if not player then return false, "Player not found." end

        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        local p_pos = player:get_pos()
        airliner.add_waypoint(ent.object, p_pos, "Player Location")
        return true, "Waypoint added at your location (" .. math.floor(p_pos.x) .. "," .. math.floor(p_pos.y) .. "," .. math.floor(p_pos.z) .. ")."
    end
})

core.register_chatcommand("airliner_beacon", {
    description = "Adds a named Beacon as a waypoint destination (Usage: /airliner_beacon <name>).",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end
        local beacons = get_all_beacons()
        local b = beacons[param]
        if not b then
            return false, "Beacon '" .. param .. "' not found. Use /airliner_beacons to list."
        end
        airliner.add_waypoint(ent.object, {x = b.x, y = b.y, z = b.z}, b.name)
        return true, "Added destination: " .. b.name .. " (" .. b.x .. "," .. b.y .. "," .. b.z .. ")"
    end
})

core.register_lbm({
    name = "airliner:beacon_registration",
    nodenames = {"airliner:waypoint_beacon"},
    run_at_every_load = true,
    action = function(pos, node)
        local meta = core.get_meta(pos)
        local p_name = meta:get_string("owner") or ""
        local b_name = meta:get_string("beacon_name")
        if not b_name or b_name == "" then
            b_name = "Airport (" .. pos.x .. "," .. pos.z .. ")"
            meta:set_string("beacon_name", b_name)
        end
        add_beacon_record(b_name, pos, p_name)
    end,
})

core.register_chatcommand("airliner_beacons", {
    description = "Lists all registered Waypoint Beacons in the world with coordinates and distance.",
    func = function(name, param)
        local player = core.get_player_by_name(name)
        local p_pos = player and player:get_pos()
        local beacons = get_all_beacons()
        local count = 0
        local msg = "=== Registered Waypoint Beacons ===\n"
        for k, b in pairs(beacons) do
            count = count + 1
            local dist_str = ""
            if p_pos then
                local d = math.floor(vector.distance(p_pos, {x = b.x, y = b.y, z = b.z}))
                dist_str = " (" .. d .. "m away)"
            end
            msg = msg .. " - " .. b.name .. " -> (" .. b.x .. ", " .. b.y .. ", " .. b.z .. ")" .. dist_str .. "\n"
        end
        if count == 0 then
            return true, "No Waypoint Beacons registered. Place an 'Airliner Waypoint Beacon' or explore near existing ones to auto-detect!"
        end
        return true, msg
    end
})

core.register_chatcommand("airliner_route", {
    description = "Shows all waypoints queued in the nearest airliner.",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        local msg = "=== Active Flight Plan ===\n"
        if #ent.waypoints == 0 then
            msg = msg .. "  No waypoints currently queued in airliner.\n"
        else
            for i, wp in ipairs(ent.waypoints) do
                local wname = wp.name or ("Waypoint #" .. i)
                msg = msg .. "  " .. i .. ". " .. wname .. " -> (" .. wp.x .. ", " .. wp.y .. ", " .. wp.z .. ")\n"
            end
        end
        if #ent.full_route >= 2 then
            msg = msg .. "Full Shuttle Route: " .. #ent.full_route .. " stops (" .. ent.route_direction .. ")\n"
        end
        return true, msg
    end
})

core.register_chatcommand("airliner_gui", {
    description = "Opens the Flight Computer GUI for the nearest airliner.",
    func = function(name, param)
        local player = core.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found nearby." end
        show_flight_computer(player, ent)
        return true
    end
})

core.register_chatcommand("airliner_clear", {
    description = "Clears all waypoints and resets the shuttle route.",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        airliner.clear_waypoints(ent.object)
        return true, "Waypoints and shuttle route cleared."
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
        if ent.passengers then
            for i = #ent.passengers, 1, -1 do
                airliner.detach(ent.passengers[i], true)
            end
        end

        if ent.object then ent.object:remove() end
        if ent.plane_id then airliner.tracked_planes[ent.plane_id] = nil end
        return true, "Airliner removed."
    end
})

core.register_chatcommand("airliner_tp", {
    description = "Teleports you to your airliner.",
    func = function(name, param)
        local player = core.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        local pos = (ent.object and ent.object.get_pos and ent.object:get_pos()) or ent.pos
        if pos then
            player:set_pos({x = pos.x, y = pos.y + 2, z = pos.z})
            if not ent.object or not ent.object:get_pos() then
                local obj = airliner.spawn(pos, ent.owner)
                if obj then
                    local new_ent = obj:get_luaentity()
                    if new_ent then
                        new_ent.state = ent.state
                        new_ent.waypoints = ent.waypoints or {}
                        new_ent.full_route = ent.full_route or {}
                        new_ent.target_waypoint = ent.target_waypoint
                        new_ent.route_direction = ent.route_direction
                        new_ent.target_cruise_y = ent.target_cruise_y
                        new_ent.idle_timer = ent.idle_timer
                        ent.object = obj
                    end
                end
            end
            return true, "Teleported to airliner at (" .. math.floor(pos.x) .. ", " .. math.floor(pos.y) .. ", " .. math.floor(pos.z) .. ")."
        end
        return false, "Could not determine airliner location."
    end
})

core.register_chatcommand("airliner_kill_all", {
    description = "Removes all airliner entities in the world (useful for cleaning up stuck test planes).",
    func = function(name, param)
        local count = 0
        for _, obj in pairs(core.object_refs) do
            local ent = airliner.get_airliner(obj)
            if ent then
                if ent.pilot then airliner.detach(ent.pilot, true) end
                if ent.passengers then
                    for i = #ent.passengers, 1, -1 do
                        airliner.detach(ent.passengers[i], true)
                    end
                end
                obj:remove()
                count = count + 1
            end
        end
        airliner.tracked_planes = {}
        return true, "Cleaned up " .. count .. " airliner(s)."
    end
})

core.register_chatcommand("airliner_status", {
    description = "Shows the status and waypoints of the nearest owned airliner.",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        local pos = (ent.object and ent.object.get_pos and ent.object:get_pos()) or ent.pos or {x = 0, y = 0, z = 0}
        local msg = "State: " .. ent.state
        msg = msg .. " | Pos: (" .. math.floor(pos.x) .. ", " .. math.floor(pos.y) .. ", " .. math.floor(pos.z) .. ")"
        msg = msg .. " | Waypoints queued: " .. #(ent.waypoints or {})
        msg = msg .. " | Route stops: " .. #(ent.full_route or {})
        msg = msg .. " | Direction: " .. (ent.route_direction or "forward")
        if ent.target_waypoint then
            local tw = ent.target_waypoint
            msg = msg .. "\nTarget: " .. (tw.name or "WP") .. " at (" .. tw.x .. ", " .. (tw.y or "ground") .. ", " .. tw.z .. ")"
        end
        local has_players = false
        if ent._has_players then
            has_players = ent:_has_players()
        elseif ent.pilot_name or ent.passenger_names then
            has_players = (ent.pilot_name and ent.pilot_name ~= "") or (ent.passenger_names and next(ent.passenger_names) ~= nil)
        end
        if (ent.state == "arrived" or ent.state == "ground") and not has_players and #(ent.full_route or {}) >= 2 then
            local remaining = math.max(0, math.floor(IDLE_TIMEOUT - (ent.idle_timer or 0)))
            msg = msg .. "\nAuto-depart in: " .. remaining .. "s"
        end
        return true, msg
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
        end
    end
end)