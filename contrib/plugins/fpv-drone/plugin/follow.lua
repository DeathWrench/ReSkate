-- Follow mode, as Extension/Skater/drone_follow.h had it: the drone flies itself behind the skater
-- while the player skates, and the view is its camera. An autopilot works the same sticks a pilot
-- would (angle mode with height hold) through the flight model, so it has to lean to speed up,
-- overshoots a turn, swings round to keep the skater in shot and climbs over what is in the way.
--
-- It sees the skater a reaction time late and moves its sticks with a hand's smoothness and a
-- little wander. When the skater rides back and forth in one place (a halfpipe, a bowl) it stops
-- chasing and holds a spot off to the side to film the session. It keeps off walls and ceilings.
local flight = require("flight")
local follow = {}

local V = vector.create
local dot, cross, len, norm, clamp1 = vector.dot, vector.cross, vector.magnitude, flight.norm, flight.clamp1
local ZERO, UP = V(0, 0, 0), V(0, 1, 0)
local DEG = math.pi / 180

-- The tuning for a follow distance (m) and how aggressively the pilot flies (0 calm, 0.5 middling,
-- 1 hard): how quickly it sees and answers the skater, how hard it closes a gap, leans and turns.
-- Further back it also flies a little higher, and films a session from further away.
function follow.tuning(distance, aggression)
    local a = math.clamp(flight.finite(aggression) and aggression or 0.5, 0, 1)
    local function mix(calm, mid, hard)
        if a < 0.5 then return calm + (mid - calm) * (a / 0.5) end
        return mid + (hard - mid) * ((a - 0.5) / 0.5)
    end
    local t = {lead = 0.15, wander = 0.035, uptilt = 5, margin = 1.2, clearance = 1.4}
    t.distance = math.clamp(flight.finite(distance) and distance or 4.5, 1, 30)
    t.height = 1 + 0.09 * t.distance
    t.session_distance = math.max(t.distance + 2.5, 5)
    t.reaction = mix(0.20, 0.12, 0.06)
    t.hands = mix(0.16, 0.10, 0.05)
    t.gap_gain = mix(0.5, 0.8, 1.2)
    t.speed_gain = mix(1.0, 1.5, 2.0)
    t.catch_up = mix(4, 6, 10)
    t.brake = mix(1.2, 2.0, 3.5)
    t.max_lean = mix(25, 40, 55)
    t.max_yaw_rate = mix(2.5, 4.5, 6.0)
    t.tilt_ease = mix(0.6, 0.4, 0.25)
    return t
end

-- The flight settings it flies with: the player's own drone made easy to fly well (self-levelling,
-- height hold), and bumps never cut the motors (nobody is there to arm it again).
function follow.flight_settings(cfg, t)
    local out = table.clone(cfg)
    out.angle_mode = true
    out.alt_hold = true
    out.max_angle = math.clamp(t.max_lean + 10, 20, 80)
    out.uptilt = t.uptilt
    out.crash_speed = 0
    out.range = 0
    out.armed = true
    out.top_speed = math.max(cfg.top_speed, 8)
    return out
end

function follow.pilot()
    return {valid = false, last_target = ZERO, target_velocity = ZERO, heading = V(0, 0, -1),
            seen = {}, seen_head = 0, seen_count = 0, ride_y = 0, climb_extra = 0, blocked_for = 0, floor_lift = 0,
            pitch = 0, roll = 0, yaw = 0, climb = 0, tilt = 0,
            history = {}, history_head = 0, history_count = 0, history_clock = 0,
            session = false, session_for = 0, session_spot = ZERO, session_middle = ZERO, session_side = ZERO, session_reach = 0,
            nearby = {0, 0, 0, 0, 0}, near_next = 1, noise = 0x9e3779b9, wander_now = ZERO, wander_to = ZERO, wander_time = 0}
end

local SEEN, HISTORY = 48, 60

-- Where the drone wants to be: behind the skater along its heading, up and a little ahead in time.
function follow.spot(target, velocity, heading, t, extra)
    local ahead = target + velocity * t.lead
    return ahead - heading * t.distance + V(0, t.height + extra, 0)
end

-- A level basis at `at` facing `look`.
function follow.facing(at, look)
    return flight.level_basis(look - at)
end

local function history_at(p, back)
    return p.history[(p.history_head - back - 1) % HISTORY + 1]
end

