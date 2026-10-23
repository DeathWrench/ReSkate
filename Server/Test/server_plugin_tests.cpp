// The dedicated server's plugins (server_plugins.cpp) with the server's host, over a transport
// that is not Steam's and simulated players: what a server plugin sees of the players' skaters.
//
//   dingosdk_server_plugin_tests <Server/Test/fixtures/park_mods>
#include "Server/server_host.h"
#include "Extension/Multiplayer/Net/pose_batch.h"
#include "Extension/Multiplayer/Net/pose_codec.h"
#include "Extension/Multiplayer/Net/wire_codec.h"
#include "Extension/Multiplayer/Steam/steam_transport.h"
#include "Engine/Game/Build/supported_build.h"
#include "Engine/Game/World/world_names.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <deque>
#include <fstream>
#include <map>
#include <string>
#include <vector>

namespace dingosdk::multiplayer {
namespace {
// What the fake transport holds: what each player is sent, and what they send.
struct Wire {
    TransportStatus status;
    std::vector<TransportMessage> inbound;
    std::map<std::uint64_t, std::vector<std::vector<std::uint8_t>>> sent;
};
Wire &wire() {
    static Wire value;
    return value;
}
} // namespace

struct SteamTransport::Impl {};
SteamTransport::SteamTransport() = default;
SteamTransport::~SteamTransport() = default;
bool SteamTransport::open() { return true; }
bool SteamTransport::open_game_server(void *) { return true; }
bool SteamTransport::host(unsigned) {
    wire().status.ready = wire().status.hosting = true;
    wire().status.local_id = (1ULL << 56) | (4ULL << 52) | 1; // a game server's SteamID, never a player's
    return true;
}
bool SteamTransport::join(std::uint64_t, std::uint32_t, std::uint16_t) { return false; }
bool SteamTransport::listen_direct(std::uint16_t) { return true; }
void SteamTransport::set_packing(unsigned) {}
std::vector<std::string> SteamTransport::take_direct_notes() { return {}; }
bool SteamTransport::set_steam_debug(bool) { return false; }
bool SteamTransport::connect_peer(std::uint64_t) { return false; }
void SteamTransport::allow_peers(std::span<const Member>) {}
bool SteamTransport::socket_test() { return true; }
void SteamTransport::stop() {}
void SteamTransport::disconnect(std::uint64_t id, const char *) {
    std::erase_if(wire().status.peers, [&](const TransportPeer &peer) { return peer.id == id; });
}
void SteamTransport::poll() {}
bool SteamTransport::send(std::uint64_t id, std::span<const std::uint8_t> bytes, bool, bool, TrafficLane) {
    if (std::none_of(wire().status.peers.begin(), wire().status.peers.end(), [&](const auto &peer) { return peer.id == id; })) return false;
    wire().sent[id].emplace_back(bytes.begin(), bytes.end());
    return true;
}
void SteamTransport::send_batch(std::span<TransportSend> messages) {
    for (auto &message : messages) message.sent = send(message.id, message.bytes, message.reliable, message.fresh, message.lane);
}
std::vector<TransportMessage> SteamTransport::receive() { return std::exchange(wire().inbound, {}); }
std::string SteamTransport::name(std::uint64_t) { return {}; }
const TransportStatus &SteamTransport::status() const { return wire().status; }
std::string SteamTransport::take_closed(std::uint64_t) { return {}; }
std::string SteamTransport::link_report(std::uint64_t) { return {}; }
std::int64_t SteamTransport::pending(std::uint64_t) const { return 0; }
std::string SteamTransport::relay_status() const { return "OK"; }
bool SteamTransport::set_send_rate(int) { return true; }
int SteamTransport::send_rate() const { return 900 * 1024; }
std::vector<TransportLink> SteamTransport::links() { return {}; }
bool SteamTransport::bind(void *, void *, void *) { return true; }
} // namespace dingosdk::multiplayer

namespace {
using namespace dingosdk;
using namespace dingosdk::multiplayer;
using namespace dingosdk::server;

int failures{};
void check(bool ok, const std::string &what) {
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", what.c_str());
        ++failures;
    }
}
bool has(const std::vector<std::string> &lines, std::string_view text) {
    return std::any_of(lines.begin(), lines.end(), [&](const auto &line) { return line.find(text) != std::string::npos; });
}
void write(const std::filesystem::path &file, const std::string &text) {
    std::filesystem::create_directories(file.parent_path());
    std::ofstream(file, std::ios::binary | std::ios::trunc) << text;
}

