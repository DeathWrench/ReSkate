-- SmokeyDawg58's 1-UP UI (HIS/UI/NativeMenu/one_up_menu.cpp: official_setup's 1-UP page, waiting_hud,
-- native_countdown_hud, native_score_hud, native_results_hud; one_up_match_panel.inl's 1-UP view;
-- throwdown_map_identity's 1-UP stats; HIS/Throwdowns/one_up_placement.cpp's 1-UP flag flow; and
-- HIS/UI/Overlay/one_up_overlay.cpp's ReSkate-menu card) on the throwdown kit, from his 1-UP runtime's
-- View (td/oneup/runtime.lua). 1-UP is an ordinary mode of this plugin now: "oneup".
local M = require("td/core")
local MT = require("td/oneup/match")
local SP = require("td/oneup/spawn")
local nz = MT.nz

local logo = "UI/ReSkate/OneUp/img_OneUp_Blue_1024"
-- His setup page's choices: s.seconds (20 on every open) and s.max_players (kept between opens).
local setup = {game = 0, seconds = 20, players = 4}
-- His HUD's memory: when the match ended (score HUD), each player's elimination turn and the
-- results window (HudResultsWindow), the countdown banner's token.
local memory = {ended_at = 0, results_match = "0", eliminated_at = {}, window_match = "0", window_ended = 0, window_finished = false,
                banner_token = nil, banner_serial = 0}

local function name(v, id)
    local found = v.names[id]
    return (found == nil or found == "") and "Skater" or found
end
local function connected(s)
    local count = 0
    for _, p in ipairs(s.players) do
        if p.connected then count += 1 end
    end
    return count
end
local function points(n) return string.format("%d", math.max(0, math.floor(n))) end
-- HudResultsWindow::visible: from four to sixteen seconds after the match finished.
local function results_window(match, finished, now)
    if memory.window_match ~= match or not finished then
        memory.window_match = match; memory.window_ended = now; memory.window_finished = false
    end
    if not nz(match) or not finished then return false end
    if not memory.window_finished then memory.window_ended = now; memory.window_finished = true end
    local age = now >= memory.window_ended and now - memory.window_ended or 0
    return age >= 4000 and age < 16000
end

