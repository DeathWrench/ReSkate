# Replay editor

ReSkate's own replay editor, over the game's. The game keeps recording everything it draws (about
half an hour of it); its editor shows the last 15 s to 5 min, one trimmed range at a time, with keys
only on your own skater. ReSkate's opens the whole recording, cuts many clips into one edit, keys
cameras that follow or circle any skater, ramps the speed, keys the picture's look, adds titles, and
exports the edit in one go.

Code:
- [Extension/ReplayEditor/](../Extension/ReplayEditor), the parts with no game code (unit tested in
  [Test/](../Extension/ReplayEditor/Test/replay_editor_tests.cpp)):
  - `replay_edit` holds the edit;
  - `replay_motion` the curves and camera maths;
  - `replay_program` the edit made playable;
  - `replay_project_file` the project files;
  - `replay_bridge` what the screen and the game's side share.
- [replay_session.cpp](../Extension/ReplayEditor/replay_session.cpp) is the game's side.
- [replay_editor.cpp](../Extension/UI/Overlay/replay_editor.cpp) and
  [replay_editor_timeline.cpp](../Extension/UI/Overlay/replay_editor_timeline.cpp) are the screen.
- The game's addresses are in [replay_session.h](../Engine/Game/Build/20260929/replay_session.h).
- The research behind it is `build/replay-editor-redesign.md` and `build/replay-editor-research/`
  (gitignored).

## Using it

**Opening it.** Open the game's replay editor as usual (hold Select, or B on the keyboard).
ReSkate's editor opens over it. It is a switch in the overlay (Insert, Skater, REPLAY EDITOR), or
`replayeditor auto on|off`. `replayeditor open` opens it over the game's editor. CLOSE, Esc or
holding B (or `replayeditor close`) leaves the replay altogether. `replayeditor game` goes back to
the game's own editor instead.

**The screen**, laid out as a video editor's (Premiere's), panels sized by dragging the bars
between them:
- **The menu bar** has File, Edit, Marker, View and Help, the project's name and CLOSE.
- **Project** (left) holds the sequence's clips with their first pictures and the saved projects;
  **Moments** lists what happened (a right click clips one); **Looks** puts a look on the clip at the
  playhead.
- **The monitor** (middle) shows the game's picture fitted into it, copied each frame before
  ReSkate draws (`copy_replay_preview`), so nothing is hidden under the panels. Its tabs are Source
  (the footage) and Program (the edit). Under it are the timecode, the transport and the length.
- **Effect Controls** (right) holds the selected clip's Clip, Camera, Time remapping and Look,
  changed at the playhead as in a video editor: where there is no key, a change makes one. Titles
  and Setup are its other tabs.
- **The timeline along the bottom** has two parts:
  - **FOOTAGE** is the whole recording as a filmstrip of pictures, with the clips taken from it and
    what happened. Tricks are marks as tall as their points (yellow), slams are red, players joining
    and leaving are blue, and markers are white. Hover a mark for its name and points. The filmstrip
    starts from pictures taken while you skated (the game's frames, HUD and all, kept by the
    recording's time) and fills in as the footage plays or is scrubbed past (each picture taken
    again when it is old). REMAKE THE FILMSTRIP clears it.
  - **SEQUENCE**, on the edit's own clock: V1 holds the clips one after another, as long as each plays,
    each with its pictures. Under it, CAMERA, SPEED (with its curve drawn), LOOK and TITLES show
    every clip's keys where they play.

**Making an edit.**
1. Scrub the footage (click and drag; the wheel zooms, the right or middle button pans).
2. Make clips: set In and Out (I and O) and press A. Or press C beside a moment to clip it (a
   trick gets 2.5 s before and 1.5 s after).
3. Arrange them on EDIT: drag a clip to move it, drag its ends to trim it, S splits it at the
   playhead, Ctrl+D copies it, Delete removes it.
