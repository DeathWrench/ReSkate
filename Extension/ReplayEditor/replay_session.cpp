#include "replay_session.h"
#include "replay_bridge.h"
#include "replay_program.h"
#include "Engine/Core/Hooks/hooks.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/20260929/replay_session.h"
#include "Extension/Multiplayer/Hud/game_ui_state.h"
#include "Extension/Multiplayer/Session/session.h"
#include "Extension/Plugins/plugin_session_feed.h"
#include "Extension/Settings/named_settings.h"
#include "Extension/Skater/score_hud.h"
#include "Extension/Skater/trick_watch.h"
#include "Extension/Skater/xray.h"
#include "Extension/Skater/xray_render.h"
#include "Extension/UI/Overlay/overlay.h"
#include "Extension/UI/Overlay/scripted_pad.h"
#include "Runtime/runtime_internal.h"
#include <Windows.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <deque>
#include <format>
#include <limits>
#include <map>
#include <mutex>
#include <set>
#include <vector>

namespace dingosdk::replay_editor::session {
namespace {
namespace rs = addr::replay_session;
using Address = std::uintptr_t;
using game::build::Fingerprint;

// ---- The game's functions ------------------------------------------------------------------
using SessionUpdate = void (*)(Address session, Address frame);
using KeyframePose = void* (*)(Address state, unsigned char* out, double time);
using StartCapture = void* (*)(Address out, unsigned char* settings, Address id, Address started);
using Seek = double (*)(Address session, double time);
using ExportSetup = void (*)(Address capture, int format, int resolution, int fps, double speed);
using ExportPlayback = void (*)(Address manager, bool exporting, bool fixed, double value);
struct Callback {
    Address storage{}, unused{}, manager{}, invoker{};
};
using ExportStart = void (*)(Address capture, Callback* callback);
using LatestTime = double (*)(Address table);
using InterfaceTime = double (*)(Address self);
using InterfaceRange = void (*)(Address self, double from, double to);
struct GamePiece {
    double start, end;
    float speed;
    std::uint32_t unused;
};
static_assert(sizeof(GamePiece) == 0x18);
struct GamePieces {
    const GamePiece* begin;
    const GamePiece* end;
    const GamePiece* capacity;
};
using InterfacePlaylist = void (*)(Address self, const GamePieces* pieces, double step);
using TargetItem = bool (*)(Address self, int id, int item, float* matrix);
using TargetsTime = double (*)(Address self);
using CameraApply = void (*)(Address evaluator, unsigned char* state);

Address image{};
std::atomic<bool> started{}, ready{};
std::atomic<SessionUpdate> update_original{};
std::atomic<KeyframePose> pose_original{};
std::atomic<StartCapture> capture_original{};
std::atomic<CameraApply> apply_original{};

bool matches(Address base, const Fingerprint& f) noexcept {
    std::array<unsigned char, 32> bytes{};
    return memory::peek(base + f.rva, bytes) && bytes == f.bytes;
}
Address pointer(Address at) noexcept {
    Address value{};
    return at && memory::peek(at, value) ? value : 0;
}
template <class T> T value_at(Address at, T fallback = {}) noexcept {
    T value{};
    return at && memory::peek(at, value) ? value : fallback;
}
template <class F> F function(const Fingerprint& f) noexcept { return reinterpret_cast<F>(image + f.rva); }
template <class F> F virtual_function(Address self, std::size_t slot) noexcept {
    const Address table = pointer(self);
    return table ? reinterpret_cast<F>(pointer(table + slot)) : nullptr;
}

// The game's calls, each kept from taking the game down when its object is not what it was.
__declspec(noinline) bool guarded_seek(Address session, double t) noexcept {
    __try {
        function<Seek>(rs::seek)(session, t);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
// The playback range opened to the whole recorded window (game seconds). The game's own way, native
// 6ad87382, takes the range as two floats of the timeline; written here directly, every tick, so
// nothing the game's hidden UI does narrows it again.
void open_range(Address session) noexcept {
    const double from = value_at<double>(session + rs::session_window), to = value_at<double>(session + rs::session_window + 8);
    if (!(to > from) || !std::isfinite(from) || !std::isfinite(to)) return;
    *reinterpret_cast<double*>(session + rs::session_range) = from;
    *reinterpret_cast<double*>(session + rs::session_range + 8) = to;
}
__declspec(noinline) double guarded_time(Address session) noexcept {
    __try {
        const Address face = pointer(session + rs::session_interface);
        const auto time = virtual_function<InterfaceTime>(face, rs::interface_time);
        return face && time ? time(face) : std::numeric_limits<double>::quiet_NaN();
    } __except (EXCEPTION_EXECUTE_HANDLER) { return std::numeric_limits<double>::quiet_NaN(); }
}
__declspec(noinline) bool guarded_lock(Address session, double from, double to, bool lock) noexcept {
    __try {
        const Address face = pointer(session + rs::session_interface);
        const auto call = virtual_function<InterfaceRange>(face, lock ? rs::interface_lock : rs::interface_unlock);
        if (!face || !call) return false;
        call(face, from, to);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
__declspec(noinline) double guarded_latest(Address base) noexcept {
    __try {
        if (!pointer(base + rs::replay_object) || !pointer(base + rs::time_table)) return std::numeric_limits<double>::quiet_NaN();
        return function<LatestTime>(rs::latest_time)(base + rs::time_table);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return std::numeric_limits<double>::quiet_NaN(); }
}
__declspec(noinline) bool guarded_target(Address base, int item, float* matrix) noexcept {
    __try {
        const Address targets = pointer(base + rs::camera_targets);
        const auto call = virtual_function<TargetItem>(targets, rs::targets_item);
        return targets && call && call(targets, 0, item, matrix);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
// The replay time of the frame being shown, as the keyframed camera asks it (NaN when unknown).
__declspec(noinline) double guarded_replay_time(Address base) noexcept {
    __try {
        const Address targets = pointer(base + rs::camera_targets);
        const auto call = virtual_function<TargetsTime>(targets, rs::targets_time);
        return targets && call ? call(targets) : std::numeric_limits<double>::quiet_NaN();
    } __except (EXCEPTION_EXECUTE_HANDLER) { return std::numeric_limits<double>::quiet_NaN(); }
}
__declspec(noinline) bool guarded_export_setup(Address capture, int format, int resolution, int fps) noexcept {
    __try {
        function<ExportSetup>(rs::export_setup)(capture, format, resolution, fps, 1.0);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
__declspec(noinline) bool guarded_playlist(Address session, const GamePieces* pieces, double step) noexcept {
    __try {
        const Address face = pointer(session + rs::session_interface);
        const auto call = virtual_function<InterfacePlaylist>(face, rs::interface_playlist);
        if (!face || !call) return false;
        call(face, pieces, step);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
__declspec(noinline) bool guarded_export_start(Address capture, Callback* callback) noexcept {
    __try {
        function<ExportStart>(rs::export_start)(capture, callback);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
__declspec(noinline) bool guarded_export_end(Address manager) noexcept {
    __try {
        function<ExportPlayback>(rs::export_playback)(manager, false, false, 1.0);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// ---- What the hooks share with the client thread -------------------------------------------
std::atomic<bool> active{};
std::atomic<Address> active_session{};
std::atomic<bool> exporting{};
// A seek the client thread asks the next session update to make (NaN: none).
std::atomic<double> pending_seek{std::numeric_limits<double>::quiet_NaN()};
// Edit playback: the clip playing, and what is left of its hold (seconds; negative: not holding).
std::atomic<int> edit_clip{0};
std::atomic<double> hold_left{-1};
std::atomic<bool> reached_end{};
// The camera: how often the game asked for it, and how often ReSkate's answered, this second; the
// depth of field the last answer had (for the client thread to apply).
std::atomic<int> asks{}, shown{};
std::atomic<float> shown_focus{}, shown_blur{};
std::atomic<ULONGLONG> last_shown_at{};
// Exports: the size and bitrate to give the capture the next time one starts, and the result.
struct CaptureChoice {
    int width{}, height{}, kbps{};
};
std::atomic<bool> capture_armed{};
CaptureChoice capture_choice;
std::atomic<int> export_result{0}; // 0 running or idle, 1 done, 2 failed
// While exporting: the edit's clip each playlist piece is from (the playlist index is the game's), and
// the program the export was made from.
std::mutex export_mutex;
std::vector<std::size_t> export_clips;
std::shared_ptr<const Program> export_program;
std::atomic<std::uint32_t> export_code{};

// Where the other players' skaters were, by replay time (ReSkate's own track; the game's replay
// only records them as drawn). And the local skater's recent places, for which way it is going.
struct Sample {
    double t;
    Vec3 position;
};
std::mutex tracks_mutex;
std::map<std::uint64_t, std::deque<Sample>> tracks;
std::deque<Sample> local_recent;

std::optional<TargetPlace> place_from(const std::deque<Sample>& samples, double t) {
    if (samples.empty()) return std::nullopt;
    if (t < samples.front().t - 0.5 || t > samples.back().t + 0.5) return std::nullopt;
    const auto later = std::lower_bound(samples.begin(), samples.end(), t, [](const Sample& s, double v) { return s.t < v; });
    Vec3 position;
    if (later == samples.begin()) position = later->position;
    else if (later == samples.end()) position = samples.back().position;
    else {
        const auto& a = *(later - 1);
        const auto& b = *later;
        const double u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0;
        for (int c = 0; c < 3; ++c) position[c] = static_cast<float>(a.position[c] + (b.position[c] - a.position[c]) * u);
    }
    TargetPlace place{position, {0, 0, 1}};
    // Which way: from a little before to now (a quarter of a second smooths out the wobble).
    const auto before = std::lower_bound(samples.begin(), samples.end(), t - 0.25, [](const Sample& s, double v) { return s.t < v; });
    if (before != samples.end()) {
        const float dx = position[0] - before->position[0], dz = position[2] - before->position[2];
        const float length = std::sqrt(dx * dx + dz * dz);
        if (length > 0.05f) place.heading = {dx / length, 0, dz / length};
    }
    return place;
}

std::optional<TargetPlace> target_place(const Target& target, double t) {
    if (target.player == 0) {
        const int item = target.part == Part::head ? 4 : target.part == Part::board ? 5 : 2;
        std::array<float, 16> m{};
        if (!guarded_target(image, item, m.data())) return std::nullopt;
        const Vec3 position{m[12], m[13], m[14]};
        for (const auto v : position)
            if (!std::isfinite(v) || std::abs(v) > 1e6f) return std::nullopt;
        std::lock_guard lock(tracks_mutex);
        // Kept while playing forward; a jump back starts it again.
        if (!local_recent.empty() && (t < local_recent.back().t - 1e-4 || t > local_recent.back().t + 1.0)) local_recent.clear();
        if (local_recent.empty() || t > local_recent.back().t + 1e-4) local_recent.push_back({t, position});
        while (local_recent.size() > 64) local_recent.pop_front();
        auto place = place_from(local_recent, t).value_or(TargetPlace{position, {0, 0, 1}});
        place.position = position;
        return place;
    }
    std::lock_guard lock(tracks_mutex);
    const auto found = tracks.find(target.player);
    return found == tracks.end() ? std::nullopt : place_from(found->second, t);
}

// The clip whose camera and look show at replay time t.
std::optional<std::size_t> showing_clip(const Program& program, const Playback& playback, double t) {
    if (program.empty()) return std::nullopt;
    if (exporting.load(std::memory_order_relaxed)) {
        // The playlist's piece now says which clip it is (two clips may share footage).
        const auto index = value_at<std::uint32_t>(image + rs::playlist_index);
        std::lock_guard lock(export_mutex);
        if (index < export_clips.size() && export_clips[index] < program.project().clips.size()) return export_clips[index];
        return program.clip_at_replay(t);
    }
    if (playback.mode == PlayMode::edit) {
        const auto clip = static_cast<std::size_t>(std::max(0, edit_clip.load()));
        return clip < program.project().clips.size() ? std::optional<std::size_t>(clip) : std::nullopt;
    }
    if (playback.solo)
        if (const auto index = clip_index(program.project(), playback.solo)) return program.clip_at_replay(t, *index) == index ? index : std::nullopt;
    return program.clip_at_replay(t);
}

// ---- Hooks ----------------------------------------------------------------------------------
// The play speed, the edit's speed curves and its cuts, before the game moves the clock by them.
void steer(Address session, Address frame) {
    const auto program = bridge().program();
    const auto playback = bridge().playback();
    const double seek_to = pending_seek.exchange(std::numeric_limits<double>::quiet_NaN());
    if (std::isfinite(seek_to)) guarded_seek(session, seek_to);
    const double t = guarded_time(session);
    const double dt = static_cast<double>(value_at<std::int64_t>(frame + 8)) * 1e-9;
    double rate = 0;
    if (playback.playing && std::isfinite(t)) {
        const double shuttle = std::clamp(playback.shuttle, -static_cast<double>(fastest), static_cast<double>(fastest));
        if (playback.mode == PlayMode::footage || !program || program->empty()) rate = shuttle;
        else {
            const auto& clips = program->project().clips;
            int index = std::clamp(edit_clip.load(), 0, static_cast<int>(clips.size()) - 1);
            const auto& clip = clips[static_cast<std::size_t>(index)];
            const auto go_to = [&](int next) {
                if (next < 0 || next >= static_cast<int>(clips.size())) {
                    if (playback.loop && !clips.empty()) next = shuttle > 0 ? 0 : static_cast<int>(clips.size()) - 1;
                    else {
                        reached_end.store(true);
                        return;
                    }
                }
                edit_clip.store(next);
                const auto& c = clips[static_cast<std::size_t>(next)];
                guarded_seek(session, shuttle > 0 ? c.in : c.out);
            };
            if (hold_left.load() >= 0) {
                const double left = hold_left.load() - dt * std::abs(shuttle);
                if (left <= 0) {
                    hold_left.store(-1);
                    go_to(index + 1);
                } else hold_left.store(left);
            } else if (t < clip.in - 0.05 || t > clip.out + 0.05) {
                // Somewhere else (a seek in footage mode before): start the clip from its beginning.
                guarded_seek(session, shuttle > 0 ? clip.in : clip.out);
            } else if (shuttle > 0 && t >= clip.out - 1e-3) {
                if (clip.hold > 0) hold_left.store(clip.hold);
                else go_to(index + 1);
            } else if (shuttle < 0 && t <= clip.in + 1e-3) go_to(index - 1);
            else rate = shuttle * program->speed(static_cast<std::size_t>(index), t);
        }
    }
    *reinterpret_cast<double*>(session + rs::session_rate) = rate;
}

void session_update(Address session, Address frame) {
    if (active.load(std::memory_order_relaxed) && session == active_session.load(std::memory_order_relaxed)) {
        const auto turn = overlay::take_replay_turn();
        bridge().advance_live_camera(static_cast<double>(value_at<std::int64_t>(frame + 8)) * 1e-9, turn.x, turn.y);
    }
    if (active.load(std::memory_order_relaxed) && !exporting.load(std::memory_order_relaxed) &&
        session == active_session.load(std::memory_order_relaxed)) {
        try { steer(session, frame); } catch (...) {}
    }
    update_original.load()(session, frame);
}

// The edit's camera, for whatever replay time the game asks about.
void* keyframe_pose(Address state, unsigned char* out, double time) {
    void* result = pose_original.load()(state, out, time);
    asks.fetch_add(1, std::memory_order_relaxed);
    if (!active.load(std::memory_order_relaxed) || !out) return result;
    try {
        std::optional<CameraPose> pose = bridge().live_camera();
        if (!pose) {
            std::shared_ptr<const Program> program;
            if (exporting.load(std::memory_order_relaxed)) {
                std::lock_guard lock(export_mutex);
                program = export_program;
            } else program = bridge().program();
            if (program) {
                const auto playback = bridge().playback();
                if (const auto clip = showing_clip(*program, playback, time)) pose = program->camera(*clip, time, target_place);
            }
        }
        if (!pose) return result;
        // The pose's rows are the camera's left, up, forward and position (keyframe_pose's note).
        const std::array<float, 16> m{-pose->right[0], -pose->right[1], -pose->right[2], 0, pose->up[0], pose->up[1], pose->up[2], 0,
                                      -pose->back[0], -pose->back[1], -pose->back[2], 0, pose->position[0], pose->position[1],
                                      pose->position[2], 1};
        std::memcpy(out, m.data(), sizeof(m));
        const float zero[2]{};
        std::memcpy(out + 0x40, zero, sizeof(zero));
        const float fov = pose->fov * 3.14159265f / 180.0f;
        std::memcpy(out + rs::pose_fov, &fov, sizeof(fov));
        out[rs::pose_valid] = 1;
        shown.fetch_add(1, std::memory_order_relaxed);
        shown_focus.store(pose->focus, std::memory_order_relaxed);
        shown_blur.store(pose->blur, std::memory_order_relaxed);
        last_shown_at.store(GetTickCount64(), std::memory_order_relaxed);
    } catch (...) {}
    return result;
}

// The camera ReSkate shows at replay time t: the flown one, else the showing clip's keys.
std::optional<CameraPose> replay_camera(double t) {
    if (auto live = bridge().live_camera()) return live;
    if (!std::isfinite(t)) return std::nullopt;
    std::shared_ptr<const Program> program;
    if (exporting.load(std::memory_order_relaxed)) {
        std::lock_guard lock(export_mutex);
        program = export_program;
    } else program = bridge().program();
    if (!program) return std::nullopt;
    const auto playback = bridge().playback();
    if (const auto clip = showing_clip(*program, playback, t)) return program->camera(*clip, t, target_place);
    return std::nullopt;
}

// ReSkate's camera written into a camera State (rs::camera_state_size bytes).
void put_camera(unsigned char* state, const CameraPose& pose) noexcept {
    const auto put = [&](std::size_t at, const Vec3& v) { std::memcpy(state + at, v.data(), sizeof(float) * 3); };
    put(rs::state_position, pose.position);
    put(rs::state_offset, {0, 0, 0});
    put(rs::state_target, {pose.position[0] - pose.back[0], pose.position[1] - pose.back[1], pose.position[2] - pose.back[2]});
    put(rs::state_up, pose.up);
    std::memcpy(state + rs::state_fov, &pose.fov, sizeof(float));
    if (state[rs::state_physical]) {
        const float none = 0;
        std::memcpy(state + rs::state_lens, &none, sizeof(none));
    }
}

// Every camera evaluator's state on its way into the engine camera: while ReSkate's editor has the
// replay and has a camera to show, a copy with that camera goes in instead. The state itself is left
// alone: where the game's directors do not build it again each tick (a replay of two frames did not),
// a camera written there stays, and the game's own camera is lost to set_view_camera's pairing.
void camera_apply(Address evaluator, unsigned char* state) {
    if (active.load(std::memory_order_relaxed) && state) {
        try {
            if (const auto pose = replay_camera(guarded_replay_time(image))) {
                alignas(16) unsigned char copy[rs::camera_state_size];
                std::memcpy(copy, state, sizeof(copy));
                put_camera(copy, *pose);
                // The picture itself: in a replay the main view does not follow this camera.
                xray::set_view_camera(camera_matrix(*pose), pose->fov, exporting.load(std::memory_order_relaxed));
                shown.fetch_add(1, std::memory_order_relaxed);
                shown_focus.store(pose->focus, std::memory_order_relaxed);
                shown_blur.store(pose->blur, std::memory_order_relaxed);
                last_shown_at.store(GetTickCount64(), std::memory_order_relaxed);
                apply_original.load()(evaluator, copy);
                return;
            }
        } catch (...) {}
    }
    apply_original.load()(evaluator, state);
}

// An export ReSkate started gets the size and bitrate chosen, not the game's list's.
void* start_capture(Address out, unsigned char* settings, Address id, Address started_flag) {
    if (settings && capture_armed.exchange(false)) {
        if (capture_choice.height > 0) std::memcpy(settings + rs::capture_settings_height, &capture_choice.height, 4);
        if (capture_choice.width > 0) std::memcpy(settings + rs::capture_settings_width, &capture_choice.width, 4);
        if (capture_choice.kbps > 0) std::memcpy(settings + rs::capture_settings_bitrate, &capture_choice.kbps, 4);
    }
    return capture_original.load()(out, settings, id, started_flag);
}

// The capture's answer when it ends, or fails to start (export_start's callback).
void export_finished(char ok, std::uint32_t code, void*) {
    export_code.store(code);
    export_result.store(ok ? 1 : 2);
}

template <class F> bool hook(const Fingerprint& f, F replacement, std::atomic<F>& original) {
    void* target = reinterpret_cast<void*>(image + f.rva);
    void* previous{};
    if (hook_prepare(target, reinterpret_cast<void*>(replacement), &previous) != HookOk) return false;
    original = reinterpret_cast<F>(previous);
    if (hook_enable(target) != HookOk) {
        hook_remove(target);
        original = nullptr;
        return false;
    }
    return true;
}

// ---- Client thread ---------------------------------------------------------------------------
struct Held {
    std::string found, ours, wanted;
};
// Engine settings the editor's look holds: what was there before, what it wrote (as the engine reads
// it back) and what it asked for.
std::map<std::string, Held, std::less<>> held;
// Settings a hold was refused for, said once each in the log.
std::set<std::string, std::less<>> refused;

void refuse(std::string_view name, std::string_view why) {
    if (refused.emplace(name).second)
        logging::log(logging::Level::warning, logging::Channel::runtime, "Replay editor: the look could not set {}: {}", name, why);
}
// Written again whenever the engine's value is not ours any more: something else (the game's own
// replay filters, say) may set the same setting every frame.
void hold_setting(std::string_view name, const std::string& value) {
    const auto at = held.find(name);
    const auto now = named_setting_value(name);
    if (!now) return refuse(name, "it cannot be read");
    if (at != held.end() && at->second.wanted == value && *now == at->second.ours) return;
    const auto result = change_named_setting(name, value, false);
    if (result.starts_with("error: ")) return refuse(name, result);
    const auto ours = named_setting_value(name).value_or(value);
    if (at == held.end()) held.emplace(std::string(name), Held{*now, ours, value});
    else {
        at->second.ours = ours;
        at->second.wanted = value;
    }
}
void release_setting(std::string_view name) {
    const auto at = held.find(name);
    if (at == held.end()) return;
    if (named_setting_value(name) == at->second.ours) (void)change_named_setting(name, at->second.found, false);
    held.erase(at);
}
void release_all_settings() {
    while (!held.empty()) release_setting(std::string(held.begin()->first));
}
std::string number(float v) { return std::format("{:.3f}", v); }

// The look and depth of field now, through the engine's own filters.
void apply_look(const std::optional<Look>& look, float focus, float blur) {
    if (look) {
        hold_setting("PostProcess.ForceEVCompensationEnable", "1");
        hold_setting("PostProcess.ForceEVCompensation", number(look->exposure));
        hold_setting("DingoVideoFilterSettings.Enabled", "1");
        const bool shifted = look->saturation != 1 || look->hue != 0 || look->contrast != 1;
        if (shifted) {
            hold_setting("DingoVideoFilterSettings.HueShiftEnable", "1");
            hold_setting("DingoVideoFilterSettings.HueShiftHue", number(look->hue));
            hold_setting("DingoVideoFilterSettings.HueShiftSaturation", number(look->saturation));
            hold_setting("DingoVideoFilterSettings.HueShiftValue", number(look->contrast));
        } else {
            for (const char* name : {"DingoVideoFilterSettings.HueShiftEnable", "DingoVideoFilterSettings.HueShiftHue",
                                     "DingoVideoFilterSettings.HueShiftSaturation", "DingoVideoFilterSettings.HueShiftValue"})
                release_setting(name);
        }
        if (look->vignette > 0.01f) {
            hold_setting("DingoVideoFilterSettings.VignetteEnable", "1");
            hold_setting("DingoVideoFilterSettings.VignetteOpacity", number(look->vignette));
        } else {
            release_setting("DingoVideoFilterSettings.VignetteEnable");
            release_setting("DingoVideoFilterSettings.VignetteOpacity");
        }
        if (look->barrel > 0.01f) {
            hold_setting("DingoVideoFilterSettings.BarrelDistortionEnable", "1");
            hold_setting("DingoVideoFilterSettings.BarrelDistortionGain", number(look->barrel * 0.6f));
        } else {
            release_setting("DingoVideoFilterSettings.BarrelDistortionEnable");
            release_setting("DingoVideoFilterSettings.BarrelDistortionGain");
        }
        if (look->grain > 0.01f) {
            hold_setting("DingoVideoFilterSettings.FilmGrainEnable", "1");
            hold_setting("DingoVideoFilterSettings.GrainShadowIntensity", number(look->grain));
            hold_setting("DingoVideoFilterSettings.GrainHighlightIntensity", number(look->grain * 0.5f));
        } else {
            for (const char* name : {"DingoVideoFilterSettings.FilmGrainEnable", "DingoVideoFilterSettings.GrainShadowIntensity",
                                     "DingoVideoFilterSettings.GrainHighlightIntensity"})
                release_setting(name);
        }
        if (look->aberration > 0.01f) {
            hold_setting("DingoVideoFilterSettings.ChromaticAberrationEnable", "1");
            hold_setting("DingoVideoFilterSettings.ChromaticAberrationScaleMultiply", number(look->aberration * 2));
        } else {
            release_setting("DingoVideoFilterSettings.ChromaticAberrationEnable");
            release_setting("DingoVideoFilterSettings.ChromaticAberrationScaleMultiply");
        }
    } else {
        for (auto it = held.begin(); it != held.end();) {
            const auto name = it->first;
            ++it;
            if (!name.starts_with("PostProcess.ForceDof")) release_setting(name);
        }
    }
    if (focus > 0.05f) {
        hold_setting("PostProcess.ForceDofEnable", "1");
        hold_setting("PostProcess.ForceDofFocusDistance", number(focus));
        hold_setting("PostProcess.ForceDofBlurFactor", number(blur));
    } else
        for (const char* name : {"PostProcess.ForceDofEnable", "PostProcess.ForceDofFocusDistance", "PostProcess.ForceDofBlurFactor"})
            release_setting(name);
}

struct ClientState {
    bool took_over{};
    bool game_ui_was_hidden{};
    bool handed_back{};          // the player closed ReSkate's editor in this replay: do not open it again
    bool view_camera{};          // the renderer's main-view hook kept on (xray::keep_view_camera)
    ULONGLONG active_since{};
    Address session{};
    std::string level;
    std::uint64_t run{};
    // Footage kept for the edit: clip ranges locked (game seconds).
    std::set<std::pair<double, double>> locked;
    Address locked_session{};
    // The moments of this run, and what the recorder needs between ticks.
    std::vector<Moment> moments;
    std::uint64_t moments_revision{}, published_revision{};
    tricks::TrickWatch watch;
    std::string trick_name;
    bool slam_before{};
    std::map<std::uint64_t, std::string> roster;
    ULONGLONG next_roster{}, next_track{}, next_trim{};
    // Exports.
    std::vector<GamePiece> pieces;
    Callback callback;
    ULONGLONG export_started{};
    std::string export_message;
    bool export_failed{};
    std::uint32_t export_serial{};
    // The camera's counts, a second at a time.
    ULONGLONG second_started{};
    int asks_last{}, shown_last{};
    std::string notice;
};
ClientState& client_state() {
    static auto* value = new ClientState;
    return *value;
}

void notice(ClientState& s, std::string text) {
    logging::log(logging::Level::info, logging::Channel::runtime, "Replay editor: {}", text);
    s.notice = std::move(text);
}

Address current_session(Address base) {
    const Address manager = pointer(base + rs::playback_manager);
    const Address handle = pointer(manager + rs::manager_handle);
    return handle ? pointer(handle + rs::handle_session) : 0;
}

void take_over(Address base, ClientState& s) {
    s.game_ui_was_hidden = multiplayer::sample_game_ui_state(base).ui_hidden;
    if (!s.game_ui_was_hidden) {
        std::array<char, 256> reply{};
        (void)runtime::detail::queue_debug(nullptr, {overlay::DebugAction::set_game_ui_hidden, true}, reply.data(), reply.size());
    }
    // The whole recorded window, not only the last seconds the game opened with.
    open_range(s.session);
    s.took_over = true;
    s.active_since = GetTickCount64();
    auto playback = bridge().playback();
    playback.playing = false;
    bridge().set_playback(playback);
    edit_clip.store(0);
    hold_left.store(-1);
    active_session.store(s.session);
    active.store(true);
    overlay::play_ui_sound(56);
}

void hand_back(ClientState& s, bool replay_still_open) {
    active.store(false);
    active_session.store(0);
    release_all_settings();
    bridge().set_live_camera(std::nullopt);
    auto playback = bridge().playback();
    playback.playing = false;
    bridge().set_playback(playback);
    if (s.took_over && !s.game_ui_was_hidden) {
        std::array<char, 256> reply{};
        (void)runtime::detail::queue_debug(nullptr, {overlay::DebugAction::set_game_ui_hidden, false}, reply.data(), reply.size());
    }
    if (replay_still_open && s.session) *reinterpret_cast<double*>(s.session + rs::session_rate) = 0;
    s.took_over = false;
}

int fps_choice(int fps) { return fps <= 24 ? 0 : fps <= 30 ? 1 : 2; }
int resolution_choice(int height) {
    constexpr std::array<int, 6> heights{360, 480, 720, 1080, 1440, 2160};
    int best = 3;
    for (int i = 0; i < 6; ++i)
        if (std::abs(heights[i] - height) < std::abs(heights[best] - height)) best = i;
    return best;
}

void start_export(Address base, ClientState& s, const ExportChoice& choice) {
    const auto program = bridge().program();
    if (exporting.load()) return notice(s, "an export is already running");
    if (!program || program->empty()) return notice(s, "there is nothing to export: add a clip first");
    const Address session = s.session;
    const Address manager = pointer(base + rs::playback_manager);
    const Address capture = pointer(base + rs::capture_manager);
    if (!session || !manager || !capture) return notice(s, "the replay is not open");
    if (value_at<int>(capture + rs::capture_state) != 0) return notice(s, "the game is already capturing a video");
    std::vector<ExportPiece> pieces;
    if (choice.whole_edit) pieces = program->export_pieces(1.0 / std::max(24, choice.fps));
    else {
        const auto playback = bridge().playback();
        const double t = guarded_time(session);
        const auto clip = showing_clip(*program, playback, t);
        if (!clip) return notice(s, "the playhead is not in a clip");
        Project one;
        one.clips.push_back(program->project().clips[*clip]);
        pieces = Program::build(one)->export_pieces(1.0 / std::max(24, choice.fps));
        for (auto& p : pieces) p.clip = *clip;
    }
    if (pieces.empty()) return notice(s, "there is nothing to export");
    s.pieces.clear();
    std::vector<std::size_t> clips;
    for (const auto& p : pieces) {
        s.pieces.push_back({p.start, p.end, std::max(0.0001f, p.speed), 0});
        clips.push_back(p.clip);
    }
    {
        std::lock_guard lock(export_mutex);
        export_clips = std::move(clips);
        export_program = program;
    }
    capture_choice = {choice.width & ~1, choice.height & ~1, choice.kbps};
    capture_armed.store(true);
    export_result.store(0);
    if (!guarded_export_setup(capture, choice.format, resolution_choice(choice.height), fps_choice(choice.fps)))
        return notice(s, "the game's export could not be set up");
    // As the game's own fixed-step export does (export_playback), with ReSkate's pieces: the rate
    // held, the clock given the playlist, the session told it is stepping.
    *reinterpret_cast<std::uint8_t*>(manager + rs::manager_rate_lock) = 1;
    *reinterpret_cast<double*>(session + rs::session_rate) = 0;
    const GamePieces list{s.pieces.data(), s.pieces.data() + s.pieces.size(), s.pieces.data() + s.pieces.size()};
    const double step = 1.0 / (choice.fps <= 24 ? 24.0 : choice.fps <= 30 ? 30.0 : 60.0);
    if (!guarded_playlist(session, &list, step)) {
        guarded_export_end(manager);
        return notice(s, "the export's playlist was refused");
    }
    *reinterpret_cast<std::uint8_t*>(session + rs::session_fixed_step) = 1;
    exporting.store(true);
    s.export_started = GetTickCount64();
    s.callback = {0, 0, base + rs::callback_copy, reinterpret_cast<Address>(&export_finished)};
    if (!guarded_export_start(capture, &s.callback)) export_result.store(2);
    logging::log(logging::Level::info, logging::Channel::runtime,
                 "Replay editor: export started, {} pieces, {} fps, {}x{} at {} kbps", s.pieces.size(), choice.fps, choice.width,
                 choice.height, choice.kbps);
}

// While exporting: progress, and the end.
void watch_export(Address base, ClientState& s, Status& status) {
    if (!exporting.load()) return;
    const auto count = value_at<std::uint32_t>(base + rs::playlist_count);
    const auto index = value_at<std::uint32_t>(base + rs::playlist_index);
    status.export_progress = count ? std::clamp(static_cast<double>(index) / count, 0.0, 1.0) : 0;
    const int result = export_result.load();
    if (result == 0) return;
    exporting.store(false);
    capture_armed.store(false);
    guarded_export_end(pointer(base + rs::playback_manager));
    ++s.export_serial;
    s.export_failed = result != 1;
    if (result == 1) {
        s.export_message = std::format("Saved to the Videos folder ({:.0f} s to export).",
                                            static_cast<double>(GetTickCount64() - s.export_started) / 1000.0);
        overlay::notify(overlay::NoticeLevel::info, "Replay exported", "In the game's Videos folder.");
    } else {
        s.export_message = std::format("The export failed (code {:#x}).", export_code.load());
        overlay::notify(overlay::NoticeLevel::warning, "Replay export failed", s.export_message);
    }
    notice(s, s.export_message);
}

// Footage the edit uses is locked in the recorder's ring; footage it no longer uses is let go.
void keep_footage(ClientState& s, Status& status) {
    const auto program = bridge().program();
    std::set<std::pair<double, double>> wanted;
    if (program)
        for (const auto& clip : program->project().clips)
            if (clip.out > status.window_start && clip.in < status.window_end)
                wanted.insert({std::max(status.window_start, clip.in - 0.5), std::min(status.window_end, clip.out + 0.5)});
    if (!s.session) return;
    if (s.locked_session != s.session) {
        // Another session (a new replay opened): the old locks were the engine's, which keeps them
        // until its footage is wiped; they are asked for again here.
        s.locked.clear();
        s.locked_session = s.session;
    }
    for (auto it = s.locked.begin(); it != s.locked.end();)
        if (!wanted.contains(*it)) {
            guarded_lock(s.session, it->first, it->second, false);
            it = s.locked.erase(it);
        } else ++it;
    for (const auto& range : wanted)
        if (!s.locked.contains(range) && s.locked.size() < 256 && guarded_lock(s.session, range.first, range.second, true))
            s.locked.insert(range);
    status.locked = 0;
    for (const auto& r : s.locked) status.locked += r.second - r.first;
}

// While the game records: tricks, slams, who came and went, and where the others' skaters are.
void record(Address base, ClientState& s, double now) {
    if (!std::isfinite(now)) return;
    if (const auto hud = tricks::read_score_hud(base)) {
        if (hud->action && !hud->header.empty()) s.trick_name = hud->header + (hud->descriptor.empty() ? "" : " " + hud->descriptor);
        const auto event = s.watch.update({hud->action, hud->line_score, hud->multiplier, hud->slam, false});
        if (event.kind == tricks::TrickEvent::Kind::landed) {
            s.moments.push_back({now, MomentKind::trick, 0, s.trick_name.empty() ? "Trick" : s.trick_name, event.points});
            ++s.moments_revision;
        }
        if (hud->slam && !s.slam_before) {
            s.moments.push_back({now, MomentKind::slam, 0, "Slam", 0});
            ++s.moments_revision;
        }
        s.slam_before = hud->slam;
    }
    const auto tick = GetTickCount64();
    if (tick >= s.next_roster) {
        s.next_roster = tick + 1000;
        const auto m = multiplayer::model();
        std::map<std::uint64_t, std::string> roster;
        if (m.active && m.connected)
            for (const auto& p : m.roster)
                if (p.connected && p.id && p.id != m.local_id) roster[p.id] = p.name;
        for (const auto& [id, name] : roster)
            if (!s.roster.contains(id)) {
                s.moments.push_back({now, MomentKind::joined, id, name, 0});
                ++s.moments_revision;
            }
        for (const auto& [id, name] : s.roster)
            if (!roster.contains(id)) {
                s.moments.push_back({now, MomentKind::left, id, name, 0});
                ++s.moments_revision;
            }
        s.roster = std::move(roster);
    }
    if (tick >= s.next_track) {
        s.next_track = tick + 100;
        const auto peers = plugin_feed::latest_peers();
        std::lock_guard lock(tracks_mutex);
        for (const auto& p : peers) {
            auto& samples = tracks[p.id];
            if (samples.empty() || now > samples.back().t + 1e-3) samples.push_back({now, p.position});
        }
    }
}

// What is older than the recording's window is gone from the game: it goes here too.
void trim_to_window(ClientState& s, double window_start) {
    const auto tick = GetTickCount64();
    if (tick < s.next_trim || !std::isfinite(window_start) || window_start <= 0) return;
    s.next_trim = tick + 2000;
    const auto before = s.moments.size();
    std::erase_if(s.moments, [&](const Moment& m) { return m.at < window_start - 1; });
    if (s.moments.size() > 20000) s.moments.erase(s.moments.begin(), s.moments.end() - 20000);
    if (s.moments.size() != before) ++s.moments_revision;
    std::lock_guard lock(tracks_mutex);
    for (auto it = tracks.begin(); it != tracks.end();) {
        auto& samples = it->second;
        while (!samples.empty() && samples.front().t < window_start - 1) samples.pop_front();
        while (samples.size() > 40000) samples.pop_front();
        it = samples.empty() ? tracks.erase(it) : std::next(it);
    }
}

void handle_requests(Address base, ClientState& s, bool replay_open) {
    for (auto& request : bridge().take_requests()) switch (request.kind) {
        case Request::Kind::take_over:
            s.handed_back = false;
            if (replay_open && !s.took_over && s.session) take_over(base, s);
            else if (!replay_open) notice(s, "open the game's replay editor first (hold Select, or B on the keyboard)");
            break;
        case Request::Kind::hand_back:
            if (s.took_over) {
                s.handed_back = true;
                hand_back(s, replay_open);
                overlay::notify(overlay::NoticeLevel::info, "Replay editor", "Back to the game's replay editor.");
            }
            break;
        case Request::Kind::leave:
            if (s.took_over) {
                // Out of the replay the game's own way, so its screens, its input mapping and its
                // flags all come back as its exit leaves them (replaydataprovider_game_exitreplay):
                // its UI back, then Back (B) on its replay page and A on the "exit replay?" prompt,
                // pressed on the pad the game reads (scripted_pad.h) once the overlay has let go.
                s.handed_back = true;
                hand_back(s, replay_open);
                XINPUT_GAMEPAD back{}, confirm{};
                back.wButtons = XINPUT_GAMEPAD_B;
                confirm.wButtons = XINPUT_GAMEPAD_A;
                overlay::play_pad({{0, {}}, {8, back}, {12, {}}, {40, confirm}, {44, {}}});
                logging::log(logging::Level::info, logging::Channel::runtime, "Replay editor: leaving the replay (B, then A on the game's prompt).");
            }
            break;
        case Request::Kind::seek:
            if (s.took_over && std::isfinite(request.time)) {
                pending_seek.store(request.time);
                hold_left.store(-1);
                const auto program = bridge().program();
                if (program)
                    if (const auto clip = program->clip_at_replay(request.time, static_cast<std::size_t>(std::max(0, edit_clip.load()))))
                        edit_clip.store(static_cast<int>(*clip));
                if (request.clip >= 0) edit_clip.store(request.clip);
            }
            break;
        case Request::Kind::export_edit:
            if (s.took_over) start_export(base, s, request.choice);
            break;
        case Request::Kind::open_videos: break; // the screen opens the folder itself
        case Request::Kind::add_marker:
            if (s.took_over) {
                s.moments.push_back({request.time, MomentKind::mark, 0, request.text.empty() ? "Marker" : request.text, 0});
                std::sort(s.moments.begin(), s.moments.end(), [](const Moment& a, const Moment& b) { return a.at < b.at; });
                ++s.moments_revision;
            }
            break;
        }
}
} // namespace

bool start(std::uintptr_t base) noexcept {
    if (started.exchange(true)) return ready.load();
    try {
        image = base;
        if (!base) return false;
        for (const auto* f : {&rs::session_update, &rs::keyframe_pose, &rs::camera_apply, &rs::start_capture, &rs::seek, &rs::export_setup,
                              &rs::export_playback, &rs::export_start, &rs::latest_time})
            if (!matches(base, *f)) {
                logging::log(logging::Level::warning, logging::Channel::runtime,
                             "Replay editor: game code at {:#x} differs from the supported build; the editor is off.", f->rva);
                return false;
            }
        if (!hook(rs::session_update, &session_update, update_original) || !hook(rs::keyframe_pose, &keyframe_pose, pose_original) ||
            !hook(rs::start_capture, &start_capture, capture_original) || !hook(rs::camera_apply, &camera_apply, apply_original)) {
            logging::log(logging::Level::warning, logging::Channel::runtime, "Replay editor: the replay could not be hooked.");
            return false;
        }
        bridge().set_settings(load_settings());
        auto& s = client_state();
        s.run =(static_cast<std::uint64_t>(GetCurrentProcessId()) << 32) ^ GetTickCount64();
        ready.store(true);
        return true;
    } catch (...) {
        return false;
    }
}

bool available() noexcept { return ready.load(); }

void tick(std::uintptr_t base, std::uintptr_t client, std::string_view level, bool camera_phase) noexcept {
    (void)client;
    (void)camera_phase;
    if (!ready.load() || base != image) return;
    try {
        auto& s = client_state();
        if (level != s.level) {
            // A new map: the footage, the locks and what was noted are the old map's.
            s.level = std::string(level);
            s.moments.clear();
            ++s.moments_revision;
            s.locked.clear();
            s.watch = tricks::TrickWatch{};
            std::lock_guard lock(tracks_mutex);
            tracks.clear();
        }
        const Address session = current_session(base);
        const bool replay_open = session && value_at<std::uint8_t>(base + rs::replay_shown) != 0;
        if (session != s.session) {
            if (s.took_over) hand_back(s, false);
            s.session = session;
            s.handed_back = false;
        }
        Status status;
        status.available = true;
        status.replay_open = replay_open;
        status.run = s.run;
        status.level = s.level;
        if (session) {
            status.window_start = value_at<double>(session + rs::session_window);
            status.window_end = value_at<double>(session + rs::session_window + 8);
            status.time = guarded_time(session);
            status.rate = value_at<double>(session + rs::session_rate);
        }
        if (!replay_open) {
            if (s.took_over) hand_back(s, false);
            const double latest = guarded_latest(base);
            record(base, s, latest);
            status.recording_at = latest;
        } else if (!s.took_over && !s.handed_back && bridge().settings().open_with_replay) take_over(base, s);
        handle_requests(base, s, replay_open);
        // The renderer's main-view hook, which puts ReSkate's camera in the picture, while the editor has the replay.
        if (const bool view_camera = s.took_over && replay_open; view_camera != s.view_camera) {
            (void)xray::keep_view_camera(view_camera);
            s.view_camera = view_camera;
        }
        if (s.took_over && replay_open) {
            std::shared_ptr<const Program> program;
            if (exporting.load()) {
                std::lock_guard lock(export_mutex);
                program = export_program;
            } else program = bridge().program();
            const auto playback = bridge().playback();
            // The look of the clip showing, and the depth of field of the camera last shown.
            std::optional<Look> look;
            if (program && std::isfinite(status.time))
                if (const auto clip = showing_clip(*program, playback, status.time)) look = program->look(*clip, status.time);
            if (!exporting.load()) open_range(session);
            const bool camera_recent = GetTickCount64() - last_shown_at.load() < 250;
            apply_look(look, camera_recent ? shown_focus.load() : 0, shown_blur.load());
            if (reached_end.exchange(false)) {
                auto stopped = playback;
                stopped.playing = false;
                bridge().set_playback(stopped);
            }
            status.active = true;
        }
        if (replay_open) keep_footage(s, status);
        watch_export(base, s, status);
        status.exporting = exporting.load();
        status.export_message = s.export_message;
        status.export_failed = s.export_failed;
        status.export_serial = s.export_serial;
        // The camera's counts, by the second.
        const auto now = GetTickCount64();
        if (now - s.second_started >= 1000) {
            s.second_started = now;
            s.asks_last = asks.exchange(0);
            s.shown_last = shown.exchange(0);
        }
        status.camera_asks = s.asks_last;
        status.view_taken = GetTickCount64() - last_shown_at.load() < 250;
        status.camera_shown = s.shown_last;
        trim_to_window(s, status.window_start);
        if (s.moments_revision != s.published_revision) {
            s.published_revision = s.moments_revision;
            bridge().set_moments(std::make_shared<const std::vector<Moment>>(s.moments));
        }
        status.players.push_back({0, "You"});
        for (const auto& [id, name] : s.roster) status.players.push_back({id, name});
        {
            std::lock_guard lock(tracks_mutex);
            for (const auto& [id, samples] : tracks)
                if (!s.roster.contains(id)) status.players.push_back({id, std::format("Player {:x}", id & 0xffff)});
        }
        status.notice = s.notice;
        status.edit_clip = edit_clip.load();
        status.holding = hold_left.load() >= 0;
        if (s.took_over && std::isfinite(status.time)) {
            for (const Part part : {Part::body, Part::head, Part::board})
                if (const auto place = target_place({0, part}, status.time)) status.targets.push_back({{0, part}, *place});
            for (const auto& player : status.players)
                if (player.id)
                    if (const auto place = target_place({player.id, Part::body}, status.time))
                        status.targets.push_back({{player.id, Part::body}, *place});
        }
        bridge().publish(std::move(status));
    } catch (const std::exception& error) {
        logging::log(logging::Level::warning, logging::Channel::runtime, "Replay editor tick failed: {}", error.what());
    } catch (...) {}
}

std::string status_text() {
    if (!available()) return "The replay editor is unavailable for this game build.";
    const auto s = bridge().status();
    const auto program = bridge().program();
    return std::format("replay open: {}, ReSkate's editor: {}, window {:.1f}..{:.1f} s ({:.1f} min), time {:.2f}, rate {:.2f}\n"
                       "clips: {}, footage kept: {:.1f} s, camera asked {}/s, answered {}/s, exporting: {}{}",
                       s.replay_open ? "yes" : "no", s.active ? "yes" : "no", s.window_start, s.window_end,
                       (s.window_end - s.window_start) / 60.0, s.time, s.rate, program ? program->project().clips.size() : 0, s.locked,
                       s.camera_asks, s.camera_shown, s.exporting ? "yes" : "no", s.notice.empty() ? "" : "\nlast: " + s.notice);
}
} // namespace dingosdk::replay_editor::session
