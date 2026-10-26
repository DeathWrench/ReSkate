#include "replay_editor_internal.h"
#include <tuple>
#include <Windows.h>
#include <shellapi.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <format>

// The replay editor's panels: the menu bar, Project (the edit's clips, the moments, the looks), the
// monitor (the game's picture fitted in, with the transport under it) and Effect Controls (the
// selected clip's camera, speed and look, edited at the playhead as a video editor's are: a value
// changed where there is no key makes one there).
namespace dingosdk::overlay::replay_ui {
namespace {
ImFont* font_or(ImFont* font) { return font ? font : ImGui::GetFont(); }

struct LookPreset {
    const char* name;
    re::Look look;
};
constexpr LookPreset look_presets[]{{"Neutral", {}},
                                    {"VX1000", {0, 1.1f, 1.05f, 0, 0.55f, 0.6f, 0.25f, 0.15f}},
                                    {"Film", {0, 0.85f, 1.0f, 0, 0.3f, 0, 0.4f, 0.05f}},
                                    {"Black and white", {0.2f, 0, 1.1f, 0, 0.35f, 0, 0.35f, 0}},
                                    {"Warm", {0.15f, 1.15f, 1.0f, -8, 0.15f, 0, 0, 0}},
                                    {"Night", {-0.8f, 0.7f, 0.95f, 15, 0.4f, 0, 0.2f, 0}}};

// A child region of the editor's window, with padding, for widgets.
bool begin_region(const char* id, ImVec2 a, ImVec2 z, bool scroll = true) {
    ImGui::SetCursorScreenPos(a);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, palette::panel);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, {10 * ui().k, 8 * ui().k});
    const bool open = ImGui::BeginChild(id, {z.x - a.x, z.y - a.y}, ImGuiChildFlags_AlwaysUseWindowPadding,
                                        scroll ? 0 : ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
    return open;
}

void section_label(const char* text) {
    ImGui::PushFont(font_or(ui().fonts.bold));
    ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(palette::dim), "%s", text);
    ImGui::PopFont();
}

// The key a change at replay time t goes into: the one there, or a new one made there from `base`
// (a copy of the key before, or the value now). Remembered for undo the first time.
template <class Key> Key* key_for_change(std::vector<Key>& keys, double t, const Key& base, bool& remembered) {
    if (auto* key = re::key_at(keys, t)) return key;
    if (!remembered) {
        remember();
        remembered = true;
    }
    Key fresh = base;
    fresh.at = t;
    re::put_key(keys, fresh);
    return re::key_at(keys, t);
}
template <class Key> const Key* key_before(const std::vector<Key>& keys, double t) {
    const Key* found = nullptr;
    for (const auto& key : keys)
        if (key.at <= t + re::same_key) found = &key;
    return found ? found : keys.empty() ? nullptr : &keys.front();
}

// Previous key, add or remove the key here, next key: as on a video editor's property row.
void key_navigation(const char* id, std::vector<double> times, double t, bool on_key, void (*toggle)()) {
    auto& u = ui();
    ImGui::PushID(id);
    const auto previous = [&] {
        for (auto it = times.rbegin(); it != times.rend(); ++it)
            if (*it < t - re::same_key) return std::optional<double>(*it);
        return std::optional<double>();
    }();
    const auto next = [&] {
        for (const double time : times)
            if (time > t + re::same_key) return std::optional<double>(time);
        return std::optional<double>();
    }();
    if (button("<", false, previous.has_value(), 26 * u.k)) seek(*previous);
    ImGui::SameLine(0, 2 * u.k);
    if (button(on_key ? "REMOVE KEY" : "ADD KEY", on_key, true, 100 * u.k)) toggle();
    ImGui::SameLine(0, 2 * u.k);
    if (button(">", false, next.has_value(), 26 * u.k)) seek(*next);
    ImGui::PopID();
}

void target_choice(const char* label, re::Target& target, bool& changed_target) {
    const auto s = status();
    std::string current = "You";
    for (const auto& p : s.players)
        if (p.id == target.player) current = p.name;
    current += std::string(" - ") + re::part_name(target.part);
    if (ImGui::BeginCombo(label, current.c_str())) {
        for (const auto& p : s.players)
            for (const re::Part part : {re::Part::body, re::Part::head, re::Part::board}) {
                if (p.id != 0 && part != re::Part::body) continue;
                const auto name = p.name + " - " + re::part_name(part);
                if (ImGui::Selectable(name.c_str(), target.player == p.id && target.part == part)) {
                    target = {p.id, part};
                    changed_target = true;
                }
            }
        ImGui::EndCombo();
    }
}

bool ease_combo(const char* label, re::Ease& ease) {
    int index = static_cast<int>(ease);
    const char* names[]{"Smooth", "Linear", "Ease in", "Ease out", "Ease in and out", "Hold"};
    if (!ImGui::Combo(label, &index, names, 6)) return false;
    ease = static_cast<re::Ease>(index);
    return true;
}

void toggle_camera_key() {
    auto& u = ui();
    u.lane = Lane::camera;
    auto* clip = selected_clip();
    if (clip && re::key_at(clip->camera, now())) {
        u.key = KeyRef{Lane::camera, now()};
        delete_selection();
    } else add_key_here();
}
void toggle_speed_key() {
    auto& u = ui();
    u.lane = Lane::speed;
    auto* clip = selected_clip();
    if (clip && re::key_at(clip->speed, now())) {
        u.key = KeyRef{Lane::speed, now()};
        delete_selection();
    } else add_key_here();
}
void toggle_look_key() {
    auto& u = ui();
    u.lane = Lane::look;
    auto* clip = selected_clip();
    if (clip && re::key_at(clip->look, now())) {
        u.key = KeyRef{Lane::look, now()};
        delete_selection();
    } else add_key_here();
}

