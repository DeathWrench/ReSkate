-- The drone's maths, checked without the game: the flight model over a fake world, the
-- controllers, the follow autopilot, the messages and the display. `fpv test` runs them (one every
-- few ticks, as each call into a plugin has 50 ms) and prints the failures and a summary; the host
-- test runner (dingosdk_plugin_tests) runs it too.
local settings = require("settings")
local flight = require("flight")
local radio = require("radio")
local follow = require("follow")
local osd = require("osd")
local beacon = require("beacon")

local V = vector.create
local len, dot = vector.magnitude, vector.dot
local tests = {}
local list = {}
local function test(name, fn)
    table.insert(list, {name = name, fn = fn})
end

local function near(a, b, within, what)
    if not (math.abs(a - b) <= within) then error(string.format("%s: %g, not %g (within %g)", what or "value", a, b, within), 2) end
end
local function check(ok, what)
    if not ok then error(what or "check failed", 2) end
end

-- A world of flat ground at y = 0 and, when asked, a wall at x = wall.
local function world(wall)
    return function(from, to)
        local best, at = 2, nil
        if (from.y > 0) ~= (to.y > 0) then
            local f = from.y / (from.y - to.y)
            if f < best then best, at = f, from + (to - from) * f end
        end
        if wall and (from.x < wall) ~= (to.x < wall) then
            local f = (wall - from.x) / (to.x - from.x)
            if f < best then best, at = f, from + (to - from) * f end
        end
        return at
    end
end

local function config(changes)
    local cfg = settings.flight(true)
    for k, v in changes or {} do cfg[k] = v end
    return cfg
end
local function hover_command(cfg)
    local cmd = flight.command()
    cmd.throttle = cfg.hover
    return cmd
end
local function basis_square(m)
    return math.abs(len(m.r) - 1) < 1e-3 and math.abs(len(m.u) - 1) < 1e-3 and math.abs(len(m.b) - 1) < 1e-3
        and math.abs(dot(m.r, m.u)) < 1e-3 and math.abs(dot(m.u, m.b)) < 1e-3 and math.abs(dot(m.r, m.b)) < 1e-3
end

local DT = 1 / 50

test("rates follow Betaflight's actual curve", function()
    local rate = {center = 80, max = 700, expo = 0.15}
    near(flight.actual_rate(0, rate), 0, 1e-6, "no stick")
    near(flight.actual_rate(1, rate), 700, 1e-3, "full stick")
    near(flight.actual_rate(-1, rate), -700, 1e-3, "full stick the other way")
    local small = flight.actual_rate(0.005, rate)
    near(small / 0.005, 80, 3, "the centre sensitivity")
    check(flight.actual_rate(0.5, rate) < flight.actual_rate(0.5, {center = 80, max = 700, expo = 0}), "expo softens the middle")
end)

test("a springing throttle hovers in the middle", function()
    near(flight.spring_throttle(0, 0.35), 0.35, 1e-6, "middle")
    near(flight.spring_throttle(1, 0.35), 1, 1e-6, "up")
    near(flight.spring_throttle(-1, 0.35), 0, 1e-6, "down")
    near(flight.spring_throttle(0.5, 0.2), 0.6, 1e-6, "half up")
end)

test("thrust grows with output to the power 1.5 and the hover throttle holds it up", function()
    local cfg = config({hover = 0.22})
    near(flight.thrust_at(0.22, cfg), cfg.gravity, 1e-3, "thrust at hover")
    near(flight.max_thrust(cfg) / cfg.gravity, (1 / 0.22) ^ 1.5, 1e-3, "thrust to weight")
    near(flight.output_for(cfg.gravity, cfg), 0.22, 1e-4, "the output that hovers")
    near(flight.thrust_at(0.5, cfg) / flight.thrust_at(1, cfg), 0.5 ^ 1.5, 1e-4, "the power")
end)

test("hovering holds its height, full throttle climbs, none falls", function()
    local cfg = config({collide = false, floor = 0})
    local s = flight.new_state(V(0, 50, 0), V(0, 0, -1), true, cfg)
    for _ = 1, 100 do flight.step(s, hover_command(cfg), DT, cfg) end
    near(s.position.y, 50, 0.3, "height after 2 s of hover")
    local climb = flight.command()
    climb.throttle = 1
    for _ = 1, 50 do flight.step(s, climb, DT, cfg) end
    check(s.position.y > 55, "full throttle climbs: " .. s.position.y)
    local fall = flight.command()
    fall.throttle = 0
    local peak = s.position.y
    for _ = 1, 250 do
        flight.step(s, fall, DT, cfg)
        peak = math.max(peak, s.position.y)
    end
    check(s.position.y < peak - 10, "no throttle falls")
    check(s.velocity.y < -3, "and keeps falling")
end)

