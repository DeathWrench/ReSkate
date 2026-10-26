#pragma once
#include <imgui.h>

// ReSkate's replay editor's screen (Extension/ReplayEditor/replay_session.h is the game's side, and
// replay_bridge.h what they share). The overlay draws it while the editor has the game's replay.
namespace dingosdk::overlay {
struct ReplayEditorFonts {
    ImFont *title{}, *heading{}, *bold{}, *body{};
    float scale{1};
};
// Render thread, every frame: whether the editor is showing (it then has the input).
bool replay_editor_pending() noexcept;
void draw_replay_editor(const ReplayEditorFonts& fonts);
} // namespace dingosdk::overlay
