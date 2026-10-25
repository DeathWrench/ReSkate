#include "replay_bridge.h"
#include "replay_session.h"
#include "Extension/Console/commands.h"
#include <string>

// ReSkate's replay editor (Extension/ReplayEditor/replay_session.h) from the console. The editor
// itself is a screen; these open and close it and say what it is doing.
namespace dingosdk::console {
void register_replay_editor_commands(Commands &registry) {
    namespace re = replay_editor;
    const auto unavailable = "ReSkate's replay editor is unavailable for this game build.";

    auto status = action("replayeditor status", "What ReSkate's replay editor is doing: the recording it can reach, the "
                         "edit, the camera and any export", Group::graphics);
    status.execution = Execution::local;
    status.run = [](const Model &, const Values &, const Output &out) { out(re::session::status_text()); };
    registry.add(std::move(status));

    auto open = action("replayeditor open", "Open ReSkate's replay editor over the game's (the game's replay editor must "
                       "be open: hold Select, or B on the keyboard)", Group::graphics);
    open.run = [unavailable](const Model &, const Values &, const Output &out) {
        if (!re::session::available()) return out(unavailable);
        re::bridge().ask({re::Request::Kind::take_over});
        out("Opening ReSkate's replay editor.");
    };
    registry.add(std::move(open));

    auto close = action("replayeditor close", "Close ReSkate's replay editor and leave the replay", Group::graphics);
    close.run = [](const Model &, const Values &, const Output &out) {
        re::bridge().ask({re::Request::Kind::leave});
        out("Leaving the replay.");
    };
    registry.add(std::move(close));

    auto game = action("replayeditor game", "Close ReSkate's replay editor and go back to the game's own", Group::graphics);
    game.run = [](const Model &, const Values &, const Output &out) {
        re::bridge().ask({re::Request::Kind::hand_back});
        out("Back to the game's replay editor.");
    };
    registry.add(std::move(game));

    auto automatic = variable("replayeditor auto", "Open ReSkate's replay editor whenever the game's replay editor opens. "
                              "Kept between runs", Group::graphics, argument("on|off", Type::boolean));
    automatic.inspect = [unavailable](const Model &) {
        return boolean_state(re::session::available(), re::bridge().settings().open_with_replay, unavailable);
    };
    automatic.run = [](const Model &, const Values &args, const Output &out) {
        auto settings = re::bridge().settings();
        settings.open_with_replay = std::get<bool>(args[0]);
        re::bridge().set_settings(settings);
        re::save_settings(settings);
        out(settings.open_with_replay ? "ReSkate's replay editor opens with the game's." : "The game's replay editor opens on its own; "
                                                                                           "`replayeditor open` opens ReSkate's over it.");
    };
    automatic.reset = [](const Model &, const Output &out) {
        auto settings = re::bridge().settings();
        settings.open_with_replay = true;
        re::bridge().set_settings(settings);
        re::save_settings(settings);
        out("ReSkate's replay editor opens with the game's.");
    };
    registry.add(std::move(automatic));
}
} // namespace dingosdk::console
