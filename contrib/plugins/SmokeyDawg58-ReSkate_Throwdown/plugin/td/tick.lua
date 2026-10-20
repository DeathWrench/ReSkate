-- His session tick and message receiver (game_modes.cpp lines 2829-3107), line for line.
local M = require("td/core")
local RR = require("td/h/race_route")

local forced_meat = nil -- the last Hall of Meat hold asked for (his set_forced, each tick)

-- input: {local, local_name, peers = {{id, name}}, in_world, world, barred}. Returns the messages
-- to send to every other player (none without a session).
function M.tick(input)
    local s = M.state()
    local now = M.now_ms()
    s.session = M.nz(input["local"])
    if s.game and ((M.placement("local_throwdown") and not M.placement("race_owned")
            and not M.placement("mode_owned", nil, s.game.id)) or M.nz(M.one_up_match()) or not input.in_world or input.barred) then
        M.end_game(s, "Challenge cancelled: another activity started or the world is unavailable.")
    end
    if not s.session and next(s.lobby_counted) ~= nil then -- left the lobby: a new one starts a new leaderboard
        s.lobby = {}
        s.lobby_counted = {}
        s.lobby_recent = {}
        s.lobby_played = {}
        s.lobby_leader = "0"
    end
    s.barred = input.barred
    if input["local"] ~= s["local"] or input.world ~= s.world then
        if s.game then M.end_game(s, "The game ended: the session or map changed.") end
        s.sat_out = {}
        s.offers = {}
        s.join_target = nil
        s.invite_at, s.invite_leader = 0, "0"
        s.invite_game = 0
        s.announcements = {}
    end
    s["local"] = input["local"]
    s.world = input.world
    if input.in_world then
        local map = input.map or ""
        if map ~= "" then s.course_map = map
        elseif s.course_map == "" then s.course_map = input.world end
    end
    s.local_name = input.local_name
    s.present = {}
    for _, peer in ipairs(input.peers) do
        s.present[peer.id] = true
        if peer.name ~= nil and peer.name ~= "" then s.names[peer.id] = peer.name end
    end
    local ok, err = pcall(function()
        M.track_skater(s, input.in_world, now)
        local start, flag, native_start, native_quit, route_action = s.race_start, s.native_flag, s.native_start, s.native_quit, s.route_action
        s.race_start, s.native_flag, s.native_start, s.native_quit, s.route_action = nil, nil, nil, nil, nil
        if native_quit and s.game and s.game.id == native_quit.game and s.world == native_quit.world then M.command("quit", {}) end
        if start and s.game and s.game.settings.mode == "race" and s.game.leading and not s.game.referee and s.game.id == start.game
            and s.world == start.world then
            local g = s.game
            local transition, finish = RR.accept_race_flag(g.settings, g.race_finish_placed, start.at, start.yaw, s.draft_width)
            if finish ~= nil then g.race_finish_placed = finish end
            if transition ~= "rejected" then
                g.native_lobby, g.native_flag_placed = true, true
                g.native_flag_yaw = start.yaw
                s.route_history:rebase_start(g.settings)
                M.settings_changed(g)
                s.race_object = 1
                s.placing = "points"
                s.race_resume_editor = false
                s.pad_previous = 0xFFFFFFFF
                s.keys_previous = {true, true, true, true}
                s.cycle_left, s.cycle_right = true, true
                s.placing_tick = 0
                s.cursor_ok = false
            end
        end
        if flag and s.game and s.game.settings.mode ~= "race" and s.game.native_lobby and s.game.leading and not s.game.referee
            and s.game.id == flag.game and s.world == flag.world then
            local g = s.game
            g.settings.spawn = flag.at
            g.settings.has_spawn = true
            g.native_flag_yaw = flag.yaw
            g.native_flag_placed = true
            -- R.E.S.K.A.T.E.'s trick zone is centred on its start flag, as Spot Battle's area.
            if g.settings.mode == "skate" and g.settings.area_radius > 0.0 then g.settings.corners = {flag.at} end
            M.settings_changed(g)
            -- A custom zone: its cones are placed now, one at each corner, as Deathrace's gates are.
            if g.settings.mode == "skate" and g.zone_custom and s.placing == "none" then
                g.settings.corners = {}
                g.settings.area_radius = 0.0
                M.settings_changed(g)
                s.placing = "corners"
                s.pad_previous = 0xFFFFFFFF
                s.keys_previous = {true, true, true, true}
                s.placing_tick = 0
                s.cursor_ok = false
            end
        end
        if native_start and s.game and s.game.native_lobby and s.game.native_flag_placed and s.game.leading and not s.game.referee
            and s.placing == "none" and s.game.id == native_start.game and s.world == native_start.world then
            local result = M.command("start", {})
            if M.starts_with(result, "error:") then M.popup(s, string.sub(result, 8)) end
        end
        if route_action and s.game and s.game.leading and s.game.id == route_action.game and s.world == route_action.world and s.route_dialog ~= 0 then
            M.command("route-" .. route_action.action, {route_action.argument})
        end
        M.run_placing(s, now)
        M.run_invites(s, now)
        if s.game then
            if s.game.leading then M.run_leader(s, s.game, now)
            else M.run_player(s, s.game, now) end
        end
        M.line_up(s)
        if s.game and s.game.settings.mode == "race" and s.game.state then
            local g = s.game
            local me = M.standing(g, M.self_id(s))
            if me and not me.out then
                local cue = g.countdown_audio:update(g.state.phase, g.state.remaining_ms)
                if cue then pcall(reskate.audio.play_ui, cue == "go" and "go" or "countdown") end
            end
            if me then
                local before = g.progress_audio.heard
                local cue = g.progress_audio:update(g.settings, g.state.phase, me.score, me.out)
                if g.progress_audio.heard > before then
                    g.checkpoint_fallback:advanced()
                    g.recovery_speed_guard:reset()
                    g.gate_crossed = false
                    g.miss_pending = false
                    g.have_along = false
                    if cue ~= "none" then M.play_race_sound(cue == "finish" and "finish" or "required") end
                    if cue == "required" then
                        local passed = M.mandatory_gates(g.settings, me.score)
                        local total = M.mandatory_gates(g.settings, #g.settings.points)
                        M.popup(s, passed == total and "All required gates cleared! Head to the red finish"
                            or string.format("Required gates %d/%d", passed, total))
                    end
                end
            end
        end
        M.track_game(s, now)
        -- Hall of Meat games: ReSkate's Hall of Meat held on while one is played (not saved; the
        -- menu's switch is the player's own), and every bail that hurt a bone scored with its Meat.
        local official = M.official_meat()
        if official ~= forced_meat then
            M.hall_of_meat.set_forced(official)
            forced_meat = official
        end
        M.run_skate(s, now)
        -- Everyone with game modes says so every few seconds: the menu lists them, and a game of
        -- another version that cannot read it tells its player to update.
        if s.session and now - s.hello_sent >= 5000 then
            local hello = M.Message()
            hello.kind = "hello"
            hello.leader = M.self_id(s)
            hello.game = 1
            if M.nz(hello.leader) then M.send(s, hello) end
            s.hello_sent = now
        end
        if official then
            local bail = M.hall_of_meat.take_finished_bail()
            if bail and bail.shown and bail.meat > 0 then
                M.report(s, "bail", bail.meat, 0, s.position)
                M.popup(s, "Meat: " .. M.grouped(bail.meat))
            end
        end
        M.build_hud(s, now)
        M.world_tick(s, now)
    end)
    if not ok then
        reskate.log("Game-mode tick failed: " .. tostring(err), "error")
        if s.game then M.end_game(s, "Challenge cancelled after a runtime error.") end
    end
    local out = s.outbox
    s.outbox = {}
    if not s.session then out = {} end
    return out
