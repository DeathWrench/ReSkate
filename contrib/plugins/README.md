# Test plugins

Two plugins that check ReSkate's plugin host (`Extension/Plugins`). To try one in game, copy its
folder into the game's `Mods` folder and open the console.

- **reskate-test** calls every plugin API and says what worked. `ptest all` runs every check,
  `ptest <module>` one module, and `ptest list` names them. It prints only the failures and a
  summary line. Each API ReSkate adds gets a module in `plugin/checks/`. It's also the example to
  copy when making a plugin.
- **reskate-hostile** attacks the sandbox on purpose, one attack per command. `hostile list` names
  them with what should happen. An attack that gets it stopped is expected: `plugin on
  reskate-hostile` starts it again for the next one. Any line starting with `ESCAPED` is a hole in
  the sandbox.

Both also run without the game, in `dingosdk_plugin_tests` (`DINGOSDK_BUILD_PLUGIN_TESTS`).

## Ports

Features that were built into ReSkate, as mods of their own (or, where a feature has an asset mod,
inside that mod). Each has its own checks (`<command>
test`) that `dingosdk_plugin_tests` runs too, and its own page in the ReSkate menu's PLUGINS section.

- **road-rash**: bails leave marks that build up, worn over the outfit with `reskate.outfit`. It
  ships inside the Road Rash item pack, whose items it wears. `roadrash`, `roadrash heal`,
  `roadrash bails 20`.
- **board-break**: a hard slam can snap the board, drawn with `reskate.board`. It ships inside the
  Board Break deck pack, whose decks its manifest declares as variants (one in the game at a time).
  `boardbreak`, `boardbreak deck wide`, `boardbreak snap mid`.
- **fpv-drone**: the FPV drone, flown from the free camera with the keyboard, a pad or a radio.
  `fpv fly`, `fpv follow`.
- **hall-of-meat**: skate. 3's Hall of Meat: bails show the bones they hurt on an x-ray of the
  skater (`reskate.skater.xray`, `d:skeleton`) and score a Meat card drawn with skate.'s own
  pictures (`d:game_image`). `hallofmeat 0|1`.
- **grind-exits**: LT / RT in a grind pick the side of the pop (`reskate.skater.grind_exit`,
  `reskate.input.hide`). `grindexit status`.

## Throwdown modes

Throwdown modes made in Lua with the throwdown kit ([throwdown-kit.md](../throwdown-kit.md)): the
plugin registers its modes and publishes what the player should see; ReSkate shows it with skate.'s
native Throwdowns page, setup page, flag, HUD and match panel.

- **throwdown-modes-test**: two modes through the whole native flow (card, setup page, flag,
  waiting card) and no match. The smallest example of the kit.
- **SmokeyDawg58-ReSkate_Throwdown**: SmokeyDawg58's ten modes, with their rules, HUDs, gates and
  route editor, all in Lua, inside his asset mod. `tdm help`.
