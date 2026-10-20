-- SmokeyDawg58's game modes (his game_modes.cpp), ported to Lua line for line. This is the shared
-- namespace: his State, Game and Offer with their defaults, and the helpers every part uses
-- (game_modes.cpp lines 60-560 and 902). The other files of td/ add the rest of his functions to it
-- under their C++ names. Steam IDs are strings ("0" is none), positions are vectors, his indices
-- stay 0-based where they mean something.
local M = {}

local RR = require("td/h/race_route")
local RE = require("td/h/race_editor")
local RA = require("td/h/race_arrow_placement")
local RM = require("td/h/race_momentum")
local RS = require("td/h/race_sound")
local MA = require("td/h/mode_announcements")
local PC = require("td/h/placement_camera")

-- ---- mode_rules.h --------------------------------------------------------------------------------
-- His rules (td/rules.lua), his Referee (td/referee.lua) and his wire (td/wire.lua), all in Lua: every
-- function and constant of mode_rules.h and mode_transport.h under its C++ name (M.max_players,
-- M.wire_version, M.tag_like, M.inside, M.trick_steps, M.Referee, M.encode, M.transport_messages, ...),
-- and his Settings, Standing and Message constructors (M.Settings(), M.Message(), ...).
local R = require("td/rules")
require("td/referee")
require("td/wire")
for name, f in pairs(R) do M[name] = f end

-- ---- game_modes.cpp's constants -----------------------------------------------------------------
M.wipeout_state, M.offboard_states_first = 300, 500
M.pad_a = 0x1000 -- Editor placement only; native flags own joining.
M.line_grace_ms, M.bail_settle_ms, M.leader_timeout_ms, M.setup_every_ms = 2500, 3500, 10000, 3000
M.state_every_ms, M.join_every_ms, M.out_of_area_ms, M.popup_ms = 500, 2000, 3000, 2500
-- Grinds and slides, from the physics states recorded on 2026-10-08 (402/403 grinds, 404 slides).
M.grind_states_first, M.grind_states_end = 400, 500
-- R.E.S.K.A.T.E.: rolling on the board this long after a named trick lands it; off the board this
-- long misses it.
M.settle_landed_ms, M.stepped_off_ms = 300, 1500
-- R.E.S.K.A.T.E.: names that are not board tricks (lower case parts of skate.'s trick list names).
M.off_board_words = {"jump", "hippy", "vault", "climb", "dive", "dyno", "hang", "dismount", "run", "drop in"}
function M.grind_score(seconds, metres)
    return M.trunc(150.0 + math.clamp(seconds, 0.0, 10.0) * 250.0 + math.clamp(metres, 0.0, 60.0) * 30.0)
end

-- ---- values -----------------------------------------------------------------------------------------
-- A position from the API or JSON ({x, y, z} or {x =, y =, z =}) as a vector; nil stays nil.
function M.V(t)
    if t == nil then return nil end
    if type(t) == "vector" then return t end
    if t[1] ~= nil then return vector.create(t[1] or 0, t[2] or 0, t[3] or 0) end
    return vector.create(t.x or 0, t.y or 0, t.z or 0)
end
function M.nz(id) return id ~= nil and id ~= "" and id ~= "0" and id ~= 0 end
function M.pair_key(leader, game) return tostring(leader) .. ":" .. tostring(game) end
function M.unpair(key)
    local leader, game = string.match(key, "^(.-):(.*)$")
    return leader, tonumber(game)
end
function M.sorted_keys(t, less)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys, less)
    return keys
