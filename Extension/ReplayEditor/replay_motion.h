#pragma once
#include "replay_edit.h"
#include <span>
#include <vector>

// The editor's curves and camera maths, apart from the game: values between keys, and the camera
// as the game's renderer takes it (rows right, up, back and position, y up; the convention ReSkate's
// other cameras use, Extension/Plugins/plugin_api_world.cpp camera_set).
namespace dingosdk::replay_editor {
// The velocity at every key of the natural cubic spline through (times[i], values[i]): the curve
// starts and ends without accelerating. False (and velocities untouched) when the sizes differ or
// the times do not rise.
bool spline_velocities(std::span<const double> times, std::span<const double> values, std::span<double> velocities,
                       std::vector<double>& work);
// A value between keys at t: before the first key the first, after the last the last; between two,
// as the earlier key's ease says. `velocities` from spline_velocities (only smooth segments read them).
double between_keys(std::span<const double> times, std::span<const double> values, std::span<const Ease> eases,
                    std::span<const double> velocities, double t) noexcept;
// u (0..1) eased: linear, in, out, in-out (smoothstep), hold (0 until the end).
double eased(Ease ease, double u) noexcept;
// Degrees made continuous with `previous`: within 180 of it.
double unwrap_degrees(double degrees, double previous) noexcept;

struct CameraPose {
    Vec3 position{};
    Vec3 right{1, 0, 0}, up{0, 1, 0}, back{0, 0, 1};
    float fov{65};          // vertical degrees
    float focus{}, blur{};  // focus: metres, 0 none
};
// The camera at a position looking by yaw, pitch and roll (degrees; yaw 0 looks along +z).
CameraPose camera_from(const Vec3& position, float yaw, float pitch, float roll, float fov) noexcept;
// Yaw, pitch and roll (degrees) of a camera's rows.
std::array<float, 3> camera_angles(const Vec3& right, const Vec3& up, const Vec3& back) noexcept;
// The yaw and pitch that look from `from` at `to`.
std::array<float, 2> aim(const Vec3& from, const Vec3& to) noexcept;
// The camera as 16 floats: rows right, up, back, position (w 0, 0, 0, 1).
std::array<float, 16> camera_matrix(const CameraPose& pose) noexcept;
// A camera from such a matrix (fov left at 65).
CameraPose camera_from_matrix(const std::array<float, 16>& m) noexcept;

// Where a target is at a replay time, and which way it is going (level, unit; +z when it stands).
struct TargetPlace {
    Vec3 position{};
    Vec3 heading{0, 0, 1};
};
} // namespace dingosdk::replay_editor