void clip_section(re::Clip& clip) {
    auto& u = ui();
    const auto s = status();
    static std::uint64_t named{};
    static std::array<char, 81> name{};
    if (named != clip.id) {
        named = clip.id;
        std::snprintf(name.data(), name.size(), "%s", clip.name.c_str());
    }
    if (ImGui::InputText("Name", name.data(), name.size())) {
        clip.name = name.data();
        changed();
    }
    if (ImGui::IsItemActivated()) remember();
    double in = clip.in - s.window_start, out = clip.out - s.window_start;
    const double span = std::max(1.0, s.window_end - s.window_start), zero = 0;
    bool trimmed = ImGui::SliderScalar("In", ImGuiDataType_Double, &in, &zero, &span, "%.2f s");
    if (ImGui::IsItemActivated()) remember();
    trimmed |= ImGui::SliderScalar("Out", ImGuiDataType_Double, &out, &zero, &span, "%.2f s");
    if (ImGui::IsItemActivated()) remember();
    if (trimmed) {
        re::trim_clip(u.project, clip.id, in + s.window_start, out + s.window_start, std::array<double, 2>{s.window_start, s.window_end});
        changed();
    }
    const double hold_max = 5;
    if (ImGui::SliderScalar("Hold at end", ImGuiDataType_Double, &clip.hold, &zero, &hold_max, "%.2f s")) changed();
    if (ImGui::IsItemActivated()) remember();
    if (ImGui::SliderFloat("Handheld shake", &clip.shake, 0, 4, "%.1f deg")) changed();
    if (ImGui::IsItemActivated()) remember();
    if (clip.shake > 0) {
        if (ImGui::SliderFloat("Shake rate", &clip.shake_rate, 0.2f, 4, "%.1f")) changed();
        if (ImGui::IsItemActivated()) remember();
    }
    if (ImGui::Checkbox("Label tricks as they land", &clip.trick_labels)) {
        changed();
    }
}

void camera_section(re::Clip& clip) {
    auto& u = ui();
    const double t = std::clamp(now(), clip.in, clip.out);
    std::vector<double> times;
    for (const auto& key : clip.camera) times.push_back(key.at);
    re::CameraKey* here = re::key_at(clip.camera, t);
    key_navigation("camera", times, t, here != nullptr, &toggle_camera_key);
    // New keys: their rig and target.
    int rig = static_cast<int>(u.new_rig);
    const char* rigs[]{"Free", "Look at", "Follow", "Orbit"};
    if (ImGui::Combo("New key rig", &rig, rigs, 4)) u.new_rig = static_cast<re::Rig>(rig);
    if (u.new_rig != re::Rig::free) {
        bool ignored{};
        target_choice("New key target", u.new_target, ignored);
    }
    if (clip.camera.empty()) {
        ImGui::TextWrapped("No camera keys: the game's replay camera shows. ADD KEY keys the camera on the monitor; "
                           "CAMERA (Tab) flies your own first.");
        return;
    }
    const re::CameraKey* base = here ? here : key_before(clip.camera, t);
    if (!base) return;
    re::CameraKey value = *base;
    if (!here) ImGui::TextDisabled("Between keys: a change makes a key here, from the key at %s.", clock(base->at - status().window_start).c_str());
    bool edited = false, target_changed = false;
    static bool remembered = false;
    if (ImGui::IsMouseClicked(ImGuiMouseButton_Left)) remembered = false;
    rig = static_cast<int>(value.rig);
    if (ImGui::Combo("Rig", &rig, rigs, 4)) value.rig = static_cast<re::Rig>(rig), edited = true;
    edited |= ease_combo("Ease", value.ease);
    if (value.rig != re::Rig::free) {
        target_choice("Target", value.target, target_changed);
        edited |= target_changed;
    }
    const char* position = value.rig == re::Rig::follow ? "Offset (r, u, b)" : value.rig == re::Rig::orbit ? "Radius, height, angle" : "Position";
    edited |= ImGui::DragFloat3(position, value.position.data(), 0.05f);
    edited |= ImGui::SliderFloat(value.rig == re::Rig::free ? "Yaw" : "Aim yaw", &value.yaw, -180, 180, "%.1f");
    edited |= ImGui::SliderFloat(value.rig == re::Rig::free ? "Pitch" : "Aim pitch", &value.pitch, -89, 89, "%.1f");
    edited |= ImGui::SliderFloat("Roll", &value.roll, -180, 180, "%.1f");
    edited |= ImGui::SliderFloat("Field of view", &value.fov, 5, 140, "%.0f deg");
    if (value.rig == re::Rig::orbit) edited |= ImGui::SliderFloat("Orbit speed", &value.orbit_speed, -180, 180, "%.0f deg/s");
    bool auto_focus = value.focus < 0;
    if (ImGui::Checkbox("Focus on the target", &auto_focus)) value.focus = auto_focus ? -1.0f : 0.0f, edited = true;
    if (!auto_focus) edited |= ImGui::SliderFloat("Focus distance", &value.focus, 0, 100, value.focus <= 0 ? "off" : "%.1f m");
    if (value.focus != 0) edited |= ImGui::SliderFloat("Blur", &value.blur, 0, 1, "%.2f");
    if (button("SET FROM MONITOR")) {
        if (const auto pose = camera_on_screen()) {
            const auto rig_before = u.new_rig;
            const auto target_before = u.new_target;
            u.new_rig = value.rig;
            u.new_target = value.target;
            auto fresh = key_from(*pose, t);
            fresh.ease = value.ease;
            value = fresh;
            u.new_rig = rig_before;
            u.new_target = target_before;
            edited = true;
        }
    }
    if (edited) {
        if (here && !remembered) {
            remember();
            remembered = true;
        }
        auto* key = key_for_change(clip.camera, t, *base, remembered);
        if (key) {
            value.at = key->at;
            *key = re::clamped(value);
            u.key = KeyRef{Lane::camera, key->at};
            changed();
        }
    }
}