end
-- Steam IDs ordered as numbers (his std::map<std::uint64_t, ...>): by length, then by digits.
function M.id_less(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
end
function M.copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = M.copy(x) end
    return setmetatable(out, getmetatable(v))
end
function M.same(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, x in pairs(a) do
        if not M.same(x, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
function M.trunc(x)
    if x >= 0 then return math.floor(x) end
    return math.ceil(x)
end
function M.idiv(a, b) return M.trunc(a / b) end
function M.starts_with(s, prefix) return string.sub(s, 1, #prefix) == prefix end
function M.ends_with(s, suffix) return suffix == "" or string.sub(s, -#suffix) == suffix end
function M.contains(list, value)
    for _, x in ipairs(list) do
        if x == value then return true end
    end
    return false
end
function M.erase(list, value)
    for i = #list, 1, -1 do
        if list[i] == value then table.remove(list, i) end
    end
end
function M.erase_if(list, f)
    for i = #list, 1, -1 do
        if f(list[i]) then table.remove(list, i) end
    end
end

-- His Settings, Message and Standing (mode_rules.h) with their defaults are td/rules.lua's (M.Settings(), ...).
local function vectors(list)
    local out = {}
    for i, p in ipairs(list or {}) do out[i] = M.V(p) end
    return out
end
local function numbers(list)
    local out = {}
    for i, n in ipairs(list or {}) do out[i] = n end
    return out
end
function M.settings_from(j)
    local s = M.Settings()
    if type(j) ~= "table" then return s end
    for _, key in ipairs({"mode", "duration_s", "turn_s", "strikes", "radius", "area_radius", "has_spawn", "race_finish", "trick_kinds"}) do
        if j[key] ~= nil then s[key] = j[key] end
    end
    if s.mode == "1up" or s.mode == "1-up" then s.mode = "oneup" end -- his mode_key spells it "1up"
    s.corners, s.points = vectors(j.corners), vectors(j.points)
    s.yaws, s.widths, s.arrow_rolls, s.gate_pitches = numbers(j.yaws), numbers(j.widths), numbers(j.arrow_rolls), numbers(j.gate_pitches)
    for i, k in ipairs(j.gate_kinds or {}) do s.gate_kinds[i] = (k == "guide" or k == "guiding") and "guide" or k == "arrow" and "arrow" or "required" end
    if j.spawn ~= nil then s.spawn = M.V(j.spawn) end
    return s
end
function M.tag_from(j)
    return {kind = j and j.kind == "gap" and "gap" or "grind", path = vectors(j and j.path)}
end
function M.message_from(j)
    local m = M.Message()
    if type(j) ~= "table" then return m end
    for key, v in pairs(j) do
        if key ~= "settings" and key ~= "at" and key ~= "tags" and key ~= "standings" and key ~= "zones" and key ~= "calls" then m[key] = v end
    end
    if j.settings ~= nil then m.settings = M.settings_from(j.settings) end
    if j.at ~= nil then m.at = M.V(j.at) end
    for i, t in ipairs(j.tags or {}) do m.tags[i] = M.tag_from(t) end
    for i, r in ipairs(j.standings or {}) do
        local st = M.Standing()
        for key, v in pairs(r) do st[key] = v end
        m.standings[i] = st
    end
    for i, z in ipairs(j.zones or {}) do m.zones[i] = {zone = z.zone or 0, owner = z.owner or "0", best = z.best or 0} end
    for i, c in ipairs(j.calls or {}) do m.calls[i] = c end
    return m
end

-- ---- his structs (game_modes.cpp lines 67-313) -------------------------------------------------------
-- The line the local skater is riding: tricks landed one after another, none bailed.
function M.Line()
    return {tricks = 0, sum = 0, landed = 0, at = vector.zero,
            tags = {},  -- Graffiti: what the line was skated on
            grind = {}, -- the grind under way: where the board has slid so far
            grind_started = 0}
end
-- A bail being measured until the skater settles.
function M.Bail()
    return {active = false, started = 0, speed = 0, start_y = 0, min_y = 0, tumble = 0, at = vector.zero}
end
function M.Game()
    return {
        capacity = 6,
        race_finish_placed = false,
        race_publication = RR.RaceRoutePublication.new(),
        native_lobby = false, native_flag_placed = false,
        zone_custom = false, -- R.E.S.K.A.T.E.: its trick zone is outlined by cones placed after the flag
        native_flag_yaw = 0,
        leader = "0",
        id = 0,
        leading = false,
        settings = M.Settings(),
        tags = {},          -- Graffiti: every tag's shape, by index (the leader sends them)
        tags_sent = 0,      -- leading: shapes already sent
        tags_resent = 0,    -- leading: when all were last sent again, for late arrivals
        joiners = {},       -- leading, before the start: who answered the setup
        referee = nil,      -- leading, from the start
        state = nil,        -- the latest state (the leader's own when leading)
        heard = 0, setup_sent = 0, state_sent = 0, join_sent = 0,
        state_sampled_ms = 0,
        sequence = 0, calls_seen = 0,
        checkpoint_sent = -1,
        lined_up = false, -- Deathrace: put at the start gate for this game's countdown
        checkpoint_at = 0,
        -- Deathrace: the checkpoints this player was last told about, and the side of the next gate
        -- they were on (to notice them going past it outside the posts).
        missed_warned = -1,
        progress_audio = RS.RaceProgressAudio.new(),
        recovery_until = 0, recovery_queued = 0,
        recovery_pending = false, recovery_to_safe = false,
        last_safe_spot = RR.RaceLastSafeSpot.new(),
        momentum = RM.RaceMomentum.new(),
        recovery_grace = RM.RaceRecoveryGrace.new(),
        recovery_speed_guard = RM.RaceRecoverySpeedGuard.new(),
        countdown_audio = RS.RaceCountdownAudio.new(),
        recovery_speed = 0,
        recovery_pose = RR.RaceGatePose.new(),
        checkpoint_fallback = RR.RaceCheckpointFallback.new(),
        along = 0,
        have_along = false,
        miss_pending = false,
        previous_gate_position = vector.zero,
        -- The next gate was crossed between its posts (at `crossed_at`, on its line): reported until
        -- the referee counts it, since a message can be lost.
        gate_crossed = false,
        crossed_at = vector.zero,
    }
end
-- Another player's game, heard from its leader's setup messages: offered like a throwdown drop
-- (a banner over its spot, an announcement) and joined only when the player chooses to.
function M.Offer(leader, game, settings, heard)
    return {leader = leader or "0", game = game or 0, settings = settings or M.Settings(), heard = heard or 0, phase = "setup", players = 1,
            -- A leader's state message has told its phase: until then a game heard mid-way (setup
            -- messages keep coming while it is played) is not offered as open.
            confirmed = false}
end
-- R.E.S.K.A.T.E.: the local player's attempt this turn, built from skate.'s trick list (its names, their
-- FS / BS sides) until a landing ends it or a bail misses it, and whose turn the camera follows.
function M.SkateTurn()
    return {
        key = 0, -- the turn (the state's call serial when it began): a new one starts over
        mine = false, sent = false,
        since = 0,
        parts = {},  -- {entry, name}, in order
        sides = {},  -- entry: "FS" or "BS"
        body_spins = {}, board_spins = {}, stances = {}, -- entry: "180", "360", "Switch"
        modifiers = {}, -- entry: set of "Late", "Darkflip", "Dark Catch"
        last_name = 0,     -- when the last trick name was listed
        settled_since = 0, -- rolling on the board since (0: not)
        landed_at = 0,     -- judged landed at (0: not): counts once it holds without a bail
        off_since = 0,     -- off the board since (0: on it)
        touched_down = false, -- back on the ground since its first trick: nothing more joins
        invalid_at = 0, invalid_told = 0, -- a move that is no trick (Trickless Air, a lone manual), and when that was said
        spectating = "0",
    }
end
function M.LobbyEntry()
    return {name = "", points = 0, wins = 0, podiums = 0, games = 0, streak = 0, best_streak = 0, mode_wins = {}}
end
function M.LobbyGame()
    return {mode = "jam", winner = "", second = "", players = 0, at = 0}
end
local function new_state()
    return {
        game = nil,
        offers = {},
        -- Skate Tag: every player's last position and when it came; when ours last went out; who was it.
        positions = {}, -- id: {at, time}
        position_sent = 0, last_it = "0",
        -- The latest announcement ("X is starting Hall of Meat"): shown for a while with the join button.
        invite_at = 0, invite_leader = "0",
        invite_game = 0,
        join_target = nil, -- what the join button would join now: {leader, game}
        sat_out = {},      -- finished or already-started games we left: pair_key set
        ["local"] = "0", world = "0",
        barred = false, session = false,
        local_name = "",
        names = {},
        present = {}, -- the other players here now
        -- The local skater.
        jump_known = false, wipeouts_known = false,
        jump_serial = 0, wipeouts = 0, last_tick = 0,
        recent_speed = 0, previous_vertical = 0,
        fall_peak = 0, -- the fastest fall (negative) since the skater last stood still vertically
        heights = {},  -- {time, height} over the last 3 s, outside bails
        previous_airborne = false, ragdoll_lost = false,
        previous_state = 0,
        position = vector.zero,
        skater = false, on_board = false, race_body_known = false,
        line = M.Line(),
        bail = M.Bail(),
        ragdoll_bail = RM.RagdollBailEdge.new(),
        race_runouts = RM.RaceRunoutWatch.new(),
        race_hippy = RM.RaceHippyJump.new(),
        race_offboard_ragdoll = RM.RaceOffboardRagdoll.new(),
        last_inside = nil,
        outside_since = 0,
        popup = "",
        popup_at = 0,
        version_noticed = false,
        -- Who in the session has game modes: heard from (a hello or anything else) and when, and the
        -- version of those whose messages this game cannot read; each told about once.
        modded = {},
        other_version = {},
        version_told = {},
        hello_sent = 0,
        announcements = {}, -- pair_key: MatchAnnouncements
        notices = {},
        outbox = {},
        -- Placing the area or the points on the skater, the way skate. sets up a jam session.
        placing = "none", -- none, circle, corners, points
        draft_radius = 20.0,
        heading = 0,    -- the skater's heading (degrees, the trainer's)
        yaw_offset = 0, -- Deathrace: how far the gate being placed is turned from the heading
        draft_width = RE.default_race_editor_width, -- Deathrace: the half width of the gate being placed (metres)
        race_object = 1, -- Required, Finish, Guide, floating Arrow; native picker owns start
        arrow_roll = 0,
        editor_save_blocked = false, editor_rotating = false, editor_angles_ready = false, editor_manual_rotation = false,
        rotate_key_previous = false,
        editor_yaw = 0, editor_pitch = 0, pitch_offset = 0, rotation_pivot = vector.zero, arrow_height_snapped = false,
        arrow_surface = RA.RaceArrowSurface.new(), rotation_surface = RA.RaceArrowSurface.new(), arrow_preview_ready = false,
        arrow_line_snap = RE.RaceArrowLineSnap.new(), arrow_floor_alignment = RA.RaceArrowFloorAlignment.new(),
        route_history = RE.RaceRouteHistory.new(),
        rotation_original = RE.RaceRotationOrigin.new(),
        editor_pose_game = 0, editor_pose_world = "0",
        checkpoint_back_press = RR.RaceCheckpointBackPress.new(),
        cycle_left = false, cycle_right = false, race_resume_editor = false,
        route_snap = true, snap_previous = false,
        snap_angle = RE.default_race_editor_snap_angle,
        clear_hold = RR.RaceClearHold.new(), save_hold = RR.RaceRouteMenuPress.new(), route_input_release = RE.RaceEditorInputRelease.new(),
        route_dialog = 0, route_dialog_serial = 0, route_saved_id = 0, route_rename_id = 0, route_dialog_error = "", route_name = "",
        route_library = nil,
        editor_roll_axis = false, editor_object_changed = 0,
        editor_presses = RR.RaceEditorPresses.new(),
        editor_exit_confirm = false,
        skate_return_sent = 0, -- when the last return teleport was asked for
        cone_redo = {},        -- R.E.S.K.A.T.E.'s cone editor: cones undone, newest last
        name_writes = {},      -- R.E.S.K.A.T.E.: each trick list entry's last name: entry: {text, first, count}
        not_tricks = {},       -- entries that are not tricks (the song title's)
        skate_return_at = 0,   -- R.E.S.K.A.T.E.: when to send the player back to the start flag (0: not)
        course_map = "",
        snapped_yaw = 0,
        race_start = nil,  -- {world, game, at, yaw}
        native_flag = nil, -- {world, game, at, yaw}
        native_start = nil, -- {world, game}
        native_quit = nil,
        route_action = nil, -- {world, game, action, argument}
        -- Where the next thing goes, like skate.'s quick drop: with `free_place` the free camera flies
        -- and the spot is the ground it looks at; without, the ground under the skater.
        free_place = true, freecam_requested = false, dpad_release = false,
        placement_camera = PC.PlacementCamera.new(),
        -- Hall of Meat bounce (Skate 3): how much of a hit's speed a ragdoll gets back upward; `mode bounce`.
        bounce = 0.55,
        bounce_always = false, -- on every bail, not only in a Hall of Meat game
        cursor = vector.zero,
        cursor_heading = 0, cursor_pitch = 0,
        cursor_ok = false,
        cursor_diagnostic = "",
        cursor_diagnostic_at = 0,
        pad_previous = 0,
        keys_previous = {false, false, false, false}, -- Enter, Backspace, End, Escape
        placing_tick = 0,
        -- `mode debug states on`: every physics state change goes to the log (finding grinds and manuals).
        log_states = false,
        logged_state = 0,
        skate = M.SkateTurn(),
        spectate = true, -- `mode spectate on|off`: watch whoever is up in S.K.A.T.E.
        goofy = false,   -- `mode stance regular|goofy`: R.E.S.K.A.T.E.'s stick pictures for a goofy stance
        stance_loaded = false, -- the saved stance read
        was_infected = false,  -- Infection: the local player was infected at the last tick
        was_hiding = false,    -- Hide & Seek: the hiding time was still running at the last tick
        -- The lobby leaderboard: every finished game of two or more players seen in this session.
        lobby = {},          -- id: LobbyEntry
        lobby_counted = {},  -- pair_key set
        lobby_recent = {},   -- LobbyGame, newest first, at most 6
        lobby_played = {},   -- mode: count
        lobby_leader = "0",
        diagram_until = 0, -- `mode diagram <trick>`: its flick diagram on screen until then
        -- R.E.S.K.A.T.E.: the tricks set this game, as each state names the trick up (newest last).
        letters_done = {},
        letters_done_game = 0,
        diagram_trick = "",
        hud = {active = false},
        menu = {},
        native = {active = false},
        active = false, input_locked = false, race_countdown = false, markers_restricted = false, placement_flight = false,
        recovering = false,
        -- ReSkate: what his C++ handed straight to the overlay, kept here for td/ui.lua.
        hidden_buttons = 0, held_buttons = 0, pause_input = false, buttons_sent = nil,
        route_dialog_active = false,
        flick_test = false,
        mode_teleport = false,
    }
end
local the_state
function M.state()
    if not the_state then the_state = new_state() end
    return the_state
end
-- A fresh state, for the tests.
function M.reset_state() the_state = new_state() end

-- ---- his helpers (lines 318-560) --------------------------------------------------------------------
function M.now_ms() return reskate.time.now() end
function M.self_id(s) return M.nz(s["local"]) and s["local"] or "1" end
function M.name_of(s, id)
    if id == M.self_id(s) then return s.local_name == "" and "You" or s.local_name end
    local found = s.names[id]
    return found ~= nil and found ~= "" and found or "Player"
end
function M.grouped(value)
    local text = tostring(math.abs(M.trunc(value)))
    local i = #text - 3
    while i > 0 do
        text = string.sub(text, 1, i) .. "," .. string.sub(text, i + 1)
        i -= 3
    end
    return value < 0 and "-" .. text or text
end
function M.clock_text(ms)
    local seconds = (ms + 999) // 1000
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end
function M.colour(r, g, b) return 0xff000000 + b * 65536 + g * 256 + r end
-- Every machine gives a player the same colour: by their place among the game's players' ids.
local palette = {M.colour(255, 92, 66), M.colour(64, 160, 255), M.colour(255, 206, 64), M.colour(90, 220, 120), M.colour(200, 110, 255),
                 M.colour(255, 140, 200), M.colour(80, 230, 230), M.colour(255, 160, 60)}
-- An id modulo 8, from its decimal digits.
local function id_mod(id, n)
    local r = 0
    for i = 1, #id do r = (r * 10 + (string.byte(id, i) - 48)) % n end
    return r
end
function M.player_colour(state, id)
    local ids = {}
    if state then
        for _, st in ipairs(state.standings) do table.insert(ids, st.player) end
    end
    table.sort(ids, M.id_less)
    local index
    for i, x in ipairs(ids) do
        if x == id then index = i - 1 break end
    end
    if index == nil then index = id_mod(id, 8) end
    return palette[index % #palette + 1]
end
-- A message to every other player: his encode and transport (td/wire.lua).
function M.send(s, m)
    if not s.session then return end
    local ok, packets = pcall(M.transport_messages, m)
    if not ok then
        reskate.log("Game-mode transfer failed: " .. tostring(packets), "error")
        return
    end
    for _, packet in ipairs(packets) do table.insert(s.outbox, packet) end
end
function M.header(g, kind)
    local m = M.Message()
    m.kind = kind
    m.leader = g.leader
    m.game = g.id
    return m
end
function M.standing(g, id)
    if not g.state then return nil end
    for _, st in ipairs(g.state.standings) do
        if st.player == id then return st end
    end
    return nil
end
function M.playing(g) return g.state ~= nil and g.state.phase == "playing" end
function M.race_lobby_open(s, g)
    return g.settings.mode ~= "race" or g.race_publication:accepting(g.settings, s.placing ~= "none", g.native_lobby and not g.native_flag_placed)
end
-- R.E.S.K.A.T.E.: whoever is not up (or is out) watches the one who is, and cannot skate meanwhile.
function M.skate_watching(s)
    if not s.game or not M.playing(s.game) or s.game.settings.mode ~= "skate" then return false end
    local me = M.standing(s.game, M.self_id(s))
    return me ~= nil and (me.out or (M.nz(s.game.state.turn) and s.game.state.turn ~= M.self_id(s)))
end
-- Hide & Seek: the local player seeks while the others still hide, so sees nothing and cannot move.
function M.seeker_blind(s)
    if not s.game or not M.playing(s.game) or s.game.settings.mode ~= "hide" or s.game.state.target <= 0 then return false end
    local me = M.standing(s.game, M.self_id(s))
    return me ~= nil and me.up and not me.out
end
function M.notice(s, text) table.insert(s.notices, text) end
function M.announce_match(s, leader, game, settings, state, now)
    local key = M.pair_key(leader, game)
    if not s.announcements[key] then s.announcements[key] = MA.MatchAnnouncements.new() end
    local text = s.announcements[key]:observe(M.name_of(s, leader), settings, state, now)
    if text then M.notice(s, text) end
end

-- His RaceRouteLibrary (td/routes.lua): the routes saved in the plugin's data folder.
function M.race_route_library(s)
    if not s.route_library then s.route_library = require("td/routes").new() end
    return s.route_library
end
-- ReSkate: his one_up placement's questions (one_up_placement.h) and its begin/left, on the throwdown
-- kit's native flag (reskate.throwdowns.flag): "race" (begin_race_flag_placement), "left"
-- (flag_registration_left), "race_owned", "mode_owned" (game), "waiting" (native_flag_mode_waiting),
-- "placing" (flag_placement_active), "local_throwdown" (multiplayer::local_throwdown_active).
-- A registration answers for this plugin's own modes only.
function M.placement(verb, _world, game, players, show_setup)
    local flag = reskate.throwdowns.flag
    if verb == "left" then
        flag.leave()
        return true
    end
    if verb == "local_throwdown" then return reskate.throwdowns.state().active == true end
    if verb == "race" then
        -- begin_race_flag_placement(world, game, players, show_setup): Deathrace's start flag; its
        -- cursor may rise (his NativeFlagCursorHeight::ceiling, 99999 m).
        local g = M.state().game
        return flag.begin("race", game, {players = math.clamp(players or 6, 1, 10), seconds = g and g.settings.duration_s or 120,
                                         setup_page = show_setup ~= false, cursor_height = 99999})
    end
    local st = flag.state()
    -- race_flag_registration_owned: a Deathrace registration; mode_owned: another game mode's
    -- (his generic_mode); native_flag_mode_waiting: a game mode's (not 1-UP's) waiting card.
    if verb == "race_owned" then return st.mine and st.owned and st.mode == "race" end
    if verb == "mode_owned" then return st.mine and st.owned and st.mode ~= "race" and st.mode ~= "oneup" and (game == nil or st.game == game) end
    if verb == "waiting" then return st.mine and st.waiting and st.mode ~= "oneup" end
    if verb == "placing" then return st.placing end
    return false
end
-- His RaceRecoveryDelivery (s.recovery_velocity.request / wait_for_board / reset): the skater's push
-- service, reskate.skater.push(velocity), push_wait() (two seconds more while the skater gets back
-- on the board) and push_reset() (a pending push dropped).
function M.recovery(what, velocity)
    if what == "request" and velocity then
        local ok, why = pcall(reskate.skater.push, vector.create(velocity.x, 0, velocity.z))
        if not ok then reskate.log("Game modes: the recovery push was refused: " .. tostring(why), "warn") end
    elseif what == "wait" then
        reskate.skater.push_wait()
    elseif what == "reset" then
        reskate.skater.push_reset()
    end
end
-- The pad-flown free camera while placing from the air (his placement_camera flag): asked of the SDK
-- only when it changes.
function M.set_placement_flight(s, on)
    on = on == true
    if s.placement_flight == on then return end
    s.placement_flight = on
    local ok, why = reskate.camera.pad_flight(on)
    if not ok then reskate.log("Game modes: the pad flight was refused: " .. tostring(why), "warn") end
end
function M.open_route_dialog(s, dialog)
    s.route_dialog_error = ""
    local ok, err = pcall(function() M.race_route_library(s):read(s.course_map) end)
    if not ok then s.route_dialog_error = tostring(err) end
    s.route_input_release:arm()
    s.route_dialog = dialog
    s.route_dialog_serial += 1
end
-- keep_flag (ReSkate): a `new` from his UI ends the last game after its own setup already took the
-- native flag registration, which stays.
function M.end_game(s, why, keep_flag)
    if s.game and s.game.leading and s.game.settings.mode == "race" then M.send(s, M.header(s.game, "end")) end
    s.route_dialog = 0
    s.route_dialog_error = ""
    s.route_saved_id, s.route_rename_id = 0, 0
    s.route_name = ""
    s.save_hold = RR.RaceRouteMenuPress.new()
    s.route_dialog_active = false
    s.editor_exit_confirm = false
    s.clear_hold = RR.RaceClearHold.new()
    s.editor_presses = RR.RaceEditorPresses.new()
    s.editor_rotating, s.editor_angles_ready, s.editor_manual_rotation = false, false, false
    s.rotation_original:clear()
    s.route_history:reset()
    s.editor_pose_game = 0
    M.recovery("reset")
    s.recovering = false
    reskate.physics.competition(false)
    if why ~= nil and why ~= "" then reskate.log("Custom Throwdown ended: " .. why) end
    -- A guest leaving does not end the host's challenge. Only native host End
    -- or an authoritative remote End closes the local announcement lifecycle.
    if s.game and (s.game.leading or (why ~= nil and why ~= "")) then
        local final = s.game.state and M.copy(s.game.state) or M.Message()
        final.phase = "results"
        M.announce_match(s, s.game.leader, s.game.id, s.game.settings, final, M.now_ms())
    end
    if not keep_flag and (M.placement("race_owned") or (s.game and M.placement("mode_owned", nil, s.game.id))) then
        M.placement("left")
    end
    s.race_start, s.native_flag, s.native_start, s.native_quit = nil, nil, nil, nil
    s.game = nil
    s.active = false
    s.input_locked, s.race_countdown = false, false
    s.markers_restricted = false
    s.placing = "none"
    s.race_resume_editor = false
    M.set_placement_flight(s, false)
    s.cursor_ok = false
    M.hall_of_meat.set_forced(false)
    s.line = M.Line()
    s.outside_since = 0
end
-- The local player's own line, bail or checkpoint: straight into the referee when leading,
-- else to the leader.
function M.report(s, event, value, extra, at, tags, trick)
    tags = tags or {}
    trick = trick or ""
    if not s.game or not M.playing(s.game) or not M.standing(s.game, M.self_id(s)) then return end
    local g = s.game
    g.sequence += 1
    if g.referee then
        g.referee:event(M.self_id(s), event, value, at, g.sequence, M.now_ms(), tags, trick)
        -- Everyone draws everyone in Skate Tag: the leader's own position goes to the others too.
        if event ~= "position" then return end
    end
    local m = M.header(g, "event")
    m.event = event
    m.value = value
    m.extra = extra
    m.at = at
    m.sequence = g.sequence
    m.tags = tags
    m.trick = trick
    M.send(s, m)
end
function M.popup(s, text)
    s.popup = text
    s.popup_at = M.now_ms()
end

-- Deathrace cues, soft like Skate 3's: a rising two-note chime through a checkpoint, an arpeggio at
-- the finish, two low notes for a missed gate. His make_cue's WAVs, made sample for sample, ship in
-- sounds/; his race clips (his RCDATA resources) too.
local cues = {checkpoint = "plugin/sounds/cue-checkpoint.wav", finish = "plugin/sounds/cue-finish.wav",
              missed = "plugin/sounds/cue-missed.wav", invite = "plugin/sounds/cue-invite.wav"}
local function play_wave(path)
    local ok, err = pcall(reskate.audio.play, path, {volume = 1})
    if not ok then reskate.log("Game modes: " .. tostring(err), "warn") end
end
function M.play(cue) play_wave(cues[cue] or cues.missed) end
local last_gate = 0
function M.play_race_sound(sound) -- "required", "finish", "recovery"
    local now = M.now_ms()
    if sound == "required" and now - last_gate < 250 then return end
    if sound == "required" then last_gate = now end
    play_wave(sound == "finish" and "plugin/sounds/race-finish.wav" or sound == "recovery" and "plugin/sounds/race-recovery.wav"
              or "plugin/sounds/race-gate.wav")
end
-- The leader's state before the start: who is in, nothing scored yet.
function M.setup_state(s, g)
    local m = M.header(g, "state")
    m.phase = "setup"
    local me = M.Standing()
    me.player, me.up = M.self_id(s), true
    table.insert(m.standings, me)
    for _, id in ipairs(g.joiners) do
        local st = M.Standing()
        st.player, st.up = id, true
        table.insert(m.standings, st)
    end
    return m
end
function M.default_duration(mode)
    if mode == "meat" then return 180 end
    if mode == "race" then return M.race_deadline_ms // 1000 end
    if mode == "tag" then return 240 end
    if mode == "infection" then return 300 end
    if mode == "hide" then return 360 end
    return 300
end
function M.local_meat_game()
    local s = M.state()
    return s.game ~= nil and s.game.settings.mode == "meat" and s.game.state ~= nil and s.game.state.phase == "playing"
        and M.standing(s.game, M.self_id(s)) ~= nil
end
function M.official_meat() return M.local_meat_game() and M.hall_of_meat.available() end
function M.infected_look(player)
    local s = M.state()
    if not s.game or not s.game.state or not M.hunt_like(s.game.settings.mode) then return false end
    local phase = s.game.state.phase
    if phase ~= "playing" and phase ~= "results" then return false end
    local p = M.standing(s.game, player)
    return p ~= nil and p.up and not p.out
end

-- ---- what his C++ called directly, through the API ---------------------------------------------------
-- overlay::hide_game_buttons / hold_game_buttons / pause_game_input(true): one call with all three.
function M.game_buttons(s)
    local sent = s.buttons_sent
    if s.pause_input or not sent or sent[1] ~= s.hidden_buttons or sent[2] ~= s.held_buttons then
        reskate.input.game_buttons(s.hidden_buttons, s.held_buttons, s.pause_input)
        s.buttons_sent = {s.hidden_buttons, s.held_buttons}
    end
    s.pause_input = false
end
-- ReSkate's Hall of Meat (a plugin): its exposed functions; without it, none.
local hom, hom_tried = nil, -1e12
local function hall()
    if hom then return hom end
    local now = M.now_ms()
    if now - hom_tried < 5000 then return nil end
    hom_tried = now
    local lib = reskate.require_plugin("hall-of-meat")
    hom = lib
    return hom
end
local function hom_call(name, ...)
    local lib = hall()
    if not lib then return nil end
    local ok, result = pcall(lib[name], ...)
    if not ok then
        hom = nil
        return nil
    end
    return result
end
M.hall_of_meat = {
    available = function() return hom_call("available") == true end,
    switched_on = function() return hom_call("switched_on") == true end,
    set_forced = function(on) hom_call("set_forced", on) end,
    set_enabled = function(on) hom_call("set_enabled", on) end,
    take_finished_bail = function() return hom_call("take_finished_bail") end,
}
-- His trick feed: what the trick list wrote since the last call (the trick_notes event fills it).
local notes = {}
function M.queue_trick_notes(list)
    for _, n in ipairs(list) do
        if #notes < 256 then table.insert(notes, n) end
    end
end
function M.take_trick_notes()
    local out = notes
    notes = {}
    return out
end
function M.one_up_match()
    local runtime = M.one_up
    return runtime and runtime.match_id() or "0"
end
-- His one_up::view(): the 1-UP runtime's last published View, or nil.
function M.one_up_view()
    local runtime = M.one_up
    return runtime and runtime.view and runtime.view() or nil
end
-- The trick logger is not ported: what it was told goes nowhere.
function M.skate_note(_line) end
function M.take_notices()
    local s = M.state()
    local out = s.notices
    s.notices = {}
    return out
end

return M