test("motors spool up and down rather than jump", function()
    local cfg = config({collide = false})
    local s = flight.new_state(V(0, 10, 0), V(0, 0, -1), true, cfg)
    local cmd = flight.command()
    cmd.throttle = 1
    flight.step(s, cmd, 0.01, cfg)
    check(s.motor < 0.6, "one step does not reach full: " .. s.motor)
    for _ = 1, 20 do flight.step(s, cmd, DT, cfg) end
    near(s.motor, 1, 0.01, "full after a while")
end)

test("flat out it settles near four times the top speed", function()
    for _, top in {6, 10} do
        local cfg = config({collide = false, floor = 0, angle_mode = true, max_angle = 60, top_speed = top, hover = 0.22, lin_drag = 0})
        local s = flight.new_state(V(0, 500, 0), V(0, 0, -1), true, cfg)
        local cmd = flight.command()
        cmd.pitch = -1 -- nose down: forward
        cmd.throttle = 1
        for _ = 1, 400 do flight.step(s, cmd, DT, cfg) end
        local level = math.sqrt(s.velocity.x ^ 2 + s.velocity.z ^ 2)
        check(level > top * 4 * 0.75 and s.speed < top * 4 * 1.3, string.format("top speed %g: %.1f m/s across, %.1f all, wanted near %g", top, level, s.speed, top * 4))
    end
end)

test("acro keeps the angle it is left at; angle mode levels out", function()
    local cfg = config({collide = false, floor = 0})
    local s = flight.new_state(V(0, 100, 0), V(0, 0, -1), true, cfg)
    local roll = hover_command(cfg)
    roll.roll = 0.3
    for _ = 1, 10 do flight.step(s, roll, DT, cfg) end
    local leaning = s.body.r.y
    check(math.abs(leaning) > 0.2, "rolled: " .. leaning)
    for _ = 1, 25 do flight.step(s, hover_command(cfg), DT, cfg) end
    near(s.body.r.y, leaning, 0.15, "acro stays rolled")
    cfg.angle_mode = true
    for _ = 1, 100 do flight.step(s, hover_command(cfg), DT, cfg) end
    near(s.body.r.y, 0, 0.05, "angle mode is level again")
    check(basis_square(s.body), "the body stays square")
end)

test("the body stays square through flips", function()
    local cfg = config({collide = false, floor = 0})
    local s = flight.new_state(V(0, 100, 0), V(1, 0, 0), true, cfg)
    local cmd = hover_command(cfg)
    cmd.roll, cmd.pitch, cmd.yaw_rad = 1, -0.7, 0.05
    for _ = 1, 300 do flight.step(s, cmd, DT, cfg) end
    check(basis_square(s.body), "square after 6 s of flips")
    check(basis_square(s.camera), "and so is the camera")
end)

test("the ground stops it and it rests on the ground", function()
    local cfg = config({radius = 0.3})
    local cast = world()
    local s = flight.new_state(V(0, 3, 0), V(0, 0, -1), true, cfg)
    local cmd = flight.command()
    cmd.throttle = 0.1
    local lowest = 1e9
    for _ = 1, 150 do
        flight.step(s, cmd, DT, cfg, cast)
        lowest = math.min(lowest, s.position.y)
    end
    check(lowest > 0.2, "it never goes into the ground: " .. lowest)
    check(s.position.y < 0.5, "it comes down: " .. s.position.y)
    check(s.grounded, "and is on the ground")
    check(not s.crashed, "a gentle landing is no crash")
end)

