-- SmokeyDawg58's race_route.h (HIS/Modes/race_route.h), line for line.
-- Indices (gates, checkpoints) are 0-based as in his C++; only the table access adds one.
-- Vec3 is a Luau vector. A `bool& finish` argument is returned as an extra result
-- (edit_race_route, undo_race_gate, clear_race_gates, accept_race_flag).
-- Matrices (std::array<float,16>) are 1-based lists of 16 numbers: element k is his [k-1].
local RR = {}

-- ---- helpers -------------------------------------------------------------------------------------
-- mode_rules.h's gate functions, 0-based as his.
local R = require("td/rules")
local gate_half_width, guiding_gate, arrow_marker, mandatory_gates =
    R.gate_half_width, R.guiding_gate, R.arrow_marker, R.mandatory_gates
-- From mode_rules.h: min_gate_half_width, max_gate_half_width.
local min_gate_half_width, max_gate_half_width = 1.5, 40.0


local function finite(x) return x == x and x ~= math.huge and x ~= -math.huge end
local function finite3(v) return finite(v.x) and finite(v.y) and finite(v.z) end
local function hypot(x, y) return math.sqrt(x * x + y * y) end
local function round_half_even(x)
    local f = math.floor(x)
    local d = x - f
    if d > 0.5 then return f + 1 elseif d < 0.5 then return f end
    return if f % 2 == 0 then f else f + 1
