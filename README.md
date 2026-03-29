# Immersive Turtle WoW

A UI-hiding addon for WoW 1.12.1 (Turtle WoW) that fades away interface elements when you don't need them, creating a cleaner and more immersive gameplay experience.

## Features

**Smart UI Fading**
- UI automatically fades out when not in use
- Smooth fade animations (configurable speed)
- Full UI toggle with a keybind

**Combat Awareness**
- UI automatically appears during combat
- Configurable delay before fading back out after combat ends
- Optional: show quest tracker and extra action bars during combat

**Dialogue & Vendor Integration**
- UI auto-fades when talking to NPCs, opening quests, or browsing vendors/bankers
- UI returns when dialogue closes

**Minimap Control**
- Minimap auto-hides after a configurable delay
- Toggle minimap visibility independently

**Settings Panel**
- Minimap button to open settings
- Configure fade speed, combat delay, minimap hide delay
- Toggle combat quest tracker, auto-fade on dialogue, auto-fade on vendor
- All settings saved between sessions

## Installation

1. Download or clone this repository
2. Place the `ImmersiveTurtleWoW` folder into your `Interface/AddOns/` directory
3. Restart WoW or type `/reload`

**For GitAddonsManager:** paste the clone URL and it handles the rest.

## Slash Commands

- `/fadeui` - Toggle full UI visibility
- `/fadeui minimap` - Toggle minimap
- `/fadeui settings` - Open settings panel

## Keybindings

Set keybinds in WoW's Key Bindings menu:
- **Toggle Full UI** - Show/hide all UI elements
- **Toggle Minimap** - Show/hide the minimap

## Compatibility

- **Turtle WoW:** Full support
- **Other 1.12.1 servers:** Should work (standard 1.12 API only)
- **WoW Classic (Blizzard):** Not compatible (different client)
