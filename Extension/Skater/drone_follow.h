#pragma once
// Follow mode: the FPV drone flies itself behind the skater while the player skates, and the
// view is its camera. It is not a chase camera placed each frame: an autopilot works the same
// sticks a pilot would (angle mode with height hold) through the real flight model
// (drone_flight.h), so it has to lean to speed up, overshoots a turn, swings round to keep the
// skater in shot and climbs over what is in the way, the way someone flying it would.
//
// It sees the skater a reaction time late and moves its sticks with a hand's smoothness and a
// little wander, which keeps the shot from looking machine-perfect. Plain C++, testable off the game.
#include "drone_flight.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace dingosdk::drone::follow {
using namespace dingosdk::drone::detail; // Vec3 and the vector helpers of the flight model

struct Tuning {
    float distance = 4.5f;     // m behind the skater
    float height = 1.4f;       // m above the skater
    float lead = 0.15f;        // s: aims where the skater will be this soon (about its reaction, so it sits `distance` back at any speed)
    float reaction = 0.12f;    // s: how late the pilot sees what the skater does
    float hands = 0.10f;       // s: how smoothly the sticks move
    float wander = 0.035f;     // stick unsteadiness, of full stick
    float max_lean_deg = 40.0f;
    float brake = 2.0f;        // m/s/s the pilot plans to slow down at when closing a gap
    float catch_up = 6.0f;     // m/s faster than the skater it closes a gap at, most
    float gap_gain = 0.8f;     // 1/s: how fast it closes a gap to its spot
    float speed_gain = 1.5f;   // 1/s: how hard it leans to match the speed it wants
    float uptilt_deg = 5.0f;   // camera tilt on the drone without a gimbal (the flight model's own)
    float tilt_ease = 0.4f;    // s: how smoothly the gimbal tilts to keep the skater in the middle
    float max_yaw_rate = 4.5f; // rad/s the pilot turns the drone at most
    float clearance = 1.4f;    // m the drone keeps above the ground
};

// The pilot's memory between ticks.
struct Pilot {
    bool valid = false;
    Vec3 last_target{};                 // the skater's position last tick
    Vec3 target_velocity{};             // smoothed
    Vec3 heading{0, 0, -1};             // which way the skater is going, level
    struct Seen { float age; Vec3 position, velocity; };
    std::array<Seen, 48> seen{};        // what the skater did lately, newest at `head`
    std::size_t head = 0, count = 0;
    float ride_y = 0;                   // the skater's height, without ollies and bumps
    float climb_extra = 0;              // extra height while something blocks the shot
    float blocked_for = 0;              // s the shot has been blocked
    float floor_lift = 0;               // extra height to clear the ground under the spot
    float pitch = 0, roll = 0, yaw = 0, climb = 0; // stick positions now
    float tilt = 0;                     // the camera gimbal's pitch, radians, + = up
    std::uint32_t noise = 0x9e3779b9u;
    Vec3 wander_now{}, wander_to{};     // slow unsteadiness, eased toward a new value now and then
    float wander_time = 0;
};

// Where the drone wants to be: behind the skater along its heading, up and a little ahead in time.
inline Vec3 spot(const Vec3& target, const Vec3& velocity, const Vec3& heading, const Tuning& t, float extra) {
    const Vec3 ahead = add(target, scale(velocity, t.lead));
    return add(add(ahead, scale(heading, -t.distance)), Vec3{0, t.height + extra, 0});
}

// A drone pose (camera matrix rows: right, up, back, position) hovering at `at`, facing `look`.
inline std::array<float, 16> pose_facing(const Vec3& at, const Vec3& look) {
    Vec3 forward = detail::sub(look, at);
    forward[1] = 0.0f;
    forward = detail::length(forward) > 1e-3f ? normalize(forward) : Vec3{0, 0, -1};
    const Vec3 right{-forward[2], 0.0f, forward[0]};
    std::array<float, 16> m{};
    set_row(m, 0, right);
    set_row(m, 1, Vec3{0, 1, 0});
    set_row(m, 2, scale(forward, -1.0f));
    m[12] = at[0]; m[13] = at[1]; m[14] = at[2]; m[15] = 1.0f;
    return m;
}

// The flight settings it flies with: the player's own drone, made easy to fly well (self-levelling
// and height hold), and bumps never cut the motors (nobody is there to re-arm it).
inline Settings flight_settings(Settings cfg, const Tuning& t) {
    cfg.angle_mode = true;
    cfg.alt_hold = true;
    cfg.max_angle_deg = std::clamp(t.max_lean_deg + 10.0f, 20.0f, 80.0f);
    cfg.camera_uptilt_deg = t.uptilt_deg;
    cfg.crash_speed = 0.0f;
    cfg.range = 0.0f;
    cfg.armed = true;
    return cfg;
}

