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
-- Constants & Flight Profiles
-- ----------------------------------------------------------------------------

local CRUISE_SPEED        = 50   -- nodes/second horizontal cruise speed (airline speed)
local TAXI_SPEED          = 12   -- nodes/second initial ground roll & touchdown speed
local TAKEOFF_DISTANCE    = 100  -- nodes horizontal takeoff corridor distance
local TAKEOFF_ROLL_DIST   = 25   -- nodes on-ground runway roll before rotation/liftoff
local LANDING_DISTANCE    = 100  -- nodes horizontal landing approach & glide slope distance
local LANDING_FLARE_DIST  = 20   -- nodes flare zone before touchdown
local CRUISE_ALT_OFFSET   = 100  -- nodes above takeoff/landing for cruising
local MIN_CRUISE_Y        = 120  -- minimum absolute Y altitude for cruising (clear hills/trees)
local WAYPOINT_DIST       = 25   -- horizontal distance to advance intermediate waypoint
local IDLE_TIMEOUT        = 30   -- 30 seconds for debug before auto-return shuttle
local STUCK_TIMEOUT       = 4.0  -- seconds without movement before declaring stuck on landing

-- Global tracking of all active airliners
airliner.tracked_planes = {}

-- Mod Storage & Kill Epoch Initialization
local mod_storage = (core.get_mod_storage and core.get_mod_storage()) or nil
local global_kill_epoch = 0
if mod_storage and mod_storage.get_int then
    global_kill_epoch = mod_storage:get_int("kill_epoch") or 0
end

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

local vec_add       = vector.add
local vec_sub       = vector.subtract
local vec_mul       = vector.multiply
local vec_normalize = vector.normalize
local vec_distance  = vector.distance

--- Apply 3D pitch/yaw/roll attitude to airliner mesh (supports Luanti 5.0+)
local function set_aircraft_rotation(obj, pitch, yaw, roll)
    pitch = pitch or 0
    yaw = yaw or 0
    roll = roll or 0
    if obj and obj.set_rotation then
        obj:set_rotation({x = pitch, y = yaw, z = roll})
    elseif obj and obj.set_yaw then
        obj:set_yaw(yaw)
    end
end

--- Find solid ground Y below pos, ignoring leaves and air
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
                    return check.y + 1
                end
            end
        else
            return nil
        end
    end
    return nil
end

--- Pre-flight runway clearance check over 100 blocks
-- Scans the takeoff corridor for trees, structures, or terrain
local function check_takeoff_runway(start_pos, target_pos, target_cruise_y)
    if not start_pos or not target_pos or not target_pos.x or not target_pos.z then return true end
    local dx = target_pos.x - start_pos.x
    local dz = target_pos.z - start_pos.z
    local total_h = math.sqrt(dx * dx + dz * dz)
    if total_h < 1 then return true end

    local h_dir = {x = dx / total_h, y = 0, z = dz / total_h}
    local scan_dist = math.min(TAKEOFF_DISTANCE, total_h)

    -- Step every 2 nodes along the takeoff trajectory
    for d = 2, scan_dist, 2 do
        local expected_y
        if d <= TAKEOFF_ROLL_DIST then
            -- Ground roll phase: aircraft is rolling on the runway
            expected_y = start_pos.y
        else
            -- Climb phase: smooth S-curve climb towards cruise altitude
            local u = (d - TAKEOFF_ROLL_DIST) / (TAKEOFF_DISTANCE - TAKEOFF_ROLL_DIST)
            u = math.max(0, math.min(1, u))
            local smooth_u = u * u * (3 - 2 * u)
            expected_y = start_pos.y + (target_cruise_y - start_pos.y) * smooth_u
        end

        local center_x = start_pos.x + h_dir.x * d
        local center_z = start_pos.z + h_dir.z * d

        -- Check clearance bounding volume around aircraft (width 3, height 3)
        local y_start = (d <= TAKEOFF_ROLL_DIST) and 1 or 0
        for cy = y_start, 3 do
            for cx = -1, 1 do
                for cz = -1, 1 do
                    local check_pos = {
                        x = math.floor(center_x + cx + 0.5),
                        y = math.floor(expected_y + cy + 0.5),
                        z = math.floor(center_z + cz + 0.5),
                    }
                    local node = core.get_node_or_nil(check_pos)
                    if node and node.name ~= "air" and node.name ~= "ignore" then
                        local def = core.registered_nodes[node.name]
                        if def and (def.walkable or (def.groups and (def.groups.tree or def.groups.leaves or def.groups.wood or def.groups.stone))) then
                            return false, "Runway blocked: Obstacle (" .. node.name .. ") detected at (" .. check_pos.x .. ", " .. check_pos.y .. ", " .. check_pos.z .. ") along the 100-block takeoff path. Please clear the runway."
                        end
                    end
                end
            end
        end
    end

    return true
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

