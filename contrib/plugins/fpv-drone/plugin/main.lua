-- FPV Drone: fly a first-person drone over the map, or let it follow you and film while you skate.
-- The drone ReSkate had in its core (Extension/Skater/drone_*.h), as a plugin: flight.lua is the
-- flight model, follow.lua the autopilot, radio.lua the controllers, osd.lua the goggle display,
-- beacon.lua other players' drones, page.lua its page in the menu and settings.lua the settings.
-- Console: fpv (fpv help lists what it does).
local settings = require("settings")
local flight = require("flight")
local radio = require("radio")
local follow = require("follow")
local osd = require("osd")
local beacon = require("beacon")
local page = require("page")

local V = vector.create
local len = vector.magnitude

-- What the console, the page and the tick share.
local drone = {
    mode = "off",       -- "fly", "follow" or "off"
    state = nil,        -- the flight state (flight.lua)
    pilot = nil,        -- follow mode's autopilot
    armed = true,       -- the pilot's arm switch
    reset = false,      -- asked to go back to takeoff
    problem = nil,      -- why it could not start, for the page
    sticks = {},        -- what the sticks did last, for the OSD
    calibration = radio.calibration(),
    calibration_seen = -1e9,
    switches = {},      -- the radio's switch memory
    pad = {},           -- the gamepad's button memory
    motor = nil,        -- the motor sound's id
    motor_retry = 0,
    hid_hud = false,
    camera_problem = nil,
}

-- ---- the world ----------------------------------------------------------------------------------
-- reskate.world.raycast with this plugin's own cap a tick (the host stops at 64).
local rays = 0
local function cast(from, to)
    rays += 1
    if rays > 56 then return nil end
    local ok, hit = pcall(reskate.world.raycast, from, to)
    if ok then return hit end
    return nil
end

-- ---- goggles: eyewear on the pilot's skater while the drone flies --------------------------------
local eyewear = {
    "Own_EyewearGlasses_Gen_SunglassesVisorLarge_00001", "Own_EyewearGlasses_Gen_SunglassesVisorLarge_00002",
    "Own_EyewearGlasses_Gen_SunglassesVisorLarge_00003", "Own_EyewearGlasses_Gen_SunglassesVisorLarge_00004",
    "Own_EyewearGlasses_Gen_ShieldAviator_00001", "Own_EyewearGlasses_Gen_WrapAround_00001",
    "Own_EyewearGlasses_Gen_SunglassesWraparoundSlim_00001", "Own_EyewearGlasses_Dime_SpeedShades_00001",
}
local goggles = {worn = nil, last_flying = -1e9, retry = 0, said = nil}
local function goggles_tick(now)
    if drone.mode ~= "off" then goggles.last_flying = now end
    if now < goggles.retry then return end
    -- A moment's grace, so a reset or a pause does not take them off and on again.
    local choice = math.round(settings.get("goggles"))
    local want = now - goggles.last_flying < 1500 and choice >= 1 and eyewear[choice] or nil
    if want == goggles.worn then return end
    if want then
        local ok, done, why = pcall(reskate.outfit.set, "eyewear", want)
        if ok and done then
            goggles.worn = want
        else
            goggles.retry = now + 500
            local said = tostring(ok and why or done)
            if said ~= goggles.said then
                goggles.said = said
                reskate.log("goggles: " .. said, "warn")
            end
        end
    else
        pcall(reskate.outfit.clear, "eyewear")
        goggles.worn = nil
    end
end

-- ---- the motor -----------------------------------------------------------------------------------
local function motor_tick(now)
    local s = drone.state
    local volume = settings.get("volume")
    if drone.mode == "off" or not s or volume <= 0.001 then
        if drone.motor then
            pcall(reskate.audio.stop, drone.motor)
            drone.motor = nil
        end
        return
    end
    -- Heard while armed, as the C++ drone was.
    local options = {position = s.position, throttle = math.clamp(s.throttle, 0, 1), speed = math.clamp(s.speed, 0, 200),
                     volume = s.armed_now ~= false and volume or 0, pitch = math.clamp(settings.get("motorpitch"), 0.25, 4)}
    if drone.motor then
        local ok, still = pcall(reskate.audio.set, drone.motor, options)
        if not (ok and still) then drone.motor = nil end
    elseif now >= drone.motor_retry then
        options.loop = true
        local ok, id = pcall(reskate.audio.play, "motor", options)
        if ok and id then drone.motor = id else drone.motor_retry = now + 1000 end
    end
end

-- ---- flying --------------------------------------------------------------------------------------
local function hide_hud(on)
    if on == drone.hid_hud then return end
    pcall(reskate.hud.hide, on)
    drone.hid_hud = on
