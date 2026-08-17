# Airliner Mod

An attachable self-flying airliner with waypoint navigation, airport beacon tracking, Flight Computer GUI, and automatic shuttle loop for Luanti / Minetest.

## Features
- **High-Speed Long-Distance Airline Flight**: Cruises smoothly across thousands of nodes at 50 m/s at a safe cruising altitude.
- **Airport Waypoint Beacons**: Placeable beacon nodes that act as named airport / runway destinations.
- **Interactive Flight Computer GUI**: Shift + Right-Click a parked airliner (or use `/airliner_gui`) to view route, select beacons from a dropdown, add coordinates, or launch.
- **High-Precision Vertical Landing**: Approaches destinations at cruising altitude, aligns directly above the target (X, Z), and touches down gently onto the runway/beacon.
- **Auto-Return Shuttle Loop**: If parked at a destination for 5 minutes without passengers, the airliner automatically takes off, reverses its route, and flies back to origin.
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
- **Takeoff**: Press `E` (or `AUX1`) while seated as Pilot, or click **Takeoff** in the Flight Computer.
- **Dismount**: Right-click when the airliner has landed safely to dismount.

## Chat Commands
- `/airliner_gui` - Opens the Flight Computer GUI.
- `/airliner_beacons` - Lists all registered airport beacons in the world.
- `/airliner_waypoint x,y,z` - Adds a waypoint coordinate.
- `/airliner_waypoint_here` - Adds player position as a waypoint.
- `/airliner_beacon <name>` - Adds a registered beacon by name.
- `/airliner_clear` - Clears the current route.
- `/airliner_status` - Displays state, coordinates, queued stops, and auto-depart countdown.
- `/airliner_tp` - Teleports you directly to your airliner.
- `/airliner_stop` - Forces a safe landing straight down.
- `/airliner_remove` - Removes the nearest airliner.
- `/airliner_kill_all` - Removes all airliners in the world (useful to clean up old test planes).

## Crafting Recipes
- **Airliner Spawner**: 5 Steel Ingots + 2 Glass blocks.
- **Waypoint Beacon**: 4 Steel Ingots + 2 Glass + 1 Torch.

## License
All code is provided under the MIT License.
All textures and models are provided under CC0 (Public Domain).