4. V switches between playing the footage and playing the edit (cut to cut, at each clip's speed,
   holding a clip's last frame for its Hold).

**Keys.** Pick a row (1-4, or click its name), then F sets a key at the playhead:
- **CAMERA** keys the camera you see. Tab (or R3) flies a camera of your own first:
  - WASD, and the right mouse button to look;
  - Q / E down and up, Shift fast, Ctrl slow;
  - the wheel zooms, Ctrl+wheel focuses, Alt+wheel rolls.

  New keys follow the rig chosen on CAMERA:
  - **free**: where it is and where it looks;
  - **look at**: stays put, turns to keep the target in frame;
  - **follow**: rides with the target, from behind the way it is going;
  - **orbit**: circles the target.

  The target can be any part of you (body, head, board) or another player in the session. Each
  key has its own ease (smooth, linear, ease in / out / in-out, hold), field of view, roll and
  depth of field (a distance, or "on the target"). A clip's handheld shake adds a filmer's wobble.
  Smooth keys pass through every key with no jolt at any.
- **SPEED** keys ramp the clip's pace (0.05x to 8x; preview also plays backwards). SLOW-MO HIT puts
  a ramp into slow motion and back out around the playhead.
- **LOOK** keys the game's own filters: exposure, saturation, brightness, hue, vignette, fisheye,
  grain and colour fringe, with presets (VX, Film, B&W, Warm, Night).
- **TITLES** are text over the picture (title, caption, label, lower third). A clip's "Label tricks"
  names each trick as it lands, with its points.

Click a key to pick it and go to it. Drag it to move it. The right button takes it off. The panel
changes the picked key's values.

**Export.** EXPORT (Ctrl+E, View on a pad) has presets (YouTube 1080p60, 1440p60, 4K 30, Discord
720p, small WebM, Cinematic 24), or a chosen format, frame rate, size and bitrate. It exports the
whole edit or the clip under the playhead. The game films it frame by frame into its Videos folder.

**Projects.** Projects are saved to `%LOCALAPPDATA%\ReSkate\Replays\*.rsedit` (JSON), and autosaved
a minute after a change. The game keeps footage only while it runs, so a project opened in a later
run keeps its clips, keys and titles over whatever is recorded at those times now. The panel says
so.

**Controls** (KEYS on the top bar lists them all):

| | Keyboard and mouse | Controller |
|---|---|---|
| Play / pause | Space | A |
| Shuttle | J / K / L (again: faster) | LT / RT, as far as pulled |
| Step a frame / a second | Left Right, Shift | D-pad left right |
| Previous / next edit point | Up / Down | LB / RB |
| In / out / make a clip | I / O / A | Y + D-pad left / right / down |
| Key the row | F | X |
| Fly the camera | Tab | R3 |
| Hide the editor | H | L3 |
| Back to the game's editor | Esc | hold B |

## How it works

- **Taking over.** When the game's replay session opens, ReSkate hides the game's UI (the same
  switch as `hideui`). It opens the playback range to the whole recorded window every tick
  (session `+0x80/+0x88` set to the window `+0x70/+0x78`; the native, `6ad87382`, takes the range
  as two floats). It draws its screen, which takes the input as the menu does.
- **Closing.** ReSkate gives the game its UI and input back. It then leaves the replay the game's
  own way, so the game's screens, input mapping and flags come back as its exit leaves them: Back
  (B) on the replay page, then A on the "exit replay?" prompt, pressed on the pad the game reads
  (`scripted_pad.h`). The game's exit script (`replaydataprovider_game_exitreplay`) leaves the
  session (`6c00176a`), restores the player's input mapping and clears its flags; calling those
  natives alone would leave its screen flow behind.
- **The clock.** The session's update (`0x62bba0`) is hooked. Before the game moves the replay
  time, ReSkate writes the rate: the player's shuttle, times the clip's speed curve in edit
  playback. At a clip's end it seeks to the next clip's start, or holds. The rate is a free double
  in the game, so any curve works.
- **The camera.** Every Dingo camera evaluator hands its directors' finished state to the engine
  camera through one step (`0x1725130`), once a tick, before the view manager builds the frame's
  views and frustums. The replay editor's cameras are Dingo cameras. While ReSkate has a camera to
  show (flying, or a clip with camera keys), a copy of that state with ReSkate's position, look-at point, up and FOV, for the
  replay time of the frame being shown (the replay camera targets' vfunc 0), goes in instead. The
  state itself is never written: where the game's directors do not build it again each tick (a
  replay two frames long), a camera written there stays and the game's own camera is lost.
  That moves the engine camera, but in a replay the picture is not drawn from it. Read from the
  running game, the main render view (kind 0, as `0x3f8b2b0` takes it) held the game's pose and FOV
  while everything reachable from the camera held ReSkate's. A hardware write watch on the main
  view's camera found the world renderer's frame setup (`0x4e9cba0`), which copies the frame's
  five views and culls from the copy. There (`xray::set_view_camera`, through the x-ray's render
  hooks, kept on while the editor has the replay):
  - the main view (+ 0x50) gets a camera between the last two given (one a game tick), as far
    along as the time since the newest says. The renderer draws more often than the game ticks
    (2.4 frames a tick at 144 Hz) and moves the world on every frame; a camera changing once a tick
    stood still for two frames and jumped on the third (the skater jittered against it). The flown
    camera itself moves on the game's clock (`Bridge::advance_live_camera`, the game's frame time),
    not the screen's, which differs by a tenth either way;
  - the previous main view (+ 0xbd0) gets the camera of the frame before (the same camera in both
    smeared the picture through the temporal filters);
  - any other view that is exactly the game's camera (position and rotation) gets it with its own
    FOV (view 1 is: without it the lighting stayed on the game's camera). Position alone is not
    enough: views of their own at the camera were turned too and the exposure went wild;
  - each such view's derived matrices are marked out of date (view + 0x140, bits 1, 2, 4, 8).
  The shaders' view (`0x3f8b2b0`) follows from the frame's copy and is not written: written there
  too and marked out of date, it was not derived again and the picture broke (seen on a map whose
  game camera stood still). A key in the game's keyframe session does
  not switch its director to the Keyframed camera (tried; it also took the mouse look).
  The keyframed camera's pose (`0x621f70`) is answered the same way. Spectate's takeover was tried
  first and cannot work in a replay: it waits for the client's camera phase, which never comes
  while the replay editor is open. Local targets come from the game's own replay camera targets (`0x71e7218`, recorded).
  Other players come from ReSkate's own track of where they were (10 a second while recording,
  from the session feed).
