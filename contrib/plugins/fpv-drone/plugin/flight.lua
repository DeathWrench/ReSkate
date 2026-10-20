-- The FPV drone's flight model, as Extension/Skater/drone_flight.h had it. Plain maths: the world
-- comes in as a cast(from, to) function (the hit point, or nil), so the tests fly it over a fake.
--
-- A pose is a basis {r, u, b} of world vectors (right, up, backward; the camera looks along -b) and
-- a position. World up is +Y.
--
-- The throttle sets motor output, which spools up and down over some tens of milliseconds, and
-- thrust grows with output to the power 1.5, so the hover throttle fixes the thrust-to-weight
-- ratio (a 22% hover is about 10:1, a 5-inch's). Thrust falls off as the drone climbs into its own
-- inflow and comes back near the ground. The flight controller turns the drone at the rate the
-- sticks ask, catching up in about 30 ms, or in angle mode leans it to the angle they ask. Drag is
-- quadratic and larger across the props than edge on; the top speed setting sets how much, so full
-- throttle flat out settles near it. Hits bounce off the surface they meet, knock the drone about,
-- and a hard one cuts the motors until it is armed again.
local flight = {}

local V = vector.create
local dot, cross, len = vector.dot, vector.cross, vector.magnitude
local ZERO, UP = V(0, 0, 0), V(0, 1, 0)
local DEG = math.pi / 180

flight.gimbal_roll_share = 0.3 -- how much of the body's roll a tilt gimbal's picture keeps
flight.rate_lag = 0.03         -- s: the flight controller's catch-up to the asked turn rate
flight.spool_up, flight.spool_down = 0.04, 0.07 -- s: motor output following the throttle
flight.thrust_power = 1.5      -- thrust grows with motor output to this power
flight.boost_thrust = 1.5      -- boost: this much more thrust
flight.hard_hit = 2.0          -- m/s into a surface: a bump rather than a touch
flight.bounce = 0.35           -- how much of a hard hit's speed it bounces back with
flight.hold_gain = 4.0         -- 1/s: height hold's pull toward the asked climb
-- Range: the picture is clean to half the range, lost at it; the motors cut past 1.5 times it, or
-- after 5 s without a picture.
flight.range_clean, flight.range_failsafe, flight.failsafe_after = 0.5, 1.5, 5.0

local function finite(x)
    return x == x and x > -1e30 and x < 1e30
end
local function finite_vector(v)
    return finite(v.x) and finite(v.y) and finite(v.z) and math.abs(v.x) < 1e6 and math.abs(v.y) < 1e6 and math.abs(v.z) < 1e6
end
flight.finite = finite
flight.finite_vector = finite_vector

local function norm(a)
    local l = len(a)
    if l > 1e-8 then return a / l end
    return ZERO
end
flight.norm = norm
local function clamp1(v)
    if not finite(v) then return 0 end
    return math.clamp(v, -1, 1)
end
flight.clamp1 = clamp1

-- Rodrigues: v about the unit axis by the angle (right-handed).
local function rotate(v, axis, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return v * c + cross(axis, v) * s + axis * (dot(axis, v) * (1 - c))
end
flight.rotate = rotate

-- The whole basis about a world axis, then square again.
local function rotate_basis(m, axis, angle)
    if angle == 0 then return end
    local r = norm(rotate(m.r, axis, angle))
    local u = rotate(m.u, axis, angle)
    local b = norm(cross(r, u))
    m.r, m.u, m.b = r, cross(b, r), b
end
flight.rotate_basis = rotate_basis

local function copy_basis(m)
    return {r = m.r, u = m.u, b = m.b}
end
flight.copy_basis = copy_basis

-- A level basis facing `forward` (its height is dropped).
function flight.level_basis(forward)
    local f = V(forward.x, 0, forward.z)
    if len(f) < 0.05 then f = V(0, 0, -1) end
    f = norm(f)
    return {r = V(-f.z, 0, f.x), u = UP, b = -f}
end

-- Betaflight's "Actual" rates: deg/s for a stick of -1 to 1.
function flight.actual_rate(stick, rate)
    local a = math.min(math.abs(stick), 1)
    local expo = math.clamp(rate.expo, 0, 1)
    local curve = a * (a * a * a * a * a * expo + a * (1 - expo))
    local movement = math.max(0, rate.max - rate.center)
    local v = rate.center * a + movement * curve
    return stick < 0 and -v or v
end

-- A throttle stick that springs back to the middle: the middle holds the drone up, up climbs to
-- full, down drops to nothing.
function flight.spring_throttle(stick, hover)
    local h = math.clamp(finite(hover) and hover or 0.35, 0.05, 0.95)
    local v = math.clamp(finite(stick) and stick or 0, -1, 1)
    if v >= 0 then return h + v * (1 - h) end
    return h * (1 + v)
end

local function hover_of(c)
    return math.clamp(finite(c.hover) and c.hover or 0.35, 0.05, 0.95)
end
flight.hover_of = hover_of
-- Thrust (m/s² along the drone's up) at full output, and at `output`.
local function max_thrust(c)
    return math.max(0, c.gravity) / hover_of(c) ^ flight.thrust_power
end
flight.max_thrust = max_thrust
local function thrust_at(output, c)
    return max_thrust(c) * math.clamp(output, 0, 1) ^ flight.thrust_power
end
flight.thrust_at = thrust_at
-- The output that gives `accel` m/s² of thrust.
local function output_for(accel, c)
    local most = max_thrust(c)
    if not (most > 0) or not finite(accel) then return hover_of(c) end
    return math.clamp(accel / most, 0, 1) ^ (1 / flight.thrust_power)
end
flight.output_for = output_for
-- The top speed (m/s) the speed setting asks for, and the quadratic drag that gives it: flat out,
-- the thrust left over from holding the drone up is spent on drag at that speed.
local function top_speed(speed)
    return math.clamp(finite(speed) and speed or 10, 0.6, 1500) * 4
end
flight.top_speed = top_speed
local function drag_for(c)
    local most, g = max_thrust(c), math.max(0, c.gravity)
    local spare = math.sqrt(math.max(most * most - g * g, 0.01))
    local top = top_speed(c.top_speed)
    return 0.36 * spare / (top * top)
end
flight.drag_for = drag_for

function flight.signal_strength(distance, range)
    if not (range > 0) or not finite(distance) then return 1 end
    local q = distance / range
    if q <= flight.range_clean then return 1 end
    if q >= 1 then return 0 end
    local t = (q - flight.range_clean) / (1 - flight.range_clean)
    return math.clamp(1 - t * t * (3 - 2 * t), 0, 1)
end
function flight.failsafe_due(distance, range, seconds_lost)
    if not (range > 0) then return false end
    return (finite(distance) and distance > range * flight.range_failsafe) or seconds_lost >= flight.failsafe_after
end

-- A pretend 4S pack: 16.8 V full, sagging a little with throttle and draining over the flight.
function flight.battery_volts(seconds, throttle)
    return math.max(13.2, 16.8 - 0.0045 * seconds - 0.7 * throttle)
end

-- xorshift32: -1 to 1.
local function noise(state)
    local s = state.noise
    s = bit32.bxor(s, bit32.lshift(s, 13))
    s = bit32.bxor(s, bit32.rshift(s, 17))
    s = bit32.bxor(s, bit32.lshift(s, 5))
    state.noise = s
    return bit32.band(s, 0xffffff) / 8388608 - 1
end
flight.noise = noise

-- The surface at a hit: two more rays beside the first find two more points of it. Without them
-- (an edge, or a thin thing) it is taken to face straight back along the move.
function flight.surface_normal(cast, from, dir, reach, hit, spread)
    local side = norm(cross(dir, math.abs(dir.y) < 0.9 and UP or V(1, 0, 0)))
    local other = cross(dir, side)
    local points, found = {}, 0
    for _, offset in {side, other, -side, -other} do
        if found == 2 then break end
        local start = from + offset * spread
        local at = cast(start, start + dir * reach)
        if at then
            found += 1
            points[found] = at
        end
    end
    if found == 2 then
        local n = norm(cross(points[1] - hit, points[2] - hit))
        if dot(n, dir) > 0 then n = -n end
        if len(n) > 0.5 and dot(n, dir) < -0.05 then return n end
    end
    return -dir
end

-- Body turn rates (about right, up, forward) from a world spin vector.
local function body_rates(body, spin)
    return dot(spin, body.r), dot(spin, body.u), -dot(spin, body.b)
end
flight.body_rates = body_rates

-- The camera on the body, tilted up by `uptilt` radians.
function flight.camera_from_body(body, uptilt)
    local cam = copy_basis(body)
    rotate_basis(cam, body.r, uptilt)
    return cam
end
-- A camera on a tilt gimbal (as on a DJI Avata): it faces the way the body faces and holds its
-- own pitch (+ looks up), keeping only a share of the body's roll.
function flight.camera_on_gimbal(body, tilt, roll_share)
    local f = -body.b
    f = V(f.x, 0, f.z)
    if dot(f, f) < 0.0025 then f = cross(body.r, UP) end
    f = norm(f)
    local cam = {r = V(-f.z, 0, f.x), u = UP, b = -f}
    rotate_basis(cam, cam.r, tilt)
    local roll = -math.asin(math.clamp(body.r.y, -1, 1))
    rotate_basis(cam, -cam.b, roll * roll_share)
    return cam
end

-- A new flight: level, facing `forward`, at rest and hovering, at `position`.
function flight.new_state(position, forward, armed, cfg)
    local s = {}
    flight.start(s, position, forward, armed, cfg)
    return s
end
function flight.start(s, position, forward, armed, cfg)
    s.body = flight.level_basis(forward)
    s.position = position
    s.velocity = ZERO
    s.start_y = position.y
    s.start_position = position
    s.start_body = copy_basis(s.body)
    s.flight_time = 0
    s.failsafe = false
    s.signal_lost = 0
    s.rate = {0, 0, 0} -- rad/s about right (+ nose up), up (+ left), forward (+ roll right)
    s.motor = armed and hover_of(cfg) or 0
    s.crashed = false
    s.armed_last = armed
    s.grounded = false
    s.glitch = 0
    s.wash = {0, 0}
    s.noise = s.noise or 0x2545f491
    s.signal = 1
    s.home = 0
    s.speed = 0
    s.altitude = 0
    s.throttle = s.motor
    s.crashed_now = false
    s.camera = copy_basis(s.body)
end
-- Back to where it took off, with a fresh battery and timer.
function flight.reset(s, armed, cfg)
    s.body = copy_basis(s.start_body)
    s.position = s.start_position
    s.velocity = ZERO
    s.flight_time = 0
    s.failsafe = false
    s.signal_lost = 0
    s.rate = {0, 0, 0}
    s.motor = armed and hover_of(cfg) or 0
    s.crashed = false
    s.glitch = 0
end

-- A pilot's command: pitch (+ nose up), roll (+ right), yaw_rad (radians this step, + left),
-- look_pitch (radians from the mouse, + looks down), throttle (0-1), hold and climb (height hold),
-- boost, park (motors off, hold still), gimbal (set: a tilt gimbal at this pitch).
function flight.command()
    return {pitch = 0, roll = 0, yaw_rad = 0, look_pitch = 0, throttle = 0.35, hold = false, climb = 0, boost = false, park = false, gimbal = nil}
end

-- One step of `seconds`. `cfg` is settings.flight(); `cast` the world (nil: no collisions).
-- Sets s.crashed_now when a hit cut the motors (the pilot's switch goes off).
function flight.step(s, cmd_in, seconds, cfg, cast)
    s.crashed_now = false
    if not finite(seconds) then return end
    local dt = math.clamp(seconds, 0, 0.05)
    local uptilt = cfg.uptilt * DEG
    local position = s.position

    -- After a crash the motors stay off until the drone is armed again: off, then on.
    if cfg.armed and not s.armed_last then s.crashed = false end
    s.armed_last = cfg.armed
    local cmd = cmd_in
    -- Range: the link weakens with distance from the takeoff point.
    local home = len(position - s.start_position)
    local quality = flight.signal_strength(home, cfg.range)
    s.signal_lost = quality <= 0 and s.signal_lost + dt or 0
    if flight.failsafe_due(home, cfg.range, s.signal_lost) then s.failsafe = true end
    s.signal, s.home = quality, home
    -- Disarmed, crashed or out of range: the pilot's inputs and the motors are off. A crashed drone
    -- falls even when a disarmed one would hang.
    local motors = cfg.armed and not s.failsafe and not s.crashed
    if not motors then
        local gimbal = cmd.gimbal
        cmd = flight.command()
        cmd.gimbal = gimbal
        cmd.throttle = 0
        cmd.park = cfg.disarm_freeze and not s.crashed
    end

    local pitch_in, roll_in = clamp1(cmd.pitch), clamp1(cmd.roll)
    local yaw_rate = 0
    if dt > 0 and finite(cmd.yaw_rad) then yaw_rate = math.clamp(cmd.yaw_rad / dt, -40, 40) end
    local look_pitch = finite(cmd.look_pitch) and cmd.look_pitch or 0
    local body = s.body
    local rate = s.rate

    -- Attitude: the flight controller asks for a turn rate on each axis and the drone catches up;
    -- with the motors off nothing drives it and only the air slows a spin.
    if motors then
        local w1, w2, w3
        if not cfg.angle_mode then
            w1 = flight.actual_rate(pitch_in, cfg.pitch) * DEG
            w2 = yaw_rate
            w3 = flight.actual_rate(roll_in, cfg.roll) * DEG
        else
            -- Lean toward the angle the sticks ask, about the heading the drone faces.
            local fwd = -body.b
            local level = V(fwd.x, 0, fwd.z)
            if len(level) < 0.05 then level = cross(body.r, UP) end
            level = norm(level)
            local level_right = V(-level.z, 0, level.x)
            local most = math.clamp(cfg.max_angle, 1, 89) * DEG
            local desired = rotate(UP, level_right, pitch_in * most)
            desired = rotate(desired, rotate(level, level_right, pitch_in * most), roll_in * most)
            local up = body.u
            local axis = cross(up, desired)
            local angle = math.atan2(len(axis), dot(up, desired))
            local spin = norm(axis) * (angle * math.max(cfg.angle_response, 0.5))
            local r1, _, r3 = body_rates(body, spin)
            local lp, lr = math.max(cfg.pitch.max, 30) * DEG, math.max(cfg.roll.max, 30) * DEG
            w1, w2, w3 = math.clamp(r1, -lp, lp), yaw_rate, math.clamp(r3, -lr, lr)
        end
        local k = 1 - math.exp(-dt / flight.rate_lag)
        rate[1] += (w1 - rate[1]) * k
        rate[2] += (w2 - rate[2]) * k
        rate[3] += (w3 - rate[3]) * k
    else
        local damp = math.exp(-dt * (s.grounded and 8 or 0.6))
        rate[1] *= damp
        rate[2] *= damp
        rate[3] *= damp
    end
    -- Prop wash: dropping straight down through its own wash shakes it.
    do
        local up = body.u
        local axial = dot(s.velocity, up)
        local across = len(s.velocity - up * axial)
        local sink = math.clamp((-axial - 1.5) / 6, 0, 1) * math.clamp(1 - across / 8, 0, 1)
        local amount = motors and math.clamp(cfg.propwash, 0, 1) * sink * 3 or 0
        local k = 1 - math.exp(-dt * 20)
        s.wash[1] += (noise(s) * amount - s.wash[1]) * k
        s.wash[2] += (noise(s) * amount - s.wash[2]) * k
    end
    for i = 1, 3 do
        if not finite(rate[i]) then rate[i] = 0 end
    end
    rotate_basis(body, body.u, rate[2] * dt)                                -- yaw about body up
    rotate_basis(body, body.r, (rate[1] + s.wash[1]) * dt - look_pitch)     -- pitch about body right
    rotate_basis(body, -body.b, (rate[3] + s.wash[2]) * dt)                 -- roll about body forward

    -- Translation.
    local next_position = position
    local hardest = 0
    if cmd.park then
        s.velocity = ZERO
        s.motor = 0
    else
        local right, up, back = body.r, body.u, body.b
        -- The throttle, or with height hold the output that keeps the asked climb, leaning or not.
        -- Height hold never holds the stick back: full stick is always full or no throttle.
        local want = math.clamp(cmd.throttle, 0, 1)
        if cmd.hold and motors then
            local stick = clamp1(cmd.climb)
            local direct = flight.spring_throttle(stick, hover_of(cfg))
            local lift = math.max(0, cfg.gravity + flight.hold_gain * (stick * math.max(cfg.climb_rate, 0) - s.velocity.y))
            local held = up.y > 0.25 and output_for(lift / up.y, cfg) or direct
            want = stick > 0 and math.max(held, direct) or stick < 0 and math.min(held, direct) or held
        end
        if not motors then want = 0 end
        s.motor += (want - s.motor) * (1 - math.exp(-dt / (want > s.motor and flight.spool_up or flight.spool_down)))
        local thrust = thrust_at(s.motor, cfg) * ((cmd.boost and motors) and flight.boost_thrust or 1)
        -- Inflow: climbing into its own air it pushes less, sinking a little more.
        local axial = dot(s.velocity, up)
        thrust *= math.clamp(1 - axial / math.max(top_speed(cfg.top_speed) * 2.5, 5), 0.3, 1.25)
        -- Ground effect: within a couple of prop sizes of the ground it pushes more.
        local r = math.max(cfg.radius, 0.01)
        if thrust > 0 and cast and cfg.collide then
            local reach = 4 * r
            local below = cast(position, position + V(0, -reach, 0))
            if below then thrust *= 1 + 0.25 * math.clamp(1 - (position.y - below.y) / reach, 0, 1) end
        end
        -- Drag: quadratic, larger across the props than edge on, plus the plain drag setting.
        local v = s.velocity
        local k = drag_for(cfg) * len(v)
        local drag = right * (-dot(v, right) * k) + up * (-dot(v, up) * 1.5 * k) + back * (-dot(v, back) * k)
        local accel = up * thrust + drag + V(-v.x * cfg.lin_drag, -cfg.gravity - v.y * cfg.lin_drag, -v.z * cfg.lin_drag)
        v += accel * dt
        -- (Only a guard against runaway numbers: drag sets the real top speed.)
        local cap = math.max(top_speed(cfg.top_speed) * 3, 30)
        local now = len(v)
        if now > cap then v *= cap / now end
        s.velocity = v
        next_position = position + v * dt
        s.grounded = false
        if cast and cfg.collide then
            -- Swept move: up to the first surface on the way, then what is left of the move slides
            -- along it. A hit takes away the speed into the surface; a hard one bounces back some of
            -- it and knocks the drone about.
            local p = position
            local move = next_position - position
            local spread = math.max(r, 0.05)
            for _ = 1, 3 do
                local length = len(move)
                if not (length > 1e-6) then break end
                local dir = move / length
                local hit = cast(p, p + dir * (length + r))
                if not hit then
                    p += move
                    break
                end
                local gap = len(hit - p) - r
                local allowed = math.clamp(gap, 0, length)
                p += dir * allowed
                local n = flight.surface_normal(cast, p, dir, length + r + 2 * spread, hit, spread)
                if gap < 0 then p += n * math.min(-gap, r) end -- started too close: step out
                if n.y > 0.6 then s.grounded = true end
                local into = dot(s.velocity, n)
                if into < 0 then
                    local impact = -into
                    local along = s.velocity - n * into
                    if cfg.crash and impact > flight.hard_hit then
                        s.velocity = along * 0.75 + n * (impact * flight.bounce)
                        -- Knocked about: spun away from the surface by the speed along it, plus some
                        -- of the hit at random.
                        local slide = math.min(len(along), 15)
                        local spin = norm(cross(n, along)) * (slide * 0.6)
                        spin += V(noise(s), noise(s), noise(s)) * (impact * 0.4)
                        local k1, k2, k3 = body_rates(body, spin)
                        rate[1] = math.clamp(rate[1] + k1, -30, 30)
                        rate[2] = math.clamp(rate[2] + k2, -30, 30)
                        rate[3] = math.clamp(rate[3] + k3, -30, 30)
                    else
                        s.velocity = along
                    end
                    hardest = math.max(hardest, impact)
                end
                if n.y > 0.6 then -- on the ground: skid to a stop
                    local grip = math.exp(-6 * dt)
                    local normal = dot(s.velocity, n)
                    s.velocity = (s.velocity - n * normal) * grip + n * normal
                end
                local rest = dir * (length - allowed)
                local push = dot(rest, n)
                if push < 0 then rest -= n * push end
                move = rest
            end
            next_position = p
            -- Safety net while the collision is not loaded: do not fall forever.
            local deep = s.start_y - 300
            if next_position.y < deep then
                next_position = V(next_position.x, deep, next_position.z)
                if s.velocity.y < 0 then s.velocity = V(s.velocity.x, 0, s.velocity.z) end
            end
        elseif cfg.floor > 0 then
            -- No collisions: an invisible floor so it lands instead of falling through the map.
            local floor_y = s.start_y - cfg.floor
            if next_position.y < floor_y then
                next_position = V(next_position.x, floor_y, next_position.z)
                local grip = math.exp(-6 * dt)
                s.velocity = V(s.velocity.x * grip, math.max(s.velocity.y, 0), s.velocity.z * grip)
                s.grounded = true
            end
        end
    end
    -- A hit hard enough cuts the motors (the drone falls and tumbles); any real one breaks up the picture.
    if cfg.crash and hardest > flight.hard_hit then
        s.glitch = math.max(s.glitch, math.clamp(hardest / math.max(cfg.crash_speed * 1.5, 4), 0.2, 1))
        if motors and cfg.crash_speed > 0 and hardest >= cfg.crash_speed then
            s.crashed = true
            s.crashed_now = true
        end
    end
    s.glitch *= math.exp(-dt * 2.5)

    local camera
    if cmd.gimbal then camera = flight.camera_on_gimbal(body, cmd.gimbal, flight.gimbal_roll_share)
    else camera = flight.camera_from_body(body, uptilt) end
    if not (finite_vector(next_position) and finite_vector(s.velocity) and finite_vector(camera.r) and finite_vector(camera.u)) then
        -- Bad numbers: start again where it was.
        flight.start(s, position, -s.start_body.b, cfg.armed, cfg)
        return
    end
    s.position = next_position
    s.camera = camera
    if cfg.armed then s.flight_time += dt end
    s.throttle = cmd.park and 0 or math.clamp(s.motor, 0, 1)
    s.speed = len(s.velocity)
    s.altitude = next_position.y - s.start_y
    s.armed_now = cfg.armed and not s.crashed
end

-- Keyboard and mouse (reskate.input.flight()): the keyboard has no throttle that stays put, so
-- with height hold the middle holds the height and E / Q climb and descend; without it the middle
-- is hover power. Also returns the sticks to show: roll, pitch, yaw, throttle (-1 to 1).
function flight.keyboard_command(input, cfg)
    local cmd = flight.command()
    cmd.pitch = clamp1(-input.forward) -- forward = nose down
    cmd.roll = clamp1(input.right)
    local look_x = math.clamp(finite(input.look_x) and input.look_x or 0, -250, 250)
    local look_y = math.clamp(finite(input.look_y) and input.look_y or 0, -250, 250)
    cmd.yaw_rad = -look_x * cfg.yaw_look_scale -- right = negative about up
    cmd.look_pitch = look_y * cfg.yaw_look_scale
    local up_in = clamp1(input.up)
    cmd.throttle = flight.spring_throttle(up_in, cfg.hover)
    cmd.hold = cfg.alt_hold
    cmd.climb = up_in
    cmd.boost = input.boost and true or false
    return cmd, {roll = clamp1(input.right), pitch = clamp1(input.forward), yaw = clamp1(look_x / 40), throttle = up_in}
end

-- A controller's sticks (radio.lua: an RC radio, or a gamepad read as one). A throttle stick that
-- stays put is absolute thrust; one that springs back holds the height (height hold) or hovers in
-- its middle.
function flight.radio_command(sticks, seconds, cfg)
    local dt = math.clamp(finite(seconds) and seconds or 0, 0, 0.05)
    local cmd = flight.command()
    cmd.pitch = clamp1(-sticks.pitch) -- stick forward = nose down
    cmd.roll = clamp1(sticks.roll)
    cmd.yaw_rad = -flight.actual_rate(clamp1(sticks.yaw), cfg.yaw) * DEG * dt
    cmd.throttle = math.clamp(sticks.throttle, 0, 1)
    cmd.hold = sticks.centred and cfg.alt_hold
    cmd.climb = clamp1(sticks.climb)
    return cmd, {roll = clamp1(sticks.roll), pitch = clamp1(sticks.pitch), yaw = clamp1(sticks.yaw),
                 throttle = sticks.centred and clamp1(sticks.climb) or nil}
end

return flight
