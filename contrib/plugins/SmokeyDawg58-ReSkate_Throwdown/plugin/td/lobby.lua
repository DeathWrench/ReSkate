-- SmokeyDawg58's game modes (his game_modes.cpp lines 1140-1476), ported to Lua line for line: the
-- line-up at the countdown, offered games and joining them, the game's own tracking (Deathrace's
-- gates and recoveries, the tag modes' sounds, the area's fence), and the small helpers of the
-- placement that follows them.
local M = require("td/core")
local RR = require("td/h/race_route")
local RA = require("td/h/race_arrow_placement")
local RM = require("td/h/race_momentum")

-- An id modulo n, from its decimal digits (his `id % n` on a std::uint64_t).
local function id_mod(id, n)
    local r = 0
    for i = 1, #id do r = (r * 10 + (string.byte(id, i) - 48)) % n end
    return r
end
local function hypot(x, z) return math.sqrt(x * x + z * z) end

-- The countdown: everyone in the game is put at the start, spread out so nobody lands on anyone,
-- in the same order on every machine (where the session allows teleporting; elsewhere they skate
-- there). Deathrace lines up across its start gate; a circle's players stand in a ring around its
-- centre; anything else rings the spot the leader started the game from.
-- Teleports the skater a little above `at`, facing `heading` (the trainer's degrees: facing
-- sin, cos on x and z).
-- False when the teleport was refused (a bail, a menu, a session that forbids it).
-- His thread_local mode_teleport is the State's `mode_teleport` (internal_teleport() reads it).
function M.teleport_to(at, heading)
    local s = M.state()
    s.mode_teleport = true
    -- The position-only trainer command discards a fourth heading argument.
    -- Use the same native transition queue as 1-Up, with the complete pose.
    -- race_spawn_transform(at, heading) lifts the pose 0.3 m above `at`; the API teleports to the
    -- position it is given, so the lift is added here.
    -- PORT: the API allows at most 2 teleports a second (a third is refused, false); his had no limit.
    local ok = reskate.skater.teleport(vector.create(at.x, at.y + 0.3, at.z), math.rad(heading))
    s.mode_teleport = false
    return ok
end
function M.heading_towards(from, to)
    return math.atan2(to.x - from.x, to.z - from.z) * 180.0 / 3.14159265
end
-- Which way Deathrace gate i faces: its own facing, else along the route (the start towards the
-- next gate, any other from the gate before it).
function M.gate_heading(st, i)
    if i < #st.yaws then return st.yaws[i + 1] end
    if #st.points < 2 or i >= #st.points then return 0.0 end
    return if i > 0 then M.heading_towards(st.points[i], st.points[i + 1]) else M.heading_towards(st.points[1], st.points[2])
end
-- R.E.S.K.A.T.E.'s start: its flag, or a custom zone's middle when the flag stands outside its cones
-- (starting outside, no try would count).
function M.skate_start(st)
    if st.area_radius <= 0.0 and M.has_area(st) and (not st.has_spawn or not M.inside(st, st.spawn)) then return M.area_centre(st.corners) end
    return st.spawn
end
function M.line_up(s)
    if not s.game or not s.skater then return end
    local g = s.game
    if g.lined_up or not g.state or g.state.phase ~= "countdown" or not M.standing(g, M.self_id(s)) then return end
    local ids = {}
    for _, p in ipairs(g.state.standings) do table.insert(ids, p.player) end
    table.sort(ids, M.id_less)
    local count = #ids
    local index = count -- std::find's end when missing
    for i, id in ipairs(ids) do
        if id == M.self_id(s) then
            index = i - 1
            break
        end
    end
    local spot = vector.zero
    if g.settings.mode == "race" and #g.settings.points >= 2 then
        spot = RR.race_start_position(g.settings, index, count)
    else
        local centre = vector.zero
        if g.settings.area_radius > 0 and #g.settings.corners > 0 then
            centre = g.settings.corners[1]
        elseif g.settings.mode == "skate" and M.has_area(g.settings) then
            centre = M.skate_start(g.settings)
        elseif g.settings.has_spawn then
            centre = g.settings.spawn
        elseif M.has_area(g.settings) then
            centre = M.area_centre(g.settings.corners)
        else
            return
        end
        -- Skate Tag spreads everyone well out, so whoever starts it has a chase on their hands.
        local spread = if M.tag_like(g.settings.mode) then 15.0 + 2.0 * count else 2.0 + 0.6 * count
        local ring = if count <= 1 then 0.0 else spread
        local angle = 6.2831853 * index / math.max(1.0, count)
        spot = vector.create(centre.x + math.cos(angle) * ring, centre.y, centre.z + math.sin(angle) * ring)
        -- Round the circle everyone faces its middle; alone, the way the leader set it up.
        local facing
        if ring > 0 then
            facing = M.heading_towards(spot, centre)
        elseif g.native_flag_placed and g.settings.mode ~= "skate" then
            facing = g.native_flag_yaw
        else
            facing = s.heading
        end
        g.lined_up = M.teleport_to(spot, facing)
        return
    end
    g.lined_up = M.teleport_to(spot, RR.race_start_heading(g.settings))
