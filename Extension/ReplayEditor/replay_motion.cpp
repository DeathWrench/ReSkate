#include "replay_motion.h"
#include <algorithm>
#include <cmath>
#include <numbers>

namespace dingosdk::replay_editor {
namespace {
constexpr double radians = std::numbers::pi / 180.0;
Vec3 cross(const Vec3& a, const Vec3& b) noexcept {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
float dot(const Vec3& a, const Vec3& b) noexcept { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
Vec3 normalized(Vec3 v, const Vec3& fallback) noexcept {
    const float length = std::sqrt(dot(v, v));
    if (!(length > 1e-6f) || !std::isfinite(length)) return fallback;
    for (auto& c : v) c /= length;
    return v;
}
}

bool spline_velocities(std::span<const double> times, std::span<const double> values, std::span<double> velocities,
                       std::vector<double>& work) {
    const std::size_t n = times.size();
    if (n == 0 || values.size() != n || velocities.size() != n) return false;
    for (std::size_t i = 1; i < n; ++i)
        if (!(times[i] > times[i - 1])) return false;
    if (n == 1) {
        velocities[0] = 0;
        return true;
    }
    // The natural cubic spline's slopes m solve, at every key i (h the gaps, d the chords' slopes):
    //   inner:  h[i] m[i-1] + 2 (h[i-1] + h[i]) m[i] + h[i-1] m[i+1] = 3 (h[i] d[i-1] + h[i-1] d[i])
    //   ends:   2 m[0] + m[1] = 3 d[0];  m[n-2] + 2 m[n-1] = 3 d[n-2]
    // a tridiagonal system, solved by the Thomas algorithm.
    work.assign(3 * n, 0.0);
    double* c = work.data();       // super-diagonal after elimination
    double* r = work.data() + n;   // right-hand side after elimination
    const auto gap = [&](std::size_t i) { return times[i + 1] - times[i]; };
    const auto chord = [&](std::size_t i) { return (values[i + 1] - values[i]) / gap(i); };
    for (std::size_t i = 0; i < n; ++i) {
        double a = 0, b = 0, up = 0, rhs = 0;
        if (i == 0) {
            b = 2, up = 1, rhs = 3 * chord(0);
        } else if (i == n - 1) {
            a = 1, b = 2, rhs = 3 * chord(n - 2);
        } else {
            a = gap(i), b = 2 * (gap(i - 1) + gap(i)), up = gap(i - 1);
            rhs = 3 * (gap(i) * chord(i - 1) + gap(i - 1) * chord(i));
        }
        if (i > 0) {
            const double m = b - a * c[i - 1];
            if (!(std::abs(m) > 1e-12)) return false;
            c[i] = up / m;
            r[i] = (rhs - a * r[i - 1]) / m;
        } else {
            c[0] = up / b;
            r[0] = rhs / b;
        }
    }
    velocities[n - 1] = r[n - 1];
    for (std::size_t i = n - 1; i-- > 0;) velocities[i] = r[i] - c[i] * velocities[i + 1];
    for (const auto v : velocities)
        if (!std::isfinite(v)) return false;
    return true;
}

double eased(Ease ease, double u) noexcept {
    u = std::clamp(u, 0.0, 1.0);
    switch (ease) {
    case Ease::linear: return u;
    case Ease::ease_in: return u * u;
    case Ease::ease_out: return 1 - (1 - u) * (1 - u);
    case Ease::ease_in_out: return u * u * (3 - 2 * u);
    case Ease::hold: return u >= 1 ? 1 : 0;
    case Ease::smooth: return u;
    }
    return u;
}

double between_keys(std::span<const double> times, std::span<const double> values, std::span<const Ease> eases,
                    std::span<const double> velocities, double t) noexcept {
    const std::size_t n = times.size();
    if (n == 0 || values.size() != n) return 0;
    if (t <= times[0] || n == 1) return values[0];
    if (t >= times[n - 1]) return values[n - 1];
    const auto it = std::upper_bound(times.begin(), times.end(), t);
    const std::size_t i = static_cast<std::size_t>(it - times.begin()) - 1;
    const double h = times[i + 1] - times[i];
    const double u = h > 0 ? (t - times[i]) / h : 1;
    const Ease ease = i < eases.size() ? eases[i] : Ease::smooth;
    if (ease != Ease::smooth || velocities.size() != n) return values[i] + (values[i + 1] - values[i]) * eased(ease, u);
    // Cubic Hermite with the spline's slopes.
    const double u2 = u * u, u3 = u2 * u;
    return (2 * u3 - 3 * u2 + 1) * values[i] + (u3 - 2 * u2 + u) * h * velocities[i] + (-2 * u3 + 3 * u2) * values[i + 1] +
           (u3 - u2) * h * velocities[i + 1];
}

double unwrap_degrees(double degrees, double previous) noexcept {
    if (!std::isfinite(degrees) || !std::isfinite(previous)) return degrees;
    while (degrees - previous > 180) degrees -= 360;
    while (degrees - previous < -180) degrees += 360;
    return degrees;
}

CameraPose camera_from(const Vec3& position, float yaw, float pitch, float roll, float fov) noexcept {
    const double y = yaw * radians, p = std::clamp(static_cast<double>(pitch), -89.5, 89.5) * radians, r = roll * radians;
    const Vec3 forward{static_cast<float>(std::sin(y) * std::cos(p)), static_cast<float>(std::sin(p)),
                       static_cast<float>(std::cos(y) * std::cos(p))};
    CameraPose pose;
    pose.position = position;
    pose.back = {-forward[0], -forward[1], -forward[2]};
    const Vec3 right0 = normalized(cross({0, 1, 0}, pose.back), {-1, 0, 0});
    const Vec3 up0 = cross(pose.back, right0);
    const float cr = static_cast<float>(std::cos(r)), sr = static_cast<float>(std::sin(r));
    pose.right = normalized({right0[0] * cr + up0[0] * sr, right0[1] * cr + up0[1] * sr, right0[2] * cr + up0[2] * sr}, right0);
    pose.up = cross(pose.back, pose.right);
    pose.fov = fov;
    return pose;
}

std::array<float, 3> camera_angles(const Vec3& right, const Vec3& up, const Vec3& back) noexcept {
    (void)up;
    const Vec3 forward{-back[0], -back[1], -back[2]};
    const float yaw = static_cast<float>(std::atan2(forward[0], forward[2]) / radians);
    const float pitch = static_cast<float>(std::asin(std::clamp(forward[1], -1.0f, 1.0f)) / radians);
    const Vec3 b = normalized(back, {0, 0, 1});
    const Vec3 right0 = normalized(cross({0, 1, 0}, b), {-1, 0, 0});
    const Vec3 up0 = cross(b, right0);
    const float roll = static_cast<float>(std::atan2(dot(right, up0), dot(right, right0)) / radians);
    return {yaw, pitch, roll};
}

std::array<float, 2> aim(const Vec3& from, const Vec3& to) noexcept {
    const double dx = to[0] - from[0], dy = to[1] - from[1], dz = to[2] - from[2];
    const double flat = std::sqrt(dx * dx + dz * dz);
    if (flat < 1e-5 && std::abs(dy) < 1e-5) return {0, 0};
    return {static_cast<float>(std::atan2(dx, dz) / radians), static_cast<float>(std::atan2(dy, flat) / radians)};
}

std::array<float, 16> camera_matrix(const CameraPose& pose) noexcept {
    return {pose.right[0], pose.right[1], pose.right[2], 0, pose.up[0], pose.up[1], pose.up[2], 0,
            pose.back[0], pose.back[1], pose.back[2], 0, pose.position[0], pose.position[1], pose.position[2], 1};
}

CameraPose camera_from_matrix(const std::array<float, 16>& m) noexcept {
    CameraPose pose;
    pose.right = {m[0], m[1], m[2]};
    pose.up = {m[4], m[5], m[6]};
    pose.back = {m[8], m[9], m[10]};
    pose.position = {m[12], m[13], m[14]};
    return pose;
}
} // namespace dingosdk::replay_editor
