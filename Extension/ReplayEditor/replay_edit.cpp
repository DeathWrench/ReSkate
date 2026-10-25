#include "replay_edit.h"
#include <algorithm>
#include <cmath>

namespace dingosdk::replay_editor {
namespace {
float finite_or(float value, float fallback) noexcept { return std::isfinite(value) ? value : fallback; }
float clamp_or(float value, float low, float high, float fallback) noexcept {
    return std::clamp(finite_or(value, fallback), low, high);
}
// Degrees into -180..180.
float wrap_degrees(float degrees) noexcept {
    if (!std::isfinite(degrees)) return 0;
    degrees = std::fmod(degrees, 360.0f);
    if (degrees > 180) degrees -= 360;
    if (degrees < -180) degrees += 360;
    return degrees;
}
template <class Key> void put_sorted(std::vector<Key>& keys, Key key) {
    if (!std::isfinite(key.at)) return;
    if (auto* same = key_at(keys, key.at)) {
        *same = key;
        return;
    }
    const auto at = std::upper_bound(keys.begin(), keys.end(), key.at, [](double t, const Key& k) { return t < k.at; });
    keys.insert(at, std::move(key));
}
template <class Key> void sort_keys(std::vector<Key>& keys) {
    std::erase_if(keys, [](const Key& k) { return !std::isfinite(k.at); });
    std::stable_sort(keys.begin(), keys.end(), [](const Key& a, const Key& b) { return a.at < b.at; });
    // Keys on top of each other: the later one in the list stays.
    for (std::size_t i = 1; i < keys.size();)
        if (keys[i].at - keys[i - 1].at < same_key) keys.erase(keys.begin() + static_cast<std::ptrdiff_t>(i - 1));
        else ++i;
}
}

const char* ease_name(Ease ease) noexcept {
    switch (ease) {
    case Ease::smooth: return "smooth";
    case Ease::linear: return "linear";
    case Ease::ease_in: return "ease in";
    case Ease::ease_out: return "ease out";
    case Ease::ease_in_out: return "ease in-out";
    case Ease::hold: return "hold";
    }
    return "smooth";
}
std::optional<Ease> ease_from(std::string_view name) noexcept {
    for (const auto ease : all_eases)
        if (name == ease_name(ease)) return ease;
    return std::nullopt;
}
const char* part_name(Part part) noexcept {
    switch (part) {
    case Part::body: return "body";
    case Part::head: return "head";
    case Part::board: return "board";
    }
    return "body";
}
const char* rig_name(Rig rig) noexcept {
    switch (rig) {
    case Rig::free: return "free";
    case Rig::look_at: return "look at";
    case Rig::follow: return "follow";
    case Rig::orbit: return "orbit";
    }
    return "free";
}
const char* title_style_name(TitleStyle style) noexcept {
    switch (style) {
    case TitleStyle::title: return "title";
    case TitleStyle::caption: return "caption";
    case TitleStyle::label: return "label";
    case TitleStyle::lower_third: return "lower third";
    }
    return "title";
}

Clip* find_clip(Project& project, std::uint64_t id) noexcept {
    for (auto& clip : project.clips)
        if (clip.id == id) return &clip;
    return nullptr;
}
const Clip* find_clip(const Project& project, std::uint64_t id) noexcept {
    for (const auto& clip : project.clips)
        if (clip.id == id) return &clip;
    return nullptr;
}
std::optional<std::size_t> clip_index(const Project& project, std::uint64_t id) noexcept {
    for (std::size_t i = 0; i < project.clips.size(); ++i)
        if (project.clips[i].id == id) return i;
    return std::nullopt;
}

std::uint64_t add_clip(Project& project, double in, double out, std::size_t position, std::string name) {
    if (!std::isfinite(in) || !std::isfinite(out)) return 0;
    if (out < in) std::swap(in, out);
    if (out - in < shortest_clip) out = in + shortest_clip;
    Clip clip;
    clip.id = project.next_id++;
    clip.in = in;
    clip.out = out;
    clip.name = name.empty() ? "Clip " + std::to_string(clip.id) : std::move(name);
    position = std::min(position, project.clips.size());
    project.clips.insert(project.clips.begin() + static_cast<std::ptrdiff_t>(position), std::move(clip));
    return project.next_id - 1;
}

std::optional<std::uint64_t> split_clip(Project& project, std::uint64_t id, double t) {
    const auto index = clip_index(project, id);
    if (!index) return std::nullopt;
    Clip& first = project.clips[*index];
    if (!(t - first.in >= shortest_clip && first.out - t >= shortest_clip)) return std::nullopt;
    Clip second = first;
    second.id = project.next_id++;
    second.name = first.name + " (2)";
    second.in = t;
    first.out = t;
    first.hold = 0;
    // Keys stay with the part they are in; each part keeps the key on either side of the cut so
    // its curves read the same as before at the cut.
    const auto split_keys = [t](auto& before, auto& after) {
        using Key = typename std::decay_t<decltype(before)>::value_type;
        std::vector<Key> keep_before, keep_after;
        std::optional<Key> last_before, first_after;
        for (const auto& key : before) {
            if (key.at <= t) { keep_before.push_back(key); last_before = key; }
            else { keep_after.push_back(key); if (!first_after) first_after = key; }
        }
        if (first_after && !keep_before.empty()) keep_before.push_back(*first_after);
        if (last_before && !keep_after.empty() && last_before->at < t - same_key) keep_after.insert(keep_after.begin(), *last_before);
        before = std::move(keep_before);
        after = std::move(keep_after);
    };
    split_keys(first.speed, second.speed);
    split_keys(first.camera, second.camera);
    split_keys(first.look, second.look);
    std::erase_if(first.titles, [t](const Title& title) { return title.at >= t; });
    std::erase_if(second.titles, [t](const Title& title) { return title.at < t; });
    const auto new_id = second.id;
    project.clips.insert(project.clips.begin() + static_cast<std::ptrdiff_t>(*index + 1), std::move(second));
    return new_id;
}

bool remove_clip(Project& project, std::uint64_t id) {
    const auto index = clip_index(project, id);
    if (!index) return false;
    project.clips.erase(project.clips.begin() + static_cast<std::ptrdiff_t>(*index));
    return true;
}

bool move_clip(Project& project, std::uint64_t id, std::size_t position) {
    const auto index = clip_index(project, id);
    if (!index) return false;
    position = std::min(position, project.clips.size() - 1);
    if (position == *index) return false;
    Clip clip = std::move(project.clips[*index]);
    project.clips.erase(project.clips.begin() + static_cast<std::ptrdiff_t>(*index));
    project.clips.insert(project.clips.begin() + static_cast<std::ptrdiff_t>(position), std::move(clip));
    return true;
}

bool trim_clip(Project& project, std::uint64_t id, double in, double out, std::optional<std::array<double, 2>> window) {
    Clip* clip = find_clip(project, id);
    if (!clip || !std::isfinite(in) || !std::isfinite(out)) return false;
    if (window) {
        in = std::clamp(in, (*window)[0], (*window)[1]);
        out = std::clamp(out, (*window)[0], (*window)[1]);
    }
    if (out - in < shortest_clip) {
        // Whichever end moved stops short of the other.
        if (in != clip->in) in = out - shortest_clip;
        else out = in + shortest_clip;
    }
    clip->in = in;
    clip->out = out;
    return true;
}

std::optional<std::uint64_t> duplicate_clip(Project& project, std::uint64_t id) {
    const auto index = clip_index(project, id);
    if (!index) return std::nullopt;
    Clip copy = project.clips[*index];
    copy.id = project.next_id++;
    copy.name += " copy";
    const auto new_id = copy.id;
    project.clips.insert(project.clips.begin() + static_cast<std::ptrdiff_t>(*index + 1), std::move(copy));
    return new_id;
}

void put_key(std::vector<CameraKey>& keys, CameraKey key) { put_sorted(keys, clamped(key)); }
void put_key(std::vector<SpeedKey>& keys, SpeedKey key) {
    key.speed = clamp_or(key.speed, slowest, fastest, 1);
    put_sorted(keys, key);
}
void put_key(std::vector<LookKey>& keys, LookKey key) {
    key.look = clamped(key.look);
    put_sorted(keys, key);
}

CameraKey clamped(CameraKey key) {
    for (auto& v : key.position) v = clamp_or(v, -100000.0f, 100000.0f, 0);
    key.yaw = wrap_degrees(key.yaw);
    key.pitch = clamp_or(key.pitch, -89.5f, 89.5f, 0);
    key.roll = wrap_degrees(key.roll);
    key.fov = clamp_or(key.fov, 5, 140, 65);
    key.orbit_speed = clamp_or(key.orbit_speed, -360, 360, 20);
    key.focus = key.focus < 0 ? -1.0f : clamp_or(key.focus, 0, 1000, 0);
    key.blur = clamp_or(key.blur, 0, 1, 0.5f);
    if (static_cast<unsigned>(key.rig) > static_cast<unsigned>(Rig::orbit)) key.rig = Rig::free;
    if (static_cast<unsigned>(key.ease) > static_cast<unsigned>(Ease::hold)) key.ease = Ease::smooth;
    if (static_cast<unsigned>(key.target.part) > static_cast<unsigned>(Part::board)) key.target.part = Part::body;
    return key;
}
Look clamped(Look look) {
    look.exposure = clamp_or(look.exposure, -3, 3, 0);
    look.saturation = clamp_or(look.saturation, 0, 2, 1);
    look.contrast = clamp_or(look.contrast, 0.5f, 1.5f, 1);
    look.hue = clamp_or(look.hue, -180, 180, 0);
    look.vignette = clamp_or(look.vignette, 0, 1, 0);
    look.barrel = clamp_or(look.barrel, 0, 1, 0);
    look.grain = clamp_or(look.grain, 0, 1, 0);
    look.aberration = clamp_or(look.aberration, 0, 1, 0);
    return look;
}

void normalize(Clip& clip) {
    if (!std::isfinite(clip.in)) clip.in = 0;
    if (!std::isfinite(clip.out)) clip.out = clip.in + 1;
    if (clip.out < clip.in) std::swap(clip.in, clip.out);
    if (clip.out - clip.in < shortest_clip) clip.out = clip.in + shortest_clip;
    clip.hold = std::isfinite(clip.hold) ? std::clamp(clip.hold, 0.0, 30.0) : 0;
    for (auto& key : clip.speed) key.speed = clamp_or(key.speed, slowest, fastest, 1);
    for (auto& key : clip.camera) key = clamped(key);
    for (auto& key : clip.look) key.look = clamped(key.look);
    sort_keys(clip.speed);
    sort_keys(clip.camera);
    sort_keys(clip.look);
    std::erase_if(clip.titles, [](const Title& t) { return !std::isfinite(t.at) || t.text.empty(); });
    for (auto& title : clip.titles) {
        title.length = std::isfinite(title.length) ? std::clamp(title.length, 0.1, 600.0) : 3;
        title.x = clamp_or(title.x, 0, 1, .5f);
        title.y = clamp_or(title.y, 0, 1, .8f);
        title.size = clamp_or(title.size, .25f, 4, 1);
        if (title.text.size() > 200) title.text.resize(200);
        if (static_cast<unsigned>(title.style) > static_cast<unsigned>(TitleStyle::lower_third)) title.style = TitleStyle::title;
    }
    clip.shake = clamp_or(clip.shake, 0, 10, 0);
    clip.shake_rate = clamp_or(clip.shake_rate, 0.1f, 10, 1.2f);
    if (clip.name.size() > 80) clip.name.resize(80);
}
void normalize(Project& project) {
    if (project.name.empty()) project.name = "Untitled";
    if (project.name.size() > 80) project.name.resize(80);
    std::uint64_t highest = 0;
    for (auto& clip : project.clips) {
        normalize(clip);
        highest = std::max(highest, clip.id);
    }
    // Ids are unique: a repeated one gets a new id.
    for (std::size_t i = 0; i < project.clips.size(); ++i)
        for (std::size_t j = 0; j < i; ++j)
            if (project.clips[j].id == project.clips[i].id || project.clips[i].id == 0) {
                project.clips[i].id = ++highest;
                break;
            }
    project.next_id = std::max(project.next_id, highest + 1);
}

void History::remember(const Project& before) {
    past_.push_back(before);
    if (past_.size() > 100) past_.erase(past_.begin());
    future_.clear();
}
bool History::undo(Project& project) {
    if (past_.empty()) return false;
    future_.push_back(std::move(project));
    project = std::move(past_.back());
    past_.pop_back();
    return true;
}
bool History::redo(Project& project) {
    if (future_.empty()) return false;
    past_.push_back(std::move(project));
    project = std::move(future_.back());
    future_.pop_back();
    return true;
}
void History::clear() noexcept {
    past_.clear();
    future_.clear();
}
} // namespace dingosdk::replay_editor