end
-- Where a game's banner stands and its joiners are sent: Deathrace's start gate, the circle's or
-- area's centre, its first spot, or where its leader set it up.
function M.game_spot(st)
    if st.mode == "race" and #st.points > 0 then return st.points[1] end
    if st.area_radius > 0 and #st.corners > 0 then return st.corners[1] end
    if M.has_area(st) then return M.area_centre(st.corners) end
    if #st.points > 0 then return st.points[1] end
    if st.has_spawn then return st.spawn end
    return nil
end
function M.offer_open(o)
    return o.confirmed and (o.phase == "setup" or o.phase == "countdown") and
        (o.settings.mode ~= "race" or RR.race_route_ready(o.settings, o.settings.race_finish))
end
-- Joins an offered game: the leader is asked at once, and the player is put at its start, a few
-- steps from its spot (round the circle, or behind Deathrace's start gate), not on anyone's head.
function M.join_offer(s, offer, now)
    if M.nz(M.one_up_match()) or M.placement("placing") or M.placement("local_throwdown") then
        return "error: quit the active Throwdown before joining another challenge."
    end
    if s.barred then return "error: your mods change trick scoring, so you cannot play in this session." end
    if not M.offer_open(offer) then return "error: that game is already under way." end
    if s.game and s.game.leading then return "error: you lead a game: `mode stop` it first." end
    -- A game joined but not heard from yet counts too: replacing it silently would leave its leader
    -- counting this player in.
    if s.game and (not s.game.state or s.game.state.phase ~= "results") then
        return "error: you are in " .. M.name_of(s, s.game.leader) .. "'s game: `mode leave` first."
    end
    local g = M.Game()
    g.leader = offer.leader
    g.id = offer.game
    g.settings = M.copy(offer.settings)
    g.heard = now
    g.join_sent = now
    s.game = g
    s.active = true
    M.send(s, M.header(s.game, "join"))
    local text = string.format("Joined %s's %s!", M.name_of(s, offer.leader), M.mode_name(offer.settings.mode))
    local spot = M.game_spot(offer.settings)
    if spot and s.skater then
        local angle = id_mod(M.self_id(s), 12) * 0.5236 -- twelve places round it
        local at = vector.create(spot.x + math.cos(angle) * 3.0, spot.y, spot.z + math.sin(angle) * 3.0)
        local facing = M.heading_towards(at, spot)
        if offer.settings.mode == "race" then
            facing = M.gate_heading(offer.settings, 0)
            local yaw = facing * 3.14159265 / 180.0
            local side = (id_mod(M.self_id(s), 5) - 2.0) * 2.0
            at = vector.create(spot.x - math.sin(yaw) * 3.0 - math.cos(yaw) * side, spot.y,
                spot.z - math.cos(yaw) * 3.0 + math.sin(yaw) * side)
        end
        M.teleport_to(at, facing)
    end
    local leader = offer.leader
    M.erase_if(s.offers, function(o) return o.leader == leader end)
    s.invite_at = 0
    M.popup(s, text)
    return text
end
-- Native flags and the Throwdown picker own joining. A normal push or a held
-- face button must never join a challenge behind the native interaction.
M.invite_ms = 15000
function M.run_invites(s, now)
    -- A game seen reach its results is not offered again by the setup messages its leader keeps
    -- sending until it closes.
    for _, o in ipairs(s.offers) do
        if o.phase == "results" then s.sat_out[M.pair_key(o.leader, o.game)] = true end
    end
    M.erase_if(s.offers, function(o)
        return now - o.heard > M.leader_timeout_ms or (s.session and not s.present[o.leader]) or o.phase == "results" or
            s.sat_out[M.pair_key(o.leader, o.game)] == true or (s.game ~= nil and s.game.leader == o.leader and s.game.id == o.game)
    end)
    s.join_target = nil
    local free = not s.game or (s.game.state ~= nil and s.game.state.phase == "results")
    if free and s.placing == "none" then
        local pick = nil
        if now - s.invite_at < M.invite_ms then
            for _, o in ipairs(s.offers) do
                if o.leader == s.invite_leader and o.game == s.invite_game and M.offer_open(o) then pick = o end
            end
        end
        if not pick and s.skater then
            local best = 30.0
            for _, o in ipairs(s.offers) do
                local spot = M.game_spot(o.settings)
                if spot and M.offer_open(o) then
                    local d = hypot(spot.x - s.position.x, spot.z - s.position.z)
                    if d < best and math.abs(spot.y - s.position.y) < 15.0 then
                        best = d
                        pick = o
                    end
                end
            end
        end
        if pick then s.join_target = {pick.leader, pick.game} end
    end
end
-- Deathrace: the next checkpoint reached. The area: a player outside it for a while is put back.
function M.track_game(s, now)
    if not s.game or not M.playing(s.game) or (not s.skater and not (s.game.settings.mode == "race" and
        (s.game.recovery_grace:pending() or s.game.gate_crossed or s.race_hippy:active(now)))) then
        s.outside_since = 0
        return
    end
    local g = s.game
    -- trainer::telemetry() and local_skater_teleport_pending(), read once.
    local t = M.telemetry()
    local race_rider = s.on_board or (g.settings.mode == "race" and
        RM.race_offboard_progress(s.skater and not s.race_offboard_ragdoll:active(), s.previous_state, s.race_hippy:active(now)))
    local me = M.standing(g, M.self_id(s))
    if not me or me.out then return end
    if M.tag_like(g.settings.mode) or g.settings.mode == "race" then
        -- Where we are, to the leader and everyone (about 7 times a second), and the sounds of
        -- being tagged and of tagging.
        s.positions[M.self_id(s)] = {s.position, now}
        if now - s.position_sent >= 150 then
            s.position_sent = now
            M.report(s, "position", 0, 0, s.position)
        end
    end
    -- Infection: the moment the local player is caught.
    if g.settings.mode == "infection" then
        if me.up and not s.was_infected then
            M.play("missed")
            M.popup(s, "YOU'RE INFECTED! Hunt the survivors")
        end
        s.was_infected = me.up
    end
    -- Hide & Seek: found, and the seekers let loose.
    if g.settings.mode == "hide" and g.state then
        if me.up and not s.was_infected and g.state.target <= 0 then
            M.play("missed")
            M.popup(s, "FOUND! Now you seek too")
        end
        s.was_infected = me.up
        local hiding = g.state.target > 0
        if s.was_hiding and not hiding then
            M.play("invite")
            M.popup(s, if me.up then "GO FIND THEM!" else "THEY'RE COMING!")
        end
        s.was_hiding = hiding
    end
    if g.settings.mode == "tag" then
        local it = if g.state then g.state.turn else "0"
        if M.nz(it) and it ~= s.last_it then
            if it == M.self_id(s) then
                M.play("missed")
                M.popup(s, "YOU'RE IT! Tag someone")
            elseif s.last_it == M.self_id(s) then
                M.play("checkpoint")
                M.popup(s, "Tagged " .. M.name_of(s, it) .. "! Run!")
            end
            s.last_it = it
        end
    end
    if g.settings.mode == "race" and me.score >= 0 and me.score < #g.settings.points then
        local index = me.score
        local finish = g.settings.race_finish and index + 1 == #g.settings.points
        local function expire_grace()
            if not g.recovery_grace:ready(now) then return end
            g.recovery_grace:reset()
            g.recovery_pending = true
            g.recovery_to_safe = true
            g.recovery_queued = 0
            g.have_along = false
            g.gate_crossed = false
            g.miss_pending = false
        end
        if g.recovery_pending then
            g.have_along = false
            g.gate_crossed = false
            g.miss_pending = false
            if g.recovery_queued == 0 then
                -- RaceLastSafeSpot::pose() and race_return_pose's argument are copies.
                local saved = if g.recovery_to_safe then g.last_safe_spot:pose() else nil
                local safe = if saved ~= nil then M.copy(saved) else nil
                g.recovery_pose = RR.race_return_pose(g.settings, index, g.checkpoint_fallback:target(g.settings, index), safe)
                if M.teleport_to(g.recovery_pose.at, g.recovery_pose.yaw) then g.recovery_queued = now end
            elseif race_rider and not t.teleport_pending and
                hypot(s.position.x - g.recovery_pose.at.x, s.position.z - g.recovery_pose.at.z) < 3.0 then
                M.recovery("request", RM.race_recovery_motion(g.recovery_speed, g.recovery_pose.yaw))
                g.recovery_pending = false
                g.recovery_to_safe = false
                g.recovery_queued = 0
                g.recovery_until = now + 3000
                g.momentum:suspend_until(now + 400)
                g.recovery_speed_guard:completed(now)
                M.play_race_sound("recovery")
            elseif now - g.recovery_queued > 5500 then
                g.recovery_queued = 0
            end
            return
        end
        if not race_rider and not (finish and g.gate_crossed) and not g.recovery_grace:pending() then
            g.have_along = false
            return
        end
        if not s.skater and not s.race_body_known and not (finish and g.gate_crossed) then
            g.have_along = false
            expire_grace()
            return
        end
        if race_rider and g.have_along then g.checkpoint_fallback:observe_crossings(g.settings, index, g.previous_gate_position, s.position) end
        local next = g.settings.points[index + 1]
        local dx, dz = s.position.x - next.x, s.position.z - next.z
        -- A gate counts when the skater crosses its line, forwards, between its posts: not on
        -- getting near it. Its facing is its own (or along the route).
        local yaw = M.gate_heading(g.settings, index) * 3.14159265 / 180.0
        local fx, fz = math.sin(yaw), math.cos(yaw)
        local along = dx * fx + dz * fz
        -- Sweep the actual movement segment through the gate plane. Fast
        -- skating and frame gaps must not skip a crossing between two samples.
        local crossing = if g.have_along and (race_rider or (finish and g.recovery_grace:waiting(now)))
            then RR.race_gate_crossing(g.settings, index, g.previous_gate_position, s.position) else RR.RaceGateCrossing.new()
        -- Crossing is evaluated at the swept intersection, including wide detours.
        if crossing.inside and not g.gate_crossed then
            g.gate_crossed = true
            g.crossed_at = crossing.at
        end
        -- Reported (again every 1.5 s) until the referee counts it: a lost message must not cost the gate.
        if g.gate_crossed and (g.checkpoint_sent ~= me.score or now - g.checkpoint_at > 1500) then
            g.checkpoint_sent = me.score
            g.checkpoint_at = now
            M.report(s, "checkpoint", me.score, 0, g.crossed_at)
        end
        if finish and g.gate_crossed then g.recovery_grace:reset() end
        local missed = race_rider and not g.recovery_grace:pending() and g.have_along and not g.gate_crossed and
            RR.race_later_gate_crossed(g.settings, index, g.previous_gate_position, s.position) ~= nil
        g.along = along
        g.previous_gate_position = s.position
        g.have_along = true
        expire_grace()
        if missed and (g.missed_warned ~= me.score or now > g.recovery_until) then
            g.recovery_speed = g.recovery_speed_guard:limit(g.momentum:current(now), now)
            g.missed_warned = me.score
            g.recovery_pending = true
            g.recovery_to_safe = false
            g.last_safe_spot:reset()
            g.recovery_queued = 0
            g.recovery_until = now + 8000
            M.popup(s, string.format("Missed required gate %d. Returning to your last cleared gate.", M.mandatory_gates(g.settings, index) + 1))
        end
    end
    -- R.E.S.K.A.T.E.'s area is a trick zone, not a fence: players roll in from outside it.
    if not M.has_area(g.settings) or g.settings.mode == "skate" then return end
    if M.inside(g.settings, s.position) then
        s.outside_since = 0
        if not t.airborne then s.last_inside = s.position end
        return
    end
    if s.outside_since == 0 then s.outside_since = now end
    if now - s.outside_since >= M.out_of_area_ms then
        s.outside_since = now -- try again later if the teleport is refused
        -- The last spot inside only while it is inside this game's area (it may be from an earlier game's).
        local back = if s.last_inside and M.inside(g.settings, s.last_inside) then s.last_inside else M.area_centre(g.settings.corners)
        local middle = if g.settings.area_radius > 0 then g.settings.corners[1] else M.area_centre(g.settings.corners)
        -- Back inside, facing into the area.
        if M.teleport_to(back, if hypot(middle.x - back.x, middle.z - back.z) > 1.0 then M.heading_towards(back, middle) else s.heading) then
            M.popup(s, "Back in the area")
        end
    end