// One player's game: its greeting, its world being ready, and its poses sent as a game sends
// them (pose_batch.h), standing at `at` and facing `heading` about world up.
struct Player {
    std::uint64_t id{}, epoch{}, secret{}, map{};
    std::string name;
    std::array<float, 3> at{};
    float heading{};
    std::uint32_t sequence{};
    struct Kept {
        std::uint32_t sequence{};
        std::uint64_t time_us{};
        pose_codec::QuantPose pose;
    };
    std::deque<Kept> kept;
    pose_batch::Sender upload;

    Packet header(PacketKind kind, std::uint64_t now) {
        Packet p;
        p.kind = kind;
        p.session = secret;
        p.map = map;
        p.world = 1;
        p.epoch = epoch;
        p.source = id;
        p.time_us = now;
        p.sequence = ++sequence;
        p.build = supported_build::game_sha256_bytes;
        return p;
    }
    void hello(std::uint64_t now) {
        wire().status.peers.push_back({id, true});
        auto p = header(PacketKind::hello, now);
        p.text = name;
        wire().inbound.push_back({id, encode_wire(p), now});
    }
    void ready(std::uint64_t now) {
        auto p = header(PacketKind::world_ready, now);
        p.world_ready = true;
        wire().inbound.push_back({id, encode_wire(p), now});
    }
    void pose(std::uint64_t now) {
        for (const auto &bytes : std::exchange(wire().sent[id], {}))
            if (const auto read = pose_batch::Ack::read(bytes)) upload.ack(*read);
        auto p = header(PacketKind::pose, now);
        p.pose.root.position = at;
        p.pose.root.rotation = {0.f, std::sin(heading * 0.5f), 0.f, std::cos(heading * 0.5f)};
        p.pose.skater.resize(pose_codec::finger_skeleton);
        p.pose.skater[1].position = at;
        p.pose.board.resize(16);
        p.pose.board[0].position = at;
        kept.push_back({p.sequence, p.time_us, pose_codec::quantize(p.pose)});
        while (kept.size() > 64) kept.pop_front();
        const auto find = [&](std::uint32_t sequence) -> std::optional<pose_batch::KeptView> {
            for (auto it = kept.rbegin(); it != kept.rend(); ++it)
                if (it->sequence == sequence) return pose_batch::KeptView{it->sequence, it->time_us, &it->pose};
            return {};
        };
        const auto emit = [&](std::span<const std::uint8_t> message, bool) {
            wire().inbound.push_back({id, {message.begin(), message.end()}, now});
            return true;
        };
        upload.begin(1, map);
        upload.add(p.source, p.epoch, *find(p.sequence), find, false, false, pose_batch::Rate::full, now, emit);
        upload.flush(emit);
    }
};

