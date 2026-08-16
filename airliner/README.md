# Airliner Mod

An attachable self-flying airliner with takeoff and waypoint landing capabilities for Luanti / Minetest.

## Airutils Decision
**airutils is not required.**
This mod implements a controllable airliner entity with its own independent waypoint, takeoff, landing, and attachment systems using direct Luanti entity APIs. `airutils` is generally suited for airport props and shared vehicle helpers, which is beyond the scope of this standalone mod.

## Installation
1. Clone or copy the `airliner` folder into your world's or server's `worldmods/` or `mods/` directory.
2. Enable the mod in your world settings.

## Spawning the Airliner
- Using the item: You can obtain the "Airliner Spawner" from your inventory or by giving it to yourself. Place it on top of a node to spawn the airliner above it.
- Using commands: Type `/airliner_spawn` in the chat to spawn an airliner directly in front of you.

## Attaching as a Pilot
Right-click the airliner when it is grounded (parked). You will be attached as the pilot. The first person to attach (or spawn) the airliner will be set as its owner.

## Flying and Waypoints
To make the airliner take off, press `E` (or `AUX1`) while attached as the pilot, provided the airliner is grounded.

Before taking off, you should add waypoints for the airliner to follow. A waypoint is treated as a landing destination. When multiple waypoints exist, each takeoff consumes the next waypoint in the queue.

To set waypoints:
- Use `/airliner_waypoint x,y,z` to set a waypoint at specific coordinates.
- Use `/airliner_waypoint_here` to set a waypoint exactly where you are standing.

Once the airliner takes off, it climbs to a safe altitude, cruises towards its target, and descends when nearing the waypoint to touch down at the coordinate.

*Note on detaching:* You cannot detach while the airliner is in mid-air flying. The mod restricts this for safety and immersion. You must wait until it lands safely before being allowed to right-click again to detach. Furthermore, boarding is disallowed while the airliner is active.

## Chat Commands
- `/airliner_spawn` - Spawns an airliner in front of the player.
- `/airliner_waypoint x,y,z` - Adds a waypoint to the attached or nearest owned airliner.
- `/airliner_waypoint_here` - Adds the player's current position as a waypoint.
- `/airliner_clear` - Clears waypoints and current target.
- `/airliner_stop` - Stops the airliner safely. If flying, it forces a landing straight down.
- `/airliner_remove` - Removes the attached or nearest owned airliner.

## Modifying Properties
If you'd like to adjust scale, speed, or the collision box:
- **Speed**: Modify `CRUISE_SPEED` and `CLIMB_SPEED` constants at the top of `init.lua`.
- **Scale/Visual Size**: Adjust the `visual_size = {x = 1, y = 1, z = 1}` property inside `core.register_entity("airliner:airliner", ...)`.
- **Collision**: Adjust the `collisionbox` and `selectionbox` fields in the same entity registration.

## Public API Example
```lua
local pos = {x = 0, y = 5, z = 0}
local obj = airliner.spawn(pos, "alice")

airliner.add_waypoint(obj, {x = 100, y = 10, z = 0})
airliner.add_waypoint(obj, {x = 200, y = 12, z = 100})

local player = core.get_player_by_name("alice")
if player then
    airliner.attach(player, obj, {x = 0, y = 10, z = 0})
end
```

## License
All code is provided under the MIT License.
All generated textures and resources are provided under CC0 (Public Domain).
