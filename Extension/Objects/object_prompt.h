#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <optional>

// The game's prompt on a placed object names who placed it by asking for the local
// player's info, which is right in the game's own sessions (it only shows on your
// objects there) and wrong in ReSkate's, where other players' objects are spawned
// locally: every object read as your own. While that prompt's graph runs, the
// local-player lookup answers with the owner of the object nearest the skater instead
// (native_party_hooks.cpp), found among the objects ReSkate spawned for other players.
namespace dingosdk::object_prompt {
// The prompt's graph, as the expression VM names it (the hash at resource + 0x10).
inline constexpr std::uint32_t graph = 0x25bf9270;
// How far from the skater the object may be. The prompt is about the nearest one wherever
// it is, so this only rules out a position that is nowhere near the park.
inline constexpr float reach = 1337.f;

// Where the local skater is, as the multiplayer session saw them this frame. Written
// every frame and read from a UI script, so it takes no lock; a torn read only moves
// the point by a frame.
struct Viewer {
    std::atomic<float> x{}, y{}, z{};
    std::atomic<bool> known{};
};
inline Viewer &viewer() noexcept {
    static Viewer value;
    return value;
}
inline void set_viewer(const std::array<float, 3> &position) noexcept {
    auto &v = viewer();
    v.x.store(position[0], std::memory_order_relaxed);
    v.y.store(position[1], std::memory_order_relaxed);
    v.z.store(position[2], std::memory_order_relaxed);
    v.known.store(true, std::memory_order_relaxed);
}
inline void forget_viewer() noexcept { viewer().known.store(false, std::memory_order_relaxed); }
inline std::optional<std::array<float, 3>> viewer_position() noexcept {
    const auto &v = viewer();
    if (!v.known.load(std::memory_order_relaxed)) return std::nullopt;
    return std::array<float, 3>{v.x.load(std::memory_order_relaxed), v.y.load(std::memory_order_relaxed),
                                v.z.load(std::memory_order_relaxed)};
}
} // namespace dingosdk::object_prompt