void speed_section(re::Clip& clip) {
    auto& u = ui();
    const double t = std::clamp(now(), clip.in, clip.out);
    std::vector<double> times;
    for (const auto& key : clip.speed) times.push_back(key.at);
    re::SpeedKey* here = re::key_at(clip.speed, t);
    key_navigation("speed", times, t, here != nullptr, &toggle_speed_key);
    const auto index = re::clip_index(u.project, clip.id);
    re::SpeedKey value = here ? *here : re::SpeedKey{t, u.program && index ? u.program->speed(*index, t) : 1.0f, re::Ease::smooth};
    static bool remembered = false;
    if (ImGui::IsMouseClicked(ImGuiMouseButton_Left)) remembered = false;
    bool edited = ImGui::SliderFloat("Speed", &value.speed, re::slowest, 4.0f, "%.2fx", ImGuiSliderFlags_Logarithmic);
    edited |= ease_combo("Speed ease", value.ease);
    for (const float preset : {0.1f, 0.25f, 0.5f, 1.0f, 2.0f}) {
        if (button(std::format("{:g}x", preset).c_str(), std::abs(value.speed - preset) < 1e-3f)) value.speed = preset, edited = true;
        ImGui::SameLine(0, 2 * u.k);
    }
    ImGui::NewLine();
    if (button("SLOW-MO HIT")) {
        remember();
        re::put_key(clip.speed, {std::max(clip.in, t - 0.6), 1, re::Ease::smooth});
        re::put_key(clip.speed, {t, 0.25f, re::Ease::smooth});
        re::put_key(clip.speed, {std::min(clip.out, t + 0.9), 0.25f, re::Ease::smooth});
        re::put_key(clip.speed, {std::min(clip.out, t + 1.4), 1, re::Ease::smooth});
        changed();
    }
    ImGui::SameLine(0, 2 * u.k);
    if (button("RESET SPEED", false, !clip.speed.empty())) {
        remember();
        clip.speed.clear();
        changed();
    }
    if (edited) {
        if (here && !remembered) {
            remember();
            remembered = true;
        }
        if (auto* key = key_for_change(clip.speed, t, value, remembered)) {
            key->speed = std::clamp(value.speed, re::slowest, re::fastest);
            key->ease = value.ease;
            u.key = KeyRef{Lane::speed, key->at};
            changed();
        }
    }
}

void look_section(re::Clip& clip) {
    auto& u = ui();
    const double t = std::clamp(now(), clip.in, clip.out);
    std::vector<double> times;
    for (const auto& key : clip.look) times.push_back(key.at);
    re::LookKey* here = re::key_at(clip.look, t);
    key_navigation("look", times, t, here != nullptr, &toggle_look_key);
    const auto index = re::clip_index(u.project, clip.id);
    re::LookKey value{t, {}, re::Ease::smooth};
    if (here) value = *here;
    else if (u.program && index)
        if (const auto look = u.program->look(*index, t)) value.look = *look;
    static bool remembered = false;
    if (ImGui::IsMouseClicked(ImGuiMouseButton_Left)) remembered = false;
    auto& l = value.look;
    bool edited = ImGui::SliderFloat("Exposure", &l.exposure, -3, 3, "%.2f stops");
    edited |= ImGui::SliderFloat("Saturation", &l.saturation, 0, 2);
    edited |= ImGui::SliderFloat("Brightness", &l.contrast, 0.5f, 1.5f);
    edited |= ImGui::SliderFloat("Hue", &l.hue, -180, 180, "%.0f deg");
    edited |= ImGui::SliderFloat("Vignette", &l.vignette, 0, 1);
    edited |= ImGui::SliderFloat("Fisheye", &l.barrel, 0, 1);
    edited |= ImGui::SliderFloat("Grain", &l.grain, 0, 1);
    edited |= ImGui::SliderFloat("Colour fringe", &l.aberration, 0, 1);
    edited |= ease_combo("Look ease", value.ease);
    if (edited) {
        if (here && !remembered) {
            remember();
            remembered = true;
        }
        if (auto* key = key_for_change(clip.look, t, value, remembered)) {
            key->look = re::clamped(value.look);
            key->ease = value.ease;
            u.key = KeyRef{Lane::look, key->at};
            changed();
        }
    }
}

void titles_tab() {
    auto& u = ui();
    re::Clip* clip = selected_clip();
    if (!clip) return (void)ImGui::TextDisabled("Pick a clip in the sequence.");
    ImGui::TextWrapped("Text over the picture. Titles show in the editor; the game's export films its own picture, so they "
                       "are not in exported videos yet.");
    if (button("ADD TITLE AT THE PLAYHEAD")) {
        u.lane = Lane::titles;
        add_key_here();
    }
    ImGui::Separator();
    for (std::size_t i = 0; i < clip->titles.size(); ++i) {
        auto& title = clip->titles[i];
        ImGui::PushID(static_cast<int>(i));
        const bool selected = u.key && u.key->lane == Lane::titles && std::abs(u.key->at - title.at) < re::same_key;
        if (ImGui::Selectable((title.text + "##title").c_str(), selected)) {
            u.key = KeyRef{Lane::titles, title.at};
            seek(title.at);
        }
        if (selected) {
            std::array<char, 201> text{};
            std::snprintf(text.data(), text.size(), "%s", title.text.c_str());
            if (ImGui::InputText("Text", text.data(), text.size())) {
                title.text = text.data();
                changed();
            }
            if (ImGui::IsItemActivated()) remember();
            int style = static_cast<int>(title.style);
            const char* styles[]{"Title", "Caption", "Label", "Lower third"};
            if (ImGui::Combo("Style", &style, styles, 4)) {
                remember();
                title.style = static_cast<re::TitleStyle>(style);
                changed();
            }
            const double shortest = 0.2, longest = 20;
            bool edited = ImGui::SliderScalar("Length", ImGuiDataType_Double, &title.length, &shortest, &longest, "%.1f s");
            if (ImGui::IsItemActivated()) remember();
            edited |= ImGui::SliderFloat("Across", &title.x, 0, 1);
            if (ImGui::IsItemActivated()) remember();
            edited |= ImGui::SliderFloat("Down", &title.y, 0, 1);
            if (ImGui::IsItemActivated()) remember();
            edited |= ImGui::SliderFloat("Size", &title.size, 0.25f, 3);
            if (ImGui::IsItemActivated()) remember();
            if (edited) changed();
            if (button("DELETE TITLE")) {
                delete_selection();
                ImGui::PopID();
                return;
            }
        }
        ImGui::PopID();
    }
}