end

function drone.stop()
    if drone.mode == "off" then return end
    drone.mode = "off"
    pcall(reskate.input.capture, false)
    pcall(reskate.camera.release)
    hide_hud(false)
    drone.problem = nil
end

-- Takes off from where the game's camera is: "fly" (the pilot flies it) or "follow" (it follows
-- the skater). False and why when it cannot.
function drone.start(mode)
    local view = reskate.camera.get()
    if not view or not reskate.level.current() then
        drone.problem = "Load into a level to fly."
        return false, drone.problem
    end
    if mode == "follow" and not reskate.skater.get() then
        drone.problem = "Follow me needs your skater."
        return false, drone.problem
    end
    if drone.mode ~= "off" then drone.stop() end
    drone.problem = nil
    drone.armed = true
    drone.reset = false
    local cfg = settings.flight(true)
    drone.state = flight.new_state(view.position, view.forward, true, cfg)
    drone.pilot = mode == "follow" and follow.pilot() or nil
    drone.sticks = {}
    drone.mode = mode
    hide_hud(settings.on("hideui"))
    local ok, why = reskate.camera.set(view.position, view.forward, V(0, 1, 0), 0)
    if not ok then
        drone.stop()
        drone.problem = "The camera is not free: " .. tostring(why)
        return false, drone.problem
    end
    return true
end

local function calibrating(now)
    return drone.calibration:active() and now - drone.calibration_seen < 500
end

-- The pilot's command this tick: from the controller when it has one, else the keyboard and
-- mouse. Nil while there is nothing to fly with (the menu is open with the keyboard), and the
-- drone holds still meanwhile.
local function pilot_command(seconds, now, cfg)
    local input = reskate.input.flight() -- nil while the menu has the input, or the camera is not ours
    local menu_closed = input ~= nil
    if settings.controller.enabled then
        if settings.on("gamepad") then
            local pad = reskate.input.gamepad()
            if pad then
                -- While the menu is open the pad is the menu's: the drone hovers and the buttons do nothing.
                local toggle_arm, reset = radio.pad_buttons(drone.pad, pad.buttons, menu_closed)
                if toggle_arm then drone.armed = not drone.armed end
                if reset then drone.reset = true end
                local used = menu_closed and pad or {left_x = 0, left_y = 0, right_x = 0, right_y = 0}
                local v = settings.values
                return radio.gamepad_sticks(used, v.deadzone, v.padrate, v.padexpo, v.hover, v.padinvert >= 0.5, v.mode >= 0.5)
            end
        else
            local stick = reskate.input.joystick()
            if stick then
                if calibrating(now) then return "hold" end -- the setup is moving the sticks and switches
                local v = settings.values
                local bits = radio.button_bits(stick.buttons)
                local armed, reset = radio.switches(drone.switches, stick.axes, bits, v.armaxis, v.armbutton, v.resetaxis, v.resetbutton)
                if armed ~= nil then drone.armed = armed end
                if reset then drone.reset = true end
                return radio.map_axes(stick.axes, settings.controller.map, v.deadzone, v.throttlecentre >= 0.5, v.hover)
            end
        end
    end
    if not input then return nil end
    local cmd, shown = flight.keyboard_command(input, cfg)
    return cmd, shown
end

local function fly_tick(seconds, now)
    local s = drone.state
    local cfg
    local cmd
    if drone.mode == "fly" then
        pcall(reskate.input.capture, true)
        cfg = settings.flight(drone.armed)
        local got, shown = pilot_command(seconds, now, cfg)
        if got == "hold" then got = nil
        elseif got and got.valid ~= nil then
            -- Sticks from a controller.
            cmd, shown = flight.radio_command(got, seconds, cfg)
        else
            cmd = got
        end
        cfg.armed = drone.armed
        if shown then drone.sticks = shown end
    else
        local skater = reskate.skater.get()
        local p = drone.pilot
        local target = skater and skater.position or p.last_target
        local facing = skater and V(math.sin(skater.heading), 0, math.cos(skater.heading)) or p.heading
        local t = follow.tuning(settings.get("followdistance"), settings.get("followaggression"))
        cfg = follow.flight_settings(settings.flight(true), t)
        if skater and len(target - s.position) > 60 then
            -- Left far behind (a respawn, a teleport): it is back where it should be.
            local spot = follow.spot(target, V(0, 0, 0), p.heading, t, 0)
            flight.start(s, spot, target - spot, true, cfg)
            drone.pilot = follow.pilot()
            p = drone.pilot
        end
        cmd = follow.fly(p, s, target, facing, seconds, cfg, t, cast)
        drone.sticks = {roll = cmd.roll, pitch = -cmd.pitch, yaw = math.clamp(-cmd.yaw_rad / math.max(seconds, 1e-3) / t.max_yaw_rate, -1, 1),
                        throttle = cmd.climb}
    end
    if drone.reset then
        flight.reset(s, cfg.armed, cfg)
        drone.reset = false
    end
    if cmd then
        flight.step(s, cmd, seconds, cfg, cast)
        if s.crashed_now then drone.armed = false end
    end
    local camera = s.camera
    local ok, done, why = pcall(reskate.camera.set, s.position, -camera.b, camera.u, 0)
    if ok and done then drone.camera_problem = nil else drone.camera_problem = tostring(ok and why or done) end
