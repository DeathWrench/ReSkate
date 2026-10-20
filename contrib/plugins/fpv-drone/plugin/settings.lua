-- The drone's settings: the same 62 the C++ drone had (dronetune's names), the top speed (freecam's
-- flyspeed there) and the controller's axes, kept in the plugin's storage. `fpv tune` and the menu
-- panels change them through set(), which clamps a value to its range and saves it.
local settings = {}

-- name, help, lowest, highest, default.
settings.list = {
    {"gravity", "How hard the drone is pulled down. 9.8 is Earth; higher feels heavier and snappier", 0, 50, 9.81},
    {"drag", "Air resistance. Higher slows the drone down sooner when you let off", 0, 3, 0.15},
    {"hover", "The throttle that keeps the drone in the air (0.1-0.9). Lower means more power to spare: 0.22 is about ten times its weight in thrust, a 5-inch's", 0.1, 0.9, 0.35},
    {"rollcenter", "Roll speed near the middle of the stick, in degrees per second (Betaflight \"Actual\" rates)", 1, 1000, 80},
    {"rollmax", "Roll speed with the stick fully over, in degrees per second", 30, 2000, 700},
    {"rollexpo", "How much softer roll is near the middle of the stick (0 = none, 1 = most)", 0, 1, 0.15},
    {"pitchcenter", "Pitch speed near the middle of the stick, in degrees per second", 1, 1000, 80},
    {"pitchmax", "Pitch speed with the stick fully over, in degrees per second", 30, 2000, 700},
    {"pitchexpo", "How much softer pitch is near the middle of the stick (0 = none, 1 = most)", 0, 1, 0.15},
    {"yawcenter", "Yaw (turning) speed near the middle of the stick, in degrees per second", 1, 1000, 130},
    {"yawmax", "Yaw speed with the stick fully over, in degrees per second", 30, 2000, 780},
    {"yawexpo", "How much softer yaw is near the middle of the stick (0 = none, 1 = most)", 0, 1, 0.30},
    {"uptilt", "How far the camera points up, in degrees. Real FPV cameras sit at about 25-40; faster flying needs more", -30, 70, 0},
    {"floor", "With collisions off: an invisible floor this many metres below where you took off (0 = none)", 0, 1000, 1.5},
    {"collide", "Hit the ground, walls and ramps (1), or fly through everything (0)", 0, 1, 1},
    {"radius", "How big the drone is for collisions, in metres: how close it gets to things", 0.05, 3, 0.3},
    {"osd", "Show the goggle display: battery, timer, throttle, altitude, speed and signal. The range warnings show either way", 0, 1, 1},
    {"volume", "Motor sound volume (0 = silent)", 0, 1, 0.09},
    {"osdscale", "Size of the goggle display's text (1 = normal, 2 = double)", 0.4, 5, 1.5},
    {"osdcolor", "Goggle display colour: 0 white, 1 green, 2 yellow, 3 cyan, 4 orange, 5 pink", 0, 5, 0},
    {"osdfont", "Goggle display font: 0 = pixel, like real goggles; 1 = smooth", 0, 1, 0},
    {"osdmargin", "How far the goggle display sits in from the screen edges (0-0.3 of the screen)", 0, 0.3, 0.06},
    {"crosshair", "Show a crosshair in the middle of the screen", 0, 1, 0},
    {"osdarmed", "Show ARMED / DISARMED", 0, 1, 1},
    {"osdbattery", "Show the battery voltage", 0, 1, 1},
    {"osdtimer", "Show the flight timer", 0, 1, 1},
    {"osdthrottle", "Show the throttle", 0, 1, 1},
    {"osdalt", "Show the altitude", 0, 1, 1},
    {"osdspeed", "Show the speed", 0, 1, 1},
    {"sticks", "Show your sticks on screen (left: throttle and yaw, right: pitch and roll)", 0, 1, 1},
    {"sticksize", "Size of the on-screen sticks (1 = normal)", 0.4, 3, 1},
    {"armaxis", "Controller axis (1-6) for an arm switch: switch on = armed. Minus reverses it; 0 = none. Use one no stick is on", -6, 6, 0},
    {"resetaxis", "Controller axis (1-6) for a reset switch: flick it on to put the drone back. 0 = none. Use one no stick is on", -6, 6, 0},
    {"disarmfreeze", "When disarmed, the drone hangs in the air (1) instead of falling (0)", 0, 1, 0},
    {"beacon", "Let other players see your drone (they need this mod too)", 0, 1, 1},
    {"showbeacons", "Show other players' drones (0 hides them)", 0, 1, 1},
    {"armbutton", "Controller button (1-32) to arm with: held = armed. 0 = none", 0, 32, 0},
    {"resetbutton", "Controller button (1-32) that puts the drone back where it took off. 0 = none", 0, 32, 0},
    {"analog", "Make the picture look like analogue FPV video: scanlines, static, dark corners and glitches", 0, 1, 0},
    {"analognoise", "Analogue look: how much static (0-1)", 0, 1, 0.35},
    {"analogscan", "Analogue look: how strong the scanlines are (0-1)", 0, 1, 0.5},
    {"analogvignette", "Analogue look: how dark the corners are (0-1)", 0, 1, 0.5},
    {"analogglitch", "Analogue look: how often the picture rolls and tears (0-1)", 0, 1, 0.3},
    {"range", "How far your signal reaches from where you took off, in metres. 0 = unlimited", 0, 5000, 0},
    {"motorpitch", "Motor sound pitch. Higher sounds like a smaller drone", 0.4, 2.5, 1},
    {"throttlecentre", "Your throttle stick springs back to the middle (gamepads): the middle hovers, up climbs, down descends", 0, 1, 0},
    {"deadzone", "How far a stick must move before the drone reacts (0-0.3). Raise it if the drone drifts on its own", 0, 0.3, 0.03},
    {"goggles", "What your skater wears over their eyes while you fly: 0 = nothing, 1-8 = one of the eyewear choices on the FPV Drone panel", 0, 8, 1},
    {"hideui", "Hide the game's own interface while you fly or the drone follows you", 0, 1, 1},
    {"gamepad", "Fly with a gamepad (Xbox or PlayStation) instead of an RC radio: left stick throttle and yaw, right stick pitch and roll, with gentler sticks. A arms, Menu / Options puts the drone back", 0, 1, 1},
    {"padrate", "Gamepad: how much of your rates the sticks reach at full tilt (0.2-1). Lower is calmer. In angle mode it slows turning only: full stick still leans all the way", 0.2, 1, 0.6},
    {"padexpo", "Gamepad: how much softer the middle of the sticks is, for small corrections (0 = none, 1 = most)", 0, 1, 0.45},
    {"althold", "With a throttle that springs back to the middle (a gamepad, or the keyboard): hold your height (1), adding throttle as you lean to keep it; up climbs, down descends. Off (0): the middle is hover power and the throttle is yours alone", 0, 1, 0},
    {"climbrate", "Height hold: how fast full throttle stick climbs or descends, in metres per second", 1, 40, 20},
    {"mode", "Flight mode: 0 = acro (the stick sets how fast it turns, full flips), 1 = angle (self-levelling: the stick sets how far it leans, and letting go levels it)", 0, 1, 0},
    {"maxangle", "Angle mode: how far the drone leans at full stick, in degrees", 10, 80, 55},
    {"crash", "Crashes: hits bounce and tumble the drone, and a hard one cuts the motors until you arm again (1). Off: it just stops against things (0)", 0, 1, 1},
    {"crashspeed", "Crashes: how hard a hit cuts the motors, in metres per second into the surface. 0 = never", 0, 30, 7},
    {"propwash", "How much the drone shakes when it drops through its own prop wash (0-1)", 0, 1, 0.5},
    {"padinvert", "Gamepad: push the right stick up to tip the nose up, like aiming a camera (1); or to tip it down and fly forward, like an RC radio (0)", 0, 1, 1},
    {"followdistance", "Follow me: how far behind you the drone flies, in metres (it flies a little higher the further back it is)", 3, 12, 4.5},
    {"followaggression", "Follow me: how hard the pilot flies (0-1). Low is a calm cinematic pilot who lags a little and leans gently; high reacts fast, leans hard and stays right on you", 0, 1, 0.5},
    -- Not one of dronetune's: freecam's flyspeed there.
    {"topspeed", "Top speed: full throttle flat out settles near four times this, in metres per second", 0.6, 300, 15},
}
settings.count = #settings.list
settings.info = {}
for index, entry in settings.list do
    settings.info[entry[1]] = {index = index, name = entry[1], help = entry[2], lo = entry[3], hi = entry[4], def = entry[5]}
