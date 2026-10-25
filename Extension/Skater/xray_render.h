#pragma once
#include "Engine/Game/Abi/linear_transform.h"
#include <array>
#include <cstdint>
#include <vector>

// The local skater as the renderer draws it (Engine/Game/Build/20260929/skater_render.h): the
// skinning matrices its mesh was drawn with and the camera of the same picture, so the x-ray's
// skeleton (xray.h) lies exactly where the game draws the skater. Two hooks: the skinned draw packets
// (observed, or hidden), and the main view's camera (observed, or given: set_view_camera).
namespace dingosdk::xray {
// Requires the validated build: verifies the layout and prepares both hooks, which patches nothing.
bool start_render(std::uintptr_t image_base) noexcept;
// Client tick: both hooks on while a plugin keeps the x-ray ready, off otherwise, so the renderer
// never calls them for nothing. False when they could not be changed (logged; both stay as they were).
bool hook_render(bool on) noexcept;
// Client tick: while `wanted` (a plugin draws the x-ray), which render objects are the local skater's
// (no_bail.h no_bail_skater), riding and walking; otherwise both hooks pass every call straight on.
void follow_render(bool wanted) noexcept;

struct Picture {
    std::vector<game::LinearTransform> skin; // each render bone's skinning matrix: from model space into the world
    std::array<float, 16> camera{};          // the camera's world matrix: right, up, back, position rows
    float vertical_fov{};                    // degrees
};
// Render thread: the latest picture's, while the renderer draws the local skater.
bool latest_picture(Picture& picture) noexcept;
// Client tick: while true (and followed, follow_render), the local skater's draw packets go out
// not visible, so this screen does not draw it; while hidden there is no picture.
void hide_skater(bool hidden) noexcept;
// Any thread: the main picture's camera (world matrix rows right, up, back, position; vertical FOV in
// degrees) for the next frames, written into the frame's main view as the world renderer takes it,
// before it culls, current and previous alike (the shaders' view follows from that). It
// lapses unless given again within a few frames. What the game itself streams around still follows
// its own camera. The hooks must be on (xray.h keep_view_camera).
// Given once a game tick: each frame is drawn between the last two given, as the game draws its own.
// `steady_frames` (an export: one frame a tick at the encoder's pace, not the clock's): each frame gets
// the newest camera as it is, and a camera stays given longer between ticks.
void set_view_camera(const std::array<float, 16>& world, float vertical_fov, bool steady_frames = false) noexcept;
}
