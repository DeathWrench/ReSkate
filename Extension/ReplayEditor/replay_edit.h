#pragma once
#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// ReSkate's replay editor: the edit the player makes of a session's footage, apart from the game
// (replay_session.h is the game's side, Extension/UI/Overlay/replay_editor.cpp the screen).
//
// Times are the replay's own clock, the game's seconds, the same as the session's recorded window.
// A clip is a stretch of that clock, and what is keyed in a clip (speed, camera, look, titles) is
// keyed at those times too, so trimming a clip later leaves its keys where they were in the
// footage. The edit's own time (how long it plays) follows from the clips and their speeds
// (replay_program.h).
namespace dingosdk::replay_editor {
using Vec3 = std::array<float, 3>;

// How a value goes from one key to the next. Smooth passes through every key with no change of speed
// or acceleration at any (the natural cubic spline through the keys); hold keeps the key's value
// until the next.
enum class Ease : std::uint8_t { smooth, linear, ease_in, ease_out, ease_in_out, hold };
const char* ease_name(Ease ease) noexcept;
std::optional<Ease> ease_from(std::string_view name) noexcept;
inline constexpr std::array<Ease, 6> all_eases{Ease::smooth, Ease::linear, Ease::ease_in, Ease::ease_out,
                                               Ease::ease_in_out, Ease::hold};

// What a camera looks at or follows: the local skater (the game records where its body, head and
// board are) or another player in the session, by Steam id (ReSkate tracks them as they skate).
enum class Part : std::uint8_t { body, head, board };
const char* part_name(Part part) noexcept;
struct Target {
    std::uint64_t player{}; // 0: the local skater
    Part part{Part::body};
    bool operator==(const Target&) const = default;
};

// How a camera key places the camera.
//   free:    where it is and the way it looks, as set.
//   look_at: where it is as set; it turns to keep the target in frame.
//   follow:  it rides with the target: `position` is the offset in the target's frame (right, up,
//            back, from the way the target is moving), and it looks at the target.
//   orbit:   it circles the target: `position` is (radius, height, start angle in degrees) and it
//            goes round at `orbit_speed` degrees a second.
// In look_at, follow and orbit the key's yaw and pitch are added to the aim (framing), and roll
// turns the picture.
enum class Rig : std::uint8_t { free, look_at, follow, orbit };
const char* rig_name(Rig rig) noexcept;
inline constexpr std::array<Rig, 4> all_rigs{Rig::free, Rig::look_at, Rig::follow, Rig::orbit};

struct CameraKey {
    double at{};
    Rig rig{Rig::free};
    Ease ease{Ease::smooth};
    Vec3 position{};
    float yaw{}, pitch{}, roll{}; // degrees; yaw 0 looks along +z, pitch up positive
    float fov{65};                // vertical, degrees
    float orbit_speed{20};
    Target target;
    // Depth of field: the distance kept sharp in metres (0: none; -1: on the target), and how
    // strongly the rest blurs (0..1).
    float focus{}, blur{0.5f};
};

struct SpeedKey {
    double at{};
    float speed{1};
    Ease ease{Ease::smooth};
};

// The picture's look, as the game's own filters make it (replay_session.h applies it through the
// engine's settings). Neutral is no change.
struct Look {
    float exposure{};    // stops, -3..3
    float saturation{1}; // 0 (black and white)..2
    float contrast{1};   // brightness of the picture, 0.5..1.5 (the hue shift's value)
    float hue{};         // degrees, -180..180
    float vignette{};    // 0..1
    float barrel{};      // fisheye, 0..1
    float grain{};       // 0..1
    float aberration{};  // colour fringes, 0..1
    bool operator==(const Look&) const = default;
};
struct LookKey {
    double at{};
    Look look;
    Ease ease{Ease::smooth};
};

// Text over the picture: a title, a caption, a name. Shown from `at` for `length` seconds of the
// replay's clock, centred on (x, y) as fractions of the screen.
enum class TitleStyle : std::uint8_t { title, caption, label, lower_third };
const char* title_style_name(TitleStyle style) noexcept;
struct Title {
    double at{}, length{3};
    std::string text;
    float x{.5f}, y{.8f}, size{1};
    TitleStyle style{TitleStyle::title};
};

struct Clip {
    std::uint64_t id{};
    std::string name;
    double in{}, out{}; // replay seconds, in < out
    double hold{};      // seconds the last frame is held at the end (a freeze)
    std::vector<SpeedKey> speed;   // none: as recorded
    std::vector<CameraKey> camera; // none: the game's replay camera
    std::vector<LookKey> look;     // none: as the game draws it
    std::vector<Title> titles;
    float shake{}, shake_rate{1.2f}; // handheld: degrees of wobble, and how fast (per second)
    bool trick_labels{};             // name each trick landed inside it, with its points
    double length() const noexcept { return out - in; }
};

// Something that happened while recording, for the timeline (replay_moments in replay_session.h).
enum class MomentKind : std::uint8_t { trick, slam, joined, left, mark };
struct Moment {
    double at{};
    MomentKind kind{MomentKind::trick};
    std::uint64_t player{}; // 0: the local skater
    std::string text;       // the trick's name, the player's name
    float points{};
};

struct Project {
    std::string name{"Untitled"};
    std::string level;          // the map it was made on
    std::uint64_t footage{};    // the game run whose footage it uses (replay_session.h run_stamp)
    std::vector<Clip> clips;    // in the order they play
    std::uint64_t next_id{1};
};

// Keys closer than this are the same key: adding one there replaces it.
inline constexpr double same_key = 1.0 / 120.0;
// The shortest clip.
inline constexpr double shortest_clip = 0.1;
inline constexpr float slowest = 0.05f, fastest = 8.0f;

// ---- Editing (each keeps the project valid: clips in < out, keys sorted, values in range) --------
Clip* find_clip(Project& project, std::uint64_t id) noexcept;
const Clip* find_clip(const Project& project, std::uint64_t id) noexcept;
std::optional<std::size_t> clip_index(const Project& project, std::uint64_t id) noexcept;
// A new clip of [in, out] at `position` in the edit (the end when past it); its id.
std::uint64_t add_clip(Project& project, double in, double out, std::size_t position = static_cast<std::size_t>(-1),
                       std::string name = {});
// Splits a clip at replay time t (inside it, away from its ends): the second part is a new clip
// right after it, with the keys and titles after t. Its id, or nothing.
std::optional<std::uint64_t> split_clip(Project& project, std::uint64_t id, double t);
bool remove_clip(Project& project, std::uint64_t id);
bool move_clip(Project& project, std::uint64_t id, std::size_t position);
// New ends (kept apart by shortest_clip and clamped to `window`, when given).
bool trim_clip(Project& project, std::uint64_t id, double in, double out,
               std::optional<std::array<double, 2>> window = std::nullopt);
std::optional<std::uint64_t> duplicate_clip(Project& project, std::uint64_t id);

// Keys go in sorted; one within same_key of another replaces it. The removers take the key at (or
// nearest within same_key of) t.
void put_key(std::vector<CameraKey>& keys, CameraKey key);
void put_key(std::vector<SpeedKey>& keys, SpeedKey key);
void put_key(std::vector<LookKey>& keys, LookKey key);
template <class Key> bool remove_key(std::vector<Key>& keys, double t) {
    for (auto it = keys.begin(); it != keys.end(); ++it)
        if (it->at > t - same_key && it->at < t + same_key) {
            keys.erase(it);
            return true;
        }
    return false;
}
template <class Key> Key* key_at(std::vector<Key>& keys, double t) {
    for (auto& key : keys)
        if (key.at > t - same_key && key.at < t + same_key) return &key;
    return nullptr;
}
// Values kept in their ranges, keys sorted, clips valid. Used after loading a file too.
void normalize(Project& project);
void normalize(Clip& clip);
CameraKey clamped(CameraKey key);
Look clamped(Look look);

// Undo and redo: whole projects, the last 100.
class History {
public:
    // Call before a change, with the project as it is.
    void remember(const Project& before);
    bool undo(Project& project);
    bool redo(Project& project);
    bool can_undo() const noexcept { return !past_.empty(); }
    bool can_redo() const noexcept { return !future_.empty(); }
    void clear() noexcept;

private:
    std::vector<Project> past_, future_;
};
} // namespace dingosdk::replay_editor
