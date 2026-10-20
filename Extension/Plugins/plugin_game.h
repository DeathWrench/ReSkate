#pragma once
#include "plugin_wave.h"
#include "Engine/Core/Json/json.h"
#include "Extension/AnimationStudio/anim_core.h"
#include "Extension/Throwdowns/throwdown_kit.h"
#include <array>
#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// The game behind the wider set of the plugin API (docs: ReSkate Plugin System Design): what plugins
// may read and change of the skater, the world, the session and the rest. Every function has an
// "unavailable" default, so the host runs without a game (the tests give it a fake one) and the
// game side fills in what it can (plugin_game_runtime.cpp). Client thread throughout.
//
// A string a function returns is empty when it worked, and otherwise says why not, for the plugin.
namespace dingosdk::plugins {
using Vec3 = std::array<float, 3>;
inline constexpr char unavailable[] = "unavailable here";

// The game's camera as it is now: where it is, the way it looks, and its vertical field of view.
struct CameraView {
    Vec3 position{}, forward{};
    float fov{};
    Vec3 right{}, up{};
    bool free_camera{}; // the view is Freecam's, verified selected (not just asked for)
};
// What a game layer reads of the local skater each tick (reskate.skater.telemetry): the trainer's
// telemetry and its last measured jump, the physics state the skater's selector chose (with No
// Bail's wipeout and runout counts), the Bone Cam's slams and where the body is during a bail.
struct SkaterTelemetry {
    bool skater{}, airborne{};
    Vec3 position{};
    float heading{}; // the trainer's degrees: 0 faces +Z, forward (sin, 0, cos)
    float speed{}, vertical{}, air_time{}, height{}, top_speed{};
    std::uint32_t physics_state{};
    struct Jump {
        std::uint64_t serial{};
        float takeoff_speed{}, takeoff_angle{}, air_time{}, height{}, distance{}, drop{}, landing_speed{};
        float spin{}, spin_rate{}, flip{}, board_turn{};
        std::uint32_t state{};
        Vec3 takeoff{}, landing{};
    } last;
    struct Watch {
        bool valid{}, ragdoll_known{}, ragdoll{};
        std::uint32_t state{}, previous{};
        float previous_seconds{};
        std::uint64_t changes{}, wipeouts{}, runouts{};
    } watch;
    bool teleport_pending{}, slam{}, struck{};
    std::optional<Vec3> body; // the hips, during a bail (Bone Cam)
};
struct TrickNote {
    std::uint64_t entry{};
    char kind{}; // 'n' name, 's' side, 'l' landing, 'b' body spin, 'r' board spin, 'k' stance, 'm' modifier
    std::string text;
};
// Input for a plugin that flies something: the flight keys and mouse look (as Freecam reads them),
// a gamepad's sticks, triggers and buttons (XInput's bits), a joystick or radio's axes and buttons.
struct FlightInput {
    float right{}, up{}, forward{}, look_x{}, look_y{};
    bool boost{};
};
struct PadInput {
    float left_x{}, left_y{}, right_x{}, right_y{}, left_trigger{}, right_trigger{};
    std::uint32_t buttons{};
    bool playstation{};
};
struct StickInput {
    std::array<float, 6> axes{};
    std::uint32_t buttons{};
    std::string name;
};
// A sound a plugin plays (reskate.audio): its wave, or the motor synth when it has none.
struct SoundStart {
    std::shared_ptr<const Wave> wave;
    float volume{1}, pitch{1}, range{40}, throttle{}, speed{};
    bool loop{};
    std::optional<Vec3> position; // empty: at the local skater
};
struct SoundChange {
    std::optional<float> volume, pitch, range, throttle, speed;
    std::optional<std::optional<Vec3>> position;
};
// What the local skater's physics did since the last tick (events.skater).
struct SkaterNews {
    struct Landing {
        float down_speed{}, speed{};
        bool rail{};
    };
    struct Hit {
        std::string bone; // as the game names its body ("Left forearm")
        float impact{};
        bool vehicle{}, board{};
    };
    struct Fall {
        float seconds{}, left{}, right{};
        struct Bone {
            std::string name;
            float impact{}, slide{};
        };
        std::vector<Bone> bones; // those that hit or slid
    };
    std::vector<Landing> landings;
    std::vector<Hit> hits;
    std::vector<Fall> falls;
};
// One physics step of the local skater (events.physics): when (the steady clock, ms, as
// reskate.time.now), how long it simulated, and what the body did; only the bodies touching something.
struct PhysicsStep {
    double at{};
    float seconds{};
    bool wipeout{}, airborne{};
    std::optional<bool> ragdoll;
    std::optional<Vec3> velocity;
    std::optional<float> spin;
    struct Body {
        std::string name; // as body_hit names it
        float impact{}, slide{};
        bool board{}, vehicle{}, world{}; // world: anything but the board and vehicles
    };
    std::vector<Body> bodies;
};
// What a plugin asks of the next pop out of a grind: "toe", "heel", "left" or "right" (of travel),
// the player's stance (0 not set, 1 regular, 2 goofy: what toe and heel need), and 0.1 to 1 of the
// full sideways speed. And a pop as it went (Extension/Skater/grind_exit.h).
struct GrindExitWish {
    std::string side;
    int stance{};
    float strength{1};
};
struct GrindPop {
    bool applied{};
    std::string reason, basis;
    int toward{}; // +1 the left of travel, -1 the right, 0 the game's own
    float before{}, after{};
};
// The last slam: its force and the game's cause number, and how long ago (ms).
struct SlamNews {
    float force{};
    int cause{-1};
    double ago_ms{};
};
struct CatalogItem {
    std::string key, title, category;
};
// A park editor object on the map being played: its layout id, the item, where and how it sits.
struct GameObject {
    std::uint64_t id{};
    std::string item;
    Vec3 position{};
    std::array<float, 4> rotation{0, 0, 0, 1}; // x, y, z, w
    float scale{1};
};
struct Destination {
    std::string id, name, map; // fast travel
};
struct LevelInfo {
    std::string asset, name;
    bool can_load{};
};
// Another player's skater as the session last heard it.
struct PeerSkater {
    std::uint64_t id{};
    Vec3 position{};
    float heading{}; // as the local skater's
    double age_ms{}; // since its pose arrived
};
struct ChatLine {
    std::uint64_t sequence{}, sender{};
    std::string name, text;
    bool local{}, server{};
};
struct Track {
    bool available{}, playing{};
    std::string app, title, artist, album;
    std::uint64_t revision{};
};
struct ThrowdownState {
    bool active{}, host{};
    struct Player {
        std::string name;
        int letters{};
        bool up{}, out{};
    };
    std::vector<Player> skate; // S.K.A.T.E.'s players and letters, while one is shown
};
// A throwdown mode on the game's Throwdowns page: a card on its picker, the game's own setup page
// (relabelled from the plugin's setup document) and the game's start flag. The plugin runs it.
struct ThrowdownMode {
    std::string id, name, description;
    std::string art;  // the logo: a texture or image asset the plugin's mod adds, by path; empty: the card's own
    std::string flag; // the placement-preview prefab its native flag shows, by path; empty: Spot Battle's
    std::string card = "spot"; // the stock card it is cloned from: "skate", "spot" or "jam"
    std::string replaces; // the stock throwdown whose place it takes: "skate", "spot", "jam" or empty
    std::uint32_t color{};
    int order{};          // among the plugin modes on the picker
    int min_players = 1, max_players = 6, players = 4;
    float cursor_height{}; // > 0: its flag's placement cursor may rise this far (metres)
};
// reskate.ui.dialog: an overlay dialog over the game (plugin_dialog.cpp). Its answers come back to
// the plugin as throwdown_ui events with action "dialog" (throwdown_kit.h).
struct DialogSpec {
    std::string id, title, message;
    struct Field {
        bool present{};
        std::string text;
        std::size_t max{64};
    } field;
    struct Row {
        std::string text, sub;
        std::vector<std::string> buttons; // each answers with its name and the row
    };
    bool list{};
    std::vector<Row> rows;
    std::string empty; // shown in a list with no rows
    struct Button {
        std::string id, label;
    };
    std::vector<Button> buttons;
    struct File {
        bool present{};
        std::string label, filter; // filter: "*.json" or "*.json;*.txt"
    } file;
};
struct Progress {
    bool available{};
    struct District {
        std::string id, name;
        int rank{};
    };
    std::vector<District> districts;
    struct Challenge {
        std::string id, type, neighborhood;
        int attempts{}, completed_goals{}, goal_count{};
    };
    std::vector<Challenge> challenges;
    double score{}, score_cap{};
    int score_level{};
};

class Game {
public:
    virtual ~Game() = default;
    // ---- the local skater ----------------------------------------------------------------------
    // Its physics state (100s riding, 200s in the air, 300 a wipeout, 400s grinding, 504 off the
    // board), or empty without a skater; and how many wipeouts it has had this session.
    virtual std::optional<std::uint32_t> physics_state() { return std::nullopt; }
    virtual std::uint64_t wipeouts() { return 0; }
    // "noclip_on", "noclip_off", "boost_forward", "boost_up", "boost_offboard": queued as the
    // console's own are, under the host's rules.
    virtual std::string control(std::string_view) { return unavailable; }
    // The game's HUD hidden while any plugin asks; given back when the last one stops asking.
    virtual void hide_hud(std::string_view /*plugin*/, bool) {}
    // ---- the world -------------------------------------------------------------------------------
    virtual std::vector<CatalogItem> object_catalog() { return {}; }
    virtual std::vector<GameObject> objects() { return {}; }
    // "place" (item and pose), "move" (id and pose) or "delete" (id): through the park editor,
    // under the session's object rules and limits. One at a time: it is busy until done.
    virtual std::string edit_object(std::string_view, const GameObject&) { return unavailable; }
    // A plugin's own world objects (world_entities.h): an entity of a world object blueprint at a
    // full transform (rows: right, up, forward axes with their scale, then the position), kept by the
    // plugin's id for it. Only this player's game shows them. Status: 0 none, 1 waiting, 2 loading,
    // 3 missing, 4 ready, 5 hidden.
    virtual std::string entity_set(std::string_view /*plugin*/, std::uint32_t, std::string_view, const std::array<float, 16>&, bool) {
        return unavailable;
    }
    virtual void entity_remove(std::string_view /*plugin*/, std::uint32_t) {}
    virtual void entity_clear(std::string_view /*plugin*/) {}
    virtual int entity_status(std::string_view /*plugin*/, std::uint32_t) { return 0; }
    virtual bool entities_ready(std::string_view /*plugin*/) { return false; }
    // kind "tod" (key: morning, noon, afternoon, evening, night, weatherday, weathernight, default),
    // "control" (key: fog, fog_distance, sky_brightness, clouds, wind_strength, wind_direction,
    // traffic, pedestrians; value a number, -1 the default) or "park" (key: a lot, value a layout).
    virtual std::string set_environment(std::string_view, std::string_view, std::string_view) { return unavailable; }
    virtual std::vector<Destination> destinations() { return {}; }
    virtual std::vector<LevelInfo> levels() { return {}; }
    // kind "location" (a destination's id) or "level" (a level's asset); a guest is refused.
    virtual std::string travel(std::string_view, std::string_view) { return unavailable; }
    // "spawn" (count) or "clear"; refused in a session, where others would never see them.
    virtual std::string ai(std::string_view, int) { return unavailable; }
    virtual int ai_count() { return 0; }
    // ---- the session ----------------------------------------------------------------------------
    virtual std::vector<PeerSkater> peer_skaters() { return {}; }
    // A short tag beside a player's nametag, the plugin's own (empty text takes it away).
    virtual void set_nametag(std::string_view /*plugin*/, std::uint64_t, std::string, std::uint32_t) {}
    // 0 mutes, 1 is as heard, up to 10. The local player's ears only.
    virtual std::string voice_volume(std::uint64_t, float) { return unavailable; }
    // Chat lines after `sequence`, as this player sees them (filtered when they filter).
    virtual std::vector<ChatLine> chat_since(std::uint64_t) { return {}; }
    virtual std::string send_chat(std::string_view) { return unavailable; }
    // A line in this player's chat only, under the plugin's name with a "Plugin" tag.
    virtual std::string local_chat(std::string_view /*plugin*/, std::string_view, std::uint32_t /*colour, 0 the usual*/) { return unavailable; }
    virtual ThrowdownState throwdowns() { return {}; }
    // A drop the local player hosts where the skater stands, for chosen players of the session
    // (`series` "JamSession", "SpotBattle" or "ThrowdownSkate"): they see it and join it with the
    // game's own Join, and it starts once all have. Its status: "", "asked", "spawning", "open",
    // "started", "cancelled", or why it failed.
    virtual std::string host_throwdown(std::string_view /*plugin*/, std::string_view /*series*/, std::vector<std::uint64_t> /*players*/,
                                       int /*max players*/) {
        return unavailable;
    }
    virtual void cancel_throwdown(std::string_view /*plugin*/) {}
    virtual std::string throwdown_status(std::string_view /*plugin*/) { return {}; }
    // Adds the mode to the Throwdowns page, or updates it (by id).
    virtual std::string set_throwdown_mode(std::string_view /*plugin*/, const ThrowdownMode&) { return unavailable; }
    virtual void remove_throwdown_mode(std::string_view /*plugin*/, std::string_view /*id*/) {}
    // The throwdown kit (throwdown_kit.h): the plugin's documents for the native UI, and the one
    // native flag registration (`mode` is the SDK's id, "<plugin>/<id>"). Leave lets go of the
    // registration only when it is one of the plugin's modes.
    virtual std::string publish_throwdown_ui(std::string_view /*plugin*/, const Json&) { return unavailable; }
    virtual bool throwdown_flag_begin(std::string_view /*mode*/, std::uint32_t /*game*/, const throwdowns::kit::flag::Options&) { return false; }
    virtual throwdowns::kit::flag::State throwdown_flag_state() { return {}; }
    virtual void throwdown_flag_leave(std::string_view /*plugin*/) {}
    // ---- general services for a game layer in Lua (plugin_api_services.cpp) ----------------------
    virtual std::optional<SkaterTelemetry> skater_telemetry() { return std::nullopt; }
    // The pad's XInput button bits, LT 0x10000 and RT 0x20000 (empty: no pad). `menu`: read while
    // ReSkate's menu is open too.
    virtual std::optional<std::uint32_t> pad_bits(bool /*menu*/) { return std::nullopt; }
    virtual bool key_down(int /*virtual_key*/) { return false; }
    virtual int mouse_wheel() { return 0; }
    // Game buttons kept from the game while asked (overlay::hide_game_buttons/hold_game_buttons),
    // and all game input paused for half a second at a time.
    virtual void game_buttons(std::string_view /*plugin*/, std::uint16_t /*hidden*/, std::uint16_t /*held*/, bool /*paused*/) {}
    // The game window has the focus, ReSkate's menu is shut and the native UI lets the game play.
    virtual bool input_allowed() { return false; }
    virtual std::string free_camera(std::string_view /*plugin*/, bool) { return unavailable; }
    // The free camera flown from the pad while placing from the air (Extension/Skater/pad_flight.h);
    // one plugin holds it at a time.
    virtual std::string pad_flight(std::string_view /*plugin*/, bool) { return unavailable; }
    // The stock physics while the local player competes (set_competition_stock_physics).
    virtual void competition(std::string_view /*plugin*/, bool) {}
    virtual bool stock_physics_ready() { return false; }
    // physics_tuning::prepare(): the game's stock tuning read, without switching anything.
    virtual void prepare_physics() {}
    // The session's world (it changes with the map or session), whether the local player's mods bar
    // them from scoring, and the map's name.
    virtual std::string world_map() { return {}; }
    virtual std::uint64_t world_id() { return 0; }
    virtual bool world_barred() { return false; }
    virtual std::optional<bool> stance_goofy() { return std::nullopt; }
    virtual void trick_feed(std::string_view /*plugin*/, bool) {}
    virtual std::vector<TrickNote> take_trick_notes() { return {}; }
    // The Bone Cam (Extension/Skater/bone_cam.h): no words for its setting, "status", "bail",
    // "ringing", "game on|off" (the plugin's game asks for it), or the bonecam console words.
    virtual std::string bone_cam(std::string_view /*plugin*/, const std::vector<std::string>& /*words*/) { return {}; }
    // Three focus checks: the game window has focus, ReSkate's overlay is open, and the throwdown
    // flow lets gameplay input through.
    struct InputFocus {
        bool focused{}, interface_open{}, gameplay{};
    };
    virtual InputFocus input_focus() { return {}; }
    // Watch another player's skater the way the native party menu does (0: back to our own).
    virtual void spectate(std::uint64_t /*player*/) {}
    // The flick diagram of a flip trick as skate. names it (trick_gestures.h): read in the
    // background the first time; empty until then, or for a trick without one.
    virtual std::vector<std::array<float, 2>> trick_gesture(std::string_view /*trick*/) { return {}; }
    // ---- files: the plugin's own data folder, <game>/Mods/.reskate/data/<plugin>/ ------------------
    // Paths are relative to it and already checked (plugin_manifest.h's safe_relative_path). A listing
    // names the files and folders in `folder` (empty: the top), folders ending in "/".
    virtual std::string files_list(std::string_view /*plugin*/, std::string_view /*folder*/, std::vector<std::string>& /*names*/) { return unavailable; }
    virtual std::string files_read(std::string_view /*plugin*/, std::string_view /*path*/, std::string& /*text*/) { return unavailable; }
    virtual std::string files_write(std::string_view /*plugin*/, std::string_view /*path*/, std::string_view /*text*/) { return unavailable; }
    virtual std::string files_remove(std::string_view /*plugin*/, std::string_view /*path*/) { return unavailable; }
    // ---- ui.dialog -----------------------------------------------------------------------------------
    // One dialog at a time over the game; the same id again updates it (what was typed is kept).
    virtual std::string dialog_open(std::string_view /*plugin*/, const DialogSpec&) { return unavailable; }
    virtual void dialog_close(std::string_view /*plugin*/, std::string_view /*id, empty: any of the plugin's*/) {}
    // ---- skater.push / hold ----------------------------------------------------------------------------
    // The skater's velocity set to this (metres per second, world) once it is back on its board, and
    // the skater held where it is (no input, no physics) while asked. A pending push may wait two
    // seconds more (the skater is still getting back on its board) or be dropped.
    virtual std::string skater_push(std::string_view /*plugin*/, const Vec3&) { return unavailable; }
    virtual std::string skater_push_wait(std::string_view /*plugin*/) { return unavailable; }
    virtual std::string skater_push_reset(std::string_view /*plugin*/) { return unavailable; }
    virtual std::string skater_hold(std::string_view /*plugin*/, bool) { return unavailable; }
    // ---- the rest ----------------------------------------------------------------------------------
    // The music an outside player (Spotify and the like) is playing, and "play", "pause",
    // "next" or "previous" for it.
    virtual Track track() { return {}; }
    virtual std::string music(std::string_view) { return unavailable; }
    // The game's own soundtrack on the player's headphones (none while a Spotify station is on:
    // then the outside player's song is the one heard), and "next" for it.
    virtual std::optional<Track> game_track() { return std::nullopt; }
    virtual std::string game_music(std::string_view) { return unavailable; }
    virtual Progress progress() { return {}; }
    virtual std::optional<std::string> setting(std::string_view) { return std::nullopt; }
    virtual std::vector<std::string> setting_names() { return {}; }
    // ---- camera ------------------------------------------------------------------------------------
    // The view from a pose (rows right, up, back and position, as follow_camera.h builds them) with
    // a vertical field of view in degrees (0 the camera's own). One plugin holds it at a time, and
    // Spectate takes it back while it runs; the game's own camera returns on release.
    virtual std::optional<CameraView> camera_view() { return std::nullopt; }
    virtual std::string set_camera(std::string_view /*plugin*/, const std::array<float, 16>&, float) { return unavailable; }
    // Spectate's camera on a session player (0 stops the one this plugin started).
    virtual std::string follow_player(std::string_view /*plugin*/, std::uint64_t) { return unavailable; }
    virtual void release_camera(std::string_view /*plugin*/) {}
    // "" while the plugin's view is the one shown, otherwise why not.
    virtual std::string camera_status(std::string_view /*plugin*/) { return unavailable; }
    // Holds the skater where it is (noclip, with no input), while any plugin asks.
    virtual std::string freeze(std::string_view /*plugin*/, bool) { return unavailable; }
    // ---- the session's authority (plugins' server copies) --------------------------------------------
    // Drops a player from the session; a chat line to everyone; one to one player (a dedicated
    // server's only: a lobby has no private chat); moves a player's skater (their game does the move).
    virtual std::string kick(std::uint64_t, std::string_view /*why*/) { return unavailable; }
    virtual std::string announce(std::string_view /*plugin*/, std::string_view) { return unavailable; }
    virtual std::string tell(std::string_view /*plugin*/, std::uint64_t, std::string_view) { return unavailable; }
    virtual std::string move_player(std::uint64_t, const Vec3&) { return unavailable; }
    // ---- skater.animation: clips on the local skater's body (Extension/Skater/skater_animation.h) ------
    // One plugin plays at a time; none while a throwdown runs. A replacement plays when the game does
    // `trick` ("kickflip") with that pop ("" any, "low", "mid", "high"); a null clip takes it away.
    using ClipRef = std::shared_ptr<const anim_studio::Clip>;
    virtual std::string play_clip(std::string_view /*plugin*/, ClipRef, float /*speed*/, float /*blend*/, bool /*loop*/) { return unavailable; }
    virtual void stop_clip(std::string_view /*plugin*/) {}
    virtual bool clip_playing(std::string_view /*plugin*/) { return false; }
    virtual std::string replace_trick(std::string_view /*plugin*/, std::string /*trick*/, std::string /*pop*/, ClipRef, float /*speed*/) {
        return unavailable;
    }
    // Records the skater's pose for so many seconds; the clip comes from take_recording once done.
    virtual std::string record_clip(std::string_view /*plugin*/, float /*seconds*/) { return unavailable; }
    virtual ClipRef take_recording(std::string_view /*plugin*/) { return nullptr; }
    // The game's name for the trick the skater is doing now ("kickflip"), or empty.
    virtual std::string current_trick() { return {}; }
    // ---- outfit: items worn over the local skater's outfit (Extension/Skater/outfit_overlay.h) ----------
    struct OutfitSlot {
        std::string name, item;
        std::vector<float> parameters;
    };
    virtual std::string outfit_set(std::string_view /*plugin*/, std::string_view /*slot*/, std::string_view /*item*/, std::vector<float>, bool) {
        return unavailable;
    }
    virtual void outfit_clear(std::string_view /*plugin*/, std::string_view /*slot, empty: all*/) {}
    virtual std::string outfit_find(std::string_view) { return {}; }
    virtual std::vector<OutfitSlot> outfit_slots() { return {}; }
    virtual std::string outfit_status() { return unavailable; }
    // ---- board: what is drawn of the local skateboard (Extension/Skater/board_pose.h) ------------------
    struct BoardBone {
        Vec3 position{};
        std::array<float, 4> rotation{0, 0, 0, 1};
        Vec3 scale{1, 1, 1};
    };
    virtual std::optional<std::array<BoardBone, 16>> board_bones() { return std::nullopt; }
    virtual std::string board_set(std::string_view /*plugin*/, int, const BoardBone&, bool /*world*/) { return unavailable; }
    virtual std::string board_hide(std::string_view /*plugin*/, int) { return unavailable; }
    virtual void board_clear(std::string_view /*plugin*/, int /*bone, -1: all*/) {}
    virtual void board_park(std::string_view /*plugin*/, std::vector<int>) {}
    virtual std::string board_toss(std::string_view /*plugin*/, std::vector<int>, const Vec3&, const Vec3&, float) { return unavailable; }
    // How every board is fitted (board_pose.h fit); none: the plugin's fit ends.
    struct BoardFit {
        bool plates{};
        float axle = 1.0f;
    };
    virtual std::string board_fit(std::string_view /*plugin*/, std::optional<BoardFit>) { return unavailable; }
    // ---- variants: of the plugin's own mod (Engine/Vfs/mod_list.h Variants) -----------------------------
    struct VariantState {
        std::vector<std::string> installed; // its "order" first
        std::string chosen;                 // empty: none was
        std::string in_play;                // empty: none of them is in the game
    };
    // Empty when the mod declares no variants.
    virtual std::optional<VariantState> variants(std::string_view /*plugin*/, const std::filesystem::path& /*package*/) { return std::nullopt; }
    // The variant saved as the mod's choice, the mods applied again and the level loaded again with it.
    virtual std::string choose_variant(std::string_view /*plugin*/, const std::filesystem::path& /*package*/, std::string_view /*variant*/) {
        return unavailable;
    }
    // ---- the skater's physics -----------------------------------------------------------------------
    virtual SkaterNews take_skater_news() { return {}; }
    virtual std::optional<Vec3> board_velocity() { return std::nullopt; }
    virtual std::optional<SlamNews> last_slam() { return std::nullopt; }
    // Every physics step since the last tick (kept once asked for: at most 512).
    virtual std::vector<PhysicsStep> take_physics_steps() { return {}; }
    // The skater's x-ray ready while any plugin asks (Extension/Skater/xray.h); d:skeleton draws it.
    virtual std::string xray(std::string_view /*plugin*/, bool) { return unavailable; }
    // skate.'s bottom left HUD hidden while any plugin asks; false keeps the plugin ready to hide it.
    virtual std::string hud_corner(std::string_view /*plugin*/, bool) { return unavailable; }
    // The game run at `speed` (0.05 to 1; 1 drops the ask) while it is the slowest asked; never in a
    // multiplayer session. And the speed it runs at for plugins now.
    virtual std::string game_speed(std::string_view /*plugin*/, float) { return unavailable; }
    virtual float game_speed_now() { return 1; }
    // The next pop out of a grind (Extension/Skater/grind_exit.h); empty: the game's own exit. One
    // plugin at a time. Its pops come back from take_grind_pops.
    virtual std::string grind_exit(std::string_view /*plugin*/, std::optional<GrindExitWish>) { return unavailable; }
    virtual std::vector<GrindPop> take_grind_pops(std::string_view /*plugin*/) { return {}; }
    // Pad controls kept from the game while any plugin asks: the triggers, and the left stick's
    // left/right while the skater grinds.
    virtual std::string hide_pad(std::string_view /*plugin*/, bool /*lt*/, bool /*rt*/, bool /*left_x while grinding*/) { return unavailable; }
    // The skater bails as from a slam of `force` (0.5 to 3); not in a throwdown. While No Bail protects
    // the skater the wipeout is dropped, as any other is.
    virtual std::string wipeout(float /*force*/) { return unavailable; }
    // ---- audio: plugins' own sounds, in a level ---------------------------------------------------------
    // Its id, or 0 when the plugin plays 8 already (or there is no level).
    virtual std::uint64_t play_sound(std::string_view /*plugin*/, SoundStart) { return 0; }
    virtual bool change_sound(std::string_view /*plugin*/, std::uint64_t, const SoundChange&) { return false; }
    virtual void stop_sound(std::string_view /*plugin*/, std::uint64_t) {}
    virtual bool sound_playing(std::string_view /*plugin*/, std::uint64_t) { return false; }
    // ---- input -------------------------------------------------------------------------------------
    // The flight keys and mouse only while the plugin's camera is shown; pads while the game has the
    // focus. Capture keeps the game from the controller too, for 250 ms a call (renewed each tick),
    // and only while the plugin's camera is shown.
    virtual std::optional<FlightInput> flight_input(std::string_view /*plugin*/) { return std::nullopt; }
    virtual std::optional<PadInput> gamepad() { return std::nullopt; }
    virtual std::optional<StickInput> joystick() { return std::nullopt; }
    virtual std::string capture_input(std::string_view /*plugin*/, bool) { return unavailable; }
    // A named action on a key or pad combo (controller_bindings.h's encoding); presses come back
    // from take_presses as (plugin, action), only while the game itself has the input.
    virtual std::string bind(std::string_view /*plugin*/, std::string_view, std::uint32_t) { return unavailable; }
    virtual std::vector<std::pair<std::string, std::string>> take_presses() { return {}; }
    // Everything a plugin holds of the game (its HUD hide, nametags, binds), when it stops.
    virtual void release(std::string_view /*plugin*/) {}
};

// "F7", "Ctrl+K", "Shift+Alt+1", "Space"; or a pad combo, "Pad.LB+Pad.RB", "Pad.A", "Pad.Up"...
// As controller_bindings.h encodes binds; 0 for a name that is not one.
std::uint32_t combo_of(std::string_view name);
// A physics state as plugins hear it: "riding", "air", "wipeout", "grinding", "off_board",
// "planted", "other" or "none".
const char* skater_state_name(std::uint32_t state);
}
