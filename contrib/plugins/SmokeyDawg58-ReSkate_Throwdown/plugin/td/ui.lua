-- SmokeyDawg58's Throwdowns UI, as the throwdown kit's documents (reskate.throwdowns.ui): what his
-- native UI (HIS/UI/NativeMenu/one_up_menu.cpp, throwdown_modes_ui.inl, one_up_match_panel.inl,
-- throwdown_map_identity.inl) made of his game layer's NativeView and ModesHud, branch for branch,
-- now data the SDK's general native renderer draws. This file: the setup page (his official_setup and
-- native_setup_capabilities), the waiting card (waiting_hud), the match panel (match_panel_view), the
-- flags (throwdown_map_identity's stats) and what a match asks of the game (mode_bridge.cpp's derive,
-- infected/hidden players, 1-UP's hides/waits_offboard/countdown_locks_input). The HUD is
-- td/ui_hud.lua's, 1-UP's td/ui_oneup.lua's, the events td/ui_events.lua's.
local M = require("td/core")
local ML = require("td/h/mode_lobby")
local RR = require("td/h/race_route")

-- His challenge_registry's definitions, by mode (plugin/modes.lua).
local defs = {}
for _, d in ipairs(require("modes")) do defs[d.id] = d end
M.definitions = defs

-- native_hud_race_time(ms): mm:ss.mmm.
function M.race_time(ms)
    ms = math.max(0, math.floor(ms))
    return string.format("%02d:%02d.%03d", ms // 60000, (ms // 1000) % 60, ms % 1000)
end
-- A standing's place as his rows wrote it: std::to_string(i+1) + st/nd/rd/th (i from 0).
function M.ordinal(i)
    return tostring(i + 1) .. (i == 0 and "st" or i == 1 and "nd" or i == 2 and "rd" or "th")
end
local function upper(text) return string.upper(text) end

-- ---- the setup page (official_setup, native_setup_capabilities) -------------------------------------
-- His Trick Zone sizes and Tricks words (native_setup_capabilities).
M.zone_sizes = {0, 10, 20, 35, 60}
M.trick_words = {"all", "flips", "grinds", "grabs"}
local function setup_doc(s, st)
    local g = s.game
    if not g or not g.leading or g.settings.mode ~= st.mode or g.native_flag_placed then return nil end
    local mode = g.settings.mode
    local d = defs[mode]
    if not d then return nil end
    local deathrace, hide_timer, letters = mode == "race", mode == "hide", mode == "skate"
    local doc = {mode = mode, title = d.name, art = d.art, description = d.description, back = "BACK",
                 players = {caption = "Players", min = 1, max = 6, step = 1, value = g.capacity}, rows = {}}
    -- The stock Timer row: Deathrace's finish deadline, R.E.S.K.A.T.E.'s turn (it has no game clock),
    -- the others' duration.
    if deathrace then
        doc.timer = {caption = "Finish deadline", min = 30, max = 3600, step = 30, value = g.settings.duration_s}
    elseif letters then
        doc.timer = {caption = "Turn Timer", min = 10, max = 120, step = 5, value = g.settings.turn_s}
    else
        doc.timer = {caption = hide_timer and "Duration" or "Timer", min = 30, max = 3600, step = 10, value = g.settings.duration_s}
    end
    if deathrace then return doc end -- Deathrace keeps the stock rows only
    local rows = doc.rows
    if hide_timer then
        table.insert(rows, {id = "hide_time", kind = "slider", caption = "Hide Timer", min = 10, max = 120, step = 5, value = g.settings.turn_s})
    end
    -- R.E.S.K.A.T.E.: how many letters put a player out (the word's first ones).
    if letters then
        table.insert(rows, {id = "letters", kind = "slider", caption = "Letters", min = 1, max = M.max_strikes, step = 1, value = g.settings.strikes})
    end
    -- R.E.S.K.A.T.E.: which tricks can be set, picked left/right like Allow Join.
    if letters then
        local kinds = g.settings.trick_kinds
        local selected = kinds == M.trick_flips and 1 or kinds == M.trick_grinds and 2 or kinds == M.trick_grabs and 3 or 0
        table.insert(rows, {id = "tricks", kind = "choice", caption = "Tricks", options = {"All tricks", "Flips only", "Grinds only", "Grabs only"},
                            value = selected + 1})
    end
    -- R.E.S.K.A.T.E.'s trick zone: a size around its start flag (cones on its edge), as Spot Battle's
    -- area, picked left/right; the free-placed area is for the other challenges.
    if letters then
        local selected = 0
        for i, size in ipairs(M.zone_sizes) do
            if math.abs(g.settings.area_radius - size) < .5 then selected = i - 1 end
        end
        if M.reskate_custom_zone(g.settings, g.zone_custom) then selected = 5 end -- Custom: cones placed after the start flag
        table.insert(rows, {id = "zone", kind = "choice", caption = "Trick Zone", options = {"Anywhere", "Small", "Medium", "Large", "Huge", "Custom"},
                            value = selected + 1})
    end
    if not d.needs_points and not letters then
        table.insert(rows, {id = "area", kind = "button", caption = "Area", label = #g.settings.corners == 0 and "Set optional area" or "Change area"})
    elseif mode == "domination" then
        table.insert(rows, {id = "capture-spots", kind = "button", caption = "Capture Spots", label = #g.settings.points == 0 and "Place spots" or "Add spots"})
    end
    local offer_mode = upper(d.name)
    for _, offer in ipairs(s.hud.offers or {}) do
        if not offer.own and offer.open and offer.mode == offer_mode then
            table.insert(rows, {id = "join-" .. offer.id, kind = "button", caption = "Join", label = offer.host})
            if #rows >= 8 then break end
        end
    end
    return doc
end

-- ---- the waiting card (waiting_hud, a game mode's flag) ----------------------------------------------
local function waiting_doc(s)
    local g = s.game
    if not g or not g.native_lobby or not g.native_flag_placed or g.referee or (g.state and g.state.phase ~= "setup") then return nil end
    -- While an editor is open over the placed flag (Deathrace's route, R.E.S.K.A.T.E.'s cones) its
    -- HUD is the lobby: the card stays hidden until it closes (the flag's registration lives on).
    if s.placing ~= "none" then return nil end
    local d = defs[g.settings.mode]
    if not d then return nil end
    local n = s.native
    local lobby = n.waiting
    local guest = not g.leading
    local message
    if n.waiting_status ~= "" then message = n.waiting_status
    elseif lobby then message = guest and "Enrolled  |  Waiting for host" or "Enrolled skaters  |  Host starts"
    else message = n.waiting_status end
    return {mode = g.settings.mode, title = d.name, art = d.art, status = message,
            enrolled = g.state and ML.lobby_enrolled_count(g.state) or 1, capacity = g.capacity, can_start = lobby and not guest}
end

-- ---- the match panel (match_panel_view, a game mode) -------------------------------------------------
-- R.E.S.K.A.T.E.'s letters as the panel shows them: "R E S - - - -" reads "R.E.S", none yet "-".
local function reskate_earned_letters(spelled)
    local letters = ""
    for ch in string.gmatch(spelled, "[A-Z]") do
        if letters ~= "" then letters ..= "." end
        letters ..= ch
    end
    return letters == "" and "-" or letters
end
local descriptions = {
    jam = "TOTAL SCORE\nAccumulate the most points across all your tricks to win.",
    meat = "BAIL SCORE\nScore the biggest bail before time runs out.",
    domination = "CONTROL THE SPOTS\nBeat each spot's score to take control. Hold the most spots to win.",
    graffiti = "CLAIM THE MOST\nLand tricks on spots to claim them. Finish with the most claims.",
    tag = "SKATE TAG\nTag another skater when you're it. Avoid being caught.",
    infection = "STAY CLEAR\nAvoid infected skaters. Once caught, join the hunt.",
    hide = "HIDE & SEEK\nHide during the countdown, then avoid the seeker.",
}
-- His mode_racer_time: (DNF) and the racer's time, advanced from the state's sample while racing.
function M.racer_time(n, row, now)
    local running = n.state and n.state.phase == "playing" and not row.out and math.max(0, row.score) < #n.settings.points
    local deadline = n.settings.duration_s * 1000
    local observed = math.max(0, row.aux)
    local extra = (running and n.state_sampled_ms ~= 0 and now > n.state_sampled_ms) and now - n.state_sampled_ms or 0
    local elapsed = observed >= deadline and deadline or observed + math.min(extra, deadline - observed)
    return (row.out and "DNF  " or "") .. M.race_time(elapsed)
end
local function panel_doc(s, now)
    local n, feed = s.native, s.hud
    local st = n.state
    if not n.active or n.placing or not st or st.phase == "setup" or st.phase == "results" then return nil end
    local participant = false
    for _, row in ipairs(st.standings) do
        if row.player == n["local"] then participant = true end
    end
    if not participant then return nil end
    local mode = n.settings.mode
    local d = defs[mode]
    if not d then return nil end
    local timer_caption = d.supports_turns and "Turn Timer" or "Timer"
    local timer = tostring(d.supports_turns and n.settings.turn_s or n.settings.duration_s) .. "s"
    local score_caption = mode == "race" and "Time" or "Score"
    local rule_caption, rule_value, rule_icon = "Area", M.has_area(n.settings) and "Selected area" or "Whole map", "rounds"
    local description = descriptions[mode] or d.description
    local prompts = {}
    local portrait = nil
    if mode == "race" then
        local rewind = false
        for _, row in ipairs(st.standings) do
            if st.phase == "playing" and row.player == n["local"] and not row.out and row.score >= 0 and row.score < #n.settings.points then rewind = true end
        end
        description = "FASTEST TIME\nPass Required gates in order. Guides are optional. Reach the red Finish."
        timer_caption = "Time Limit"
        timer = M.race_time(n.settings.duration_s * 1000)
        rule_caption = "Required Gates"
        rule_value = tostring(M.mandatory_gates(n.settings, #n.settings.points - ((n.settings.race_finish and #n.settings.points > 0) and 1 or 0)))
        rule_icon = d.art -- his Required Gates setting shows the mode's logo
        -- His HUD's second prompt over the panel's. Its D-pad Up is read by his game layer itself
        -- (placing.lua's checkpoint_back_press), so its panel_command does nothing more.
        if rewind then table.insert(prompts, {input = "UI_DpadUp", caption = "Go back to previous gate", command = "rewind"}) end
    elseif mode == "skate" then
        -- R.E.S.K.A.T.E.: short lines that fit the rules panel, a letters column and the trick zone.
        description = "COPY OR TAKE A LETTER\nSpell R.E.S.K.A.T.E. and you're out."
        score_caption = "Letters"
        portrait = "steam"
        rule_caption = "Trick Zone"
        local radius = n.settings.area_radius
        rule_value = n.zone_custom and "Custom" or radius <= 0 and "Anywhere" or radius <= 10 and "Small" or radius <= 20 and "Medium"
            or radius <= 35 and "Large" or "Huge"
    end
    local players = {}
    for i, standing in ipairs(st.standings) do
        local name = feed.rows[i] and feed.rows[i].name
        if not name then
            for _, player in ipairs(n.names) do
                if player.id == standing.player then name = player.name end
            end
        end
        local value
        if mode == "race" then value = M.racer_time(n, standing, now)
        elseif mode == "skate" then value = reskate_earned_letters(feed.rows[i] and feed.rows[i].value or "")
        else value = feed.rows[i] and feed.rows[i].value or tostring(standing.score) end
        table.insert(players, {id = standing.player, name = name or standing.player, value = value, portrait = portrait,
                               self = standing.player == n["local"]})
    end
    return {title = d.name, description = description, art = d.art, score_caption = score_caption, quit = "QUIT",
            settings = {{icon = "players", caption = "Players", value = tostring(#players)}, {icon = "timer", caption = timer_caption, value = timer},
                        {icon = rule_icon, caption = rule_caption, value = rule_value}},
            prompts = prompts, players = players}
end

-- ---- the flags (his own game's flag, for the others; throwdown_map_identity's stats) ------------------
local function flags_doc(s)
    local g = s.game
    if not s.session or not g or not g.leading or not g.native_flag_placed or g.referee then return nil end
    local phase = g.state and g.state.phase or "setup"
    if phase ~= "setup" and phase ~= "countdown" then return nil end
    local st = g.settings
    if st.mode == "race" and not RR.race_route_ready(st, st.race_finish) then return nil end
    local at = M.game_spot(st)
    if not at then return nil end
    local race = st.mode == "race"
    local players = g.state and #g.state.standings or 1
    -- The remote map card's three stats (throwdown_map_identity's custom_throwdown_flag_info branch).
    return {{id = "game-" .. tostring(g.id), mode = st.mode, leader = M.self_id(s), game = g.id, at = at,
             yaw = race and M.gate_heading(st, 0) or 0, players = players, capacity = g.capacity,
             open = phase == "countdown" or M.race_lobby_open(s, g),
             stats = {{title = "Players", value = tostring(players)},
                      {title = race and "Required Gates" or "Duration",
                       value = race and tostring(M.mandatory_gates(st, #st.points)) or tostring(st.duration_s) .. "s"},
                      {title = "Time Limit", value = M.race_time(st.duration_s * 1000)}}}}
end

-- ---- what a running match asks of the game (mode_bridge.cpp's derive, game_modes' hides) --------------
local held = false
local function match_doc(s, oneup)
    local n = s.native
    local hidden = {}
    -- Hide & Seek: the hiders other players do not see (hidden_player: playing, not up, not out).
    if n.active and n.state and n.state.phase == "playing" and n.settings.mode == "hide" then
        for _, p in ipairs(n.state.standings) do
            if p.player ~= n["local"] and not p.up and not p.out then table.insert(hidden, p.player) end
        end
    end
    for _, id in ipairs(oneup.hidden or {}) do table.insert(hidden, id) end
    -- His board holds: the race countdown and a checkpoint return keep the board still.
    local hold = s.race_countdown or s.recovering
    if hold ~= held then
        held = hold
        pcall(reskate.skater.hold, hold)
    end
    local markers = s.markers_restricted or oneup.markers
    return {markers = markers, input_lock = s.input_locked or oneup.input_lock, offboard = oneup.offboard, hidden = hidden,
            teleports = s.active or oneup.teleports, in_activity = markers}
end

-- ---- every document ----------------------------------------------------------------------------------
-- The documents of this tick: the game modes' and 1-UP's, whichever is on. Idle: no HUD.
function M.build_ui(s, now)
    local st = reskate.throwdowns.flag.state()
    local oneup = M.ui_oneup and M.ui_oneup(st, now) or {}
    local doc = {flags = {}}
    if st.mine and st.busy and not st.waiting and st.mode then
        if st.mode == "oneup" then doc.setup = oneup.setup else doc.setup = setup_doc(s, st) end
    end
    doc.waiting = waiting_doc(s) or oneup.waiting
    local hud = M.ui_game_hud(s, now)
    if hud then doc.hud = hud else doc.hud = oneup.hud end
    doc.panel = panel_doc(s, now) or oneup.panel
    for _, f in ipairs(flags_doc(s) or oneup.flags or {}) do table.insert(doc.flags, f) end
    doc.match = match_doc(s, oneup)
    return doc
end

return nil