end

-- ---- the tick ------------------------------------------------------------------------------------
local perf = {total = 0, ticks = 0, worst = 0, rays = 0}
local clock = os and os.clock or function() return reskate.time.now() / 1000 end

reskate.on("tick", function(dt_ms)
    local started = clock()
    rays = 0
    local now = reskate.time.now()
    local seconds = math.clamp((dt_ms or 16) / 1000, 0, 0.05)
    if drone.mode ~= "off" then
        if not reskate.level.current() then drone.stop()
        else fly_tick(seconds, now) end
    end
    goggles_tick(now)
    motor_tick(now)
    -- Other players: where this drone is, about 12 times a second, and theirs.
    local share = drone.mode ~= "off" and settings.on("beacon")
    local message = beacon.outgoing(now, share and drone.state or nil, share)
    if message then pcall(reskate.net.send, "all", message) end
    beacon.tick(now, settings.on("showbeacons"), settings.get("volume"))
    local spent = (clock() - started) * 1000
    perf.total += spent
    perf.ticks += 1
    perf.rays += math.min(rays, 56)
    perf.worst = math.max(perf.worst, spent)
end)

reskate.on("message", function(from, payload)
    if from and not from.me then beacon.receive(from, payload, reskate.time.now()) end
end)
reskate.on("player_left", function(player)
    beacon.forget(player.id)
end)
reskate.on("level_unloading", function()
    drone.stop()
    beacon.clear()
end)

reskate.on("draw", function(d)
    local started = clock()
    local size = d:size()
    local w, h = size.x, size.y
    if w <= 0 or h <= 0 then return end
    local s = drone.state
    local now = reskate.time.now()
    local flying = drone.mode ~= "off" and s ~= nil
    -- The analogue look under everything, so the markers and the display stay crisp.
    if flying then osd.analog(d, w, h, s, settings.values, now / 1000) end
    if settings.on("showbeacons") and beacon.count() > 0 then
        local view = reskate.camera.get()
        if flying then view = {position = s.position, forward = -s.camera.b, fov = view and view.fov or 60} end
        beacon.draw(d, w, h, view, now)
    end
    if flying then
        s.sticks = drone.sticks
        osd.draw(d, osd.layout(s, settings.values), w, h)
    end
    perf.total += (clock() - started) * 1000
end)

-- ---- the console ---------------------------------------------------------------------------------
local function say(text)
    reskate.console.print(text)
end
local function show_setting(name)
    local info = settings.info[name]
    say(string.format("%-16s %-8g %s (default %g, range %g-%g)", name, settings.get(name), info.help, info.def, info.lo, info.hi))
end

local commands = {}
commands.help = function()
    say("fpv fly | stop | follow: start flying, land, or let the drone follow you while you skate")
    say("fpv arm | disarm | reset: motors on, motors off, back to where it took off")
    say("fpv tune [setting [value]] | tune reset: list, show or change the settings; reset puts them all back")
    say("fpv preset <1-3>: Tinywhoop, Toothpick or 5 inch")
    say("fpv controller on|off | axes <roll> <pitch> <throttle> <yaw> | check: the controller")
    say("fpv status | perf | test")
    say("Its page in the menu's PLUGINS section has every setting.")
end
commands.fly = function()
    local ok, why = drone.start("fly")
    say(ok and "fpv: flying. W/S tilt forward/back, A/D roll, E/Q throttle, mouse turns, Shift boosts. fpv stop lands." or ("fpv: " .. why))
end
commands.follow = function()
    local ok, why = drone.start("follow")
    say(ok and "fpv: the drone follows you. Skate as normal; fpv stop lands it." or ("fpv: " .. why))
end
commands.stop = function()
    drone.stop()
    say("fpv: landed.")
end
commands.arm = function()
    drone.armed = true
    say("fpv: armed.")
