#pragma once
#include "Extension/AnimationStudio/anim_core.h"
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// Clips on the local skater's body, for plugins (reskate.animation): Animation Studio's pose
// override (PR 297) without the studio. A clip (anim_core.h's, recorded from the game) replaces the
// body, Hips and every joint below it, blended in and out; the placement joints the game moves the
// skater with are never written, and the board follows the clip only when it recorded one. Other
// players see what is drawn here (the local pose filter). Nothing is hooked until a clip is asked for.
//
// The pose is read on the thread that evaluates animation and written when it goes to the renderer
// (the body physics rebuild the buffer in between); the client thread only hands over what to play.
namespace dingosdk::skater_animation {
using anim_studio::Clip;

// A clip from now on, in place: `speed` times as fast, blended in and out over `blend` seconds,
// once or over and over.
struct Play {
    std::shared_ptr<const Clip> clip;
    float speed{1}, blend{0.15f};
    bool loop{};
};
// A clip the game's own trick plays as, from its takeoff: the clip's air (its takeoff to its
// landing) stretched to the trick's. `trick` is the game's name ("kickflip"); `pop` "", "low",
// "mid" or "high".
struct Replacement {
    std::string trick, pop;
    std::shared_ptr<const Clip> clip;
    float speed{1};
};

// Client thread throughout.
void play(std::optional<Play> clip);
bool playing() noexcept; // a clip of play() has not finished
void set_replacements(std::vector<Replacement> list);
// Records the pose for `seconds` (at most 10); the clip comes from take_recording once done.
bool record(float seconds);
bool recording() noexcept;
std::shared_ptr<const Clip> take_recording();
// The game's name for the trick the skater is doing now, or empty.
std::string current_trick() noexcept;
// Each client tick: the local skater's animation component (0 for none), and whether clips may be
// written now (not while a throwdown or a S.K.A.T.E. game runs).
void tick(std::uintptr_t base, std::uintptr_t component, bool allowed);
std::string status();
}
