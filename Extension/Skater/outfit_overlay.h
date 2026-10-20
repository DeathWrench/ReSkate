#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

// Items worn over the local skater's outfit, for plugins (reskate.outfit): the way Road Rash wore
// its marks before it became a plugin, as one service every plugin shares. Each
// owner puts an item in a slot of the skater's recipe (by the slot's name: "tattoo_legl", "moles",
// "eyewear"); the skater wears them over the outfit through the game's own recipe copy, and is given
// back to the game while one of its menus is up (the menus change the outfit), when nothing is worn,
// and when a plugin stops. Only the face and skin layers (tattoos, moles) and eyewear, and never a
// paid store item. Others see what the skater wears. Client thread throughout.
namespace dingosdk::outfit_overlay {
// The slots items may go in: a slot's name holds one of these.
bool allowed_slot(std::string_view slot) noexcept;
// `placement`, when given, is written over the item's first parameters (as floats): where a tattoo
// sits. `covers`: it goes over the player's own item in the slot (else only over an empty one).
// Empty when it is taken, otherwise why not.
std::string set(std::string owner, std::string slot, std::string item, std::vector<float> placement, bool covers);
void clear(std::string_view owner, std::string_view slot = {});
// The installed cosmetic whose name ends in `ending` (any case), or empty.
std::string find_item(std::string_view ending);
struct Slot {
    std::string name, item;
    std::vector<float> parameters;
};
// The skater's recipe slots now; empty without a skater.
std::vector<Slot> slots();
// Each client tick.
void tick() noexcept;
std::string status();
}
