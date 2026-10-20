# Animator Studio (plugin)

The Animator Studio of 22sh, Fourth Studio and Norms (pull request 297) as a sandboxed Luau plugin.
Record a trick, change the body and the board on a timeline, save it, and from then on doing that
trick in game plays your version. Every other trick stays the game's own, and no game data is
changed.

## How to use it

1. Press **F8** (or **L3 + R3** on a pad), or open it from its page in the menu's PLUGINS section, or
   type `studio`. The studio is a panel down the right of the screen; the skater is held still, and
   the camera turns round him: hold the right mouse button and drag to turn, roll the wheel to come
   closer.
2. **TRICKS > Record a trick**: the studio steps out. Skate and land the trick within 10 seconds, and
   you are back in the studio with it, cut from a little before its takeoff to a little after its
   landing.
3. **JOINTS**: pick a joint in the list, or click its dot on the skater. Turn it with the X, Y and Z
   sliders (the hips and the board move as well). With **Key as you change it** on, each change keys
   the joint at the timeline's time; **Key it here** keys it as it is. Move along the timeline with
   its slider or a frame at a time; **Play** plays it. A key's ease (smooth, linear or step) says how
   it goes into the next one. **Undo** and **Redo** step through the changes.
4. **PLAYBACK**: which pop it is for (any, low, mid or high), its speed, and **Play it in game**.
   **Copy to low, mid and high pop** saves a copy for each pop, each playing in game.
5. **LIBRARY > Save**. With **Play it in game** on, doing the trick plays it, and keeps doing so every
   time the game starts. **Open** brings a saved one back to change it.

Console: `studio open|close|record|save <name>|ingame on|off|list|status`.

## How it works

It is built on general plugin APIs, so another plugin can do the same:

- `reskate.animation.record` records the skater as the game draws it, with the trick's takeoff and
  landing marked; `reskate.animation.trim` cuts it down to the trick.
- The keys are the plugin's own. `reskate.animation.edit` bakes them onto the recording: each key
  turns a joint in its own frame and moves it in its parent's, eased into the next key.
- The studio shows the baked clip on the skater, held at the timeline's time
  (`reskate.animation.play` with `paused`, then `seek`, `pause` and `time`).
- The panel is a docked `reskate.ui.screen`; `reskate.input.cursor` is the mouse beside it, and the
  joints' dots come from `reskate.skater.joint`.
- A saved animation is its recording as a clip file and its keys as JSON, in the plugin's data folder
  (`Mods/.reskate_plugin_data/animator-studio/anims/<name>.fas` and `.json`), saved with
  `reskate.animation.save` and read back as `"data:anims/<name>.fas"`.
- Playing in game is `reskate.animation.replace` on the game's trick, for its pop.

## Install

Copy this folder into the game's `Mods` folder.

## Not here from the pull request

- The studio room: the PR walks the game menu to the Skaters page's lit character room and draws the
  skater there. The plugin opens the studio where the skater is.
- The loading screen over that walk, and the gizmo for dragging a joint round on the skater: here
  joints turn with sliders.
- The game's own tricks as a library to start from (`make_trick_library.py`).

## Limits

- A trick played in game is also what other players see, as for any plugin's clip.
- Clips do not play while a throwdown or a game of S.K.A.T.E. runs; the studio shows nothing then.
- A plugin's clips hold at most 48 MB of poses: each saved animation that plays in game holds its
  clip while the plugin runs.
