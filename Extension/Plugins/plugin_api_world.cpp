#include "plugin_api.h"
#include "plugin_game.h"
#include "lua.h"
#include "lualib.h"
#include <algorithm>
#include <cctype>
#include <charconv>
#include <cmath>
#include <cstring>
#include <span>

// The wider set's game parts of the reskate API: the skater's state, control and save points, the
// HUD, park editor objects, the environment, travel, AI skaters, other players' skaters, nametags,
// voice, chat, throwdowns, music, progress, settings, input binds and full-screen screens. Each
// checks its permission, its arguments and its own rate, and the game (plugin_game.h) does the rest
// under the game's own rules (a session's host, the park editor's limits).
namespace dingosdk::plugins {
namespace {
// ok, or false and why: what most of these return.
int result(lua_State* L, const std::string& why) {
    lua_pushboolean(L, why.empty());
    if (why.empty()) return 1;
    lua_pushlstring(L, why.data(), why.size());
    return 2;
}
// A player by id ("7656...") or a player table ({id = ...}).
std::uint64_t player_of(lua_State* L, int index) {
    std::string id;
    if (lua_istable(L, index)) {
        lua_getfield(L, index, "id");
        id = luaL_checkstring(L, -1);
        lua_pop(L, 1);
    } else id = luaL_checkstring(L, index);
    std::uint64_t value = 0;
    if (std::from_chars(id.data(), id.data() + id.size(), value).ec != std::errc{} || !value) luaL_argerror(L, index, "not a player");
    return value;
}
// A per-second budget; false past it.
bool within(double now, double& second, int& count, int most) {
    if (now - second >= 1000) {
        second = now;
        count = 0;
    }
    return ++count <= most;
}
}

const char* skater_state_name(std::uint32_t state) {
    if (state >= 100 && state < 200) return "riding";
    if (state >= 200 && state < 300) return "air";
    if (state >= 300 && state < 400) return "wipeout";
    if (state >= 400 && state < 500) return "grinding";
    if (state >= 500 && state < 600) return "off_board";
    if (state == 602) return "planted";
    return state ? "other" : "none";
}

struct WorldApi {
    static Game& game(Plugin& plugin) { return plugin.services_.game(); }

