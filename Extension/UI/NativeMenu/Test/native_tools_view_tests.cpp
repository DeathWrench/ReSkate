#include "Extension/UI/NativeMenu/native_tools_view.h"
#include <cstdio>
#include <stdexcept>

using namespace dingosdk;
using namespace dingosdk::native_tools;
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
struct Capture {
    unsigned calls{};
    std::string command, root, destination, spawn;
    overlay::DebugRequest debug;
};
int main() {
    try {
        {
            // A BAM root with its seven time-of-day layers, as the level scan finds them.
            WorldLayerCatalog catalog{{{"Levels/Game/BAM_LevelRoot/Root", WorldMap::bam, -1, true}}, {0}, {}};
            for (const auto* time : time_of_day_keys) {
                const auto slot = static_cast<unsigned>(catalog.nodes.size());
                catalog.nodes.push_back({std::string("Levels/Game/BAM_LevelRoot/TOD_") + time, WorldMap::bam, 0, false});
                catalog.layers.push_back({std::string("bam_tod_") + time, time, "", WorldMap::bam, slot, slot, "Lighting"});
            }
            install_world_layer_catalog(std::move(catalog));
        }
        State state;
        overlay::Model model;
        Capture capture;
        overlay::CallbacksV3 cb;
        cb.user = &capture;
        cb.queue_load = [](void* user, const char* root, const char*, const char* destination, const char* spawn, char*, std::size_t) {
            auto& c = *static_cast<Capture*>(user); ++c.calls; c.root = root; c.destination = destination; c.spawn = spawn; return true;
        };
        cb.queue_debug = [](void* user, const overlay::DebugRequest& request, char*, std::size_t) {
            auto& c = *static_cast<Capture*>(user); ++c.calls; c.debug = request; return true;
        };
        cb.queue_console_command = [](void* user, const char* command, char*, std::size_t) {
            auto& c = *static_cast<Capture*>(user); ++c.calls; c.command = command; return true;
        };
        model.levels = {{std::string(root_asset), "Root"}, {"Studio/Example", "Studio", {"EntryA"}, {}, false}};
        model.can_queue_load = true;
        activate(state, model, cb, "select-level", "Studio/Example");
        check(capture.calls == 0 && state.destination == "Studio/Example", "Selecting a detached level must not load it");
        activate(state, model, cb, "load-level", "");
        check(capture.calls == 1 && capture.root == root_asset && capture.destination == "Studio/Example" && capture.spawn == "EntryA", "Detached level uses its sole manifest spawn automatically");
        model.levels.back().native_registered = true;
        activate(state, model, cb, "load-level", "");
        check(capture.calls == 2 && capture.spawn.empty(), "Registered level uses the engine's default spawn without retaining a previous selection");
        check(state.feedback.empty(), "Accepted changes do not display queue diagnostics");
        model.multiplayer.active = true;
        check(!can_load(state, model, cb), "Guest cannot load a level even with an otherwise ready loader");
        const auto guest_page = render(state, model, cb, 0);
        check(std::none_of(guest_page.main.begin(), guest_page.main.end(), [](const auto& row) {
            return row.command == "select-level";
        }), "Guest level choices are visibly locked");
        check(std::none_of(guest_page.side.begin(), guest_page.side.end(), [](const auto& row) {
            return row.command == "load-level";
        }), "Guest load button has no activation delegate");
        activate(state, model, cb, "load-level", "");
        check(capture.calls == 2 && state.feedback == "Only the lobby host can change levels.",
            "A stale level action cannot load after joining a host");
        model.multiplayer.hosting = true;
        check(can_load(state, model, cb), "Host retains level controls");
        model.multiplayer = {};
        check(can_load(state, model, cb), "Level controls return when the host ends the lobby");
        model.multiplayer.lobby_joining = true;
        check(!can_load(state, model, cb), "Joining cannot race a manual level change");
        model.multiplayer = {};
        model.can_queue_load = false;
        activate(state, model, cb, "load-level", "");
        check(capture.calls == 2, "Stale load button cannot queue during transition");
        model.can_queue_load = true;
        model.levels.pop_back();
        activate(state, model, cb, "load-level", "");
        check(capture.calls == 2 && state.destination.empty(), "Removed level selection must not load");
        model.world.map = WorldMap::bam; model.parks.available = true;
        activate(state, model, cb, "park-lot", "financial");
        activate(state, model, cb, "park-family", "");
        activate(state, model, cb, "load-park", "");
        check(capture.command == "park financial flumppark_01", "Selected park targets its own lot");
        const auto calls = capture.calls;
        model.parks.controlled_by_host = true;
        activate(state, model, cb, "load-park", "");
        check(capture.calls == calls, "Host ownership is rechecked on activation");
        activate(state, model, cb, "noclip", "");
        check(capture.calls == calls, "Unavailable debug control cannot queue");
        model.debug.noclip = true;
        activate(state, model, cb, "noclip", "");
        check(capture.debug.action == overlay::DebugAction::set_noclip && !capture.debug.enabled, "Active noclip can always be disabled");
        model.graphics.available = true; model.graphics.ready[0] = true; model.graphics.enabled[0] = false;
        activate(state, model, cb, "graphics", "film_grain");
        check(capture.command == "graphics film_grain 1", "Toggle reads effective authored graphic state");
        model.progression.challenges_enabled = true; model.progression.challenges_hidden = true;
        activate(state, model, cb, "challenges", "");
        check(capture.command == "challenges 1", "Hidden challenges use show command");
        model.world.ready = true; model.world_controls.population_available = true;
        model.world_controls.choices.traffic = 3;
        activate(state, model, cb, "traffic", "");
        check(capture.command == "environment traffic -1", "Population cycles back to authored default");
        const auto parks = render(state, model, cb, parks_section);
        const auto load = std::find_if(parks.side.begin(), parks.side.end(), [](const auto& row) { return row.id == "load-park"; });
        check(load != parks.side.end() && load->command.empty(), "Host-owned park action is visibly unavailable");
        cb.queue_debug = [](void*, const overlay::DebugRequest&, char* result, std::size_t size) {
            std::snprintf(result, size, "Queued for the game update thread."); return true;
        };
        activate(state, model, cb, "noclip", "");
        check(state.feedback.empty(), "Successful callback diagnostics stay out of the menu");
        model.debug.status = "Native callback diagnostic";
        const auto player_page = render(state, model, cb, player_section);
        check(std::none_of(player_page.side.begin(), player_page.side.end(), [](const auto& row) {
            return row.title.find("Native callback") != std::string::npos;
        }), "Debug model status stays out of the player menu");
        const auto find = [](const std::vector<Row>& rows, std::string_view id) {
            return std::find_if(rows.begin(), rows.end(), [&](const auto& row) { return row.id == id; });
        };
        // Hall of Meat sits with the player's other switches.
        const auto meat_row = [&] {
            const auto page = render(state, model, cb, player_section);
            return *find(page.main, "hall-of-meat");
        };
        check(meat_row().title == "Hall of Meat: Off" && meat_row().command.empty(), "Hall of Meat waits until it started");
        model.hall_of_meat = {true, false};
        activate(state, model, cb, "hall-of-meat", "");
        check(meat_row().command == "hall-of-meat" && capture.command == "hallofmeat 1", "Hall of Meat turns on");
        model.hall_of_meat = {true, true};
        activate(state, model, cb, "hall-of-meat", "");
        check(meat_row().title == "Hall of Meat: On" && capture.command == "hallofmeat 0", "and off again");
        model.multiplayer.local_name = "steam_name";
        model.player_card = {true, "Card Name", {}};
        const auto card_page = render(state, model, cb, player_section);
        const auto field = find(card_page.side, "card-name");
        check(field != card_page.side.end() && field->input && field->title == "steam_name" && field->argument == "Card Name",
            "Card name field shows the Steam name as its hint and the saved name as its text");
        check(find(card_page.side, "card-name-reset")->command == "card-name-reset", "A custom card name can be reset");
        model.player_card.custom_name.clear();
        const auto steam_page = render(state, model, cb, player_section);
        check(find(steam_page.side, "card-name-reset")->command.empty(), "Steam name reset is idle without a custom name");
        {
            // Time of day forces one of a map's seven time layers, others off.
            overlay::Model world;
            world.world.available = world.world.ready = true;
            world.world.map = WorldMap::bam;
            world.world.supported.assign(world_layers().size(), true);
            State tod;
            Capture log;
            overlay::CallbacksV3 record;
            record.user = &log;
            record.queue_console_command = [](void* user, const char* command, char*, std::size_t) {
                auto& c = *static_cast<Capture*>(user); ++c.calls; c.command = command; return true;
            };
            check(time_of_day_available(world, record) && time_of_day(world) == 0, "Time of day starts at the level's default");
            activate(tod, world, record, "time-of-day", {});
            check(log.calls == 7 && log.command == "world bam_tod_1_morning on", "Cycling selects Morning last, after the others are off");
            for (unsigned slot = 0; slot < time_of_day_keys.size(); ++slot)
                world.world.choices[time_of_day_layer(WorldMap::bam, slot)] = slot == 4 ? "on" : "off";
            check(time_of_day(world) == 5, "A single forced layer reads back as that time");
            const auto page = render(tod, world, record, 0);
            check(std::any_of(page.side.begin(), page.side.end(), [](const auto& row) { return row.title == "Time of day: Night"; }),
                "The World page shows the current time of day");
            for (unsigned slot = 0; slot < 6; ++slot) activate(tod, world, record, "time-of-day", {});
            world.world.choices[time_of_day_layer(WorldMap::bam, 6)] = "on";
            check(time_of_day(world) == 0, "Two forced times read as no single choice");
            for (auto& choice : world.world.choices) choice = "default";
            world.world.choices[time_of_day_layer(WorldMap::bam, 6)] = "on";
            for (unsigned slot = 0; slot < 6; ++slot) world.world.choices[time_of_day_layer(WorldMap::bam, slot)] = "off";
            log.calls = 0;
            activate(tod, world, record, "time-of-day", {});
            check(log.calls == 7 && log.command.ends_with(" default"), "Cycling past the last time returns all seven to default");
            world.world.controlled_by_host = true;
            log.calls = 0;
            activate(tod, world, record, "time-of-day", {});
            check(log.calls == 0 && !time_of_day_available(world, record), "A host-forced lobby cannot change time of day");
        }
        {
            overlay::Model maps;
            maps.levels = {{std::string(root_asset), "Root"}, {"levels/Game/BAM_LevelRoot/BAM_LevelRoot"},
                {"levels/Game/DingoLevel_Splash/DingoLevel_Splash"}, {"Levels/Custom/Bedroom", "Bedroom"}};
            maps.levels.back().custom = true;
            State split;
            const auto shows = [](const Page& page, std::string_view asset) {
                return std::any_of(page.main.begin(), page.main.end(), [&](const auto& row) { return row.argument == asset; });
            };
            const auto world_page = render(split, maps, cb, world_section), custom_page = render(split, maps, cb, custom_section);
            check(shows(world_page, maps.levels[1].asset) && !shows(world_page, "Levels/Custom/Bedroom"), "World lists only official levels");
            check(shows(custom_page, "Levels/Custom/Bedroom") && !shows(custom_page, maps.levels[1].asset), "Custom Maps lists only mod levels");
            check(!shows(world_page, maps.levels[2].asset) && !shows(custom_page, maps.levels[2].asset), "Splash is never listed");
            activate(split, maps, cb, "select-level", maps.levels[2].asset);
            check(split.destination.empty(), "Splash cannot be selected");
        }
        std::puts("Native ReSkate control checks passed.");
        return 0;
    } catch (const std::exception& e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
}
