#pragma once
#include "Engine/Game/Build/fingerprint.h"
#include <cstddef>
#include <cstdint>

// The replay editor's session, playback clock, camera and export, as ReSkate's own replay editor
// drives them (Extension/ReplayEditor/replay_session.h; research in build/replay-editor-research).
// The game's editor is a UI made of game data over a few dozen small natives; these are the natives'
// own functions and the objects they work on.
namespace dingosdk::game::build::v20260929::replay_session {
// ---- Objects ----------------------------------------------------------------------------------
// The playback manager (natives reach it through 0x610030). + 0x08 the open playback handle (its
// + 0x10 is the session below), + 0x44 the keyframe session being played, + 0x48 set while an
// export runs: the playback rate is not to be changed then.
inline constexpr std::uintptr_t playback_manager = 0x71f2148;
inline constexpr std::size_t manager_handle = 0x08;
inline constexpr std::size_t handle_session = 0x10;
inline constexpr std::size_t manager_keyframe_session = 0x44;
inline constexpr std::size_t manager_rate_lock = 0x48;
// The session (client + 0x568): its engine interface (vtable 0x6084518) at + 0x50, the playback
// rate (double) at + 0x58, the recorded window at + 0x70 / + 0x78 and the playback range at
// + 0x80 / + 0x88 (game seconds), the fixed-step flag an export sets at + 0x99, and the timeline's
// segments ({double start, double end, ...}, 0x18 bytes) from + 0xa0 to + 0xa8.
inline constexpr std::size_t session_interface = 0x50;
inline constexpr std::size_t session_rate = 0x58;
inline constexpr std::size_t session_window = 0x70;
inline constexpr std::size_t session_range = 0x80;
inline constexpr std::size_t session_fixed_step = 0x99;
inline constexpr std::size_t session_segments = 0xa0;
// The interface's slots: lock / unlock a range of footage so the recorder's ring keeps it (game
// seconds; slot 6 and 7, no 120 s limit, unlike the drafts' pin), the replay time now (slot 17), and
// an export's playlist of pieces (slot 25: {double start, double end, float speed} each, copied, and
// a fixed step a frame).
inline constexpr std::size_t interface_lock = 0x30;
inline constexpr std::size_t interface_unlock = 0x38;
inline constexpr std::size_t interface_time = 0x88;
inline constexpr std::size_t interface_playlist = 0xc8;
// The export's capture manager (natives reach it through 0x610020): + 0x28 non-zero while a capture
// runs, + 0x7c format (0 MP4, 1 WebM), + 0x80 frame rate (0 24, 1 30, else 60), + 0x84 resolution
// (0 360p .. 5 2160p), + 0x88 bitrate (0 8000, 1 12000, 2 18000 kbps).
inline constexpr std::uintptr_t capture_manager = 0x71f2140;
inline constexpr std::size_t capture_state = 0x28;
inline constexpr std::size_t capture_bitrate = 0x88;
// The replay camera's targets (ReplayCameraTarget): vfunc + 0x10 (self, id, item, float out[16]) is
// where a target's item is in the frame being shown, as a matrix with the position in its last row;
// id 0 the local player; items 2 the body (GameplayFulcrum), 4 the head, 5 the feet (the board).
inline constexpr std::uintptr_t camera_targets = 0x71e7218;
inline constexpr std::size_t targets_item = 0x10;
// The replay keyframes' state (vtable 0x60cad80); slot 0 is keyframe_pose below.
inline constexpr std::uintptr_t keyframes_state = 0x71f2138;
// The engine's replay: the time table (game time to stream time; 0x28-byte rows under a critical
// section), whether the replay lane is up (byte) and the replay object.
inline constexpr std::uintptr_t time_table = 0x7726450;
inline constexpr std::uintptr_t replay_shown = 0x7726468;
inline constexpr std::uintptr_t replay_object = 0x77264e0;
// The playing export's playlist: the pieces, how many, which one now.
inline constexpr std::uintptr_t playlist_count = 0x77264f0;
inline constexpr std::uintptr_t playlist_index = 0x7726500;

// ---- Hooked ----------------------------------------------------------------------------------
// camera_apply(evaluator, State*): the Dingo camera evaluator's step that turns its directors' finished
// state into the engine camera (0x17ac360 builds the rows, 0x1707c60 writes camera + 0x10 / + 0x50,
// the FOV goes to + 0xac), once a tick for every enabled evaluator, after the directors and before the
// view manager builds the frame's views and frustums from the camera (0x2f16470). Its only caller is
// the evaluator's tick 0x1728a50. Every replay camera (the replay editor's cameras are Dingo cameras,
// DingoCameraID ReplayEditor) passes here, whichever director plays, so ReSkate gives it a copy of the
// state with its own camera in; the engine camera follows it, though a replay's picture does not
// (xray_render.h set_view_camera). State (0xa0 bytes): + 0x00 position, + 0x10 an
// offset added to it (shake), + 0x20
// the point looked at, + 0x30 the up hint (float4s, w lanes kept), + 0x78 the FOV in degrees, + 0x96 a
// physical camera, whose FOV then comes from its lens at + 0x84 when that is above 0.
inline constexpr Fingerprint camera_apply{0x1725130, {
    0x48,0x8b,0xc4,0x48,0x89,0x58,0x08,0x48,0x89,0x78,0x10,0x55,0x48,0x8d,0x68,0xa1,
    0x48,0x81,0xec,0x00,0x01,0x00,0x00,0x48,0x8b,0xda,0x48,0x8b,0xf9,0x48,0x8b,0xcb}};
inline constexpr std::size_t camera_state_size = 0xa0;
inline constexpr std::size_t state_position = 0x00, state_offset = 0x10, state_target = 0x20, state_up = 0x30;
inline constexpr std::size_t state_fov = 0x78, state_lens = 0x84, state_physical = 0x96;
// The replay camera targets' vfunc 0: the replay time of the frame being shown (as 0x4a9b40 asks it).
inline constexpr std::size_t targets_time = 0x00;
// session_update(session, frame): every frame while a session is open. Moves the replay time by the
// frame's real time (frame + 8, nanoseconds) times the rate at session + 0x58, within the playback
// range, then seeks; and turns recording off while the session is held or played.
inline constexpr Fingerprint session_update{0x62bba0, {
    0x48,0x8b,0xc4,0x53,0x55,0x41,0x54,0x48,0x81,0xec,0x80,0x00,0x00,0x00,0x48,0x89,
    0x70,0x08,0x48,0x8b,0xd9,0x48,0x8b,0x0d,0x64,0xc3,0xb7,0x06,0x48,0x8b,0xf2,0x48}};
// Pose* keyframe_pose(state, Pose* out, double time): the keyframed replay camera at a replay time,
// asked by the Keyframed camera director's update (0x4a9b40) every frame it runs (not while the
// replay editor's other directors play, even with keys in the session: seen in game, 2026-10-25). Pose (0x58
// bytes): a 4x4 float matrix whose rows are the camera's left, up, forward and position (0x4a9b40
// negates the first and third into the camera's right and back), two floats at + 0x40 / + 0x44
// (zero as the pose starts out, 0x599cd00), the vertical field of view in radians at + 0x48, and
// at + 0x50 a byte: the pose is good.
inline constexpr Fingerprint keyframe_pose{0x621f70, {
    0x48,0x89,0x5c,0x24,0x18,0x57,0x48,0x81,0xec,0x90,0x00,0x00,0x00,0x48,0x8b,0xf9,
    0x48,0x8b,0xda,0xc5,0xf8,0x29,0xb4,0x24,0x80,0x00,0x00,0x00,0x48,0x8d,0x4c,0x24}};
inline constexpr std::size_t pose_fov = 0x48;
inline constexpr std::size_t pose_valid = 0x50;
// start_capture(out name, Settings*, encoder id, bool* started): the engine's movie capture, which
// an export starts (0x62c010). Settings: + 0x08 height, + 0x10 width, + 0x14 frames a second
// (float), + 0x18 kilobits a second.
inline constexpr Fingerprint start_capture{0x34f2450, {
    0x40,0x55,0x56,0x57,0x41,0x55,0x41,0x56,0x48,0x8b,0xec,0x48,0x81,0xec,0x80,0x00,
    0x00,0x00,0x48,0x8d,0x05,0x9b,0xc2,0xe0,0x03,0x4d,0x8b,0xe9,0x48,0x89,0x01,0x41}};
inline constexpr std::size_t capture_settings_height = 0x08;
inline constexpr std::size_t capture_settings_width = 0x10;
inline constexpr std::size_t capture_settings_bitrate = 0x18;

// ---- Called ----------------------------------------------------------------------------------
// double seek(session, double time): moves the replay to a time (kept within the window and the
// timeline's segments) and returns where it went.
inline constexpr Fingerprint seek{0x61a5d0, {
    0x40,0x53,0x55,0x56,0x57,0x48,0x83,0xec,0x38,0xc5,0xfa,0x6f,0x1d,0xcf,0x59,0xa5,
    0x05,0xc5,0xfb,0x10,0x25,0xa7,0x13,0xab,0x05,0xc5,0xf8,0x29,0x74,0x24,0x20,0xc5}};
// void export_setup(capture, format, resolution, frame rate, double speed): the export's choices
// onto the capture manager (speed kept within 0.1..5).
inline constexpr Fingerprint export_setup{0x6254e0, {
    0xc5,0xfb,0x10,0x4c,0x24,0x28,0xc5,0xf9,0x57,0xc0,0xc5,0xf9,0x2f,0xc8,0x89,0x51,
    0x7c,0x44,0x89,0x81,0x84,0x00,0x00,0x00,0x44,0x89,0x89,0x80,0x00,0x00,0x00,0x76}};
// void export_playback(manager, bool exporting, bool fixed, double value): what the export does to
// playback before it starts and after it ends. ReSkate does the start itself (its own pieces) and
// calls this with (false, false, 1.0) after, as the game's own end does (0x54ac30).
inline constexpr Fingerprint export_playback{0x6250b0, {
    0x48,0x89,0x6c,0x24,0x18,0x48,0x89,0x74,0x24,0x20,0x57,0x48,0x83,0xec,0x50,0xc5,
    0xf8,0x29,0x74,0x24,0x40,0xc5,0xf8,0x28,0xf3,0x41,0x0f,0xb6,0xe8,0x88,0x51,0x48}};
// void export_start(capture, Callback*): starts the capture and keeps the callback, called
// (bool ok, uint32 code, Callback*) when it ends or fails. Callback: storage (8 bytes), 8 more,
// a manager (Callback* to, Callback* from, int op: 1 and 2 copy the storage), the invoker.
inline constexpr Fingerprint export_start{0x62c010, {
    0x40,0x55,0x57,0x41,0x56,0x48,0x8d,0x6c,0x24,0xb9,0x48,0x81,0xec,0x90,0x00,0x00,
    0x00,0x83,0x79,0x28,0x00,0x48,0x8b,0xfa,0x4c,0x8b,0xf1,0x74,0x12,0x4c,0x8b,0xc2}};
// The game's own manager for a callback whose storage is one pointer (the copy above).
inline constexpr std::uintptr_t callback_copy = 0x204590;
// double latest_time(TimeTable**): the game time of the newest row, the replay time now while it
// records. Passed the address of time_table.
inline constexpr Fingerprint latest_time{0x41a66d0, {
    0x40,0x53,0x48,0x83,0xec,0x30,0x48,0x8b,0x19,0xc5,0xf8,0x29,0x74,0x24,0x20,0x48,
    0x89,0x7c,0x24,0x40,0x48,0x8b,0xf9,0x48,0x8b,0xcb,0xe8,0x91,0x96,0x3e,0xfd,0x48}};
}
