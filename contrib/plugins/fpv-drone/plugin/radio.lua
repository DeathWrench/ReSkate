-- Controllers for the drone, as Extension/Skater/drone_radio.h and drone_flight.h had them: an RC
-- radio (reskate.input.joystick(): six axes, 32 buttons) and a gamepad (reskate.input.gamepad()),
-- both read into the same sticks; the radio's arm and reset switches; and the guided setup that
-- finds which axis each stick is on. Plain maths, so the tests drive it.
local flight = require("flight")
local radio = {}

-- Sticks as the flight model wants them: roll (+ right), pitch (+ stick forward), yaw (+ right),
-- throttle (0-1), centred (the throttle springs back) and climb (that stick, -1 to 1).
local function sticks()
    return {valid = false, roll = 0, pitch = 0, yaw = 0, throttle = 0, centred = false, climb = 0}
end
radio.sticks = sticks

function radio.deadzone(v, dz)
    local a = math.abs(v)
    if not (a > dz) then return 0 end
    local out = math.min(1, (a - dz) / (1 - dz))
    return v < 0 and -out or out
end
-- Axis n (1-6) of the six, minus reversed; 0 for none.
function radio.pick_axis(axes, signed)
    local index = math.abs(signed)
    if index < 1 or index > 6 then return 0 end
    local v = axes[index] or 0
    return signed < 0 and -v or v
end

-- An RC radio's six axes, with the saved axes (roll, pitch, throttle, yaw), dead zone and throttle kind.
function radio.map_axes(axes, map, dz, centred_throttle, hover)
    local out = sticks()
    out.valid = true
    out.roll = radio.deadzone(radio.pick_axis(axes, map[1]), dz)
    out.pitch = radio.deadzone(radio.pick_axis(axes, map[2]), dz)
    out.centred = centred_throttle
    if centred_throttle then
        out.climb = radio.deadzone(radio.pick_axis(axes, map[3]), dz)
        out.throttle = flight.spring_throttle(out.climb, hover)
    else
        out.throttle = math.clamp((radio.pick_axis(axes, map[3]) + 1) * 0.5, 0, 1)
    end
    out.yaw = radio.deadzone(radio.pick_axis(axes, map[4]), dz)
    return out
end

-- A gamepad's sticks, Mode 2: left stick throttle (springing back) and yaw, right stick pitch and
-- roll. Each stick has a round dead zone; then the middle is softened (`expo`) and the whole travel
-- scaled down (`scale`), since a pad's short sticks at a radio's rates make every touch a flip.
-- `invert`: up on the right stick tips the nose up. In angle mode `scale` leaves pitch and roll
-- alone: full stick is the full lean.
function radio.gamepad_sticks(pad, dz, scale, expo, hover, invert, angle)
    local out = sticks()
    if not pad then return out end
    out.valid = true
    local zone = math.clamp(flight.finite(dz) and dz or 0, 0.08, 0.5)
    local function stick(x, y)
        x = flight.finite(x) and math.clamp(x, -1, 1) or 0
        y = flight.finite(y) and math.clamp(y, -1, 1) or 0
        local length = math.sqrt(x * x + y * y)
        if not (length > zone) then return 0, 0 end
        local k = math.min(1, (length - zone) / (1 - zone)) / length
        return x * k, y * k
    end
    local e = math.clamp(flight.finite(expo) and expo or 0, 0, 1)
    local s = math.clamp(flight.finite(scale) and scale or 1, 0.05, 1)
    local function shape(v, most)
        local a = math.abs(v)
        local out_v = (e * a * a * a + (1 - e) * a) * most
        return v < 0 and -out_v or out_v
    end
    local tilt = angle and 1 or s
    local lx, ly = stick(pad.left_x, pad.left_y)
    local rx, ry = stick(pad.right_x, pad.right_y)
    out.yaw = shape(lx, s)
    out.roll = shape(rx, tilt)
    out.pitch = shape(invert and -ry or ry, tilt) -- + = forward = nose down
    out.centred = true
    out.climb = ly
    out.throttle = flight.spring_throttle(ly, hover)
    return out