function airliner.materialize_entity(plane_id)
    local p = airliner.tracked_planes[plane_id]
    if not p then return nil end

    if p.object and p.object.get_pos and p.object:get_pos() ~= nil then
        return p.object
    end

    local pos = p.pos
    if not pos then return nil end

    core.forceload_block(pos, true)

    local staticdata = core.serialize({
        plane_id         = plane_id,
        state            = p.state or "ground",
        waypoints        = p.waypoints or {},
        target_waypoint  = p.target_waypoint,
        owner            = p.owner,
        takeoff_y        = p.takeoff_y or pos.y,
        target_cruise_y  = p.target_cruise_y or 120,
        idle_timer       = p.idle_timer or 0,
        full_route       = p.full_route or {},
        route_direction  = p.route_direction or "forward",
        flight_start_pos = p.flight_start_pos or pos,
        landing_start_y  = p.landing_start_y,
        landing_target_y = p.landing_target_y,
    })

    local obj = core.add_entity(pos, "airliner:airliner", staticdata)
    if obj then
        p.object = obj
        if p.target_waypoint then
            local dx = p.target_waypoint.x - pos.x
            local dz = p.target_waypoint.z - pos.z
            local yaw = math.atan2(-dx, dz)
            set_aircraft_rotation(obj, 0, yaw, 0)
        end
        return obj
    end
    return nil
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
        if ent.state == "ground" or ent.state == "arrived" or ent.state == "stuck" then
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

    if ent.state ~= "ground" and ent.state ~= "arrived" and ent.state ~= "stuck" then
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
        -- Allow dismount if grounded, arrived, stuck, or forced
        if not force and (ent.state ~= "ground" and ent.state ~= "arrived" and ent.state ~= "stuck") then
            core.chat_send_player(p_name, "[Airliner] Cannot detach while airliner is in active flight.")
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
-- Airliner Entity Definition
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
        backface_culling = true,
        static_save = true,
        pointable = true,
        hp_max = 100,
    },

    -- Instance fields
    state              = "ground",
    waypoints          = {},
    target_waypoint    = nil,
    owner              = nil,
    pilot              = nil,
    passengers         = {},
    aux1_held          = false,
    takeoff_y          = 0,
    target_cruise_y    = 120,
    idle_timer         = 0,
    stuck_timer        = 0,
    full_route         = {},
    route_direction    = "forward",
    flight_start_pos   = nil,
    landing_start_y    = nil,
    landing_target_y   = nil,
    last_pos           = nil,

    -- -----------------------------------------------------------------------
    -- Lifecycle & Authoritative Entity Singleton
    -- -----------------------------------------------------------------------

    on_activate = function(self, staticdata)
        self.object:set_armor_groups({fleshy = 100, cracky = 1, crumbly = 1, snappy = 1, choppy = 1})
        self.waypoints = {}
        self.passengers = {}
        self.full_route = {}
        self.idle_timer = 0
        self.stuck_timer = 0
        self.route_direction = "forward"

        if staticdata and staticdata ~= "" then
            local data = core.deserialize(staticdata)
            if data then
                self.state            = data.state or "ground"
                self.waypoints        = data.waypoints or {}
                self.target_waypoint  = data.target_waypoint
                self.owner            = data.owner
                self.takeoff_y        = data.takeoff_y or 0
                self.target_cruise_y  = data.target_cruise_y or 120
                self.idle_timer       = data.idle_timer or 0
                self.full_route       = data.full_route or {}
                self.route_direction  = data.route_direction or "forward"
                self.plane_id         = data.plane_id
                self.flight_start_pos = data.flight_start_pos
                self.landing_start_y  = data.landing_start_y
                self.landing_target_y = data.landing_target_y
            end
        end

        -- Ensure unique plane_id
        if not self.plane_id or self.plane_id == "" then
            self.plane_id = "plane_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
        end

        -- EPOCH PURGE: Purge any dormant entity from previous test sessions before the last /airliner_kill_all
        local kill_epoch = global_kill_epoch
        if mod_storage and mod_storage.get_int then
            kill_epoch = math.max(kill_epoch, mod_storage:get_int("kill_epoch") or 0)
        end
        local plane_ts = tonumber(string.match(self.plane_id or "", "^plane_(%d+)_")) or 0
        if plane_ts > 0 and plane_ts <= kill_epoch then
            core.log("action", "[Airliner] Purged dormant airliner (" .. self.plane_id .. ") created at " .. plane_ts .. " <= kill_epoch " .. kill_epoch)
            self.object:remove()
            return
        end

        local my_pos = self.object:get_pos()

        -- DEDUPLICATION & OBSOLETE SNAPSHOT PURGE:
        local existing = airliner.tracked_planes[self.plane_id]
        if existing then
            if existing.object and existing.object ~= self.object and existing.object:get_pos() ~= nil then
                core.log("action", "[Airliner] Removed duplicate airliner instance for " .. self.plane_id)
                self.object:remove()
                return
            end

            -- If existing tracking has moved far away (> 15m), this loaded entity is an obsolete snapshot from an unloaded mapblock
            if existing.pos and my_pos and vector.distance(my_pos, existing.pos) > 15.0 then
                core.log("action", "[Airliner] Removed obsolete airliner snapshot for " .. self.plane_id .. " at (" .. math.floor(my_pos.x) .. "," .. math.floor(my_pos.y) .. "," .. math.floor(my_pos.z) .. "), active pos is (" .. math.floor(existing.pos.x) .. "," .. math.floor(existing.pos.y) .. "," .. math.floor(existing.pos.z) .. ")")
                self.object:remove()
                return
            end

            -- Otherwise, adopt existing state from tracking
            self.state = existing.state or self.state
            self.waypoints = existing.waypoints or self.waypoints
            self.full_route = existing.full_route or self.full_route
            self.target_waypoint = existing.target_waypoint or self.target_waypoint
            self.route_direction = existing.route_direction or self.route_direction
            self.target_cruise_y = existing.target_cruise_y or self.target_cruise_y
            self.idle_timer = existing.idle_timer or self.idle_timer
            self.takeoff_y = existing.takeoff_y or self.takeoff_y
            self.flight_start_pos = existing.flight_start_pos or self.flight_start_pos
            self.landing_start_y = existing.landing_start_y or self.landing_start_y
            self.landing_target_y = existing.landing_target_y or self.landing_target_y
        end

        -- PROXIMITY DEDUPLICATION: Remove overlapping clone sitting at the exact same parked position (< 3m)
        if my_pos and (self.state == "ground" or self.state == "arrived") then
            for id, p in pairs(airliner.tracked_planes) do
                if id ~= self.plane_id and p.object and p.object ~= self.object and p.object:get_pos() then
                    local d = vector.distance(my_pos, p.object:get_pos())
                    if d < 3.0 then
                        core.log("action", "[Airliner] Removed overlapping airliner clone at (" .. math.floor(my_pos.x) .. "," .. math.floor(my_pos.y) .. "," .. math.floor(my_pos.z) .. ")")
                        self.object:remove()
                        return
                    end
                end
            end
        end

        self.object:set_properties({static_save = true, backface_culling = true})
        airliner.tracked_planes[self.plane_id] = {
            id = self.plane_id,
            object = self.object,
            owner = self.owner,
            state = self.state,
            pos = my_pos,
            waypoints = self.waypoints,
            full_route = self.full_route,
            target_waypoint = self.target_waypoint,
            route_direction = self.route_direction,
            idle_timer = self.idle_timer,
            target_cruise_y = self.target_cruise_y,
            takeoff_y = self.takeoff_y,
            flight_start_pos = self.flight_start_pos,
            landing_start_y = self.landing_start_y,
            landing_target_y = self.landing_target_y,
            pilot_name = self.pilot_name,
            passenger_names = self.passenger_names,
        }
    end,

    get_staticdata = function(self)
        return core.serialize({
            state            = self.state,
            waypoints        = self.waypoints,
            target_waypoint  = self.target_waypoint,
            owner            = self.owner,
            takeoff_y        = self.takeoff_y,
            target_cruise_y  = self.target_cruise_y,
            idle_timer       = self.idle_timer,
            full_route       = self.full_route,
            route_direction  = self.route_direction,
            plane_id         = self.plane_id,
            flight_start_pos = self.flight_start_pos,
            landing_start_y  = self.landing_start_y,
            landing_target_y = self.landing_target_y,
        })
    end,

    -- -----------------------------------------------------------------------
    -- Punch -> Damage & Drop
    -- -----------------------------------------------------------------------

    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
        local hp = self.object:get_hp()
        if puncher and puncher:is_player() then
            local p_name = puncher:get_player_name()
            core.chat_send_player(p_name, "[Airliner] HP: " .. math.max(0, hp) .. " / 100")
        end
        if hp <= 0 then
            if self.pilot then airliner.detach(self.pilot, true) end
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
            if self.forceloaded_pos then
                core.forceload_free_block(self.forceloaded_pos, true)
                self.forceloaded_pos = nil
            end
            self.object:remove()
        end
    end,

    -- -----------------------------------------------------------------------
    -- Internal: Takeoff & Landing
    -- -----------------------------------------------------------------------

    _start_takeoff = function(self)
        if self.state ~= "ground" and self.state ~= "arrived" and self.state ~= "stuck" then return false end

        local pos = self.object:get_pos()
        if not pos then return false end
        self.takeoff_y = pos.y

        -- 1. If waypoints are empty but full_route exists with >= 2 stops, reverse/advance shuttle route
        if #self.waypoints == 0 and not self.target_waypoint and #self.full_route >= 2 then
            self.waypoints = {}
            if self.route_direction == "forward" then
                self.route_direction = "reverse"
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
                for i = 2, #self.full_route do
                    table.insert(self.waypoints, {
                        x = self.full_route[i].x,
                        y = self.full_route[i].y,
                        z = self.full_route[i].z,
                        name = self.full_route[i].name,
                    })
                end
            end
        end

        -- 2. If STILL no waypoints and no full_route, auto-check placed beacons in the world
        if #self.waypoints == 0 and not self.target_waypoint and #self.full_route == 0 then
            local beacons = get_all_beacons()
            local beacon_list = {}
            for _, b in pairs(beacons) do
                local d = vector.distance(pos, {x = b.x, y = b.y, z = b.z})
                if d > 20 then
                    table.insert(beacon_list, b)
                end
            end
            if #beacon_list > 0 then
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

        -- 3. If STILL no waypoints, warn and do not take off
        if #self.waypoints == 0 and not self.target_waypoint then
            if self.pilot and self.pilot:is_player() then
                core.chat_send_player(self.pilot:get_player_name(), "[Airliner] No destination set! Place a Waypoint Beacon or use /airliner_waypoint x,y,z or Shift+Right-Click to open Flight Computer.")
            end
            return false
        end

        -- 4. Capture full_route on the first departure
        if #self.waypoints > 0 and #self.full_route == 0 then
            self.full_route = {}
            table.insert(self.full_route, {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z), name = "Origin (Airport A)"})
            for _, wp in ipairs(self.waypoints) do
                table.insert(self.full_route, {x = wp.x, y = wp.y, z = wp.z, name = wp.name})
            end
            self.route_direction = "forward"
        end

        if not self.target_waypoint and #self.waypoints > 0 then
            self.target_waypoint = table.remove(self.waypoints, 1)
        end

        if not self.target_waypoint then
            return false
        end

        -- Compute safe cruising altitude
        local target_y = self.target_waypoint.y or pos.y
        local max_y = math.max(pos.y, target_y)
        self.target_cruise_y = math.max(MIN_CRUISE_Y, max_y + CRUISE_ALT_OFFSET)

        -- 100-Block Pre-flight Runway Clearance Check
        local is_clear, block_reason = check_takeoff_runway(pos, self.target_waypoint, self.target_cruise_y)
        if not is_clear then
            core.log("warning", "[Airliner] Takeoff aborted: " .. block_reason)
            if self.pilot and self.pilot:is_player() then
                core.chat_send_player(self.pilot:get_player_name(), "[Airliner] " .. block_reason)
            end
            -- Re-queue target waypoint so it is not lost
            if self.target_waypoint then
                table.insert(self.waypoints, 1, self.target_waypoint)
                self.target_waypoint = nil
            end
            return false
        end

        self.flight_start_pos = {x = pos.x, y = pos.y, z = pos.z}
        self.state = "takeoff"
        self.idle_timer = 0
        self.stuck_timer = 0
        self.last_pos = {x = pos.x, y = pos.y, z = pos.z}

        local dest_name = (self.target_waypoint and (self.target_waypoint.name or "(" .. self.target_waypoint.x .. "," .. self.target_waypoint.z .. ")")) or "Unknown"
        core.log("action", "[Airliner] Takeoff initiated towards " .. dest_name .. " (Cruise Alt: " .. self.target_cruise_y .. ")")
        if self.pilot and self.pilot:is_player() then
            core.chat_send_player(self.pilot:get_player_name(), "[Airliner] Runway clear! Taking off towards " .. dest_name .. " (Climbing to Y=" .. self.target_cruise_y .. " over 100 blocks).")
        end
        return true
    end,

    _force_landing = function(self)
        local pos = self.object:get_pos()
        if not pos then return end
        self.state = "landing"
        self.landing_start_y = pos.y
        self.landing_target_y = find_ground_y(pos, 300) or pos.y
        self.stuck_timer = 0
        self.last_pos = {x = pos.x, y = pos.y, z = pos.z}
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
        if not pos then return end
        self.takeoff_y = pos.y

        self:_start_takeoff()
    end,

    -- -----------------------------------------------------------------------
    -- on_step: High-precision 100-block takeoff, cruise & landing
    -- -----------------------------------------------------------------------

    on_step = function(self, dtime)
        if dtime > 0.5 then dtime = 0.5 end
        local pos = self.object:get_pos()
        if not pos then return end

        -- Update global tracker
        if self.plane_id then
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
            t.takeoff_y = self.takeoff_y
            t.flight_start_pos = self.flight_start_pos
            t.landing_start_y = self.landing_start_y
            t.landing_target_y = self.landing_target_y
            t.pilot_name = self.pilot_name
            t.passenger_names = self.passenger_names
            airliner.tracked_planes[self.plane_id] = t
        end

        -- ===== GROUND / ARRIVED / STUCK =====
        if self.state == "ground" or self.state == "arrived" or self.state == "stuck" then
            if self.forceloaded_pos then
                core.forceload_free_block(self.forceloaded_pos, true)
                self.forceloaded_pos = nil
            end

            if self.state ~= "stuck" and not self:_has_players() and #self.full_route >= 2 then
                self.idle_timer = self.idle_timer + dtime
                if self.idle_timer >= IDLE_TIMEOUT then
                    self:_auto_return()
                end
            else
                self.idle_timer = 0
            end
            return
        end

        -- ===== ACTIVE FLIGHT =====
        if not self.target_waypoint then
            self.state = "ground"
            return
        end

        local target = self.target_waypoint
        local cruise_y = self.target_cruise_y or (self.takeoff_y + CRUISE_ALT_OFFSET)

        -- Keep active mapblock forceloaded during flight
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

        local yaw = math.atan2(-h_dir.x, h_dir.z)

        -- ----- TAKEOFF: 100-block ground roll & natural climb -----
        if self.state == "takeoff" then
            local start = self.flight_start_pos or pos
            local d_flown = math.sqrt((pos.x - start.x)^2 + (pos.z - start.z)^2)

            if d_flown < TAKEOFF_DISTANCE and pos.y < cruise_y - 0.5 then
                if d_flown <= TAKEOFF_ROLL_DIST then
                    -- 1. Ground roll on runway: accelerate forward, level attitude
                    local roll_progress = d_flown / TAKEOFF_ROLL_DIST
                    local fwd_speed = TAXI_SPEED + (35 - TAXI_SPEED) * roll_progress
                    local step_x = pos.x + h_dir.x * fwd_speed * dtime
                    local step_z = pos.z + h_dir.z * fwd_speed * dtime
                    self.object:set_pos({x = step_x, y = start.y, z = step_z})
                    set_aircraft_rotation(self.object, 0, yaw, 0)
                else
                    -- 2. Lift-off & climb: smooth S-curve climb with nose-up pitch attitude
                    local climb_u = (d_flown - TAKEOFF_ROLL_DIST) / (TAKEOFF_DISTANCE - TAKEOFF_ROLL_DIST)
                    climb_u = math.max(0, math.min(1, climb_u))
                    local smooth_u = climb_u * climb_u * (3 - 2 * climb_u)

                    local climb_speed = 35 + (CRUISE_SPEED - 35) * climb_u
                    local step_x = pos.x + h_dir.x * climb_speed * dtime
                    local step_z = pos.z + h_dir.z * climb_speed * dtime
                    local target_y = start.y + (cruise_y - start.y) * smooth_u

                    -- Nose-up pitch attitude during climb (~11.5 degrees max)
                    local pitch_angle = -0.20 * math.sin(climb_u * math.pi)

                    self.object:set_pos({x = step_x, y = target_y, z = step_z})
                    set_aircraft_rotation(self.object, pitch_angle, yaw, 0)
                end
            else
                -- Reached cruise altitude & transitioned out of 100-block takeoff corridor
                self.state = "cruise"
                self.object:set_pos({x = pos.x, y = cruise_y, z = pos.z})
                set_aircraft_rotation(self.object, 0, yaw, 0)
                core.log("action", "[Airliner] Reached cruise altitude (" .. math.floor(cruise_y) .. "m). Cruising at " .. CRUISE_SPEED .. "m/s.")
            end
            return
        end

        -- ----- CRUISE: Fly horizontally towards target -----
        if self.state == "cruise" then
            if #self.waypoints > 0 then
                -- Intermediate waypoint transition
                if h_dist < WAYPOINT_DIST then
                    local next_wp = table.remove(self.waypoints, 1)
                    self.target_waypoint = next_wp
                    local next_name = next_wp.name or ("WP (" .. next_wp.x .. "," .. next_wp.z .. ")")
                    core.log("action", "[Airliner] Reached intermediate waypoint. Next: " .. next_name)
                    if self.pilot and self.pilot:is_player() then
                        core.chat_send_player(self.pilot:get_player_name(), "[Airliner] Waypoint reached. Next stop: " .. next_name)
                    end
                else
                    local step_x = pos.x + h_dir.x * CRUISE_SPEED * dtime
                    local step_z = pos.z + h_dir.z * CRUISE_SPEED * dtime
                    self.object:set_pos({x = step_x, y = cruise_y, z = step_z})
                    set_aircraft_rotation(self.object, 0, yaw, 0)
                end
            else
                -- Approaching final destination: begin 100-block landing glide slope
                if h_dist <= LANDING_DISTANCE then
                    self.state = "landing"
                    self.landing_start_y = pos.y
                    local target_ground = find_ground_y({x = target.x, y = pos.y, z = target.z}, 300)
                    self.landing_target_y = (target.y and target.y > 0 and target.y) or target_ground or pos.y
                    self.stuck_timer = 0
                    self.last_pos = {x = pos.x, y = pos.y, z = pos.z}
                    core.log("action", "[Airliner] Entering 100-block landing glide slope to " .. (target.name or "destination") .. " (Runway Y=" .. self.landing_target_y .. ").")
                    if self.pilot and self.pilot:is_player() then
                        core.chat_send_player(self.pilot:get_player_name(), "[Airliner] Approaching runway. Descending on glide slope towards " .. (target.name or "runway") .. ".")
                    end
                else
                    local step_x = pos.x + h_dir.x * CRUISE_SPEED * dtime
                    local step_z = pos.z + h_dir.z * CRUISE_SPEED * dtime
                    self.object:set_pos({x = step_x, y = cruise_y, z = step_z})
                    set_aircraft_rotation(self.object, 0, yaw, 0)
                end
            end
            return
        end

        -- ----- LANDING / DESCENDING: Natural 100-block Glide Slope, Flare & Touchdown -----
        if self.state == "landing" or self.state == "descending" then
            local target_y = (target.y ~= nil and target.y) or (self.landing_target_y ~= nil and self.landing_target_y) or pos.y
            local start_y = self.landing_start_y or cruise_y

            -- Ensure destination mapblock is also forceloaded so runway is loaded
            local dest_mb = {
                x = math.floor(target.x / 16) * 16,
                y = math.floor(target_y / 16) * 16,
                z = math.floor(target.z / 16) * 16,
            }
            if not self.forceloaded_dest or self.forceloaded_dest.x ~= dest_mb.x or self.forceloaded_dest.y ~= dest_mb.y or self.forceloaded_dest.z ~= dest_mb.z then
                if self.forceloaded_dest then
                    core.forceload_free_block(self.forceloaded_dest, true)
                end
                core.forceload_block(dest_mb, true)
                self.forceloaded_dest = dest_mb
            end

            -- Obstruction / Stuck Detection during landing (only if players onboard)
            if self:_has_players() and self.last_pos then
                local dist_moved = vector.distance(pos, self.last_pos)
                if dist_moved < 0.05 * dtime then
                    self.stuck_timer = (self.stuck_timer or 0) + dtime
                    if self.stuck_timer >= STUCK_TIMEOUT then
                        self.state = "stuck"
                        if self.forceloaded_pos then
                            core.forceload_free_block(self.forceloaded_pos, true)
                            self.forceloaded_pos = nil
                        end
                        if self.forceloaded_dest then
                            core.forceload_free_block(self.forceloaded_dest, true)
                            self.forceloaded_dest = nil
                        end
                        core.log("warning", "[Airliner] Airliner obstructed / stuck during landing descent at (" .. math.floor(pos.x) .. "," .. math.floor(pos.y) .. "," .. math.floor(pos.z) .. ")!")
                        if self.pilot and self.pilot:is_player() then
                            core.chat_send_player(self.pilot:get_player_name(), "[Airliner] Airliner obstructed / hung on terrain during landing! Emergency dismount enabled: Right-click to exit safely.")
                        end
                        if self.passengers then
                            for _, pass in ipairs(self.passengers) do
                                if pass and pass:is_player() then
                                    core.chat_send_player(pass:get_player_name(), "[Airliner] Airliner obstructed / hung during landing! Right-click to exit safely.")
                                end
                            end
                        end
                        return
                    end
                else
                    self.stuck_timer = math.max(0, (self.stuck_timer or 0) - dtime)
                end
            end
            self.last_pos = {x = pos.x, y = pos.y, z = pos.z}

            local p = 1.0 - math.max(0, math.min(1, h_dist / LANDING_DISTANCE)) -- 0 at 100m, 1 at touchdown

            if h_dist > 15.0 and p < 0.85 then
                -- 1. Glide Slope Descent (100m to 15m out): smooth descent with gentle nose-down pitch
                local g = p / 0.85
                local app_speed = TAXI_SPEED + (CRUISE_SPEED - TAXI_SPEED) * (1 - g)
                local move_step = app_speed * dtime

                local next_y = start_y - (start_y - (target_y + 2.0)) * (g^1.2)
                local pitch_angle = 0.08 * (1 - g) -- Slight nose-down attitude on glide slope

                local next_x = pos.x + h_dir.x * move_step
                local next_z = pos.z + h_dir.z * move_step

                self.object:set_pos({x = next_x, y = next_y, z = next_z})
                set_aircraft_rotation(self.object, pitch_angle, yaw, 0)
            elseif h_dist > 1.5 then
                -- 2. Flare Zone (last 15m before touchdown): pitch nose up slightly to flare and settle smoothly
                local f = (p - 0.85) / 0.15
                f = math.max(0, math.min(1, f))
                local flare_speed = math.max(6, TAXI_SPEED * (1 - f * 0.4))
                local move_step = flare_speed * dtime

                local next_y = (target_y + 2.0) - 1.5 * f
                local pitch_angle = -0.06 * math.sin(f * math.pi) -- Nose-up flare attitude

                local next_x = pos.x + h_dir.x * move_step
                local next_z = pos.z + h_dir.z * move_step

                self.object:set_pos({x = next_x, y = next_y, z = next_z})
                set_aircraft_rotation(self.object, pitch_angle, yaw, 0)
            elseif pos.y > target_y + 0.8 then
                -- 3. Vertical descent to runway (if aligned above destination at altitude)
                local sink_speed = 10 -- m/s descent
                local next_y = pos.y - sink_speed * dtime
                if next_y <= target_y + 0.5 then
                    next_y = target_y + 0.5
                end
                self.object:set_pos({x = target.x, y = next_y, z = target.z})
                set_aircraft_rotation(self.object, 0, yaw, 0)
            else
                -- 4. Touchdown & Arrival
                local final_ground = find_ground_y({x = target.x, y = target_y + 5, z = target.z}, 50) or target_y
                self.object:set_pos({x = target.x, y = final_ground + 0.5, z = target.z})
                set_aircraft_rotation(self.object, 0, yaw, 0)
                self.object:set_properties({static_save = true})
                self.state = "arrived"
                self.target_waypoint = nil
                self.idle_timer = 0
                self.stuck_timer = 0

                if self.forceloaded_pos then
                    core.forceload_free_block(self.forceloaded_pos, true)
                    self.forceloaded_pos = nil
                end
                if self.forceloaded_dest then
                    core.forceload_free_block(self.forceloaded_dest, true)
                    self.forceloaded_dest = nil
                end

                core.log("action", "[Airliner] Touched down at (" .. math.floor(target.x) .. ", " .. math.floor(final_ground) .. ", " .. math.floor(target.z) .. "). Landing complete.")
                if self.pilot_name and self.pilot_name ~= "" then
                    core.chat_send_player(self.pilot_name, "[Airliner] Landed safely at destination. Right-click to dismount.")
                end
                if self.passengers then
                    for _, pass in ipairs(self.passengers) do
                        if pass and pass:is_player() then
                            core.chat_send_player(pass:get_player_name(), "[Airliner] Landed safely at destination. Right-click to dismount.")
                        end
                    end
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
-- Right-click handler for boarding, flight computer & dismount
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

    -- If this player is already aboard (as pilot or passenger), detach them!
    if self.pilot_name == p_name or (self.passenger_names and self.passenger_names[p_name]) or (self.pilot and self.pilot == clicker) then
        airliner.detach(clicker, false)
        return
    end

    if self.state ~= "ground" and self.state ~= "arrived" and self.state ~= "stuck" then
        core.chat_send_player(p_name, "[Airliner] Cannot board while the airliner is flying.")
        return
    end

    airliner.attach(clicker, self.object)
