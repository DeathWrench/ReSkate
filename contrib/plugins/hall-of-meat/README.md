# Hall of Meat (plugin)

skate. 3's Hall of Meat for skate., as a sandboxed Luau plugin: when you bail, the bones you hurt show
through your skater, yellow where a hit bruised one and red where one broke it, with the bail's Meat
card in the bottom left corner. It ships no game data: the skeleton (the Dem Bones costume's mesh),
the card's icons, the THRASHER wordmark and the brush strokes are read from the installed game by
ReSkate.

## What it does

- **The skeleton.** From the first hurt bone until you are back on your feet, then it fades out. A fall
  that hurts nothing shows nothing. A fresh hit flashes the bone it hit.
- **The card.** It takes the place of skate.'s own HUD in that corner (the d-pad and the score HUD come
  back after). Time, hits (head hits count double, hits from vehicles half again), broken bones, road
  rash, airtime, fall, top speed and rotations, each with its points, then the Meat. Small stats join
  the card once they are worth showing. Each map keeps its best Meat (**NEW BEST** / **BEST 12,345**).
- **A break.** The screen's edges pulse red and, in single player only, the game slows down for a
  moment. ReSkate never slows the game in a multiplayer session.

On once installed: switch it on or off on its page in the ReSkate menu's PLUGINS section, or with the
console (`~`): `hallofmeat 0|1`; `hallofmeat` on its own says this map's best and the last bail.
`hallofmeat test` runs the plugin's own checks. With No Bail on, a wipeout No Bail stops is not a bail,
so nothing shows.

## How it works

- `plugin/model.lua`: the bail's phases (riding, bailing, down, getting up) and its Meat, fed every
  physics step of the local skater (the `physics_step` event: what each body hit and how hard, how it
  moves, whether it is a ragdoll), on the game's clock.
- `plugin/card.lua`: the card's rows.
- `plugin/draw.lua`: the x-ray (`reskate.skater.xray`, `d:skeleton`), the red edge (`d:gradient`) and
  the card (`d:game_image`, skate.'s own pictures).
- `plugin/main.lua`: the wiring to `reskate`, skate.'s HUD corner hidden while the card shows
  (`reskate.hud.corner`), the slow motion (`reskate.time.slow`), each map's best (`reskate.storage`),
  the console command and its page in the menu's PLUGINS section.

ReSkate keeps what has to run in the game itself: the skater's physics steps
(`Extension/Skater/skater_physics.h`), the x-ray's renderer hooks and skeleton mesh
(`Extension/Skater/xray.h`), the HUD corner (`Extension/UI/hud_corner.h`) and the slow motion
(`Extension/Skater/game_speed.h`).

The skater's render hooks, its skeleton and its body maps were first found by
[gBGYo's ReSkate fork](https://github.com/gBGYo/ReSkate).
