#pragma once
#include <cstdint>
#include <string>
#include <string_view>

// ReSkate's replay editor, the game's side (the edit itself is replay_edit.h, the screen
// Extension/UI/Overlay/replay_editor.cpp, and they meet in replay_bridge.h).
//
// The game keeps recording everything it draws into its replay; its own replay editor is a UI
// made of game data over a few natives (Engine/Game/Build/<build>/replay_session.h). ReSkate keeps
// all of that underneath and puts its own editor on top:
//   - When the game's replay editor opens, ReSkate's takes it over: the game's UI is hidden, the
//     playback range is opened to the whole recorded window (the game shows the last 15 s to 5 min
//     of the 30 or so minutes it keeps), and the overlay takes the input.
//   - The game's playback clock is steered every frame (session_update): the play speed, the
//     edit's speed curves, and the cuts from clip to clip.
//   - The camera: every camera evaluator's finished state is handed to the engine camera through one
//     step (camera_apply), whichever of the game's replay cameras plays; ReSkate gives it a copy with
//     the edit's camera for the replay time of the frame being shown, so an export films what the
//     preview showed. (The keyframed camera's pose, keyframe_pose, is answered the same way.)
//   - The edit's look (exposure, colour, vignette, fisheye, grain, depth of field) goes through the
//     engine's own settings, put back when the editor closes.
//   - An export is the game's own, given the whole edit as one playlist of pieces, at the size and
//     bitrate chosen (start_capture).
//   - While the game records, ReSkate notes what happened (tricks landed and their points, slams,
//     players joining and leaving) and where the other players' skaters were, for the timeline and
//     for cameras that follow them.
// Footage is kept from being overwritten while the edit uses it (the interface's range lock).
namespace dingosdk::replay_editor::session {
// Checks this build's functions and hooks them; once. False when it can't (then the game's own
// editor stays as it is).
bool start(std::uintptr_t image_base) noexcept;
bool available() noexcept;
// Client thread, every tick, with the level being played and whether the camera may be changed now
// (the client tick's camera phase).
void tick(std::uintptr_t image_base, std::uintptr_t client, std::string_view level, bool camera_phase) noexcept;
// For the console: what the editor is doing.
std::string status_text();
} // namespace dingosdk::replay_editor::session