end

-- ----------------------------------------------------------------------------
-- Globalstep: Pilot Input & 30s Periodic Status Logger to debug.txt
-- ----------------------------------------------------------------------------

local debug_log_timer = 0
local DEBUG_LOG_INTERVAL = 30 -- seconds

core.register_globalstep(function(dtime)
    if dtime > 0.5 then dtime = 0.5 end

    -- 1. Pilot AUX1 key detection for takeoff
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
                        if ent.state == "ground" or ent.state == "arrived" or ent.state == "stuck" then
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

    -- 2. Remote Simulation & Auto-Materialization for Unmanned Aircraft
    for plane_id, p in pairs(airliner.tracked_planes) do
        local is_live_obj = p.object and p.object.get_pos and p.object:get_pos() ~= nil
        local has_active_pilot = (p.pilot_name and p.pilot_name ~= "") or (p.passenger_names and next(p.passenger_names) ~= nil)

        -- If unmanned airliner has no live entity in world, check if any player is nearby to materialize it
        if not is_live_obj and not has_active_pilot and p.pos then
            local player_nearby = false
            for _, pl in pairs(core.get_connected_players()) do
                local ppos = pl:get_pos()
                if ppos and vector.distance(ppos, p.pos) < 150 then
                    player_nearby = true
                    break
                end
            end

            if player_nearby then
                local obj = airliner.materialize_entity(plane_id)
                if obj then
                    is_live_obj = true
                end
            end
        end

        if not is_live_obj and not has_active_pilot and (p.state == "cruise" or p.state == "takeoff" or p.state == "landing" or p.state == "descending") and p.target_waypoint then
            local pos = p.pos or {x = 0, y = 120, z = 0}
            local target = p.target_waypoint
            local start = p.flight_start_pos or pos
            local cruise_y = p.target_cruise_y or 120

            local dx = target.x - pos.x
            local dz = target.z - pos.z
            local h_dist = math.sqrt(dx * dx + dz * dz)
            local d_flown = math.sqrt((pos.x - start.x)^2 + (pos.z - start.z)^2)

            local h_dir
            if h_dist > 0.01 then
                h_dir = {x = dx / h_dist, z = dz / h_dist}
            else
                h_dir = {x = 0, z = 0}
            end

            -- Remote TAKEOFF Phase (100 blocks climb)
            if p.state == "takeoff" then
                if d_flown < TAKEOFF_DISTANCE and pos.y < cruise_y - 0.5 then
                    if d_flown <= TAKEOFF_ROLL_DIST then
                        local roll_prog = d_flown / TAKEOFF_ROLL_DIST
                        local fwd_speed = TAXI_SPEED + (35 - TAXI_SPEED) * roll_prog
                        pos.x = pos.x + h_dir.x * fwd_speed * dtime
                        pos.z = pos.z + h_dir.z * fwd_speed * dtime
                        pos.y = start.y
                    else
                        local climb_u = (d_flown - TAKEOFF_ROLL_DIST) / (TAKEOFF_DISTANCE - TAKEOFF_ROLL_DIST)
                        climb_u = math.max(0, math.min(1, climb_u))
                        local smooth_u = climb_u * climb_u * (3 - 2 * climb_u)
                        local climb_speed = 35 + (CRUISE_SPEED - 35) * climb_u
                        pos.x = pos.x + h_dir.x * climb_speed * dtime
                        pos.z = pos.z + h_dir.z * climb_speed * dtime
                        pos.y = start.y + (cruise_y - start.y) * smooth_u
                    end
                else
                    p.state = "cruise"
                    pos.y = cruise_y
                    core.log("action", "[Airliner] Unmanned airliner " .. plane_id .. " reached cruise altitude (" .. math.floor(cruise_y) .. "m). Cruising at " .. CRUISE_SPEED .. "m/s.")
                end
                p.pos = pos
                core.forceload_block(pos, true)

            -- Remote CRUISE Phase
            elseif p.state == "cruise" then
                pos.y = cruise_y
                if #(p.waypoints or {}) > 0 then
                    if h_dist < WAYPOINT_DIST then
                        local next_wp = table.remove(p.waypoints, 1)
                        p.target_waypoint = next_wp
                        core.log("action", "[Airliner] Unmanned airliner " .. plane_id .. " reached intermediate waypoint. Next: " .. (next_wp.name or "WP"))
                    else
                        pos.x = pos.x + h_dir.x * CRUISE_SPEED * dtime
                        pos.z = pos.z + h_dir.z * CRUISE_SPEED * dtime
                    end
                else
                    if h_dist <= LANDING_DISTANCE then
                        p.state = "landing"
                        p.landing_start_y = pos.y
                        p.landing_target_y = (target.y and target.y > 0 and target.y) or 10
                        core.log("action", "[Airliner] Unmanned airliner " .. plane_id .. " entering landing glide slope to " .. (target.name or "destination"))
                    else
                        pos.x = pos.x + h_dir.x * CRUISE_SPEED * dtime
                        pos.z = pos.z + h_dir.z * CRUISE_SPEED * dtime
                    end
                end
                p.pos = pos
                core.forceload_block(pos, true)

            -- Remote LANDING Phase (100 blocks glide slope)
            elseif p.state == "landing" or p.state == "descending" then
                local target_y = (target.y and target.y > 0 and target.y) or (p.landing_target_y and p.landing_target_y > 0 and p.landing_target_y) or 10
                local start_y = p.landing_start_y or cruise_y
                local prog = 1.0 - math.max(0, math.min(1, h_dist / LANDING_DISTANCE))

                if h_dist > 15.0 and prog < 0.85 then
                    local g = prog / 0.85
                    local app_speed = TAXI_SPEED + (CRUISE_SPEED - TAXI_SPEED) * (1 - g)
                    pos.y = start_y - (start_y - (target_y + 2.0)) * (g^1.2)
                    pos.x = pos.x + h_dir.x * app_speed * dtime
                    pos.z = pos.z + h_dir.z * app_speed * dtime
                    p.pos = pos
                    core.forceload_block(pos, true)
                elseif h_dist > 1.5 then
                    local f = (prog - 0.85) / 0.15
                    f = math.max(0, math.min(1, f))
                    local flare_speed = math.max(6, TAXI_SPEED * (1 - f * 0.4))
                    pos.y = (target_y + 2.0) - 1.5 * f
                    pos.x = pos.x + h_dir.x * flare_speed * dtime
                    pos.z = pos.z + h_dir.z * flare_speed * dtime
                    p.pos = pos
                    core.forceload_block(pos, true)
                else
                    -- Touchdown & Arrival
                    pos.x = target.x
                    pos.y = target_y + 0.5
                    pos.z = target.z
                    p.pos = pos
                    p.state = "arrived"
                    p.target_waypoint = nil
                    p.idle_timer = 0
                    core.forceload_block(p.pos, true)
                    core.log("action", "[Airliner] Unmanned airliner " .. plane_id .. " arrived at " .. (target.name or "destination") .. " via remote shuttle simulation.")
                    airliner.materialize_entity(plane_id)
                end
            end

        -- Remote Auto-Return Shuttle
        elseif not is_live_obj and not has_active_pilot and (p.state == "arrived" or p.state == "ground") and #(p.full_route or {}) >= 2 then
            p.idle_timer = (p.idle_timer or 0) + dtime
            if p.idle_timer >= IDLE_TIMEOUT then
                p.idle_timer = 0
                p.waypoints = {}
                if p.route_direction == "forward" then
                    p.route_direction = "reverse"
                    for i = #p.full_route - 1, 1, -1 do
                        table.insert(p.waypoints, {
                            x = p.full_route[i].x,
                            y = p.full_route[i].y,
                            z = p.full_route[i].z,
                            name = p.full_route[i].name,
                        })
                    end
                else
                    p.route_direction = "forward"
                    for i = 2, #p.full_route do
                        table.insert(p.waypoints, {
                            x = p.full_route[i].x,
                            y = p.full_route[i].y,
                            z = p.full_route[i].z,
                            name = p.full_route[i].name,
                        })
                    end
                end

                if #p.waypoints > 0 then
                    p.target_waypoint = table.remove(p.waypoints, 1)
                    local pos = p.pos or {x = 0, y = 10, z = 0}
                    p.takeoff_y = pos.y
                    p.flight_start_pos = {x = pos.x, y = pos.y, z = pos.z}
                    local target_y = (p.target_waypoint and p.target_waypoint.y) or pos.y
                    local max_y = math.max(pos.y, target_y)
                    p.target_cruise_y = math.max(MIN_CRUISE_Y, max_y + CRUISE_ALT_OFFSET)
                    p.state = "takeoff"
                    p.stuck_timer = 0
                    local dest_name = (p.target_waypoint and (p.target_waypoint.name or "(" .. p.target_waypoint.x .. "," .. p.target_waypoint.z .. ")")) or "Unknown"
                    core.log("action", "[Airliner] Unmanned airliner " .. plane_id .. " auto-departing on return flight towards " .. dest_name .. " (Cruise Alt: " .. p.target_cruise_y .. ")")
                end
            end
        end
    end

    -- 3. Periodic 30-second Airliner Status Dump to debug.txt
    debug_log_timer = debug_log_timer + dtime
    if debug_log_timer >= DEBUG_LOG_INTERVAL then
        debug_log_timer = 0

        local t_stamp = os.date("%Y-%m-%d %H:%M:%S")
        local lines = {}
        table.insert(lines, "=== AIRLINER STATUS LOG [" .. t_stamp .. "] ===")
        local count = 0

        for plane_id, p in pairs(airliner.tracked_planes) do
            count = count + 1
            local pos = (p.object and p.object.get_pos and p.object:get_pos()) or p.pos or {x = 0, y = 0, z = 0}
            local state = p.state or "UNKNOWN"
            local tw_str = "None"
            if p.target_waypoint then
                local tw = p.target_waypoint
                tw_str = (tw.name or "WP") .. " at (" .. math.floor(tw.x or 0) .. "," .. math.floor(tw.y or 0) .. "," .. math.floor(tw.z or 0) .. ")"
            end
            local wps_count = #(p.waypoints or {})
            local route_count = #(p.full_route or {})
            local idle = math.floor(p.idle_timer or 0)
            local pilot = (p.pilot_name and p.pilot_name ~= "" and p.pilot_name) or "None"
            local is_obj_live = (p.object and p.object.get_pos and p.object:get_pos() ~= nil) and "LIVE" or "TRACKED"

            local entry = string.format("[%d] ID: %s (%s) | State: %s | Pos: (%.1f, %.1f, %.1f) | Target: %s | Queued WPs: %d | Route Stops: %d | Direction: %s | Idle: %ds | Pilot: %s",
                count, plane_id, is_obj_live, string.upper(state), pos.x, pos.y, pos.z, tw_str, wps_count, route_count, (p.route_direction or "forward"), idle, pilot)
            table.insert(lines, entry)
        end

        if count == 0 then
            table.insert(lines, "  No active airliners currently tracked in the world.")
        end
        table.insert(lines, "============================================================\n")

        -- Write directly to the general game debug.txt via Minetest logging engine
        for _, line in ipairs(lines) do
            core.log("none", "[Airliner] " .. line)
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
            set_aircraft_rotation(obj, 0, yaw, 0)

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

    -- 1. Check local in-memory objects
    for _, obj in pairs(core.object_refs) do
        local ent = airliner.get_airliner(obj)
        if ent then
            local is_owner = (ent.owner == name or ent.owner == nil or ent.owner == "" or core.check_player_privs(name, {protection_bypass = true}))
            if is_owner and obj:get_pos() then
                local dist = vector.distance(p_pos, obj:get_pos())
                if dist < min_dist then
                    min_dist = dist
                    nearest = ent
                end
            end
        end
    end

    if nearest then return nearest end

    -- 2. Check tracked planes globally (even if object is far away / in remote mapblock)
    for _, plane_info in pairs(airliner.tracked_planes) do
        local is_owner = (plane_info.owner == name or plane_info.owner == nil or plane_info.owner == "" or core.check_player_privs(name, {protection_bypass = true}))
        if is_owner then
            if plane_info.object and plane_info.object.get_pos and plane_info.object:get_pos() then
                local ent = airliner.get_airliner(plane_info.object)
                if ent then return ent end
            end
            return plane_info
        end
    end

    -- 3. Fallback to any tracked plane in singleplayer
    for _, plane_info in pairs(airliner.tracked_planes) do
        if plane_info.object and plane_info.object.get_pos and plane_info.object:get_pos() then
            local ent = airliner.get_airliner(plane_info.object)
            if ent then return ent end
        end
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
            set_aircraft_rotation(obj, 0, player:get_look_horizontal(), 0)
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
        local obj = ent.object or (ent.id and airliner.tracked_planes[ent.id] and airliner.tracked_planes[ent.id].object)
        if obj then
            airliner.add_waypoint(obj, pos, "WP (" .. pos.x .. "," .. pos.z .. ")")
        elseif ent.waypoints then
            table.insert(ent.waypoints, {x = pos.x, y = pos.y, z = pos.z, name = "WP (" .. pos.x .. "," .. pos.z .. ")"})
        end
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
        local obj = ent.object or (ent.id and airliner.tracked_planes[ent.id] and airliner.tracked_planes[ent.id].object)
        if obj then
            airliner.add_waypoint(obj, p_pos, "Player Location")
        elseif ent.waypoints then
            table.insert(ent.waypoints, {x = p_pos.x, y = p_pos.y, z = p_pos.z, name = "Player Location"})
        end
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
        local obj = ent.object or (ent.id and airliner.tracked_planes[ent.id] and airliner.tracked_planes[ent.id].object)
        if obj then
            airliner.add_waypoint(obj, {x = b.x, y = b.y, z = b.z}, b.name)
        elseif ent.waypoints then
            table.insert(ent.waypoints, {x = b.x, y = b.y, z = b.z, name = b.name})
        end
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
        if #(ent.waypoints or {}) == 0 then
            msg = msg .. "  No waypoints currently queued in airliner.\n"
        else
            for i, wp in ipairs(ent.waypoints) do
                local wname = wp.name or ("Waypoint #" .. i)
                msg = msg .. "  " .. i .. ". " .. wname .. " -> (" .. wp.x .. ", " .. wp.y .. ", " .. wp.z .. ")\n"
            end
        end
        if #(ent.full_route or {}) >= 2 then
            msg = msg .. "Full Shuttle Route: " .. #ent.full_route .. " stops (" .. (ent.route_direction or "forward") .. ")\n"
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

        local obj = ent.object or (ent.id and airliner.tracked_planes[ent.id] and airliner.tracked_planes[ent.id].object)
        if obj then
            airliner.clear_waypoints(obj)
        else
            ent.waypoints = {}
            ent.full_route = {}
            ent.target_waypoint = nil
        end
        return true, "Waypoints and shuttle route cleared."
    end
})

