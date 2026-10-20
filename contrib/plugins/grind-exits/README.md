# Grind Exits (plugin)

Pick the side you pop out of a grind to with **LT / RT**, independently of the trick and of the body's
rotation. In skate.'s own controls both come from the left stick at the same moment, so a frontside
180 always pops out toward one side and a backside 180 toward the other. With this, any trick and any
rotation can go out either side: a frontside 180 out to your toe side, a backside 180 out to your heel
side, a kickflip out to whichever side you pick.

## Using it

On once installed. Its settings are on its page in the ReSkate menu's PLUGINS section, and on the console
(`~`): `grindexit exits on|off|status`.

- **While grinding, press LT or RT** (or up to 1 s before the grind connects, for example as you ollie
  up to the rail), then do any trick out of the grind with the right stick as usual. Keep the trigger
  held until you land, then let go.
- **Input mode** (`grindexit sides toeheel|travel`):
  - **Toe / Heel**: LT pops out to your toe side, RT to your heel side, riding normal, fakie or switch.
    Needs **your stance** (`grindexit stance goofy|regular`). On slides (boardslide, lipslide), where
    toes and heels point along the rail, LT / RT are left / right of travel.
  - **Left / Right**: LT pops out to the left of your direction of travel, RT to the right.
- **No trigger, or both**: the game's own exit.
- **Grabs**: a trigger used to pick the side is kept from the game until you let go of it, so holding
  it through the pop does not grab. Let go and press it again in the air to grab (`grindexit guard on|off`).
- **Spins**: push the left stick for your spin as you always do. While the trigger is held in the grind,
  the stick's left / right reaches the game at the pop instead of before it, so the game's own lean
  exit cannot drag the board toward the spin and into the rail (`grindexit leanguard on|off`).
- **Pop-out strength** (`grindexit strength 10-100`): how far to the side a trigger exit pops, as a
  share of the full exit (100%, the default, is the game's own sideways speed). Lower it for rails next
  to a wall.
- **Multiplayer**: works in any session or server. It adds no speed or height; it only changes which
  input picks the exit side.

`grindexit test` runs the plugin's own checks of the trigger rules.

## How it works

- `plugin/triggers.lua`: each tick, which trigger picks the side and what the game must not see of
  the pad. No game access, so `plugin/tests.lua` checks it.
- `plugin/main.lua`: the wiring to `reskate`: the pad (`reskate.input.gamepad`, which sees the
  triggers even while they are kept from the game), the hiding (`reskate.input.hide`), the side asked
  of the next pop (`reskate.skater.grind_exit`) and each pop as it went (the `grind_exit` event), the
  console command and its page in the menu's PLUGINS section.

ReSkate does what has to happen in the game's own threads (`Extension/Skater/grind_exit.h`): at the
pop the game calls its jump-trajectory setter with the launch velocity, which the trainer hooks; for a
pop out of a grind only the sideways part of that velocity is replaced, across the rail: the game's
own sideways speed when it had one, mirrored to the chosen side, else the game's usual 1.8 m/s. The
speed along the rail, the pop's height, the trick, the flip and the rotation are the game's. The pad
filter hides the triggers and the left stick's left / right in the game's input thread.

**Toe / heel.** The game keeps which foot leads in a flag (context + 0x13c4, bit 5), found by recording
the skater's state while riding regular and switch: it changed exactly at each change of stance and
never during grinds, pops or 180s. With the player's stance it gives the lead foot; the toes face the
skater root's right axis when the right foot leads (measured), the other way when the left foot does.

**Measured** (when it was built into ReSkate, on build 25414733, with a goofy skater over four
sessions): 48 pops out of grinds with the game's own controls to learn its exits, then 144 pops whose
side the triggers set. Forward, fakie and switch 50-50s, ollies, kick- and heelflips, shove-its and
frontside / backside 180s went out to the chosen side with the trick and the rotation unchanged.
Frontside 180 out to the toe side clipped the rail until the lean guard was added; with it, all 4 tries
landed. As a plugin the triggers are read once a client tick rather than at every pad poll, so the game
may see a trigger for a frame before it is hidden.
