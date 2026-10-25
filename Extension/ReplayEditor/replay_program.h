#pragma once
#include "replay_edit.h"
#include "replay_motion.h"
#include <functional>
#include <memory>
#include <optional>
#include <vector>

// An edit made playable: built once each time the project changes (the screen does it), then read
// by the game's side wherever the game asks, by replay time. Immutable, so any thread may read it.
//
// The edit's own clock: each clip plays its stretch of footage at its speed curve's pace, then holds
// its last frame for `hold` seconds; clips follow each other. edit_time and at_edit turn one clock
// into the other.
namespace dingosdk::replay_editor {
// Where a target is at a replay time (replay_motion.h); empty when it is not known then.
using TargetLookup = std::function<std::optional<TargetPlace>(const Target&, double replay_time)>;

// One stretch of an export's playlist: footage from start to end at a speed (the game's own form,
// replay_session.h interface_playlist).
struct ExportPiece {
    double start{}, end{};
    float speed{1};
    std::size_t clip{}; // the edit's clip it is from
};

class Program {
public:
    static std::shared_ptr<const Program> build(const Project& project);

    const Project& project() const noexcept { return project_; }
    bool empty() const noexcept { return project_.clips.empty(); }
    // The whole edit's length, in edit seconds.
    double duration() const noexcept { return clip_starts_.empty() ? 0 : clip_starts_.back(); }
    // Where clip i starts in the edit, and how long it plays (its hold included).
    double clip_start(std::size_t i) const noexcept;
    double clip_length(std::size_t i) const noexcept;

    struct Place {
        std::size_t clip{};
        double replay{};   // the footage's time
        bool holding{};    // in the clip's hold, after its last frame
    };
    // The clip and footage at an edit time (clamped to the edit); nothing for an empty edit.
    std::optional<Place> at_edit(double edit) const noexcept;
    // The edit time of footage time t inside clip i.
    double edit_time(std::size_t clip, double replay) const noexcept;
    // The clip whose footage holds replay time t: `prefer` when it does, else the first that does.
    std::optional<std::size_t> clip_at_replay(double replay, std::optional<std::size_t> prefer = std::nullopt) const noexcept;

    // The clip's speed at replay time t (1 without speed keys).
    float speed(std::size_t clip, double replay) const noexcept;
    // The clip's camera at replay time t, or nothing when it has no camera keys. `targets` tells
    // where targets are; a target that is not known leaves its key where it was set.
    std::optional<CameraPose> camera(std::size_t clip, double replay, const TargetLookup& targets) const;
    // The clip's look at replay time t, or nothing when it has no look keys.
    std::optional<Look> look(std::size_t clip, double replay) const noexcept;
    // The titles showing at replay time t in clip i, with how far into each (0..1).
    struct ShownTitle {
        const Title* title{};
        double progress{};
    };
    std::vector<ShownTitle> titles(std::size_t clip, double replay) const;

    // The whole edit as an export's playlist: speed changes cut into pieces no shorter than a
    // frame; a hold is a hair of footage played slowly enough to last it.
    std::vector<ExportPiece> export_pieces(double frame = 1.0 / 60.0) const;

private:
    struct ClipTable {
        double step{};
        std::vector<double> edit; // edit seconds from the clip's start at in + i * step
        // The speed curve, its spline solved once.
        std::vector<double> speed_times, speed_values, speed_velocities;
        std::vector<Ease> speed_eases;
    };
    Project project_;
    std::vector<double> clip_starts_; // edit time where each clip starts; one more for the end
    std::vector<ClipTable> tables_;
};

// The shake's angles (yaw, pitch, roll degrees) at time t: smooth, never repeating in a way the eye
// catches, `amount` degrees at most.
std::array<float, 3> handheld(double t, float amount, float rate) noexcept;
} // namespace dingosdk::replay_editor
