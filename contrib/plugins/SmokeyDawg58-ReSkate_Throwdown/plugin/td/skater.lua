-- SmokeyDawg58's game modes (his game_modes.cpp lines 740-1138), ported to Lua line for line: the
-- R.E.S.K.A.T.E. callout and trick key reading, the saved stance, and the local skater (its bails,
-- its lines, its grinds). The trick logger between them (trick_file, flush_trick_log, skate_note,
-- trick_log_command) is not in this build.
local M = require("td/core")
local RM = require("td/h/race_momentum")

-- ---- trainer::telemetry() ----------------------------------------------------------------------------
-- The API's reading of the trainer, the physics watch and the Bone Cam, as his trainer::telemetry(),
-- watched_physics_state(), local_skater_teleport_pending(), bone_cam_slam(), bone_cam_struck() and
-- race_bail_position() gave them; a default-constructed one (no skater, physics state 0) when there
-- is none. Positions are vectors.
-- PORT: his bone_cam_slam() and bone_cam_struck() take their flag (an exchange), and only track_bail
-- read them. The API reads (and so takes) both on every reskate.skater.telemetry() call, so a slam
-- seen by any other call would be lost: they are kept here until track_bail takes them. Every caller
-- should read the telemetry through M.telemetry() for that to hold.
local slam_seen, struck_seen = false, false
function M.telemetry()
    local t = reskate.skater.telemetry()
    if t == nil then
        return {skater = false, airborne = false, position = vector.zero, heading = 0, speed = 0, vertical = 0, air_time = 0, height = 0,
                top_speed = 0, physics_state = 0,
                last = {serial = 0, takeoff_speed = 0, takeoff_angle = 0, air_time = 0, height = 0, distance = 0, drop = 0,
                        landing_speed = 0, spin = 0, spin_rate = 0, flip = 0, board_turn = 0, state = 0, takeoff = vector.zero,
                        landing = vector.zero},
                watch = {valid = false, ragdoll_known = false, ragdoll = false, state = 0, previous = 0, previous_seconds = 0, changes = 0,
                         wipeouts = 0, runouts = 0},
                teleport_pending = false, slam = false, struck = false, body = nil}
    end
    t.position = M.V(t.position)
    t.last.takeoff = M.V(t.last.takeoff)
    t.last.landing = M.V(t.last.landing)
    t.body = M.V(t.body)
    if t.slam then slam_seen = true end
    if t.struck then struck_seen = true end
    return t
end
local function bone_cam_slam()
    local seen = slam_seen
    slam_seen = false
    return seen
end
local function bone_cam_struck()
    local seen = struck_seen
    struck_seen = false
    return seen
end