-- Reads the skater's last few seconds: riding back and forth in one place starts a session (the
-- drone holds a spot off to the side), riding away or stopping for a while ends it.
function follow.read_session(p, drone_at, t, cast)
    local n = math.min(p.history_count, 50) -- the last five seconds
    if n < 30 then
        p.session = false
        return
    end
    -- The way it rides most (across a halfpipe), from how its velocity spreads.
    local xx, xz, zz, low, high, path = 0, 0, 0, 1e9, -1e9, 0
    local middle = ZERO
    for back = 0, n - 1 do
        local sample = history_at(p, back)
        local v = sample.velocity
        xx += v.x * v.x
        xz += v.x * v.z
        zz += v.z * v.z
        middle += sample.position
        low = math.min(low, sample.position.y)
        high = math.max(high, sample.position.y)
        if back > 0 then
            local before = history_at(p, back - 1).position
            local dx, dz = sample.position.x - before.x, sample.position.z - before.z
            path += math.sqrt(dx * dx + dz * dz)
        end
    end
    middle /= n
    local angle = 0.5 * math.atan2(2 * xz, xx - zz)
    local axis = V(math.cos(angle), 0, math.sin(angle))
    local half = 0.5 * (xx + zz)
    local spread = math.sqrt(math.max(half * half - (xx * zz - xz * xz), 0))
    local line = half + spread > 3 * math.max(half - spread, 1e-3) -- one way and back, not round
    local reversals, since_reversal = 0, n
    local sign, lo, hi = 0, 1e9, -1e9
    for back = n - 1, 0, -1 do
        local sample = history_at(p, back)
        local along = dot(sample.velocity, axis)
        local x = dot(sample.position - middle, axis)
        lo = math.min(lo, x)
        hi = math.max(hi, x)
        if math.abs(along) >= 1.5 then
            local now = along > 0 and 1 or -1
            if sign ~= 0 and now ~= sign then
                reversals += 1
                since_reversal = back
            end
            sign = now
        end
    end
    local first, last = history_at(p, n - 1).position, history_at(p, 0).position
    local net = math.sqrt((last.x - first.x) ^ 2 + (last.z - first.z) ^ 2)
    local back_and_forth = reversals >= 2 and path > 8 and net < 0.4 * path
    local across = V(-axis.z, 0, axis.x)
    if not p.session then
        if not back_and_forth then return end
        p.session = true
        p.session_for = 0
        -- Watched from off to the side of the way it rides, on the side the drone is already on;
        -- round riding (a bowl) from where the drone already is.
        local from = V(drone_at.x - middle.x, 0, drone_at.z - middle.z)
        if line then p.session_side = dot(from, across) >= 0 and across or -across
        else p.session_side = len(from) > 0.5 and norm(from) or across end
    else
        -- Ends: no turn back for a while, or the skater has left the middle.
        local out = math.sqrt((last.x - p.session_middle.x) ^ 2 + (last.z - p.session_middle.z) ^ 2)
        if p.session_for > 3 and (since_reversal > 35 or out > p.session_reach + 6) then
            p.session = false
            return
        end
        if line then p.session_side = dot(across, p.session_side) >= 0 and across or -across end
    end
    p.session_middle = middle
    p.session_reach = math.max(-lo, hi)
    -- Far enough to see both ends of the riding, high enough to see the airs.
    local distance = math.clamp(0.6 * (hi - lo), t.session_distance, 14)
    local height = low + math.clamp(0.5 * (high - low) + 1.5, 1.8, 6)
    local look_from = V(middle.x, height, middle.z)
    local function place(side)
        local spot = look_from + side * distance
        local room = distance
        local hit = cast and cast(look_from, spot + side * t.margin)
        if hit then
            room = math.max(len(hit - look_from) - t.margin, 0.5)
            spot = look_from + side * room
        end
        return spot, room
    end
    local spot, room = place(p.session_side)
    p.session_spot = spot
    if room < 3 then -- boxed in on this side: the other side, if it is any better
        local other, other_room = place(-p.session_side)
        if other_room > room + 1 then
            p.session_side = -p.session_side
            p.session_spot = other
        end
    end
end

