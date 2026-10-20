# Road Rash (plugin)

ReSkate's Road Rash as a sandboxed Luau plugin, to ship inside the `Fourth_Studio-Road_Rash` item
pack. Bails leave marks on the local skater that build up over a session: road dust and grazes,
then scrapes and bruises, and raw wounds and a bruised face, on the side that took more of them
first. A mark never gets smaller until the skater is healed (`roadrash heal`) or the game is closed.

The marks are the pack's skin items (`plugin/rules.lua` has their names), worn over the outfit with
`reskate.outfit`. A slot that holds one of the player's own tattoos or moles keeps it, unless the
player lets the wounds cover it.

- `plugin/rules.lua`: how bails build up into marks, and which item each mark is.
- `plugin/main.lua`: the wiring to `reskate`, the console command and its page in the menu's
  PLUGINS section.
- `plugin/tests.lua`: the rules' own checks (`roadrash test`).

## Install

Copy `reskate-plugin.json` and `plugin/` into the pack's folder in `Mods`, beside its `Win32/` and
`layout.toc`. The pack's `manifest.json` is the mod's.

## Console

`roadrash`, or `road rash` while ReSkate still has a Road Rash of its own: `0|1`, `heal`,
`bails <count>`, `blood 0|1`, `tattoos 0|1`, `test`. The same is on its page in the ReSkate menu's
PLUGINS section.