-- The 1-UP documents of this tick: {setup, waiting, hud, panel, flags, markers, input_lock, ...}.
function M.ui_oneup(st, now)
    local O = M.one_up
    if not O then return {} end
    local v = O.view()
    local s = v.state
    local out = {}
    local mine = st.mine and st.mode == "oneup"
    -- The native setup page, 1-UP's (official_setup without a game mode).
    out.setup = {mode = "oneup", title = "1-UP", art = logo, back = "BACK",
                 description = "Add up every landed trick before time runs out.\nBeat the previous total. Three penalties and you're out!",
                 players = {caption = "Players", min = 1, max = 6, step = 1, value = setup.players},
                 -- PORT: his page kept the stock Spot Battle timer row's own caption; the kit's row
                 -- needs one, so it says what his map card called it.
                 timer = {caption = "Turn Timer", min = 10, max = 120, step = 10, value = setup.seconds}, rows = {}}
    -- The waiting card (waiting_hud): only its lobby shows it.
    local awaiting = mine and st.owned and not nz(s.match)
    local lobby = awaiting or (nz(s.match) and s.phase == "lobby")
    if lobby and (mine or nz(s.match)) then
        local guest = nz(s.match) and s.leader ~= v["local"]
        out.waiting = {mode = "oneup", title = "1-UP", art = logo,
                       status = guest and "Enrolled  |  Waiting for host" or "Enrolled skaters  |  Host starts",
                       enrolled = awaiting and 1 or connected(s), capacity = awaiting and setup.players or s.config.max_players, can_start = not guest}
    end
    -- The HUD: native_score_hud while the match runs and four seconds after, native_results_hud from
    -- then to sixteen seconds, native_countdown_hud's intro banner and 3-2-1.
    local ended = s.phase == "finished" or s.phase == "cancelled"
    if not ended then memory.ended_at = 0 elseif memory.ended_at == 0 then memory.ended_at = now end
    local show = nz(s.match) and s.phase ~= "lobby" and (not ended or now - memory.ended_at < 4000)
    if memory.results_match ~= s.match or s.phase == "lobby" then
        memory.results_match = s.match
        memory.eliminated_at = {}
    end
    for _, p in ipairs(s.players) do
        if not MT.Player.eligible(p) and memory.eliminated_at[p.id] == nil then memory.eliminated_at[p.id] = s.turn end
    end
    local practice = false
    if v.solo_test and s.phase == "cancelled" then
        for _, p in ipairs(s.players) do
            if p.penalties == 3 then practice = true end
        end
    end
    local finished = nz(s.match) and (s.phase == "finished" or practice)
    local results = results_window(s.match, finished, now) and not M.state().active
    if results then
        local players = table.clone(s.players)
        local winner = s.winner
        local order = {}
        for i, p in ipairs(players) do order[p.id] = i end
        local function eliminated(id) return memory.eliminated_at[id] or MT.UINT32_MAX end
        table.sort(players, function(a, b) -- his std::stable_sort
            if a.id == winner or b.id == winner then
                if (a.id == winner) ~= (b.id == winner) then return a.id == winner end
                return order[a.id] < order[b.id]
            end
            local x, y = eliminated(a.id), eliminated(b.id)
            if x ~= y then return x > y end
            return order[a.id] < order[b.id]
        end)
        local rows = {}
        for i, p in ipairs(players) do
            table.insert(rows, {rank = M.ordinal(i - 1), name = name(v, p.id), self = p.id == v["local"],
                                value = p.id == winner and "WINNER" or not p.connected and "LEFT" or p.penalties >= 3 and "1 U P" or "ACTIVE"})
        end
        out.hud = {theme = "oneup", header = {title = "", art = logo},
                   results = {title = "1-UP RESULTS", caption = "1-UP", rows = rows,
                              notice = practice and "PRACTICE COMPLETE" or (nz(winner) and name(v, winner) .. " WINS!" or "MATCH COMPLETE")}}
    elseif show then
        local hud = {theme = "oneup", header = {title = "1-UP", art = logo}, score_art = "OneUpScore",
                     counters = {"TARGET   " .. points(s.target), "SCORE   " .. points(s.best)},
                     clock = {remaining_ms = s.phase == "playing" and v.remaining or 0, total_ms = s.config.turn_ms, sampled_ms = v.published,
                              ticking = not ended and s.phase == "playing"}}
        local rows = {}
        for _, p in ipairs(s.players) do
            table.insert(rows, {name = name(v, p.id), out = not MT.Player.eligible(p), self = p.id == v["local"],
                                marks = {{text = "1", on = p.penalties > 0}, {text = "U", on = p.penalties > 1}, {text = "P", on = p.penalties > 2}}})
        end
        hud.board = {heading = "list", variant = "stamps", name_art = "OneUpName", out_art = "OneUpEliminated", rows = rows,
                     title = ended and (nz(s.winner) and name(v, s.winner) .. " WINS!" or "MATCH COMPLETE") or name(v, s.active) .. "'S TURN"}
        -- The first half announces the mode using the native Throwdown banner; the final three
        -- seconds use the game's own turn-start 3-2-1 (and GO).
        local countdown = s.phase == "countdown" and not v.positioning
        if countdown then
            local token = s.match .. ":" .. tostring(s.turn) .. ":" .. s.active
            if memory.banner_token ~= token then
                memory.banner_token = token
                memory.banner_serial += 1
            end
            if v.remaining > 3000 then
                hud.banner = {title = "1-UP", subtitle = "Beat the target. Last skater standing wins!", art = logo, serial = memory.banner_serial,
                              ms = math.floor(v.remaining - 3000)}
            else
                hud.countdown = {remaining_ms = v.remaining, total_ms = 3000, sampled_ms = v.published, ticking = true}
            end
        end
        out.hud = hud
    end
    -- The Throwdown Panel (match_panel_view's 1-UP branch).
    if nz(s.match) and v.participant and s.phase ~= "lobby" and s.phase ~= "cancelled" and s.phase ~= "finished" then
        local players = {}
        for _, p in ipairs(s.players) do
            table.insert(players, {id = p.id, name = name(v, p.id), self = p.id == v["local"],
                                   value = not p.connected and "LEFT" or not MT.Player.eligible(p) and "OUT" or string.sub("1UP", 1, p.penalties)})
        end
        out.panel = {title = "1-UP", description = "BEAT THE TARGET\nBeat the previous turn's score. Three penalties and you're out.", art = logo,
                     score_caption = "1-UP", quit = "QUIT", players = players,
                     settings = {{icon = "players", caption = "Players", value = tostring(#players)},
                                 {icon = "timer", caption = "Turn Timer", value = tostring(s.config.turn_ms // 1000) .. "s"},
                                 {icon = "rounds", caption = "Penalties", value = "3"}}}
    end
    -- The hosted lobby's flag, for the others (throwdown_map_identity's 1-UP stats).
    local spot, facing, hosted = O.spot()
    if hosted and nz(s.match) and s.phase == "lobby" and reskate.session.active() then
        local count = connected(s)
        out.flags = {{id = "oneup:" .. s.match, mode = "oneup", leader = v["local"], game = setup.game ~= 0 and setup.game or 1, at = spot,
                      yaw = math.deg(SP.yaw(facing)), players = count, capacity = s.config.max_players, open = true,
                      stats = {{title = "Players", value = tostring(count) .. "/" .. tostring(s.config.max_players)}, {title = "Penalties", value = "3"},
                               {title = "Turn Timer", value = tostring(s.config.turn_ms // 1000) .. "s"}}}}
    end
    -- What 1-UP asks of the game: markers, its countdown's input lock, the others off the board and
    -- hidden while one skater is up, and its own teleports to the start.
    out.markers = O.restricts_session_markers()
    out.input_lock = O.countdown_locks_input()
    out.offboard = O.waits_offboard()
    out.hidden = O.hidden()
    out.teleports = nz(s.match) and s.phase ~= "lobby" and not ended
    return out
end

-- The kit's events for "oneup": his one_up_menu's 1-UP flows and one_up_placement's 1-UP hand-off.
function M.on_oneup_ui(e)
    local O = M.one_up
    if not O then return end
    local args = e.args or {}
    local v = O.view()
    local s = v.state
    local action = e.action
    if action == "open" then
        -- arm_native_setup(20, entry_players): refused while a game mode or an unfinished match is on.
        local ended = s.phase == "finished" or s.phase == "cancelled"
        if M.state().active or (nz(s.match) and not ended) then
            reskate.throwdowns.flag.leave()
            return
        end
        if nz(s.match) then O.queue("leave keep-flag") end
        setup.game = tonumber(args[1] or "") or 0
        setup.seconds = 20
    elseif action == "setup_row" then
        local value = tonumber(args[2] or "")
        if not value then return end
        value = math.round(value)
        if args[1] == "players" then setup.players = math.clamp(value, 1, 6)
        elseif args[1] == "timer" then setup.seconds = math.clamp(value, 10, 120) end
    elseif action == "setup_confirm" then
        -- set_native_setup_options(seconds, players), what the page chose.
        local players, seconds = tonumber(args[1] or ""), tonumber(args[2] or "")
        if players and players >= 1 and players <= 6 then setup.players = math.round(players) end
        if seconds and seconds >= 10 and seconds <= 120 then setup.seconds = math.round(seconds) end
    elseif action == "flag_placed" then
        -- tick_flag_placement's hand-off: create_at_spawn(SpawnRequest{spawn, world, local, seconds, players, facing}).
        if #args < 5 then return end
        O.command("create", {args[2], args[3], args[4], args[5], tostring(setup.seconds), tostring(setup.players)})
    elseif action == "start" then
        if s.leader == v["local"] then O.queue("start") end
    elseif action == "leave" or action == "quit" then
        O.queue("leave")
    elseif action == "join" then
        -- The stock Join on another player's 1-UP flag (the kit adopted it): join <leader> <match>.
        local match = string.match(args[1] or "", "^oneup:(%d+)$")
        if not match or not nz(args[2]) then
            reskate.throwdowns.flag.leave()
            return
        end
        O.queue("join " .. args[2] .. " " .. match)
    end
end

-- ---- the ReSkate menu's 1-UP card (one_up_overlay.cpp one_up_card) --------------------------------------
local phase_text = {lobby = "READY UP", countdown = "GET READY", playing = "TURN SCORE", settling = "TIME UP", feedback = "TURN RESULT",
                    finished = "LAST SKATER STANDING", cancelled = "MATCH ENDED"}
local card_seconds = 20
function M.one_up_card(ui)
    local O = M.one_up
    if not O then
        ui:note("The game modes are still loading.")
        return
    end
    local v = O.view()
    local s = v.state
    local function send(text) O.queue(text) end
    ui:card("1-UP", "Beat the previous turn total. Three penalties and you're out.")
    if not nz(s.match) then
        ui:note("Spot Battle  /  Skate Jam  /  S.K.A.T.E. remain available in the game's Throwdowns menu.")
        card_seconds = math.round(ui:slider("turn-length", "Turn length", card_seconds, 10, 120, "%d seconds"))
        -- PORT: his button was disabled without can_create; a page button cannot be, so it does nothing then.
        if ui:button("place", "Place 1-Up here", true) and v.can_create then send("create " .. tostring(card_seconds)) end
        if not v.scoring_ready then ui:note("Waiting for the game's scoring system...") end
        for _, offer in ipairs(v.offers) do
            local label = (offer.started and "Watch " or "Join ") .. offer.name .. "'s 1-Up"
            if ui:button("offer-" .. offer.leader, label) then send("join " .. offer.leader .. " " .. offer.match) end
        end
        ui:note("Choose a starting spawn. Score tricks anywhere on the map.")
    else
        if s.phase == "finished" then
            ui:heading(name(v, s.winner) .. " WINS!")
            ui:info("Final attempt", name(v, s.judged_player) .. ": " .. string.format("%.0f", s.judged_score))
        else
            ui:heading(phase_text[s.phase] or "1-UP")
        end
        if nz(s.active) then ui:info("Up next", name(v, s.active)) end
        ui:info("Target to beat", string.format("%.0f", s.target))
        ui:info("Total this turn", string.format("%.0f", s.best))
        ui:info("Turn length", tostring(s.config.turn_ms // 1000) .. " seconds")
        -- His roster: the one up marked, each penalty letter lit once earned (here: shown, else "-"),
        -- and Left / Out / Ready / Waiting. PORT: page labels have no colours.
        for _, p in ipairs(s.players) do
            local letters = ""
            for letter = 0, 2 do letters ..= "[" .. (letter < p.penalties and string.sub("1UP", letter + 1, letter + 1) or "-") .. "]" end
            local status = not p.connected and "Left" or p.penalties == 3 and "Out" or s.phase == "lobby" and (p.ready and "Ready" or "Waiting") or ""
            ui:label((p.id == s.active and "> " or "") .. name(v, p.id) .. "  " .. letters .. (status ~= "" and "  " .. status or ""))
        end
        if s.notice ~= "" then ui:note(s.notice) end
        if s.phase == "lobby" then
            if not v.participant then
                if ui:button("rejoin", "Join rematch") then send("enroll") end
            elseif ui:button("ready", "Ready at the starting spot") then
                send("ready")
            end
            if s.leader == v["local"] and ui:button("start", "Start 1-Up", true) then send("start") end
        end
        if s.phase == "finished" and s.leader == v["local"] and ui:button("rematch", "Rematch") then send("rematch") end
        if s.phase == "finished" and s.leader ~= v["local"] then ui:note("The host can open a rematch. Everyone chooses Ready again.") end
        if ui:button("exit", "Exit 1-Up") then send("leave") end
    end
    if v.status ~= "" then ui:note(v.status) end
end

return nil
