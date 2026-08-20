# Airliner Mod

An attachable self-flying airliner with waypoint navigation, airport beacon tracking, Flight Computer GUI, natural 100-block takeoff & landing glide slopes, and automatic shuttle loop for Luanti / Minetest.

## Features
- **High-Speed Long-Distance Airline Flight**: Cruises smoothly across thousands of nodes at 50 m/s at a safe cruising altitude.
- **Natural 100-Block Takeoff**: Rolls 25 nodes down the runway, rotates, and smoothly climbs to cruising altitude over 100 blocks with pitch-up aircraft attitude.
- **Pre-Flight Runway Clearance Check**: Scans the 100-block takeoff corridor for trees, structures, or terrain obstacles; alerts the pilot with `"Runway blocked"` if the path is obstructed.
- **Natural 100-Block Landing Glide Slope**: Transitions into a gentle 100-block descent glide slope, flares before touchdown, and rolls to a smooth halt on the runway.
- **Landing Stuck & Obstruction Recovery**: Detects if the airliner hangs or gets obstructed on landing, alerting players with emergency dismount enabled so they can exit safely onto solid ground.
- **Single-Machine Shuttle Loop**: Reverses route after 5 minutes idle and flies back cleanly as a single aircraft without entity duplication.
- **Airport Waypoint Beacons**: Placeable beacon nodes that act as named airport / runway destinations.
- **Interactive Flight Computer GUI**: Shift + Right-Click a parked airliner (or use `/airliner_gui`) to view route, select beacons from a dropdown, add coordinates, or launch.
- **100 HP & Pickaxe Removable**: Aircraft can be punched or dug with pickaxes to take damage (100 HP total), dropping the spawner item upon destruction.

## Installation
1. Clone or copy the `airliner` folder into your world's or server's `worldmods/` or `mods/` directory.
2. Enable the mod in your world settings.

## Spawning the Airliner
- **Item**: Place the "Airliner Spawner" on top of a solid block.
- **Command**: Type `/airliner_spawn` in chat.

## Setting Up Airline Routes

### Method 1: Using Waypoint Beacons (Recommended)
1. Place a **Waypoint Beacon** (`airliner:waypoint_beacon`) at Airport A (origin runway) and Airport B (destination runway).
2. Right-click the beacon to name it (e.g. "Main Terminal", "Island Airport").
3. Shift + Right-Click the airliner to open the **Flight Computer** and select your beacon from the dropdown, or the airliner will automatically detect placed beacons when taking off.

### Method 2: Using Chat Commands
- `/airliner_waypoint x,y,z` - Adds a waypoint at specific coordinates.
- `/airliner_waypoint_here` - Adds your current position as a waypoint.
- `/airliner_beacon <name>` - Adds a named beacon to the flight plan.

## Flying and Takeoff
- **Boarding**: Right-click the airliner when grounded to board as the Pilot. Passengers can also right-click to board (up to 10 players total).
- **Takeoff**: Press `E` (or `AUX1`) while seated as Pilot, or click **Takeoff** in the Flight Computer. Takeoff will automatically verify that the 100-block runway corridor is clear.
- **Dismount**: Right-click when the airliner has landed or if stuck to dismount safely.

## Chat Commands
- `/airliner_gui` - Opens the Flight Computer GUI.
- `/airliner_beacons` - Lists all registered airport beacons in the world.
- `/airliner_waypoint x,y,z` - Adds a waypoint coordinate.
- `/airliner_waypoint_here` - Adds player position as a waypoint.
- `/airliner_beacon <name>` - Adds a registered beacon by name.
- `/airliner_clear` - Clears the current route.
- `/airliner_status` - Displays state, coordinates, queued stops, and auto-depart countdown.
- `/airliner_tp` - Teleports you directly to your airliner.
- `/airliner_stop` - Forces a safe landing glide slope descent.
- `/airliner_remove` - Removes the nearest airliner.
- `/airliner_kill_all` - Removes all airliners in the world.

## Crafting Recipes
- **Airliner Spawner**: 5 Steel Ingots + 2 Glass blocks.
- **Waypoint Beacon**: 4 Steel Ingots + 2 Glass + 1 Torch.

## License
All code is provided under the MIT License.
All textures and models are provided under CC0 (Public Domain).