test("a hard hit cuts the motors, and arming again puts it right", function()
    local cfg = config({radius = 0.3, crash_speed = 7})
    local cast = world(10)
    local s = flight.new_state(V(0, 5, 0), V(1, 0, 0), true, cfg)
    s.velocity = V(20, 0, 0)
    local cmd = hover_command(cfg)
    local crashed = false
    for _ = 1, 50 do
        flight.step(s, cmd, DT, cfg, cast)
        crashed = crashed or s.crashed_now
        check(s.position.x < 10, "it never goes through the wall: " .. s.position.x)
    end
    check(crashed and s.crashed, "20 m/s into a wall is a crash")
    check(s.glitch > 0, "and breaks up the picture")
    cfg.armed = false
    flight.step(s, cmd, DT, cfg, cast)
    cfg.armed = true
    flight.step(s, cmd, DT, cfg, cast)
    check(not s.crashed, "off and on again arms it")
    local soft = config({radius = 0.3, crash = false})
    local t = flight.new_state(V(0, 5, 0), V(1, 0, 0), true, soft)
    t.velocity = V(20, 0, 0)
    for _ = 1, 50 do flight.step(t, hover_command(soft), DT, soft, cast) end
    check(not t.crashed and t.position.x < 10, "with crashes off it just stops")
end)

test("without collisions an invisible floor holds it", function()
    local cfg = config({collide = false, floor = 1.5})
    local s = flight.new_state(V(0, 10, 0), V(0, 0, -1), true, cfg)
    local cmd = flight.command()
    cmd.throttle = 0
    for _ = 1, 200 do flight.step(s, cmd, DT, cfg) end
    near(s.position.y, 8.5, 1e-3, "it sits on the floor")
end)

test("range breaks the picture up and then cuts the motors", function()
    near(flight.signal_strength(100, 300), 1, 1e-6, "clean near")
    near(flight.signal_strength(300, 300), 0, 1e-6, "lost at the range")
    local mid = flight.signal_strength(225, 300)
    check(mid > 0 and mid < 1, "fading between")
    check(not flight.failsafe_due(300, 300, 4.9), "not yet")
    check(flight.failsafe_due(300, 300, 5), "five seconds without a picture")
    check(flight.failsafe_due(451, 300, 0), "far past it at once")
    check(not flight.failsafe_due(1e6, 0, 100), "unlimited never")
    local cfg = config({collide = false, floor = 0, range = 50})
    local s = flight.new_state(V(0, 100, 0), V(0, 0, -1), true, cfg)
    s.position = V(0, 100, 80)
    flight.step(s, hover_command(cfg), DT, cfg)
    check(s.failsafe and s.signal == 0, "past 1.5 times the range the motors cut")
    flight.reset(s, true, cfg)
    flight.step(s, hover_command(cfg), DT, cfg)
    check(not s.failsafe, "a reset puts it right")
end)

test("disarmed it falls, or hangs with disarmfreeze", function()
    local cfg = config({collide = false, floor = 0, armed = false})
    local s = flight.new_state(V(0, 50, 0), V(0, 0, -1), false, cfg)
    for _ = 1, 50 do flight.step(s, hover_command(cfg), DT, cfg) end
    check(s.position.y < 47, "it falls")
    cfg.disarm_freeze = true
    local y = s.position.y
    for _ = 1, 50 do flight.step(s, hover_command(cfg), DT, cfg) end
    near(s.position.y, y, 1e-4, "it hangs")
end)

test("height hold keeps the height while leaning", function()
    local cfg = config({collide = false, floor = 0, angle_mode = true, alt_hold = true})
    local s = flight.new_state(V(0, 30, 0), V(0, 0, -1), true, cfg)
    local cmd = flight.command()
    cmd.hold, cmd.climb, cmd.pitch = true, 0, -0.6
    for _ = 1, 150 do flight.step(s, cmd, DT, cfg) end
    near(s.position.y, 30, 1.5, "height after 3 s leaning")
    check(len(s.velocity) > 5, "and it went somewhere")
end)

test("the gimbal keeps its tilt whatever the body does", function()
    local body = flight.level_basis(V(0, 0, -1))
    flight.rotate_basis(body, body.r, -0.5) -- nose down
    local cam = flight.camera_on_gimbal(body, 0.2, 0.3)
    near(math.asin(-cam.b.y), 0.2, 1e-3, "the camera's pitch")
    near(cam.r.y, 0, 1e-3, "no roll without the body's")
end)

test("the keyboard flies as the C++ drone's did", function()
    local cfg = config({})
    local cmd, shown = flight.keyboard_command({right = 1, up = 0, forward = 1, look_x = 40, look_y = 0, boost = true}, cfg)
    near(cmd.pitch, -1, 1e-6, "forward is nose down")
    near(cmd.roll, 1, 1e-6, "right rolls right")
    check(cmd.yaw_rad < 0, "the mouse right turns right")
    near(cmd.throttle, cfg.hover, 1e-6, "the middle hovers")
    check(cmd.boost and shown.yaw == 1, "boost, and the yaw shown")
end)

