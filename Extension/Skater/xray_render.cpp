#include "xray_render.h"
#include "Engine/Core/Hooks/hooks.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/20260929/skater_render.h"
#include "Engine/Game/Rendering/draw_packet.h"
#include "Engine/Game/UI/game_view.h"
#include "Extension/Skater/no_bail.h"
#include <Windows.h>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>
#include <format>
#include <mutex>
#include <numbers>
#include <span>
#include <string>

namespace dingosdk::xray {
// TEMPORARY (2026-10-25): each frame's pick, read from outside the game while it runs.
struct FramePickRecord {
    std::uint64_t chosen, newest;
    std::int32_t matches, unused;
    float picked[3], game[3];
};
std::array<FramePickRecord, 128> frame_picks{};
std::atomic<std::uint32_t> frame_pick_next{};
namespace {
namespace build = addr::skater_render;
using DrawPacket = void (*)(std::uintptr_t object, std::uintptr_t packet);
using RenderView = void (*)(std::uintptr_t blackboard, std::uintptr_t current, std::uintptr_t previous, std::uint8_t jitter);
using FrameSetup = void (*)(std::uintptr_t renderer, std::uintptr_t frame, std::uintptr_t state, std::uintptr_t a4, std::uintptr_t a5,
                            std::uintptr_t a6, std::uintptr_t a7, std::uintptr_t a8);
constexpr std::uint32_t no_index = UINT32_MAX;
constexpr std::uint32_t most_bones = 1024;
constexpr std::uint64_t lease_ms = 500;  // the client tick's indices, while ticks come and a bail shows
constexpr std::uint64_t fresh_ms = 250;  // a picture's parts, while the renderer draws
constexpr float camera_reach = 10.0f;    // metres from the client's camera: the main view's, not a mirror's
constexpr std::uint64_t given_ms = 150;  // set_view_camera's camera, until given again
constexpr std::uint64_t steady_given_ms = 2000; // the same while frames are steady (an export renders slower)

struct State {
    std::atomic<bool> ready{}; // the hooks prepared
    bool hooked{};             // and enabled (hook_render): client thread only
    std::uintptr_t base{};
    DrawPacket draw_original{};
    RenderView view_original{};
    FrameSetup frame_original{};
    std::array<std::atomic<std::uint32_t>, build::render_modes> indices{no_index, no_index};
    std::atomic<std::uint64_t> indices_until{};
    std::atomic<bool> found_logged{}, hiding{}, hide_logged{};
    std::mutex lock; // guards the picture's parts
    std::vector<game::LinearTransform> skin;
    std::uint64_t skin_at{};
    std::array<float, 16> camera{};
    float vertical_fov{};
    std::uint64_t camera_at{};
    // set_view_camera's camera, under its own lock: written from the game, read by the renderer.
    std::mutex given_lock;
    std::array<float, 16> given{};
    float given_fov{};
    std::uint64_t given_at{};
    bool steady{}; // set_view_camera's `steady_frames`
    // The last cameras given (one a game tick), numbered and timed, so each frame can be drawn between
    // two of them as the game draws its own (give_view_camera).
    struct Given {
        std::array<float, 16> world{};
        float fov{};
        std::uint64_t serial{};
        std::chrono::steady_clock::time_point at{};
    };
    std::array<Given, 8> recent{};
    std::size_t recent_next{};
    std::uint64_t serial{};
    // The camera given for this frame and the frame before (give_view_camera), and when the frame began.
    std::array<float, 16> frame_now{}, frame_before{};
    float frame_fov{}, frame_fov_before{};
    std::uint64_t frame_at{};
    std::atomic<bool> given_logged{};
};
State& state() { static auto* value = new State; return *value; }

// A hook must not leave the game a different last error.
struct LastError {
    DWORD value = GetLastError();
    ~LastError() { SetLastError(value); }
};
std::uintptr_t pointer_at(std::uintptr_t address) noexcept {
    std::uintptr_t value{};
    return memory::peek(address, value) ? value : 0;
}

// The record a handle names in a manager's paged pool.
std::uintptr_t record_of(std::uintptr_t manager, const build::RenderManager& kind, std::uint32_t handle) noexcept {
    if (handle < build::first_handle || handle > 1'000'000) return 0;
    const std::uint64_t slot = std::uint64_t{handle - build::first_handle} + 16;
    const auto high = std::bit_width(slot) - 1; // 4 and up
    const auto page = pointer_at(manager + build::manager_pool_offset + 8 + 8 * (high - 4));
    return page ? page + static_cast<std::uintptr_t>(slot - (std::uint64_t{1} << high)) * kind.record_size : 0;
}
// The render index of the entity's render object for one mode, through the managers' handles.
std::uint32_t render_index(std::uintptr_t base, std::uintptr_t entity, std::size_t mode) noexcept {
    std::uint32_t handle{};
    if (!memory::peek(entity + build::entity_render_handles_offset + mode * build::entity_render_handle_stride, handle))
        return no_index;
    for (const auto& kind : build::handle_chain) {
        const auto manager = pointer_at(base + kind.global);
        if (!manager || pointer_at(manager) != base + kind.vtable) return no_index;
        const auto record = record_of(manager, kind, handle);
        if (!record || !memory::peek(record + kind.handle_offset, handle)) return no_index;
    }
    return handle >= build::first_handle ? handle - build::first_handle : no_index;
}

// One of the local skater's render objects (riding or walking), while the client tick follows them.
bool local_object(State& s, std::uintptr_t object) noexcept {
    std::uint32_t index{};
    return GetTickCount64() <= s.indices_until.load(std::memory_order_acquire) && pointer_at(object) == s.base + build::render_object_vtable &&
           memory::peek(object + build::render_index_offset, index) &&
           (index == s.indices[0].load(std::memory_order_acquire) || index == s.indices[1].load(std::memory_order_acquire));
}
bool clear_byte(std::uintptr_t address) noexcept {
    __try {
        *reinterpret_cast<volatile std::uint8_t*>(address) = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}
// Render threads, after each skinned draw packet: the local skater's visible one, as skinning
// matrices in the world.
void observe_packet(std::uintptr_t object, std::uintptr_t packet) {
    auto& s = state();
    std::uint32_t index{}, count{}, locked{};
    std::uint8_t visible{}, relative{};
    if (GetTickCount64() > s.indices_until.load(std::memory_order_acquire) ||
        pointer_at(object) != s.base + build::render_object_vtable || !memory::peek(object + build::render_index_offset, index) ||
        (index != s.indices[0].load(std::memory_order_acquire) && index != s.indices[1].load(std::memory_order_acquire)))
        return;
    if (!memory::peek(packet + build::packet_visible_offset, visible) || !visible ||
        !memory::peek(packet + build::packet_bone_count_offset, count) || !count || count > most_bones ||
        !memory::peek(packet + build::packet_relative_offset, relative) ||
        !memory::peek(object + build::render_object_lock_offset, locked) || locked)
        return;
    const auto bones = pointer_at(packet + build::packet_bones_offset), root_at = pointer_at(packet + build::packet_root_offset);
    std::vector<draw_packet::PackedBone> packed(count);
    std::array<float, 4> root{};
    game::LinearTransform actor{};
    if (!bones || !memory::peek_bytes(bones, packed.data(), packed.size() * sizeof(draw_packet::PackedBone)) ||
        (root_at && !memory::peek(root_at, root)) || !memory::peek(packet + build::packet_actor_offset, actor))
        return;
    const auto placed = draw_packet::placement(root, relative != 0, actor);
    std::vector<game::LinearTransform> skin(count);
    for (std::size_t bone = 0; bone < count; ++bone)
        if (!draw_packet::skin(packed[bone], placed, skin[bone])) return;
    {
        std::lock_guard guard(s.lock);
        s.skin = std::move(skin);
        s.skin_at = GetTickCount64();
    }
    if (!s.found_logged.exchange(true))
        logging::log(logging::Level::info, logging::Channel::graphics,
            "X-ray: the renderer draws the local skater (render object {}, {} bones).", index, count);
}
void draw_packet_hook(std::uintptr_t object, std::uintptr_t packet) {
    auto& s = state();
    s.draw_original(object, packet);
    LastError error;
    try {
        // Hidden on this screen (reskate.skater.hide): the packet goes out not visible.
        if (s.hiding.load(std::memory_order_acquire) && packet && local_object(s, object)) {
            if (clear_byte(packet + build::packet_visible_offset) && !s.hide_logged.exchange(true))
                logging::log(logging::Level::info, logging::Channel::graphics, "Skater hide: the local skater's draw packets go out not visible.");
            return;
        }
        observe_packet(object, packet);
    } catch (...) { /* A lost picture is never worth the renderer. */ }
}

// The camera of the main picture: a sound world matrix, close to the client's own camera.
void observe_view(std::uintptr_t view) {
    auto& s = state();
    if (GetTickCount64() > s.indices_until.load(std::memory_order_acquire)) return;
    std::uint32_t kind{};
    std::array<std::byte, build::view_size> data{};
    if (!memory::peek(view - build::view_kind_back, kind) || kind != build::main_view_kind ||
        !memory::peek_bytes(view, data.data(), data.size()))
        return;
    std::array<float, 16> camera{};
    float radians{};
    std::memcpy(camera.data(), data.data() + build::view_camera_offset, sizeof(camera));
    std::memcpy(&radians, data.data() + build::view_fov_offset, sizeof(radians));
    for (std::size_t row = 0; row < 4; ++row) {
        for (std::size_t axis = 0; axis < 3; ++axis)
            if (!std::isfinite(camera[row * 4 + axis]) || std::abs(camera[row * 4 + axis]) > 1e7f) return;
        camera[row * 4 + 3] = row == 3 ? 1.0f : 0.0f;
    }
    for (std::size_t row = 0; row < 3; ++row)
        for (std::size_t other = row; other < 3; ++other) {
            float dot{};
            for (std::size_t axis = 0; axis < 3; ++axis) dot += camera[row * 4 + axis] * camera[other * 4 + axis];
            if (std::abs(dot - (row == other ? 1.0f : 0.0f)) > 0.05f) return;
        }
    const float fov = radians * 180.0f / std::numbers::pi_v<float>;
    const auto client = latest_game_view();
    if (!std::isfinite(fov) || fov <= 1 || fov >= 175 || !client) return;
    float distance{};
    for (std::size_t axis = 0; axis < 3; ++axis) {
        const float delta = camera[12 + axis] - client->world[12 + axis];
        distance += delta * delta;
    }
    if (!(distance <= camera_reach * camera_reach)) return;
    std::lock_guard guard(s.lock);
    s.camera = camera;
    s.vertical_fov = fov;
    s.camera_at = GetTickCount64();
}
// The camera rows (their fourth lanes kept) and the FOV written into a view, and everything the view
// derives from them marked out of date, so its matrices and frustum are derived from this camera.
bool write_view_camera(std::uintptr_t view, const std::array<float, 16>& world, float radians) noexcept {
    __try {
        for (std::size_t row = 0; row < 4; ++row)
            std::memcpy(reinterpret_cast<void*>(view + build::view_camera_offset + row * 16), world.data() + row * 4, sizeof(float) * 3);
        std::memcpy(reinterpret_cast<void*>(view + build::view_fov_offset), &radians, sizeof(radians));
        *reinterpret_cast<std::uint32_t*>(view + build::view_stale_offset) |= build::view_all_stale;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}
// A view's camera position.
bool view_position(std::uintptr_t view, std::array<float, 3>& at) noexcept {
    return memory::peek(view + build::view_camera_offset + 3 * 16, at);
}
bool same_place(const std::array<float, 3>& a, const std::array<float, 3>& b, float within = 0.01f) noexcept {
    return std::abs(a[0] - b[0]) < within && std::abs(a[1] - b[1]) < within && std::abs(a[2] - b[2]) < within;
}
// A camera matrix's rows right, up and back made unit length and square to each other again (after
// two cameras were blended), the back row kept as it was most.
void orthonormal(std::array<float, 16>& m) noexcept {
    const auto row = [&](std::size_t r) { return std::array<float, 3>{m[r * 4], m[r * 4 + 1], m[r * 4 + 2]}; };
    const auto dot = [](const std::array<float, 3>& a, const std::array<float, 3>& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; };
    const auto unit = [&](std::array<float, 3> v) {
        const float length = std::sqrt(dot(v, v));
        if (length > 1e-6f)
            for (auto& x : v) x /= length;
        return v;
    };
    const auto back = unit(row(2));
    auto right = row(0);
    const float rb = dot(right, back);
    for (std::size_t c = 0; c < 3; ++c) right[c] -= back[c] * rb;
    right = unit(right);
    auto up = row(1);
    const float ub = dot(up, back), ur = dot(up, right);
    for (std::size_t c = 0; c < 3; ++c) up[c] -= back[c] * ub + right[c] * ur;
    up = unit(up);
    for (std::size_t c = 0; c < 3; ++c) {
        m[c] = right[c];
        m[4 + c] = up[c];
        m[8 + c] = back[c];
    }
}
// A view's whole camera: its four rows, without their fourth lanes.
using Pose = std::array<float, 12>;
bool view_pose(std::uintptr_t view, Pose& pose) noexcept {
    for (std::size_t row = 0; row < 4; ++row)
        if (!memory::peek_bytes(view + build::view_camera_offset + row * 16, pose.data() + row * 3, sizeof(float) * 3)) return false;
    return true;
}
bool same_pose(const Pose& a, const Pose& b) noexcept {
    for (std::size_t i = 0; i < a.size(); ++i)
        if (std::abs(a[i] - b[i]) > (i < 9 ? 0.0001f : 0.01f)) return false;
    return true;
}
// The main view gets set_view_camera's camera while it is fresh, and the previous main view the camera
// given for the frame before, so motion blur and the temporal filters see ReSkate's camera move, not
// the game's (the same camera in both smeared the picture as it moved). Once a frame, at the frame
// setup: the shaders' view is set up later from the frame's own copy, so it follows without being
// written (written there too and marked out of date, it was not derived again and the picture broke).
// `others`: further views of the same frame; each that is the game's camera exactly, now or the frame
// before (made from it, for lighting, say), gets the matching camera too, with its own field of view.
// Position alone is not enough: views of their own that only stand at the camera (looking their own
// way) were turned with it, which wrecked the picture's exposure where the game's camera stood still.
void give_view_camera(std::uintptr_t current, std::uintptr_t previous, std::span<const std::uintptr_t> others) {
    auto& s = state();
    std::uint32_t kind{};
    if (!memory::peek(current - build::view_kind_back, kind) || kind != build::main_view_kind) return;
    std::array<float, 3> game_at{};
    (void)view_position(current, game_at);
    Pose game_pose{}, game_pose_before{};
    const bool posed = view_pose(current, game_pose);
    const bool posed_before = previous && view_pose(previous, game_pose_before);
    std::array<float, 16> world{}, before{};
    float fov{}, fov_before{};
    {
        std::lock_guard guard(s.given_lock);
        const auto now = GetTickCount64();
        const auto fresh = s.steady ? steady_given_ms : given_ms;
        if (!s.given_at || now - s.given_at > fresh) {
            s.frame_at = 0;
            return;
        }
        // The renderer draws more often than the game ticks (2.4 frames a tick at 144 Hz) and draws each
        // frame between the last two ticks, so the game's camera and the world move on every frame
        // while the cameras given change once a tick: taken as they were, the camera stood still for
        // two frames and jumped on the third, and the skater jittered against it. So the frame gets the
        // camera between the last two given, as far along as the time since the newest says. (Placing
        // it by the game's camera in the frame agreed with the time only now and then, and every
        // switch between the two jumped.)
        const auto find = [&](std::uint64_t serial) -> const State::Given* {
            for (const auto& given : s.recent)
                if (given.serial && given.serial == serial) return &given;
            return nullptr;
        };
        const State::Given* to = find(s.serial);
        const State::Given* from = nullptr;
        float along = 1;
        // Steady frames (an export) are drawn one a tick at their own pace, not the clock's: the newest
        // as it is (placed by the clock, the exported skater jittered against the camera).
        if (to && !s.steady)
            if (const auto* before_newest = find(s.serial - 1); before_newest && to->at > before_newest->at) {
                const float tick = std::chrono::duration<float>(to->at - before_newest->at).count();
                const float since = std::chrono::duration<float>(std::chrono::steady_clock::now() - to->at).count();
                from = before_newest;
                along = std::clamp(since / tick, 0.0f, 1.0f);
            }
        std::array<float, 16> pick = to ? to->world : s.given;
        float pick_fov = to ? to->fov : s.given_fov;
        if (from && to) {
            for (std::size_t i = 0; i < 16; ++i) pick[i] = from->world[i] + (to->world[i] - from->world[i]) * along;
            pick_fov = from->fov + (to->fov - from->fov) * along;
            orthonormal(pick);
        }
        {
            auto& record = frame_picks[frame_pick_next.fetch_add(1) % frame_picks.size()];
            record = {to ? to->serial : 0, s.serial, 0, static_cast<std::int32_t>(along * 1000), {pick[12], pick[13], pick[14]}, {game_at[0], game_at[1], game_at[2]}};
        }
        const bool going = s.frame_at && now - s.frame_at <= fresh;
        s.frame_before = going ? s.frame_now : pick;
        s.frame_fov_before = going ? s.frame_fov : pick_fov;
        s.frame_now = pick;
        s.frame_fov = pick_fov;
        s.frame_at = now;
        world = s.frame_now;
        before = s.frame_before;
        fov = s.frame_fov;
        fov_before = s.frame_fov_before;
    }
    const auto radians = [](float degrees) { return degrees * std::numbers::pi_v<float> / 180.0f; };
    if (!write_view_camera(current, world, radians(fov))) return;
    if (previous && previous != current) (void)write_view_camera(previous, before, radians(fov_before));
    std::string matched;
    for (std::size_t i = 0; i < others.size(); ++i) {
        Pose pose{};
        float own_fov{};
        if (!others[i] || !view_pose(others[i], pose) || !memory::peek(others[i] + build::view_fov_offset, own_fov)) continue;
        if (posed && same_pose(pose, game_pose)) {
            if (write_view_camera(others[i], world, own_fov)) matched += std::format(" {}", i);
        } else if (posed_before && same_pose(pose, game_pose_before)) {
            if (write_view_camera(others[i], before, own_fov)) matched += std::format(" {}(before)", i);
        }
    }
    if (!s.given_logged.exchange(true))
        logging::log(logging::Level::info, logging::Channel::graphics,
                     "Render camera: the main picture is drawn from a camera ReSkate gives; other views of the frame given it too:{}.",
                     matched.empty() ? " none" : matched);
}
void render_view_hook(std::uintptr_t blackboard, std::uintptr_t current, std::uintptr_t previous, std::uint8_t jitter) {
    auto& s = state();
    s.view_original(blackboard, current, previous, jitter);
    LastError error;
    try {
        observe_view(current);
    } catch (...) { /* A lost camera is never worth the renderer. */ }
}
// The frame's views as the world renderer takes them, before it culls: the given camera goes in here
// so what is drawn, and how it is lit, follows it too (given at the shaders' view setup alone, only the
// picture moved).
void frame_setup_hook(std::uintptr_t renderer, std::uintptr_t frame, std::uintptr_t setup_state, std::uintptr_t a4, std::uintptr_t a5,
                      std::uintptr_t a6, std::uintptr_t a7, std::uintptr_t a8) {
    auto& s = state();
    try {
        if (frame) {
            std::array<std::uintptr_t, build::frame_views - 2> others{};
            std::size_t n = 0;
            for (std::size_t i = 0; i < build::frame_views; ++i) {
                const auto view = frame + build::frame_main_view + i * build::frame_view_stride;
                if (view != frame + build::frame_main_view && view != frame + build::frame_previous_view) others[n++] = view;
            }
            give_view_camera(frame + build::frame_main_view, frame + build::frame_previous_view, others);
        }
    } catch (...) { /* The game's camera, then. */ }
    s.frame_original(renderer, frame, setup_state, a4, a5, a6, a7, a8);
}
std::array<void*, 3> render_targets(std::uintptr_t base) noexcept {
    return {reinterpret_cast<void*>(base + build::draw_packet_contract.rva),
        reinterpret_cast<void*>(base + build::render_view_contract.rva),
        reinterpret_cast<void*>(base + build::frame_setup_contract.rva)};
}
}

bool start_render(std::uintptr_t base) noexcept {
    auto& s = state();
    if (s.ready.load(std::memory_order_acquire)) return s.base == base;
    for (const auto& contract : build::contracts) {
        std::array<unsigned char, 32> actual{};
        if (!memory::peek(base + contract.rva, actual) || actual != contract.bytes) {
            logging::log(logging::Level::warning, logging::Channel::graphics,
                "The skater x-ray cannot see where the skater is drawn: the native contract at 0x{:x} did not match.", contract.rva);
            return false;
        }
    }
    s.base = base;
    const auto targets = render_targets(base);
    const std::array replacements{reinterpret_cast<void*>(&draw_packet_hook), reinterpret_cast<void*>(&render_view_hook),
        reinterpret_cast<void*>(&frame_setup_hook)};
    std::array<void*, 3> originals{};
    auto status = HookOk;
    std::size_t prepared{};
    for (; prepared < targets.size(); ++prepared) {
        status = hook_prepare(targets[prepared], replacements[prepared], &originals[prepared]);
        if (status != HookOk) break;
        if (!originals[prepared]) {
            ++prepared;
            status = HookUnsupportedFunction;
            break;
        }
    }
    if (status == HookOk) {
        // Both relays are published before either target is enabled (hook_render).
        s.draw_original = reinterpret_cast<DrawPacket>(originals[0]);
        s.view_original = reinterpret_cast<RenderView>(originals[1]);
        s.frame_original = reinterpret_cast<FrameSetup>(originals[2]);
        s.ready.store(true, std::memory_order_release);
        return true;
    }
    logging::log(logging::Level::warning, logging::Channel::graphics,
        "The skater x-ray cannot see where the skater is drawn: hooking the renderer failed (status {}).", static_cast<LONG>(status));
    while (prepared) (void)hook_remove(targets[--prepared]);
    return false;
}

bool hook_render(bool on) noexcept {
    auto& s = state();
    if (!s.ready.load(std::memory_order_acquire)) return !on; // nothing to hook
    if (s.hooked == on) return true;
    const auto targets = render_targets(s.base);
    auto status = HookOk;
    std::size_t changed{};
    for (; changed < targets.size(); ++changed) {
        status = on ? hook_enable(targets[changed]) : hook_disable(targets[changed]);
        if (status != HookOk) break;
    }
    if (status == HookOk) {
        s.hooked = on;
        return true;
    }
    logging::log(logging::Level::warning, logging::Channel::graphics, "The skater x-ray could not {} its renderer hooks (status {}).",
        on ? "enable" : "disable", static_cast<LONG>(status));
    // Both or neither.
    while (changed) {
        const auto target = targets[--changed];
        (void)(on ? hook_disable(target) : hook_enable(target));
    }
    return false;
}

void follow_render(bool wanted) noexcept {
    auto& s = state();
    if (!s.ready.load(std::memory_order_acquire)) return;
    NoBailSkater skater;
    if (!wanted || !no_bail_skater(skater)) {
        s.indices_until.store(0, std::memory_order_release);
        return;
    }
    for (std::size_t mode = 0; mode < build::render_modes; ++mode)
        s.indices[mode].store(render_index(s.base, skater.entity, mode), std::memory_order_release);
    s.indices_until.store(GetTickCount64() + lease_ms, std::memory_order_release);
}

void hide_skater(bool hidden) noexcept { state().hiding.store(hidden, std::memory_order_release); }
void set_view_camera(const std::array<float, 16>& world, float vertical_fov, bool steady_frames) noexcept {
    auto& s = state();
    std::lock_guard guard(s.given_lock);
    s.given = world;
    s.given_fov = vertical_fov;
    s.given_at = GetTickCount64();
    s.steady = steady_frames;
    s.recent[s.recent_next] = {world, vertical_fov, ++s.serial, std::chrono::steady_clock::now()};
    s.recent_next = (s.recent_next + 1) % s.recent.size();
}
bool latest_picture(Picture& picture) noexcept {
    auto& s = state();
    const auto now = GetTickCount64();
    std::lock_guard guard(s.lock);
    if (!s.skin_at || !s.camera_at || now - s.skin_at > fresh_ms || now - s.camera_at > fresh_ms) return false;
    try {
        picture.skin = s.skin;
    } catch (...) {
        return false;
    }
    picture.camera = s.camera;
    picture.vertical_fov = s.vertical_fov;
    return true;
}
}