local WAYS = {V(1, 0, 0), V(-1, 0, 0), V(0, 0, 1), V(0, 0, -1), V(0, 1, 0)}
-- Keeps off walls and ceilings: looks along the way it flies and the way it wants to, and slows
-- toward anything there in time to stop short of it; and pushes away from anything already close.
-- Returns the changed level velocity it wants, and whether the way up is blocked.
function follow.avoid(p, drone, position, want, t, cast)
    for _, going in {drone.velocity, want} do
        local dir = V(going.x, 0, going.z)
        local speed = len(dir)
        if speed >= 0.3 then
            dir /= speed
            local reach = t.margin + 0.5 + speed * 0.7
            local hit = cast(position, position + dir * reach)
            if hit then
                local n = flight.surface_normal(cast, position, dir, reach, hit, 0.3)
                n = V(n.x, 0, n.z)
                if len(n) >= 0.2 then -- a wall, not the ground
                    n = norm(n)
                    local room = len(hit - position) - t.margin
                    local allowed = room > 0 and math.sqrt(2 * 4 * room) or room * 2 -- m/s toward it; < 0 backs off
                    local toward = -dot(want, n)
                    if toward > allowed then want += n * (toward - allowed) end
                end
            end
        end
    end
    -- Two of the five ways around it each tick.
    local reach = t.margin + 0.3
    for _ = 1, 2 do
        local w = p.near_next
        p.near_next = w % 5 + 1
        local hit = cast(position, position + WAYS[w] * reach)
        p.nearby[w] = hit and math.max(len(hit - position), 0.01) or 0
    end
    for w = 1, 4 do
        if p.nearby[w] > 0 then want += WAYS[w] * (-(reach - p.nearby[w]) * 3) end
    end
    return want, p.nearby[5] > 0 and p.nearby[5] < t.margin
end