// One tick: what the pilot does with the sticks. `drone` is the flight state, `position` the
// drone's, `target` the skater's position and `skater_forward` which way the skater faces.
inline Cmd fly(Pilot& p, const State& drone, const Vec3& position, const Vec3& target, const Vec3& skater_forward,
               float seconds, const Settings& cfg, const Tuning& t, const World* world = nullptr) {
    using detail::length;
    using detail::sub;
    const float dt = std::clamp(std::isfinite(seconds) ? seconds : 0.0f, 0.0f, 0.05f);
    Cmd cmd;
    cmd.hold = true;
    cmd.throttle = detail::hover_of(cfg);
    cmd.gimbal_tilt_rad = p.tilt;
    if (!(dt > 0.0f)) return cmd;

    // What the skater is doing: velocity from its moves (a jump of more than a few metres in one
    // tick is a respawn, not a move), and the way it is going.
    if (!p.valid || length(sub(target, p.last_target)) > 8.0f) {
        p.valid = true;
        p.target_velocity = {0, 0, 0};
        Vec3 f{skater_forward[0], 0.0f, skater_forward[2]};
        p.heading = length(f) > 0.1f ? normalize(f) : Vec3{0, 0, -1};
        p.count = 0;
        p.ride_y = target[1];
        p.tilt = std::clamp(std::atan2(target[1] + 0.9f - position[1], std::max(std::hypot(target[0] - position[0], target[2] - position[2]), 0.5f)), -1.2f, 0.35f);
        p.climb_extra = p.blocked_for = p.floor_lift = 0;
    } else {
        const Vec3 now = scale(sub(target, p.last_target), 1.0f / dt);
        const float k = 1.0f - std::exp(-dt / 0.15f);
        p.target_velocity = add(p.target_velocity, scale(sub(now, p.target_velocity), k));
        // A pilot follows the lie of the ground, not every ollie: height is eased toward slowly,
        // slower still going up (most rises are jumps that come straight back down).
        const float tau = target[1] > p.ride_y ? 1.4f : 0.6f;
        p.ride_y += (target[1] - p.ride_y) * (1.0f - std::exp(-dt / tau));
    }
    p.last_target = target;
    // Remembered, so the pilot can act on what it saw a reaction time ago.
    for (std::size_t i = 0; i < p.count; ++i) p.seen[i].age += dt;
    p.head = (p.head + 1) % p.seen.size();
    p.seen[p.head] = {0.0f, Vec3{target[0], p.ride_y, target[2]}, Vec3{p.target_velocity[0], 0.0f, p.target_velocity[2]}};
    p.count = std::min(p.count + 1, p.seen.size());
    Pilot::Seen seen = p.seen[p.head];
    for (std::size_t back = 0; back < p.count; ++back) {
        const auto& s = p.seen[(p.head + p.seen.size() - back) % p.seen.size()];
        seen = s;
        if (s.age >= t.reaction) break;
    }
    // Heading: the way the skater moves once it moves at all, else the way it faces; turned toward
    // gently, as a pilot swings round behind.
    {
        Vec3 want{seen.velocity[0], 0.0f, seen.velocity[2]};
        if (length(want) < 1.5f) want = Vec3{skater_forward[0], 0.0f, skater_forward[2]};
        if (length(want) > 0.1f) {
            const float k = 1.0f - std::exp(-dt * (length(seen.velocity) > 4.0f ? 2.2f : 0.8f));
            const Vec3 blended = add(p.heading, scale(sub(normalize(want), p.heading), k));
            if (length(blended) > 0.1f) p.heading = normalize(blended);
        }
    }

    // Where to be. Something between the drone's spot and the skater spoils the shot: climb until
    // it clears; the ground under the spot keeps it up.
    Vec3 goal = spot(seen.position, seen.velocity, p.heading, t, p.climb_extra);
    const Vec3 chest = add(seen.position, Vec3{0, 1.0f, 0});
    if (world && world->cast) {
        // Only a block that lasts (a wall, a ledge, not a rail flicking past) is worth climbing
        // for, and only a little.
        Vec3 hit{};
        const bool blocked = world->cast(goal, chest, hit) || world->cast(position, goal, hit);
        p.blocked_for = blocked ? p.blocked_for + dt : 0.0f;
        p.climb_extra = p.blocked_for > 0.3f ? std::min(p.climb_extra + 1.5f * dt, 3.0f) : std::max(p.climb_extra - 0.8f * dt, 0.0f);
        // Ground under the spot (a bank, a ledge) lifts it, quickly up and slowly back down.
        Vec3 ground{};
        float lift = 0.0f;
        if (world->cast(add(goal, Vec3{0, 2.0f, 0}), add(goal, Vec3{0, -(t.height + 6.0f), 0}), ground))
            lift = std::max(ground[1] + t.clearance - goal[1], 0.0f);
        p.floor_lift += (lift - p.floor_lift) * (1.0f - std::exp(-dt / (lift > p.floor_lift ? 0.2f : 1.0f)));
        goal[1] += p.floor_lift;
    }

    // Speed: match the skater, closing the gap; then lean to get it, no further than a pilot would.
    const Vec3 error = sub(goal, position);
    // Closing a gap: no faster than it can still slow down from gently by the time it gets there,
    // so it does not overshoot and have to stand on the brakes (nose up, the skater out of shot).
    Vec3 want_velocity = seen.velocity;
    {
        const Vec3 level{error[0], 0.0f, error[2]};
        if (const float d = length(level); d > 0.01f) {
            const float close = std::min({t.gap_gain * d, std::sqrt(2.0f * t.brake * d), t.catch_up});
            want_velocity = add(want_velocity, scale(level, close / d));
        }
    }
    // Too close (the skater stopped short, or came back at it): back off as a pilot pulls away,
    // rather than flying past and losing the shot.
    {
        // Measured from where the skater must be by now, not where it was seen a reaction ago.
        const Vec3 now_at = add(seen.position, scale(seen.velocity, t.reaction));
        Vec3 away{position[0] - now_at[0], 0.0f, position[2] - now_at[2]};
        const float gap = length(away), keep = t.distance * 0.7f;
        if (gap < keep) {
            away = gap > 0.05f ? scale(away, 1.0f / gap) : scale(p.heading, -1.0f);
            want_velocity = add(want_velocity, scale(away, (keep - gap) * 2.0f));
        }
    }
    Vec3 accel = scale(sub(want_velocity, drone.velocity), t.speed_gain);
    const float g = std::max(cfg.gravity, 1.0f);
    const float most = std::tan(std::clamp(t.max_lean_deg, 5.0f, 70.0f) * kDegToRad) * g;
    {
        Vec3 level{accel[0], 0.0f, accel[2]};
        if (const float a = length(level); a > most) { accel[0] *= most / a; accel[2] *= most / a; }
    }
    const Vec3 forward = [&] {
        Vec3 f = scale(row(drone.body, 2), -1.0f);
        f[1] = 0.0f;
        return length(f) > 0.05f ? normalize(f) : Vec3{0, 0, -1};
    }();
    const Vec3 right{-forward[2], 0.0f, forward[0]};
    const float lean = std::clamp(cfg.max_angle_deg, 1.0f, 89.0f) * kDegToRad;
    // Angle mode: pitch stick back (+) leans the nose up, so speeding up forward is stick forward.
    const float want_pitch = clamp1(-std::atan(dot(accel, forward) / g) / lean);
    const float want_roll = clamp1(std::atan(dot(accel, right) / g) / lean);
    // Height: eased toward, a few metres a second at most.
    const float want_climb = clamp1(std::clamp(1.5f * error[1], -2.5f, 3.0f) / std::max(cfg.climb_rate, 1.0f));
    // Yaw: keep the skater in the middle of the shot, at a pilot's turn rate.
    float want_yaw{};
    {
        Vec3 to{chest[0] - position[0], 0.0f, chest[2] - position[2]};
        if (length(to) > 0.5f) {
            to = normalize(to);
            const float across = dot(cross(forward, to), Vec3{0, 1, 0}); // + = the skater is to the left
            const float angle = std::atan2(across, dot(forward, to));
            // Far off the middle of the shot the pilot snaps round faster.
            const float gain = 3.0f + 3.0f * std::clamp(std::abs(angle) / 0.6f, 0.0f, 1.0f);
            want_yaw = std::clamp(angle * gain, -t.max_yaw_rate, t.max_yaw_rate);
        }
    }

    // Hands: the sticks follow what the pilot wants smoothly, with a little wander.
    p.wander_time -= dt;
    if (p.wander_time <= 0.0f) {
        p.wander_time = 0.4f + 0.5f * (detail::noise(p.noise) + 1.0f);
        p.wander_to = {detail::noise(p.noise), detail::noise(p.noise), detail::noise(p.noise)};
    }
    const float w = 1.0f - std::exp(-dt / 0.35f);
    p.wander_now = add(p.wander_now, scale(sub(p.wander_to, p.wander_now), w));
    const float h = 1.0f - std::exp(-dt / std::max(t.hands, 0.01f));
    p.pitch += (want_pitch + t.wander * p.wander_now[0] - p.pitch) * h;
    p.roll += (want_roll + t.wander * p.wander_now[1] - p.roll) * h;
    p.yaw += (want_yaw * (1.0f + 0.15f * p.wander_now[2]) - p.yaw) * h;
    p.climb += (want_climb - p.climb) * h;

    cmd.pitch = clamp1(p.pitch);
    cmd.roll = clamp1(p.roll);
    cmd.yaw_rad = p.yaw * dt; // + = turn left
    cmd.climb = clamp1(p.climb);
    // The camera sits on a tilt gimbal, eased toward the skater: leaning to speed up or slow down
    // no longer swings the shot to the ground or the sky.
    {
        const Vec3 to = sub(add(Vec3{target[0], p.ride_y, target[2]}, Vec3{0, 0.9f, 0}), position);
        const float level = std::hypot(to[0], to[2]);
        const float want_tilt = std::clamp(std::atan2(to[1], std::max(level, 0.5f)), -1.2f, 0.35f);
        p.tilt += (want_tilt - p.tilt) * (1.0f - std::exp(-dt / std::max(t.tilt_ease, 0.05f)));
        cmd.gimbal_tilt_rad = p.tilt;
    }
    return cmd;
}
} // namespace dingosdk::drone::follow