    // ---- events.skater -------------------------------------------------------------------------
    static int state(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "events.skater", "reskate.skater.state");
        const auto now = game(plugin).physics_state();
        if (!now) lua_pushnil(L);
        else lua_pushstring(L, skater_state_name(*now));
        return 1;
    }
    // ---- skater.control ------------------------------------------------------------------------
    static int control(lua_State* L, const char* action) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "skater.control", "reskate.skater control");
        if (!within(plugin.services_.now_ms(), plugin.control_second_, plugin.controls_, 4)) return result(L, "asked more than 4 times in a second");
        return result(L, game(plugin).control(action));
    }
    static int noclip(lua_State* L) { return control(L, lua_toboolean(L, 1) ? "noclip_on" : "noclip_off"); }
    static int boost(lua_State* L) {
        const std::string kind = luaL_checkstring(L, 1);
        if (kind == "forward") return control(L, "boost_forward");
        if (kind == "up") return control(L, "boost_up");
        if (kind == "offboard") return control(L, "boost_offboard");
        luaL_argerror(L, 1, "a boost is \"forward\", \"up\" or \"offboard\"");
        return 0;
    }
    static int freeze(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "skater.control", "reskate.skater.freeze");
        if (!within(plugin.services_.now_ms(), plugin.control_second_, plugin.controls_, 4)) return result(L, "asked more than 4 times in a second");
        return result(L, game(plugin).freeze(plugin.id(), lua_toboolean(L, 1)));
    }
    // wipeout(force): the skater bails as from a slam of that force (0.5 to 3); one every 2 s.
    static int wipeout(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "skater.control", "reskate.skater.wipeout");
        const double force = luaL_optnumber(L, 1, 2.5);
        if (!(force >= 0.5 && force <= 3)) luaL_argerror(L, 1, "a wipeout's force is 0.5 to 3");
        const double now = plugin.services_.now_ms();
        if (now - plugin.wipeout_at_ < 2000) return result(L, "one wipeout every 2 s");
        plugin.wipeout_at_ = now;
        return result(L, game(plugin).wipeout(static_cast<float>(force)));
    }
    // skater.xray(on): the x-ray ready (the renderer followed) while on; d:skeleton draws it.
    static int xray(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "overlay", "reskate.skater.xray");
        return result(L, game(plugin).xray(plugin.id(), lua_toboolean(L, 1) != 0));
    }
    // skater.grind_exit(wish): the next pop out of a grind, {side = "toe"|"heel"|"left"|"right",
    // stance = "regular"|"goofy", strength = 0.1 to 1}; nil the game's own exit.
    static int grind_exit(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "skater.control", "reskate.skater.grind_exit");
        if (lua_isnoneornil(L, 1)) return result(L, game(plugin).grind_exit(plugin.id(), std::nullopt));
        luaL_checktype(L, 1, LUA_TTABLE);
        GrindExitWish wish;
        lua_getfield(L, 1, "side");
        wish.side = luaL_checkstring(L, -1);
        lua_pop(L, 1);
        if (wish.side != "toe" && wish.side != "heel" && wish.side != "left" && wish.side != "right")
            luaL_error(L, "a grind exit's side is \"toe\", \"heel\", \"left\" or \"right\"");
        lua_getfield(L, 1, "stance");
        if (!lua_isnil(L, -1)) {
            const std::string stance = luaL_checkstring(L, -1);
            if (stance == "regular") wish.stance = 1;
            else if (stance == "goofy") wish.stance = 2;
            else luaL_error(L, "a stance is \"regular\" or \"goofy\"");
        }
        lua_pop(L, 1);
        lua_getfield(L, 1, "strength");
        if (!lua_isnil(L, -1)) {
            const double strength = luaL_checknumber(L, -1);
            if (!(strength >= 0.1 && strength <= 1)) luaL_error(L, "a grind exit's strength is 0.1 to 1");
            wish.strength = static_cast<float>(strength);
        }
        lua_pop(L, 1);
        return result(L, game(plugin).grind_exit(plugin.id(), std::move(wish)));
    }
    // board.motion(): the board's velocity in the last physics step, or nil.
    static int board_motion(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "skater.read", "reskate.board.motion");
        const auto v = game(plugin).board_velocity();
        if (!v) {
            lua_pushnil(L);
            return 1;
        }
        lua_createtable(L, 0, 1);
        push_position(L, *v);
        lua_setfield(L, -2, "velocity");
        return 1;
    }
    // ---- camera -------------------------------------------------------------------------------------
    static float fov_at(lua_State* L, int index) {
        const double fov = luaL_optnumber(L, index, 0);
        if (!(fov == 0 || (fov >= 10 && fov <= 150))) luaL_argerror(L, index, "a field of view is 10 to 150 degrees (0 or none: the camera's own)");
        return static_cast<float>(fov);
    }
    // look(position, target, fov): the view from position towards target.
    static int camera_look(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "camera", "reskate.camera.look");
        const auto eye = position_of(L, 1, "the camera's position");
        const auto target = position_of(L, 2, "what the camera looks at");
        const float fov = fov_at(L, 3);
        Vec3 back{eye[0] - target[0], eye[1] - target[1], eye[2] - target[2]};
        const float length = std::sqrt(back[0] * back[0] + back[1] * back[1] + back[2] * back[2]);
        if (!(length > 0.01f)) luaL_error(L, "the camera's position and what it looks at are the same point");
        for (auto& v : back) v /= length;
        Vec3 right{back[2], 0, -back[0]};
        const float flat = std::sqrt(right[0] * right[0] + right[2] * right[2]);
        if (flat > 0.001f) {
            right[0] /= flat;
            right[2] /= flat;
        } else right = {1, 0, 0}; // straight up or down
        const Vec3 up{back[1] * right[2] - back[2] * right[1], back[2] * right[0] - back[0] * right[2], back[0] * right[1] - back[1] * right[0]};
        const std::array<float, 16> pose{right[0], right[1], right[2], 0, up[0], up[1], up[2], 0,
                                         back[0], back[1], back[2], 0, eye[0], eye[1], eye[2], 1};
        return result(L, game(plugin).set_camera(plugin.id(), pose, fov));
    }
    // set(position, forward, up, fov): the view from position along forward, `up` giving its roll.
    static int camera_set(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "camera", "reskate.camera.set");
        const auto eye = position_of(L, 1, "the camera's position");
        const auto forward = position_of(L, 2, "the camera's forward");
        const auto up_hint = position_of(L, 3, "the camera's up");
        const float fov = fov_at(L, 4);
        const auto length = [](const Vec3& v) { return std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); };
        const auto cross = [](const Vec3& a, const Vec3& b) {
            return Vec3{a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
        };
        Vec3 back{-forward[0], -forward[1], -forward[2]};
        const float lb = length(back);
        if (!(lb > 1e-4f)) luaL_error(L, "the camera's forward has no length");
        for (auto& v : back) v /= lb;
        auto right = cross(up_hint, back);
        const float lr = length(right);
        if (!(lr > 1e-4f)) luaL_error(L, "the camera's up is along its forward");
        for (auto& v : right) v /= lr;
        const auto up = cross(back, right);
        const std::array<float, 16> pose{right[0], right[1], right[2], 0, up[0], up[1], up[2], 0,
                                         back[0], back[1], back[2], 0, eye[0], eye[1], eye[2], 1};
        return result(L, game(plugin).set_camera(plugin.id(), pose, fov));
    }
    static int camera_follow(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "camera", "reskate.camera.follow");
        if (!within(plugin.services_.now_ms(), plugin.control_second_, plugin.controls_, 4)) return result(L, "asked more than 4 times in a second");
        return result(L, game(plugin).follow_player(plugin.id(), lua_isnoneornil(L, 1) ? 0 : player_of(L, 1)));
    }
    static int camera_release(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "camera", "reskate.camera.release");
        game(plugin).release_camera(plugin.id());
        return 0;
    }
    static int camera_held(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "camera", "reskate.camera.held");
        return result(L, game(plugin).camera_status(plugin.id()));
    }
    static int camera_get(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "camera", "reskate.camera.get");
        const auto view = game(plugin).camera_view();
        if (!view) {
            lua_pushnil(L);
            return 1;
        }
        lua_createtable(L, 0, 3);
        push_position(L, view->position);
        lua_setfield(L, -2, "position");
        push_position(L, view->forward);
        lua_setfield(L, -2, "forward");
        push_position(L, view->right);
        lua_setfield(L, -2, "right");
        push_position(L, view->up);
        lua_setfield(L, -2, "up");
        lua_pushnumber(L, view->fov);
        lua_setfield(L, -2, "fov");
        lua_pushboolean(L, view->free_camera);
        lua_setfield(L, -2, "free");
        return 1;
    }
    // ---- trainer: one save point of the plugin's own -------------------------------------------
    static int set_point(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "trainer", "reskate.trainer.set_point");
        const auto s = plugin.services_.skater();
        if (!s) return result(L, "there is no skater");
        plugin.trainer_point_ = std::pair(s->position, s->heading);
        return result(L, {});
    }
    static int back(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "trainer", "reskate.trainer.back");
        if (!plugin.trainer_point_) return result(L, "no save point is set");
        if (!within(plugin.services_.now_ms(), plugin.teleport_second_, plugin.teleports_, plugin.limits_.teleports_per_second))
            return result(L, "asked more than twice in a second");
        switch (plugin.services_.teleport(plugin.id(), plugin.trainer_point_->first, plugin.trainer_point_->second)) {
        case Teleport::sent: return result(L, {});
        case Teleport::forbidden: return result(L, "the host has turned teleporting off");
        default: return result(L, "teleporting is unavailable now");
        }
    }
    // ---- hud ---------------------------------------------------------------------------------------
    static int hide_hud(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "hud", "reskate.hud.hide");
        game(plugin).hide_hud(plugin.id(), lua_toboolean(L, 1) != 0);
        return 0;
    }
    // hud.corner(hidden): skate.'s bottom left HUD hidden while true; false keeps it ready to hide.
    static int hud_corner(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "hud", "reskate.hud.corner");
        return result(L, game(plugin).hud_corner(plugin.id(), lua_toboolean(L, 1) != 0));
    }
    // time.slow(speed): the game at `speed` (0.05 to 1; 1 or nil gives it back); single player only.
    static int slow(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "game.speed", "reskate.time.slow");
        const double speed = luaL_optnumber(L, 1, 1.0);
        if (!(speed >= 0.05 && speed <= 1)) luaL_argerror(L, 1, "a game speed is 0.05 to 1");
        return result(L, game(plugin).game_speed(plugin.id(), static_cast<float>(speed)));
    }
    static int speed(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "game.speed", "reskate.time.speed");
        lua_pushnumber(L, game(plugin).game_speed_now());
        return 1;
    }
    // ---- world.objects -----------------------------------------------------------------------------
    static int catalog(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.objects", "reskate.objects.catalog");
        const auto items = game(plugin).object_catalog();
        lua_createtable(L, static_cast<int>(items.size()), 0);
        for (std::size_t i = 0; i < items.size(); ++i) {
            lua_createtable(L, 0, 3);
            lua_pushlstring(L, items[i].key.data(), items[i].key.size());
            lua_setfield(L, -2, "key");
            lua_pushlstring(L, items[i].title.data(), items[i].title.size());
            lua_setfield(L, -2, "title");
            lua_pushlstring(L, items[i].category.data(), items[i].category.size());
            lua_setfield(L, -2, "category");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        return 1;
    }
    static int objects(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.objects", "reskate.objects.list");
        const auto list = game(plugin).objects();
        lua_createtable(L, static_cast<int>(list.size()), 0);
        for (std::size_t i = 0; i < list.size(); ++i) {
            const auto& o = list[i];
            lua_createtable(L, 0, 5);
            const auto id = std::to_string(o.id);
            lua_pushlstring(L, id.data(), id.size());
            lua_setfield(L, -2, "id");
            lua_pushlstring(L, o.item.data(), o.item.size());
            lua_setfield(L, -2, "item");
            push_position(L, o.position);
            lua_setfield(L, -2, "position");
            // The heading the pose turns to, as the skater's: about world up.
            const float heading = std::atan2(2 * (o.rotation[3] * o.rotation[1] + o.rotation[0] * o.rotation[2]),
                                             1 - 2 * (o.rotation[1] * o.rotation[1] + o.rotation[0] * o.rotation[0]));
            lua_pushnumber(L, heading);
            lua_setfield(L, -2, "heading");
            lua_pushnumber(L, o.scale);
            lua_setfield(L, -2, "scale");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        return 1;
    }
    static GameObject pose(lua_State* L, int at, int heading_index, int scale_index) {
        GameObject object;
        object.position = position_of(L, at, "the object's position");
        const double heading = luaL_optnumber(L, heading_index, 0);
        if (!std::isfinite(heading)) luaL_argerror(L, heading_index, "a heading is a finite number of radians");
        object.rotation = {0, static_cast<float>(std::sin(heading / 2)), 0, static_cast<float>(std::cos(heading / 2))};
        if (scale_index) {
            const double scale = luaL_optnumber(L, scale_index, 1);
            if (!(scale >= 0.1 && scale <= 10)) luaL_argerror(L, scale_index, "a scale is 0.1 to 10");
            object.scale = static_cast<float>(scale);
        }
        return object;
    }
    static std::uint64_t object_id(lua_State* L, int index) {
        const std::string text = luaL_checkstring(L, index);
        std::uint64_t id = 0;
        if (std::from_chars(text.data(), text.data() + text.size(), id).ec != std::errc{} || !id) luaL_argerror(L, index, "not an object's id");
        return id;
    }
    static int edit(lua_State* L, const char* operation, GameObject object) {
        auto& plugin = plugin_of(L);
        if (!within(plugin.services_.now_ms(), plugin.edit_second_, plugin.edits_, 4)) return result(L, "more than 4 edits in a second");
        return result(L, game(plugin).edit_object(operation, object));
    }
    // ---- world.entities ----------------------------------------------------------------------------
    // set(id, blueprint, transform, hidden?): the plugin's object `id` (1 to 2^31) is an entity of the
    // world object blueprint at the transform, made, moved or taken away by the game a few a frame.
    // A transform is {position = vector, right = vector, up = vector, forward = vector} (axes carry
    // their scale), {position, yaw, pitch, roll (degrees), scale (number or vector)}, or
    // {matrix = {16 numbers}} (rows right, up, forward, position).
    static std::uint32_t entity_id(lua_State* L, int index) {
        const double id = luaL_checknumber(L, index);
        if (!(id >= 1 && id <= 2147483647.0) || id != std::floor(id)) luaL_argerror(L, index, "an object's id is a whole number from 1");
        return static_cast<std::uint32_t>(id);
    }
    static std::array<float, 3> axis_of(lua_State* L, int table, const char* field) {
        lua_getfield(L, table, field);
        const float* v = luaL_checkvector(L, -1);
        std::array<float, 3> result{v[0], v[1], v[2]};
        lua_pop(L, 1);
        return result;
    }
    static std::array<float, 16> transform_of(lua_State* L, int table) {
        luaL_checktype(L, table, LUA_TTABLE);
        std::array<float, 16> m{};
        lua_getfield(L, table, "matrix");
        if (!lua_isnil(L, -1)) {
            luaL_checktype(L, -1, LUA_TTABLE);
            if (lua_objlen(L, -1) != 16) luaL_error(L, "a matrix is 16 numbers");
            for (int i = 0; i < 16; ++i) {
                lua_rawgeti(L, -1, i + 1);
                m[i] = static_cast<float>(luaL_checknumber(L, -1));
                lua_pop(L, 1);
            }
            lua_pop(L, 1);
            return m;
        }
        lua_pop(L, 1);
        lua_getfield(L, table, "position");
        const auto at = position_of(L, -1, "an object's position");
        lua_pop(L, 1);
        lua_getfield(L, table, "right");
        const bool axes = !lua_isnil(L, -1);
        lua_pop(L, 1);
        std::array<float, 3> right{1, 0, 0}, up{0, 1, 0}, forward{0, 0, 1};
        if (axes) {
            right = axis_of(L, table, "right");
            up = axis_of(L, table, "up");
            forward = axis_of(L, table, "forward");
        } else {
            const auto degrees = [&](const char* field) {
                lua_getfield(L, table, field);
                const double value = luaL_optnumber(L, -1, 0);
                lua_pop(L, 1);
                if (!std::isfinite(value)) luaL_error(L, "%s is a finite number of degrees", field);
                return value * 3.14159265358979323846 / 180;
            };
            const double yaw = degrees("yaw"), pitch = degrees("pitch"), roll = degrees("roll");
            // Yaw about up (forward = sin, 0, cos at zero pitch), then pitch about right, then roll
            // about forward, as the game lays out a world object's axes.
            const double cy = std::cos(yaw), sy = std::sin(yaw), cp = std::cos(pitch), sp = std::sin(pitch), cr = std::cos(roll), sr = std::sin(roll);
            const std::array<double, 3> f{sy * cp, sp, cy * cp}, r0{cy, 0, -sy};
            const std::array<double, 3> u0{f[1] * r0[2] - f[2] * r0[1], f[2] * r0[0] - f[0] * r0[2], f[0] * r0[1] - f[1] * r0[0]};
            for (int i = 0; i < 3; ++i) {
                right[i] = static_cast<float>(r0[i] * cr + u0[i] * sr);
                up[i] = static_cast<float>(u0[i] * cr - r0[i] * sr);
                forward[i] = static_cast<float>(f[i]);
            }
            lua_getfield(L, table, "scale");
            std::array<float, 3> scale{1, 1, 1};
            if (lua_isnumber(L, -1)) scale.fill(static_cast<float>(lua_tonumber(L, -1)));
            else if (lua_isvector(L, -1)) {
                const float* v = lua_tovector(L, -1);
                scale = {v[0], v[1], v[2]};
            } else if (!lua_isnil(L, -1)) luaL_error(L, "a scale is a number or a vector");
            lua_pop(L, 1);
            for (int i = 0; i < 3; ++i) right[i] *= scale[0], up[i] *= scale[1], forward[i] *= scale[2];
        }
        for (int i = 0; i < 3; ++i) m[i] = right[i], m[4 + i] = up[i], m[8 + i] = forward[i], m[12 + i] = at[i];
        m[15] = 1;
        return m;
    }
    static int entities_set(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.entities", "reskate.entities.set");
        const auto id = entity_id(L, 1);
        const auto asset = checked_text(L, 2, 200, "a blueprint's name");
        const auto matrix = transform_of(L, 3);
        return result(L, game(plugin).entity_set(plugin.id(), id, asset, matrix, lua_toboolean(L, 4) != 0));
    }
    static int entities_remove(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.entities", "reskate.entities.remove");
        game(plugin).entity_remove(plugin.id(), entity_id(L, 1));
        return 0;
    }
    static int entities_clear(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.entities", "reskate.entities.clear");
        game(plugin).entity_clear(plugin.id());
        return 0;
    }
    static int entities_status(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.entities", "reskate.entities.status");
        static constexpr const char* names[] = {nullptr, "waiting", "loading", "missing", "ready", "hidden"};
        const auto status = game(plugin).entity_status(plugin.id(), entity_id(L, 1));
        if (status <= 0 || status > 5) lua_pushnil(L);
        else lua_pushstring(L, names[status]);
        return 1;
    }
    static int entities_ready(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.entities", "reskate.entities.ready");
        lua_pushboolean(L, game(plugin).entities_ready(plugin.id()));
        return 1;
    }
    static int place(lua_State* L) {
        need(L, plugin_of(L), "world.objects", "reskate.objects.place");
        auto object = pose(L, 2, 3, 4);
        object.item = checked_text(L, 1, 200, "an item's key");
        return edit(L, "place", object);
    }
    // move(id, position, heading?, scale?): what is not given stays as the object has it.
    static int move(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.objects", "reskate.objects.move");
        auto object = pose(L, 2, 3, 4);
        object.id = object_id(L, 1);
        if (lua_isnoneornil(L, 3) || lua_isnoneornil(L, 4))
            for (const auto& existing : game(plugin).objects())
                if (existing.id == object.id) {
                    if (lua_isnoneornil(L, 3)) object.rotation = existing.rotation;
                    if (lua_isnoneornil(L, 4)) object.scale = existing.scale;
                    break;
                }
        return edit(L, "move", object);
    }
    static int remove(lua_State* L) {
        need(L, plugin_of(L), "world.objects", "reskate.objects.remove");
        GameObject object;
        object.id = object_id(L, 1);
        return edit(L, "delete", object);
    }
    // ---- world.environment -----------------------------------------------------------------------
    static int environment(lua_State* L, const char* kind, const std::string& key, const std::string& value) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.environment", "reskate.world's environment");
        if (!within(plugin.services_.now_ms(), plugin.environment_second_, plugin.environments_, 4))
            return result(L, "more than 4 changes in a second");
        return result(L, game(plugin).set_environment(kind, key, value));
    }
    static int set_time(lua_State* L) { return environment(L, "tod", checked_text(L, 1, 20, "a time of day"), {}); }
    static int set_control(lua_State* L) {
        const auto key = checked_text(L, 1, 30, "a world control");
        const double value = luaL_checknumber(L, 2);
        if (!std::isfinite(value)) luaL_argerror(L, 2, "a finite number");
        return environment(L, "control", key, std::to_string(value));
    }
    static int set_park(lua_State* L) { return environment(L, "park", checked_text(L, 1, 30, "a lot"), checked_text(L, 2, 40, "a layout")); }
    // ---- travel ------------------------------------------------------------------------------------
    static int locations(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "travel", "reskate.travel.locations");
        const auto list = game(plugin).destinations();
        lua_createtable(L, static_cast<int>(list.size()), 0);
        for (std::size_t i = 0; i < list.size(); ++i) {
            lua_createtable(L, 0, 3);
            lua_pushlstring(L, list[i].id.data(), list[i].id.size());
            lua_setfield(L, -2, "id");
            lua_pushlstring(L, list[i].name.data(), list[i].name.size());
            lua_setfield(L, -2, "name");
            lua_pushlstring(L, list[i].map.data(), list[i].map.size());
            lua_setfield(L, -2, "map");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        return 1;
    }
    static int levels(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "travel", "reskate.travel.levels");
        const auto list = game(plugin).levels();
        lua_createtable(L, static_cast<int>(list.size()), 0);
        for (std::size_t i = 0; i < list.size(); ++i) {
            lua_createtable(L, 0, 3);
            lua_pushlstring(L, list[i].asset.data(), list[i].asset.size());
            lua_setfield(L, -2, "asset");
            lua_pushlstring(L, list[i].name.data(), list[i].name.size());
            lua_setfield(L, -2, "name");
            lua_pushboolean(L, list[i].can_load);
            lua_setfield(L, -2, "can_load");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        return 1;
    }
    static int travel(lua_State* L, const char* kind) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "travel", "reskate.travel");
        const auto target = checked_text(L, 1, 260, "a destination");
        const double now = plugin.services_.now_ms();
        if (now - plugin.travel_at_ < 5000) return result(L, "one trip every 5 s");
        plugin.travel_at_ = now;
        return result(L, game(plugin).travel(kind, target));
    }
    static int go(lua_State* L) { return travel(L, "location"); }
    static int load(lua_State* L) { return travel(L, "level"); }
    // ---- world.ai -----------------------------------------------------------------------------------
    static int ai_spawn(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.ai", "reskate.ai.spawn");
        const auto count = static_cast<int>(luaL_optinteger(L, 1, 1));
        if (count < 1 || count > 8) luaL_argerror(L, 1, "1 to 8 at a time");
        if (!within(plugin.services_.now_ms(), plugin.control_second_, plugin.controls_, 4)) return result(L, "asked more than 4 times in a second");
        return result(L, game(plugin).ai("spawn", count));
    }
    static int ai_clear(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.ai", "reskate.ai.clear");
        return result(L, game(plugin).ai("clear", 0));
    }
    static int ai_count(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "world.ai", "reskate.ai.count");
        lua_pushinteger(L, game(plugin).ai_count());
        return 1;
    }
    // ---- session.skaters / session.nametags / voice.control -----------------------------------------
    static int skaters(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "session.skaters", "reskate.session.skaters");
        const auto list = game(plugin).peer_skaters();
        lua_createtable(L, static_cast<int>(list.size()), 0);
        for (std::size_t i = 0; i < list.size(); ++i) {
            lua_createtable(L, 0, 4);
            const auto id = std::to_string(list[i].id);
            lua_pushlstring(L, id.data(), id.size());
            lua_setfield(L, -2, "id");
            push_position(L, list[i].position);
            lua_setfield(L, -2, "position");
            lua_pushnumber(L, list[i].heading);
            lua_setfield(L, -2, "heading");
            lua_pushnumber(L, list[i].age_ms);
            lua_setfield(L, -2, "age_ms");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        return 1;
    }
    static int tag(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "session.nametags", "reskate.session.tag");
        const auto player = player_of(L, 1);
        std::string text = lua_isnoneornil(L, 2) ? std::string{} : checked_text(L, 2, 16, "a nametag's tag");
        for (const char c : text)
            if (c < 0x20 || c > 0x7e) luaL_error(L, "a nametag's tag is printable text");
        game(plugin).set_nametag(plugin.id(), player, std::move(text), colour_at(L, 3, 0xffffffff));
        return 0;
    }
    // 0xRRGGBBAA from Lua, as the overlay draws it (IM_COL32: 0xAABBGGRR).
    static std::uint32_t colour_at(lua_State* L, int index, std::uint32_t fallback) {
        if (lua_isnoneornil(L, index)) return fallback;
        const double value = luaL_checknumber(L, index);
        if (!(value >= 0 && value <= 4294967295.0) || value != std::floor(value)) luaL_argerror(L, index, "a colour number is 0xRRGGBBAA");
        const auto rgba = static_cast<std::uint32_t>(value);
        return (rgba >> 24) | ((rgba >> 16) & 0xff) << 8 | ((rgba >> 8) & 0xff) << 16 | (rgba & 0xff) << 24;
    }
    static int voice_volume(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "voice.control", "reskate.voice.set_volume");
        const auto player = player_of(L, 1);
        const double volume = luaL_checknumber(L, 2);
        if (!(volume >= 0 && volume <= 10)) luaL_argerror(L, 2, "a volume is 0 (muted) to 10");
        if (!within(plugin.services_.now_ms(), plugin.voice_second_, plugin.voices_, 10)) return result(L, "more than 10 changes in a second");
        return result(L, game(plugin).voice_volume(player, static_cast<float>(volume)));
    }
    // ---- chat.send ------------------------------------------------------------------------------------
    static int chat_send(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "chat.send", "reskate.chat.send");
        const auto text = checked_text(L, 1, 200, "a chat line");
        if (text.empty() || text.front() == '/') luaL_argerror(L, 1, "a chat line, not empty and not a / command");
        const double now = plugin.services_.now_ms();
        if (now - plugin.chat_at_ < 3000) return result(L, "one line every 3 s");
        plugin.chat_at_ = now;
        return result(L, game(plugin).send_chat(text));
    }
    // A line only this player sees, under the plugin's name: no / commands, 5 a second.
    static int chat_local(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "chat.local", "reskate.chat.notice");
        const auto text = checked_text(L, 1, 200, "a chat line");
        if (text.empty()) luaL_argerror(L, 1, "a chat line, not empty");
        for (const unsigned char c : text)
            if (c < 0x20) luaL_argerror(L, 1, "a chat line is one line of text");
        const auto colour = colour_at(L, 2, 0);
        if (!within(plugin.services_.now_ms(), plugin.local_chat_second_, plugin.local_chats_, 5)) return result(L, "more than 5 lines in a second");
        return result(L, game(plugin).local_chat(plugin.id(), text, colour));
    }
    // ---- skater.animation -----------------------------------------------------------------------------
    static std::size_t pose_bytes(const anim_studio::Clip& clip) { return clip.times.size() * clip.joints * 40 + clip.board.size() * 40; }
    // A clip by its path in the package (an Animation Studio clip file, FAS1 to FAS3), or "rec:<n>".
    static Game::ClipRef clip_at(lua_State* L, Plugin& plugin, int index) {
        const auto name = checked_text(L, index, 200, "a clip");
        if (const auto found = plugin.clips_.find(name); found != plugin.clips_.end()) return found->second;
        if (name.starts_with("rec:")) luaL_error(L, "there is no recording %s", name.c_str());
        std::string error;
        const auto bytes = read_package_file(package_file(L, plugin, name), 8u << 20, error);
        if (bytes.empty()) luaL_error(L, "the clip %s cannot be read: %s", name.c_str(), error.empty() ? "it is empty" : error.c_str());
        // Its size as poses, from the header (magic, joints, frames), before anything is made of it.
        if (bytes.size() >= 12) {
            std::uint32_t joints{}, frames{};
            std::memcpy(&joints, bytes.data() + 4, 4);
            std::memcpy(&frames, bytes.data() + 8, 4);
            if (joints > anim_studio::skeleton_joints) luaL_error(L, "the clip %s has more joints than the skater", name.c_str());
            if (std::uint64_t{joints + 1} * frames * 40 + plugin.clip_bytes_ > plugin.limits_.clip_bytes)
                luaL_error(L, "a plugin's clips hold at most %d MB of poses", static_cast<int>(plugin.limits_.clip_bytes >> 20));
        }
        std::shared_ptr<const anim_studio::Clip> clip;
        try {
            clip = std::make_shared<const anim_studio::Clip>(anim_studio::clip_from_bytes(
                std::span<const std::uint8_t>(reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size())));
        } catch (const std::exception& e) {
            luaL_error(L, "the clip %s is not one: %s", name.c_str(), e.what());
        }
        if (clip->empty()) luaL_error(L, "the clip %s has no frames", name.c_str());
        plugin.clip_bytes_ += pose_bytes(*clip);
        return plugin.clips_.emplace(name, std::move(clip)).first->second;
    }
    static float number_field(lua_State* L, int table, const char* name, float fallback, float least, float most) {
        if (lua_isnoneornil(L, table)) return fallback;
        luaL_checktype(L, table, LUA_TTABLE);
        lua_getfield(L, table, name);
        float value = fallback;
        if (!lua_isnil(L, -1)) {
            const double v = luaL_checknumber(L, -1);
            if (!(v >= least && v <= most)) luaL_error(L, "%s is %g to %g", name, static_cast<double>(least), static_cast<double>(most));
            value = static_cast<float>(v);
        }
        lua_pop(L, 1);
        return value;
    }
    static bool flag_field(lua_State* L, int table, const char* name) {
        if (lua_isnoneornil(L, table)) return false;
        luaL_checktype(L, table, LUA_TTABLE);
        lua_getfield(L, table, name);
        const bool value = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
        return value;
    }
    static Plugin& animating(lua_State* L, const char* what) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "skater.animation", what);
        return plugin;
    }
    // play(clip, {speed, blend, loop}): the clip on the skater's body from now, in place.
    static int animation_play(lua_State* L) {
        auto& plugin = animating(L, "reskate.animation.play");
        auto clip = clip_at(L, plugin, 1);
        const float speed = number_field(L, 2, "speed", 1, 0.1f, 4), blend = number_field(L, 2, "blend", 0.15f, 0, 2);
        const bool loop = flag_field(L, 2, "loop");
        if (!within(plugin.services_.now_ms(), plugin.control_second_, plugin.controls_, 4)) return result(L, "asked more than 4 times in a second");
        return result(L, game(plugin).play_clip(plugin.id(), std::move(clip), speed, blend, loop));
    }
    static int animation_stop(lua_State* L) {
        auto& plugin = animating(L, "reskate.animation.stop");
        game(plugin).stop_clip(plugin.id());
        return 0;
    }
    static int animation_playing(lua_State* L) {
        auto& plugin = animating(L, "reskate.animation.playing");
        lua_pushboolean(L, game(plugin).clip_playing(plugin.id()));
        return 1;
    }
    // replace(trick, clip or nil, {pop, speed}): the game's own trick plays as the clip.
    static int animation_replace(lua_State* L) {
        auto& plugin = animating(L, "reskate.animation.replace");
        auto trick = checked_text(L, 1, 48, "a trick's name");
        for (auto& c : trick) {
            c = static_cast<char>(c >= 'A' && c <= 'Z' ? c + 32 : c);
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == ' ' || c == '-'))
                luaL_argerror(L, 1, "a trick's name is the game's (\"kickflip\", \"ollie\")");
        }
        auto clip = lua_isnoneornil(L, 2) ? Game::ClipRef{} : clip_at(L, plugin, 2);
        std::string pop;
        if (!lua_isnoneornil(L, 3)) {
            luaL_checktype(L, 3, LUA_TTABLE);
            lua_getfield(L, 3, "pop");
            if (!lua_isnil(L, -1)) pop = luaL_checkstring(L, -1);
            lua_pop(L, 1);
            if (pop != "" && pop != "low" && pop != "mid" && pop != "high") luaL_argerror(L, 3, "a pop is \"low\", \"mid\" or \"high\"");
        }
        const float speed = number_field(L, 3, "speed", 1, 0.1f, 4);
        return result(L, game(plugin).replace_trick(plugin.id(), std::move(trick), std::move(pop), std::move(clip), speed));
    }
    // record(seconds): the skater's pose for so long (0.2 to 10 s), as a clip recorded() hands back.
    static int animation_record(lua_State* L) {
        auto& plugin = animating(L, "reskate.animation.record");
        const double seconds = luaL_checknumber(L, 1);
        if (!(seconds >= 0.2 && seconds <= 10)) luaL_argerror(L, 1, "a recording is 0.2 to 10 seconds");
        if (plugin.clip_bytes_ + 10u * 60 * 396 * 40 > plugin.limits_.clip_bytes)
            return result(L, "its clips hold too much already (each recording can be 10 s of poses)");
        return result(L, game(plugin).record_clip(plugin.id(), static_cast<float>(seconds)));
    }
    // The last recording, once it is done, as a clip's name ("rec:1"), or nil.
    static int animation_recorded(lua_State* L) {
        auto& plugin = animating(L, "reskate.animation.recorded");
        auto clip = game(plugin).take_recording(plugin.id());
        if (!clip) {
            lua_pushnil(L);
            return 1;
        }
        const auto name = "rec:" + std::to_string(++plugin.recordings_);
        plugin.clip_bytes_ += pose_bytes(*clip);
        plugin.clips_.emplace(name, std::move(clip));
        lua_pushlstring(L, name.data(), name.size());
        return 1;
    }
    // Lets a clip go (its memory with it); one still playing plays on.
    static int animation_forget(lua_State* L) {
        auto& plugin = animating(L, "reskate.animation.forget");
        const auto name = checked_text(L, 1, 200, "a clip");
        if (const auto found = plugin.clips_.find(name); found != plugin.clips_.end()) {
            plugin.clip_bytes_ -= std::min(plugin.clip_bytes_, pose_bytes(*found->second));
            plugin.clips_.erase(found);
        }
        return 0;
    }
    static int animation_trick(lua_State* L) {
        auto& plugin = animating(L, "reskate.animation.trick");
        const auto name = game(plugin).current_trick();
        if (name.empty()) lua_pushnil(L);
        else lua_pushlstring(L, name.data(), name.size());
        return 1;
    }
    // ---- board: the local skateboard's 16 bones as drawn -----------------------------------------------------
    static int bone_number(lua_State* L, int index) {
        const double b = luaL_checknumber(L, index);
        if (!(b >= 2 && b <= 15) || b != std::floor(b)) luaL_argerror(L, index, "a board's bone is 2 to 15 (0 and 1 place the board)");
        return static_cast<int>(b);
    }
    static std::vector<int> bone_list(lua_State* L, int index) {
        luaL_checktype(L, index, LUA_TTABLE);
        std::vector<int> out;
        const int count = lua_objlen(L, index);
        if (count > 16) luaL_argerror(L, index, "a board has 16 bones");
        for (int i = 1; i <= count; ++i) {
            lua_rawgeti(L, index, i);
            out.push_back(bone_number(L, lua_gettop(L)));
            lua_pop(L, 1);
        }
        return out;
    }
    static std::array<float, 4> quaternion_at(lua_State* L, int index) {
        luaL_checktype(L, index, LUA_TTABLE);
        std::array<float, 4> q{};
        for (int i = 0; i < 4; ++i) {
            lua_rawgeti(L, index, i + 1);
            const double v = luaL_checknumber(L, -1);
            if (!std::isfinite(v)) luaL_error(L, "a rotation is 4 finite numbers {x, y, z, w}");
            q[static_cast<std::size_t>(i)] = static_cast<float>(v);
            lua_pop(L, 1);
        }
        const float n = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
        if (!(n > 1e-4f)) luaL_error(L, "a rotation {x, y, z, w} has a length");
        for (auto& v : q) v /= n;
        return q;
    }
    static void push_quaternion(lua_State* L, const std::array<float, 4>& q) {
        lua_createtable(L, 4, 0);
        for (int i = 0; i < 4; ++i) {
            lua_pushnumber(L, q[static_cast<std::size_t>(i)]);
            lua_rawseti(L, -2, i + 1);
        }
    }
    // bones(): {[0] = {position, rotation = {x, y, z, w}, scale}, ... [15]} as last drawn, or nil.
    static int board_bones(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "board", "reskate.board.bones");
        const auto bones = game(plugin).board_bones();
        if (!bones) {
            lua_pushnil(L);
            return 1;
        }
        lua_createtable(L, 15, 1);
        for (int i = 0; i < 16; ++i) {
            const auto& b = (*bones)[static_cast<std::size_t>(i)];
            lua_createtable(L, 0, 3);
            push_position(L, b.position);
            lua_setfield(L, -2, "position");
            push_quaternion(L, b.rotation);
            lua_setfield(L, -2, "rotation");
            push_position(L, b.scale);
            lua_setfield(L, -2, "scale");
            lua_rawseti(L, -2, i);
        }
        return 1;
    }
    // set(bone, {position, rotation, space = "local" or "world"}).
    static int board_set(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "board", "reskate.board.set");
        const int bone = bone_number(L, 1);
        luaL_checktype(L, 2, LUA_TTABLE);
        Game::BoardBone value;
        lua_getfield(L, 2, "position");
        value.position = position_of(L, lua_gettop(L), "a bone's position");
        lua_pop(L, 1);
        lua_getfield(L, 2, "rotation");
        if (!lua_isnil(L, -1)) value.rotation = quaternion_at(L, lua_gettop(L));
        lua_pop(L, 1);
        lua_getfield(L, 2, "space");
        const std::string space = lua_isnil(L, -1) ? "local" : luaL_checkstring(L, -1);
        lua_pop(L, 1);
        if (space != "local" && space != "world") luaL_argerror(L, 2, "space is \"local\" or \"world\"");
        return result(L, game(plugin).board_set(plugin.id(), bone, value, space == "world"));
    }
    static int board_hide(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "board", "reskate.board.hide");
        return result(L, game(plugin).board_hide(plugin.id(), bone_number(L, 1)));
    }
    static int board_clear(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "board", "reskate.board.clear");
        game(plugin).board_clear(plugin.id(), lua_isnoneornil(L, 1) ? -1 : bone_number(L, 1));
        return 0;
    }
    // park({12, 13, 14, 15}): these bones out of sight on every board, other players' too.
    static int board_park(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "board", "reskate.board.park");
        game(plugin).board_park(plugin.id(), bone_list(L, 1));
        return 0;
    }
    // fit({plates = bool, axle = 0.8 to 1.6}): how every board in the game is fitted, for a deck model
    // that is not the game's own: the baseplates held on the deck, the wheels' spread. fit(nil) ends it.
    static int board_fit(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "board", "reskate.board.fit");
        if (lua_isnoneornil(L, 1)) return result(L, game(plugin).board_fit(plugin.id(), std::nullopt));
        luaL_checktype(L, 1, LUA_TTABLE);
        Game::BoardFit fit;
        lua_getfield(L, 1, "plates");
        fit.plates = lua_toboolean(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 1, "axle");
        if (!lua_isnil(L, -1)) fit.axle = static_cast<float>(luaL_checknumber(L, -1));
        lua_pop(L, 1);
        return result(L, game(plugin).board_fit(plugin.id(), fit));
    }
    // toss({bones}, {velocity, spin, ground}): a piece of the board comes off and falls.
    static int board_toss(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "board", "reskate.board.toss");
        auto bones = bone_list(L, 1);
        luaL_checktype(L, 2, LUA_TTABLE);
        lua_getfield(L, 2, "velocity");
        const auto velocity = position_of(L, lua_gettop(L), "the piece's velocity");
        lua_pop(L, 1);
        lua_getfield(L, 2, "spin");
        const auto spin = lua_isnil(L, -1) ? Vec3{} : position_of(L, lua_gettop(L), "the piece's spin");
        lua_pop(L, 1);
        lua_getfield(L, 2, "ground");
        const double ground = luaL_checknumber(L, -1);
        lua_pop(L, 1);
        if (!within(plugin.services_.now_ms(), plugin.control_second_, plugin.controls_, 4)) return result(L, "asked more than 4 times in a second");
        return result(L, game(plugin).board_toss(plugin.id(), std::move(bones), velocity, spin, static_cast<float>(ground)));
    }
    // ---- outfit ------------------------------------------------------------------------------------------
    // set(slot, item, {placement = {...}, covers = bool}): the item worn over the outfit in that slot.
    static int outfit_set(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "outfit", "reskate.outfit.set");
        const auto slot = checked_text(L, 1, 48, "a slot's name");
        const auto item = checked_text(L, 2, 200, "an item's name");
        // Only the face and skin layers, and eyewear (Extension/Skater/outfit_overlay.h).
        std::string lowered = slot;
        for (auto& c : lowered) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c + 32 : c);
        if (lowered.find("tattoo") == std::string::npos && lowered.find("moles") == std::string::npos && lowered.find("eyewear") == std::string::npos)
            return result(L, "only tattoo, moles and eyewear slots");
        std::vector<float> placement;
        bool covers{};
        if (!lua_isnoneornil(L, 3)) {
            luaL_checktype(L, 3, LUA_TTABLE);
            lua_getfield(L, 3, "covers");
            covers = lua_toboolean(L, -1) != 0;
            lua_pop(L, 1);
            lua_getfield(L, 3, "placement");
            if (!lua_isnil(L, -1)) {
                luaL_checktype(L, -1, LUA_TTABLE);
                const int count = lua_objlen(L, -1);
                if (count > 8) luaL_error(L, "a placement is at most 8 numbers");
                for (int i = 1; i <= count; ++i) {
                    lua_rawgeti(L, -1, i);
                    placement.push_back(static_cast<float>(luaL_checknumber(L, -1)));
                    lua_pop(L, 1);
                }
            }
            lua_pop(L, 1);
        }
        if (!within(plugin.services_.now_ms(), plugin.control_second_, plugin.controls_, 4)) return result(L, "asked more than 4 times in a second");
        return result(L, game(plugin).outfit_set(plugin.id(), slot, item, std::move(placement), covers));
    }
    static int outfit_clear(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "outfit", "reskate.outfit.clear");
        game(plugin).outfit_clear(plugin.id(), lua_isnoneornil(L, 1) ? std::string{} : checked_text(L, 1, 48, "a slot's name"));
        return 0;
    }
    // find(ending): the installed item whose name ends so (any case), or nil.
    static int outfit_find(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "outfit", "reskate.outfit.find");
        const auto name = game(plugin).outfit_find(checked_text(L, 1, 200, "an item's name"));
        if (name.empty()) lua_pushnil(L);
        else lua_pushlstring(L, name.data(), name.size());
        return 1;
    }
    static int outfit_slots(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "outfit", "reskate.outfit.slots");
        const auto slots = game(plugin).outfit_slots();
        lua_createtable(L, static_cast<int>(slots.size()), 0);
        for (std::size_t i = 0; i < slots.size(); ++i) {
            lua_createtable(L, 0, 3);
            lua_pushlstring(L, slots[i].name.data(), slots[i].name.size());
            lua_setfield(L, -2, "slot");
            lua_pushlstring(L, slots[i].item.data(), slots[i].item.size());
            lua_setfield(L, -2, "item");
            lua_createtable(L, static_cast<int>(slots[i].parameters.size()), 0);
            for (std::size_t k = 0; k < slots[i].parameters.size(); ++k) {
                lua_pushnumber(L, std::isfinite(slots[i].parameters[k]) ? slots[i].parameters[k] : 0.0f);
                lua_rawseti(L, -2, static_cast<int>(k + 1));
            }
            lua_setfield(L, -2, "parameters");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        return 1;
    }
    static int outfit_status(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "outfit", "reskate.outfit.status");
        const auto status = game(plugin).outfit_status();
        lua_pushlstring(L, status.data(), status.size());
        return 1;
    }
    // ---- audio --------------------------------------------------------------------------------------------
    static std::shared_ptr<const Wave> wave_at(lua_State* L, Plugin& plugin, const std::string& path) {
        if (const auto found = plugin.waves_.find(path); found != plugin.waves_.end()) return found->second;
        if (plugin.waves_.size() >= plugin.limits_.sounds) luaL_error(L, "a plugin plays at most %d different sounds", static_cast<int>(plugin.limits_.sounds));
        std::string error;
        const auto bytes = read_package_file(package_file(L, plugin, path), 8u << 20, error);
        if (bytes.empty()) luaL_error(L, "the sound %s cannot be read: %s", path.c_str(), error.empty() ? "it is empty" : error.c_str());
        auto wave = decode_wave(std::span<const std::uint8_t>(reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size()), 30, error);
        if (!wave) luaL_error(L, "the sound %s cannot be played: %s", path.c_str(), error.c_str());
        return plugin.waves_.emplace(path, std::move(wave)).first->second;
    }
    // volume, pitch, range, throttle, speed, loop, position (a vector, or "skater").
    static void sound_options(lua_State* L, int index, SoundStart* start, SoundChange* change) {
        if (lua_isnoneornil(L, index)) return;
        luaL_checktype(L, index, LUA_TTABLE);
        const auto number = [&](const char* name, float least, float most, auto&& set) {
            lua_getfield(L, index, name);
            if (!lua_isnil(L, -1)) {
                const double v = luaL_checknumber(L, -1);
                if (!(v >= least && v <= most)) luaL_error(L, "%s is %g to %g", name, static_cast<double>(least), static_cast<double>(most));
                set(static_cast<float>(v));
            }
            lua_pop(L, 1);
        };
        number("volume", 0, 1, [&](float v) { if (start) start->volume = v; else change->volume = v; });
        number("pitch", 0.25f, 4, [&](float v) { if (start) start->pitch = v; else change->pitch = v; });
        number("range", 1, 500, [&](float v) { if (start) start->range = v; else change->range = v; });
        number("throttle", 0, 1, [&](float v) { if (start) start->throttle = v; else change->throttle = v; });
        number("speed", 0, 200, [&](float v) { if (start) start->speed = v; else change->speed = v; });
        if (start) {
            lua_getfield(L, index, "loop");
            start->loop = lua_toboolean(L, -1) != 0;
            lua_pop(L, 1);
        }
        lua_getfield(L, index, "position");
        if (!lua_isnil(L, -1)) {
            std::optional<Vec3> at;
            if (lua_isstring(L, -1) && std::string_view(lua_tostring(L, -1)) == "skater") at = std::nullopt;
            else at = position_of(L, lua_gettop(L), "a sound's position");
            if (start) start->position = at;
            else change->position = at;
        }
        lua_pop(L, 1);
    }
    // play(path or "motor", options): a sound in the game where it is, or at the skater; its id.
    static int audio_play(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "audio", "reskate.audio.play");
        const auto what = checked_text(L, 1, 200, "a sound");
        SoundStart start;
        if (what != "motor") start.wave = wave_at(L, plugin, what);
        sound_options(L, 2, &start, nullptr);
        if (!within(plugin.services_.now_ms(), plugin.wave_second_, plugin.wave_starts_, 20)) return result(L, "more than 20 sounds in a second");
        const auto id = game(plugin).play_sound(plugin.id(), std::move(start));
        if (!id) return result(L, "it plays 8 sounds already, or there is no level");
        lua_pushnumber(L, static_cast<double>(id));
        return 1;
    }
    static std::uint64_t sound_id(lua_State* L, int index) {
        const double id = luaL_checknumber(L, index);
        if (!(id >= 1 && id < 9007199254740992.0) || id != std::floor(id)) luaL_argerror(L, index, "not a sound's id");
        return static_cast<std::uint64_t>(id);
    }
    static int audio_set(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "audio", "reskate.audio.set");
        const auto id = sound_id(L, 1);
        SoundChange change;
        sound_options(L, 2, nullptr, &change);
        lua_pushboolean(L, game(plugin).change_sound(plugin.id(), id, change));
        return 1;
    }
    static int audio_stop(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "audio", "reskate.audio.stop");
        game(plugin).stop_sound(plugin.id(), sound_id(L, 1));
        return 0;
    }
    static int audio_playing(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "audio", "reskate.audio.playing");
        lua_pushboolean(L, game(plugin).sound_playing(plugin.id(), sound_id(L, 1)));
        return 1;
    }
    // ---- server: what only the session's authority does ----------------------------------------------
    static Plugin& authority(lua_State* L, const char* what) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "server", what);
        if (!plugin.services_.authority())
            luaL_error(L, "%s is for the plugin's server copy (reskate.side is \"server\": \"side\" \"server\" or \"both\" in reskate-plugin.json)", what);
        if (!within(plugin.services_.now_ms(), plugin.server_second_, plugin.server_calls_, 20)) luaL_error(L, "more than 20 server calls in a second");
        return plugin;
    }
    static int server_kick(lua_State* L) {
        auto& plugin = authority(L, "reskate.server.kick");
        const auto player = player_of(L, 1);
        const auto why = lua_isnoneornil(L, 2) ? std::string{} : checked_text(L, 2, 120, "why");
        return result(L, game(plugin).kick(player, why));
    }
    static int server_say(lua_State* L) {
        auto& plugin = authority(L, "reskate.server.say");
        const auto text = checked_text(L, 1, 200, "a chat line");
        if (text.empty() || text.front() == '/') luaL_argerror(L, 1, "a chat line, not empty and not a / command");
        const double now = plugin.services_.now_ms();
        if (now - plugin.chat_at_ < 1000) return result(L, "one line a second");
        plugin.chat_at_ = now;
        return result(L, game(plugin).announce(plugin.channel_name(), text));
    }
    static int server_tell(lua_State* L) {
        auto& plugin = authority(L, "reskate.server.tell");
        const auto player = player_of(L, 1);
        const auto text = checked_text(L, 2, 200, "a chat line");
        if (text.empty()) luaL_argerror(L, 2, "a chat line, not empty");
        return result(L, game(plugin).tell(plugin.channel_name(), player, text));
    }
    static int server_move(lua_State* L) {
        auto& plugin = authority(L, "reskate.server.move");
        const auto player = player_of(L, 1);
        return result(L, game(plugin).move_player(player, position_of(L, 2, "where the player goes")));
    }
    static int server_ban(lua_State* L) {
        auto& plugin = authority(L, "reskate.server.ban");
        return result(L, game(plugin).ban(player_of(L, 1)));
    }
    static int server_unban(lua_State* L) {
        auto& plugin = authority(L, "reskate.server.unban");
        return result(L, game(plugin).unban(player_of(L, 1)));
    }
    // A player's permissions: player.permissions is what the server holds for them now, read-only;
    // permissions:clone() is a copy to change; player:apply_permissions(copy) makes it theirs.
    static constexpr std::array<std::pair<const char*, bool Game::Permissions::*>, 6> permission_fields{{
        {"noclip", &Game::Permissions::noclip}, {"nobail", &Game::Permissions::nobail}, {"boosts", &Game::Permissions::boosts},
        {"tuning", &Game::Permissions::tuning}, {"objects", &Game::Permissions::objects}, {"ollies", &Game::Permissions::ollies}}};
    static void push_permissions(lua_State* L, const Game::Permissions& permissions, bool readonly) {
        lua_createtable(L, 0, static_cast<int>(permission_fields.size()));
        for (const auto& [name, field] : permission_fields) {
            lua_pushboolean(L, permissions.*field);
            lua_setfield(L, -2, name);
        }
        lua_getfield(L, LUA_REGISTRYINDEX, "reskate.permissions");
        lua_setmetatable(L, -2);
        if (readonly) lua_setreadonly(L, -1, true);
    }
    // Every permission, each true or false, and nothing else: a clone, so none is left out by mistake.
    static Game::Permissions permissions_of(lua_State* L, int index) {
        luaL_checktype(L, index, LUA_TTABLE);
        Game::Permissions permissions;
        for (const auto& [name, field] : permission_fields) {
            lua_getfield(L, index, name);
            if (!lua_isboolean(L, -1)) luaL_error(L, "permission \"%s\" must be true or false (clone the player's permissions to change them)", name);
            permissions.*field = lua_toboolean(L, -1);
            lua_pop(L, 1);
        }
        lua_pushnil(L);
        while (lua_next(L, index)) {
            const char* key = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : nullptr;
            const bool known = key && std::any_of(permission_fields.begin(), permission_fields.end(),
                                                  [&](const auto& f) { return std::string_view(f.first) == key; });
            if (!known) luaL_error(L, "there is no permission \"%s\"", key ? key : "(not a name)");
            lua_pop(L, 1);
        }
        return permissions;
    }
    static int permissions_clone(lua_State* L) {
        push_permissions(L, permissions_of(L, 1), false);
        return 1;
    }
    static int player_apply_permissions(lua_State* L) {
        auto& plugin = authority(L, "player:apply_permissions");
        const auto player = player_of(L, 1);
        return result(L, game(plugin).apply_permissions(plugin.id(), player, permissions_of(L, 2)));
    }
    // A player table's own names: permissions (read when asked, so always the server's now) and
    // apply_permissions. Anything else a player table does not have is nil.
    static int player_index(lua_State* L) {
        const char* key = lua_type(L, 2) == LUA_TSTRING ? lua_tostring(L, 2) : "";
        if (std::string_view(key) == "apply_permissions") {
            lua_pushcfunction(L, player_apply_permissions, "apply_permissions");
            return 1;
        }
        if (std::string_view(key) != "permissions") return 0;
        auto& plugin = authority(L, "player.permissions");
        const auto permissions = game(plugin).permissions(player_of(L, 1));
        if (!permissions) return 0;
        push_permissions(L, *permissions, true);
        return 1;
    }
    // ---- throwdowns -------------------------------------------------------------------------------------
    // host(mode, players, {max}): a drop where the skater stands for these players ("jam",
    // "spot_battle" or "skate"); it starts once they all join. One every 5 s.
    static int throwdown_host(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "throwdowns", "reskate.throwdowns.host");
        const std::string mode = luaL_checkstring(L, 1);
        const char* series = mode == "jam" || mode == "JamSession" ? "JamSession"
                           : mode == "spot_battle" || mode == "SpotBattle" ? "SpotBattle"
                           : mode == "skate" || mode == "ThrowdownSkate" ? "ThrowdownSkate" : nullptr;
        if (!series) luaL_argerror(L, 1, "a throwdown is \"jam\", \"spot_battle\" or \"skate\"");
        luaL_checktype(L, 2, LUA_TTABLE);
        std::vector<std::uint64_t> players;
        const int count = lua_objlen(L, 2);
        if (count < 1 || count > 7) luaL_argerror(L, 2, "a drop is for 1 to 7 other players");
        for (int i = 1; i <= count; ++i) {
            lua_rawgeti(L, 2, i);
            const auto player = player_of(L, lua_gettop(L));
            lua_pop(L, 1);
            if (std::find(players.begin(), players.end(), player) == players.end()) players.push_back(player);
        }
        int most = 0;
        if (!lua_isnoneornil(L, 3)) {
            luaL_checktype(L, 3, LUA_TTABLE);
            lua_getfield(L, 3, "max");
            if (!lua_isnil(L, -1)) most = static_cast<int>(luaL_checkinteger(L, -1));
            lua_pop(L, 1);
            if (most != 0 && (most < 2 || most > 8)) luaL_argerror(L, 3, "max is 2 to 8 players");
        }
        const double now = plugin.services_.now_ms();
        if (now - plugin.host_at_ < 5000) return result(L, "one drop every 5 s");
        plugin.host_at_ = now;
        return result(L, game(plugin).host_throwdown(plugin.id(), series, std::move(players), most));
    }
    static int throwdown_cancel(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "throwdowns", "reskate.throwdowns.cancel");
        game(plugin).cancel_throwdown(plugin.id());
        return 0;
    }
    static int throwdown_hosting(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "throwdowns", "reskate.throwdowns.hosting");
        const auto status = game(plugin).throwdown_status(plugin.id());
        if (status.empty()) lua_pushnil(L);
        else lua_pushlstring(L, status.data(), status.size());
        return 1;
    }
    // mode{id, name, description, art, color, card, replaces, order, flag, cursor_height,
    // players = {min, max, default}}: the mode's card on the Throwdowns page (cloned from the stock
    // `card`: "skate", "spot" or "jam") and its native flag's preview prefab; cursor_height (metres)
    // lets its flag's placement cursor rise onto anything that high. Its setup page is the plugin's
    // `setup` document (throwdowns.ui). Again with the same id updates it.
    static int int_field(lua_State* L, int table, const char* name, int fallback) {
        lua_getfield(L, table, name);
        const int value = lua_isnil(L, -1) ? fallback : static_cast<int>(luaL_checkinteger(L, -1));
        lua_pop(L, 1);
        return value;
    }
    static std::string text_field(lua_State* L, int table, const char* name) {
        lua_getfield(L, table, name);
        std::string value;
        if (!lua_isnil(L, -1)) {
            if (!lua_isstring(L, -1)) luaL_error(L, "%s is a string", name);
            value = lua_tostring(L, -1);
        }
        lua_pop(L, 1);
        return value;
    }
    static int throwdown_mode(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "throwdowns", "reskate.throwdowns.mode");
        luaL_checktype(L, 1, LUA_TTABLE);
        ThrowdownMode mode;
        mode.id = text_field(L, 1, "id");
        mode.name = text_field(L, 1, "name");
        mode.description = text_field(L, 1, "description");
        mode.art = text_field(L, 1, "art");
        mode.flag = text_field(L, 1, "flag");
        mode.replaces = text_field(L, 1, "replaces");
        mode.card = text_field(L, 1, "card");
        if (mode.card.empty()) mode.card = "spot";
        mode.order = int_field(L, 1, "order", 0);
        lua_getfield(L, 1, "color");
        if (lua_isnumber(L, -1)) {
            const double c = lua_tonumber(L, -1);
            if (!(c >= 0 && c <= 4294967295.0)) luaL_argerror(L, 1, "color is 0xAABBGGRR");
            mode.color = static_cast<std::uint32_t>(c);
        }
        lua_pop(L, 1);
        lua_getfield(L, 1, "cursor_height");
        if (!lua_isnil(L, -1)) {
            const double h = luaL_checknumber(L, -1);
            if (!(h >= 0 && h <= 100000)) luaL_argerror(L, 1, "cursor_height is 0 to 100000 metres");
            mode.cursor_height = static_cast<float>(h);
        }
        lua_pop(L, 1);
        const auto stock = [](const std::string& tile) { return tile == "skate" || tile == "spot" || tile == "spot_battle" || tile == "jam"; };
        if (!mode.replaces.empty() && !stock(mode.replaces)) luaL_argerror(L, 1, "replaces is \"skate\", \"spot\" or \"jam\"");
        if (!stock(mode.card)) luaL_argerror(L, 1, "card is \"skate\", \"spot\" or \"jam\"");
        if (mode.flag.size() > 256 || mode.art.size() > 256) luaL_argerror(L, 1, "art and flag are at most 256 characters");
        // An asset path: letters, digits, _ - . and /.
        for (const char c : mode.flag)
            if (!std::isalnum(static_cast<unsigned char>(c)) && c != '_' && c != '/' && c != '-' && c != '.')
                luaL_argerror(L, 1, "flag is an asset path: letters, digits, _, -, . and /");
        lua_getfield(L, 1, "players");
        if (!lua_isnil(L, -1)) {
            luaL_checktype(L, -1, LUA_TTABLE);
            const int at = lua_gettop(L);
            mode.min_players = int_field(L, at, "min", 1);
            mode.max_players = int_field(L, at, "max", 6);
            mode.players = int_field(L, at, "default", std::min(4, mode.max_players));
        }
        lua_pop(L, 1);
        return result(L, game(plugin).set_throwdown_mode(plugin.id(), mode));
    }
    static int throwdown_remove_mode(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "throwdowns", "reskate.throwdowns.remove_mode");
        game(plugin).remove_throwdown_mode(plugin.id(), luaL_checkstring(L, 1));
        return 0;
    }
    static int throwdown_state(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "throwdowns", "reskate.throwdowns.state");
        const auto t = game(plugin).throwdowns();
        lua_createtable(L, 0, 3);
        lua_pushboolean(L, t.active);
        lua_setfield(L, -2, "active");
        lua_pushboolean(L, t.host);
        lua_setfield(L, -2, "host");
        lua_createtable(L, static_cast<int>(t.skate.size()), 0);
        for (std::size_t i = 0; i < t.skate.size(); ++i) {
            lua_createtable(L, 0, 4);
            lua_pushlstring(L, t.skate[i].name.data(), t.skate[i].name.size());
            lua_setfield(L, -2, "name");
            lua_pushinteger(L, t.skate[i].letters);
            lua_setfield(L, -2, "letters");
            lua_pushboolean(L, t.skate[i].up);
            lua_setfield(L, -2, "up");
            lua_pushboolean(L, t.skate[i].out);
            lua_setfield(L, -2, "out");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        lua_setfield(L, -2, "skate");
        return 1;
    }
    // ---- music -------------------------------------------------------------------------------------------
    static void push_track(lua_State* L, const Track& t) {
        lua_createtable(L, 0, 5);
        lua_pushlstring(L, t.app.data(), t.app.size());
        lua_setfield(L, -2, "app");
        lua_pushlstring(L, t.title.data(), t.title.size());
        lua_setfield(L, -2, "title");
        lua_pushlstring(L, t.artist.data(), t.artist.size());
        lua_setfield(L, -2, "artist");
        lua_pushlstring(L, t.album.data(), t.album.size());
        lua_setfield(L, -2, "album");
        lua_pushboolean(L, t.playing);
        lua_setfield(L, -2, "playing");
    }
    static int current(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "music", "reskate.music.current");
        const auto t = game(plugin).track();
        if (!t.available) lua_pushnil(L);
        else push_track(L, t);
        return 1;
    }
    static int music(lua_State* L, const char* command) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "music", "reskate.music");
        if (!within(plugin.services_.now_ms(), plugin.music_second_, plugin.musics_, 2)) return result(L, "more than 2 a second");
        return result(L, game(plugin).music(command));
    }
    static int play(lua_State* L) { return music(L, "play"); }
    static int pause(lua_State* L) { return music(L, "pause"); }
    static int next(lua_State* L) { return music(L, "next"); }
    // The game's own soundtrack: what it plays on the player's headphones, and a skip.
    static int game_current(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "music", "reskate.music.game");
        const auto t = game(plugin).game_track();
        if (!t) lua_pushnil(L);
        else push_track(L, *t);
        return 1;
    }
    static int game_next(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "music", "reskate.music.game_next");
        if (!within(plugin.services_.now_ms(), plugin.music_second_, plugin.musics_, 2)) return result(L, "asked more than twice in a second");
        return result(L, game(plugin).game_music("next"));
    }
    static int previous(lua_State* L) { return music(L, "previous"); }
    // ---- progression.read / settings.read -------------------------------------------------------------
    static int progress(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "progression.read", "reskate.progression.get");
        const auto p = game(plugin).progress();
        if (!p.available) {
            lua_pushnil(L);
            return 1;
        }
        lua_createtable(L, 0, 5);
        lua_createtable(L, static_cast<int>(p.districts.size()), 0);
        for (std::size_t i = 0; i < p.districts.size(); ++i) {
            lua_createtable(L, 0, 3);
            lua_pushlstring(L, p.districts[i].id.data(), p.districts[i].id.size());
            lua_setfield(L, -2, "id");
            lua_pushlstring(L, p.districts[i].name.data(), p.districts[i].name.size());
            lua_setfield(L, -2, "name");
            lua_pushinteger(L, p.districts[i].rank);
            lua_setfield(L, -2, "rank");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        lua_setfield(L, -2, "districts");
        lua_createtable(L, static_cast<int>(p.challenges.size()), 0);
        for (std::size_t i = 0; i < p.challenges.size(); ++i) {
            const auto& c = p.challenges[i];
            lua_createtable(L, 0, 6);
            lua_pushlstring(L, c.id.data(), c.id.size());
            lua_setfield(L, -2, "id");
            lua_pushlstring(L, c.type.data(), c.type.size());
            lua_setfield(L, -2, "type");
            lua_pushlstring(L, c.neighborhood.data(), c.neighborhood.size());
            lua_setfield(L, -2, "neighborhood");
            lua_pushinteger(L, c.attempts);
            lua_setfield(L, -2, "attempts");
            lua_pushinteger(L, c.completed_goals);
            lua_setfield(L, -2, "completed_goals");
            lua_pushinteger(L, c.goal_count);
            lua_setfield(L, -2, "goal_count");
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        lua_setfield(L, -2, "challenges");
        lua_pushnumber(L, p.score);
        lua_setfield(L, -2, "score");
        lua_pushnumber(L, p.score_cap);
        lua_setfield(L, -2, "score_cap");
        lua_pushinteger(L, p.score_level);
        lua_setfield(L, -2, "score_level");
        return 1;
    }
    static int setting(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "settings.read", "reskate.settings.game");
        const auto value = game(plugin).setting(checked_text(L, 1, 120, "a setting's name"));
        if (value) lua_pushlstring(L, value->data(), value->size());
        else lua_pushnil(L);
        return 1;
    }
    static int setting_names(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "settings.read", "reskate.settings.names");
        const auto names = game(plugin).setting_names();
        lua_createtable(L, static_cast<int>(names.size()), 0);
        for (std::size_t i = 0; i < names.size(); ++i) {
            lua_pushlstring(L, names[i].data(), names[i].size());
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        return 1;
    }
    // ---- input -------------------------------------------------------------------------------------------
    // bind(action, "F7" | "Ctrl+K" | "Pad.LB+Pad.RB"): the "action" event names it on each press,
    // while the game itself has the input (no menu, console or text box open).
    static int bind(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "input", "reskate.input.bind");
        const auto action = checked_text(L, 1, 48, "an action's name");
        const auto key = checked_text(L, 2, 60, "a key");
        if (action.empty()) luaL_argerror(L, 1, "an action needs a name");
        const auto combo = combo_of(key);
        if (!combo) luaL_error(L, "\"%s\" is not a key: 0-9, A-Z, Space, F1-F12 with Ctrl, Shift or Alt; or Pad.A, Pad.LB+Pad.RB...", key.c_str());
        if (!plugin.binds_.contains(action) && plugin.binds_.size() >= 16) luaL_error(L, "at most 16 actions");
        if (const auto why = game(plugin).bind(plugin.id(), action, combo); !why.empty()) return result(L, why);
        plugin.binds_.insert(action);
        return result(L, {});
    }
    static int input_flight(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "input", "reskate.input.flight");
        const auto in = game(plugin).flight_input(plugin.id());
        if (!in) {
            lua_pushnil(L);
            return 1;
        }
        lua_createtable(L, 0, 6);
        const std::pair<const char*, float> fields[] = {{"right", in->right}, {"up", in->up}, {"forward", in->forward},
                                                         {"look_x", in->look_x}, {"look_y", in->look_y}};
        for (const auto& [name, value] : fields) {
            lua_pushnumber(L, value);
            lua_setfield(L, -2, name);
        }
        lua_pushboolean(L, in->boost);
        lua_setfield(L, -2, "boost");
        return 1;
    }
    static void push_buttons(lua_State* L, std::uint32_t bits, const std::pair<const char*, std::uint32_t>* names, std::size_t count) {
        lua_createtable(L, 0, static_cast<int>(count));
        for (std::size_t i = 0; i < count; ++i) {
            lua_pushboolean(L, (bits & names[i].second) != 0);
            lua_setfield(L, -2, names[i].first);
        }
    }
    static int input_gamepad(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "input", "reskate.input.gamepad");
        const auto pad = game(plugin).gamepad();
        if (!pad) {
            lua_pushnil(L);
            return 1;
        }
        lua_createtable(L, 0, 10);
        const std::pair<const char*, float> axes[] = {{"left_x", pad->left_x}, {"left_y", pad->left_y}, {"right_x", pad->right_x},
                                                       {"right_y", pad->right_y}, {"left_trigger", pad->left_trigger}, {"right_trigger", pad->right_trigger}};
        for (const auto& [name, value] : axes) {
            lua_pushnumber(L, value);
            lua_setfield(L, -2, name);
        }
        // XInput's button bits.
        static constexpr std::pair<const char*, std::uint32_t> names[] = {
            {"up", 0x1}, {"down", 0x2}, {"left", 0x4}, {"right", 0x8}, {"start", 0x10}, {"back", 0x20}, {"left_stick", 0x40},
            {"right_stick", 0x80}, {"lb", 0x100}, {"rb", 0x200}, {"a", 0x1000}, {"b", 0x2000}, {"x", 0x4000}, {"y", 0x8000}};
        push_buttons(L, pad->buttons, names, std::size(names));
        lua_setfield(L, -2, "buttons");
        lua_pushboolean(L, pad->playstation);
        lua_setfield(L, -2, "playstation");
        return 1;
    }
    static int input_joystick(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "input", "reskate.input.joystick");
        const auto stick = game(plugin).joystick();
        if (!stick) {
            lua_pushnil(L);
            return 1;
        }
        lua_createtable(L, 0, 3);
        lua_createtable(L, 6, 0);
        for (int i = 0; i < 6; ++i) {
            lua_pushnumber(L, stick->axes[static_cast<std::size_t>(i)]);
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "axes");
        lua_createtable(L, 32, 0);
        for (int i = 0; i < 32; ++i) {
            lua_pushboolean(L, (stick->buttons >> i) & 1);
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "buttons");
        lua_pushlstring(L, stick->name.data(), stick->name.size());
        lua_setfield(L, -2, "name");
        return 1;
    }
    static int input_capture(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "input", "reskate.input.capture");
        return result(L, game(plugin).capture_input(plugin.id(), lua_toboolean(L, 1) != 0));
    }
    // input.hide({left_trigger = true, right_trigger = true, left_x = "grinding"}): those kept from the
    // game while asked; nil or {} gives them back.
    static int input_hide(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "input", "reskate.input.hide");
        bool lt{}, rt{}, left_x{};
        if (!lua_isnoneornil(L, 1)) {
            luaL_checktype(L, 1, LUA_TTABLE);
            lua_getfield(L, 1, "left_trigger");
            lt = lua_toboolean(L, -1) != 0;
            lua_getfield(L, 1, "right_trigger");
            rt = lua_toboolean(L, -1) != 0;
            lua_getfield(L, 1, "left_x");
            if (!lua_isnil(L, -1)) {
                if (lua_type(L, -1) != LUA_TSTRING || std::string_view(lua_tostring(L, -1)) != "grinding")
                    luaL_error(L, "left_x is hidden only while grinding: left_x = \"grinding\"");
                left_x = true;
            }
            lua_pop(L, 3);
        }
        return result(L, game(plugin).hide_pad(plugin.id(), lt, rt, left_x));
    }
    // ---- ui.screen ---------------------------------------------------------------------------------------
    // screen(title, build): a full-screen screen, drawn while open() has it open; Esc closes it.
    static int screen(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "ui.screen", "reskate.ui.screen");
        std::size_t length = 0;
        const char* text = luaL_checklstring(L, 1, &length);
        const std::string title(text, length);
        luaL_checktype(L, 2, LUA_TFUNCTION);
        if (title.empty() || title.size() > 40) luaL_argerror(L, 1, "a screen's title is 1 to 40 characters");
        if (plugin.screens_.size() >= 4) luaL_error(L, "at most 4 screens");
        for (const auto& entry : plugin.screens_)
            if (entry.title == title) luaL_error(L, "the screen \"%s\" is there already", title.c_str());
        lua_pushvalue(L, 2);
        plugin.screens_.push_back({title, lua_ref(L, -1)});
        lua_pop(L, 1);
        return 0;
    }
    static int open(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "ui.screen", "reskate.ui.open");
        const std::string title = luaL_checkstring(L, 1);
        if (std::none_of(plugin.screens_.begin(), plugin.screens_.end(), [&](const auto& e) { return e.title == title; }))
            luaL_error(L, "there is no screen \"%s\"", title.c_str());
        plugin.open_screen_ = title;
        return 0;
    }
    static int close(lua_State* L) {
        auto& plugin = plugin_of(L);
        need(L, plugin, "ui.screen", "reskate.ui.close");
        plugin.open_screen_.clear();
        return 0;
    }

    static void install(Plugin& plugin, lua_State* L);
};

