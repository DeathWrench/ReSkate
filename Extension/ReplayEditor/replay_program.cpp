#include "replay_program.h"
#include <algorithm>
#include <cmath>
#include <numbers>

namespace dingosdk::replay_editor {
namespace {
constexpr double radians = std::numbers::pi / 180.0;
// Each clip's edit-time table has at most this many steps, and steps no finer than this.
constexpr std::size_t most_steps = 20000;
constexpr double finest_step = 1.0 / 240.0;

Vec3 add(const Vec3& a, const Vec3& b) noexcept { return {a[0] + b[0], a[1] + b[1], a[2] + b[2]}; }
Vec3 scaled(const Vec3& a, float s) noexcept { return {a[0] * s, a[1] * s, a[2] * s}; }
float distance(const Vec3& a, const Vec3& b) noexcept {
    const float x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2];
    return std::sqrt(x * x + y * y + z * z);
}
Vec3 level_unit(Vec3 v) noexcept {
    v[1] = 0;
    const float length = std::sqrt(v[0] * v[0] + v[2] * v[2]);
    if (!(length > 1e-5f)) return {0, 0, 1};
    return {v[0] / length, 0, v[2] / length};
}
// Interpolates one channel of a run of keys (times rising) at t.
struct Channel {
    std::vector<double> values, velocities, work;
    double at(const std::vector<double>& times, const std::vector<Ease>& eases, double t) {
        velocities.assign(values.size(), 0.0);
        if (!spline_velocities(times, values, velocities, work)) velocities.clear();
        return between_keys(times, values, eases, velocities, t);
    }
};
}

std::array<float, 3> handheld(double t, float amount, float rate) noexcept {
    if (!(amount > 0)) return {0, 0, 0};
    const double w = 2 * std::numbers::pi * rate * t;
    // Sums of sines at frequencies that share no small ratio: a drift that does not visibly repeat.
    const auto wave = [&](double a, double b, double c, double p) {
        return 0.55 * std::sin(w * a + p) + 0.3 * std::sin(w * b + p * 1.7) + 0.15 * std::sin(w * c + p * 2.3);
    };
    return {static_cast<float>(amount * wave(1.0, 2.37, 5.13, 0.4)), static_cast<float>(amount * 0.7 * wave(0.83, 2.91, 4.47, 2.1)),
            static_cast<float>(amount * 0.35 * wave(0.61, 1.93, 3.71, 4.2))};
}

std::shared_ptr<const Program> Program::build(const Project& project) {
    auto program = std::make_shared<Program>();
    program->project_ = project;
    normalize(program->project_);
    double start = 0;
    std::vector<double> work;
    for (std::size_t i = 0; i < program->project_.clips.size(); ++i) {
        const auto& clip = program->project_.clips[i];
        program->clip_starts_.push_back(start);
        ClipTable table;
        for (const auto& k : clip.speed) {
            table.speed_times.push_back(k.at);
            table.speed_values.push_back(k.speed);
            table.speed_eases.push_back(k.ease);
        }
        table.speed_velocities.assign(table.speed_times.size(), 0.0);
        if (!spline_velocities(table.speed_times, table.speed_values, table.speed_velocities, work)) table.speed_velocities.clear();
        program->tables_.push_back(std::move(table));
        auto& t = program->tables_.back();
        const double length = clip.length();
        t.step = std::max(finest_step, length / static_cast<double>(most_steps));
        const std::size_t steps = static_cast<std::size_t>(std::ceil(length / t.step));
        t.edit.reserve(steps + 1);
        t.edit.push_back(0);
        double edit = 0;
        for (std::size_t s = 0; s < steps; ++s) {
            const double from = clip.in + static_cast<double>(s) * t.step;
            const double to = std::min(clip.out, from + t.step);
            edit += (to - from) / program->speed(i, (from + to) * 0.5);
            t.edit.push_back(edit);
        }
        start += edit + clip.hold;
    }
    program->clip_starts_.push_back(start);
    return program;
}

double Program::clip_start(std::size_t i) const noexcept { return i < clip_starts_.size() ? clip_starts_[i] : duration(); }
double Program::clip_length(std::size_t i) const noexcept {
    return i + 1 < clip_starts_.size() ? clip_starts_[i + 1] - clip_starts_[i] : 0;
}