test("a radio's axes, reversed and with a dead zone", function()
    local s = radio.map_axes({0.5, -1, 0.0, 0.02, 0, 0}, {1, -2, 3, 4}, 0.03, false, 0.35)
    check(s.valid, "valid")
    near(s.roll, (0.5 - 0.03) / 0.97, 1e-5, "roll")
    near(s.pitch, 1, 1e-6, "pitch reversed")
    near(s.throttle, 0.5, 1e-6, "a throttle that stays put is absolute")
    near(s.yaw, 0, 1e-6, "inside the dead zone")
    local c = radio.map_axes({0, 0, -0.5, 0, 0, 0}, {1, 2, 3, 4}, 0.03, true, 0.35)
    check(c.centred and c.climb < 0 and c.throttle < 0.35, "a springing throttle below the middle descends")
end)

test("a gamepad's sticks: round dead zone, softer middle, inverted pitch", function()
    local s = radio.gamepad_sticks({left_x = 0.05, left_y = 0, right_x = 1, right_y = 1}, 0.03, 0.6, 0.45, 0.35, true, false)
    near(s.yaw, 0, 1e-6, "inside the dead zone")
    check(s.roll > 0 and s.roll <= 0.6, "full roll is scaled down: " .. s.roll)
    check(s.pitch < 0, "inverted: up tips the nose up")
    near(s.throttle, 0.35, 1e-6, "the middle hovers")
    local angle = radio.gamepad_sticks({left_x = 0, left_y = 0, right_x = 1, right_y = 0}, 0.1, 0.6, 0, 0.35, false, true)
    near(angle.roll, 1, 1e-6, "in angle mode full stick leans all the way")
end)

test("switches arm and reset on clear moves only", function()
    local memory = {}
    local armed, reset = radio.switches(memory, {0, 0, 0, 0, 0.9, 0}, 0, 5, 0, 0, 0)
    check(armed == true and not reset, "axis 5 high arms")
    armed = radio.switches(memory, {0, 0, 0, 0, 0.3, 0}, 0, 5, 0, 0, 0)
    check(armed == nil, "the middle says nothing")
    armed = radio.switches(memory, {0, 0, 0, 0, 0.9, 0}, 0, -5, 0, 0, 0)
    check(armed == false, "reversed")
    local _, first = radio.switches(memory, {0, 0, 0, 0, 0, 0.9}, 0, 0, 0, 6, 0)
    local _, again = radio.switches(memory, {0, 0, 0, 0, 0, 0.9}, 0, 0, 0, 6, 0)
    check(first and not again, "a reset switch resets once when flicked")
    local bits = radio.button_bits({false, false, true})
    check(radio.pressed(bits, 3) and not radio.pressed(bits, 2), "button bits")
    local _, held = radio.switches(memory, {0, 0, 0, 0, 0, 0}, bits, 0, 3, 0, 0)
    check(held == false, "an arm button")
    check(radio.switches(memory, {0, 0, 0, 0, 0, 0}, bits, 0, 3, 0, 0) == true, "held is armed")
end)

test("gamepad buttons count once each press, and not while the menu has them", function()
    local memory = {}
    local a = radio.pad_buttons(memory, {a = true}, true)
    check(not a, "held from before counts for nothing")
    radio.pad_buttons(memory, {a = false}, true)
    a = radio.pad_buttons(memory, {a = true}, true)
    check(a, "pressed")
    a = radio.pad_buttons(memory, {a = true}, true)
    check(not a, "held is not pressed again")
    radio.pad_buttons(memory, {}, false)
    local _, start = radio.pad_buttons(memory, {start = true}, false)
    check(not start, "not while the menu has the pad")
end)