void install_world_api(Plugin& plugin, lua_State* L) { WorldApi::install(plugin, L); }

void WorldApi::install(Plugin& plugin, lua_State* L) {
    (void)plugin;
    // The metatables of player tables (push_player) and of permissions; their own stay hidden.
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, player_index, "player");
    lua_setfield(L, -2, "__index");
    lua_pushstring(L, "locked");
    lua_setfield(L, -2, "__metatable");
    lua_setfield(L, LUA_REGISTRYINDEX, "reskate.player");
    lua_createtable(L, 0, 2);
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, permissions_clone, "clone");
    lua_setfield(L, -2, "clone");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "__index");
    lua_pushstring(L, "locked");
    lua_setfield(L, -2, "__metatable");
    lua_setfield(L, LUA_REGISTRYINDEX, "reskate.permissions");
    add_functions(L, "skater", {{"state", state}, {"noclip", noclip}, {"boost", boost}, {"freeze", freeze}, {"wipeout", wipeout}, {"xray", xray},
                                {"grind_exit", grind_exit}});
    add_functions(L, "board", {{"motion", board_motion}, {"bones", board_bones}, {"set", board_set}, {"hide", board_hide}, {"clear", board_clear},
                               {"park", board_park}, {"fit", board_fit}, {"toss", board_toss}});
    add_functions(L, "camera", {{"look", camera_look}, {"set", camera_set}, {"follow", camera_follow}, {"release", camera_release}, {"held", camera_held}, {"get", camera_get}});
    add_functions(L, "trainer", {{"set_point", set_point}, {"back", back}});
    add_functions(L, "hud", {{"hide", hide_hud}, {"corner", hud_corner}});
    add_functions(L, "time", {{"slow", slow}, {"speed", speed}});
    add_functions(L, "objects", {{"catalog", catalog}, {"list", objects}, {"place", place}, {"move", move}, {"remove", remove}});
    add_functions(L, "entities", {{"set", entities_set}, {"remove", entities_remove}, {"clear", entities_clear}, {"status", entities_status},
                                  {"ready", entities_ready}});
    add_functions(L, "world", {{"set_time", set_time}, {"set_control", set_control}, {"set_park", set_park}});
    add_functions(L, "travel", {{"locations", locations}, {"levels", levels}, {"go", go}, {"load", load}});
    add_functions(L, "ai", {{"spawn", ai_spawn}, {"clear", ai_clear}, {"count", ai_count}});
    add_functions(L, "session", {{"skaters", skaters}, {"tag", tag}});
    add_functions(L, "voice", {{"set_volume", voice_volume}});
    add_functions(L, "chat", {{"send", chat_send}, {"notice", chat_local}});
    add_functions(L, "animation", {{"play", animation_play}, {"stop", animation_stop}, {"playing", animation_playing}, {"replace", animation_replace},
                                   {"record", animation_record}, {"recorded", animation_recorded}, {"forget", animation_forget}, {"trick", animation_trick}});
    add_functions(L, "outfit", {{"set", outfit_set}, {"clear", outfit_clear}, {"find", outfit_find}, {"slots", outfit_slots}, {"status", outfit_status}});
    add_functions(L, "audio", {{"play", audio_play}, {"set", audio_set}, {"stop", audio_stop}, {"playing", audio_playing}});
    add_functions(L, "server", {{"kick", server_kick}, {"say", server_say}, {"tell", server_tell}, {"move", server_move},
                                {"ban", server_ban}, {"unban", server_unban}});
    add_functions(L, "throwdowns", {{"state", throwdown_state}, {"host", throwdown_host}, {"cancel", throwdown_cancel}, {"hosting", throwdown_hosting},
                                    {"mode", throwdown_mode}, {"remove_mode", throwdown_remove_mode}});
    add_functions(L, "music", {{"current", current}, {"play", play}, {"pause", pause}, {"next", next}, {"previous", previous},
                               {"game", game_current}, {"game_next", game_next}});
    add_functions(L, "progression", {{"get", progress}});
    add_functions(L, "settings", {{"game", setting}, {"names", setting_names}});
    add_functions(L, "input", {{"bind", bind}, {"flight", input_flight}, {"gamepad", input_gamepad}, {"joystick", input_joystick}, {"capture", input_capture},
                               {"hide", input_hide}});
    add_functions(L, "ui", {{"screen", screen}, {"open", open}, {"close", close}});
}