end

-- std::vector::resize: cut to n, or grow to n with `fill`.
local function resize(list, n, fill)
    while #list > n do table.remove(list) end
    while #list < n do table.insert(list, fill) end
end
-- The leader changed the settings before the start: everyone gets them at once.
function M.settings_changed(g)
    g.setup_sent = 0
    g.state_sent = 0
    -- Every Deathrace gate has a facing: one placed without (the console) looks along the route.
    local s = g.settings
    if s.mode ~= "race" then
        table.clear(s.yaws)
        table.clear(s.widths)
        table.clear(s.gate_kinds)
        table.clear(s.arrow_rolls)
        table.clear(s.gate_pitches)
        return
    end
    for i = #s.yaws, #s.points - 1 do table.insert(s.yaws, M.gate_heading(s, i)) end
    resize(s.yaws, #s.points, 0.0)
    -- Every gate has a width too: one placed without keeps the game's checkpoint radius.
    while #s.widths < #s.points do table.insert(s.widths, math.clamp(s.radius, M.min_gate_half_width, M.max_gate_half_width)) end
    resize(s.widths, #s.points, 0.0)
    resize(s.gate_kinds, #s.points, "required")
    if #s.arrow_rolls > 0 then resize(s.arrow_rolls, #s.points, 0.0) end
    if #s.gate_pitches > 0 then resize(s.gate_pitches, #s.points, 0.0) end
end
function M.game_window_focused()
    local f = reskate.input.focus()
    return f ~= nil and f.focused == true
end
M.pad_up, M.pad_down, M.pad_left, M.pad_right = 0x1, 0x2, 0x4, 0x8
function M.point_name(g) return if g.settings.mode == "race" then "checkpoint" else "spot" end
-- A Deathrace route's gates: the first is the start, the last the finish, checkpoints between.
function M.gate_name(index, count)
    if index == 0 then return "Start" end
    if index + 1 == count and count >= 2 then return "Finish" end
    return string.format("Checkpoint %d", index)
end

-- The spot the next thing goes, on the real ground: where the free camera looks, or under the
-- skater (whose position is carried above the ground, which left Deathrace posts floating). Rays
-- use the client collision context directly, independently of the park editor's
-- persistence/server readiness. This function runs on that verified client thread.
-- His world ray slots; the API casts at once, so they only name the rays here.
M.aim_ray, M.ground_ray, M.arrow_ray = 0x6d6f6401, 0x6d6f6402, 0x6d6f6403
local function finite(x) return x == x and x ~= math.huge and x ~= -math.huge end
function M.cast_arrow_ray(origin, direction, length)
    -- queue_world_ray(arrow_ray, origin, direction, length); tick_local_world_rays(); world_ray(arrow_ray):
    -- the ray from `origin` along `direction` (normalised), `length` long, cast at once.
    local result = RA.RaceArrowRay.new()
    -- queue_world_ray's checks.
    -- PORT: where those checks refused the ray, his world_ray still answered with the arrow ray's
    -- previous cast when it was under 500 ms old; here a refused ray is unavailable.
    for _, v in ipairs({origin.x, origin.y, origin.z, direction.x, direction.y, direction.z}) do
        if not finite(v) then return result end
    end
    if math.abs(origin.x) > 100000 or math.abs(origin.y) > 100000 or math.abs(origin.z) > 100000 then return result end
    local size = vector.magnitude(direction)
    if size < 0.5 or not (length > 0) or length > 2000 then return result end
    -- PORT: `available` is that the cast was made (reskate.world.raycast returned: it errors past 1000 m
    -- or 64 rays a tick); his also meant the native collision API and world were ready, which the API
    -- does not say (an unready world answers as a miss: available, no hit).
    local ok, hit = pcall(reskate.world.raycast, origin, origin + direction / size * length)
    result.available = ok
    result.hit = ok and hit ~= nil
    if result.hit then result.at = M.V(hit) end
    return result
end

-- His placement cursor's diagnostics (lines 1464-1475): the issue once every 5 s, at his debug level
-- (ReSkate's plugin log has none below info, so it goes there only with `mode debug states on`).
function M.cursor_diagnostic(s, issue, camera, origin, direction)
    camera = camera or 0
    origin = origin or vector.zero
    direction = direction or vector.zero
    if not s.game or s.game.settings.mode ~= "race" then return end
    local now = M.now_ms()
    if s.cursor_diagnostic == issue and now - s.cursor_diagnostic_at < 5000 then return end
    s.cursor_diagnostic = issue
    s.cursor_diagnostic_at = now
    if not s.log_states then return end
    reskate.log(string.format("Deathrace placement cursor: %s; camera=0x%x; origin=(%.2f, %.2f, %.2f); direction=(%.3f, %.3f, %.3f); hit=(%s, %.2f, %.2f, %.2f).",
        issue, camera, origin.x, origin.y, origin.z, direction.x, direction.y, direction.z, tostring(s.cursor_ok), s.cursor.x, s.cursor.y, s.cursor.z))
end

return nil