- **The filmstrip** (`replay_filmstrip.cpp`) holds 96 pictures of 160 x 90 in one atlas texture
  (SRV slot `replay_filmstrip_slot`). The presented frame is copied on the game's queue before
  ReSkate draws and read a frame or two later, when the GPU has finished, without waiting
  (`copy_presented_frame`, `take_frame_copies`); only the pixels a picture needs are converted (HDR
  frames too). A read-back that waited held the overlay up for about four frames, and a camera flown
  in it stood still meanwhile, so the editor never took pictures while playing and went through the
  recording once on opening instead. While the game records (no replay open), a picture every half
  second of recording is kept with the recording's time (`Status::recording_at`), a few hundred at
  most: when full, every other one goes and pictures come half as often. On opening, each slot takes
  the nearest kept one. The atlas goes to two textures in turn (two SRV slots), so an upload never
  waits for the GPU to finish with the one it replaces.
- **The look and depth of field** are engine settings, held while the editor has the replay and put
  back after: `PostProcess.ForceEVCompensation*`, `PostProcess.ForceDof*`,
  `DingoVideoFilterSettings.HueShift*`, `Vignette*`, `BarrelDistortion*`, `FilmGrain*` /
  `Grain*` and `ChromaticAberration*`.
- **Moments.** While the game records, the score HUD is read each tick (`trick_watch`: a trick's
  name and points as it lands, and slams). The session's roster gives joins and leaves. Each is
  stamped with the game time of the replay's newest row (`0x41a66d0`), the same clock as the
  footage.
- **Keeping footage.** Each clip's range is locked in the recorder's ring through the session
  interface's lock (slot 6 / 7, no 120 s limit, unlike drafts) and let go when the clip goes.
- **Export.** ReSkate does what the game's fixed-step export does (`0x6250b0`), with its own
  playlist:
  1. holds the rate;
  2. gives the clock the whole edit's pieces (interface slot 25: footage start, end and speed;
     speed ramps cut into frame-long pieces; a hold as a thousandth of a second slowed to last it);
  3. marks the session as stepping;
  4. starts the game's capture (`0x62c010`) with a callback of its own.

  The capture's start (`0x34f2450`) is hooked to give it the chosen size and bitrate. Frame pacing
  is `replay_export.cpp`'s, as before. The camera and look follow the playlist piece being filmed.

## Not tried yet

None of it has been run in the game; only the edit, curves, playback clock, export pieces, camera
rigs and project files are tested (`dingosdk_replay_editor_tests`). To find out, in order:

- **Whether the camera step changes the replay's view.** SETUP shows how often ReSkate's camera was
  put on screen. Also unknown: whether the camera's FOV field is vertical (as ReSkate's overlays
  treat it) or horizontal, and whether switching between ReSkate's camera and the game's smears
  through TAA (no cut is flagged).
- **Whether Close leaves the replay.** It assumes B opens the game's "exit replay?" prompt and A
  confirms it.
- **Whether the whole window opens.** About 30 min solo is expected; `replayeditor status` says how
  much it reached.
- **Whether an export with several clips** comes out as one file with every clip and ramp, at the
  size and bitrate chosen.
- **Whether the look settings change the picture as named.** Their scales are guesses: hue in
  degrees, saturation and brightness as multipliers, fisheye gain 0..0.6.
- **Playing backwards, and very slow motion.** The game interpolates transforms between its 60
  recorded frames a second; other state steps.
- **Titles are not in exports.** The game films its own picture before ReSkate's overlay is drawn.
  Burning them in needs ReSkate to draw into the game's frame, or a pass over the exported file.
- **Not built:** a music track and beat snapping, footage that outlives the game run (the design's
  "ghost footage"), a larger recording buffer.