std::uint32_t combo_of(std::string_view name) {
    constexpr std::array<std::pair<std::string_view, std::uint32_t>, 16> pad{{
        {"up", 0x1}, {"down", 0x2}, {"left", 0x4}, {"right", 0x8}, {"start", 0x10}, {"back", 0x20}, {"l3", 0x40}, {"r3", 0x80},
        {"lb", 0x100}, {"rb", 0x200}, {"a", 0x1000}, {"b", 0x2000}, {"x", 0x4000}, {"y", 0x8000}, {"lt", 0x10000}, {"rt", 0x20000},
    }};
    std::array<std::uint64_t, 4> keys{};
    std::uint32_t buttons = 0;
    bool keyboard = false, controller = false;
    std::size_t start = 0;
    while (start <= name.size()) {
        const auto end = std::min(name.find('+', start), name.size());
        std::string part(name.substr(start, end - start));
        for (auto& c : part) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
        start = end + 1;
        if (part.starts_with("pad.")) {
            const auto button = std::string_view(part).substr(4);
            const auto found = std::find_if(pad.begin(), pad.end(), [&](const auto& p) { return p.first == button; });
            if (found == pad.end()) return 0;
            buttons |= found->second;
            controller = true;
            continue;
        }
        unsigned key = 0;
        if (part == "ctrl") key = 0x11;
        else if (part == "shift") key = 0x10;
        else if (part == "alt") key = 0x12;
        else if (part == "space") key = 0x20;
        else if (part.size() == 1 && ((part[0] >= 'a' && part[0] <= 'z') || (part[0] >= '0' && part[0] <= '9')))
            key = part[0] >= 'a' ? static_cast<unsigned>(part[0] - 32) : static_cast<unsigned>(part[0]);
        else if (part.size() >= 2 && part[0] == 'f') {
            unsigned n = 0;
            if (std::from_chars(part.data() + 1, part.data() + part.size(), n).ec != std::errc{} || n < 1 || n > 12) return 0;
            key = 0x70 + n - 1;
        } else return 0;
        keys[key / 64] |= std::uint64_t{1} << (key % 64);
        keyboard = true;
    }
    if (keyboard == controller) return 0; // a key or a pad combo, not both, and not nothing
    if (controller) return buttons;
    std::uint32_t value = 0x40000000u; // as controller_bindings.h's keyboard_binding_from_keys
    unsigned count = 0;
    const auto id_of = [](unsigned key) -> unsigned {
        if (key >= '0' && key <= '9') return key - '0' + 1;
        if (key >= 'A' && key <= 'Z') return key - 'A' + 11;
        if (key == 0x20) return 37;
        if (key >= 0x70 && key <= 0x7b) return key - 0x70 + 38;
        if (key == 0x11) return 50;
        if (key == 0x10) return 51;
        if (key == 0x12) return 52;
        return 0;
    };
    unsigned single = 0;
    for (unsigned key = 0; key < 256; ++key) {
        if (!(keys[key / 64] & (std::uint64_t{1} << (key % 64)))) continue;
        if (count == 5) return 0;
        single = key;
        ++count;
    }
    if (count == 1) return 0x80000000u | single;
    // Chord ids go in ascending order.
    std::vector<unsigned> ids;
    for (unsigned key = 0; key < 256; ++key)
        if (keys[key / 64] & (std::uint64_t{1} << (key % 64))) ids.push_back(id_of(key));
    std::sort(ids.begin(), ids.end());
    for (std::size_t i = 0; i < ids.size(); ++i) value |= ids[i] << (i * 6);
    return value;
}
}
