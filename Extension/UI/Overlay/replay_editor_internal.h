#pragma once
#include "replay_editor.h"
#include "Extension/ReplayEditor/replay_bridge.h"
#include "Extension/ReplayEditor/replay_edit.h"
#include "Extension/ReplayEditor/replay_program.h"
#include "Extension/ReplayEditor/replay_project_file.h"
#include <imgui.h>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// The replay editor's screen, shared by its files, laid out as a video editor's (Premiere's): a menu
// bar; the Project panel (clips, moments, looks) on the left; the monitor in the middle, showing the
// game's picture fitted into it (replay_preview in overlay_render.cpp); Effect Controls on the right;
// the timeline along the bottom.
//   replay_editor.cpp           the frame, the layout, the input, the edit's actions
//   replay_editor_panels.cpp    the menu bar, Project, the monitor, Effect Controls, the dialogs
//   replay_editor_timeline.cpp  the timeline
//   replay_filmstrip.cpp        the pictures of the footage
namespace dingosdk::overlay::replay_ui {
namespace re = replay_editor;

// The timeline's key rows, under the sequence.
enum class Lane : int { clips, camera, speed, look, titles };
inline constexpr int lane_count = 5;
const char* lane_name(Lane lane) noexcept;
enum class ProjectTab : int { clips, moments, looks };
enum class EffectsTab : int { effects, titles, setup };

struct KeyRef {
    Lane lane{};
    double at{};
};

struct Ui {
    bool initialized{};
    re::Project project;
    re::History history;
    std::shared_ptr<const re::Program> program;
    bool dirty{};
    double saved_at{};
    std::uint64_t selected{};
    std::optional<KeyRef> key;
    Lane lane{Lane::camera};
    ProjectTab project_tab{ProjectTab::clips};
    EffectsTab effects_tab{EffectsTab::effects};
    // Playback. Source plays the footage; Program plays the edit.
    re::PlayMode mode{re::PlayMode::footage};
    bool playing{}, loop{};
    double shuttle{1};
    std::optional<double> mark_in, mark_out;
    // The timeline's views: the source row in replay seconds, the sequence in edit seconds (empty: all).
    double view_from{}, view_to{};
    double sequence_from{}, sequence_to{};
    // Camera mode: the player flies a camera and keys from it.
    bool camera_mode{};
    re::Vec3 fly_position{};
    float fly_yaw{}, fly_pitch{}, fly_roll{}, fly_fov{65};
    float fly_speed{6}, fly_focus{}, fly_blur{0.5f};
    // Turning by the cursor (when no raw mouse comes): where it was put back to last frame.
    bool cursor_turning{};
    int cursor_x{}, cursor_y{};
    re::Rig new_rig{re::Rig::free};
    re::Target new_target;
    bool hide_ui{}, snapping{true};
    // Dialogs.
    bool export_open{}, help_open{};
    re::ExportChoice export_choice;
    int preset{-1};
    std::vector<re::ProjectFile> files;
    double files_listed_at{-100};
    std::string message;
    double message_until{};
    std::uint32_t export_serial{};
    // Pad.
    unsigned pad_before{};
    double pad_repeat_at{};
    bool pad_shuttling{};
    double b_held_since{-1};
    // Timeline drags.
    std::uint64_t drag_clip{};
    int drag_edge{};
    double drag_from_in{}, drag_from_out{};
    float drag_x{};
    bool drag_remembered{};
    std::optional<KeyRef> drag_key;
    double drag_key_from{};
    bool scrubbing{}, sequence_scrubbing{};
    // The layout: panel sizes in design pixels (1080 lines), dragged by the splitters.
    float left_width{330}, right_width{420}, timeline_height{330};
    ImVec2 monitor_a{}, monitor_z{}; // where the picture is on screen this frame
    // Look.
    ReplayEditorFonts fonts;
    float k{1};
};
Ui& ui();

// ---- Colours (Premiere's dark theme) ------------------------------------------------------------
namespace palette {
inline constexpr ImU32 back = IM_COL32(24, 24, 24, 255);
inline constexpr ImU32 panel = IM_COL32(35, 35, 35, 255);
inline constexpr ImU32 header = IM_COL32(46, 46, 46, 255);
inline constexpr ImU32 well = IM_COL32(28, 28, 28, 255);
inline constexpr ImU32 line = IM_COL32(16, 16, 16, 255);
inline constexpr ImU32 text = IM_COL32(214, 214, 214, 255);
inline constexpr ImU32 dim = IM_COL32(140, 140, 140, 255);
inline constexpr ImU32 accent = IM_COL32(45, 140, 235, 255);
inline constexpr ImU32 playhead = IM_COL32(70, 155, 255, 255);
inline constexpr ImU32 timecode = IM_COL32(80, 165, 255, 255);
inline constexpr ImU32 clip = IM_COL32(108, 120, 186, 255);
inline constexpr ImU32 clip_selected = IM_COL32(146, 158, 232, 255);
inline constexpr ImU32 camera_key = IM_COL32(255, 150, 60, 255);
inline constexpr ImU32 speed_key = IM_COL32(120, 220, 140, 255);
inline constexpr ImU32 look_key = IM_COL32(205, 130, 255, 255);
inline constexpr ImU32 title_key = IM_COL32(235, 235, 235, 255);
}

// ---- The edit (each change can be undone) ----------------------------------------------------
void remember();
void changed();
void set_project(re::Project project);
re::Clip* selected_clip();
double now();
re::Status status();
void seek(double replay, int clip = -1);
void say(std::string text, double seconds = 3);
void save(bool quiet = false);
std::filesystem::path projects_folder();

// ---- Actions (replay_editor.cpp), shared by the keys, the menus and the panels ----------------
void toggle_play();
void shuttle(int direction);
void step(double seconds);
void jump(int direction);
void set_mode(re::PlayMode mode);
void add_clip(double in, double out, std::string name = {});
void clip_from_moment();
void split_here();
void delete_selection();
void add_key_here();
void enter_camera_mode();
void leave_camera_mode();
void leave_replay();
re::Clip* clip_for_keys();
std::optional<re::CameraPose> camera_on_screen();
re::CameraKey key_from(const re::CameraPose& pose, double t);
// The clip showing now: in Program the one playing, in Source the one the playhead is in.
std::optional<std::size_t> showing_clip_index();
// The edit time now, when the playhead is in a clip of the edit.
std::optional<double> sequence_now();

// ---- Drawing helpers ---------------------------------------------------------------------------
ImU32 colour(int r, int g, int b, int a = 255);
bool button(const char* label, bool on = false, bool enabled = true, float width = 0);
std::string clock(double seconds);     // m:ss.cc
std::string timecode(double seconds);  // hh:mm:ss:ff at 60 frames a second
// A panel's header strip with tabs: the tab pressed, or -1.
int panel_tabs(ImDrawList* draw, ImVec2 a, float width, std::initializer_list<const char*> tabs, int current);
void diamond(ImDrawList* draw, ImVec2 c, float r, ImU32 fill, bool selected);

// ---- Panels ------------------------------------------------------------------------------------
void draw_menu_bar(ImVec2 size);
void draw_project(ImVec2 a, ImVec2 z);
void draw_monitor(ImVec2 a, ImVec2 z);
void draw_effects(ImVec2 a, ImVec2 z);
void draw_timeline(ImVec2 a, ImVec2 z);
void draw_export_dialog(ImVec2 size);
void draw_help_dialog(ImVec2 size);
void draw_titles_over(ImVec2 a, ImVec2 z); // over the monitor's picture
void draw_camera_hud(ImVec2 a, ImVec2 z);
std::vector<double> edit_points();

// ---- The filmstrip (replay_filmstrip.cpp) ------------------------------------------------------
struct FilmCell {
    ImTextureID texture{};
    ImVec2 uv0, uv1;
};
void filmstrip_update();
void filmstrip_rebuild();
std::optional<FilmCell> filmstrip_cell(double replay);
} // namespace dingosdk::overlay::replay_ui

namespace dingosdk::overlay {
// The game's frame as a texture, copied before ReSkate draws (overlay_render.cpp), for the monitor:
// its id and its size; empty before the first copy.
struct ReplayPreview {
    ImTextureID texture{};
    float width{}, height{};
};
ReplayPreview replay_preview() noexcept;
} // namespace dingosdk::overlay
