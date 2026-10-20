#include "skater_animation.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Game/Build/20260929/no_bail.h"
#include "Engine/Game/Build/20260929/skater_state.h"
#include "Extension/Multiplayer/Remote/native_pose_layout.h"
#include "Extension/Multiplayer/Remote/native_skater.h"
#include <Windows.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <format>
#include <mutex>

// The pose paths of Animation Studio (PR 297, anim_studio.cpp: on_animation, on_render,
// on_board_render, on_send), for clips plugins play; see the header.
namespace dingosdk::skater_animation {
namespace {
using namespace anim_studio;
using logging::Channel;
using logging::Level;

// ---- guarded memory --------------------------------------------------------------------------------
constexpr std::uintptr_t highest_user = 0x00007fffffffffffULL;
bool peek(std::uintptr_t address, void* out, std::size_t size) noexcept {
    if (address < 0x10000 || address > highest_user - size) return false;
    __try {
        std::memcpy(out, reinterpret_cast<const void*>(address), size);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}
bool poke(std::uintptr_t address, const void* data, std::size_t size) noexcept {
    if (address < 0x10000 || address > highest_user - size) return false;
    __try {
        std::memcpy(reinterpret_cast<void*>(address), data, size);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}
template <class T> std::optional<T> read(std::uintptr_t address) noexcept {
    T value{};
    if (!peek(address, &value, sizeof(T))) return std::nullopt;
    return value;
}
struct alignas(16) NativeBone {
    std::array<float, 4> scale, rotation, position;
};
static_assert(sizeof(NativeBone) == 0x30);

double now_seconds() noexcept {
    static const double frequency = [] {
        LARGE_INTEGER f{};
        QueryPerformanceFrequency(&f);
        return static_cast<double>(f.QuadPart);
    }();
    LARGE_INTEGER c{};
    QueryPerformanceCounter(&c);
    return static_cast<double>(c.QuadPart) / frequency;
}

// ---- transforms ------------------------------------------------------------------------------------
// One transform after another (parent, then child in the parent's frame); uniform scale.
Joint compose(const Joint& parent, const Joint& child) noexcept {
    const float k = (parent.scale[0] + parent.scale[1] + parent.scale[2]) / 3.0f;
    const auto moved = rotate(parent.rotation, {child.position[0] * k, child.position[1] * k, child.position[2] * k});
    Joint out;
    out.position = {parent.position[0] + moved[0], parent.position[1] + moved[1], parent.position[2] + moved[2]};
    out.rotation = normalised(multiply(parent.rotation, child.rotation));
    const float c = (child.scale[0] + child.scale[1] + child.scale[2]) / 3.0f;
    out.scale = {k * c, k * c, k * c};
    return out;
}
// `world` seen from `parent`'s frame.
Joint relative(const Joint& parent, const Joint& world) noexcept {
    const float k = std::max((parent.scale[0] + parent.scale[1] + parent.scale[2]) / 3.0f, 1e-4f);
    const auto back = conjugate(parent.rotation);
    const auto d = rotate(back, {world.position[0] - parent.position[0], world.position[1] - parent.position[1], world.position[2] - parent.position[2]});
    Joint out;
    out.position = {d[0] / k, d[1] / k, d[2] / k};
    out.rotation = normalised(multiply(back, world.rotation));
    const float c = (world.scale[0] + world.scale[1] + world.scale[2]) / 3.0f;
    out.scale = {c / k, c / k, c / k};
    return out;
}
Joint joint_of(const NativeBone& b) noexcept {
    Joint j;
    j.scale = {b.scale[0], b.scale[1], b.scale[2]};
    j.rotation = b.rotation;
    j.position = {b.position[0], b.position[1], b.position[2]};
    return j;
}
// The board's rig (board_pose.h): 16 bones, 0 its reference, 1 its place in the world, 2 the deck's
// mount, which carries the deck, the trucks and the wheels.
constexpr std::uint32_t board_bones = 16;
constexpr std::size_t board_mount = 2;
Joint board_parent(const std::array<NativeBone, board_bones>& b) noexcept { return compose(joint_of(b[0]), joint_of(b[1])); }

// The body: Hips (7) and every joint below it. A clip replaces these only, never the placement
// joints the game moves the skater with, nor the board's bones in the skater's rig.
const std::array<bool, skeleton_joints>& body_joints() {
    static const auto mask = [] {
        std::array<bool, skeleton_joints> m{};
        for (std::uint16_t i = 0; i < skeleton_joints; ++i)
            for (int at = i; at >= 0; at = parent(static_cast<std::uint16_t>(at)))
                if (at == hips_joint) {
                    m[i] = true;
                    break;
                }
        return m;
    }();
    return mask;
}

// ---- the skater ------------------------------------------------------------------------------------
// The local skater's physics state (no_bail.cpp's selector): component +0x70 the core, core +0x3c0 its
// context, context +0x1414 the state. In the air on the board: 200, 201.
std::optional<bool> in_the_air(std::uintptr_t base, std::uintptr_t component) noexcept {
    const auto core = read<std::uintptr_t>(component + 0x70);
    if (!core || !*core) return std::nullopt;
    const auto type = read<std::uintptr_t>(*core);
    if (!type || *type != base + addr::no_bail::bail_core_vtable) return std::nullopt;
    const auto context = read<std::uintptr_t>(*core + 0x3c0);
    if (!context || !*context) return std::nullopt;
    const auto value = read<std::uint32_t>(*context + addr::skater_state::physics_state_offset);
    if (!value) return std::nullopt;
    return std::find(addr::skater_state::board_air_states.begin(), addr::skater_state::board_air_states.end(), *value) !=
           addr::skater_state::board_air_states.end();
}
// The game's name for the trick the skater is doing ("ollie", "kickflip"): the animation holder
// (component +0xa0) -> +0x20 -> +0x250 -> +0x98, a C string (found 2026-10-18 for PR 297; right from
// 0.05 s after takeoff and through the whole air). Empty when the chain or the text looks wrong.
std::string trick_of(std::uintptr_t component) noexcept {
    const auto holder = read<std::uintptr_t>(component + 0xa0).value_or(0);
    const auto a = holder ? read<std::uintptr_t>(holder + 0x20).value_or(0) : 0;
    const auto b = a ? read<std::uintptr_t>(a + 0x250).value_or(0) : 0;
    const auto c = b ? read<std::uintptr_t>(b + 0x98).value_or(0) : 0;
    char text[49]{};
    if (!c || !peek(c, text, 48)) return {};
    std::string name;
    for (std::size_t i = 0; i < 48 && text[i]; ++i) {
        const char ch = text[i];
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == ' ' || ch == '-')) return {};
        name += static_cast<char>(ch >= 'A' && ch <= 'Z' ? ch + 32 : ch);
    }
    return name.size() >= 2 ? name : std::string{};
}
// The board's upward speed (m/s): its physics' root body (skater_state.h).
std::optional<float> board_up_speed(std::uintptr_t base, std::uintptr_t component) noexcept {
    namespace st = addr::skater_state;
    const auto core = read<std::uintptr_t>(component + 0x70).value_or(0);
    const auto holder = core ? read<std::uintptr_t>(core + st::board_holder_offset).value_or(0) : 0;
    const auto physics = holder ? read<std::uintptr_t>(holder + st::board_physics_offset).value_or(0) : 0;
    if (!physics || read<std::uintptr_t>(physics).value_or(0) != base + st::board_physics_vtable) return std::nullopt;
    const auto bodies = read<std::uintptr_t>(physics + st::physics_bodies_offset).value_or(0);
    if (!bodies || read<std::uint32_t>(bodies).value_or(0) != st::board_body_count) return std::nullopt;
    if (read<std::uintptr_t>(bodies + st::body_owner_offset).value_or(0) != physics) return std::nullopt;
    const auto v = read<std::array<float, 3>>(bodies + st::body_velocity_offset);
    if (!v || !std::isfinite((*v)[1])) return std::nullopt;
    return (*v)[1];
}
std::string pop_of(float air) {
    if (!(air > 0)) return {};
    return air < 0.45f ? "low" : air < 0.65f ? "mid" : "high";
}

// ---- what the client thread asks -------------------------------------------------------------------
struct Plan {
    std::optional<Play> play;
    double started{};
    float from{};               // the clip's seconds at `started`
    std::optional<float> held;  // paused at these seconds of the clip
    std::uint64_t serial{};
    std::vector<Replacement> replacements;
    bool allowed{};
    float record_seconds{}; // > 0: record this long, from the next update
    std::uint64_t record_serial{};
    std::optional<arm_reach::Goal> reach;
    double reach_until{}, joints_until{}; // now_seconds() until which the reach holds, and the joints are read
    std::vector<std::uint16_t> joints_read; // joint(): the joints asked for, in order
    std::vector<PoseOffset> offsets;        // pose(), until offsets_until
    float offsets_weight{1};
    double offsets_until{};
};
// The joints asked for as last evaluated (joint()), for the client thread.
std::mutex joints_mutex;
std::vector<std::pair<std::uint16_t, Joint>> joints_now;
// The client thread's: each joint asked for and when it was last.
std::vector<std::pair<std::uint16_t, double>> joints_asked;
std::mutex plan_mutex;
std::shared_ptr<const Plan> plan_now = std::make_shared<Plan>();
Plan plan_draft; // the client thread's, published as plan_now
std::shared_ptr<const Plan> plan() {
    std::lock_guard lock(plan_mutex);
    return plan_now;
}
void publish() {
    auto next = std::make_shared<const Plan>(plan_draft);
    std::lock_guard lock(plan_mutex);
    plan_now = std::move(next);
}
std::atomic<std::uint64_t> finished_serial{}; // the play the animation thread saw finish
std::mutex recorded_mutex;
std::shared_ptr<const Clip> recorded; // under recorded_mutex
std::atomic<bool> record_running{};

// ---- the animation thread's own ----------------------------------------------------------------------
struct Live {
    std::atomic<std::uintptr_t> base{}, component{}, board_holder{};
    std::vector<NativeBone> bones;
    std::vector<Joint> pose, custom;
    std::array<NativeBone, board_bones> board{};
    bool board_ok{};
    // A game trick played as a replacement.
    bool game_air{};
    double game_takeoff{}, game_landing{-1};
    int game_ground{};
    float predicted_air{};
    const Replacement* game_trick{};
    std::shared_ptr<const Plan> game_plan; // keeps game_trick alive
    // Recording.
    std::atomic<std::uint64_t> record_serial{};
    double record_start{-1}, record_until{};
    Clip taking;
    bool taking_board{true}, was_air{};
    std::uint64_t failures{};
};
Live& live() {
    static auto* l = new Live;
    return *l;
}
// The pose to draw, from the animation thread to the render publication.
struct Pending {
    std::mutex mutex;
    std::uintptr_t buffer{};
    std::uint32_t first{}, last{};
    std::vector<NativeBone> bones; // [first, last)
    double at{};
};
Pending& pending() {
    static auto* p = new Pending;
    return *p;
}
// Where the board's mount goes in the world, and how much of that.
struct PendingBoard {
    std::mutex mutex;
    Joint mount;
    float weight{};
    double at{};
};
PendingBoard& pending_board() {
    static auto* p = new PendingBoard;
    return *p;
}
// What other players get of the local skater: the same joints as the renderer.
struct SentPose {
    std::mutex mutex;
    std::uintptr_t component{};
    std::uint32_t first{}, last{};
    std::vector<Joint> joints;
    double at{};
};
SentPose& sent_pose() {
    static auto* value = new SentPose;
    return *value;
}

void finish_recording(Live& l) {
    record_running.store(false, std::memory_order_release);
    l.record_start = -1;
    auto clip = std::make_shared<Clip>(std::move(l.taking));
    l.taking = {};
    if (clip->times.size() < 2) return;
    if (!l.taking_board) clip->board.clear();
    std::lock_guard lock(recorded_mutex);
    recorded = std::move(clip);
}
void record_frame(Live& l, double at, const std::optional<bool>& air) {
    if (l.record_start < 0) {
        l.record_start = at;
        l.taking = {};
        l.taking.joints = skeleton_joints;
        l.taking_board = true;
        l.was_air = air && *air;
    }
    const float t = static_cast<float>(at - l.record_start);
    l.taking.times.push_back(t);
    l.taking.frames.insert(l.taking.frames.end(), l.pose.begin(), l.pose.begin() + skeleton_joints);
    const auto placement = world(l.pose, placement_joint);
    if (l.board_ok) l.taking.board.push_back(relative(placement, compose(board_parent(l.board), joint_of(l.board[board_mount]))));
    else l.taking_board = false;
    const bool up = air && *air;
    if (up && !l.was_air && l.taking.takeoff < 0) l.taking.takeoff = t;
    if (!up && l.was_air && l.taking.takeoff >= 0 && l.taking.landing < 0) l.taking.landing = t;
    l.was_air = up;
    if (at >= l.record_until || l.taking.times.size() >= 900) finish_recording(l);
}

// ---- the animation thread ------------------------------------------------------------------------
void on_animation(std::uintptr_t component) noexcept {
    auto& l = live();
    if (!component || component != l.component.load(std::memory_order_acquire)) return;
    const auto error = GetLastError();
    try {
        const auto snap = plan();
        const bool wants_record = snap->record_seconds > 0 && snap->record_serial != l.record_serial.load(std::memory_order_acquire);
        const bool busy = record_running.load(std::memory_order_acquire) || wants_record;
        const double now = now_seconds();
        const bool reaching = snap->reach && now < snap->reach_until;
        const bool joints_wanted = now < snap->joints_until && !snap->joints_read.empty();
        const bool posing = !snap->offsets.empty() && now < snap->offsets_until;
        if (!busy && !reaching && !joints_wanted && !posing && (!snap->allowed || (!snap->play && snap->replacements.empty()))) {
            std::lock_guard lock(pending().mutex);
            pending().bones.clear();
            SetLastError(error);
            return;
        }
        const auto base = l.base.load(std::memory_order_acquire);
        const auto holder = read<std::uintptr_t>(component + 0xa0);
        if (!holder || !*holder) throw std::runtime_error("the skater has no animation yet");
        const auto layout = multiplayer::read_native_pose_layout(peek, base, *holder, 512);
        if (!layout.buffer) throw std::runtime_error("the skater's pose is still loading");
        if (layout.count != skeleton_joints)
            throw std::runtime_error(std::format("the skater has {} joints, not the standard {}", layout.count, skeleton_joints));
        l.board_ok = false;
        if (const auto bh = l.board_holder.load(std::memory_order_acquire)) {
            const auto bl = multiplayer::read_native_pose_layout(peek, base, bh, 64);
            l.board_ok = bl.buffer && bl.count == board_bones && peek(bl.buffer, l.board.data(), sizeof(l.board)) &&
                         finite(compose(board_parent(l.board), joint_of(l.board[board_mount])));
        }
        l.bones.resize(layout.count);
        if (!peek(layout.buffer, l.bones.data(), l.bones.size() * sizeof(NativeBone))) throw std::runtime_error("the skater's pose is unreadable");
        l.pose.resize(layout.count);
        for (std::size_t i = 0; i < layout.count; ++i) l.pose[i] = joint_of(l.bones[i]);
        const double at = now_seconds();
        const auto air = in_the_air(base, component);
        // Recording: the pose as the game animated it, before anything here changes it.
        if (wants_record) {
            l.record_serial.store(snap->record_serial, std::memory_order_release);
            l.record_start = -1;
            l.record_until = at + std::clamp(snap->record_seconds, 0.2f, 10.0f);
            record_running.store(true, std::memory_order_release);
        }
        if (record_running.load(std::memory_order_acquire)) record_frame(l, at, air);

        const Clip* clip = nullptr;
        float t = -1, weight = 0;
        if (snap->allowed && snap->play && snap->play->clip && !snap->play->clip->empty()) {
            // A clip played in place from when it was asked for.
            const auto& p = *snap->play;
            clip = p.clip.get();
            const float elapsed = static_cast<float>(at - snap->started);
            const float blend = std::max(p.blend, 0.0f);
            const float run = snap->held ? *snap->held : snap->from + elapsed * std::max(p.speed, 0.05f);
            const float length = clip->duration();
            if (p.loop && length > 0) t = std::fmod(run, length);
            else t = std::min(run, length);
            weight = blend > 0 ? std::clamp(elapsed / blend, 0.0f, 1.0f) : 1.0f;
            if (!p.loop && !snap->held && run >= length) {
                const float after = (run - length) / std::max(p.speed, 0.05f);
                weight = std::min(weight, blend > 0 ? 1 - std::clamp(after / blend, 0.0f, 1.0f) : 0.0f);
                if (weight <= 0) finished_serial.store(snap->serial, std::memory_order_release);
            }
        } else if (snap->allowed && !snap->replacements.empty() && air) {
            // A game trick with a replacement: the clip plays on the body from the takeoff, blended in
            // and out, its air stretched to this one's (anim_studio.cpp's play in game).
            if (*air) {
                if (!l.game_air) {
                    l.game_air = true;
                    l.game_takeoff = at;
                    l.game_landing = -1;
                    l.game_trick = nullptr;
                    l.game_plan = snap;
                    l.predicted_air = 0;
                }
                l.game_ground = 0;
                if (l.predicted_air == 0 && at - l.game_takeoff >= 0.03) {
                    const double elapsed = at - l.game_takeoff;
                    const auto vy = board_up_speed(base, component);
                    l.predicted_air = vy && *vy > 0.3f
                                          ? static_cast<float>(std::clamp(2 * (*vy + 9.81 * elapsed) / 9.81 - elapsed, 0.15, 3.0)) : -1.0f;
                    l.game_trick = nullptr;
                }
                if (at - l.game_takeoff < 0.25 && l.game_plan) {
                    const auto name = trick_of(component);
                    const auto pop = pop_of(l.predicted_air);
                    const Replacement* found = nullptr;
                    for (const auto& r : l.game_plan->replacements)
                        if (r.trick == name && r.clip && (r.pop == pop || (r.pop.empty() && !found))) found = &r;
                    l.game_trick = found;
                }
            } else if (l.game_air && ++l.game_ground >= 3) {
                l.game_air = false;
                l.game_landing = at;
            }
            if (const auto* trick = l.game_trick) {
                const auto& c = *trick->clip;
                const float speed = std::max(trick->speed, 0.1f);
                if (l.game_air && c.takeoff >= 0) {
                    float rate = speed;
                    if (l.predicted_air > 0 && c.landing > c.takeoff) rate *= (c.landing - c.takeoff) / l.predicted_air;
                    t = c.takeoff + static_cast<float>(at - l.game_takeoff) * rate;
                    weight = std::clamp(static_cast<float>(at - l.game_takeoff) / 0.08f, 0.0f, 1.0f);
                    if (c.landing > c.takeoff) t = std::min(t, c.landing);
                } else if (l.game_landing > 0 && c.landing >= 0) {
                    const float after = static_cast<float>(at - l.game_landing) * speed;
                    const float span = std::max(0.05f, std::min(0.35f, c.duration() - c.landing));
                    t = std::min(c.landing + after, c.duration());
                    weight = 1 - std::clamp(after / span, 0.0f, 1.0f);
                    if (weight <= 0) {
                        l.game_trick = nullptr;
                        l.game_plan.reset();
                        l.game_landing = -1;
                        t = -1;
                    }
                }
                if (l.game_trick) clip = &c;
            }
        }

        std::size_t first = 0, last = 0; // [first, last) of l.pose written
        Joint board_target;
        float board_weight = 0;
        if (clip && t >= 0 && weight > 0) {
            const auto placement = world(l.pose, placement_joint);
            l.custom.resize(layout.count);
            std::copy(l.pose.begin(), l.pose.end(), l.custom.begin());
            clip->sample(t, std::span<Joint>(l.custom.data(), std::min<std::size_t>(l.custom.size(), clip->joints)));
            if (Joint rel; clip->sample_board(t, rel)) {
                board_target = compose(placement, rel);
                board_weight = weight;
            }
            const auto& body = body_joints();
            for (std::size_t i = 0; i < std::min<std::size_t>(layout.count, clip->joints); ++i) {
                if (!body[i]) continue;
                auto& j = l.pose[i];
                const auto& c = l.custom[i];
                j.rotation = slerp(j.rotation, c.rotation, weight);
                for (std::size_t k = 0; k < 3; ++k) j.position[k] += (c.position[k] - j.position[k]) * weight;
            }
            first = 2;
            last = layout.count;
        }
        // Joints turned and scaled, after the clip and before any reach: they join what is written.
        if (posing) {
            const float w = std::clamp(snap->offsets_weight, 0.0f, 1.0f);
            for (const auto& o : snap->offsets) {
                if (o.joint < 2 || o.joint >= layout.count) continue;
                auto& j = l.pose[o.joint];
                j.rotation = normalised(multiply(j.rotation, slerp(Quat{0, 0, 0, 1}, o.rotation, w)));
                const float s = 1.0f + (o.scale - 1.0f) * w;
                for (auto& k : j.scale) k *= s;
                for (std::size_t a = 0; a < 3; ++a) j.position[a] += o.offset[a] * w;
                if (last > first) {
                    first = std::min<std::size_t>(first, o.joint);
                    last = std::max<std::size_t>(last, o.joint + 1u);
                } else {
                    first = o.joint;
                    last = o.joint + 1u;
                }
            }
        }
        // An arm reaching, after the clip: its joints join what is written.
        if (reaching) {
            const auto& goal = *snap->reach;
            if (arm_reach::reach(std::span<Joint>(l.pose.data(), l.pose.size()), goal).valid) {
                const std::size_t from = arm_reach::first_written(goal.hand), to = arm_reach::last_written(goal.hand) + 1u;
                if (last > first) {
                    first = std::min(first, from);
                    last = std::max(last, to);
                } else {
                    first = from;
                    last = to;
                }
            }
        }
        if (joints_wanted) {
            const std::span<const Joint> pose(l.pose.data(), l.pose.size());
            thread_local std::vector<std::pair<std::uint16_t, Joint>> placed;
            placed.clear();
            for (const auto index : snap->joints_read)
                if (index < pose.size())
                    if (const auto w = anim_studio::world(pose, index); anim_studio::finite(w)) placed.emplace_back(index, w);
            std::lock_guard lock(joints_mutex);
            joints_now.swap(placed);
        }
        if (last > first) {
            for (std::size_t i = first; i < last; ++i)
                if (!finite(l.pose[i])) throw std::runtime_error("a clip made a broken pose; nothing was written");
            for (std::size_t i = first; i < last; ++i) {
                auto& b = l.bones[i];
                const auto& j = l.pose[i];
                std::memcpy(b.scale.data(), j.scale.data(), 12);
                b.rotation = j.rotation;
                std::memcpy(b.position.data(), j.position.data(), 12);
            }
            // Written when the pose goes to the renderer (on_render): the body physics rebuild this
            // buffer after the animation update.
            {
                auto& p = pending();
                std::lock_guard lock(p.mutex);
                p.buffer = layout.buffer;
                p.first = static_cast<std::uint32_t>(first);
                p.last = static_cast<std::uint32_t>(last);
                p.bones.assign(l.bones.begin() + static_cast<std::ptrdiff_t>(first), l.bones.begin() + static_cast<std::ptrdiff_t>(last));
                p.at = at;
            }
            auto& sp = sent_pose();
            std::lock_guard sent_lock(sp.mutex);
            sp.component = component;
            sp.first = static_cast<std::uint32_t>(first);
            sp.last = static_cast<std::uint32_t>(last);
            sp.joints.assign(l.pose.begin() + static_cast<std::ptrdiff_t>(first), l.pose.begin() + static_cast<std::ptrdiff_t>(last));
            sp.at = at;
        } else {
            auto& p = pending();
            std::lock_guard lock(p.mutex);
            p.bones.clear();
        }
        auto& pb = pending_board();
        std::lock_guard lock(pb.mutex);
        pb.weight = board_weight > 0 && finite(board_target) ? board_weight : 0;
        pb.mount = board_target;
        pb.at = at;
    } catch (const std::exception& e) {
        if (l.failures++ % 600 == 0) logging::log(Level::warning, Channel::skater, "Plugin animation: {}", e.what());
    } catch (...) {
    }
    SetLastError(error);
}

// What other players get of the local skater: the clip, as drawn here.
void on_send(std::uintptr_t component, std::vector<multiplayer::Transform>& skater) noexcept {
    try {
        auto& sp = sent_pose();
        std::lock_guard lock(sp.mutex);
        if (component != sp.component || now_seconds() - sp.at > 0.15 || sp.last > skater.size()) return;
        for (std::uint32_t i = sp.first; i < sp.last; ++i) {
            const auto& j = sp.joints[i - sp.first];
            skater[i].rotation = j.rotation;
            skater[i].position = j.position;
        }
    } catch (...) {
    }
}

// The local skater's pose handed to the renderer: the clip's pose goes in now, over whatever the
// body physics left there, each joint's own lanes only (each bone's 4th lane stays).
void on_render(std::uintptr_t animation_interface) noexcept {
    auto& l = live();
    const auto component = l.component.load(std::memory_order_acquire);
    if (!component) return;
    const auto error = GetLastError();
    try {
        const auto holder = read<std::uintptr_t>(component + 0xa0);
        if (!holder || !*holder || animation_interface != *holder + 0xc0) {
            SetLastError(error);
            return;
        }
        auto& p = pending();
        std::lock_guard lock(p.mutex);
        if (p.bones.empty() || now_seconds() - p.at > 0.1) {
            SetLastError(error);
            return;
        }
        const auto layout = multiplayer::read_native_pose_layout(peek, l.base.load(std::memory_order_acquire), *holder, 512);
        if (layout.buffer != p.buffer || layout.count != skeleton_joints || p.last > layout.count || p.first >= p.last) {
            SetLastError(error);
            return;
        }
        thread_local std::vector<NativeBone> current;
        current.resize(p.last - p.first);
        if (!peek(layout.buffer + p.first * sizeof(NativeBone), current.data(), current.size() * sizeof(NativeBone))) {
            SetLastError(error);
            return;
        }
        for (std::size_t i = 0; i < current.size(); ++i) {
            std::memcpy(current[i].scale.data(), p.bones[i].scale.data(), 12);
            current[i].rotation = p.bones[i].rotation;
            std::memcpy(current[i].position.data(), p.bones[i].position.data(), 12);
        }
        (void)poke(layout.buffer + p.first * sizeof(NativeBone), current.data(), current.size() * sizeof(NativeBone));
    } catch (...) {
    }
    SetLastError(error);
}

// The board's pose, just before it goes to the renderer: the whole rig moved so its mount lands where
// the clip has it (anim_studio.cpp's on_board_render).
void on_board_render(std::uintptr_t animation_interface, std::uintptr_t /*render_data*/) noexcept {
    auto& l = live();
    const auto error = GetLastError();
    try {
        const auto bh = l.board_holder.load(std::memory_order_acquire);
        if (!bh || animation_interface != bh + 0xc0) {
            SetLastError(error);
            return;
        }
        Joint target;
        float weight{};
        {
            auto& pb = pending_board();
            std::lock_guard lock(pb.mutex);
            if (pb.weight > 0 && now_seconds() - pb.at < 0.1) {
                target = pb.mount;
                weight = pb.weight;
            }
        }
        if (weight > 0) {
            const auto layout = multiplayer::read_native_pose_layout(peek, l.base.load(std::memory_order_acquire), bh, 64);
            std::array<NativeBone, board_bones> b{};
            if (layout.buffer && layout.count == board_bones && peek(layout.buffer, b.data(), sizeof(b))) {
                const auto now_mount = compose(board_parent(b), joint_of(b[board_mount]));
                Joint want = target;
                want.rotation = slerp(now_mount.rotation, target.rotation, weight);
                for (std::size_t i = 0; i < 3; ++i) want.position[i] = now_mount.position[i] + (target.position[i] - now_mount.position[i]) * weight;
                want.scale = now_mount.scale;
                const auto mount_local = joint_of(b[board_mount]);
                const auto root_world = compose(want, relative(mount_local, Joint{}));
                const auto root_local = relative(joint_of(b[0]), root_world);
                if (finite(root_local)) {
                    auto& r = b[1];
                    r.rotation = root_local.rotation;
                    std::memcpy(r.position.data(), root_local.position.data(), 12);
                    (void)poke(layout.buffer + sizeof(NativeBone), &r, sizeof(NativeBone));
                }
            }
        }
    } catch (...) {
    }
    SetLastError(error);
}

bool hooked{};
std::string failure;
std::uint64_t serial{};
}

void play(std::optional<Play> clip) {
    plan_draft.play = std::move(clip);
    plan_draft.started = now_seconds();
    plan_draft.from = plan_draft.play ? plan_draft.play->at : 0;
    plan_draft.held = plan_draft.play && plan_draft.play->paused ? std::optional(plan_draft.from) : std::nullopt;
    plan_draft.serial = ++serial;
    publish();
}
std::optional<float> play_time() {
    if (!plan_draft.play || !plan_draft.play->clip) return std::nullopt;
    if (plan_draft.held) return plan_draft.held;
    const auto& p = *plan_draft.play;
    const float run = plan_draft.from + static_cast<float>(now_seconds() - plan_draft.started) * std::max(p.speed, 0.05f);
    const float length = p.clip->duration();
    if (p.loop && length > 0) return std::fmod(run, length);
    return std::min(run, length);
}
void seek(float seconds) {
    if (!plan_draft.play || !plan_draft.play->clip) return;
    const float t = std::clamp(seconds, 0.0f, plan_draft.play->clip->duration());
    if (plan_draft.held) plan_draft.held = t;
    else {
        // Playing on from there, already blended in.
        plan_draft.from = t;
        plan_draft.started = now_seconds() - std::max(plan_draft.play->blend, 0.0f);
        if (plan_draft.play->speed > 0) plan_draft.from -= std::max(plan_draft.play->blend, 0.0f) * plan_draft.play->speed;
    }
    publish();
}
void pause(bool paused) {
    if (!plan_draft.play || !plan_draft.play->clip || paused == plan_draft.held.has_value()) return;
    if (paused) plan_draft.held = play_time();
    else {
        const float t = *plan_draft.held;
        plan_draft.held.reset();
        seek(t);
        return;
    }
    publish();
}
bool playing() noexcept {
    return plan_draft.play.has_value() && finished_serial.load(std::memory_order_acquire) != plan_draft.serial;
}
void pose(std::vector<PoseOffset> offsets, float weight) {
    plan_draft.offsets = std::move(offsets);
    plan_draft.offsets_weight = weight;
    plan_draft.offsets_until = plan_draft.offsets.empty() ? 0 : now_seconds() + 0.3;
    publish();
}
void reach(std::optional<arm_reach::Goal> goal) {
    plan_draft.reach = std::move(goal);
    plan_draft.reach_until = plan_draft.reach ? now_seconds() + 0.3 : 0;
    publish();
}
std::optional<Joint> joint(std::uint16_t index) {
    if (index >= 395) return std::nullopt;
    const double now = now_seconds();
    std::erase_if(joints_asked, [&](const auto& asked) { return now - asked.second > 2.0; });
    const auto asked = std::find_if(joints_asked.begin(), joints_asked.end(), [&](const auto& a) { return a.first == index; });
    if (asked != joints_asked.end()) asked->second = now;
    else if (joints_asked.size() < 32) joints_asked.emplace_back(index, now);
    else return std::nullopt;
    std::vector<std::uint16_t> read;
    for (const auto& a : joints_asked) read.push_back(a.first);
    std::sort(read.begin(), read.end());
    if (read != plan_draft.joints_read || plan_draft.joints_until < now + 1.0) {
        plan_draft.joints_read = std::move(read);
        plan_draft.joints_until = now + 2.0;
        publish();
    }
    std::lock_guard lock(joints_mutex);
    for (const auto& [at, w] : joints_now)
        if (at == index) return w;
    return std::nullopt;
}
std::optional<arm_reach::Placed> hand(arm_reach::Hand side) {
    const auto at = joint(arm_reach::chain(side).back());
    if (!at) return std::nullopt;
    return arm_reach::Placed{at->position, at->rotation, at->scale[0]};
}
void set_replacements(std::vector<Replacement> list) {
    plan_draft.replacements = std::move(list);
    publish();
}
bool record(float seconds) {
    if (record_running.load(std::memory_order_acquire) || !(seconds > 0)) return false;
    plan_draft.record_seconds = std::min(seconds, 10.0f);
    plan_draft.record_serial = ++serial;
    publish();
    return true;
}
bool recording() noexcept {
    return record_running.load(std::memory_order_acquire) || (plan_draft.record_seconds > 0 && live().record_serial.load(std::memory_order_acquire) != plan_draft.record_serial);
}
std::shared_ptr<const Clip> take_recording() {
    std::lock_guard lock(recorded_mutex);
    return std::exchange(recorded, {});
}
std::string current_trick() noexcept {
    const auto component = live().component.load(std::memory_order_acquire);
    return component ? trick_of(component) : std::string{};
}

void tick(std::uintptr_t base, std::uintptr_t component, bool allowed) {
    auto& l = live();
    if (component && base) {
        // The skater's board (its own entity, with a 16-bone rig): its animation holder.
        std::uintptr_t holder{};
        try {
            const auto collection = read<std::uintptr_t>(component + 0x18).value_or(0);
            const auto entity = collection ? read<std::uintptr_t>(collection).value_or(0) : 0;
            if (entity) holder = multiplayer::read_native_board(peek, base, entity).holder;
        } catch (...) {}
        l.board_holder.store(holder, std::memory_order_release);
    }
    if (component != l.component.load(std::memory_order_acquire)) {
        l.base.store(base, std::memory_order_release);
        l.component.store(component, std::memory_order_release);
    }
    if (allowed != plan_draft.allowed) {
        plan_draft.allowed = allowed;
        publish();
    }
    // A play that finished is over.
    if (plan_draft.play && finished_serial.load(std::memory_order_acquire) == plan_draft.serial) {
        plan_draft.play.reset();
        publish();
    }
    const double now = now_seconds();
    const bool wanted = plan_draft.play || !plan_draft.replacements.empty() || recording() ||
                        (plan_draft.reach && now < plan_draft.reach_until) || now < plan_draft.joints_until ||
                        (!plan_draft.offsets.empty() && now < plan_draft.offsets_until);
    if (wanted && !hooked && base) {
        std::string detail;
        if (multiplayer::install_entity_hooks(base, detail)) {
            multiplayer::set_pose_override_listener(&on_animation);
            multiplayer::set_pose_override_render_listener(&on_render);
            multiplayer::set_pose_override_board_listener(&on_board_render);
            multiplayer::set_local_pose_filter(&on_send);
            hooked = true;
            logging::write(Level::info, Channel::skater, "Plugin animation: listening to the skater's animation.");
        } else failure = "the animation hook is unavailable: " + detail;
    }
}

std::string status() {
    if (!hooked) return failure.empty() ? "not hooked (no clip asked for yet)" : failure;
    return std::format("hooked; {}playing, {} replacement(s){}", playing() ? "" : "not ", plan_draft.replacements.size(),
                       recording() ? ", recording" : "");
}
}