end
commands.disarm = function()
    drone.armed = false
    say("fpv: disarmed. It falls (or hangs, with fpv tune disarmfreeze 1).")
end
commands.reset = function()
    drone.reset = true
    say("fpv: back to takeoff.")
end
commands.tune = function(args)
    local name, value = args[2], args[3]
    if not name then
        for _, entry in settings.list do show_setting(entry[1]) end
        return
    end
    if name == "reset" then
        settings.reset()
        return say("fpv: every setting is back to its default.")
    end
    if not settings.info[name] then return say("fpv: there is no setting called '" .. name .. "'. fpv tune lists them.") end
    if not value then return show_setting(name) end
    local wanted = tonumber(value)
    if not wanted then return say("fpv: " .. value .. " is not a number.") end
    local got = settings.set(name, wanted)
    say(got == wanted and string.format("%s = %g", name, got) or string.format("%s = %g (the closest allowed value)", name, got))
end
commands.preset = function(args)
    local n = tonumber(args[2] or "")
    if not n or not settings.apply_preset(n) then return say("fpv preset 1 (Tinywhoop), 2 (Toothpick) or 3 (5 inch)") end
    say("fpv: " .. settings.presets[n].name .. ".")
end
commands.controller = function(args)
    if args[2] == "on" or args[2] == "off" then settings.set_controller(args[2] == "on") end
    say("fpv: controller " .. (settings.controller.enabled and "on" or "off") .. ", " .. (settings.on("gamepad") and "gamepad" or "RC radio"))
end
commands.axes = function(args)
    if #args >= 5 then settings.set_controller(nil, {tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), tonumber(args[5])}) end
    local m = settings.controller.map
    say(string.format("fpv: roll %d, pitch %d, throttle %d, yaw %d", m[1], m[2], m[3], m[4]))
end
commands.check = function()
    local stick, pad = reskate.input.joystick(), reskate.input.gamepad()
    if stick then
        say(string.format("fpv: %s axes %+.2f %+.2f %+.2f %+.2f %+.2f %+.2f", stick.name, stick.axes[1], stick.axes[2], stick.axes[3],
            stick.axes[4], stick.axes[5], stick.axes[6]))
        local v = settings.values
        local s = radio.map_axes(stick.axes, settings.controller.map, v.deadzone, v.throttlecentre >= 0.5, v.hover)
        say(string.format("fpv: read as roll %+.2f pitch %+.2f throttle %.2f yaw %+.2f", s.roll, s.pitch, s.throttle, s.yaw))
    else
        say("fpv: no RC radio")
    end
    say(pad and string.format("fpv: gamepad L %+.2f %+.2f R %+.2f %+.2f", pad.left_x, pad.left_y, pad.right_x, pad.right_y) or "fpv: no gamepad")
end
commands.status = function()
    local s = drone.state
    say(string.format("fpv: %s, %s, %d other drones", drone.mode, drone.armed and "armed" or "disarmed", beacon.count()))
    if drone.mode ~= "off" and s then
        say(string.format("fpv: %.0f%% throttle, %.0f km/h, %.1f m up, %.0f s%s", s.throttle * 100, s.speed * 3.6, s.altitude,
            s.flight_time, drone.camera_problem and (", camera: " .. tostring(drone.camera_problem)) or ""))
    end
    if goggles.said then say("fpv: goggles: " .. goggles.said) end
end
-- Its own time a tick (tick and draw), against the 2 ms a plugin has.
commands.perf = function()
    if perf.ticks == 0 then return say("fpv perf: no ticks yet") end
    say(string.format("fpv perf: %.3f ms a tick on average over %d ticks (its budget is 2 ms), %.3f ms the slowest tick handler, %.1f raycasts a tick",
        perf.total / perf.ticks, perf.ticks, perf.worst, perf.rays / perf.ticks))
    perf.total, perf.ticks, perf.worst, perf.rays = 0, 0, 0, 0
end
commands.test = function()
    require("tests").run(say)
end

reskate.console.command("fpv", "The FPV drone: fpv fly, fpv follow, fpv stop, fpv tune (fpv help for the rest)", function(args)
    local run = commands[args[1] or "help"]
    if not run then return say("fpv: there is no " .. tostring(args[1]) .. " (fpv help lists them)") end
    run(args)
end)

reskate.on("unload", function()
    drone.stop()
    beacon.clear()
    pcall(reskate.outfit.clear, "eyewear")
    if drone.motor then pcall(reskate.audio.stop, drone.motor) end
end)

settings.load()
page.install(drone)
reskate.log("FPV Drone loaded: fpv fly, or its page in the menu's PLUGINS section")
