# Rock to Fakie (plugin)

TheRealEJR's [Rock to Fakie](https://github.com/TheRealEJR/ReSkate-Rock-to-Fakie-mod) as a
sandboxed Luau plugin, from his pull request 285. skate. has no button for a rock to fakie, but the
move is in the game: ride up to a coping, Board Stall or Lip Stall on it, and press **B** (Circle on
a PlayStation pad) to roll back in fakie. With this on, the game calls it what it is:

- **The trick ticker** shows Rock to Fakie for a Board Stall or a Lip Stall while the skater holds
  it (`reskate.tricks.label`). A BS / FS prefix the ticker adds is the game's and stays.
- **A stall left with B** is recorded as the game's own `fakie_rock` (trick 187) instead of the stall
  (9 or 12): B pressed while the stall is held asks that the stall the game records within 250 ms be
  recorded as `fakie_rock` (`reskate.tricks.record_as`).

The stall is the physics state the game chose (`reskate.skater.telemetry().watch.state`): 400 or 401
holds a stall or a grind, and only a stall's label or trick id is ever changed. Off until switched
on: `rocktofakie on|off|status`, or its page in the ReSkate menu's PLUGINS section.

## Install

Copy this folder into the game's `Mods` folder.

## Limits

- The hooks behind `reskate.tricks` are tied to the supported game build: on another, the status
  says why nothing is asked.
- It does not detect a real coping contact: any Board Stall or Lip Stall counts, wherever it is done.
- A recorded trick is your game's: whether a multiplayer host sees it the same has not been checked.
  It is not asked while a throwdown runs.
