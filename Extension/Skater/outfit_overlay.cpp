#include "outfit_overlay.h"
#include "Extension/Skater/skater_items.h"
#include "Extension/Customization/local_customization_runtime.h"
#include "Extension/Multiplayer/Hud/game_ui_state.h"
#include "Extension/Skater/no_bail.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Vfs/content_catalogs.h"
#include <Windows.h>
#include <algorithm>
#include <bit>
#include <cmath>
#include <set>
#include <format>
#include <map>
#include <optional>

namespace dingosdk::outfit_overlay {
namespace {
using skater_items::SkaterItems;
using skater_items::lower;
constexpr std::string_view allowed[] = {"tattoo", "moles", "eyewear"};

struct Wanted {
    std::string owner, item;
    std::vector<float> placement;
    bool covers{};
};
struct State {
    std::map<std::string, Wanted> wanted; // by slot name
    std::map<std::string, std::string> found; // installed items by ending
    bool own{}, dirty{}, worn{};
    std::uintptr_t skater{}, component{}, slots_of{};
    std::map<std::string, int> slot_index; // by slot name, for slots_of
    std::optional<skater_items::Feed> feed; // how the game fed the skater before a recipe of ours
    std::set<std::string> ours;          // items we put on
    std::uint64_t given_back{}, menu_seen{}, checked{}, applied{}, last_error{};
    std::string status{"nothing worn"};
};
State& state() {
    static auto* s = new State;
    return *s;
}
bool blank(const std::string& asset) { return asset.empty() || lower(asset).ends_with("_empty"); }
int slot_of(State& s, const SkaterItems& m, std::uintptr_t resource, const std::string& wanted) {
    if (s.slots_of != resource) {
        s.slot_index.clear();
        s.slots_of = resource;
        const auto table = m.ptr(resource, 0x28);
        const auto count = m.count(table, 24, multiplayer::max_cosmetic_slots);
        for (std::size_t i = 0; i < count; ++i) {
            const auto slot = m.ptr(table, i * 24 + 8) & ~std::uintptr_t{4};
            s.slot_index.emplace(lower(m.text(m.ptr(slot, 0x20))), static_cast<int>(i));
        }
    }
    for (const auto& [name, index] : s.slot_index)
        if (name.find(wanted) != std::string::npos) return index;
    return -1;
}
void wear(State& s, const SkaterItems& m, std::uintptr_t skater, std::uint64_t now) {
    const auto component = m.component(skater);
    auto recipe = m.capture(skater);
    const auto resource = m.resource(component);
    bool marked{};
    for (const auto& item : recipe.items) marked |= s.ours.contains(item.asset);
    if (const auto fed = skater_items::feed(m, component); fed.follows_outfit()) {
        SkaterItems::check(!marked || now - s.given_back > 3000, "Waiting for the game to put the outfit back.");
        s.feed = fed;
    } else {
        SkaterItems::check(s.feed && (marked || component == s.component), "The skater does not follow its outfit: left alone.");
    }
    bool changed{}, worn{};
    for (const auto& [slot_name, want] : s.wanted) {
        const int i = slot_of(s, m, resource, slot_name);
        if (i < 0 || static_cast<std::size_t>(i) >= recipe.items.size()) continue;
        auto& slot = recipe.items[static_cast<std::size_t>(i)];
        if (!want.covers && !blank(slot.asset) && !s.ours.contains(slot.asset)) continue; // the player's own stays
        worn = true;
        auto parameters = slot.parameters;
        for (std::size_t k = 0; k < want.placement.size() && k < parameters.size(); ++k) parameters[k] = std::bit_cast<std::uint32_t>(want.placement[k]);
        if (slot.asset == want.item && slot.parameters == parameters) continue;
        slot.asset = want.item;
        slot.parameters = std::move(parameters);
        s.ours.insert(want.item);
        changed = true;
    }
    s.worn = worn;
    if (!changed) return;
    skater_items::apply(m, component, recipe);
    s.own = true;
    s.component = component;
    s.applied = now;
}
void give_back(State& s, const SkaterItems& m, std::uintptr_t skater, std::uint64_t now) {
    const auto component = m.component(skater);
    if (const auto fed = skater_items::feed(m, component); fed.follows_outfit() || s.feed) {
        skater_items::hand_back(m, component, fed.follows_outfit() ? fed : *s.feed);
        s.given_back = now;
    }
    s.own = s.worn = false;
}
}

bool allowed_slot(std::string_view slot) noexcept {
    const auto name = lower(slot);
    return std::any_of(std::begin(allowed), std::end(allowed), [&](std::string_view a) { return name.find(a) != std::string::npos; });
}

std::string set(std::string owner, std::string slot, std::string item, std::vector<float> placement, bool covers) {
    auto& s = state();
    slot = lower(slot);
    if (!allowed_slot(slot)) return "only tattoo, moles and eyewear slots";
    if (const auto taken = s.wanted.find(slot); taken != s.wanted.end() && taken->second.owner != owner) return taken->second.owner + " has that slot";
    if (!content_cache::catalogs().available) return "the paid items are not known yet; try again in a moment";
    if (profile_runtime::reserved_cosmetic(item)) return "that is a paid store item";
    if (placement.size() > 8 || !std::all_of(placement.begin(), placement.end(), [](float v) { return std::isfinite(v) && std::abs(v) <= 100; }))
        return "a placement is at most 8 finite numbers";
    s.wanted[slot] = {std::move(owner), std::move(item), std::move(placement), covers};
    s.dirty = true;
    return {};
}
void clear(std::string_view owner, std::string_view slot) {
    auto& s = state();
    const auto name = lower(slot);
    if (std::erase_if(s.wanted, [&](const auto& w) { return w.second.owner == owner && (name.empty() || w.first == name); })) s.dirty = true;
}
std::string find_item(std::string_view ending) {
    auto& s = state();
    const auto key = lower(ending);
    if (const auto known = s.found.find(key); known != s.found.end()) return known->second;
    NoBailSkater skater;
    if (!no_bail_skater(skater)) return {};
    try {
        auto name = skater_items::installed_item(SkaterItems{skater_items::readable, skater.base}, key);
        if (s.found.size() < 512) s.found.emplace(key, name);
        return name;
    } catch (...) {
        return {};
    }
}
std::vector<Slot> slots() {
    std::vector<Slot> out;
    NoBailSkater skater;
    if (!no_bail_skater(skater)) return out;
    try {
        const SkaterItems m{skater_items::readable, skater.base};
        const auto recipe = m.capture(skater.entity);
        const auto resource = m.resource(m.component(skater.entity));
        const auto table = m.ptr(resource, 0x28);
        const auto count = m.count(table, 24, multiplayer::max_cosmetic_slots);
        for (std::size_t i = 0; i < count; ++i) {
            const auto slot = m.ptr(table, i * 24 + 8) & ~std::uintptr_t{4};
            Slot view{m.text(m.ptr(slot, 0x20)), i < recipe.items.size() ? recipe.items[i].asset : std::string{}, {}};
            if (i < recipe.items.size())
                for (const auto word : recipe.items[i].parameters) view.parameters.push_back(std::bit_cast<float>(word));
            out.push_back(std::move(view));
        }
    } catch (...) {
    }
    return out;
}

void tick() noexcept {
    auto& s = state();
    if (s.wanted.empty() && !s.own) return;
    try {
        NoBailSkater skater;
        if (!no_bail_skater(skater)) {
            // A respawn or a level change: the next skater comes from the profile, with nothing of ours.
            s.skater = s.slots_of = 0;
            s.own = s.worn = false;
            s.feed.reset();
            s.dirty = true;
            return;
        }
        if (skater.entity != s.skater) {
            s.skater = skater.entity;
            s.own = false;
            s.feed.reset();
            s.dirty = true;
        }
        const auto now = GetTickCount64();
        const SkaterItems m{skater_items::readable, skater.base};
        const bool menu = multiplayer::sample_game_ui_state(skater.base).in_menu;
        if (menu) s.menu_seen = now;
        if (s.wanted.empty() || menu) {
            if (s.own) give_back(s, m, skater.entity, now);
            s.status = s.wanted.empty() ? "nothing worn" : "a game menu is up: the outfit is the game's";
            s.dirty = true;
            return;
        }
        // Not before the game has had a second after a menu, nor more than once a second; while worn,
        // a look every 3 s whether the game put its own items over ours.
        if (now - s.given_back < 300 || now - s.menu_seen < 1000 || now - s.applied < 1000 || !(s.dirty || (s.worn && now - s.checked > 3000)))
            return;
        s.checked = now;
        wear(s, m, skater.entity, now);
        s.dirty = false;
        s.status = std::format("{} item(s) worn", s.wanted.size());
    } catch (const std::exception& error) {
        s.status = std::string("waiting: ") + error.what();
    } catch (...) {
    }
}
std::string status() { return state().status; }
}
