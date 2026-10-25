#include "replay_bridge.h"
#include <Windows.h>
#include <shlobj.h>
#include <algorithm>
#include <charconv>
#include <format>
#include <fstream>
#include <sstream>

namespace dingosdk::replay_editor {
namespace {
std::string_view trimmed(std::string_view text) {
    while (!text.empty() && (text.front() == ' ' || text.front() == '\t' || text.front() == '\r')) text.remove_prefix(1);
    while (!text.empty() && (text.back() == ' ' || text.back() == '\t' || text.back() == '\r')) text.remove_suffix(1);
    return text;
}
bool whole(std::string_view text, int& out) {
    const auto r = std::from_chars(text.data(), text.data() + text.size(), out);
    return r.ec == std::errc{} && r.ptr == text.data() + text.size();
}
}

std::string to_text(const Settings& s) {
    const auto& e = s.export_choice;
    return std::format("open_with_replay={}\npreset={}\nformat={}\nfps={}\nwidth={}\nheight={}\nkbps={}\ngame_shape={}\n",
                       s.open_with_replay ? 1 : 0, s.preset, e.format, e.fps, e.width, e.height, e.kbps, e.game_shape ? 1 : 0);
}

Settings settings_from_text(std::string_view text) {
    Settings s;
    while (!text.empty()) {
        const auto end = text.find('\n');
        const auto line = text.substr(0, end);
        text = end == std::string_view::npos ? std::string_view{} : text.substr(end + 1);
        const auto eq = line.find('=');
        if (eq == std::string_view::npos) continue;
        const auto key = trimmed(line.substr(0, eq));
        int value{};
        if (!whole(trimmed(line.substr(eq + 1)), value)) continue;
        if (key == "open_with_replay") s.open_with_replay = value != 0;
        else if (key == "preset") s.preset = std::clamp(value, -1, static_cast<int>(export_presets.size()) - 1);
        else if (key == "format") s.export_choice.format = std::clamp(value, 0, 1);
        else if (key == "fps") s.export_choice.fps = value == 24 || value == 30 ? value : 60;
        else if (key == "width") s.export_choice.width = std::clamp(value, 320, 7680) & ~1;
        else if (key == "height") s.export_choice.height = std::clamp(value, 240, 4320) & ~1;
        else if (key == "kbps") s.export_choice.kbps = std::clamp(value, 1000, 200000);
        else if (key == "game_shape") s.export_choice.game_shape = value != 0;
    }
    return s;
}

void Bridge::publish(Status status) {
    active_.store(status.active, std::memory_order_relaxed);
    std::lock_guard lock(mutex_);
    status_ = std::move(status);
}
void Bridge::set_moments(std::shared_ptr<const std::vector<Moment>> moments) {
    std::lock_guard lock(mutex_);
    moments_ = std::move(moments);
}
std::vector<Request> Bridge::take_requests() {
    std::lock_guard lock(mutex_);
    return std::exchange(requests_, {});
}
void Bridge::ask(Request request) {
    std::lock_guard lock(mutex_);
    if (requests_.size() < 64) requests_.push_back(std::move(request));
}
void Bridge::set_program(std::shared_ptr<const Program> program) {
    std::lock_guard lock(mutex_);
    program_ = std::move(program);
}
void Bridge::set_playback(const Playback& playback) {
    std::lock_guard lock(mutex_);
    playback_ = playback;
}
void Bridge::set_live_camera(std::optional<CameraPose> pose, Vec3 velocity, const LiveTurn& turn) {
    std::lock_guard lock(mutex_);
    live_ = pose;
    live_velocity_ = velocity;
    live_at_ = std::chrono::steady_clock::now();
    live_turn_ = turn;
    pending_yaw_ += turn.extra_yaw;
    pending_pitch_ += turn.extra_pitch;
}
Status Bridge::status() const {
    std::lock_guard lock(mutex_);
    return status_;
}
Bridge::Recording Bridge::recording() const {
    std::lock_guard lock(mutex_);
    return {status_.recording_at, status_.level, status_.run, status_.available};
}
std::shared_ptr<const Program> Bridge::program() const {
    std::lock_guard lock(mutex_);
    return program_;
}
std::shared_ptr<const std::vector<Moment>> Bridge::moments() const {
    std::lock_guard lock(mutex_);
    return moments_;
}
Playback Bridge::playback() const {
    std::lock_guard lock(mutex_);
    return playback_;
}
std::optional<CameraPose> Bridge::live_camera() const {
    std::lock_guard lock(mutex_);
    if (!live_) return std::nullopt;
    auto pose = *live_;
    if (!game_placed_) return pose;
    auto placed = camera_from(game_position_, game_yaw_, game_pitch_, live_turn_.roll, pose.fov);
    placed.focus = pose.focus;
    placed.blur = pose.blur;
    return placed;
}
void Bridge::advance_live_camera(double seconds, long mouse_x, long mouse_y) {
    std::lock_guard lock(mutex_);
    if (!live_) {
        game_placed_ = false;
        pending_yaw_ = pending_pitch_ = 0;
        return;
    }
    const auto wrap = [](float degrees) {
        while (degrees > 180) degrees -= 360;
        while (degrees < -180) degrees += 360;
        return degrees;
    };
    // Where the screen has it now: carried on by its speed since it drew (at most a tenth of a second).
    const float since = std::clamp(std::chrono::duration<float>(std::chrono::steady_clock::now() - live_at_).count(), 0.0f, 0.1f);
    Vec3 screen = live_->position;
    for (int c = 0; c < 3; ++c) screen[c] += live_velocity_[c] * since;
    float apart = 0;
    for (int c = 0; c < 3; ++c) apart += (screen[c] - game_position_[c]) * (screen[c] - game_position_[c]);
    // A jump on the screen (camera mode entered, a key's camera taken): there at once.
    if (!game_placed_ || apart > 4.0f || std::abs(wrap(live_turn_.yaw - game_yaw_)) > 20 || std::abs(live_turn_.pitch - game_pitch_) > 20) {
        game_position_ = screen;
        game_yaw_ = live_turn_.yaw;
        game_pitch_ = live_turn_.pitch;
        pending_yaw_ = pending_pitch_ = 0;
        game_placed_ = true;
        return;
    }
    // Turned on the game's clock: the mouse moved since the last game frame, the stick's rates over
    // the game's frame time, what the screen turned alone; then slowly toward the screen's angles.
    const float turn_step = static_cast<float>(std::clamp(seconds, 0.0, 0.1));
    if (live_turn_.turning) {
        game_yaw_ -= static_cast<float>(mouse_x) * live_turn_.per_count;
        game_pitch_ -= static_cast<float>(mouse_y) * live_turn_.per_count;
    }
    game_yaw_ += live_turn_.yaw_rate * turn_step + pending_yaw_;
    game_pitch_ += live_turn_.pitch_rate * turn_step + pending_pitch_;
    pending_yaw_ = pending_pitch_ = 0;
    game_yaw_ = wrap(game_yaw_ + wrap(live_turn_.yaw - game_yaw_) * 0.05f);
    game_pitch_ = std::clamp(game_pitch_ + (live_turn_.pitch - game_pitch_) * 0.05f, -89.0f, 89.0f);
    const float step = static_cast<float>(std::clamp(seconds, 0.0, 0.1));
    for (int c = 0; c < 3; ++c) {
        game_position_[c] += live_velocity_[c] * step;
        // Slowly toward the screen's, so the two clocks never drift apart.
        game_position_[c] += (screen[c] - game_position_[c]) * 0.05f;
    }
}
Settings Bridge::settings() const {
    std::lock_guard lock(mutex_);
    return settings_;
}
void Bridge::set_settings(const Settings& settings) {
    std::lock_guard lock(mutex_);
    settings_ = settings;
}

std::pair<int, int> export_size(const ExportChoice& choice, float game_aspect) noexcept {
    const auto even = [](double v) { return std::max(2, static_cast<int>(std::lround(v / 2)) * 2); };
    if (!choice.game_shape || !(game_aspect > 0.1f && game_aspect < 10.0f)) return {even(choice.width), even(choice.height)};
    // In whole 16-pixel blocks, at most 3840 wide: the game's encoder refused 4096 x 1672 outright.
    const auto blocks = [](double v) { return std::max(16, static_cast<int>(std::lround(v / 16)) * 16); };
    constexpr int widest = 3840;
    double height = choice.height, width = height * game_aspect;
    if (width > widest) {
        height *= widest / width;
        width = widest;
    }
    return {std::min(widest, blocks(width)), blocks(height)};
}
Bridge& bridge() {
    static auto* value = new Bridge; // the game's threads may still ask at exit
    return *value;
}

std::filesystem::path editor_folder() {
    PWSTR raw = nullptr;
    std::filesystem::path folder;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &raw)) && raw) folder = std::filesystem::path(raw) / L"ReSkate";
    if (raw) CoTaskMemFree(raw);
    if (folder.empty()) return {};
    std::error_code error;
    std::filesystem::create_directories(folder / L"Replays", error);
    return folder;
}

Settings load_settings() {
    const auto folder = editor_folder();
    if (folder.empty()) return {};
    std::ifstream in(folder / L"ReplayEditor.settings", std::ios::binary);
    if (!in) return {};
    std::ostringstream text;
    text << in.rdbuf();
    return settings_from_text(text.str());
}

void save_settings(const Settings& settings) {
    const auto folder = editor_folder();
    if (folder.empty()) return;
    std::ofstream out(folder / L"ReplayEditor.settings", std::ios::binary | std::ios::trunc);
    const auto text = to_text(settings);
    out.write(text.data(), static_cast<std::streamsize>(text.size()));
}
} // namespace dingosdk::replay_editor