end
-- std::remainder
local function remainder(x, y) return x - y * round_half_even(x / y) end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return setmetatable(out, getmetatable(value))
end
local function list_equal(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
-- std::vector::resize
local function resize(list, n, fill)
    for i = #list, n + 1, -1 do list[i] = nil end
    for i = #list + 1, n do list[i] = fill end
end
-- A struct or class: Name.new(fields?) with his defaults, Name.copy(x).
local function class(defaults)
    local C = {}
    C.__index = C
    function C.new(fields)
        local self = defaults()
        if fields then for k, v in pairs(fields) do self[k] = v end end
        return setmetatable(self, C)
    end
    function C.copy(x) return copy(x) end
    return C
end

-- ---- race_route.h --------------------------------------------------------------------------------
-- enum class RaceObject : unsigned { start, checkpoint, finish, guiding, arrow }
RR.RaceObject = { start = 0, checkpoint = 1, finish = 2, guiding = 3, arrow = 4 }
local RaceObject = RR.RaceObject

function RR.cycle_race_object(object, previous)
    local n = object
    if previous then
        return if n <= 1 then 4 else n - 1
    end
    return if n >= 4 then 1 else n + 1
end

function RR.race_spawn_transform(at, heading)
    local yaw = heading * 3.14159265 / 180
    local co, si = math.cos(yaw), math.sin(yaw)
    return { co, 0, -si, 0, 0, 1, 0, 0, si, 0, co, 0, at.x, at.y + .3, at.z, 1 }
end

function RR.race_arrow_transform(at, heading, roll, half_width, pitch)
    pitch = pitch or 0
    local yaw, r = heading * 3.14159265 / 180, roll * 3.14159265 / 180
    local co, si, cr, sr, scale = math.cos(yaw), math.sin(yaw), math.cos(r), math.sin(r), 4 * half_width / 6
    local p = pitch * 3.14159265 / 180
    local cp, sp = math.cos(p), math.sin(p)
    -- The native chevron is an XY quad. Aim supplies yaw and tilt; the
    -- D-pad adds roll in that aimed plane. Only the preview follows the camera.
    local right, up, forward = { co, 0, -si }, { si * sp, cp, co * sp }, { si * cp, -sp, co * cp }
    local origin = { at.x, at.y, at.z }
    local pose = table.create(16, 0)
    for a = 1, 3 do
        pose[a] = (right[a] * cr + up[a] * sr) * scale
        pose[4 + a] = (-right[a] * sr + up[a] * cr) * scale
        pose[8 + a] = forward[a] * scale
        pose[12 + a] = origin[a]
    end
    pose[16] = 1
    return pose
end

function RR.race_arrow_layer_transform(at, heading, roll, width, pitch, part)
    local pose = RR.race_arrow_transform(at, heading, roll, width, pitch)
    -- These separately spawned native FX layers used exactly the same plane.
    -- Keep the translucent blue glow just above the cutout core, so depth
    -- precision at distance cannot let that core suppress its own glow.
    if part == 1 then
        local length = math.sqrt(pose[9] * pose[9] + pose[10] * pose[10] + pose[11] * pose[11])
        if length > .001 then
            for axis = 0, 2 do pose[13 + axis] += .015 * pose[9 + axis] / length end
        end
    end
    return pose
end

-- The placed starting flag owns the lineup direction, including on a saved
-- course. Only legacy routes without an authored facing infer it from a gate.
function RR.race_start_heading(route)
    if #route.yaws > 0 and finite(route.yaws[1]) then return route.yaws[1] end
    if #route.points > 0 then
        for i = 1, #route.points - 1 do
            if guiding_gate(route, i) then continue end
            local x, z = route.points[i + 1].x - route.points[1].x, route.points[i + 1].z - route.points[1].z
            if hypot(x, z) > .1 then return math.atan2(x, z) * 180 / 3.14159265 end
        end
    end
    return 0
end

function RR.align_race_start(route)
    if route.mode ~= "race" or #route.points < 2 then return end
    local heading = RR.race_start_heading(route)
    if #route.yaws == 0 then resize(route.yaws, 1, 0) end
    route.yaws[1] = heading
end

-- A centered row perpendicular to the flag, with everyone behind its plane.
function RR.race_start_position(route, index, count)
    if #route.points == 0 then return route.spawn end
    local start = route.points[1]
    local yaw = RR.race_start_heading(route) * 3.14159265 / 180
    local dx, dz = math.sin(yaw), math.cos(yaw)
    local across = (index - (count - 1) * .5) * 2.5
    return vector.create(start.x - dz * across - dx * 1.5, start.y, start.z + dx * across - dz * 1.5)
end

-- A course belongs to a map, independently of any lobby, player or match.
RR.RaceCourseMemory = class(function() return { courses = {} } end)
function RR.RaceCourseMemory:save(map, route)
    if map ~= "" and route.mode == "race" and #route.points > 0 then self.courses[map] = copy(route) end
end
function RR.RaceCourseMemory:restore(map)
    local it = self.courses[map]
    return if it == nil then nil else copy(it)
end
function RR.RaceCourseMemory:clear(map) self.courses[map] = nil end

-- View is deliberately separate from B/Cancel. A release or loss of focus
-- resets progress, and a completed hold fires only once until released.
RR.RaceClearHold = class(function() return { since = 0, fired = false, progress = 0 } end)
function RR.RaceClearHold:update(down, focused, now)
    if not down or not focused then
        self.since = 0; self.fired = false; self.progress = 0; return false
    end
    if self.fired then return false end
    if self.since == 0 then self.since = now end
    -- PORT: unsigned now-since wraps to a huge value when now < since, so progress is 1.
    self.progress = if now < self.since then 1 else math.min(1, (now - self.since) / 1500)
    if self.progress < 1 then return false end
    self.fired = true; return true
end

-- enum class RaceRouteMenuAction {none,load,save}: "none" | "load" | "save"
RR.RaceRouteMenuPress = class(function()
    return { hold_ = RR.RaceClearHold.new(), previous = false, fired = false, progress = 0 }
end)
function RR.RaceRouteMenuPress:update(down, focused, now)
    if not focused then
        self.hold_ = RR.RaceClearHold.new(); self.previous = false; self.fired = false; self.progress = 0
        return "none"
    end
    local complete = self.hold_:update(down, true, now); self.progress = self.hold_.progress
    local tap = self.previous and not down and not self.fired
    self.previous = down
    if complete then self.fired = true elseif not down then self.fired = false end
    return if complete then "load" elseif tap then "save" else "none"
end

-- Returns finish (his bool&).
function RR.clear_race_gates(route, finish)
    -- Retain the native start flag while clearing all checkpoints and finish.
    local keep = math.min(1, #route.points)
    resize(route.points, keep, vector.zero); resize(route.yaws, keep, 0); resize(route.widths, keep, 0)
    resize(route.gate_kinds, keep, "required"); resize(route.arrow_rolls, keep, 0); resize(route.gate_pitches, keep, 0)
    finish = false; route.race_finish = false
    return finish
end

function RR.race_gate_height(settings, index) return 10 * gate_half_width(settings, index) / 6 end
function RR.race_gate_pitch(settings, index)
    return if index < #settings.gate_pitches then settings.gate_pitches[index + 1] else 0
end

RR.RaceGateAxes = class(function() return { right = vector.zero, up = vector.zero, forward = vector.zero } end)
function RR.race_gate_axes(yaw, pitch, roll)
    local matrix = RR.race_arrow_transform(vector.zero, yaw, roll or 0, 1.5, pitch)
    return RR.RaceGateAxes.new({
        right = vector.create(matrix[1], matrix[2], matrix[3]),
        up = vector.create(matrix[5], matrix[6], matrix[7]),
        forward = vector.create(matrix[9], matrix[10], matrix[11]),
    })
end
function RR.race_gate_dot(p, origin, axis)
    return (p.x - origin.x) * axis.x + (p.y - origin.y) * axis.y + (p.z - origin.z) * axis.z
end

RR.RaceGateCrossing = class(function() return { crossed = false, inside = false, at = vector.zero } end)
function RR.race_gate_crossing(settings, index, before, after)
    if index >= #settings.points then return RR.RaceGateCrossing.new() end
    local gate = settings.points[index + 1]
    local from = if index ~= 0 then settings.points[index] else settings.points[index + 1]
    local to
    if index ~= 0 then
        to = settings.points[index + 1]
    elseif index + 1 < #settings.points then
        to = settings.points[index + 2]
    else
        to = settings.points[index + 1]
    end
    local heading = if index < #settings.yaws then settings.yaws[index + 1]
        else math.atan2(to.x - from.x, to.z - from.z) * 180 / 3.14159265
    local yaw = heading * 3.14159265 / 180
    local fx, fz = math.sin(yaw), math.cos(yaw)
    local pitch = RR.race_gate_pitch(settings, index); local axes = RR.race_gate_axes(heading, pitch)
    local function along(p)
        if pitch == 0 then return (p.x - gate.x) * fx + (p.z - gate.z) * fz end
        return RR.race_gate_dot(p, gate, axes.forward)
    end
    local a, b = along(before), along(after)
    if (a < 0) == (b < 0) or a == b then return RR.RaceGateCrossing.new() end
    local fraction = a / (a - b)
    local at = before + (after - before) * fraction
    local across = math.abs((at.x - gate.x) * fz - (at.z - gate.z) * fx)
    local up = if pitch == 0 then at.y - gate.y else RR.race_gate_dot(at, gate, axes.up)
    return RR.RaceGateCrossing.new({
        crossed = true,
        inside = across <= gate_half_width(settings, index) and math.abs(up) <= RR.race_gate_height(settings, index),
        at = at,
    })
end

function RR.race_gate_missed(settings, index, before, after)
    if index == 0 or index >= #settings.points or guiding_gate(settings, index) then return false end
    local crossing = RR.race_gate_crossing(settings, index, before, after)
    -- Going around (or above) a required gate still crosses its plane. Do not
    -- restrict this warning to a narrow band outside the posts.
    return crossing.crossed and not crossing.inside
end

-- Signed distance to a gate plane, independent of recovery policy.
function RR.race_gate_along(route, index, at)
    if index >= #route.points then return 0 end
    local heading
    if index < #route.yaws then
        heading = route.yaws[index + 1]
    elseif index ~= 0 then
        heading = math.atan2(route.points[index + 1].x - route.points[index].x,
            route.points[index + 1].z - route.points[index].z) * 180 / 3.14159265
    else
        heading = 0
    end
    local yaw = heading * 3.14159265 / 180
    local pitch = RR.race_gate_pitch(route, index)
    if pitch ~= 0 then return RR.race_gate_dot(at, route.points[index + 1], RR.race_gate_axes(heading, pitch).forward) end
    return (at.x - route.points[index + 1].x) * math.sin(yaw) + (at.z - route.points[index + 1].z) * math.cos(yaw)
end

function RR.race_snap_reach(degrees) return math.clamp(degrees * .1, .5, 6) end
function RR.rotate_race_gate(yaw, direction, snap, degrees)
    degrees = math.clamp(degrees, 5, 90)
    return remainder((if snap then math.round(yaw / degrees) * degrees else yaw) + direction * degrees, 360)
end
function RR.size_race_gate(width, direction)
    -- Five percentage points relative to the standard six-metre half width.
    return math.clamp(width + direction * .3, min_gate_half_width, max_gate_half_width)
end

-- next/started are std::array<uint64,4>: 1-based lists here, slot i+1 for bit i.
RR.RaceEditorPresses = class(function()
    return { previous = 0, blocked = 0, next = { 0, 0, 0, 0 }, started = { 0, 0, 0, 0 } }
end)
function RR.RaceEditorPresses:suppress(held)
    if held == nil then held = 15 end
    self.blocked = held; self.previous = 0; self.next = { 0, 0, 0, 0 }; self.started = { 0, 0, 0, 0 }
end
function RR.RaceEditorPresses:update(held, now, rotating)
    rotating = rotating or false
    self.blocked = bit32.band(self.blocked, held); held = bit32.band(held, bit32.bnot(self.blocked))
    local pressed = 0
    for i = 0, 3 do
        local bit = bit32.lshift(1, i)
        if bit32.band(held, bit) == 0 then
            self.next[i + 1] = 0; self.started[i + 1] = 0; continue
        end
        if bit32.band(self.previous, bit) == 0 then
            pressed = bit32.bor(pressed, bit); self.started[i + 1] = now
            self.next[i + 1] = now + (if rotating then 250 else 350)
        elseif now >= self.next[i + 1] then
            pressed = bit32.bor(pressed, bit)
            -- PORT: unsigned now-started wraps when now < started (counts as >= 900).
            local held_long = now < self.started[i + 1] or now - self.started[i + 1] >= 900
            local interval = if rotating then (if held_long then 50 else 80) else 150
            self.next[i + 1] = now + interval -- Never replay missed repeats after a frame stall.
        end
    end
    self.previous = held; return pressed
end

RR.RaceGatePose = class(function() return { at = vector.zero, yaw = 0 } end)

-- Keep a short trail of confirmed grounded poses. A brief landing, collision,
-- air sample or ragdoll cannot replace the last settled position before a fall.
-- trail: list of {first = time, second = RaceGatePose}; saved: RaceGatePose or nil.
RR.RaceLastSafeSpot = class(function() return { trail = {}, saved = nil } end)
function RR.RaceLastSafeSpot:reset() table.clear(self.trail); self.saved = nil end
function RR.RaceLastSafeSpot:pose() return if self.saved == nil then nil else RR.RaceGatePose.copy(self.saved) end
function RR.RaceLastSafeSpot:observe(safe, at, yaw, now)
    local trail = self.trail
    if not safe or not finite(yaw) or not finite3(at) then
        table.clear(trail); return
    end
    if #trail > 0 and now < trail[#trail].first then self:reset() end
    while #trail > 0 and now - trail[1].first >= 250 do
        self.saved = trail[1].second; table.remove(trail, 1)
    end
    if #trail == 0 or now - trail[#trail].first >= 50 then
        table.insert(trail, { first = now, second = RR.RaceGatePose.new({ at = at, yaw = yaw }) })
    end
end

function RR.previous_required_checkpoint(route, before)
    if #route.points == 0 then return 0 end
    local index = math.min(before, #route.points - 1)
    while index > 0 do
        index -= 1
        if not guiding_gate(route, index) then break end
    end
    return index
end

-- Manual fallback persists through another bail at the unsafe checkpoint. A
-- newly cleared Required gate resets it; guides and arrows never become targets.
-- selected_, visible_: std::optional<std::size_t>, nil when empty.
RR.RaceCheckpointFallback = class(function() return { selected_ = nil, visible_ = nil } end)
function RR.RaceCheckpointFallback:step_back(route, next)
    local last = if self.selected_ ~= nil then self.selected_ else RR.previous_required_checkpoint(route, next)
    self.selected_ = RR.previous_required_checkpoint(route, last); self.visible_ = self.selected_
    return self.selected_
end
function RR.RaceCheckpointFallback:target(route, next)
    return if self.selected_ ~= nil then self.selected_ else RR.previous_required_checkpoint(route, next)
end
function RR.RaceCheckpointFallback:visible_from(next)
    return if self.visible_ ~= nil then self.visible_ else next
end
function RR.RaceCheckpointFallback:observe_crossings(route, next, before, after)
    if self.selected_ == nil or #route.points == 0 then return end
    local stop = math.min(next, #route.points - 1) -- his `end`
    -- Authoritative progress stays cleared during rewind. Re-crossing an
    -- older Required gate must still move the local recovery point ahead.
    for i = self.selected_, stop - 1 do
        if not guiding_gate(route, i) and
            RR.race_gate_along(route, i, after) > RR.race_gate_along(route, i, before) and
            RR.race_gate_crossing(route, i, before, after).inside then
            self.selected_ = i; self.visible_ = i + 1
        end
    end
end
function RR.RaceCheckpointFallback:advanced() self.selected_ = nil; self.visible_ = nil end

RR.RaceCheckpointBackPress = class(function() return { down = true } end)
function RR.RaceCheckpointBackPress:update(held, allowed)
    local fire = allowed and held and not self.down
    self.down = held or not allowed
    return fire
end

function RR.snap_race_gate(settings, at, yaw, enabled, degrees)
    if degrees == nil then degrees = 15 end
    local pose = RR.RaceGatePose.new({ at = at, yaw = yaw })
    if not enabled or not finite(yaw) or not finite3(at) then return pose end
    degrees = math.clamp(degrees, 5, 90)
    pose.yaw = remainder(math.round(yaw / degrees) * degrees, 360)
    pose.at = vector.create(math.round(at.x * 2) * .5, pose.at.y, math.round(at.z * 2) * .5)
    local count = #settings.points - (if settings.race_finish and #settings.points > 0 then 1 else 0)
    if count == 0 or count > #settings.yaws then return pose end
    local previous = settings.points[count]
    local heading = settings.yaws[count]
    local angle = heading * 3.14159265 / 180
    local fx, fz, dx, dz = math.sin(angle), math.cos(angle), at.x - previous.x, at.z - previous.z
    local along, across = dx * fx + dz * fz, dx * fz - dz * fx
    -- Preserve the ground hit's height. Only attract a nearby centre line;
    -- routes can bend and fork without being pulled across the road.
    if math.abs(across) <= RR.race_snap_reach(degrees) and math.abs(along) >= 3 then
        local spacing = math.round(along)
        pose.at = vector.create(previous.x + fx * spacing, pose.at.y, previous.z + fz * spacing)
    end
    if math.abs(remainder(yaw - heading, 360)) <= degrees * .5 then pose.yaw = heading end
    return pose
end

function RR.race_checkpoint_pose(route, checkpoint)
    if #route.points == 0 then return RR.RaceGatePose.new() end
    local last = math.min(checkpoint, #route.points - 1)
    local pose = RR.RaceGatePose.new({
        at = route.points[last + 1],
        yaw = if last < #route.yaws then route.yaws[last + 1] else 0,
    })
    local yaw = pose.yaw * 3.14159265 / 180
    -- Leave room to regain control before skating through the gate again.
    -- Progress remains cleared; the teleport is never a gate crossing.
    pose.at = vector.create(pose.at.x - math.sin(yaw) * 3, pose.at.y, pose.at.z - math.cos(yaw) * 3)
    return pose
end

-- safe: a RaceGatePose or nil (taken by value).
function RR.race_return_pose(route, next, checkpoint, safe)
    if safe == nil then return RR.race_checkpoint_pose(route, checkpoint) end
    safe = RR.RaceGatePose.copy(safe)
    -- A safe position remains useful even if the rider had turned around.
    -- Carry their onboard speed towards the next required gate, not their
    -- pre-fall facing. Decorative objects cannot redirect the recovery.
    for i = next, #route.points - 1 do
        if not guiding_gate(route, i) then
            local dx, dz = route.points[i + 1].x - safe.at.x, route.points[i + 1].z - safe.at.z
            if hypot(dx, dz) > .1 then
                safe.yaw = math.atan2(dx, dz) * 180 / 3.14159265
            elseif i < #route.yaws then
                safe.yaw = route.yaws[i + 1]
            end
            break
        end
    end
    return safe
end

function RR.race_recovery_pose(route, missed)
    return RR.race_checkpoint_pose(route, RR.previous_required_checkpoint(route, missed))
end

-- Builder mutations keep pose arrays aligned and reserve the last slot for
-- exactly one finish. The wire continues to send the route in crossing order.
-- Returns ok, finish (his bool&).
function RR.edit_race_route(settings, finish, object, at, yaw, width, roll, pitch)
    roll = roll or 0; pitch = pitch or 0
    if settings.mode ~= "race" or #settings.points ~= #settings.yaws or #settings.points ~= #settings.widths or
        not finite(yaw) or not finite(roll) or math.abs(roll) > 360 or not finite(pitch) or math.abs(pitch) > 90 or
        not finite(width) or width < min_gate_half_width or width > max_gate_half_width or
        not (finite(at.x) and math.abs(at.x) < 100000 and finite(at.y) and math.abs(at.y) < 100000 and
            finite(at.z) and math.abs(at.z) < 100000) then
        return false, finish
    end
    if #settings.gate_kinds > 0 and #settings.gate_kinds ~= #settings.points then return false, finish end
    if #settings.arrow_rolls > 0 and #settings.arrow_rolls ~= #settings.points then return false, finish end
    if #settings.gate_pitches > 0 and #settings.gate_pitches ~= #settings.points then return false, finish end
    if object ~= RaceObject.start and object ~= RaceObject.checkpoint and object ~= RaceObject.finish and
        object ~= RaceObject.guiding and object ~= RaceObject.arrow then
        return false, finish
    end
    if #settings.gate_kinds == 0 then resize(settings.gate_kinds, #settings.points, "required") end
    if #settings.arrow_rolls == 0 then resize(settings.arrow_rolls, #settings.points, 0) end
    if #settings.gate_pitches == 0 then resize(settings.gate_pitches, #settings.points, 0) end
    if object == RaceObject.start then
        if #settings.points == 0 then
            table.insert(settings.points, at); table.insert(settings.yaws, yaw); table.insert(settings.widths, width)
            table.insert(settings.gate_kinds, "required"); table.insert(settings.arrow_rolls, 0)
            table.insert(settings.gate_pitches, 0)
        else
            settings.points[1] = at; settings.yaws[1] = yaw; settings.widths[1] = width
        end
        settings.spawn = at; settings.has_spawn = true; return true, finish
    end
    if #settings.points == 0 then return false, finish end
    local index = #settings.points - (if finish then 1 else 0)
    if object == RaceObject.finish then
        if index < 2 or mandatory_gates(settings, index) == 0 then return false, finish end
        if finish then
            local n = #settings.points
            settings.points[n] = at; settings.yaws[#settings.yaws] = yaw; settings.widths[#settings.widths] = width
            settings.gate_pitches[#settings.gate_pitches] = pitch; settings.race_finish = true
            return true, finish
        end
        finish = true; settings.race_finish = true
    end
    table.insert(settings.points, index + 1, at)
    table.insert(settings.yaws, index + 1, yaw)
    table.insert(settings.widths, index + 1, width)
    table.insert(settings.gate_kinds, index + 1,
        if object == RaceObject.arrow then "arrow" elseif object == RaceObject.guiding then "guide" else "required")
    table.insert(settings.arrow_rolls, index + 1, if object == RaceObject.arrow then roll else 0)
    table.insert(settings.gate_pitches, index + 1, pitch)
    return true, finish
end

-- Returns ok, finish.
function RR.undo_race_gate(settings, finish)
    if #settings.points <= 1 or #settings.points ~= #settings.yaws or #settings.points ~= #settings.widths then
        return false, finish
    end
    table.remove(settings.points); table.remove(settings.yaws); table.remove(settings.widths)
    if #settings.gate_kinds > 0 then table.remove(settings.gate_kinds) end
    if #settings.arrow_rolls > 0 then table.remove(settings.arrow_rolls) end
    if #settings.gate_pitches > 0 then table.remove(settings.gate_pitches) end
    finish = false; settings.race_finish = false; return true, finish
end

function RR.race_route_ready(settings, finish)
    local n = #settings.points
    return finish and settings.race_finish and settings.has_spawn and n >= 3 and
        n == #settings.yaws and n == #settings.widths and
        (#settings.gate_kinds == 0 or #settings.gate_kinds == n) and
        (#settings.arrow_rolls == 0 or #settings.arrow_rolls == n) and
        (#settings.gate_pitches == 0 or #settings.gate_pitches == n) and
        not guiding_gate(settings, 0) and not guiding_gate(settings, n - 1) and mandatory_gates(settings, n - 1) > 0
end

-- A finish mesh is not publication. Only an explicit Save commits the shape;
-- any later edit withdraws it until saved again. Timer/player edits keep the shape.
function RR.same_race_shape(a, b)
    return a.mode == b.mode and list_equal(a.points, b.points) and list_equal(a.yaws, b.yaws) and
        list_equal(a.widths, b.widths) and list_equal(a.gate_kinds, b.gate_kinds) and
        list_equal(a.arrow_rolls, b.arrow_rolls) and list_equal(a.gate_pitches, b.gate_pitches) and
        a.race_finish == b.race_finish and a.has_spawn == b.has_spawn and a.spawn == b.spawn
end

-- saved_: a Settings or nil.
RR.RaceRoutePublication = class(function() return { saved_ = nil } end)
function RR.RaceRoutePublication:begin_edit() self.saved_ = nil end
function RR.RaceRoutePublication:save(route)
    if not RR.race_route_ready(route, route.race_finish) then return false end
    self.saved_ = copy(route); return true
end
function RR.RaceRoutePublication:ready(route)
    return self.saved_ ~= nil and RR.same_race_shape(self.saved_, route) and RR.race_route_ready(route, route.race_finish)
end
-- Native flag placement is a separate editor phase. A stale Join must not
-- enroll a guest while that picker is open, even when old geometry is valid.
function RR.RaceRoutePublication:accepting(route, editing, flag_pending)
    return not editing and not flag_pending and self:ready(route)
end

function RR.race_gate_visible(route, index, from, playing)
    return not playing or arrow_marker(route, index) or index >= from
end

-- Missing a gate's posts never teleports. A later Required gate proves a
-- skipped checkpoint; the Finish is ignored until every Required gate is clear.
-- Returns the gate index or nil.
function RR.race_later_gate_crossed(route, expected, before, after)
    if expected == 0 or expected >= #route.points then return nil end
    local stop = #route.points - (if route.race_finish then 1 else 0) -- his `end`
    for i = expected + 1, stop - 1 do
        if not guiding_gate(route, i) and RR.race_gate_along(route, i, after) > RR.race_gate_along(route, i, before) and
            RR.race_gate_crossing(route, i, before, after).inside then
            return i
        end
    end
    return nil
end

-- "" when there is nothing wrong.
function RR.race_route_save_error(route, finish)
    if not finish or not route.race_finish then return "You need a Finish line before saving this route." end
    if not route.has_spawn or #route.points == 0 then return "Place the start flag before saving this route." end
    if mandatory_gates(route, #route.points - 1) == 0 then
        return "Place at least one Required gate before saving this route."
    end
    if not RR.race_route_ready(route, finish) then
        return "The route is incomplete. Check the start, Required gates and Finish line."
    end
    return ""
end

-- enum class RaceFlagTransition { rejected, edit_route }: "rejected" | "edit_route"
-- A saved course keeps every gate and its single finish when its native start
-- flag is placed again. Always open the builder so its owner can edit or clear
-- the restored course, or save it unchanged before choosing Start.
-- Returns the transition, finish.
function RR.accept_race_flag(settings, finish, at, yaw, width)
    local ok
    ok, finish = RR.edit_race_route(settings, finish, RaceObject.start, at, yaw, width)
    if not ok then return "rejected", finish end
    return "edit_route", finish
end

return RR
