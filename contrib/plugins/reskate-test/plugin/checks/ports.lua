local h = require("harness")
local t = h.module("ports")

-- What the drone, Board Break and Road Rash need to be mods of their own: flight input and capture,
-- a rolled camera, sounds of a package's own and a motor, the skater's physics news, items over the
-- outfit, and the board's bones. ptest all reads; the rest is by hand: ptest fly, pad, sound,
-- physics, wipeout, outfit, board.

t.check("flight input only with the camera, pads and the board's motion read", function()
    local f = reskate.input.flight()
    assert(f == nil or type(f.forward) == "number", "flight input is a table, or nil without the plugin's camera")
    local pad = reskate.input.gamepad()
    assert(pad == nil or (type(pad.left_x) == "number" and type(pad.buttons.a) == "boolean"))
    local motion = reskate.board.motion()
    assert(motion == nil or typeof(motion.velocity) == "vector")
end)
t.check("sounds come from the package, as waves", function()
    h.refused(reskate.audio.play, "icons/ptest.png")
    h.refused(reskate.audio.play, "sounds/beep.wav", {volume = 5})
end)
t.check("the outfit's slots read", function()
    local slots = reskate.outfit.slots()
    assert(type(slots) == "table" and (#slots == 0 or type(slots[1].slot) == "string"))
end)
t.check("the board's bones read, and bones 0 and 1 are not the plugin's", function()
    local bones = reskate.board.bones()
    assert(bones == nil or (bones[0] and bones[15] and typeof(bones[2].position) == "vector"))
    h.refused(reskate.board.set, 1, {position = vector.create(0, 0, 0)})
    h.refused(reskate.board.hide, 16)
end)

local function said(name, ok, why)
    reskate.console.print("ptest " .. name .. ": " .. (ok and "done" or ("refused: " .. tostring(why))))
end
-- A free camera for 15 s: WASD, Q/E, Shift and the mouse (right button) fly it; the controller is
-- the plugin's meanwhile (input.capture), and the view rolls with A and D.
local flying = nil
reskate.on("tick", function(dt)
    if not flying then return end
    local f = flying
    if reskate.time.now() > f.until_ms then
        flying = nil
        reskate.camera.release()
        reskate.input.capture(false)
        return reskate.console.print("ptest fly: done")
    end
    reskate.input.capture(true)
    local input = reskate.input.flight()
    local seconds = (dt or 16) / 1000
    if input then
        f.yaw -= input.look_x * 0.003
        f.pitch = math.clamp(f.pitch - input.look_y * 0.003, -1.4, 1.4)
        f.roll += ((input.right * 0.5) - f.roll) * math.min(1, seconds * 4)
        local forward = vector.create(math.sin(f.yaw) * math.cos(f.pitch), math.sin(f.pitch), math.cos(f.yaw) * math.cos(f.pitch))
        local right = vector.create(-math.cos(f.yaw), 0, math.sin(f.yaw)) -- facing +Z, the view's right is -X
        local speed = input.boost and 20 or 6
        f.at += (forward * input.forward + right * input.right + vector.create(0, 1, 0) * input.up) * speed * seconds
        f.forward = forward
    end
    local up = vector.create(0, 1, 0) * math.cos(f.roll) + vector.create(-math.cos(f.yaw), 0, math.sin(f.yaw)) * math.sin(f.roll)
    reskate.camera.set(f.at, f.forward, up, 75)
end)
reskate.console.command("ptest fly", "Flies a camera for 15 s (WASD, Q/E, mouse with the right button)", function()
    local s = reskate.skater.get()
    if not s then return reskate.console.print("ptest fly: no skater") end
    flying = {at = s.position + vector.create(0, 2, 0), yaw = s.heading, pitch = 0, roll = 0,
              forward = vector.create(math.sin(s.heading), 0, math.cos(s.heading)), until_ms = reskate.time.now() + 15000}
    reskate.console.print("ptest fly: flying for 15 s")
end)
reskate.console.command("ptest pad", "Says the gamepad's sticks and the radio's axes for 5 s", function()
    local id
    local until_ms = reskate.time.now() + 5000
    id = reskate.time.every(500, function()
        local pad, stick = reskate.input.gamepad(), reskate.input.joystick()
        reskate.console.print(string.format("ptest pad: pad %s, radio %s",
            pad and string.format("L %.2f %.2f R %.2f %.2f A %s", pad.left_x, pad.left_y, pad.right_x, pad.right_y, tostring(pad.buttons.a)) or "none",
            stick and string.format("%s %.2f %.2f %.2f %.2f", stick.name, stick.axes[1], stick.axes[2], stick.axes[3], stick.axes[4]) or "none"))
        if reskate.time.now() > until_ms then reskate.time.cancel(id) end
    end)
end)
reskate.console.command("ptest sound", "A beep at the skater, then a motor 5 m ahead revving for 3 s", function()
    local beep, why = reskate.audio.play("sounds/beep.wav", {volume = 1})
    said("sound beep", beep, why)
    local s = reskate.skater.get()
    if not s then return end
    local ahead = s.position + vector.create(math.sin(s.heading), 1, math.cos(s.heading)) * 5
    local motor, why2 = reskate.audio.play("motor", {volume = 1, throttle = 0.2, position = ahead, loop = true})
    said("sound motor", motor, why2)
    if not motor then return end
    for i = 1, 6 do
        reskate.time.after(i * 500, function() reskate.audio.set(motor, {throttle = (i % 2 == 0) and 0.2 or 0.9}) end)
    end
    reskate.time.after(3200, function() reskate.audio.stop(motor) end)
end)
local physics_until = 0
reskate.on("board_landed", function(e)
    if reskate.time.now() < physics_until then
        reskate.console.print(string.format("ptest physics: landed at %.1f m/s down onto %s", e.down_speed, e.onto))
    end
end)
reskate.on("body_hit", function(e)
    if reskate.time.now() < physics_until then reskate.console.print(string.format("ptest physics: %s hit at %.1f m/s", e.bone, e.impact)) end
end)
reskate.on("bail_end", function(e)
    if reskate.time.now() < physics_until then
        reskate.console.print(string.format("ptest physics: a fall of %.1f s, left %.0f, right %.0f", e.seconds, e.left, e.right))
    end
end)
reskate.on("bail", function(e)
    if reskate.time.now() < physics_until then
        reskate.console.print("ptest physics: bail, force " .. tostring(e.force) .. ", cause " .. tostring(e.cause))
    end
end)
reskate.console.command("ptest physics", "For 30 s, says the board's landings, the body's hits and falls", function()
    physics_until = reskate.time.now() + 30000
    reskate.console.print("ptest physics: jump, grind and bail")
end)
reskate.console.command("ptest wipeout", "Throws the skater (gently)", function() said("wipeout", reskate.skater.wipeout(1.5)) end)
reskate.console.command("ptest outfit", "Lists the outfit's slots; ptest outfit <slot> <item> wears one; ptest outfit off", function(args)
    if args[1] == "off" then
        reskate.outfit.clear()
        return reskate.console.print("ptest outfit: off (" .. reskate.outfit.status() .. ")")
    end
    if args[1] and args[2] then
        local item = reskate.outfit.find(args[2]) or args[2]
        return said("outfit " .. args[1] .. " " .. item, reskate.outfit.set(args[1], item, {covers = true}))
    end
    for _, slot in reskate.outfit.slots() do
        reskate.console.print("ptest outfit: " .. slot.slot .. " = " .. (slot.item ~= "" and slot.item or "-"))
    end
end)
reskate.console.command("ptest board", "Hides the deck for 3 s, then throws the front truck off for 5 s", function()
    said("board hide deck", reskate.board.hide(3))
    reskate.time.after(3000, function()
        reskate.board.clear()
        local s = reskate.skater.get()
        local ground = s and s.position.y or 0
        said("board toss truck", reskate.board.toss({8}, {velocity = vector.create(1, 3, 1), spin = vector.create(4, 2, 0), ground = ground}))
        reskate.time.after(5000, function()
            reskate.board.clear()
            reskate.console.print("ptest board: whole again")
        end)
    end)
end)
