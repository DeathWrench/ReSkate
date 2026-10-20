#pragma once
#include <array>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

// What the session and the plugins hand each other (Extension/Multiplayer/Session/session.cpp
// and plugin_game_runtime.cpp): other players' skaters as the session last heard them, published
// each rendered frame; and the short tags plugins put beside players' nametags. Header only, so
// neither depends on the other. Any thread.
namespace dingosdk::plugin_feed {
struct Peer {
    std::uint64_t id{};
    std::array<float, 3> position{};
    std::array<float, 4> rotation{0, 0, 0, 1}; // x, y, z, w
    double age_ms{};                          // since its pose arrived, when published
};
struct Tag {
    std::string text;
    std::uint32_t colour{0xffffffffu}; // IM_COL32 layout
};

namespace detail {
inline std::mutex mutex;
inline std::vector<Peer> peers;
inline std::map<std::pair<std::string, std::uint64_t>, Tag> tags; // (plugin, player)
}

inline void publish_peers(std::vector<Peer> peers) {
    std::lock_guard lock(detail::mutex);
    detail::peers = std::move(peers);
}
inline std::vector<Peer> latest_peers() {
    std::lock_guard lock(detail::mutex);
    return detail::peers;
}
inline void set_tag(const std::string& plugin, std::uint64_t player, std::string text, std::uint32_t colour) {
    std::lock_guard lock(detail::mutex);
    if (text.empty()) detail::tags.erase({plugin, player});
    else if (detail::tags.size() < 1024 || detail::tags.contains({plugin, player})) detail::tags[{plugin, player}] = {std::move(text), colour};
}
inline void release_tags(const std::string& plugin) {
    std::lock_guard lock(detail::mutex);
    std::erase_if(detail::tags, [&](const auto& item) { return item.first.first == plugin; });
}
// The tag a plugin gave this player (the first, when several did).
inline std::optional<Tag> tag_of(std::uint64_t player) {
    std::lock_guard lock(detail::mutex);
    for (const auto& [key, tag] : detail::tags)
        if (key.second == player) return tag;
    return std::nullopt;
}
}