void setup_tab() {
    const auto s = status();
    auto settings = re::bridge().settings();
    if (ImGui::Checkbox("Open with the game's replay editor", &settings.open_with_replay)) {
        re::bridge().set_settings(settings);
        re::save_settings(settings);
    }
    ImGui::Separator();
    section_label("STATUS");
    ImGui::Text("Recording reached: %.1f min", (s.window_end - s.window_start) / 60.0);
    ImGui::Text("Footage kept for the edit: %.1f s", s.locked);
    ImGui::Text("Camera: ReSkate's shown %d/s (keyframed camera asked %d/s)", s.camera_shown, s.camera_asks);
    ImGui::TextWrapped(s.view_taken ? "ReSkate's camera has the view." : "The game's replay camera is showing.");
    if (!s.notice.empty()) ImGui::TextWrapped("Last: %s", s.notice.c_str());
    if (button("REMAKE THE FILMSTRIP")) filmstrip_rebuild();
}
} // namespace

// ---- The menu bar ----------------------------------------------------------------------------
void draw_menu_bar(ImVec2 size) {
    auto& u = ui();
    const float k = u.k, height = 26 * k;
    ImDrawList* draw = ImGui::GetWindowDrawList();
    draw->AddRectFilled({0, 0}, {size.x, height}, colour(30, 30, 30));
    ImGui::SetCursorScreenPos({0, 0});
    ImGui::PushStyleColor(ImGuiCol_MenuBarBg, colour(30, 30, 30));
    ImGui::PushStyleColor(ImGuiCol_ChildBg, colour(30, 30, 30));
    if (ImGui::BeginChild("##replay_menu", {size.x, height}, 0, ImGuiWindowFlags_MenuBar | ImGuiWindowFlags_NoScrollbar)) {
        if (ImGui::BeginMenuBar()) {
            ImGui::PushFont(font_or(u.fonts.title));
            ImGui::TextUnformatted("REPLAY EDITOR");
            ImGui::PopFont();
            if (ImGui::BeginMenu("File")) {
                if (ImGui::MenuItem("New project")) {
                    if (u.dirty && !u.project.clips.empty()) save(true);
                    set_project({});
                }
                if (ImGui::MenuItem("Save", "Ctrl+S")) save();
                if (ImGui::MenuItem("Export...", "Ctrl+E", false, !u.project.clips.empty())) u.export_open = true;
                if (ImGui::MenuItem("Open the Replays folder")) {
                    const auto folder = projects_folder();
                    ShellExecuteW(nullptr, L"open", folder.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                }
                if (ImGui::MenuItem("Open the Videos folder")) {
                    const auto folder = re::editor_folder() / L"Game" / L"Skate" / L"data" / L"Videos";
                    ShellExecuteW(nullptr, L"open", folder.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                }
                ImGui::Separator();
                if (ImGui::MenuItem("Back to the game's replay editor")) re::bridge().ask({re::Request::Kind::hand_back});
                if (ImGui::MenuItem("Leave the replay", "Esc")) leave_replay();
                ImGui::EndMenu();
            }
            if (ImGui::BeginMenu("Edit")) {
                if (ImGui::MenuItem("Undo", "Ctrl+Z", false, u.history.can_undo()) && u.history.undo(u.project)) changed();
                if (ImGui::MenuItem("Redo", "Ctrl+Y", false, u.history.can_redo()) && u.history.redo(u.project)) changed();
                ImGui::Separator();
                if (ImGui::MenuItem("Split clip at the playhead", "S")) split_here();
                if (ImGui::MenuItem("Duplicate clip", "Ctrl+D", false, selected_clip() != nullptr)) {
                    remember();
                    if (const auto copy = re::duplicate_clip(u.project, u.selected)) u.selected = *copy;
                    changed();
                }
                if (ImGui::MenuItem("Delete", "Del", false, selected_clip() != nullptr)) delete_selection();
                ImGui::EndMenu();
            }
            if (ImGui::BeginMenu("Marker")) {
                if (ImGui::MenuItem("Mark in", "I")) u.mark_in = now();
                if (ImGui::MenuItem("Mark out", "O")) u.mark_out = now();
                if (ImGui::MenuItem("Clip from in to out", "A", false, u.mark_in || u.mark_out))
                    add_clip(u.mark_in.value_or(status().window_start), u.mark_out.value_or(now()));
                if (ImGui::MenuItem("Clip the moment by the playhead", "C")) clip_from_moment();
                if (ImGui::MenuItem("Add a marker", "M")) re::bridge().ask({re::Request::Kind::add_marker, now()});
                ImGui::EndMenu();
            }
            if (ImGui::BeginMenu("View")) {
                if (ImGui::MenuItem("Source (footage)", "V", u.mode == re::PlayMode::footage)) set_mode(re::PlayMode::footage);
                if (ImGui::MenuItem("Program (edit)", "V", u.mode == re::PlayMode::edit, !u.project.clips.empty())) set_mode(re::PlayMode::edit);
                if (ImGui::MenuItem("Fly the camera", "Tab", u.camera_mode)) u.camera_mode ? leave_camera_mode() : enter_camera_mode();
                if (ImGui::MenuItem("Hide the editor", "H")) u.hide_ui = true;
                if (ImGui::MenuItem("Snapping", "N", u.snapping)) u.snapping = !u.snapping;
                if (ImGui::MenuItem("Remake the filmstrip")) filmstrip_rebuild();
                ImGui::EndMenu();
            }
            if (ImGui::BeginMenu("Help")) {
                if (ImGui::MenuItem("Keys", "F1")) u.help_open = true;
                ImGui::EndMenu();
            }
            // The project and what was said, on the right.
            const auto name = u.project.name + (u.dirty ? " *" : "");
            std::string right = name;
            if (!u.message.empty() && ImGui::GetTime() < u.message_until) right = u.message + "     " + name;
            const float width = ImGui::CalcTextSize(right.c_str()).x;
            ImGui::SameLine(size.x - width - 90 * k);
            ImGui::TextColored(ImGui::ColorConvertU32ToFloat4(!u.message.empty() && ImGui::GetTime() < u.message_until ? colour(255, 210, 90) : palette::dim),
                               "%s", right.c_str());
            ImGui::SameLine(size.x - 80 * k);
            if (button("CLOSE", false, true, 70 * k)) leave_replay();
            ImGui::EndMenuBar();
        }
    }
    ImGui::EndChild();
    ImGui::PopStyleColor(2);
}

// ---- Project ----------------------------------------------------------------------------------
void draw_project(ImVec2 a, ImVec2 z) {
    auto& u = ui();
    const float k = u.k;
    ImDrawList* draw = ImGui::GetWindowDrawList();
    const int pressed = panel_tabs(draw, a, z.x - a.x, {"Project", "Moments", "Looks"}, static_cast<int>(u.project_tab));
    if (pressed >= 0) u.project_tab = static_cast<ProjectTab>(pressed);
    if (!begin_region("##replay_project", {a.x, a.y + 24 * k}, z)) return ImGui::EndChild();
    const auto s = status();
    switch (u.project_tab) {
    case ProjectTab::clips: {
        std::array<char, 81> name{};
        std::snprintf(name.data(), name.size(), "%s", u.project.name.c_str());
        if (ImGui::InputText("##project-name", name.data(), name.size())) {
            u.project.name = name.data();
            u.dirty = true;
        }
        if (!u.project.clips.empty() && u.project.footage != s.run)
            ImGui::TextColored(ImVec4(1, 0.6f, 0.4f, 1), "Footage from an earlier game run: the clips show whatever is recorded at those times now.");
        section_label(std::format("SEQUENCE  ({} clips, {})", u.project.clips.size(), clock(u.program ? u.program->duration() : 0)).c_str());
        // Each clip with its first picture.
        const float thumb_h = 40 * k, thumb_w = thumb_h * 16 / 9;
        for (std::size_t i = 0; i < u.project.clips.size(); ++i) {
            const auto& clip = u.project.clips[i];
            ImGui::PushID(static_cast<int>(clip.id));
            const ImVec2 at = ImGui::GetCursorScreenPos();
            const bool selected = clip.id == u.selected;
            if (ImGui::Selectable("##clip", selected, 0, {0, thumb_h})) {
                u.selected = clip.id;
                u.key.reset();
                seek(clip.in, static_cast<int>(i));
            }
            ImDrawList* list = ImGui::GetWindowDrawList();
            if (const auto picture = filmstrip_cell(clip.in + 0.1)) list->AddImage(picture->texture, at, {at.x + thumb_w, at.y + thumb_h}, picture->uv0, picture->uv1);
            else list->AddRectFilled(at, {at.x + thumb_w, at.y + thumb_h}, colour(50, 50, 50));
            list->AddText({at.x + thumb_w + 8 * k, at.y + 3 * k}, palette::text, clip.name.c_str());
            const auto detail = std::format("{}   {}", clock(clip.in - s.window_start), clock(u.program ? u.program->clip_length(i) : clip.length()));
            list->AddText({at.x + thumb_w + 8 * k, at.y + 21 * k}, palette::dim, detail.c_str());
            ImGui::PopID();
        }
        if (u.project.clips.empty())
            ImGui::TextWrapped("No clips yet. In the timeline's SOURCE row set In (I) and Out (O) and press A, or press C beside a "
                               "moment.");
        ImGui::Separator();
        section_label("SAVED PROJECTS");
        if (ImGui::GetTime() - u.files_listed_at > 5) {
            u.files_listed_at = ImGui::GetTime();
            u.files = re::list_projects(projects_folder());
        }
        for (const auto& file : u.files)
            if (ImGui::Selectable((file.name + "##" + file.path.filename().string()).c_str(), file.name == u.project.name)) {
                std::string why;
                if (auto project = re::load_project(file.path, why)) {
                    if (u.dirty && !u.project.clips.empty()) save(true);
                    set_project(std::move(*project));
                    say("Opened " + file.name);
                } else say("Not opened: " + why, 5);
            }
        if (u.files.empty()) ImGui::TextDisabled("(none yet)");
        break;
    }
    case ProjectTab::moments: {
        const auto moments = re::bridge().moments();
        if (!moments || moments->empty()) {
            ImGui::TextWrapped("Tricks, slams and players coming and going show here as they happen while the game records.");
            break;
        }
        for (std::size_t i = moments->size(); i-- > 0;) {
            const auto& m = (*moments)[i];
            ImGui::PushID(static_cast<int>(i));
            const char* kind = m.kind == re::MomentKind::trick ? "TRICK" : m.kind == re::MomentKind::slam ? "SLAM" :
                               m.kind == re::MomentKind::joined ? "JOINED" : m.kind == re::MomentKind::left ? "LEFT" : "MARK";
            const auto label = m.kind == re::MomentKind::trick ? std::format("{}  {}  {:.0f}", clock(m.at - s.window_start), m.text, m.points)
                                                                : std::format("{}  {} {}", clock(m.at - s.window_start), kind, m.text);
            if (ImGui::Selectable(label.c_str())) seek(m.at);
            if (ImGui::BeginPopupContextItem()) {
                if (ImGui::MenuItem("Make a clip of it")) {
                    seek(m.at);
                    add_clip(m.at - (m.kind == re::MomentKind::trick ? 2.5 : 1.5), m.at + 1.5, m.text);
                }
                ImGui::EndPopup();
            }
            ImGui::PopID();
        }
        break;
    }
    case ProjectTab::looks: {
        ImGui::TextWrapped("A look onto the clip under the playhead, keyed at the playhead.");
        for (const auto& preset : look_presets)
            if (ImGui::Selectable(preset.name)) {
                if (re::Clip* clip = clip_for_keys()) {
                    remember();
                    clip = selected_clip();
                    const double t = std::clamp(now(), clip->in, clip->out);
                    re::put_key(clip->look, {t, preset.look, re::Ease::smooth});
                    u.key = KeyRef{Lane::look, t};
                    changed();
                }
            }
        break;
    }
    }
    ImGui::EndChild();
}

// ---- The monitor --------------------------------------------------------------------------------
void draw_monitor(ImVec2 a, ImVec2 z) {
    auto& u = ui();
    const float k = u.k;
    ImDrawList* draw = ImGui::GetWindowDrawList();
    const int pressed = panel_tabs(draw, a, z.x - a.x, {"Source: footage", "Program: edit"}, u.mode == re::PlayMode::edit ? 1 : 0);
    if (pressed == 0) set_mode(re::PlayMode::footage);
    if (pressed == 1 && !u.project.clips.empty()) set_mode(re::PlayMode::edit);
    const float controls = 70 * k;
    const ImVec2 area_a{a.x, a.y + 24 * k}, area_z{z.x, z.y - controls};
    draw->AddRectFilled(area_a, area_z, colour(12, 12, 12));
    // The picture, as large as fits, at its own shape.
    const auto preview = replay_preview();
    const float aspect = preview.width > 0 && preview.height > 0 ? preview.width / preview.height : 16.0f / 9.0f;
    float w = area_z.x - area_a.x - 16 * k, h = area_z.y - area_a.y - 16 * k;
    if (w / h > aspect) w = h * aspect;
    else h = w / aspect;
    const ImVec2 pa{(area_a.x + area_z.x - w) / 2, (area_a.y + area_z.y - h) / 2}, pz{pa.x + w, pa.y + h};
    u.monitor_a = pa;
    u.monitor_z = pz;
    if (preview.texture) draw->AddImage(preview.texture, pa, pz);
    else draw->AddText(pa, palette::dim, "The picture shows from the next frame.");
    draw_titles_over(pa, pz);
    if (u.camera_mode) draw_camera_hud(pa, pz);
    // Under it: the timecode, the transport, the length.
    const auto s = status();
    const double t = now();
    const auto e = sequence_now();
    const std::string here = u.mode == re::PlayMode::edit && e ? timecode(*e) : timecode(t - s.window_start);
    const std::string total = u.mode == re::PlayMode::edit && u.program ? timecode(u.program->duration()) : timecode(s.window_end - s.window_start);
    ImFont* bold = font_or(u.fonts.bold);
    draw->AddRectFilled({a.x, z.y - controls}, z, palette::panel);
    draw->AddText(bold, 17 * k, {a.x + 12 * k, z.y - controls + 10 * k}, palette::timecode, here.c_str());
    const auto total_size = bold->CalcTextSizeA(15 * k, FLT_MAX, 0, total.c_str());
    draw->AddText(bold, 15 * k, {z.x - total_size.x - 12 * k, z.y - controls + 11 * k}, palette::dim, total.c_str());
    if (u.playing) {
        const auto speed = std::format("{}{:g}x", u.shuttle < 0 ? "-" : "", std::abs(u.shuttle));
        draw->AddText(bold, 13 * k, {a.x + 12 * k, z.y - controls + 34 * k}, colour(120, 220, 140), speed.c_str());
    }
    // The transport, in the middle.
    const float bw = 38 * k, row_y = z.y - controls + 8 * k;
    const char* labels[]{"{", "}", "|<", "<", "PLAY", ">", ">|", "LOOP", "+CLIP", "CAM", "KEY"};
    const float total_w = bw * 10 + 64 * k + 2 * k * 10;
    ImGui::SetCursorScreenPos({(a.x + z.x - total_w) / 2, row_y});
    for (int i = 0; i < 11; ++i) {
        ImGui::PushID(i);
        const float width = i == 4 ? 64 * k : bw;
        const char* label = i == 4 ? (u.playing ? "PAUSE" : "PLAY") : labels[i];
        const bool on = (i == 0 && u.mark_in) || (i == 1 && u.mark_out) || (i == 4 && u.playing) || (i == 7 && u.loop) || (i == 9 && u.camera_mode);
        if (button(label, on, i != 8 || u.mark_in || u.mark_out, width)) switch (i) {
            case 0: u.mark_in = t; break;
            case 1: u.mark_out = t; break;
            case 2: jump(-1); break;
            case 3: step(-1.0 / 60); break;
            case 4: toggle_play(); break;
            case 5: step(1.0 / 60); break;
            case 6: jump(1); break;
            case 7: u.loop = !u.loop; break;
            case 8: add_clip(u.mark_in.value_or(s.window_start), u.mark_out.value_or(t)); break;
            case 9: u.camera_mode ? leave_camera_mode() : enter_camera_mode(); break;
            case 10: add_key_here(); break;
            default: break;
            }
        if (ImGui::IsItemHovered()) {
            const char* tips[]{"Mark in (I)", "Mark out (O)", "Previous edit point (Up)", "Back a frame (Left)", "Play / pause (Space)",
                               "Forward a frame (Right)", "Next edit point (Down)", "Loop the edit", "Clip from in to out (A)",
                               "Fly the camera (Tab)", "Key the selected row at the playhead (F)"};
            ImGui::SetTooltip("%s", tips[i]);
        }
        ImGui::SameLine(0, 2 * k);
        ImGui::PopID();
    }
    ImGui::NewLine();
}

// ---- Effect Controls --------------------------------------------------------------------------
void draw_effects(ImVec2 a, ImVec2 z) {
    auto& u = ui();
    const float k = u.k;
    ImDrawList* draw = ImGui::GetWindowDrawList();
    const int pressed = panel_tabs(draw, a, z.x - a.x, {"Effect Controls", "Titles", "Setup"}, static_cast<int>(u.effects_tab));
    if (pressed >= 0) u.effects_tab = static_cast<EffectsTab>(pressed);
    if (!begin_region("##replay_effects", {a.x, a.y + 24 * k}, z)) return ImGui::EndChild();
    ImGui::PushItemWidth(-128 * k);
    switch (u.effects_tab) {
    case EffectsTab::effects: {
        re::Clip* clip = selected_clip();
        if (!clip) {
            ImGui::TextWrapped("Pick a clip in the sequence (or in Project) to change its camera, speed and look. Values change at "
                               "the playhead: where there is no key, a change makes one.");
            break;
        }
        section_label(clip->name.c_str());
        if (ImGui::CollapsingHeader("Clip", ImGuiTreeNodeFlags_DefaultOpen)) clip_section(*clip);
        clip = selected_clip();
        if (clip && ImGui::CollapsingHeader("Camera", ImGuiTreeNodeFlags_DefaultOpen)) camera_section(*clip);
        clip = selected_clip();
        if (clip && ImGui::CollapsingHeader("Time remapping", ImGuiTreeNodeFlags_DefaultOpen)) speed_section(*clip);
        clip = selected_clip();
        if (clip && ImGui::CollapsingHeader("Look", ImGuiTreeNodeFlags_DefaultOpen)) look_section(*clip);
        break;
    }
    case EffectsTab::titles: titles_tab(); break;
    case EffectsTab::setup: setup_tab(); break;
    }
    ImGui::PopItemWidth();
    ImGui::EndChild();
}

// ---- Over the picture ---------------------------------------------------------------------
void draw_titles_over(ImVec2 a, ImVec2 z) {
    auto& u = ui();
    if (!u.program || u.program->empty()) return;
    const auto index = showing_clip_index();
    if (!index || *index >= u.project.clips.size()) return;
    const double t = now();
    ImDrawList* draw = ImGui::GetForegroundDrawList();
    const float w = z.x - a.x, h = z.y - a.y, k = h / 1080.0f;
    draw->PushClipRect(a, z, true);
    const auto text = [&](const std::string& words, float x, float y, float height, re::TitleStyle style, float alpha) {
        ImFont* font = style == re::TitleStyle::title ? font_or(u.fonts.title) : style == re::TitleStyle::caption ? font_or(u.fonts.body) : font_or(u.fonts.bold);
        const auto extent = font->CalcTextSizeA(height, FLT_MAX, 0, words.c_str());
        const ImVec2 at{a.x + x * w - extent.x / 2, a.y + y * h - extent.y / 2};
        const auto alpha8 = static_cast<int>(alpha * 255);
        if (style == re::TitleStyle::label || style == re::TitleStyle::lower_third) {
            const float pad = 12 * k;
            draw->AddRectFilled({at.x - pad, at.y - pad * 0.5f}, {at.x + extent.x + pad, at.y + extent.y + pad * 0.5f}, colour(15, 15, 15, alpha8 * 3 / 4), 4 * k);
            if (style == re::TitleStyle::lower_third)
                draw->AddRectFilled({at.x - pad, at.y + extent.y + pad * 0.5f}, {at.x + extent.x + pad, at.y + extent.y + pad * 0.5f + 4 * k},
                                    (palette::accent & 0x00ffffff) | (static_cast<ImU32>(alpha8) << 24));
        } else draw->AddText(font, height, {at.x + 2 * k, at.y + 2 * k}, colour(0, 0, 0, alpha8 / 2), words.c_str());
        draw->AddText(font, height, at, colour(255, 255, 255, alpha8), words.c_str());
    };
    const auto fade = [](double progress, double length) {
        const double edge = std::min(0.3, length / 3), seconds = progress * length;
        return static_cast<float>(std::clamp(std::min(seconds / edge, (length - seconds) / edge), 0.0, 1.0));
    };
    for (const auto& shown : u.program->titles(*index, t)) {
        const auto& title = *shown.title;
        const float height = (title.style == re::TitleStyle::title ? 72.0f : title.style == re::TitleStyle::caption ? 34.0f : 36.0f) * title.size * k;
        text(title.text, title.x, title.y, height, title.style, fade(shown.progress, title.length));
    }
    const auto& clip = u.project.clips[*index];
    if (clip.trick_labels)
        if (const auto moments = re::bridge().moments())
            for (const auto& m : *moments) {
                if (m.kind != re::MomentKind::trick || m.at < clip.in || m.at > clip.out || t < m.at || t > m.at + 2.2) continue;
                const auto words = m.points > 0 ? std::format("{}   {:.0f}", m.text, m.points) : m.text;
                text(words, 0.5f, 0.72f, 38 * k, re::TitleStyle::label, fade((t - m.at) / 2.2, 2.2));
            }
    draw->PopClipRect();
}

void draw_camera_hud(ImVec2 a, ImVec2 z) {
    auto& u = ui();
    ImDrawList* draw = ImGui::GetForegroundDrawList();
    const float k = u.k;
    const ImVec2 c{(a.x + z.x) / 2, (a.y + z.y) / 2};
    draw->AddLine({c.x - 14 * k, c.y}, {c.x + 14 * k, c.y}, colour(255, 255, 255, 200), 1.5f * k);
    draw->AddLine({c.x, c.y - 14 * k}, {c.x, c.y + 14 * k}, colour(255, 255, 255, 200), 1.5f * k);
    const auto line = std::format("CAMERA   FOV {:.0f}   FOCUS {}   ROLL {:.0f}   new keys: {}", u.fly_fov,
                                  u.fly_focus > 0 ? std::format("{:.1f} m", u.fly_focus) : std::string("off"), u.fly_roll, re::rig_name(u.new_rig));
    ImFont* font = font_or(u.fonts.bold);
    const auto extent = font->CalcTextSizeA(14 * k, FLT_MAX, 0, line.c_str());
    const ImVec2 at{c.x - extent.x / 2, a.y + 10 * k};
    draw->AddRectFilled({at.x - 10 * k, at.y - 4 * k}, {at.x + extent.x + 10 * k, at.y + extent.y + 4 * k}, colour(15, 15, 15, 200), 4 * k);
    draw->AddText(font, 14 * k, at, palette::text, line.c_str());
    const char* hint = "WASD / left stick fly   right mouse / right stick look   Q E down up   wheel zoom   Enter / A key   Tab done";
    const auto hint_size = font_or(u.fonts.body)->CalcTextSizeA(12 * k, FLT_MAX, 0, hint);
    draw->AddText(font_or(u.fonts.body), 12 * k, {c.x - hint_size.x / 2, z.y - 22 * k}, colour(230, 230, 230), hint);
}

// ---- Dialogs ----------------------------------------------------------------------------------
void draw_export_dialog(ImVec2 size) {
    auto& u = ui();
    const float k = u.k;
    ImGui::SetNextWindowPos({size.x / 2, size.y / 2}, ImGuiCond_Always, {0.5f, 0.5f});
    ImGui::SetNextWindowSize({540 * k, 0});
    ImGui::PushStyleColor(ImGuiCol_WindowBg, colour(32, 32, 32, 252));
    ImGui::PushStyleColor(ImGuiCol_TitleBgActive, palette::header);
    if (ImGui::Begin("Export##replay_export", &u.export_open, ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings |
                                                                  ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoMove)) {
        auto& c = u.export_choice;
        section_label("PRESET");
        for (int i = 0; i < static_cast<int>(re::export_presets.size()); ++i) {
            if (button(re::export_presets[static_cast<std::size_t>(i)].name, u.preset == i)) {
                u.preset = i;
                c = re::export_presets[static_cast<std::size_t>(i)].choice;
            }
            if (i % 3 != 2) ImGui::SameLine();
        }
        ImGui::NewLine();
        ImGui::Separator();
        int format = c.format;
        const char* formats[]{"MP4 (H.264)", "WebM (VP8)"};
        if (ImGui::Combo("Format", &format, formats, 2)) c.format = format, u.preset = -1;
        int fps = c.fps == 24 ? 0 : c.fps == 30 ? 1 : 2;
        const char* rates[]{"24 fps", "30 fps", "60 fps"};
        if (ImGui::Combo("Frame rate", &fps, rates, 3)) c.fps = fps == 0 ? 24 : fps == 1 ? 30 : 60, u.preset = -1;
        const char* sizes[]{"720p", "1080p", "1440p", "2160p"};
        const int widths[]{1280, 1920, 2560, 3840}, heights[]{720, 1080, 1440, 2160};
        int size_index = 1;
        for (int i = 0; i < 4; ++i)
            if (c.height == heights[i]) size_index = i;
        if (ImGui::Combo("Size", &size_index, sizes, 4)) c.width = widths[size_index], c.height = heights[size_index], u.preset = -1;
        // The game's picture: the monitor's copy of it.
        const auto picture = replay_preview();
        const float game_aspect = picture.width > 0 && picture.height > 0 ? picture.width / picture.height : 16.0f / 9.0f;
        ImGui::Checkbox("The game's shape", &c.game_shape);
        const auto [video_width, video_height] = re::export_size(c, game_aspect);
        ImGui::SameLine();
        ImGui::TextDisabled(c.game_shape ? "%d x %d, as the game shows it" : "%d x %d: the game's picture is scaled into it", video_width,
                            video_height);
        if (ImGui::SliderInt("Bitrate", &c.kbps, 2000, 100000, "%d kbps", ImGuiSliderFlags_Logarithmic)) u.preset = -1;
        int what = c.whole_edit ? 0 : 1;
        ImGui::RadioButton("The whole sequence", &what, 0);
        ImGui::SameLine();
        ImGui::RadioButton("The clip under the playhead", &what, 1);
        c.whole_edit = what == 0;
        const double length = u.program ? u.program->duration() : 0;
        ImGui::TextDisabled("%s long, about %.0f MB", clock(length).c_str(), length * c.kbps / 8.0 / 1000.0);
        ImGui::TextWrapped("The game films the edit frame by frame into its Videos folder. Titles are the editor's and are not in it yet.");
        if (button("EXPORT", true, u.program && !u.program->empty(), 160 * k)) {
            auto settings = re::bridge().settings();
            settings.export_choice = c;
            settings.preset = u.preset;
            re::bridge().set_settings(settings);
            re::save_settings(settings);
            u.playing = false;
            leave_camera_mode();
            re::Request request{re::Request::Kind::export_edit};
            request.choice = c;
            std::tie(request.choice.width, request.choice.height) = re::export_size(c, game_aspect);
            re::bridge().ask(request);
            u.export_open = false;
            say("Exporting...", 2);
        }
    }
    ImGui::End();
    ImGui::PopStyleColor(2);
}

void draw_help_dialog(ImVec2 size) {
    auto& u = ui();
    ImGui::SetNextWindowPos({size.x / 2, size.y / 2}, ImGuiCond_Always, {0.5f, 0.5f});
    ImGui::SetNextWindowSize({720 * u.k, 0});
    ImGui::PushStyleColor(ImGuiCol_WindowBg, colour(32, 32, 32, 252));
    if (ImGui::Begin("Keys##replay_help", &u.help_open, ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings |
                                                           ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoMove)) {
        const char* rows[][3]{{"Play / pause", "Space", "A"},
                              {"Shuttle back / pause / forward", "J / K / L (again: faster)", "LT / RT (how far pulled)"},
                              {"Step a frame / a second", "Left Right / Shift", "D-pad left right"},
                              {"Previous / next edit point", "Up / Down", "LB / RB"},
                              {"In / out", "I / O", "Y + D-pad left / right"},
                              {"Clip from in to out", "A", "Y + D-pad down"},
                              {"Clip the moment by the playhead", "C", ""},
                              {"Split the clip", "S or Ctrl+B", ""},
                              {"Key the selected row", "F", "X"},
                              {"Pick a row", "1 2 3 4", "D-pad up / down"},
                              {"Fly the camera", "Tab, WASD, right mouse, Q/E", "R3, sticks, LB/RB"},
                              {"Source / Program", "V", ""},
                              {"Delete", "Delete", ""},
                              {"Undo / redo", "Ctrl+Z / Ctrl+Y", ""},
                              {"Save / export", "Ctrl+S / Ctrl+E", "View"},
                              {"Hide the editor", "H", "L3"},
                              {"Zoom the source row", "wheel over it", "Right stick"},
                              {"Leave the replay", "Esc", "hold B"}};
        if (ImGui::BeginTable("keys", 3, ImGuiTableFlags_RowBg)) {
            ImGui::TableSetupColumn("");
            ImGui::TableSetupColumn("Keyboard and mouse");
            ImGui::TableSetupColumn("Controller");
            ImGui::TableHeadersRow();
            for (const auto& row : rows) {
                ImGui::TableNextRow();
                for (int c = 0; c < 3; ++c) {
                    ImGui::TableSetColumnIndex(c);
                    ImGui::TextUnformatted(row[c]);
                }
            }
            ImGui::EndTable();
        }
    }
    ImGui::End();
    ImGui::PopStyleColor();
}
} // namespace dingosdk::overlay::replay_ui