end

-- The 32 buttons as a number, bit n-1 for button n.
function radio.button_bits(list)
    local bits = 0
    if type(list) ~= "table" then return 0 end
    for n = 1, 32 do
        if list[n] then bits = bit32.bor(bits, bit32.lshift(1, n - 1)) end
    end
    return bits
end
local function pressed(bits, n)
    return n >= 1 and n <= 32 and bit32.btest(bits, bit32.lshift(1, n - 1))
end
radio.pressed = pressed

-- Radio switches: an arm switch and a reset switch, each an axis (-6 to 6) or a button (1-32). An
-- axis has to go well past the middle to count (above +0.5 on, below -0.5 off for arming; +0.5 then
-- back under +0.2 for reset), so a stick that drifts a little never sets them off. Returns the
-- armed switch (true, false, or nil when no switch says) and whether to reset.
function radio.switches(memory, axes, bits, arm_axis, arm_button, reset_axis, reset_button)
    local armed, reset = nil, false
    arm_axis, reset_axis = math.round(arm_axis), math.round(reset_axis)
    arm_button, reset_button = math.round(arm_button), math.round(reset_button)
    if arm_axis ~= 0 and math.abs(arm_axis) <= 6 then
        local v = radio.pick_axis(axes, arm_axis)
        if v > 0.5 then armed = true elseif v < -0.5 then armed = false end
    end
    if arm_button ~= 0 then armed = pressed(bits, arm_button) end
    if reset_axis ~= 0 and math.abs(reset_axis) <= 6 then
        local v = radio.pick_axis(axes, reset_axis)
        if v > 0.5 and not memory.reset_axis_high then
            reset = true
            memory.reset_axis_high = true
        elseif v < 0.2 then
            memory.reset_axis_high = false
        end
    end
    if reset_button ~= 0 then
        local down = pressed(bits, reset_button)
        if down and not memory.reset_button_down then reset = true end
        memory.reset_button_down = down
    end
    return armed, reset
end

-- A gamepad's buttons: A (cross) arms or disarms, Menu (Options) puts the drone back, each on the
-- press. With `act` false (the menu has the pad) they are only watched, so a button still held when
-- the menu closes does nothing. Returns toggle_arm, reset.
function radio.pad_buttons(memory, buttons, act)
    local a, start = buttons and buttons.a or false, buttons and buttons.start or false
    -- Nothing counts as pressed until it has been seen up.
    local a_pressed = a and memory.a_up == true
    local start_pressed = start and memory.start_up == true
    memory.a_up, memory.start_up = not a, not start
    if not act then return false, false end
    return a_pressed, start_pressed
end

-- Guided controller setup: works out which axis each stick is on, and which way round, by asking
-- the pilot to move one stick at a time; then, optionally, which switch arms and which resets.
-- It starts from the sticks at rest (centred, throttle down). For each stick it picks the unused
-- axis that moved furthest from rest, once held well over for a moment, and takes the way it moved
-- as plus (throttle up, yaw right, pitch forward, roll right). The stick must come back to rest
-- before the next one. Switches are any other axis that swings across, or a button that was not
-- already down at rest.
local Calibration = {}
Calibration.__index = Calibration
radio.move_threshold, radio.switch_threshold, radio.return_threshold, radio.hold_seconds = 0.6, 0.8, 0.25, 0.3
radio.steps = {"rest", "throttle", "yaw", "pitch", "roll", "arm", "reset", "done"}

function radio.calibration()
    local c = setmetatable({}, Calibration)
    c:cancel()
    return c
end
function Calibration:cancel()
    self.step = "idle"
    self.rest = {0, 0, 0, 0, 0, 0}
    self.rest_buttons = 0
    self.map = {1, 2, 3, 4}
    self.used = {false, false, false, false, false, false}
    self.used_buttons = 0
    self.arm_axis, self.arm_button, self.reset_axis, self.reset_button = 0, 0, 0, 0
    self.candidate, self.candidate_button, self.held = -1, 0, 0
    self.returning = false
    self.throttle_centred = false
    self.found_axis, self.found_button = -1, 0
