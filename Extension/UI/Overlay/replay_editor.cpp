#include "replay_editor_internal.h"
#include "overlay_internal.h"
#include "Extension/Plugins/plugin_camera.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <format>

// The replay editor's screen: the frame, the layout, the input and the edit's actions. Keyboard and
// mouse work as in a video editor (J/K/L, I/O, S...); a controller works too (the triggers shuttle,
// the bumpers jump, R3 flies the camera). The panels are replay_editor_panels.cpp and
// replay_editor_timeline.cpp.
namespace dingosdk::overlay {
namespace replay_ui {
namespace {
constexpr double frame = 1.0 / 60.0;
constexpr float menu_height = 26, splitter = 5;
constexpr unsigned pad_up = 0x0001, pad_down = 0x0002, pad_left = 0x0004, pad_right = 0x0008, pad_start = 0x0010, pad_back = 0x0020,
                   pad_l3 = 0x0040, pad_r3 = 0x0080, pad_lb = 0x0100, pad_rb = 0x0200, pad_a = 0x1000, pad_b = 0x2000, pad_x = 0x4000,
                   pad_y = 0x8000;

ImFont* font_or(ImFont* font) { return font ? font : ImGui::GetFont(); }

std::optional<re::TargetPlace> target_now(const re::Target& target) {
    for (const auto& t : status().targets)
        if (t.target.player == target.player && (t.target.part == target.part || target.player != 0)) return t.place;
    return std::nullopt;
}

// The camera flown from the keyboard and mouse (the right button over the monitor turns it) or the
// controller.
void fly(const Gamepad& pad) {
    auto& u = ui();
    const auto& io = ImGui::GetIO();
    const float dt = std::clamp(io.DeltaTime, 0.0f, 0.1f);
    const auto pose = re::camera_from(u.fly_position, u.fly_yaw, u.fly_pitch, 0, u.fly_fov);
    const float speed = u.fly_speed * (ImGui::IsKeyDown(ImGuiKey_LeftShift) ? 3.0f : 1.0f) * (ImGui::IsKeyDown(ImGuiKey_LeftCtrl) ? 0.25f : 1.0f);
    float forward = 0, sideways = 0, rise = 0, roll = 0, zoom = 0, yaw_rate = 0, pitch_rate = 0;
    if (!io.WantTextInput) {
        forward += (ImGui::IsKeyDown(ImGuiKey_W) ? 1.0f : 0.0f) - (ImGui::IsKeyDown(ImGuiKey_S) ? 1.0f : 0.0f);
        sideways += (ImGui::IsKeyDown(ImGuiKey_D) ? 1.0f : 0.0f) - (ImGui::IsKeyDown(ImGuiKey_A) ? 1.0f : 0.0f);
        rise += (ImGui::IsKeyDown(ImGuiKey_E) ? 1.0f : 0.0f) - (ImGui::IsKeyDown(ImGuiKey_Q) ? 1.0f : 0.0f);
        roll += (ImGui::IsKeyDown(ImGuiKey_X) ? 1.0f : 0.0f) - (ImGui::IsKeyDown(ImGuiKey_Z) ? 1.0f : 0.0f);
    }
    if (pad.valid) {
        const auto dead = [](float v) { return std::abs(v) < 0.18f ? 0.0f : v; };
        forward += dead(pad.left_y);
        sideways += dead(pad.left_x);
        rise += ((pad.buttons & pad_rb) ? 1.0f : 0.0f) - ((pad.buttons & pad_lb) ? 1.0f : 0.0f);
        roll += ((pad.buttons & pad_right) ? 1.0f : 0.0f) - ((pad.buttons & pad_left) ? 1.0f : 0.0f);
        zoom += pad.left_trigger - pad.right_trigger;
        yaw_rate = -dead(pad.right_x) * 110 * (u.fly_fov / 65);
        pitch_rate = dead(pad.right_y) * 80 * (u.fly_fov / 65);
        u.fly_yaw += yaw_rate * dt;
        u.fly_pitch += pitch_rate * dt;
        if (pad.buttons & pad_up) u.fly_focus = std::min(200.0f, u.fly_focus + 4 * dt * std::max(1.0f, u.fly_focus));
        if (pad.buttons & pad_down) u.fly_focus = std::max(0.0f, u.fly_focus - 4 * dt * std::max(1.0f, u.fly_focus));
    }
    // The raw mouse (the pointer stops at the window's edge), the editor's own count of it. The game
    // can take its raw mouse registration away (until the editor is opened again): with no raw packet
    // for half a second the cursor turns the camera instead, put back in the monitor's middle each frame.
    auto& s = detail::state();
    long turn_x = s.replay_mouse_x.exchange(0), turn_y = s.replay_mouse_y.exchange(0);
    const bool raw_live = turn_x || turn_y || GetTickCount64() - s.raw_mouse_at.load() < 500;
    const bool over_monitor = ImGui::IsMouseHoveringRect(u.monitor_a, u.monitor_z, false);
    re::Bridge::LiveTurn live_turn;
    const float turn = 0.08f * (u.fly_fov / 65);
    live_turn.per_count = turn;
    if (ImGui::IsMouseDown(ImGuiMouseButton_Right) && (over_monitor || ImGui::IsMouseDragging(ImGuiMouseButton_Right))) {
        ImGui::SetMouseCursor(ImGuiMouseCursor_None);
        live_turn.turning = raw_live;
        if (!raw_live) {
            POINT now{};
            if (GetCursorPos(&now)) {
                if (u.cursor_turning) {
                    turn_x = now.x - u.cursor_x;
                    turn_y = now.y - u.cursor_y;
                }
                POINT middle{static_cast<LONG>((u.monitor_a.x + u.monitor_z.x) / 2), static_cast<LONG>((u.monitor_a.y + u.monitor_z.y) / 2)};
                if (ClientToScreen(s.window.load(), &middle) && SetCursorPos(middle.x, middle.y)) now = middle;
                u.cursor_x = now.x;
                u.cursor_y = now.y;
                u.cursor_turning = true;
            }
        }
        u.fly_yaw -= static_cast<float>(turn_x) * turn;
        u.fly_pitch -= static_cast<float>(turn_y) * turn;
        if (!raw_live) {
            live_turn.extra_yaw = -static_cast<float>(turn_x) * turn;
            live_turn.extra_pitch = -static_cast<float>(turn_y) * turn;
        }
    } else u.cursor_turning = false;
    if (over_monitor && io.MouseWheel != 0) {
        if (io.KeyCtrl) u.fly_focus = std::clamp(u.fly_focus * (io.MouseWheel > 0 ? 1.15f : 0.87f) + (io.MouseWheel > 0 ? 0.2f : -0.2f), 0.0f, 200.0f);
        else if (io.KeyAlt) u.fly_roll += io.MouseWheel * 2;
        else u.fly_fov = std::clamp(u.fly_fov - io.MouseWheel * 3, 5.0f, 140.0f);
    }
    u.fly_fov = std::clamp(u.fly_fov + zoom * 40 * dt, 5.0f, 140.0f);
    u.fly_roll += roll * 45 * dt;
    u.fly_pitch = std::clamp(u.fly_pitch, -89.0f, 89.0f);
    while (u.fly_yaw > 180) u.fly_yaw -= 360;
    while (u.fly_yaw < -180) u.fly_yaw += 360;
    const re::Vec3 ahead{-pose.back[0], -pose.back[1], -pose.back[2]};
    re::Vec3 velocity{};
    for (int c = 0; c < 3; ++c) velocity[c] = (ahead[c] * forward + pose.right[c] * sideways) * speed;
    velocity[1] += rise * speed;
    for (int c = 0; c < 3; ++c) u.fly_position[c] += velocity[c] * dt;
    auto shown = re::camera_from(u.fly_position, u.fly_yaw, u.fly_pitch, u.fly_roll, u.fly_fov);
    shown.focus = u.fly_focus;
    shown.blur = u.fly_blur;
    live_turn.yaw = u.fly_yaw;
    live_turn.pitch = u.fly_pitch;
    live_turn.roll = u.fly_roll;
    live_turn.yaw_rate = yaw_rate;
    live_turn.pitch_rate = pitch_rate;
    re::bridge().set_live_camera(shown, velocity, live_turn);
}

void keyboard() {
    auto& u = ui();
    const auto& io = ImGui::GetIO();
    if (io.WantTextInput) return;
    const bool ctrl = io.KeyCtrl, shift = io.KeyShift;
    const auto pressed = [](ImGuiKey key, bool repeat = false) { return ImGui::IsKeyPressed(key, repeat); };
    if (pressed(ImGuiKey_Escape)) {
        if (u.export_open || u.help_open) u.export_open = u.help_open = false;
        else if (u.camera_mode) leave_camera_mode();
        else leave_replay();
        return;
    }
    if (pressed(ImGuiKey_Tab)) {
        if (u.camera_mode) leave_camera_mode();
        else enter_camera_mode();
    }
    if (u.camera_mode) {
        if (pressed(ImGuiKey_Enter) || pressed(ImGuiKey_KeypadEnter) || pressed(ImGuiKey_F)) add_key_here();
        if (pressed(ImGuiKey_Space)) toggle_play();
        return; // the rest of the keys fly the camera
    }
    if (ctrl && pressed(ImGuiKey_Z)) {
        if (shift ? u.history.redo(u.project) : u.history.undo(u.project)) changed();
        return;
    }
    if (ctrl && pressed(ImGuiKey_Y)) {
        if (u.history.redo(u.project)) changed();
        return;
    }
    if (ctrl && pressed(ImGuiKey_S)) return save();
    if (ctrl && pressed(ImGuiKey_E)) {
        u.export_open = true;
        return;
    }
    if (ctrl && pressed(ImGuiKey_B)) return split_here();
    if (ctrl && pressed(ImGuiKey_D)) {
        if (selected_clip()) {
            remember();
            if (const auto copy = re::duplicate_clip(u.project, u.selected)) u.selected = *copy;
            changed();
        }
        return;
    }
    if (ctrl) return;
    if (pressed(ImGuiKey_Space)) toggle_play();
    if (pressed(ImGuiKey_K)) u.playing = false;
    if (pressed(ImGuiKey_L)) shuttle(1);
    if (pressed(ImGuiKey_J)) shuttle(-1);
    if (pressed(ImGuiKey_LeftArrow, true)) step(shift ? -1.0 : -frame);
    if (pressed(ImGuiKey_RightArrow, true)) step(shift ? 1.0 : frame);
    if (pressed(ImGuiKey_UpArrow, true)) jump(-1);
    if (pressed(ImGuiKey_DownArrow, true)) jump(1);
    if (pressed(ImGuiKey_Home)) seek(u.mode == re::PlayMode::edit && !u.project.clips.empty() ? u.project.clips.front().in : status().window_start, 0);
    if (pressed(ImGuiKey_End))
        seek(u.mode == re::PlayMode::edit && !u.project.clips.empty() ? u.project.clips.back().out : status().window_end,
             static_cast<int>(u.project.clips.size()) - 1);
    if (pressed(ImGuiKey_I)) u.mark_in = now();
    if (pressed(ImGuiKey_O)) u.mark_out = now();
    if (pressed(ImGuiKey_A) || pressed(ImGuiKey_Comma) || pressed(ImGuiKey_Period)) {
        if (u.mark_in || u.mark_out) add_clip(u.mark_in.value_or(status().window_start), u.mark_out.value_or(now()));
        else say("Set In (I) and Out (O) first.");
    }
    if (pressed(ImGuiKey_C)) clip_from_moment();
    if (pressed(ImGuiKey_S)) split_here();
    if (pressed(ImGuiKey_Delete) || pressed(ImGuiKey_Backspace)) delete_selection();
    if (pressed(ImGuiKey_F)) add_key_here();
    if (pressed(ImGuiKey_M)) re::bridge().ask({re::Request::Kind::add_marker, now()});
    if (pressed(ImGuiKey_V)) set_mode(u.mode == re::PlayMode::edit ? re::PlayMode::footage : re::PlayMode::edit);
    if (pressed(ImGuiKey_H) || pressed(ImGuiKey_GraveAccent)) u.hide_ui = !u.hide_ui;
    if (pressed(ImGuiKey_N)) {
        u.snapping = !u.snapping;
        say(u.snapping ? "Snapping on." : "Snapping off.");
    }
    if (pressed(ImGuiKey_1)) u.lane = Lane::camera;
    if (pressed(ImGuiKey_2)) u.lane = Lane::speed;
    if (pressed(ImGuiKey_3)) u.lane = Lane::look;
    if (pressed(ImGuiKey_4)) u.lane = Lane::titles;
    if (pressed(ImGuiKey_F1) || (shift && pressed(ImGuiKey_Slash))) u.help_open = !u.help_open;
}

void controller(const Gamepad& pad) {
    auto& u = ui();
    if (!pad.valid) {
        u.pad_before = 0;
        return;
    }
    const unsigned down = pad.buttons, fresh = down & ~u.pad_before;
    u.pad_before = down;
    const double time = ImGui::GetTime();
    const auto held_repeat = [&](unsigned bit) {
        if (fresh & bit) {
            u.pad_repeat_at = time + 0.35;
            return true;
        }
        if ((down & bit) && time >= u.pad_repeat_at) {
            u.pad_repeat_at = time + 0.06;
            return true;
        }
        return false;
    };
    // B: back; held a second, out of the replay.
    if (down & pad_b) {
        if (u.b_held_since < 0) u.b_held_since = time;
        else if (time - u.b_held_since > 1.0 && !u.camera_mode) {
            u.b_held_since = 1e9;
            leave_replay();
        }
    } else u.b_held_since = -1;
    if (fresh & pad_b) {
        if (u.export_open || u.help_open) u.export_open = u.help_open = false;
        else if (u.camera_mode) leave_camera_mode();
    }
    if (fresh & pad_r3) {
        if (u.camera_mode) leave_camera_mode();
        else enter_camera_mode();
    }
    if (fresh & pad_l3) u.hide_ui = !u.hide_ui;
    if (fresh & pad_back) u.export_open = !u.export_open;
    if (fresh & pad_start) u.project_tab = u.project_tab == ProjectTab::clips ? ProjectTab::moments : ProjectTab::clips;
    if (u.camera_mode) {
        if (fresh & pad_a) add_key_here();
        return; // sticks, bumpers, triggers and the pad fly the camera
    }
    if (fresh & pad_a) toggle_play();
    if (fresh & pad_x) add_key_here();
    if (down & pad_y) {
        if (fresh & pad_left) u.mark_in = now();
        else if (fresh & pad_right) u.mark_out = now();
        else if ((fresh & pad_down) && (u.mark_in || u.mark_out)) add_clip(u.mark_in.value_or(status().window_start), u.mark_out.value_or(now()));
    } else {
        if (held_repeat(pad_left)) step(-frame);
        if (held_repeat(pad_right)) step(frame);
        if (fresh & pad_up) u.lane = static_cast<Lane>(std::max(1, static_cast<int>(u.lane) - 1));
        if (fresh & pad_down) u.lane = static_cast<Lane>(std::min(lane_count - 1, static_cast<int>(u.lane) + 1));
    }
    if (fresh & pad_lb) jump(-1);
    if (fresh & pad_rb) jump(1);
    // The triggers shuttle: how far one is pulled is how fast (squared, up to 8x).
    const float back = pad.left_trigger, ahead = pad.right_trigger;
    if (back > 0.08f || ahead > 0.08f) {
        const float pull = ahead > back ? ahead : -back;
        u.shuttle = std::copysign(std::max(0.1, 8.0 * pull * pull), static_cast<double>(pull));
        u.playing = true;
        u.pad_shuttling = true;
    } else if (u.pad_shuttling) {
        u.pad_shuttling = false;
        u.playing = false;
        u.shuttle = 1;
    }
    // The right stick zooms (up and down) and scrolls (left and right) the source row.
    if (std::abs(pad.right_y) > 0.3f || std::abs(pad.right_x) > 0.3f) {
        const auto s = status();
        const double dt = std::clamp(static_cast<double>(ImGui::GetIO().DeltaTime), 0.0, 0.1);
        double span = std::clamp((u.view_to - u.view_from) * std::pow(0.25, pad.right_y * dt), 2.0, std::max(2.0, s.window_end - s.window_start));
        const double centre = (u.view_from + u.view_to) / 2 + pad.right_x * span * dt;
        u.view_from = std::clamp(centre - span / 2, s.window_start, std::max(s.window_start, s.window_end - span));
        u.view_to = u.view_from + span;
    }
}

// A bar between panels that drags their sizes.
void splitter_bar(const char* id, ImVec2 a, ImVec2 z, bool vertical, float& size, float sign, float least, float most) {
    auto& u = ui();
    ImGui::SetCursorScreenPos(a);
    ImGui::InvisibleButton(id, {std::max(1.0f, z.x - a.x), std::max(1.0f, z.y - a.y)});
    const bool hot = ImGui::IsItemHovered() || ImGui::IsItemActive();
    if (hot) ImGui::SetMouseCursor(vertical ? ImGuiMouseCursor_ResizeEW : ImGuiMouseCursor_ResizeNS);
    if (ImGui::IsItemActive()) {
        const float delta = (vertical ? ImGui::GetIO().MouseDelta.x : ImGui::GetIO().MouseDelta.y) / u.k;
        size = std::clamp(size + delta * sign, least, most);
    }
    ImGui::GetWindowDrawList()->AddRectFilled(a, z, hot ? palette::accent : palette::line);
}
} // namespace

// ---- The edit's actions ---------------------------------------------------------------------
std::filesystem::path projects_folder() {
    const auto folder = re::editor_folder();
    return folder.empty() ? std::filesystem::path{} : folder / L"Replays";
}

void save(bool quiet) {
    auto& u = ui();
    std::string why;
    const auto folder = projects_folder();
    if (folder.empty()) return say("The Replays folder is unavailable.");
    const auto path = re::save_project(folder, u.project, why);
    if (path.empty()) return say("Not saved: " + why, 5);
    u.dirty = false;
    u.saved_at = ImGui::GetTime();
    u.files_listed_at = -100;
    if (!quiet) say("Saved " + path.filename().string());
}

std::optional<re::CameraPose> camera_on_screen() {
    auto& u = ui();
    if (u.camera_mode) return re::camera_from(u.fly_position, u.fly_yaw, u.fly_pitch, u.fly_roll, u.fly_fov);
    const auto view = plugin_camera::camera_now();
    if (!view) return std::nullopt;
    auto pose = re::camera_from_matrix(view->world);
    pose.fov = view->vertical_fov > 1 && view->vertical_fov < 175 ? view->vertical_fov : 65;
    return pose;
}

re::Clip* clip_for_keys() {
    auto& u = ui();
    const double t = now();
    if (auto* clip = selected_clip(); clip && t >= clip->in - 1e-6 && t <= clip->out + 1e-6) return clip;
    if (u.program)
        if (const auto index = u.program->clip_at_replay(t)) {
            u.selected = u.project.clips[*index].id;
            return &u.project.clips[*index];
        }
    say("Put the playhead inside a clip first (make one with I, O and A).");
    return nullptr;
}

re::CameraKey key_from(const re::CameraPose& pose, double t) {
    auto& u = ui();
    re::CameraKey key;
    key.at = t;
    key.rig = u.new_rig;
    key.target = u.new_target;
    key.fov = pose.fov;
    key.focus = u.fly_focus;
    key.blur = u.fly_blur;
    const auto angles = re::camera_angles(pose.right, pose.up, pose.back);
    key.yaw = angles[0];
    key.pitch = angles[1];
    key.roll = angles[2];
    key.position = pose.position;
    const auto target = key.rig == re::Rig::free ? std::nullopt : target_now(key.target);
    if (key.rig != re::Rig::free && !target) {
        say("That player is not known here, so the key is a free one.");
        key.rig = re::Rig::free;
    }
    if (target) {
        const auto aim = re::aim(pose.position, target->position);
        key.yaw = angles[0] - aim[0];
        while (key.yaw > 180) key.yaw -= 360;
        while (key.yaw < -180) key.yaw += 360;
        key.pitch = angles[1] - aim[1];
        const re::Vec3 d{pose.position[0] - target->position[0], pose.position[1] - target->position[1], pose.position[2] - target->position[2]};
        if (key.rig == re::Rig::follow) {
            const auto& h = target->heading;
            const re::Vec3 right{-h[2], 0, h[0]};
            key.position = {d[0] * right[0] + d[2] * right[2], d[1], -(d[0] * h[0] + d[2] * h[2])};
        } else if (key.rig == re::Rig::orbit) {
            key.position = {std::sqrt(d[0] * d[0] + d[2] * d[2]), d[1], static_cast<float>(std::atan2(d[0], d[2]) * 180.0 / 3.14159265358979)};
            key.orbit_speed = 20;
        }
    }
    return re::clamped(key);
}

void add_key_here() {
    auto& u = ui();
    if (!clip_for_keys()) return;
    remember();
    re::Clip* clip = selected_clip();
    const double t = std::clamp(now(), clip->in, clip->out);
    switch (u.lane) {
    case Lane::clips:
    case Lane::camera: {
        const auto pose = camera_on_screen();
        if (!pose) return say("The camera is not known yet.");
        re::put_key(clip->camera, key_from(*pose, t));
        u.lane = Lane::camera;
        say("Camera key set.");
        break;
    }
    case Lane::speed: {
        const auto index = re::clip_index(u.project, clip->id);
        re::put_key(clip->speed, {t, u.program && index ? u.program->speed(*index, t) : 1.0f, re::Ease::smooth});
        break;
    }
    case Lane::look: {
        const auto index = re::clip_index(u.project, clip->id);
        re::Look look;
        if (u.program && index)
            if (const auto now_look = u.program->look(*index, t)) look = *now_look;
        re::put_key(clip->look, {t, look, re::Ease::smooth});
        break;
    }
    case Lane::titles: {
        re::Title title;
        title.at = t;
        title.text = "Title";
        title.length = std::min(3.0, clip->out - t);
        clip->titles.push_back(title);
        u.effects_tab = EffectsTab::titles;
        break;
    }
    }
    u.key = KeyRef{u.lane == Lane::clips ? Lane::camera : u.lane, t};
    changed();
}

void delete_selection() {
    auto& u = ui();
    if (!selected_clip()) return;
    remember();
    re::Clip* clip = selected_clip();
    if (u.key) {
        bool removed = false;
        switch (u.key->lane) {
        case Lane::camera: removed = re::remove_key(clip->camera, u.key->at); break;
        case Lane::speed: removed = re::remove_key(clip->speed, u.key->at); break;
        case Lane::look: removed = re::remove_key(clip->look, u.key->at); break;
        case Lane::titles: removed = std::erase_if(clip->titles, [&](const re::Title& t) { return std::abs(t.at - u.key->at) < re::same_key; }) > 0; break;
        default: break;
        }
        u.key.reset();
        if (removed) changed();
        return;
    }
    const auto index = re::clip_index(u.project, clip->id).value_or(0);
    re::remove_clip(u.project, clip->id);
    u.selected = u.project.clips.empty() ? 0 : u.project.clips[std::min(index, u.project.clips.size() - 1)].id;
    changed();
    say("Clip deleted (Ctrl+Z brings it back).");
}

void add_clip(double in, double out, std::string name) {
    auto& u = ui();
    const auto s = status();
    in = std::clamp(in, s.window_start, s.window_end);
    out = std::clamp(out, s.window_start, s.window_end);
    if (std::abs(out - in) < re::shortest_clip) return say("The clip would be too short.");
    remember();
    if (u.project.clips.empty()) {
        u.project.footage = s.run;
        u.project.level = s.level;
    }
    u.selected = re::add_clip(u.project, std::min(in, out), std::max(in, out), static_cast<std::size_t>(-1), std::move(name));
    u.key.reset();
    u.mark_in.reset();
    u.mark_out.reset();
    changed();
    say("Clip added to the end of the sequence.");
}

void clip_from_moment() {
    const auto moments = re::bridge().moments();
    const double t = now();
    const re::Moment* best = nullptr;
    if (moments)
        for (const auto& m : *moments)
            if (std::abs(m.at - t) < 3 && (!best || std::abs(m.at - t) < std::abs(best->at - t))) best = &m;
    if (!best) return say("No moment near the playhead.");
    const double before = best->kind == re::MomentKind::trick ? 2.5 : 1.5;
    add_clip(best->at - before, best->at + 1.5, best->text);
}

void jump(int direction) {
    const auto points = edit_points();
    const double t = now();
    if (direction > 0) {
        for (const double p : points)
            if (p > t + 1.0 / 120) return seek(p);
    } else
        for (auto it = points.rbegin(); it != points.rend(); ++it)
            if (*it < t - 1.0 / 120) return seek(*it);
}

void step(double seconds) {
    auto& u = ui();
    u.playing = false;
    seek(now() + seconds, u.mode == re::PlayMode::edit ? status().edit_clip : -1);
}

void toggle_play() {
    auto& u = ui();
    if (u.playing) {
        u.playing = false;
        return;
    }
    if (u.shuttle <= 0) u.shuttle = 1;
    u.playing = true;
    if (u.mode == re::PlayMode::edit && u.program && !u.program->empty() &&
        !u.program->clip_at_replay(now(), static_cast<std::size_t>(std::max(0, status().edit_clip))))
        seek(u.project.clips.front().in, 0);
}

void shuttle(int direction) {
    auto& u = ui();
    if (!u.playing || (u.shuttle > 0) != (direction > 0)) {
        u.shuttle = direction;
        u.playing = true;
    } else u.shuttle = std::clamp(u.shuttle * 2, -8.0, 8.0);
}

void split_here() {
    auto& u = ui();
    re::Clip* clip = clip_for_keys();
    if (!clip) return;
    remember();
    if (const auto second = re::split_clip(u.project, clip->id, now())) {
        u.selected = *second;
        changed();
        say("Clip split.");
    } else say("Too near the clip's ends to split.");
}

void set_mode(re::PlayMode mode) {
    auto& u = ui();
    u.mode = mode;
    if (mode == re::PlayMode::edit && u.program && !u.program->empty()) {
        if (const auto index = u.program->clip_at_replay(now())) seek(now(), static_cast<int>(*index));
        else seek(u.project.clips.front().in, 0);
    }
}

void enter_camera_mode() {
    auto& u = ui();
    const auto view = plugin_camera::camera_now();
    re::CameraPose pose;
    if (view) {
        pose = re::camera_from_matrix(view->world);
        pose.fov = view->vertical_fov > 1 && view->vertical_fov < 175 ? view->vertical_fov : 65;
    } else if (const auto t = target_now({0, re::Part::body})) {
        // No game view to start from: behind and above the skater.
        pose = re::camera_from({t->position[0], t->position[1] + 1.8f, t->position[2] - 4}, 0, -12, 0, 65);
    } else return say("The camera is not known yet.");
    u.fly_position = pose.position;
    const auto angles = re::camera_angles(pose.right, pose.up, pose.back);
    u.fly_yaw = angles[0];
    u.fly_pitch = angles[1];
    u.fly_roll = 0;
    u.fly_fov = pose.fov;
    u.camera_mode = true;
    u.playing = false;
}

void leave_camera_mode() {
    ui().camera_mode = false;
    re::bridge().set_live_camera(std::nullopt);
}

void leave_replay() {
    auto& u = ui();
    if (u.dirty && !u.project.clips.empty()) save(true);
    leave_camera_mode();
    re::bridge().ask({re::Request::Kind::leave});
}

std::optional<std::size_t> showing_clip_index() {
    auto& u = ui();
    if (!u.program || u.program->empty()) return std::nullopt;
    if (u.mode == re::PlayMode::edit) {
        const auto index = static_cast<std::size_t>(std::max(0, status().edit_clip));
        return index < u.project.clips.size() ? std::optional<std::size_t>(index) : std::nullopt;
    }
    return u.program->clip_at_replay(now());
}

std::optional<double> sequence_now() {
    auto& u = ui();
    const auto index = showing_clip_index();
    if (!index) return std::nullopt;
    return u.program->edit_time(*index, now());
}

// ---- Shared ---------------------------------------------------------------------------------
Ui& ui() {
    static auto* value = new Ui;
    return *value;
}
const char* lane_name(Lane lane) noexcept {
    switch (lane) {
    case Lane::clips: return "clips";
    case Lane::camera: return "camera";
    case Lane::speed: return "speed";
    case Lane::look: return "look";
    case Lane::titles: return "titles";
    }
    return "camera";
}
void remember() { ui().history.remember(ui().project); }
void changed() {
    auto& u = ui();
    re::normalize(u.project);
    u.program = re::Program::build(u.project);
    u.dirty = true;
    re::bridge().set_program(u.program);
}
void set_project(re::Project project) {
    auto& u = ui();
    re::normalize(project);
    u.project = std::move(project);
    u.history.clear();
    u.selected = u.project.clips.empty() ? 0 : u.project.clips.front().id;
    u.key.reset();
    u.program = re::Program::build(u.project);
    re::bridge().set_program(u.program);
    u.dirty = false;
}
re::Clip* selected_clip() { return re::find_clip(ui().project, ui().selected); }
re::Status status() {
    static re::Status cached;
    static double read_at = -1;
    const double time = ImGui::GetTime();
    if (time != read_at) {
        read_at = time;
        cached = re::bridge().status();
    }
    return cached;
}
double now() {
    const auto s = status();
    return std::isfinite(s.time) ? s.time : s.window_end;
}
void seek(double replay, int clip) {
    re::Request request{re::Request::Kind::seek, replay};
    request.clip = clip;
    re::bridge().ask(request);
}
void say(std::string text, double seconds) {
    ui().message = std::move(text);
    ui().message_until = ImGui::GetTime() + seconds;
}
ImU32 colour(int r, int g, int b, int a) { return IM_COL32(r, g, b, a); }
bool button(const char* label, bool on, bool enabled, float width) {
    auto& u = ui();
    ImGui::BeginDisabled(!enabled);
    ImGui::PushStyleColor(ImGuiCol_Button, on ? palette::accent : colour(58, 58, 58));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, on ? palette::accent : colour(78, 78, 78));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, palette::accent);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 3 * u.k);
    const bool pressed = ImGui::Button(label, {width, 0});
    ImGui::PopStyleVar();
    ImGui::PopStyleColor(3);
    ImGui::EndDisabled();
    return pressed && enabled;
}
std::string clock(double seconds) {
    if (!std::isfinite(seconds)) seconds = 0;
    const bool negative = seconds < 0;
    seconds = std::abs(seconds);
    const int minutes = static_cast<int>(seconds / 60);
    return std::format("{}{}:{:05.2f}", negative ? "-" : "", minutes, seconds - minutes * 60);
}
std::string timecode(double seconds) {
    if (!std::isfinite(seconds) || seconds < 0) seconds = 0;
    const auto frames = static_cast<long long>(std::floor(seconds * 60 + 1e-6));
    return std::format("{:02}:{:02}:{:02}:{:02}", frames / 216000, frames / 3600 % 60, frames / 60 % 60, frames % 60);
}
int panel_tabs(ImDrawList* draw, ImVec2 a, float width, std::initializer_list<const char*> tabs, int current) {
    auto& u = ui();
    const float height = 24 * u.k;
    draw->AddRectFilled(a, {a.x + width, a.y + height}, palette::header);
    ImFont* font = font_or(u.fonts.bold);
    const float size = 12.5f * u.k;
    float x = a.x + 6 * u.k;
    int pressed = -1, index = 0;
    for (const char* tab : tabs) {
        const auto extent = font->CalcTextSizeA(size, FLT_MAX, 0, tab);
        const ImVec2 ta{x, a.y}, tz{x + extent.x + 18 * u.k, a.y + height};
        const bool on = index == current, hovered = ImGui::IsMouseHoveringRect(ta, tz);
        if (on) draw->AddRectFilled({ta.x, tz.y - 2 * u.k}, tz, palette::accent);
        draw->AddText(font, size, {x + 9 * u.k, a.y + (height - extent.y) / 2}, on || hovered ? palette::text : palette::dim, tab);
        if (hovered && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) pressed = index;
        x = tz.x;
        ++index;
    }
    return pressed;
}
void diamond(ImDrawList* draw, ImVec2 c, float r, ImU32 fill, bool selected) {
    const ImVec2 p[4]{{c.x, c.y - r}, {c.x + r, c.y}, {c.x, c.y + r}, {c.x - r, c.y}};
    draw->AddConvexPolyFilled(p, 4, fill);
    draw->AddPolyline(p, 4, selected ? colour(255, 255, 255) : colour(0, 0, 0, 160), ImDrawFlags_Closed, selected ? 2.0f : 1.0f);
}
} // namespace replay_ui

