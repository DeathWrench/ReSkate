#pragma once
#include "replay_edit.h"
#include "replay_motion.h"
#include "replay_program.h"
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

// What the editor's screen (the overlay, render thread) and its game side (replay_session.h, the
// game's threads) hand each other. No game code: both sides and the tests link it.
namespace dingosdk::replay_editor {
struct Player {
    std::uint64_t id{}; // Steam id; 0 the local player
    std::string name;
};
// Where a target is now (at the replay time shown), for keys the player sets from a camera.
struct TargetNow {
    Target target;
    TargetPlace place;
};

// An export's choices. Sizes are the encoder's; 0 keeps the game's own choice of size.
struct ExportChoice {
    int format{};          // 0 MP4 (H.264, AAC), 1 WebM (VP8, Opus)
    int fps{60};           // 24, 30 or 60
    int width{1920}, height{1080};
    int kbps{24000};
    bool whole_edit{true}; // the edit; otherwise the clip under the playhead only
    bool game_shape{true}; // as wide as the game's picture is for the height (export_size)
};
// The video's size for a choice and the game's picture (width / height): with game_shape the chosen
// height and the game's shape (the game scales its whole picture into the video, so a 16:9 video of a
// wider screen came out squashed), in whole 16-pixel blocks and at most 3840 wide by making it shorter;
// otherwise the chosen size, made even.
std::pair<int, int> export_size(const ExportChoice& choice, float game_aspect) noexcept;
struct ExportPreset {
    const char* name;
    ExportChoice choice;
};
inline constexpr std::array<ExportPreset, 6> export_presets{{
    {"YouTube 1080p60", {0, 60, 1920, 1080, 24000, true}},
    {"YouTube 1440p60", {0, 60, 2560, 1440, 40000, true}},
    {"4K 30", {0, 30, 3840, 2160, 60000, true}},
    {"Discord 720p", {0, 30, 1280, 720, 6000, true}},
    {"Small WebM 720p", {1, 30, 1280, 720, 4000, true}},
    {"Cinematic 24", {0, 24, 1920, 1080, 20000, true}},
}};

struct Status {
    bool available{};    // this build's functions matched and the hooks are in
    bool replay_open{};  // the game's replay editor has a session open
    bool active{};       // ReSkate's editor has taken it over
    double window_start{}, window_end{}; // the footage the game keeps (replay seconds)
    double time{}, rate{};
    // While the game records (no replay open): the newest recorded time, on the replay's clock (NaN
    // otherwise). The filmstrip takes pictures of the game as it records, by it.
    double recording_at{std::numeric_limits<double>::quiet_NaN()};
    std::uint64_t run{}; // this game run: footage from another run is gone
    std::string level;
    bool exporting{};
    double export_progress{};      // 0..1
    std::string export_message;    // the last export: where it went, or why it failed
    bool export_failed{};
    std::uint32_t export_serial{}; // one more each time an export ends
    int camera_asks{};   // how often the game asked for the replay camera in the last second
    int camera_shown{};  // how often ReSkate's camera was put on screen
    bool view_taken{};   // ReSkate's camera has the view
    double locked{};     // seconds of footage kept for the edit
    std::string notice;  // the last thing that went wrong
    std::vector<Player> players;
    std::vector<TargetNow> targets;
    int edit_clip{};     // edit playback: the clip playing
    bool holding{};      // and it is in its hold
};

enum class PlayMode : std::uint8_t { footage, edit };
struct Playback {
    bool playing{};
    double shuttle{1};       // the player's play speed (J/K/L, triggers): any sign
    PlayMode mode{PlayMode::footage};
    bool loop{};
    std::uint64_t solo{};    // footage mode: the clip whose camera and look show (0 none)
};

struct Request {
    // leave: out of the replay altogether (the game's own exit); hand_back: back to the game's replay editor.
    enum class Kind : std::uint8_t { take_over, hand_back, leave, seek, export_edit, open_videos, add_marker } kind{};
    double time{};
    int clip{-1}; // seek: the clip it lands in, in edit playback (-1: the first that holds the time)
    ExportChoice choice;
    std::string text;
};

// The player's settings for the editor, kept between runs.
struct Settings {
    bool open_with_replay{true}; // ReSkate's editor opens whenever the game's replay editor does
    ExportChoice export_choice;
    int preset{-1};              // the export preset last chosen (-1 custom)
};
std::string to_text(const Settings& settings);
Settings settings_from_text(std::string_view text);

class Bridge {
public:
    // ---- game side ----
    void publish(Status status);
    void set_moments(std::shared_ptr<const std::vector<Moment>> moments);
    std::vector<Request> take_requests();
    // ---- screen side ----
    void ask(Request request);
    void set_program(std::shared_ptr<const Program> program);
    void set_playback(const Playback& playback);
    // The camera the player flies (camera mode), shown in place of the edit's while set, and how fast
    // it moves (metres a second). The screen moves it as it draws, by the time between its frames;
    // the replay moves by the game's own frame time, which differs from that by a tenth either way,
    // so a camera moving on the screen's clock jittered against the skater. The game moves the flown
    // camera on its own clock instead (advance_live_camera), easing toward the screen's.
    // Turning works the same way: `turn` holds the screen's angles, the degrees a raw mouse count turns
    // while `turning`, the stick's turn rates, and turns made on the screen alone (the cursor, when no
    // raw mouse comes) for the game to take.
    struct LiveTurn {
        float yaw{}, pitch{}, roll{};
        float per_count{};
        bool turning{};
        float yaw_rate{}, pitch_rate{}; // degrees a second
        float extra_yaw{}, extra_pitch{};
    };
    void set_live_camera(std::optional<CameraPose> pose, Vec3 velocity = {}, const LiveTurn& turn = {});
    // Game side, once a game frame: the flown camera on by its speed over the game's frame time, and
    // turned by the raw mouse counts since the last game frame.
    void advance_live_camera(double seconds, long mouse_x = 0, long mouse_y = 0);
    // ---- either ----
    Status status() const;
    // What a picture of the game as it records is tagged with (status().recording_at, level and run),
    // without copying the whole status: asked on every presented frame.
    struct Recording {
        double at{std::numeric_limits<double>::quiet_NaN()};
        std::string level;
        std::uint64_t run{};
        bool available{};
    };
    Recording recording() const;
    std::shared_ptr<const Program> program() const;
    std::shared_ptr<const std::vector<Moment>> moments() const;
    Playback playback() const;
    std::optional<CameraPose> live_camera() const;
    bool active() const noexcept { return active_.load(std::memory_order_relaxed); }
    Settings settings() const;
    void set_settings(const Settings& settings);

private:
    mutable std::mutex mutex_;
    Status status_;
    std::shared_ptr<const Program> program_;
    std::shared_ptr<const std::vector<Moment>> moments_;
    Playback playback_;
    std::optional<CameraPose> live_;
    Vec3 live_velocity_{};
    std::chrono::steady_clock::time_point live_at_{};
    LiveTurn live_turn_{};
    float pending_yaw_{}, pending_pitch_{};
    Vec3 game_position_{}; // where the game has the flown camera (advance_live_camera), and its angles
    float game_yaw_{}, game_pitch_{};
    bool game_placed_{};
    std::vector<Request> requests_;
    Settings settings_;
    std::atomic<bool> active_{false};
};
Bridge& bridge();

// %LOCALAPPDATA%\ReSkate (made when missing): Replays\ holds the projects, ReplayEditor.settings
// the settings.
std::filesystem::path editor_folder();
Settings load_settings();
void save_settings(const Settings& settings);
} // namespace dingosdk::replay_editor