end
function Calibration:start()
    self:cancel()
    self.step = "rest"
end
function Calibration:active()
    return self.step ~= "idle" and self.step ~= "done"
end
-- "Ready" on the rest step: the sticks as they are now are where they rest.
function Calibration:capture_rest(axes, bits)
    if self.step ~= "rest" then return end
    self.rest = table.clone(axes)
    self.rest_buttons = bits
    self.step = "throttle"
end
-- "Skip" on a switch step: no switch for it.
function Calibration:skip()
    if self.step == "arm" then
        self.step = "reset"
        self:clear_hold()
    elseif self.step == "reset" then
        self.step = "done"
        self:clear_hold()
    end
end
function Calibration:clear_hold()
    self.candidate, self.candidate_button, self.held = -1, 0, 0
end
local slots = {roll = 1, pitch = 2, throttle = 3, yaw = 4}
function Calibration:furthest(axes, threshold)
    local best, distance = -1, threshold
    for i = 1, 6 do
        if not self.used[i] then
            local d = math.abs((axes[i] or 0) - self.rest[i])
            if flight.finite(d) and d > distance then
                distance = d
                best = i
            end
        end
    end
    return best
end
function Calibration:hold(axis, button, seconds)
    if axis ~= self.candidate or button ~= self.candidate_button then
        self.candidate, self.candidate_button, self.held = axis, button, 0
        return false
    end
    self.held += seconds
    return (axis >= 1 or button > 0) and self.held >= radio.hold_seconds
end
function Calibration:advance()
    local next_step = {throttle = "yaw", yaw = "pitch", pitch = "roll", roll = "arm", arm = "reset", reset = "done"}
    self.step = next_step[self.step] or self.step
end
function Calibration:back_at_rest(axes, bits)
    if self.found_axis >= 1 then
        return math.abs((axes[self.found_axis] or 0) - self.rest[self.found_axis]) < radio.return_threshold
    end
    return self.found_button <= 0 or not pressed(bits, self.found_button)
end
-- Once a frame while the setup is shown.
function Calibration:update(axes, bits, seconds)
    if not self:active() or self.step == "rest" then return end
    if not flight.finite(seconds) or seconds < 0 then seconds = 0 end
    if self.returning then
        if self:back_at_rest(axes, bits) then
            self.returning = false
            self:advance()
        end
        return
    end
    if self.step == "arm" or self.step == "reset" then
        local axis = self:furthest(axes, radio.switch_threshold)
        local button = 0
        local fresh = bit32.band(bits, bit32.bnot(self.rest_buttons), bit32.bnot(self.used_buttons))
        for n = 1, 32 do
            if pressed(fresh, n) then
                button = n
                break
            end
        end
        if axis >= 1 then button = 0 end -- an axis is the clearer signal when both move
        if not self:hold(axis, button, seconds) then return end
        if axis >= 1 then
            local value = ((axes[axis] or 0) >= self.rest[axis] and 1 or -1) * axis -- its new side counts as on
            if self.step == "arm" then self.arm_axis = value else self.reset_axis = value end
            self.used[axis] = true
        else
            if self.step == "arm" then self.arm_button = button else self.reset_button = button end
            self.used_buttons = bit32.bor(self.used_buttons, bit32.lshift(1, button - 1))
        end
        self.found_axis, self.found_button = axis, button
        -- The arm switch can stay on; the reset switch has to be let go before finishing.
        self.returning = self.step == "reset"
        if not self.returning then self:advance() end
        self:clear_hold()
    else
        local axis = self:furthest(axes, radio.move_threshold)
        if not self:hold(axis, 0, seconds) then return end
        local sign = (axes[axis] or 0) >= self.rest[axis] and 1 or -1
        self.map[slots[self.step]] = sign * axis
        if self.step == "throttle" then self.throttle_centred = math.abs(self.rest[axis]) < 0.5 end
        self.used[axis] = true
        self.found_axis, self.found_button = axis, 0
        self.returning = true
        self:clear_hold()
    end
end

return radio
