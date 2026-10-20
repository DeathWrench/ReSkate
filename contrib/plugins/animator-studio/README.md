# Animator Studio (plugin)

The Animator Studio of 22sh, Fourth Studio and Norms (pull request 297) as a sandboxed Luau plugin.
Record a trick, change the body and the board on a timeline, save it, and from then on doing that
trick in game plays your version. Every other trick stays the game's own, and no game data is
changed.

The screen is the pull request's, drawn by the plugin: the skater in the middle on the studio's own
camera, in the game's own lit studio room (the character room of the menu's Skaters page), skate.'s Trick List menu on the left with its tabs and white card, a timeline of the body's
joints along the bottom, the controls and KEY / SAVE in the lower right, the unsaved-changes card, the
recording strip and the loading screen with skate.'s own kickflipping board. It works from the
keyboard and mouse or from a controller; the prompts follow whichever was used last.

## How to use it

1. Press **F8** (or hold **L3 + R3** on a controller), or open it from its page in the menu's PLUGINS
   section, or type `studio`. A loading screen while the game's menu is walked to the Skaters page,
   then the studio in its room, the skater on the room's floor. With **Studio room** off (PLAYBACK),
   or when the walk fails, it opens where the skater is.
2. **TRICKS > Record a trick**: the studio steps out (a strip across the top shows it records). Skate
   and land the trick: you are back in the studio with it, cut from a little before its takeoff to a
   little after its landing. It records again until a trick is landed; Esc / Back goes back without
   one.
3. **JOINTS**: pick a joint (or **Board**) in the list or on the skater and turn it by dragging (the
   left stick on a controller). **G** moves the hips or the board, **R** turns again; **X / Y / Z**
   lock an axis, **L** switches between the joint's axes and the world's. The card's numbers drag
   left and right, and a double click types one in place.
4. Move along the timeline (**Left / Right**, **RT / LT**, or drag the playhead) and key with **K**
   (**A** on a controller). **Ctrl+A** chooses every key, **Shift+click** adds one, drag one to move
   them all, **Delete** takes them off. **KEYS** has the rest: blend into the next key (smooth, linear,
   step), copy and paste a pose, hide or lock a joint's keys, follow a joint with the camera.
5. **SAVE** (Ctrl+S). With **Custom tricks in game** on (PLAYBACK), doing the trick plays it, and keeps
   doing so every time the game starts. **PLAYBACK** also has the pop it is for (any, low, mid,
   high), *Copy to low, mid and high pop*, the speed and loop. **SAVED** opens a saved one again; its
   card's NAME and TRICK are typed into in place (Enter keeps it, Esc does not).

The camera: hold the right mouse button and drag to turn round the skater, the middle button to pan,
the wheel to come closer; 1 to 5 are set views and 0 the first; Tab hides the menu. On a controller
the right stick orbits, and after R3 it zooms and pans.

Console: `studio open|close|record|save <name>|ingame on|off|list|status|test`.

## The game's own tricks

The pull request made a list of the game's own trick animations with `tools/make_trick_library.py`
(here beside this README, with `clip.py` and `fbxbin.py`). It needs ReSkate Studio's command line
(`reskate_cli`, or `RESKATE_CLI` naming it) and Python with numpy:

```
python tools/make_trick_library.py "<the game's folder>" "<the game's folder>/Mods/.reskate_plugin_data/animator-studio/library"
```

The clips and `catalog.json` it writes there are listed in TRICKS by category: choose a trick, then
its pop, and it opens in the studio. The pull request hid the list for a reason that still holds: in
flips the game places the board with its physics, which those clips do not hold, so a recording is
the better way in.

## How it works

It is built on general plugin APIs, so another plugin can do the same:

- `reskate.animation.record` records the skater as the game draws it, with the trick's takeoff and
  landing marked; `reskate.animation.trim` cuts it down to the trick.
- The keys are the plugin's own. `reskate.animation.edit` bakes them onto the recording: each key
  turns a joint in its own frame and moves it in its parent's, eased into the next key. The studio
  shows the baked clip on the skater, held at the playhead (`reskate.animation.play` with `paused`,
  then `seek`, `pause` and `time`). A change shows at once through `reskate.skater.pose` (a joint's
  turn and offset) until the next bake has it.
- The screen is a `reskate.ui.screen` with no panel: the plugin draws it all in its draw handler
  (`d:rough_rect`, `d:halftone`, `d:scribble`, `d:clip`, `d:measure`, `d:game_image` for the loading
  screen's grain, tape, tiles and `loading_board`), reading `reskate.input.cursor`, the keys and the
  pad; its fields take typing with `reskate.input.text`. The joints' dots and the drag come from
  `reskate.skater.joint` (with each joint's parent).
- The room is `reskate.room`: ReSkate walks the game's menu to the Skaters page (its own navigation
  events, and RB on a pad of its own, as the pull request did), draws the skater on the room's floor
  and hides the room's own skater and board; other players still see the skater where he is.
- A saved animation is its recording as a clip file and its keys as JSON, in the plugin's data folder
  (`Mods/.reskate_plugin_data/animator-studio/anims/<name>.fas` and `.json`), saved with
  `reskate.animation.save` and read back as `"data:anims/<name>.fas"`. Playing in game is
  `reskate.animation.replace` on the game's trick, for its pop.
- `studio test` runs its own checks: the editing, the sliders' maths against the baked clip, and every
  screen drawn once.

## Install

Copy this folder into the game's `Mods` folder.


## Limits

- A trick played in game is also what other players see, as for any plugin's clip.
- Clips do not play while a throwdown or a game of S.K.A.T.E. runs; the studio shows nothing then.
- A plugin's clips hold at most 48 MB of poses: each saved animation that plays in game holds its
  clip while the plugin runs.
- A change shows on the skater at once for the body; the board's shows with the next bake, about three
  times a second.