int run(const std::filesystem::path &fixtures) {
    const auto root = std::filesystem::temp_directory_path() / "reskate_server_plugin_tests";
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / "Mods");
    for (const auto *folder : {"popular skate 2 street park", "mixed park"})
        std::filesystem::copy(fixtures / folder, root / "Mods" / folder, std::filesystem::copy_options::recursive);
    load_levels(root / "Mods"); // the retail maps
    ServerConfig config;
    config.file = root / "server" / "ReSkateServer.json";
    config.mods = root / "Mods";
    config.auto_update = false;
    config.activity_log = false;
    config.roles = default_roles();
    config.park_mods = {{"street", "popular skate 2 street park", "San Vansterdam", "bam"}, {"plaza", "mixed park", "Isle of Grom", "grom"}};
    check(config_error(config).empty(), "The test's config was refused: " + config_error(config));

    // A plugin that prints the skaters it sees every 20th tick (a second here), and one without
    // session.skaters. Ticks, not reskate.time: its clock is the real one, and this test's is not.
    write(root / "Plugins" / "watcher" / "reskate-plugin.json",
          R"({"api": 1, "entry": "plugin/main.lua", "side": "server", "permissions": ["console", "session.skaters"]})");
    write(root / "Plugins" / "watcher" / "plugin" / "main.lua", R"(
        local ticks = 0
        reskate.on("tick", function()
            ticks += 1
            if ticks % 20 ~= 0 then return end
            local list = reskate.session.skaters()
            reskate.console.print("skaters " .. #list)
            for _, s in ipairs(list) do
                reskate.console.print(string.format("skater %s at %.1f %.1f %.1f facing %.2f, %s", s.id, s.position.x, s.position.y,
                    s.position.z, s.heading, s.age_ms >= 0 and s.age_ms < 1000 and "fresh" or ("stale " .. s.age_ms)))
            end
        end)
    )");
    write(root / "Plugins" / "blind" / "reskate-plugin.json",
          R"({"api": 1, "entry": "plugin/main.lua", "side": "server", "permissions": ["console"]})");
    write(root / "Plugins" / "blind" / "plugin" / "main.lua", R"(
        local ticks = 0
        reskate.on("tick", function()
            ticks += 1
            if ticks % 20 ~= 0 then return end
            local ok, why = pcall(reskate.session.skaters)
            reskate.console.print(ok and "blind saw them" or "blind refused: " .. tostring(why))
        end)
        reskate.console.command("blind parks", "park mods without server.parks", function()
            local ok, why = pcall(reskate.server.parks)
            reskate.console.print(ok and "blind listed parks" or "blind parks refused: " .. tostring(why))
        end)
    )");

    // One that says what the level is, and when it changes.
    write(root / "Plugins" / "follower" / "reskate-plugin.json",
          R"({"api": 1, "entry": "plugin/main.lua", "side": "server", "permissions": ["console"]})");
    write(root / "Plugins" / "follower" / "plugin" / "main.lua", R"(
        reskate.on("level_unloading", function(name) reskate.console.print("unloading " .. name) end)
        reskate.on("level_loaded", function(name) reskate.console.print("loaded " .. name) end)
        local ticks = 0
        reskate.on("tick", function()
            ticks += 1
            if ticks % 20 == 0 then reskate.console.print("level " .. reskate.level.current().name) end
        end)
    )");

    // One that lists, spawns and removes park mods when the console asks it to.
    write(root / "Plugins" / "parker" / "reskate-plugin.json",
          R"({"api": 1, "entry": "plugin/main.lua", "side": "server", "permissions": ["console", "server.parks"]})");
    write(root / "Plugins" / "parker" / "plugin" / "main.lua", R"(
        reskate.console.command("parker", "park mods, for the test", function(args)
            local verb, name = args[1], args[2]
            if verb == "list" then
                for _, p in ipairs(reskate.server.parks()) do
                    reskate.console.print(string.format("park %s on %s, here %s, spawned %s, %d objects, %d min left", p.name, p.map,
                        tostring(p.here), tostring(p.spawned), p.objects, p.minutes_left))
                end
            elseif verb == "spawn" then
                local ok, why = reskate.server.park_spawn(name, tonumber(args[3]))
                reskate.console.print("spawn " .. name .. ": " .. (ok and "done" or why))
            elseif verb == "remove" then
                local ok, why = reskate.server.park_remove(name)
                reskate.console.print("remove " .. name .. ": " .. (ok and "done" or why))
            elseif verb == "bad" then
                local named = pcall(reskate.server.park_spawn, "Street; map grom")
                local timed = pcall(reskate.server.park_spawn, "street", 5000)
                reskate.console.print("bad " .. (named and "name taken" or "name refused") .. ", " .. (timed and "minutes taken" or "minutes refused"))
            end
        end)
    )");

    std::vector<std::string> log;
    SteamTransport transport;
    Host host(config, transport, [&](const std::string &line) { log.push_back(line); });
    std::string error;
    if (!host.start(error)) {
        std::fprintf(stderr, "The server did not start: %s\n", error.c_str());
        return 1;
    }
    const auto invite = parse_invite(host.invite());
    if (!invite) {
        std::fprintf(stderr, "No invite.\n");
        return 1;
    }
    std::vector<Player> players(2);
    for (std::size_t i = 0; i < players.size(); ++i) {
        auto &p = players[i];
        p.id = 76561198000000001ULL + i;
        p.epoch = 5000 + i;
        p.secret = invite->secret;
        p.map = map_hash(map_destination(config.map));
        p.name = "Player " + std::to_string(i + 1);
    }
    players[0].at = {10.f, 2.f, -30.f};
    players[0].heading = 1.f;
    players[1].at = {-4.f, 7.5f, 12.f};

    std::uint64_t now = 1000000000ULL, next_ready = now;
    bool posing{};
    const auto run_for = [&](std::uint64_t microseconds) {
        for (const auto end = now + microseconds; now < end; now += 50000) {
            if (now >= next_ready) {
                next_ready = now + 1000000;
                for (auto &p : players) p.ready(now);
            }
            if (posing)
                for (auto &p : players) p.pose(now);
            host.tick(now);
        }
    };
    // Before anyone is in the world, the plugin sees nobody.
    run_for(3000000);
    check(has(log, "skaters 0"), "The plugin did not run, or saw skaters on an empty server");
    check(std::any_of(log.begin(), log.end(),
                     [](const auto &line) { return line.starts_with("blind refused: ") && line.find("session.skaters") != std::string::npos; }),
          "A plugin without session.skaters was not refused");
    check(!has(log, "blind saw them"), "A plugin without session.skaters saw the skaters");

    // Joined and in the world, but no pose yet: still nobody to see.
    for (auto &p : players) p.hello(now);
    run_for(3000000);
    log.clear();
    run_for(1100000);
    check(has(log, "skaters 0"), "A player with no pose yet was a skater");

    // Posing: each where their latest pose put them, facing as it faces.
    posing = true;
    run_for(3000000);
    log.clear();
    run_for(1100000);
    check(has(log, "skaters 2"), "The plugin did not see both skaters");
    check(has(log, "skater 76561198000000001 at 10.0 2.0 -30.0 facing 1.00, fresh"), "The first skater's place, heading or age is wrong");
    check(has(log, "skater 76561198000000002 at -4.0 7.5 12.0 facing 0.00, fresh"), "The second skater's place, heading or age is wrong");
    // A skater who stopped sending stays where they were, older.
    posing = false;
    run_for(2000000);
    log.clear();
    run_for(1100000);
    check(has(log, "skater 76561198000000001 at 10.0 2.0 -30.0 facing 1.00, stale"), "A skater's age did not grow without poses");

    // Park mods: listed with whether they fit this map; spawned and removed through park-mod's own
    // checks, logged by the plugin's name.
    const auto plugin_command = [&](std::string_view line) {
        log.clear();
        check(host.command(line) == "Ran by a plugin.", std::string(line) + " did not reach the plugin");
    };
    plugin_command("parker list");
    check(has(log, "park street on San Vansterdam, here true, spawned false, 0 objects, 0 min left"), "street is not listed as it is");
    check(has(log, "park plaza on Isle of Grom, here false, spawned false"), "plaza is not listed as on another map");
    plugin_command("parker spawn street 5");
    check(has(log, "spawn street: done"), "The plugin could not spawn street");
    check(has(log, "[parks] street spawned (") && has(log, "5 min) by plugin parker"), "The spawn was not logged as the plugin's");
    plugin_command("parker list");
    check(has(log, "park street on San Vansterdam, here true, spawned true, ") && has(log, " objects, 5 min left"),
          "street is not listed as spawned for 5 min");
    plugin_command("parker spawn street");
    check(has(log, "spawn street: street is already spawned."), "A spawned park was spawned again");
    plugin_command("parker spawn plaza");
    check(has(log, "spawn plaza: plaza belongs on Isle of Grom"), "A park for another map was spawned");
    plugin_command("parker spawn nothing");
    check(has(log, "spawn nothing: there is no park mod called \"nothing\""), "A park that is not set up was spawned");
    plugin_command("parker bad");
    check(has(log, "bad name refused, minutes refused"), "A bad park name or time was taken");
    plugin_command("parker remove street");
    check(has(log, "remove street: done") && has(log, "[parks] street removed (by plugin parker)"), "The plugin could not remove street");
    plugin_command("parker remove street");
    check(has(log, "remove street: street is not spawned."), "A park not spawned was removed");
    plugin_command("blind parks");
    check(has(log, "blind parks refused: ") && has(log, "server.parks"), "A plugin without server.parks listed the parks");

    // The level, as players' games name it, and its change heard when the server changes it.
    const auto *first = find_level(config.map);
    const auto other = std::find_if(levels().begin(), levels().end(), [&](const auto &l) { return l.asset != first->asset; });
    check(first && other != levels().end(), "The test needs two retail maps");
    log.clear();
    run_for(1100000);
    check(has(log, "level " + first->asset), "level.current() is not the server's map: " + first->asset);
    host.change_map(other->name);
    log.clear();
    run_for(1100000);
    check(has(log, "unloading " + first->asset) && has(log, "loaded " + other->asset), "The plugin did not hear the map change");
    check(has(log, "level " + other->asset) && !has(log, "level " + first->asset), "level.current() did not follow the map change");
    check(!has(log, "skaters 2"), "Skaters stayed on the old map's places after the map changed");
    if (failures)
        for (const auto &line : log) std::fprintf(stderr, "log: %s\n", line.c_str());
    return failures ? 1 : 0;
}
} // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "Usage: dingosdk_server_plugin_tests <Server/Test/fixtures/park_mods>\n");
        return 2;
    }
    const int result = run(argv[1]);
    if (result == 0) std::printf("server plugin tests passed\n");
    return result;
}