std::optional<Program::Place> Program::at_edit(double edit) const noexcept {
    if (project_.clips.empty()) return std::nullopt;
    if (!std::isfinite(edit)) edit = 0;
    edit = std::clamp(edit, 0.0, duration());
    const auto it = std::upper_bound(clip_starts_.begin(), clip_starts_.end() - 1, edit);
    std::size_t i = it == clip_starts_.begin() ? 0 : static_cast<std::size_t>(it - clip_starts_.begin()) - 1;
    i = std::min(i, project_.clips.size() - 1);
    const auto& clip = project_.clips[i];
    const auto& table = tables_[i];
    const double local = edit - clip_starts_[i];
    if (local >= table.edit.back()) return Place{i, clip.out, clip.hold > 0 && local > table.edit.back() + 1e-9};
    const auto at = std::upper_bound(table.edit.begin(), table.edit.end(), local);
    const std::size_t s = std::max<std::size_t>(1, static_cast<std::size_t>(at - table.edit.begin())) - 1;
    const double span = table.edit[s + 1] - table.edit[s];
    const double u = span > 0 ? (local - table.edit[s]) / span : 0;
    const double replay = std::min(clip.out, clip.in + (static_cast<double>(s) + u) * table.step);
    return Place{i, replay, false};
}

double Program::edit_time(std::size_t i, double replay) const noexcept {
    if (i >= project_.clips.size()) return duration();
    const auto& clip = project_.clips[i];
    const auto& table = tables_[i];
    const double local = std::clamp(replay, clip.in, clip.out) - clip.in;
    const double f = local / table.step;
    const std::size_t s = std::min(static_cast<std::size_t>(f), table.edit.size() - 1);
    if (s + 1 >= table.edit.size()) return clip_starts_[i] + table.edit.back();
    const double u = f - static_cast<double>(s);
    return clip_starts_[i] + table.edit[s] + (table.edit[s + 1] - table.edit[s]) * u;
}

std::optional<std::size_t> Program::clip_at_replay(double replay, std::optional<std::size_t> prefer) const noexcept {
    const auto holds = [&](std::size_t i) {
        const auto& c = project_.clips[i];
        return replay >= c.in - 1e-6 && replay <= c.out + 1e-6;
    };
    if (prefer && *prefer < project_.clips.size() && holds(*prefer)) return prefer;
    for (std::size_t i = 0; i < project_.clips.size(); ++i)
        if (holds(i)) return i;
    return std::nullopt;
}

float Program::speed(std::size_t i, double replay) const noexcept {
    if (i >= tables_.size()) return 1;
    const auto& t = tables_[i];
    if (t.speed_times.empty()) return 1;
    const double v = between_keys(t.speed_times, t.speed_values, t.speed_eases, t.speed_velocities, replay);
    return std::clamp(static_cast<float>(v), slowest, fastest);
}

std::optional<CameraPose> Program::camera(std::size_t i, double t, const TargetLookup& targets) const {
    if (i >= project_.clips.size()) return std::nullopt;
    const auto& clip = project_.clips[i];
    if (clip.camera.empty()) return std::nullopt;
    // Every key's camera as it would be at t (a key on a moving target moves with it), then the
    // keys' values interpolated by time as any other channel.
    std::vector<double> times;
    std::vector<Ease> eases;
    std::array<Channel, 9> channels; // x y z yaw pitch roll fov focus blur
    for (const auto& key : clip.camera) {
        std::optional<TargetPlace> target;
        if (key.rig != Rig::free && targets) target = targets(key.target, t);
        Vec3 position = key.position;
        float yaw = key.yaw, pitch = key.pitch;
        if (key.rig == Rig::follow || key.rig == Rig::orbit) {
            if (!target) continue; // nowhere to be without the target
            if (key.rig == Rig::follow) {
                const Vec3 ahead = level_unit(target->heading);
                const Vec3 right{-ahead[2], 0, ahead[0]}; // the camera convention's right of a back of -ahead
                position = add(target->position, add(scaled(right, key.position[0]),
                                                     add(Vec3{0, key.position[1], 0}, scaled(ahead, -key.position[2]))));
            } else {
                const double a = (key.position[2] + key.orbit_speed * (t - key.at)) * radians;
                position = add(target->position, Vec3{static_cast<float>(std::sin(a) * key.position[0]), key.position[1],
                                                      static_cast<float>(std::cos(a) * key.position[0])});
            }
        }
        if (target) {
            const auto [ay, ap] = aim(position, target->position);
            yaw = ay + key.yaw;
            pitch = std::clamp(ap + key.pitch, -89.5f, 89.5f);
        }
        float focus = key.focus;
        if (focus < 0) focus = target ? std::max(0.3f, distance(position, target->position)) : 0;
        const double previous_yaw = channels[3].values.empty() ? yaw : channels[3].values.back();
        const double previous_roll = channels[5].values.empty() ? key.roll : channels[5].values.back();
        const std::array<double, 9> v{position[0], position[1], position[2], unwrap_degrees(yaw, previous_yaw), pitch,
                                      unwrap_degrees(key.roll, previous_roll), key.fov, focus, key.blur};
        if (!times.empty() && !(key.at > times.back())) continue;
        times.push_back(key.at);
        eases.push_back(key.ease);
        for (std::size_t c = 0; c < v.size(); ++c) channels[c].values.push_back(v[c]);
    }
    if (times.empty()) return std::nullopt;
    std::array<double, 9> now{};
    for (std::size_t c = 0; c < now.size(); ++c) now[c] = channels[c].at(times, eases, t);
    const auto shake = handheld(t, clip.shake, clip.shake_rate);
    auto pose = camera_from({static_cast<float>(now[0]), static_cast<float>(now[1]), static_cast<float>(now[2])},
                            static_cast<float>(now[3]) + shake[0], static_cast<float>(now[4]) + shake[1],
                            static_cast<float>(now[5]) + shake[2], std::clamp(static_cast<float>(now[6]), 5.0f, 140.0f));
    pose.focus = std::max(0.0f, static_cast<float>(now[7]));
    pose.blur = std::clamp(static_cast<float>(now[8]), 0.0f, 1.0f);
    return pose;
}

