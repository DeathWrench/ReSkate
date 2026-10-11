# Board Break

A hard slam can break the local skater's board: at the nose, in the middle or at the tail. Half the
time the grip tape holds the pieces together and the board folds or an end hangs; otherwise a piece
comes off, flies and lies where it lands, truck and wheels with it. The board is whole again once
the skater has picked it up, rides again or respawns. Built into ReSkate; the broken pieces
themselves come from content mods, one for each deck shape.

Code: [board_break.cpp](../Extension/BoardBreak/board_break.cpp) (client tick and the boards'
render pose hook), [board_break_model.h](../Extension/BoardBreak/board_break_model.h) (the rules and
the geometry on their own, with [tests](../Extension/BoardBreak/Test/board_break_tests.cpp)),
[board_break_commands.cpp](../Extension/BoardBreak/board_break_commands.cpp) (console), and the
deck's place in the mod list in [mod_catalog.cpp](../Engine/Vfs/mod_catalog.cpp).

## What the player gets

- A slam of force 10 or more always breaks the board, a lighter one a quarter of the time, rising
  in between (the force is the bail cause's that led to the wipeout). Now and then a board gives way
  while it is ridden: the nose goes.
- `boardbreak 0|1`, `boardbreak deck [name|number|next]`, `boardbreak snap [nose|mid|tail]` to look
  at a break (that one stays until `boardbreak mend` or a respawn). The switch and the deck are in
  the menus beside Road Rash (Mod Options > Player, and the overlay's Skater page). The switch is
  saved with the profile.
- A break plays back in the replay editor as it happened.
- Without a deck pack installed nothing breaks and nothing is changed.

## How it works

- **One deck model.** Every board in the game draws the same deck mesh
  (`characters/skateboard/unlicensed/deck/generic/popsicle/2022/deck_gen_popsicle_mesh`); deck
  graphics and grip tapes are items on top of it, and an item cannot bring a mesh of its own. So a
  breakable deck is a content mod that replaces that mesh: the same deck, plus four stretches of it
  (nose, front, back, tail) cut along three rows of vertices the deck already has, each rigidly
  skinned to a bone of the board's rig that the game does not use (Trajectory, Connect, Ground, and
  Connect2 for the tail, which hangs on Connect).
- **Only bones move.** `board_render_pose` (the hook multiplayer already has for other players'
  boards) runs after a board's pose has been handed to the renderer, which is the one moment a
  change to the pose is still drawn and not yet rewritten: the board's animation writes every bone
  again every frame. A broken board gets its Deck bone moved 2 km down, the trucks (which hang on
  it) moved back by as much, and each stretch moved to where its piece lies. The piece that came
  off is flown by the hook itself, from the board's place at the break: a kick, gravity, the
  ground, and written relative to wherever the board is in each frame.
- **Nothing is scaled.** The first version shrank the deck and scaled the stretches up. The game's
  replay records where a bone is and how it is turned, and not its size: a shrunk deck played back
  as a small whole board, and stretches that were scaled up not at all. Moves play back exactly.
- **Whole boards hide their stretches too.** The deck is a hollow shell (the wood has no top face,
  the grip is a sheet over it), and the game draws wood and grip as layers that do not hide what
  lies just under them: stretches left inside a whole deck showed as cracks through the grip,
  fainter the deeper they lay and never gone (tried down to 4 mm). So every frame, on every board
  that passes the hook (the local one, other players'), the stretches of a whole board are moved
  away like a broken board's deck. The call into Board Break is the last thing the hook does, after
  another player's pose has been written, so that pose's bones do not bring them back.
- **Which deck is in the game** is a question for the mod list, because any mod that reshapes the
  deck replaces the same mesh and the one higher in the order has it. When the mods are put
  together, the Board Break deck the player chose goes first, and what would fight it is set
  aside for the run: the other Board Break decks, and other mods whose bundle lists name the
  deck's bundle. Those are left out whole (with the breakable deck in place of its own, a wide-deck
  mod has its trucks and wheels on a deck they were not made for). mods.json is not changed; the
  mod list shows them as SET ASIDE.
- **Another deck without a restart.** The deck mesh is in the items superbundle, which a live apply
  of the mods already refreshes, and the game reads the mesh when a level loads. Choosing a deck
  saves the choice, applies the mods and loads the level again (live_mods.h).
- **The choice** is a line in `%LOCALAPPDATA%\ReSkate\BoardBreak.deck`, not a profile preference:
  the mods are put together before the profile is there.
- **The sound** is a wave file from the `sounds` folder of an installed deck pack (subfolders
  `light`, `medium`, `heavy`, by the size of the break), played straight to the speakers.
- **The slam's force** comes through No Bail's existing hooks: the cause it records for the watched
  skater, and the cause collector at the moment the selector chooses Wipeout. Nothing new is hooked.
- **On foot the grip tape always holds.** A loose piece takes the ground from where the board
  rolled or lies; a board in the skater's hand does not tell where the ground is, and a piece that
  came off there hung in the air at hand height.
- Off, the board holds. Without a deck pack in the game the hook returns at once.

## The deck packs

A content mod (no code) in a folder named `Board_Break_<Name>`; the name is what the deck goes by.
The eight the feature was made with are standard, wide, concave, powell, slim, egg, square and
shaped, and the console also knows those by number. Any other pack that follows the recipe works,
with no change to ReSkate:

- Start from the deck mesh as ReSkate Studio exports it (three parts on the bone Deck: the grip
  sheet, the wood, and a plain copy of the whole deck). Studio only takes back a mesh whose
  triangles are the donor's own, so a shape is made by moving vertices, never by adding any. Keep
  every vertex where it is along the board: the break rows (z = 0.260, 0.009 and -0.260 m) and the
  truck bolts stay put.
- For each of the four stretches, append a copy of every part's vertices and triangles, skinned to
  that stretch's bone, with every vertex on the far side of its break rows folded onto the row's
  cross-section (top skin onto its top line, bottom skin onto its bottom line). That leaves the
  deck's own edge faces standing in the gap as the broken end. Push the row itself along the board
  by a jagged line, the same line for both sides of a break, so the pieces fit together.
- Build the stretches at their own size, in the place they have in the whole deck.
- The standard deck's pack also carries `sounds/light|medium|heavy/*.wav`.

## Seen working in game

Offline, on main at f4292d6, with eight deck packs installed: breaks from real slams at the nose,
in the middle and at the tail, clean and held by the grip, the board whole again in hand and on
respawn; breaks from the console on foot (folded, nose and tail hanging) that stay until mended.
The grip side of a whole board, close up in the board menu, shows no cracks. A deck chosen while
the game runs is the one in the board menu and in the world after the level has loaded again
(about 20 s), and the one the next launch starts with. With a wide-deck mod switched on and first
in the order, the breakable deck is still the one in the game and the mod is set aside; so is an
older deck mod of Board Break's own. The mod list shows the decks that are set aside as such, with
nothing waiting to be applied. The switch on the overlay's Skater page turns it off and on. On the
older build the feature was developed on, a middle break played back in the replay editor.

## Not tried yet

- Multiplayer: other players' boards are only handled by the code path (their stretches are moved
  away), not seen; what peers see of a broken board, with and without the packs.
- The online route: all of the above ran on the offline profile.
- The replay editor on this branch (the replay was checked on the older build the feature was
  developed on).
- The rows in Mod Options > Player in the game itself (their view has a test; the overlay's switch
  was used).
- A level change in the middle of a break.