bool replay_editor_pending() noexcept {
    const bool shown = replay_editor::bridge().active();
    detail::state().replay_editor_visible.store(shown);
    if (!shown) detail::state().replay_preview_wanted.store(false);
    return shown;
}

void draw_replay_editor(const ReplayEditorFonts& fonts) {
    using namespace replay_ui;
    auto& u = ui();
    auto& state = detail::state();
    if (!replay_editor::bridge().active()) {
        u.camera_mode = false;
        state.replay_preview_wanted.store(false);
        return;
    }
    const auto& io = ImGui::GetIO();
    const ImVec2 size = io.DisplaySize;
    u.fonts = fonts;
    u.k = std::clamp(size.y / 1080.0f, 0.7f, 2.5f) * std::clamp(fonts.scale, 0.75f, 1.5f);
    if (!u.initialized) {
        u.initialized = true;
        const auto settings = re::bridge().settings();
        u.export_choice = settings.export_choice;
        u.preset = settings.preset;
        set_project({});
    }
    const auto s = status();
    // An export: the editor steps aside (the game films its own picture, under this overlay).
    if (s.exporting) {
        state.replay_preview_wanted.store(false);
        ImDrawList* draw = ImGui::GetForegroundDrawList();
        const auto line = std::format("EXPORTING  {:.0f}%   (the game is filming the edit)", s.export_progress * 100);
        draw->AddRectFilled({12 * u.k, 12 * u.k}, {12 * u.k + 560 * u.k, 44 * u.k}, colour(15, 15, 15, 210), 4 * u.k);
        draw->AddRectFilled({12 * u.k, 40 * u.k}, {12 * u.k + 560 * u.k * static_cast<float>(s.export_progress), 44 * u.k}, palette::accent);
        draw->AddText(font_or(u.fonts.bold), 15 * u.k, {22 * u.k, 18 * u.k}, palette::text, line.c_str());
        return;
    }
    if (s.export_serial != u.export_serial) {
        u.export_serial = s.export_serial;
        if (!s.export_message.empty()) say(s.export_message, 8);
    }
    {
        const auto playback = re::bridge().playback();
        if (!playback.playing && u.playing && playback.mode == u.mode) u.playing = false;
    }
    ImGui::PushFont(font_or(u.fonts.body));
    filmstrip_update();
    const auto pad = read_gamepad();
    keyboard();
    controller(pad);
    if (u.camera_mode) fly(pad);
    else re::bridge().set_live_camera(std::nullopt);
    re::Playback playback;
    playback.playing = u.playing;
    playback.shuttle = u.shuttle;
    playback.mode = u.mode;
    playback.loop = u.loop;
    re::bridge().set_playback(playback);
    if (u.dirty && !u.project.clips.empty() && ImGui::GetTime() - u.saved_at > 60) save(true);
    if (u.hide_ui) {
        // The game's own picture, whole screen, with the titles over it.
        state.replay_preview_wanted.store(false);
        u.monitor_a = {0, 0};
        u.monitor_z = size;
        draw_titles_over({0, 0}, size);
        if (u.camera_mode) draw_camera_hud({0, 0}, size);
        ImGui::GetForegroundDrawList()->AddText(font_or(u.fonts.body), 13 * u.k, {12 * u.k, size.y - 24 * u.k}, colour(255, 255, 255, 110),
                                                "H: show the editor");
        ImGui::PopFont();
        return;
    }
    state.replay_preview_wanted.store(true);
    // One window over the whole screen; the panels are regions of it.
    ImGui::SetNextWindowPos({0, 0});
    ImGui::SetNextWindowSize(size);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, {0, 0});
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, palette::back);
    ImGui::PushStyleColor(ImGuiCol_FrameBg, colour(24, 24, 24));
    ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, colour(30, 30, 30));
    ImGui::PushStyleColor(ImGuiCol_SliderGrab, palette::accent);
    ImGui::PushStyleColor(ImGuiCol_CheckMark, palette::accent);
    ImGui::PushStyleColor(ImGuiCol_Header, colour(58, 58, 58));
    ImGui::PushStyleColor(ImGuiCol_HeaderHovered, colour(70, 70, 70));
    ImGui::PushStyleColor(ImGuiCol_Text, palette::text);
    const bool open = ImGui::Begin("##replay_editor", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                                               ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNav |
                                                               ImGuiWindowFlags_NoScrollWithMouse);
    ImGui::PopStyleVar(3);
    if (open) {
        const float k = u.k;
        const float top = menu_height * k, gap = splitter * k;
        u.left_width = std::clamp(u.left_width, 200.0f, size.x / k * 0.35f);
        u.right_width = std::clamp(u.right_width, 260.0f, size.x / k * 0.4f);
        u.timeline_height = std::clamp(u.timeline_height, 220.0f, size.y / k * 0.6f);
        const float left = u.left_width * k, right = u.right_width * k, bottom = size.y - u.timeline_height * k;
        draw_menu_bar(size);
        draw_project({0, top}, {left, bottom - gap});
        draw_monitor({left + gap, top}, {size.x - right - gap, bottom - gap});
        draw_effects({size.x - right, top}, {size.x, bottom - gap});
        draw_timeline({0, bottom}, size);
        splitter_bar("##split_left", {left, top}, {left + gap, bottom - gap}, true, u.left_width, 1, 200, size.x / k * 0.35f);
        splitter_bar("##split_right", {size.x - right - gap, top}, {size.x - right, bottom - gap}, true, u.right_width, -1, 260, size.x / k * 0.4f);
        splitter_bar("##split_bottom", {0, bottom - gap}, {size.x, bottom}, false, u.timeline_height, -1, 220, size.y / k * 0.6f);
    }
    ImGui::End();
    ImGui::PopStyleColor(8);
    if (u.export_open) draw_export_dialog(size);
    if (u.help_open) draw_help_dialog(size);
    ImGui::PopFont();
}
} // namespace dingosdk::overlay
