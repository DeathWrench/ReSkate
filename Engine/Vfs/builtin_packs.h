#pragma once
#include <filesystem>
#include <span>
#include <string>
#include <vector>

// Game content ReSkate carries itself: packs of game assets built by ReSkate Studio, zipped into
// ReSkate.dll: the FPV drone's model (tools/models/build_drone_pack.py), and Fourth Studio's Board
// Break decks and sounds and Road Rash wounds, which were Thunderstore mods. Nobody installs or
// sees them. Before a merge each is unpacked under Mods/.reskate-builtin/<name> (a dot folder,
// which no mod list shows) when the one embedded differs from what is there, and the catalogue
// merges it after every installed mod, always on (mod_catalog.cpp).
namespace dingosdk::mods {
inline constexpr std::string_view builtin_folder = ".reskate-builtin";
struct BuiltinPack {
    std::string name;                 // as the merge knows it: reskate-builtin-<pack>
    std::filesystem::path directory;  // Mods/.reskate-builtin/<pack>
};
// The packs ReSkate.dll carries, unpacked and current under `mods_root`. ReSkate.dll is the
// module running this when it is loaded (the game); otherwise the copy beside this program (the
// launcher) is opened as data. Never throws; `notes` says what was unpacked or went wrong.
std::vector<BuiltinPack> unpack_builtin_packs(const std::filesystem::path& mods_root,
                                              std::vector<std::string>& notes) noexcept;
// One pack's bytes as ReSkate.dll carries them (builtin_pack_format.h, or a plain zip) unpacked
// into `target`; false with `issue` saying why. For tests and tools: unpack_builtin_packs uses it.
bool unpack_builtin_pack(std::span<const unsigned char> bytes, const std::filesystem::path& target, std::string& issue) noexcept;
// Whether an installed mod (its folder's name) is one a built-in pack replaces: Fourth Studio's
// Board Break pack (and its deprecated first one) and Road Rash, as Thunderstore installs them or
// put in by hand. The launcher moves such a mod to the Recycle Bin, the merge leaves it out
// should it still be there, and the launcher's Thunderstore browser neither lists nor installs it.
bool superseded_by_builtin(std::string_view folder) noexcept;
} // namespace dingosdk::mods