end

-- The values now, by name; and the controller: whether the drone flies with it, and which axis
-- (1-6, minus reversed) is roll, pitch, throttle and yaw (AETR, an EdgeTX radio's Mode 2).
settings.values = {}
settings.controller = {enabled = true, map = {1, 2, 3, 4}}
for name, info in settings.info do settings.values[name] = info.def end

local function clamp_to(info, value)
    if type(value) ~= "number" or value ~= value then return info.def end
    return math.clamp(value, info.lo, info.hi)
end

function settings.get(name)
    return settings.values[name]
end
function settings.on(name)
    return settings.values[name] >= 0.5
end

local saving = true
local function save()
    if not saving then return end
    pcall(reskate.storage.set, "settings", settings.values)
    pcall(reskate.storage.set, "controller", settings.controller)
end

-- The value it was set to (clamped), or nil and why for a name there is none of.
function settings.set(name, value)
    local info = settings.info[name]
    if not info then return nil, "there is no setting called '" .. tostring(name) .. "'" end
    local v = clamp_to(info, value)
    if settings.values[name] ~= v then
        settings.values[name] = v
        save()
    end
    return v
end

function settings.reset()
    for name, info in settings.info do settings.values[name] = info.def end
    save()
end

function settings.set_controller(enabled, map)
    if enabled ~= nil then settings.controller.enabled = enabled and true or false end
    if map then
        local fixed = {}
        for i = 1, 4 do
            local a = math.round(tonumber(map[i]) or i)
            if a == 0 or math.abs(a) > 6 then a = i end
            fixed[i] = a
        end
        settings.controller.map = fixed
    end
    save()
end

function settings.load()
    local ok, stored = pcall(reskate.storage.get, "settings")
    if ok and type(stored) == "table" then
        for name, info in settings.info do
            if stored[name] ~= nil then settings.values[name] = clamp_to(info, stored[name]) end
        end
    end
    local ok2, controller = pcall(reskate.storage.get, "controller")
    if ok2 and type(controller) == "table" then
        saving = false
        settings.set_controller(controller.enabled ~= false, controller.map)
        saving = true
    end
end

-- Without storage (the tests): nothing is kept.
function settings.keep(on)
    saving = on
end

-- Presets: whole drones in one choice, handling, rates, size, motor sound and top speed.
settings.presets = {
    {name = "Tinywhoop", description = "A 65 mm ducted whoop: small, slow and forgiving, made for indoors and tight lines.",
     values = {hover = 0.45, drag = 0.60, radius = 0.06, uptilt = 15, rollcenter = 70, rollmax = 600, rollexpo = 0.30,
               pitchcenter = 70, pitchmax = 600, pitchexpo = 0.30, yawcenter = 100, yawmax = 500, yawexpo = 0.30,
               motorpitch = 2.0, topspeed = 3.5}},
    {name = "Toothpick", description = "A light 3-inch: quick and nimble, faster than a whoop without the punch of a 5-inch.",
     values = {hover = 0.30, drag = 0.30, radius = 0.10, uptilt = 25, rollcenter = 80, rollmax = 700, rollexpo = 0.20,
               pitchcenter = 80, pitchmax = 700, pitchexpo = 0.20, yawcenter = 130, yawmax = 650, yawexpo = 0.30,
               motorpitch = 1.5, topspeed = 6.0}},
    {name = "5 inch", description = "A 5-inch freestyle quad: lots of power and speed, for big lines across the map.",
     values = {hover = 0.22, drag = 0.12, radius = 0.25, uptilt = 30, rollcenter = 80, rollmax = 720, rollexpo = 0.15,
               pitchcenter = 80, pitchmax = 720, pitchexpo = 0.15, yawcenter = 130, yawmax = 780, yawexpo = 0.30,
               motorpitch = 0.85, topspeed = 10.0}},
}

function settings.apply_preset(index)
    local preset = settings.presets[index]
    if not preset then return false end
    saving = false
    for name, value in preset.values do settings.set(name, value) end
    saving = true
    save()
    return true
end

-- The preset the settings match now, or nil (custom).
function settings.matching_preset()
    for index, preset in settings.presets do
        local same = true
        for name, value in preset.values do
            local tolerance = name == "topspeed" and 0.05 or 0.005 * math.max(1, math.abs(value))
            if math.abs(settings.values[name] - value) >= tolerance then
                same = false
                break
            end
        end
        if same then return index end
    end
    return nil
end

-- The flight model's settings table (flight.lua) from the values now. `armed` is the pilot's switch.
function settings.flight(armed)
    local v = settings.values
    return {
        gravity = v.gravity, lin_drag = v.drag, hover = v.hover,
        roll = {center = v.rollcenter, max = v.rollmax, expo = v.rollexpo},
        pitch = {center = v.pitchcenter, max = v.pitchmax, expo = v.pitchexpo},
        yaw = {center = v.yawcenter, max = v.yawmax, expo = v.yawexpo},
        uptilt = v.uptilt, floor = v.floor, collide = v.collide >= 0.5, radius = v.radius, range = v.range,
        armed = armed, disarm_freeze = v.disarmfreeze >= 0.5,
        angle_mode = v.mode >= 0.5, max_angle = v.maxangle, angle_response = 8,
        alt_hold = v.althold >= 0.5, climb_rate = v.climbrate,
        crash = v.crash >= 0.5, crash_speed = v.crashspeed, propwash = v.propwash,
        yaw_look_scale = 0.0025, top_speed = v.topspeed,
    }
end

return settings