core.register_chatcommand("airliner_stop", {
    description = "Forces the airliner into a safe landing descent.",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        local obj = ent.object or (ent.id and airliner.tracked_planes[ent.id] and airliner.tracked_planes[ent.id].object)
        if obj then
            airliner.stop(obj)
        end
        return true, "Airliner landing initiated."
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
        if ent.id then airliner.tracked_planes[ent.id] = nil end
        if ent.forceloaded_pos then core.forceload_free_block(ent.forceloaded_pos, true) end
        if ent.forceloaded_dest then core.forceload_free_block(ent.forceloaded_dest, true) end
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

        local plane_id = ent.plane_id or ent.id
        local pos = (ent.object and ent.object.get_pos and ent.object:get_pos()) or ent.pos
        if not pos and plane_id and airliner.tracked_planes[plane_id] then
            pos = airliner.tracked_planes[plane_id].pos
        end

        if pos then
            core.forceload_block(pos, true)
            if plane_id then
                airliner.materialize_entity(plane_id)
            end
            player:set_pos({x = pos.x, y = pos.y + 2, z = pos.z})
            return true, "Teleported to airliner at (" .. math.floor(pos.x) .. ", " .. math.floor(pos.y) .. ", " .. math.floor(pos.z) .. ")."
        end
        return false, "Could not determine airliner location."
    end
})

