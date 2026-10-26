#include "replay_editor_internal.h"
#include "overlay_internal.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <vector>
#include <string>
#include <cstring>

// The replay editor's filmstrip: small pictures of the footage along the timeline, as a video editor
// shows them. They are the game's own frames, copied before ReSkate draws and read a frame or two later
// (copy_presented_frame, so taking one never holds the game up). While the game records, a picture of
// it every half second or so is kept by the recording's time (`Store`, a few hundred at most: when
// full, every other one goes and they come half as often), and the filmstrip starts from those when the
// editor opens. In the editor the slot under the playhead gets its picture as the footage plays or is
// scrubbed past it, and again when it is old. All of it on the render thread, where the editor draws.
namespace dingosdk::overlay {
namespace {
constexpr int slots = 96, columns = 16, rows = slots / columns;
constexpr int cell_width = 160, cell_height = 90;
constexpr int atlas_width = columns * cell_width, atlas_height = rows * cell_height;

// A picture's pixels, one slot's worth (RGBA).
using Picture = std::vector<std::uint8_t>;
// Pictures of the game as it records.
struct Store {
    struct Kept {
        double at{}; // the recording's time
        Picture pixels;
    };
    std::string level;
    std::uint64_t run{};
    std::vector<Kept> kept; // oldest first
    double every{0.5};      // recording seconds between pictures
    double last_at{-1e9};
    bool in_flight{};
    double asked{-100}, asked_at{}; // steady seconds of the request, and the recording's time then
};
constexpr std::size_t most_kept = 256;
constexpr int store_tag = 1000; // copy_presented_frame's tag for a picture for the store

struct Filmstrip {
    double from{}, to{};                  // the recording the slots cover (replay seconds)
    std::vector<std::uint8_t> atlas;      // RGBA, every slot's picture
    std::array<double, slots> taken{};    // ImGui time each slot's picture was taken (<= 0: none)
    bool dirty{};
    double uploaded_at{-100};
    ImTextureID texture{};
    unsigned serial{};
    int wanted{-1};                       // the slot the next presented frame is for
    bool in_flight{};                     // its copy is on its way
    double last_grab{-100};
};
// Seconds on a steady clock. Not ImGui's: the picture is taken before the overlay makes its ImGui
// context current, and ImGui without one faults.
double seconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
Filmstrip& film() {
    static auto* value = new Filmstrip;
    return *value;
}
Store& store() {
    static auto* value = new Store;
    return *value;
}

// The copied frame, its middle at 16:9, shrunk into `out` (`stride` bytes a row).
void shrink(const detail::FrameSampler& frame, std::uint8_t* out, std::size_t stride) {
    double w = frame.width, h = frame.height;
    double x0 = 0, y0 = 0;
    if (w / h > 16.0 / 9.0) {
        x0 = (w - h * 16.0 / 9.0) / 2;
        w = h * 16.0 / 9.0;
    } else {
        y0 = (h - w * 9.0 / 16.0) / 2;
        h = w * 9.0 / 16.0;
    }
    for (int y = 0; y < cell_height; ++y)
        for (int x = 0; x < cell_width; ++x) {
            // Four samples a picture pixel.
            int sum[3]{};
            for (int sy = 0; sy < 2; ++sy)
                for (int sx = 0; sx < 2; ++sx) {
                    const auto p = frame.rgb(static_cast<std::uint32_t>(x0 + (x + 0.25 + sx * 0.5) * w / cell_width),
                                             static_cast<std::uint32_t>(y0 + (y + 0.25 + sy * 0.5) * h / cell_height));
                    for (int c = 0; c < 3; ++c) sum[c] += p[static_cast<std::size_t>(c)];
                }
            auto* to = out + static_cast<std::size_t>(y) * stride + static_cast<std::size_t>(x) * 4;
            for (int c = 0; c < 3; ++c) to[c] = static_cast<std::uint8_t>(sum[c] / 4);
            to[3] = 255;
        }
}

double slot_time(const Filmstrip& f, int slot) { return f.from + (f.to - f.from) * (slot + 0.5) / slots; }
int slot_of(const Filmstrip& f, double t) {
    if (!(f.to > f.from)) return -1;
    return std::clamp(static_cast<int>((t - f.from) / (f.to - f.from) * slots), 0, slots - 1);
}
} // namespace

namespace replay_ui {
void filmstrip_rebuild() {
    auto& f = film();
    const auto s = status();
    f.from = s.window_start;
    f.to = std::max(s.window_end, s.window_start + 1);
    f.taken.fill(0);
    f.atlas.assign(std::size_t{atlas_width} * atlas_height * 4, 0);
    for (std::size_t i = 3; i < f.atlas.size(); i += 4) f.atlas[i] = 255;
    f.dirty = true;
    f.wanted = -1;
    // Each slot from the picture taken while the game recorded nearest its time, when one is near.
    const auto& kept = store().kept;
    if (kept.empty() || store().level != s.level || store().run != s.run) return;
    const double reach = std::max((f.to - f.from) / slots, store().every);
    const double old = seconds() - 5; // counted as old: taken again as the footage plays past it
    for (int slot = 0; slot < slots; ++slot) {
        const double t = slot_time(f, slot);
        const auto after = std::lower_bound(kept.begin(), kept.end(), t, [](const Store::Kept& k, double v) { return k.at < v; });
        const Store::Kept* best = nullptr;
        if (after != kept.end()) best = &*after;
        if (after != kept.begin() && (!best || t - std::prev(after)->at < best->at - t)) best = &*std::prev(after);
        if (!best || std::abs(best->at - t) > reach) continue;
        const int ox = (slot % columns) * cell_width, oy = (slot / columns) * cell_height;
        for (int y = 0; y < cell_height; ++y)
            std::memcpy(f.atlas.data() + (std::size_t{static_cast<unsigned>(oy + y)} * atlas_width + static_cast<unsigned>(ox)) * 4,
                        best->pixels.data() + std::size_t{static_cast<unsigned>(y)} * cell_width * 4, std::size_t{cell_width} * 4);
        f.taken[static_cast<std::size_t>(slot)] = old;
    }
}

// Every frame the editor draws: the picture under the playhead, when it has none or it is old.
void filmstrip_update() {
    auto& u = ui();
    auto& f = film();
    const auto s = status();
    if (s.exporting) {
        f.wanted = -1;
        return;
    }
    // A new recording (another replay, or the window moved on): new pictures.
    if (std::abs(s.window_start - f.from) > 0.5 || std::abs(std::max(s.window_end, s.window_start + 1) - f.to) > 0.5 || f.atlas.empty())
        filmstrip_rebuild();
    const double time = seconds();
    // A copy lost on its way (the overlay rebuilt its graphics): ask again.
    if (f.in_flight && time - f.last_grab > 2) f.in_flight = false;
    const int slot = slot_of(f, now());
    const bool moving = u.playing || u.scrubbing;
    if (slot >= 0 && f.wanted < 0 && !f.in_flight && time - f.last_grab > 0.2 &&
        (f.taken[static_cast<std::size_t>(slot)] <= 0 || (moving && time - f.taken[static_cast<std::size_t>(slot)] > 4)))
        f.wanted = slot;
}

std::optional<FilmCell> filmstrip_cell(double t) {
    const auto& f = film();
    const int slot = slot_of(f, t);
    if (slot < 0 || !f.texture || f.taken[static_cast<std::size_t>(slot)] <= 0) return std::nullopt;
    const float u0 = static_cast<float>(slot % columns) / columns, v0 = static_cast<float>(slot / columns) / rows;
    return FilmCell{f.texture, {u0, v0}, {u0 + 1.0f / columns, v0 + 1.0f / rows}};
}
} // namespace replay_ui

namespace detail {
// A picture of the game for the store: every `every` seconds of recording, one at a time. Asked on every
// presented frame before the overlay makes its ImGui context current, so it reads the bridge itself
// (replay_ui::status() asks ImGui the time, which faulted there and left the game on a black screen).
bool store_wants(double& at) noexcept {
    auto& st = store();
    if (state().replay_editor_visible.load()) return false;
    const auto s = replay_editor::bridge().recording();
    if (!s.available || !std::isfinite(s.at)) return false;
    const double time = seconds();
    if (st.in_flight && time - st.asked > 2) st.in_flight = false; // lost on its way
    if (s.level != st.level || s.run != st.run || s.at < st.last_at - 1) {
        // Another map or run, or the recording started again: the pictures are of other footage.
        st.kept.clear();
        st.every = 0.5;
        st.last_at = -1e9;
        st.level = s.level;
        st.run = s.run;
    }
    if (st.in_flight || s.at - st.last_at < st.every || time - st.asked < 0.1) return false;
    at = s.at;
    return true;
}
bool replay_filmstrip_pending() noexcept {
    double at{};
    return store().in_flight || store_wants(at);
}
int replay_filmstrip_wanted() noexcept {
    auto& f = film();
    if (double at{}; store_wants(at)) {
        auto& st = store();
        st.in_flight = true;
        st.asked = seconds();
        st.asked_at = at;
        return store_tag;
    }
    if (!state().replay_editor_visible.load() || f.wanted < 0) return -1;
    const int slot = f.wanted;
    f.wanted = -1;
    f.in_flight = true;
    f.last_grab = seconds();
    return slot;
}

// The copied frame, its middle at 16:9, shrunk into its slot.
void replay_filmstrip_take(int slot, const FrameSampler& frame) noexcept {
    const bool picture = frame.data && frame.width && frame.height;
    if (slot == store_tag) {
        auto& st = store();
        st.in_flight = false;
        if (!picture) return;
        try {
            Store::Kept kept{st.asked_at, Picture(std::size_t{cell_width} * cell_height * 4)};
            shrink(frame, kept.pixels.data(), std::size_t{cell_width} * 4);
            st.kept.push_back(std::move(kept));
            st.last_at = st.asked_at;
            if (st.kept.size() > most_kept) {
                // Full: every other one goes (the newest stays), and pictures come half as often.
                std::vector<Store::Kept> thinned;
                thinned.reserve(st.kept.size() / 2 + 1);
                for (std::size_t i = st.kept.size() % 2 ? 0 : 1; i < st.kept.size(); i += 2) thinned.push_back(std::move(st.kept[i]));
                st.kept = std::move(thinned);
                st.every *= 2;
            }
        } catch (...) {}
        return;
    }
    auto& f = film();
    f.in_flight = false;
    if (slot < 0 || slot >= slots || !picture || f.atlas.empty()) return;
    const int ox = (slot % columns) * cell_width, oy = (slot / columns) * cell_height;
    shrink(frame, f.atlas.data() + (std::size_t{static_cast<unsigned>(oy)} * atlas_width + static_cast<unsigned>(ox)) * 4,
           std::size_t{atlas_width} * 4);
    f.taken[static_cast<std::size_t>(slot)] = seconds();
    f.dirty = true;
}

// The pictures onto the GPU, a few times a second while they change, into the two textures in turn: the
// one replaced was last drawn a quarter of a second ago at least, long done on the GPU, so nothing waits
// for it (waiting held the overlay up for a frame each time, and a flown camera stood still meanwhile).
void upload_replay_filmstrip(State& s) {
    auto& f = film();
    if (!f.dirty || !s.device || !s.srvs || f.atlas.empty()) return;
    const double time = seconds();
    if (time - f.uploaded_at < 0.25) return;
    CardPixels pixels;
    pixels.rgba = f.atlas;
    pixels.width = atlas_width;
    pixels.height = atlas_height;
    pixels.serial = ++f.serial;
    const std::size_t turn = f.serial % 2;
    const UINT slot = turn ? replay_filmstrip_second_slot : replay_filmstrip_slot;
    if (const auto id = upload_image(s, pixels, slot, s.filmstrip_textures[turn], s.filmstrip_uploads[turn])) {
        f.texture = id;
        f.dirty = false;
        f.uploaded_at = time;
    }
}
} // namespace detail
} // namespace dingosdk::overlay