test("the guided setup finds each stick and switch", function()
    local c = radio.calibration()
    c:start()
    local rest = {0, 0, -1, 0, -1, 0}
    c:capture_rest(rest, 0)
    check(c.step == "throttle", "after rest: throttle")
    local function hold(axes, bits)
        for _ = 1, 20 do c:update(axes, bits or 0, 0.05) end
    end
    hold({0, 0, -1, 1, -1, 0}) -- throttle is axis 4 here... and reversed below
    hold(rest)
    hold({0, 0, -1, 0, -1, 0}) -- (nothing)
    check(c.step == "yaw", "throttle found: " .. c.step)
    hold({0, 0, 0.5, 0, -1, 0}) -- yaw: axis 3 moved up from -1
    hold(rest)
    hold({0, -1, -1, 0, -1, 0}) -- pitch forward is axis 2 going down
    hold(rest)
    hold({1, 0, -1, 0, -1, 0}) -- roll axis 1
    hold(rest)
    check(c.step == "arm", "the sticks are done: " .. c.step)
    hold({0, 0, -1, 0, 1, 0}) -- arm switch on axis 5
    check(c.step == "reset", "arm found: " .. c.step)
    hold({0, 0, -1, 0, 1, 0}, bit32.lshift(1, 6)) -- reset: button 7
    hold({0, 0, -1, 0, 1, 0}, 0)
    check(c.step == "done", "done: " .. c.step)
    check(c.map[1] == 1 and c.map[2] == -2 and c.map[3] == 4 and c.map[4] == 3,
        string.format("the axes: %d %d %d %d", c.map[1], c.map[2], c.map[3], c.map[4]))
    check(c.throttle_centred, "a throttle resting in the middle springs back")
    check(c.arm_axis == 5 and c.reset_button == 7, "the switches")
end)

test("follow mode sits behind a skater riding along, above the ground", function()
    local cast = world()
    local t = follow.tuning(4.5, 0.5)
    local cfg = follow.flight_settings(settings.flight(true), t)
    local skater = V(0, 0, 0)
    local heading = V(0, 0, 1)
    local s = flight.new_state(V(0, 2, -5), heading, true, cfg)
    local p = follow.pilot()
    local lowest = 1e9
    for _ = 1, 400 do
        skater += heading * (5 * DT)
        local cmd = follow.fly(p, s, skater, heading, DT, cfg, t, cast)
        flight.step(s, cmd, DT, cfg, cast)
        lowest = math.min(lowest, s.position.y)
    end
    local behind = -dot(s.position - skater, heading)
    check(behind > 2 and behind < 9, "behind the skater: " .. behind)
    check(lowest > 0.5, "never on the ground: " .. lowest)
    local to = (skater + V(0, 1, 0)) - s.position
    local facing = -s.body.b
    check(dot(vector.normalize(V(to.x, 0, to.z)), vector.normalize(V(facing.x, 0, facing.z))) > 0.9, "and looks at the skater")
end)

test("follow mode films a session from the side", function()
    local t = follow.tuning(4.5, 0.5)
    local cfg = follow.flight_settings(settings.flight(true), t)
    local s = flight.new_state(V(0, 2, -6), V(0, 0, 1), true, cfg)
    local p = follow.pilot()
    local time = 0
    for _ = 1, 500 do
        time += DT
        local skater = V(0, 0, 6 * math.sin(time * 1.2)) -- back and forth across a halfpipe
        local cmd = follow.fly(p, s, skater, V(0, 0, math.cos(time * 1.2) >= 0 and 1 or -1), DT, cfg, t, nil)
        flight.step(s, cmd, DT, cfg, nil)
    end
    check(p.session, "riding back and forth is a session")
    check(math.abs(s.position.x) > 3, "watched from the side: " .. tostring(s.position))
end)

test("messages carry where a drone is, and markers glide", function()
    local body = flight.level_basis(V(1, 0, 0))
    local q = beacon.rotation(body)
    near(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2, 1, 1e-4, "a unit rotation")
    local id = beacon.rotation(flight.level_basis(V(0, 0, -1)))
    near(id[4], 1, 1e-4, "facing -z is no rotation")
    local m = beacon.decode(beacon.encode(true, V(10, 2, -3), q, 0.5, 12.5))
    check(m and m.flying, "decoded")
    near(m.position.x, 10, 1e-4, "x")
    near(m.throttle, 0.5, 0.01, "throttle")
    near(m.speed, 12.5, 0.01, "speed")
    check(beacon.decode("hello") == nil, "not one of ours")
    local player = {id = "7656", name = "Zee"}
    beacon.receive(player, beacon.encode(true, V(0, 0, 0), q, 0.4, 0), 1000)
    beacon.receive(player, beacon.encode(true, V(10, 0, 0), q, 0.4, 0), 1100)
    local r = beacon.remotes["7656"]
    near(beacon.position(r, 1150).x, 5, 1e-3, "halfway through the glide")
    near(beacon.position(r, 1300).x, 10, 1e-3, "there at the end")
    beacon.receive(player, beacon.encode(true, V(500, 0, 0), q, 0.4, 0), 1150)
    near(beacon.position(r, 1150).x, 500, 1e-3, "a jump is shown at once")
    beacon.receive(player, beacon.encode(false, V(0, 0, 0), q, 0, 0), 1200)
    check(beacon.remotes["7656"] == nil and beacon.count() == 0, "a stop takes it away")
end)