core.register_chatcommand("airliner_kill_all", {
    description = "Removes all airliner entities in the world and invalidates all past planes.",
    func = function(name, param)
        local count = 0
        local now = os.time()
        global_kill_epoch = now
        if mod_storage and mod_storage.set_int then
            mod_storage:set_int("kill_epoch", now)
        end

        for _, obj in pairs(core.object_refs) do
            local ent = airliner.get_airliner(obj)
            if ent then
                if ent.pilot then airliner.detach(ent.pilot, true) end
                if ent.passengers then
                    for i = #ent.passengers, 1, -1 do
                        airliner.detach(ent.passengers[i], true)
                    end
                end
                if ent.forceloaded_pos then core.forceload_free_block(ent.forceloaded_pos, true) end
                if ent.forceloaded_dest then core.forceload_free_block(ent.forceloaded_dest, true) end
                obj:remove()
                count = count + 1
            end
        end
        for plane_id, p in pairs(airliner.tracked_planes) do
            if p.object and p.object.get_pos and p.object:get_pos() then
                p.object:remove()
                count = count + 1
            end
        end
        airliner.tracked_planes = {}
        return true, "Cleaned up all airliners in world (Kill Epoch: " .. now .. ")."
    end
})

core.register_chatcommand("airliner_status", {
    description = "Shows the status and waypoints of the nearest owned airliner.",
    func = function(name, param)
        local ent = find_owned_airliner(name)
        if not ent then return false, "No owned airliner found." end

        local pos = (ent.object and ent.object.get_pos and ent.object:get_pos()) or ent.pos or {x = 0, y = 0, z = 0}
        local state = ent.state or "UNKNOWN"
        local msg = "State: " .. string.upper(state)
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
        if (state == "arrived" or state == "ground") and not has_players and #(ent.full_route or {}) >= 2 then
            local remaining = math.max(0, math.floor(IDLE_TIMEOUT - (ent.idle_timer or 0)))
            msg = msg .. "\nAuto-depart in: " .. remaining .. "s"
        end
        if state == "stuck" then
            msg = msg .. "\n[WARNING] Aircraft is currently obstructed/stuck on landing. Right-click to dismount safely."
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