-- One tick: what the pilot does with the sticks. `drone` is the flight state, `target` the
-- skater's position and `skater_forward` which way it faces. `cfg` is follow.flight_settings().
function follow.fly(p, drone, target, skater_forward, seconds, cfg, t, cast)
    local position = drone.position
    local dt = math.clamp(flight.finite(seconds) and seconds or 0, 0, 0.05)
    local cmd = flight.command()
    cmd.hold = true
    cmd.throttle = flight.hover_of(cfg)
    cmd.gimbal = p.tilt
    if not (dt > 0) then return cmd end

    -- What the skater is doing: velocity from its moves (a jump of more than a few metres in one
    -- tick is a respawn, not a move), and the way it is going.
    if not p.valid or len(target - p.last_target) > 8 then
        p.valid = true
        p.target_velocity = ZERO
        local f = V(skater_forward.x, 0, skater_forward.z)
        p.heading = len(f) > 0.1 and norm(f) or V(0, 0, -1)
        p.seen_count = 0
        p.ride_y = target.y
        local flat = math.max(math.sqrt((target.x - position.x) ^ 2 + (target.z - position.z) ^ 2), 0.5)
        p.tilt = math.clamp(math.atan2(target.y + 0.9 - position.y, flat), -1.2, 0.35)
        p.climb_extra, p.blocked_for, p.floor_lift = 0, 0, 0
        p.history_count, p.history_clock = 0, 0
        p.session = false
        p.nearby = {0, 0, 0, 0, 0}
    else
        local now = (target - p.last_target) / dt
        local k = 1 - math.exp(-dt / 0.15)
        p.target_velocity += (now - p.target_velocity) * k
        -- A pilot follows the lie of the ground, not every ollie: height is eased toward slowly,
        -- slower still going up (most rises are jumps that come straight back down).
        local tau = target.y > p.ride_y and 1.4 or 0.6
        p.ride_y += (target.y - p.ride_y) * (1 - math.exp(-dt / tau))
    end
    p.last_target = target
    -- Remembered, so the pilot can act on what it saw a reaction time ago.
    for i = 1, p.seen_count do
        local s = p.seen[(p.seen_head - i) % SEEN + 1]
        s.age += dt
    end
    p.seen_head = p.seen_head % SEEN + 1
    local level_velocity = V(p.target_velocity.x, 0, p.target_velocity.z)
    p.seen[p.seen_head] = {age = 0, position = V(target.x, p.ride_y, target.z), velocity = level_velocity}
    p.seen_count = math.min(p.seen_count + 1, SEEN)
    local seen = p.seen[p.seen_head]
    for back = 0, p.seen_count - 1 do
        local s = p.seen[(p.seen_head - back - 1) % SEEN + 1]
        seen = s
        if s.age >= t.reaction then break end
    end
    -- Every 0.1 s: is it riding a session?
    p.history_clock += dt
    if p.history_clock >= 0.1 then
        p.history_clock = math.min(p.history_clock - 0.1, 0.1)
        p.history_head = p.history_head % HISTORY + 1
        p.history[p.history_head] = {position = target, velocity = level_velocity}
        p.history_count = math.min(p.history_count + 1, HISTORY)
        follow.read_session(p, position, t, cast)
    end
    if p.session then p.session_for += dt end
    -- Heading: the way the skater moves once it moves at all, else the way it faces; turned toward
    -- gently, as a pilot swings round behind.
    do
        local want = V(seen.velocity.x, 0, seen.velocity.z)
        if len(want) < 1.5 then want = V(skater_forward.x, 0, skater_forward.z) end
        if len(want) > 0.1 then
            local k = 1 - math.exp(-dt * (len(seen.velocity) > 4 and 2.2 or 0.8))
            local blended = p.heading + (norm(want) - p.heading) * k
            if len(blended) > 0.1 then p.heading = norm(blended) end
        end
    end

    -- Where to be: behind the skater, or in a session the spot it films from. A wall between the
    -- skater and the spot behind brings the spot in to this side of it; one that leaves it too
    -- close, or stands between the drone and its spot, is climbed over (a little, if it lasts).
    -- The ground under the spot keeps it up.
    local goal = p.session and p.session_spot or follow.spot(seen.position, seen.velocity, p.heading, t, p.climb_extra)
    local chest = seen.position + V(0, 1, 0)
    if cast then
        local blocked = false
        if not p.session then
            local out = goal - chest
            local out_length = len(out)
            if out_length > 1 then
                local dir = out / out_length
                local hit = cast(chest + dir * 0.6, goal + dir * t.margin)
                if hit then
                    local room = len(hit - chest) - t.margin
                    goal = chest + dir * math.max(room, 0)
                    blocked = room < t.distance * 0.5
                end
            end
        end
        blocked = blocked or cast(position, goal) ~= nil
        p.blocked_for = blocked and p.blocked_for + dt or 0
        if p.blocked_for > 0.3 then p.climb_extra = math.min(p.climb_extra + 1.5 * dt, 3)
        else p.climb_extra = math.max(p.climb_extra - 0.8 * dt, 0) end
        -- Ground under the spot (a bank, a ledge) lifts it, quickly up and slowly back down.
        local lift = 0
        local ground = cast(goal + V(0, 2, 0), goal + V(0, -(t.height + 6), 0))
        if ground then lift = math.max(ground.y + t.clearance - goal.y, 0) end
        p.floor_lift += (lift - p.floor_lift) * (1 - math.exp(-dt / (lift > p.floor_lift and 0.2 or 1)))
        goal += V(0, p.floor_lift, 0)
    end

    -- Speed: match the skater, closing the gap no faster than it can still slow down from gently by
    -- the time it gets there; then lean to get it, no further than a pilot would.
    local error_v = goal - position
    local want_velocity = p.session and ZERO or seen.velocity
    do
        local level = V(error_v.x, 0, error_v.z)
        local d = len(level)
        if d > 0.01 then
            local close = math.min(t.gap_gain * d, math.sqrt(2 * t.brake * d), t.catch_up)
            want_velocity += level * (close / d)
        end
    end
    -- Too close (the skater stopped short, or came back at it): back off as a pilot pulls away.
    do
        local now_at = seen.position + seen.velocity * t.reaction
        local away = V(position.x - now_at.x, 0, position.z - now_at.z)
        local gap, keep = len(away), t.distance * 0.7
        if gap < keep then
            away = gap > 0.05 and away / gap or -p.heading
            want_velocity += away * ((keep - gap) * 2)
        end
    end
    local ceiling = false
    if cast then want_velocity, ceiling = follow.avoid(p, drone, position, want_velocity, t, cast) end
    local accel = (want_velocity - drone.velocity) * t.speed_gain
    local g = math.max(cfg.gravity, 1)
    local most = math.tan(math.clamp(t.max_lean, 5, 70) * DEG) * g
    do
        local a = math.sqrt(accel.x * accel.x + accel.z * accel.z)
        if a > most then accel = V(accel.x * most / a, accel.y, accel.z * most / a) end
    end
    local forward = V(-drone.body.b.x, 0, -drone.body.b.z)
    forward = len(forward) > 0.05 and norm(forward) or V(0, 0, -1)
    local right = V(-forward.z, 0, forward.x)
    local lean = math.clamp(cfg.max_angle, 1, 89) * DEG
    -- Angle mode: pitch stick back (+) leans the nose up, so speeding up forward is stick forward.
    local want_pitch = clamp1(-math.atan(dot(accel, forward) / g) / lean)
    local want_roll = clamp1(math.atan(dot(accel, right) / g) / lean)
    -- Height: eased toward, a few metres a second at most. The ground under the drone and just
    -- ahead of where it is going comes first: it climbs off it (as fast as it must to clear a rise
    -- ahead in time) and only sinks slowly near it, whatever its spot asks.
    local climb_rate = math.max(cfg.climb_rate, 1)
    local want_up = math.clamp(1.5 * error_v.y, -2.5, 3)
    local ground_close = false
    if cast then
        local reach = t.clearance + 4
        local room, rise = 1e9, -1e9
        local hit = cast(position + V(0, 0.5, 0), position + V(0, -reach, 0))
        if hit then room = position.y - hit.y end
        local going = V(drone.velocity.x, 0, drone.velocity.z)
        local speed = len(going)
        if speed > 1 then
            local soon = 0.8 -- s ahead it looks
            local at = position + going * math.min(soon, 10 / speed)
            local ahead = cast(at + V(0, 3, 0), at + V(0, -reach, 0))
            if ahead then rise = (ahead.y + t.clearance - position.y) / soon end
        end
        if room < t.clearance then want_up = math.max(want_up, (t.clearance - room) * 4 + 0.5) end
        if rise > 0 then want_up = math.max(want_up, rise) end
        if want_up < 0 and room < t.clearance + 1.5 then want_up *= math.clamp((room - t.clearance) / 1.5, 0, 1) end
        ground_close = room < t.clearance
    end
    local want_climb = clamp1(math.min(want_up, 8) / climb_rate)
    if ceiling then want_climb = math.min(want_climb, ground_close and 0 or -1 / climb_rate) end -- something just above
    -- Yaw: keep the skater in the middle of the shot, at a pilot's turn rate.
    local want_yaw = 0
    do
        local to = V(chest.x - position.x, 0, chest.z - position.z)
        if len(to) > 0.5 then
            to = norm(to)
            local across = dot(cross(forward, to), UP) -- + = the skater is to the left
            local angle = math.atan2(across, dot(forward, to))
            -- Far off the middle of the shot the pilot snaps round faster.
            local gain = 3 + 3 * math.clamp(math.abs(angle) / 0.6, 0, 1)
            want_yaw = math.clamp(angle * gain, -t.max_yaw_rate, t.max_yaw_rate)
        end
    end

    -- Hands: the sticks follow what the pilot wants smoothly, with a little wander.
    p.wander_time -= dt
    if p.wander_time <= 0 then
        p.wander_time = 0.4 + 0.5 * (flight.noise(p) + 1)
        p.wander_to = V(flight.noise(p), flight.noise(p), flight.noise(p))
    end
    local w = 1 - math.exp(-dt / 0.35)
    p.wander_now += (p.wander_to - p.wander_now) * w
    local h = 1 - math.exp(-dt / math.max(t.hands, 0.01))
    p.pitch += (want_pitch + t.wander * p.wander_now.x - p.pitch) * h
    p.roll += (want_roll + t.wander * p.wander_now.y - p.roll) * h
    p.yaw += (want_yaw * (1 + 0.15 * p.wander_now.z) - p.yaw) * h
    p.climb += (want_climb - p.climb) * h
    if ground_close then p.climb = math.max(p.climb, want_climb) end -- (no easing into the ground)

    cmd.pitch = clamp1(p.pitch)
    cmd.roll = clamp1(p.roll)
    cmd.yaw_rad = p.yaw * dt -- + = turn left
    cmd.climb = clamp1(p.climb)
    -- The camera sits on a tilt gimbal, eased toward the skater, so leaning to speed up or slow
    -- down does not swing the shot to the ground or the sky. It follows half of a jump; in a
    -- session all of it (the airs are the shot).
    do
        local aim = p.ride_y + (p.session and 1 or 0.5) * (target.y - p.ride_y)
        local to = V(target.x, aim + 0.9, target.z) - position
        local level = math.sqrt(to.x * to.x + to.z * to.z)
        local want_tilt = math.clamp(math.atan2(to.y, math.max(level, 0.5)), -1.2, 0.6)
        p.tilt += (want_tilt - p.tilt) * (1 - math.exp(-dt / math.max(t.tilt_ease, 0.05)))
        cmd.gimbal = p.tilt
    end
    return cmd
end

return follow