-- R.E.S.K.A.T.E.'s callout for the referee's latest calls (Skate 3's "Trick set!"): a player out,
-- then a letter ("SMOKEY  R.E.S"), then a set or a copy landed. Empty when none of them is new.
local function upper(text)
    return (string.gsub(text, "[a-z]", string.upper))
end
local function is_letters(text)
    if #text == 0 or #text % 2 == 0 then return false end
    for i = 0, #text - 1 do
        local c = string.sub(text, i + 1, i + 1)
        if i % 2 == 1 then
            if c ~= "." then return false end
        elseif not (c >= "A" and c <= "Z") then
            return false
        end
    end
    return true
end
-- std::string::rfind: the last place `what` starts (1-based), or nil.
local function rfind(text, what)
    local at = nil
    local from = 1
    while true do
        local i = string.find(text, what, from, true)
        if not i then return at end
        at = i
        from = i + 1
    end
end
function M.letters_callout(calls)
    for _, call in ipairs(calls) do
        if M.ends_with(call, " is out") then return upper(call) end
    end
    for _, call in ipairs(calls) do
        local colon = rfind(call, ": ") -- 1-based: his colon is colon - 1
        if colon and is_letters(string.sub(call, colon + 2)) then
            -- "Smokey missed: R.E" -> "SMOKEY  R.E"; the name is the call's words before the reason.
            local space = string.find(call, " ", 1, true)
            local length = (space == nil or space > colon) and colon - 1 or space - 1
            return upper(string.sub(call, 1, length)) .. "  " .. string.sub(call, colon + 2)
        end
    end
    for _, call in ipairs(calls) do
        if string.find(call, " set the ", 1, true) then return "TRICK SET!" end
        if M.ends_with(call, " landed it") then return "TRICK COPIED!" end
        if M.ends_with(call, " missed the set") then return "FAILED TO SET TRICK" end
        if M.ends_with(call, ": already set") then return "ALREADY BEEN DONE" end
        if M.ends_with(call, ": not in this game") then return "NOT IN THIS GAME" end
        if M.ends_with(call, "ran out of time to set") then return "OUT OF TIME" end
    end
    return ""
end
-- A trick named only by its text key, readable: "ID_TRICK_BSBONELESSBACKGRAB" -> "Boneless Back
-- Grab". Known words are split off greedily; anything else stays as one word.
local words = {
    "BONELESS", "BACKSIDE", "FRONTSIDE", "FASTPLANT", "FOOTPLANT", "HANDPLANT", "NOSEBONE", "TAILBONE", "STALEFISH", "SEATBELT",
    "DOUBLE", "SHIFTY", "WEDDLE", "GROUND", "INVERT", "NOLLIE", "OLLIE", "FRONT", "PLANT", "TWEAK", "STALE", "MELON", "INDY",
    "BACK", "FOOT", "HAND", "GRAB", "NOSE", "TAIL", "DARK", "ONE", "AIR", "NO", "TO"}
function M.readable_trick_key(key)
    local rest = string.sub(key, 10) -- after "ID_TRICK_"
    local text = ""
    local function add(word)
        if #text > 0 then text ..= " " end
        if word == "BS" or word == "FS" then
            text ..= word
            return
        end
        text ..= string.sub(word, 1, 1)
        text ..= (string.gsub(string.sub(word, 2), "[A-Z]", string.lower))
    end
    -- Its side is skate.'s own side field ("BS"), added with the rest of the trick: not repeated here.
    if M.starts_with(rest, "BS") or M.starts_with(rest, "FS") then rest = string.sub(rest, 3) end
    local pending = ""
    while #rest > 0 do
        local found = nil
        for _, w in ipairs(words) do
            if M.starts_with(rest, w) then
                found = w
                break
            end
        end
        if found == nil then
            if string.sub(rest, 1, 1) ~= "_" then pending ..= string.sub(rest, 1, 1) end
            rest = string.sub(rest, 2)
            continue
        end
        if #pending > 0 then
            add(pending)
            pending = ""
        end
        add(found)
        rest = string.sub(rest, #found + 1)
    end
    if #pending > 0 then add(pending) end
    return if #text == 0 then key else text
end
-- R.E.S.K.A.T.E.: the player's stance for the stick pictures, kept between launches ("goofy" or
-- "regular"; missing: regular). His build kept it in %LOCALAPPDATA%\ReSkate\stance.txt (stance_file());
-- a plugin has no files of its own to write, so the same word is kept in the plugin's storage
-- (reskate.storage), under the key "stance".
function M.load_stance()
    local ok, word = pcall(reskate.storage.get, "stance")
    return ok and word == "goofy"
end
function M.save_stance(goofy)
    pcall(reskate.storage.set, "stance", if goofy then "goofy" else "regular")
end

-- ---- the local skater ----------------------------------------------------------------
-- (official_meat is core's.)
-- Bails are watched before anything else: during a ragdoll the trainer may have no skater to
-- measure, but the physics state the bail hook reports keeps coming.
local function in_(state, first) return state >= first and state < first + 100 end
function M.track_bail(s, physics, vertical, now, dt)
    local movement = M.telemetry()
    local watch = movement.watch
    -- A wipeout loses the line and starts measuring the bail: the counter the trainer keeps for
    -- state 300, any other wipeout state (300-399), or a hard fall straight off the board.
    local deathrace = s.game ~= nil and s.game.settings.mode == "race"
    local jump_pad = reskate.input.pad_bits()
    s.race_hippy:input(jump_pad ~= nil and bit32.band(jump_pad, 0x5000) == 0x5000,
        s.on_board or (physics >= 100 and physics < 300), now)
    local ragdoll_edge = s.ragdoll_bail:observe(watch.ragdoll_known, watch.ragdoll)
    local confirmed_ragdoll = s.race_offboard_ragdoll:observe(watch.ragdoll_known, watch.ragdoll, now)
    -- A 504 animation flag also remains set during a normal hippy jump.
    -- Classify the jump before allowing that secondary flag to request recovery.
    local bailed = if deathrace then false else ragdoll_edge
    local runout_edge = s.race_runouts:observe(watch.valid, watch.runouts)
    if watch.valid or s.wipeouts_known then
        if not s.wipeouts_known then
            s.wipeouts = watch.wipeouts
            s.wipeouts_known = true
        elseif watch.wipeouts ~= s.wipeouts then
            s.wipeouts = watch.wipeouts
            bailed = true
        end
    end
    if in_(physics, M.wipeout_state) and not in_(s.previous_state, M.wipeout_state) then bailed = true end
    local hard_bail = bailed or in_(physics, M.wipeout_state)
    if deathrace and confirmed_ragdoll then bailed = true end
    if physics >= M.offboard_states_first and in_(s.previous_state, 200) and s.previous_vertical < -6.0 then bailed = true end
    local ragdoll_lost = s.ragdoll_lost
    s.ragdoll_lost = false
    if ragdoll_lost and (not deathrace or not s.race_hippy:taking_off(now)) then bailed = true end
    -- On foot the skater is off the board already, so no state change marks a jump off a roof:
    -- a fall faster than 7.5 m/s (a drop of about 3 m) brought to a stop is the slam.
    -- A reset (state 700) or a teleport moves the skater, it does not slam them.
    local reset = physics == 700 or s.previous_state == 700
    if reset then s.fall_peak = 0 end
    s.fall_peak = math.min(s.fall_peak, vertical)
    -- Off the board: 500-599. Not 600-699, the plants and other on-foot tricks (a handplant is not
    -- a fall).
    local on_foot = not reset and (in_(physics, M.offboard_states_first) or in_(s.previous_state, M.offboard_states_first))
    -- The body stopping dead off the board (a pole, a wall, the ground); on the board the game's
    -- own wipeout states say when a landing went wrong. Only when the game itself had the skater
    -- going fast (7 m/s and more): the pose's own speed jumps about on stairs, in a jump on the
    -- spot and through tricks, and alone it is no proof of anything.
    -- Striking an object at speed (a pole, a tree, a rail) off the board, when the game itself had
    -- the skater going (6 m/s and more). On the board the game wipes the skater out itself when
    -- they really hit something (state 300 and up, a bail already); a landing off a kicker jolts
    -- the pose just like a hit, and the game rolls on (state 100 or 200), so that is no bail.
    -- Read every tick all the same, so a stale strike is not kept for later.
    if bone_cam_struck() and on_foot and s.recent_speed >= 6.0 then
        reskate.log(string.format("Game modes: hit an object at %.1f m/s.", s.recent_speed), "info")
        bailed = true
    end
    local slam = bone_cam_slam()
    if slam and on_foot and s.recent_speed >= 7.0 then
        reskate.log("Game modes: on-foot slam (the body stopped dead).", "info")
        bailed = true
    end
    if vertical > -1.5 then
        if on_foot and s.fall_peak < -7.5 then
            reskate.log(string.format("Game modes: on-foot fall stopped at %.1f m/s.", -s.fall_peak), "info")
            bailed = true
        end
        s.fall_peak = 0
    end
    local hippy = s.race_hippy:observe(watch.valid or movement.skater, physics, if watch.valid then watch.previous else s.previous_state,
        vertical, hard_bail, now, movement.airborne)
    if hippy and not hard_bail then
        bailed = false
        if deathrace then s.race_offboard_ragdoll:reset() end
    end
    local runout = runout_edge and not hippy
    local controlled_offboard = RM.race_recovered_control(watch.valid or movement.skater, physics, watch.ragdoll_known, watch.ragdoll)
    if s.game and s.game.settings.mode == "race" then
        if controlled_offboard then
            s.game.recovery_grace:reset()
        elseif hippy then
            s.game.recovery_grace:cancel_runout()
        end
    end
    -- Checkpoint recovery is independent of the 3.5-second Meat measurement.
    -- A second fall after a quick recovery must not be ignored by that timer.
    if bailed or runout then
        if s.game and s.game.settings.mode == "race" and M.playing(s.game) then
            local g = s.game
            local me = M.standing(g, M.self_id(s))
            if me and not me.out and me.score >= 0 and me.score < #g.settings.points and not g.recovery_pending and
                not (g.gate_crossed and g.settings.race_finish and me.score + 1 == #g.settings.points) then
                if bailed and not controlled_offboard and g.recovery_grace:observe(true, false, now) then
                    g.recovery_speed = g.recovery_speed_guard:limit(g.momentum:before_bail(now), now)
                end
            end
        end
    end
    if bailed and not s.bail.active then
        -- multiplayer::one_up::report_bail(now): the 1-UP port's (as core's one_up_match reads its match).
        local runtime = M.one_up
        if runtime then runtime.report_bail(now) end
        reskate.log(string.format("Game modes: bail (state %d -> %d) at %.1f m/s.", s.previous_state, physics, s.recent_speed), "info")
        -- ReSkate's own Hall of Meat replaces the Bone Cam wherever it runs (its switch, or a Hall of
        -- Meat game holding it on); the Bone Cam stands in only on a game build it does not know.
        if not M.hall_of_meat.available() then reskate.skater.bone_cam("bail") end
        if s.line.tricks ~= 0 then M.popup(s, "Line lost!") end
        s.line = M.Line()
        -- The drop counts from the highest the skater was in the last few seconds: a fall is often
        -- only noticed once it has landed.
        local top = s.position.y
        for _, h in ipairs(s.heights) do top = math.max(top, h[2]) end
        local b = M.Bail()
        b.active = true
        b.started = now
        b.speed = s.recent_speed
        b.start_y = top
        b.min_y = s.position.y
        b.tumble = 0.0
        b.at = s.position
        s.bail = b
    end
    if not s.bail.active and s.skater then
        table.insert(s.heights, {now, s.position.y})
        while #s.heights > 0 and now - s.heights[1][1] > 3000 do table.remove(s.heights, 1) end
    end
    if reset then table.clear(s.heights) end
    s.previous_state = physics
    s.previous_vertical = vertical
    if s.bail.active then
        s.bail.min_y = math.min(s.bail.min_y, s.position.y)
        if in_(physics, M.wipeout_state) or physics >= M.offboard_states_first then s.bail.tumble += dt end
        if now - s.bail.started >= M.bail_settle_ms then
            local score = M.bail_score({speed = s.bail.speed, drop = s.bail.start_y - s.bail.min_y, tumble = s.bail.tumble})
            s.bail.active = false
            -- Where the body came to rest: a dive off a building outside the area still lands in it.
            s.bail.at = s.position
            reskate.log(string.format("Game modes: bail scored %d (%.1f m/s, %.1f m drop, %.1f s).",
                score, s.bail.speed, s.bail.start_y - s.bail.min_y, s.bail.tumble), "info")
            -- Hall of Meat's own Meat scores the bail instead (in the tick, below).
            if not M.official_meat() then
                M.report(s, "bail", score, 0, s.bail.at)
                if s.game and s.game.settings.mode == "meat" then M.popup(s, "Meat: " .. M.grouped(score)) end
            end
        end
    end
end

function M.track_skater(s, in_world, now)
    local t = M.telemetry()
    local dt = if s.last_tick ~= 0 and now > s.last_tick then math.min(0.25, (now - s.last_tick) / 1000.0) else 0.0
    s.last_tick = now
    local skater = in_world and t.skater
    if skater ~= s.skater and (s.bail.active or s.log_states) then
        reskate.log(string.format("Game modes: the skater is %s.", if skater then "back" else "unavailable"), "info")
    end
    -- A full ragdoll takes the skater away from the trainer mid-slam: losing it in the air or at speed is a bail.
    if not skater and s.skater and in_world and not s.bail.active and (s.previous_airborne or s.recent_speed > 2.0) then s.ragdoll_lost = true end
    s.skater = skater
    if skater then
        s.position = t.position
        s.heading = t.heading
        s.previous_airborne = t.airborne
    end
    local physics_watch = t.watch
    local physics = if physics_watch.valid then physics_watch.state else t.physics_state
    -- `mode debug states on`: every physics state change, on the board or off it.
    if s.log_states and in_world and physics ~= s.logged_state then
        reskate.log(string.format("Game modes state: %d -> %d at %.2f, %.2f, %.2f, %.1f m/s, up %.1f%s%s", s.logged_state, physics,
            t.position.x, t.position.y, t.position.z, t.speed, t.vertical, if t.airborne then " (airborne)" else "",
            if skater then "" else " (no skater)"), "info")
        s.logged_state = physics
    end
    s.on_board = skater and not (physics >= M.wipeout_state and physics < M.wipeout_state + 100) and physics < M.offboard_states_first
    if not s.on_board and s.game and s.game.settings.mode == "race" and M.playing(s.game) then
        M.recovery("wait")
    end
    if in_world and s.game and s.game.settings.mode == "race" and M.playing(s.game) and
        not s.game.recovery_pending and not t.teleport_pending then
        s.game.momentum:observe_onboard(skater and physics >= 100 and physics < 300 and
            not (physics_watch.ragdoll_known and physics_watch.ragdoll), t.speed, now)
    end
    if in_world then M.track_bail(s, physics, if skater then t.vertical else s.previous_vertical, now, dt) end
    s.race_body_known = false
    if s.game and s.game.settings.mode == "race" and s.game.recovery_grace:pending() and not s.on_board then
        local body = t.body
        if body then
            s.position = body
            s.race_body_known = true
        end
    end
    if s.game and s.game.settings.mode == "race" and M.playing(s.game) then
        local g = s.game
        local grounded = skater and not t.airborne and
            ((physics >= 100 and physics < 200) or (physics >= M.offboard_states_first and physics < 600))
        g.last_safe_spot:observe(grounded and not g.recovery_pending and not g.recovery_grace:pending() and
            not s.race_hippy:active(now) and not t.teleport_pending and
            not (physics_watch.ragdoll_known and physics_watch.ragdoll), t.position, t.heading, now)
    end
    if not s.skater then
        s.line = M.Line()
        s.jump_known = false
        return
    end
    s.recent_speed = math.max(t.speed, s.recent_speed - 15.0 * dt)

    -- A jump the Trainer finished measuring since the last tick is a trick in the line.
    if not s.jump_known then
        s.jump_serial = t.last.serial
        s.jump_known = true
    elseif t.last.serial ~= s.jump_serial then
        s.jump_serial = t.last.serial
        local score = M.trick_score({air_time = t.last.air_time, height = t.last.height, distance = t.last.distance,
            spin = t.last.spin, flip = t.last.flip, board_turn = t.last.board_turn})
        if score > 0 and not s.bail.active then
            s.line.tricks += 1
            s.line.sum += score
            s.line.landed = now
            s.line.at = t.last.landing
            -- Down a stair set or a gap: landed a metre or more below the takeoff.
            local gap = t.last.takeoff.y - t.last.landing.y >= M.gap_drop
            if gap and #s.line.tags < M.max_line_tags then table.insert(s.line.tags, {kind = "gap", path = {t.last.takeoff, t.last.landing}}) end
            M.popup(s, "+" .. M.grouped(score) .. (if gap then "  gap" else ""))
        end
    end
    -- Grinds and slides: the path the board slides along is a trick in the line, and in Graffiti
    -- a tag on whatever was ground.
    local grinding = t.physics_state >= M.grind_states_first and t.physics_state < M.grind_states_end
    if grinding and not s.bail.active then
        if #s.line.grind == 0 then s.line.grind_started = now end
        local last = if #s.line.grind == 0 then t.position else s.line.grind[#s.line.grind]
        local dx, dy, dz = t.position.x - last.x, t.position.y - last.y, t.position.z - last.z
        if #s.line.grind == 0 or dx * dx + dy * dy + dz * dz >= 0.35 * 0.35 then table.insert(s.line.grind, t.position) end
        s.line.landed = now -- the line lives on while grinding
    elseif #s.line.grind > 0 then
        local path = s.line.grind
        if #path == 1 then table.insert(path, t.position) end
        local metres = 0
        for i = 1, #path - 1 do
            local dx, dz = path[i + 1].x - path[i].x, path[i + 1].z - path[i].z
            metres += math.sqrt(dx * dx + dz * dz)
        end
        local seconds = (now - s.line.grind_started) / 1000.0
        if not s.bail.active and (seconds >= 0.2 or metres >= 0.6) then
            local score = M.grind_score(seconds, metres)
            s.line.tricks += 1
            s.line.sum += score
            s.line.landed = now
            s.line.at = path[#path]
            if #s.line.tags < M.max_line_tags then
                local thin = {}
                for i, p in ipairs(M.thin_path(path)) do thin[i] = M.V(p) end
                table.insert(s.line.tags, {kind = "grind", path = thin})
            end
            M.popup(s, "+" .. M.grouped(score) .. "  grind")
        end
        table.clear(path)
    end
    -- A line ends once the skater has been on the ground a moment, or steps off the board.
    if s.line.tricks ~= 0 and not t.airborne and not s.bail.active and #s.line.grind == 0 and
        (now - s.line.landed >= M.line_grace_ms or t.physics_state >= M.offboard_states_first) then
        local score = M.line_score(s.line.sum, s.line.tricks)
        M.report(s, "line", score, s.line.tricks, s.line.at, s.line.tags)
        M.popup(s, string.format("%s line: %s", if s.line.tricks == 1 then "1 trick" else string.format("%d trick", s.line.tricks),
            M.grouped(score)))
        s.line = M.Line()
    end
end

return nil
