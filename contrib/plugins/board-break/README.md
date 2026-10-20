# Board Break (plugin)

ReSkate's Board Break as a sandboxed Luau plugin, to ship inside the
`Fourth_Studio-Board_Break_Pack` deck pack. A hard slam, or a hard boardslide or darkslide onto a
rail, can snap the local skater's board at the nose, in the middle or at the tail. Boards wear out
with every hit and break more easily as they do. The board is whole (and new) again once the skater
has picked it up, rides again or respawns.

The pieces are the pack's: each deck has four stretches (nose, front, back, tail) on spare bones
12 to 15 of the board's rig. The plugin only moves bones with `reskate.board`, and plays the pack's
`sounds/light|medium|heavy|body/*.wav` (a crack size with no folder of its own takes the nearest
size that has one, or the wave files in `sounds/` itself; at most 6 of each are used).

- `plugin/model.lua`: where a board breaks, what is left of it, and where each part lies.
- `plugin/feel.lua`: the settings, the chances, wear, the contact type on a rail.
- `plugin/breaker.lua`: the rules at play (breaks, mending, wear, drawing), with the game passed
  in, so `plugin/tests.lua` can run them against a fake one.
- `plugin/main.lua`: the wiring to `reskate`, the deck, the console command and its page in the menu's
  PLUGINS section.

## The decks

The game has one deck model for every board, so the pack's decks are variants of it:
`reskate-plugin.json` declares `decks/<name>/` as its `variants`, and the merge loads the one chosen
(the first of its `order` when none is) and sets aside every other mod that brings a deck model.
The plugin picks the deck with `reskate.package.choose` (its page, or `boardbreak deck`), reads each
deck's `deck.ini` (`label`, `axle`) and fits every board for the deck in the game with
`reskate.board.fit`: the baseplates held on the deck and the wheels as far apart as its trucks.

## Install

Copy `reskate-plugin.json` and `plugin/` into the pack's folder in `Mods`, beside its `sounds/`.

## Console

`boardbreak`, or `board break` while ReSkate still has a Board Break of its own:
`0|1`, `status`, `deck [name|number|next]` (the list, or a deck to put in the game), `snap [nose|mid|tail]` (to look at a break: it stays until `mend` or a respawn),
`mend`, `new` (a new board), `worn [percent]`, `test` (its own checks), and the settings
`always`, `sensitivity`, `joined`, `rails`, `wear`, `wearrate`, `cracks`, `bodysounds`, each with
a value to set it or none to read it. The same is on its page in the ReSkate menu's PLUGINS section.

## What it leaves out

What the plugin API cannot do yet:

- Physics tuning by wear (a worn board's softer trucks and lazier turn).
- One wear for the board, not one per deck.
- Material detection: no metal sound for a board that breaks on metal, no `metal` or `materials`
  commands.
- Multiplayer: other players do not see a broken board.
- A new board's scratches: the game's own board wear is not reset with the break.

How it differs from ReSkate's Board Break, where the API made it so:

- A piece that comes off flies without its truck (the truck is hidden): `board.toss` writes bones
  relative to the board's place, and a truck hangs on the deck's bone.
- While the back half of a board broken in the middle flies, the front half it leaves stays level
  on its truck instead of tipping onto its broken end: the tail's bone hangs on the front
  stretch's, and tipping the front would drag the flying tail with it.
- The real deck goes 950 m down rather than 2000 m: `board.set` takes a bone at most 1000 m from
  its parent, and the trucks, which hang on the deck, come back up by as much.
- A flying piece lands on one ground found as it breaks (where the board rolled a moment before,
  else a ray down from the board), instead of following the board's height as it settles.