test("a flying drone sends about 12 times a second and says when it stops", function()
    local cfg = config({})
    local s = flight.new_state(V(0, 5, 0), V(0, 0, -1), true, cfg)
    local sent = 0
    for ms = 0, 1000, 10 do
        if beacon.outgoing(100000 + ms, s, true) then sent += 1 end
    end
    check(sent >= 11 and sent <= 14, "sent " .. sent)
    local last = beacon.outgoing(101100, nil, true)
    check(last and not beacon.decode(last).flying, "and once to say it stopped")
    check(beacon.outgoing(101200, nil, true) == nil, "then nothing")
end)

test("the goggle display shows what the C++ one did", function()
    local cfg = config({})
    local s = flight.new_state(V(0, 5, 0), V(0, 0, -1), true, cfg)
    s.armed_now = true
    s.sticks = {roll = 0.5, pitch = 0, yaw = 0}
    local values = table.clone(settings.values)
    local layout = osd.layout(s, values)
    local texts = {}
    for _, item in layout.items do texts[item.text] = item end
    check(texts["ARMED"] and texts["00:00"] and texts["THR 35%"] and texts["ALT 0.0M"] and texts["0KM/H"] and texts["16.6V"],
        "the readouts")
    check(texts["16.6V"].align == "left" and texts["00:00"].align == "right" and texts["THR 35%"].bottom, "where they sit")
    near(layout.sticks.throttle, 0.35 * 2 - 1, 1e-6, "a throttle that stays put shows as the throttle")
    values.osd = 0
    values.range = 100
    s.signal, s.signal_lost = 0, 2
    s.crashed = true
    local warnings = osd.layout(s, values)
    local found = {}
    for _, item in warnings.items do found[item.text] = item end
    check(found["NO SIGNAL - TURN BACK (3)"] and found["CRASHED - ARM TO FLY AGAIN"], "the warnings show without the display")
    check(#warnings.items == 2, "and nothing else")
    near(osd.pixel_width("ABC", 2), 34, 1e-6, "a pixel string's width")
end)

test("settings clamp, presets set a whole drone", function()
    check(settings.count == 63, "62 of the C++ drone's and the top speed: " .. settings.count)
    local before = settings.get("hover")
    check(settings.set("hover", 5) == 0.9, "clamped to its range")
    check(settings.set("nothing", 1) == nil, "an unknown one is refused")
    settings.apply_preset(3)
    check(settings.matching_preset() == 3, "the 5 inch matches")
    check(settings.get("topspeed") == 10 and settings.get("hover") == 0.22, "its values")
    settings.set("rollmax", 300)
    check(settings.matching_preset() == nil, "changed: custom")
    settings.set("hover", before)
end)

-- Runs one test every few ticks; `say` prints.
function tests.run(say)
    -- From the defaults, whatever the player has set; theirs come back after.
    local saved_values, saved_controller = table.clone(settings.values), table.clone(settings.controller)
    settings.keep(false)
    for name, info in settings.info do settings.values[name] = info.def end
    local passed, failed, index = 0, 0, 0
    local timer
    local function finish()
        reskate.time.cancel(timer)
        for name, value in saved_values do settings.values[name] = value end
        settings.controller = saved_controller
        settings.keep(true)
        beacon.clear()
        say(string.format("fpv test: %d passed, %d failed", passed, failed))
    end
    timer = reskate.time.every(50, function()
        index += 1
        local entry = list[index]
        if not entry then return finish() end
        local ok, why = pcall(entry.fn)
        if ok then passed += 1
        else
            failed += 1
            say("FAIL " .. entry.name .. ": " .. tostring(why))
        end
    end)
end
tests.list = list

return tests
