# Dual Stick (plugin)

The settings of GoalTrains' [Dual Stick Controls](https://github.com/GoalTrains/reskatedualstick)
companion on a page in the ReSkate menu's PLUGINS section, made from GoalTrains' pull request 254.
The companion translates Skate's controls across two sticks; this plugin does not. It only edits
the companion's `session_controls.ini`, which the companion reads every two seconds.

- `plugin/controls.lua`: the companion's settings: the Session-style and XL-style presets, the five
  custom slots shared with the companion's own menu, stance, stick layout, steering angle, stock ramp
  controls, the startup choice and the other settings, with the companion's keys and fallbacks.
- `plugin/ini.lua`: the file as Windows' private profile functions read it. Every line the plugin does
  not change is written back as it was, unknown keys and other sections included.
- `plugin/main.lua`: the page and the console command `dualstick` (`status`, `preset session|xl`,
  `load <slot>`, `save <slot>`, `test`).
- `plugin/tests.lua`: its checks (`dualstick test`), which ReSkate's plugin tests run too.

## Install

Copy this folder into the game's `Mods` folder. It needs the companion, in a version that keeps its
settings where a plugin can reach them (below). Without the file the page says so and creates nothing.

## Where the settings are

A plugin can write only to its own data folder:

```
<game folder>\Mods\.reskate_plugin_data\<this mod's folder>\session_controls.ini
```

The folder name is the mod's: `dual-stick` here, or the package's folder name once it is installed
from Thunderstore. The companion keeps its INI beside `Skate.exe` today, which no plugin can reach.

## For the companion

What the companion needs to change, so the page and the companion share one file:

1. Look for `Mods\.reskate_plugin_data\*\session_controls.ini` beside `Skate.exe` (each folder in
   there is one plugin's; skip names ending in `@server`). Use the one there when there is one.
2. When there is none, but the plugin's folder is installed (a `Mods\<folder>\reskate-plugin.json` of
   this plugin), copy the INI from beside `Skate.exe` into `Mods\.reskate_plugin_data\<folder>\` once,
   and use that from then on. Players keep their settings and their custom slots.
3. Otherwise go on with the INI beside `Skate.exe`, as now.

ReSkate.dll also exports `ReSkateOverlayOwnsInputV1` (`unsigned long WINAPI (void)`): 1 while
ReSkate's menu, a free camera on the pad or a prompt has the input, else 0. It keeps the caller's
last error. The companion can hold its generated gestures back while it is 1.

## What it leaves out

- The tab in the game's own Mod Options page (pull request 254 had one). Plugins have no way to add
  rows there yet; the page is in the ReSkate menu's PLUGINS section.
- Toggling the running translator: use the companion's own menu (End by default). The page's
  "Dual Stick on next launch" sets the startup choice only, as the pull request's did.