std::optional<Look> Program::look(std::size_t i, double t) const noexcept {
    if (i >= project_.clips.size()) return std::nullopt;
    const auto& keys = project_.clips[i].look;
    if (keys.empty()) return std::nullopt;
    if (keys.size() == 1) return keys[0].look;
    std::vector<double> times;
    std::vector<Ease> eases;
    std::array<Channel, 8> channels;
    for (const auto& k : keys) {
        times.push_back(k.at);
        eases.push_back(k.ease);
        const auto& l = k.look;
        const std::array<double, 8> v{l.exposure, l.saturation, l.contrast, l.hue, l.vignette, l.barrel, l.grain, l.aberration};
        for (std::size_t c = 0; c < v.size(); ++c) channels[c].values.push_back(v[c]);
    }
    Look look;
    look.exposure = static_cast<float>(channels[0].at(times, eases, t));
    look.saturation = static_cast<float>(channels[1].at(times, eases, t));
    look.contrast = static_cast<float>(channels[2].at(times, eases, t));
    look.hue = static_cast<float>(channels[3].at(times, eases, t));
    look.vignette = static_cast<float>(channels[4].at(times, eases, t));
    look.barrel = static_cast<float>(channels[5].at(times, eases, t));
    look.grain = static_cast<float>(channels[6].at(times, eases, t));
    look.aberration = static_cast<float>(channels[7].at(times, eases, t));
    return clamped(look);
}

std::vector<Program::ShownTitle> Program::titles(std::size_t i, double t) const {
    std::vector<ShownTitle> shown;
    if (i >= project_.clips.size()) return shown;
    for (const auto& title : project_.clips[i].titles)
        if (t >= title.at && t < title.at + title.length) shown.push_back({&title, (t - title.at) / title.length});
    return shown;
}

std::vector<ExportPiece> Program::export_pieces(double frame) const {
    std::vector<ExportPiece> pieces;
    if (!(frame > 0)) frame = 1.0 / 60.0;
    std::size_t clip_now = 0;
    const auto put = [&](double start, double end, float speed) {
        if (!(end > start)) return;
        if (!pieces.empty() && pieces.back().clip == clip_now && std::abs(pieces.back().end - start) < 1e-9 &&
            std::abs(pieces.back().speed - speed) < 1e-4f)
            pieces.back().end = end;
        else pieces.push_back({start, end, speed, clip_now});
    };
    for (std::size_t i = 0; i < project_.clips.size(); ++i) {
        const auto& clip = project_.clips[i];
        clip_now = i;
        if (clip.speed.empty()) put(clip.in, clip.out, 1);
        else
            for (double s = clip.in; s < clip.out - 1e-9;) {
                const double e = std::min(clip.out, s + frame);
                put(s, e, speed(i, (s + e) * 0.5));
                s = e;
            }
        if (clip.hold > 0) {
            // A thousandth of a second of the last footage, slowed to last the hold.
            constexpr double hair = 0.001;
            const double from = std::max(clip.in, clip.out - hair);
            pieces.push_back({from, clip.out, static_cast<float>((clip.out - from) / clip.hold), i});
        }
    }
    return pieces;
}
} // namespace dingosdk::replay_editor