end

local transfers = nil
local function mode_name(key)
    local mode = M.parse_mode(key)
    return if mode then M.mode_name(mode) else key
end

-- One game mode message from another player. False when the bytes are not one.
function M.receive(sender, bytes)
    local s = M.state()
    transfers = transfers or M.ModeTransfers.new()
    local now = M.now_ms()
    local decoded, why, version = M.receive_mode_bytes(transfers, sender, bytes, now)
    if why == "none" then return false end
    if why == "partial" then return true end
    if not decoded then
        -- Another version's message (a hello, every few seconds, at the least): say whose, and which of
        -- the two has to restart to update.
        if version and version ~= 0 and version ~= M.wire_version then
            s.other_version[sender] = version
            s.modded[sender] = now
            if not s.version_told[sender] then
                s.version_told[sender] = true
                M.notice(s, version > M.wire_version
                    and M.name_of(s, sender) .. " has a newer ReSkate game modes: restart your game so it updates, then you can play together."
                    or M.name_of(s, sender) .. " has an older ReSkate game modes: they need to restart their game so it updates.")
                reskate.log(string.format("Game modes: player %s speaks version %d (this game %d).", sender, version, M.wire_version))
            end
        end
        return true
    end
    local m = M.message_from(decoded)
    if not s.modded[sender] then reskate.log(string.format("Game modes: player %s has game modes (version %d).", sender, M.wire_version)) end
    s.modded[sender] = now
    s.other_version[sender] = nil
    if m.kind == "hello" then return true end
    local ours = s.game ~= nil and s.game.leader == m.leader and s.game.id == m.game
    local key = M.pair_key(m.leader, m.game)
    if m.kind == "setup" then
        if sender ~= m.leader or s.sat_out[key] then return true end
        if ours then
            if not s.game.leading and not M.same(s.game.settings, m.settings) then s.game.settings = m.settings end
            s.game.heard = now
            return true
        end
        -- Someone else's game: offered, like a throwdown drop, never joined without asking.
        local found
        for _, o in ipairs(s.offers) do
            if o.leader == m.leader and o.game == m.game then found = o break end
        end
        if not found then
            -- A leader's new game replaces their old offer.
            -- Announced once its leader's state says it is still taking players.
            M.erase_if(s.offers, function(o) return o.leader == m.leader end)
            table.insert(s.offers, M.Offer(m.leader, m.game, m.settings, now))
        else
            found.settings = m.settings
            found.heard = now
        end
    elseif m.kind == "state" then
        if ours and not s.game.leading and sender == m.leader then
            s.game.state = m
            s.game.state_sampled_ms = now
            s.game.heard = now
            M.record_result(s, m.leader, m.game, s.game.settings.mode, m)
            M.announce_match(s, m.leader, m.game, s.game.settings, m, now)
        elseif not ours and sender == m.leader then
            for _, o in ipairs(s.offers) do
                if o.leader == m.leader and o.game == m.game then
                    M.record_result(s, o.leader, o.game, o.settings.mode, m) -- a game played without us counts too
                    o.phase = m.phase
                    o.players = math.max(1, #m.standings)
                    o.heard = now
                    o.confirmed = true
                    M.announce_match(s, o.leader, o.game, o.settings, m, now)
                end
            end
        end
    elseif m.kind == "event" then
        if ours and s.game.referee then s.game.referee:event(sender, m.event, m.value, m.at, m.sequence, now, m.tags, m.trick) end
        -- Skate Tag: where every other player is, for the crown and the arrows.
        if ours and m.event == "position" then s.positions[sender] = {m.at, now} end
    elseif m.kind == "tags" then
        -- Graffiti tag shapes from the leader, from index `first` on.
        if ours and not s.game.leading and sender == m.leader then
            local tags = s.game.tags
            for j = #tags + 1, m.first do tags[j] = M.tag_from(nil) end -- his resize: empty tags before `first`
            for i, t in ipairs(m.tags) do tags[m.first + i] = t end
            s.game.heard = now
        end
    elseif m.kind == "join" then
        if ours and s.game.leading and sender ~= M.self_id(s) then
            -- During setup, require the same saved/native-flag state as the
            -- advertised offer. Countdown joins retain the referee's own gate.
            if not s.game.referee and not M.race_lobby_open(s, s.game) then return true end
            if s.game.referee then
                s.game.referee:add(sender) -- until the countdown ends
            elseif not M.contains(s.game.joiners, sender) and #s.game.joiners + 1 < s.game.capacity then
                table.insert(s.game.joiners, sender)
            end
        end
    elseif m.kind == "leave" then
        if ours and s.game.leading then
            if s.game.referee then s.game.referee:remove(sender, now)
            else
                M.erase(s.game.joiners, sender)
                s.game.state_sent = 0
            end
        end
    elseif m.kind == "ready" then -- Reserved legacy wire action; enrollment is sufficient.
    elseif m.kind == "end" then
        if ours and not s.game.leading and sender == m.leader then
            M.end_game(s, mode_name(s.game.settings.mode) .. " is over.")
        elseif not ours and sender == m.leader then -- someone else's game was stopped: no longer offered
            for _, offer in ipairs(s.offers) do
                if offer.leader == m.leader and offer.game == m.game then
                    local final = M.copy(m)
                    final.phase = "results"
                    M.announce_match(s, m.leader, m.game, offer.settings, final, now)
                end
            end
            s.sat_out[key] = true
            M.erase_if(s.offers, function(o) return o.leader == m.leader and o.game == m.game end)
        end
    end
    return true
end

return nil
