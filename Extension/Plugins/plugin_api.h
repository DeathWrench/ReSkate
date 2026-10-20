#pragma once
#include "plugin_vm.h"

// Inside the plugin host only: the reskate API a plugin's VM gets.
namespace dingosdk::plugins {
struct Api {
    // The `reskate` table, `print` and `require`, before the VM is sandboxed.
    static void install(Plugin& plugin, lua_State* L);
};
// The overlay, menu, sound, mods, session and message parts of the API (plugin_api_ui.cpp), into
// the reskate table on top of the stack.
void install_ui_api(Plugin& plugin, lua_State* L);
// Phase 3's parts of the API (plugin_api_more.cpp), into the reskate table on top of the stack.
void install_more_api(Plugin& plugin, lua_State* L);
// The wider set's game parts (plugin_api_world.cpp), into the same table.
void install_world_api(Plugin& plugin, lua_State* L);
// General services for a game layer: the skater's telemetry and Bone Cam, the pad and keys, the
// free and pad-flown cameras, the session's world, competition physics and the trick feed
// (plugin_api_services.cpp).
void install_services_api(Plugin& plugin, lua_State* L);
// The throwdown kit's documents and native flag, the plugin's data files, overlay dialogs and the
// skater's push (with its wait and reset) and hold (plugin_api_throwdowns.cpp).
void install_kit_api(Plugin& plugin, lua_State* L);
// A player as plugins get one: {id = "<SteamID64>", name, me, host}.
void push_player(lua_State* L, const SessionPlayer& player);
// A file's bytes when it is a regular file no larger than `most`; otherwise empty, and `error`
// says why ("not found" when there is none).
std::string read_package_file(const std::filesystem::path& file, std::size_t most, std::string& error);
// A file of the plugin's own package by its path there; a Lua error for one outside it.
std::filesystem::path package_file(lua_State* L, Plugin& plugin, std::string_view path);
// JSON and Lua values, both ways. Throws std::runtime_error on a value JSON cannot hold.
Json lua_to_json(lua_State* L, int index);
void push_json(lua_State* L, const Json& value);
}
