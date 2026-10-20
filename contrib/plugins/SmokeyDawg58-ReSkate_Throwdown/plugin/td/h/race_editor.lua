-- SmokeyDawg58's race_editor.h (HIS/Modes/race_editor.h), line for line.
-- Indices are 0-based as in his C++. Vec3 is a Luau vector. Reference out-parameters
-- (bool& finish, bool& snapped, float& y/p/r) keep their place in the arguments and are
-- returned as extra results.
local RR = require("td/h/race_route")
local RE = {}

-- ---- helpers -------------------------------------------------------------------------------------
-- mode_rules.h's gate functions, 0-based as his.
local R = require("td/rules")
local gate_half_width, guiding_gate, arrow_marker, mandatory_gates =
    R.gate_half_width, R.guiding_gate, R.arrow_marker, R.mandatory_gates

local function finite(x) return x == x and x ~= math.huge and x ~= -math.huge end
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
-- Settings == Settings (deep; vectors compare by value).
local function equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
-- std::vector::resize
local function resize(list, n, fill)
    for i = #list, n + 1, -1 do list[i] = nil end
    for i = #list + 1, n do list[i] = fill end
end
-- dst = std::move(src), keeping dst's own list.
local function assign_list(dst, src)
    table.clear(dst)
    for i, v in ipairs(src) do dst[i] = v end
end
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

-- ---- race_editor.h -------------------------------------------------------------------------------
RE.RaceEditorInputRelease = class(function() return { waiting = false } end)
function RE.RaceEditorInputRelease:arm() self.waiting = true end
function RE.RaceEditorInputRelease:blocked(buttons, keyboard, menu_open)
    if menu_open then self:arm(); return true end
    if not self.waiting then return false end
    if buttons == 0 and not keyboard then self.waiting = false end
    return true -- Consume the release frame too; it belongs to the menu.
end

local placement_labels = { "START FLAG", "REQUIRED GATE", "FINISH GATE", "GUIDE GATE", "ARROW" }
function RE.race_placement_label(object)
    return if object < #placement_labels then placement_labels[object + 1] else "REQUIRED GATE"
end
-- User-facing names stay separate from persisted object identifiers.
local object_names = { "Start flag", "Required gate", "Finish gate", "Guide gate", "Arrow" }
function RE.race_editor_object_name(object)
    return if object < #object_names then object_names[object + 1] else "Required gate"
end
function RE.race_default_roll_axis(object) return object == 4 end

-- Build-only markers use the mandatory sequence, excluding decorative arrows
-- and guide gates. Their world position follows the tilted gate's highest edge.
function RE.race_editor_gate_number(route, i)
    if i == 0 or i >= #route.points or arrow_marker(route, i) then return "" end
    if guiding_gate(route, i) then return "GUIDE" end
    return (if route.race_finish and i + 1 == #route.points then "FINISH " else "GATE ")
        .. tostring(mandatory_gates(route, i) + 1)
end
function RE.race_editor_gate_number_position(route, i)
    local point = route.points[i + 1]
    local from = route.points[(if i ~= 0 then i - 1 else i) + 1]
    local yaw = if i < #route.yaws then route.yaws[i + 1]
        else math.atan2(point.x - from.x, point.z - from.z) * 180 / 3.14159265
    local axes = RR.race_gate_axes(yaw, RR.race_gate_pitch(route, i))
    local half = gate_half_width(route, i)
    local scale = half / 6
    point = point + axes.up * (1.70747 * scale)
    point = vector.create(point.x, point.y + half + .7, point.z)
    return point
end

function RE.race_object_label_alpha(now, changed)
    if changed == 0 or now < changed then return 0 end
    local age = now - changed
    if age < 180 then return age / 180 end
    if age < 2000 then return 1 end
    return if age < 2300 then (2300 - age) / 300 else 0
end

RE.RaceEditorDirections = class(function()
    return { yaw = 0, tilt = 0, size = 0, undo = false, redo = false }
end)
function RE.race_editor_directions(rotating, step)
    local function on(bit) return if bit32.band(step, bit) ~= 0 then 1 else 0 end
    local horizontal = on(2) - on(1)
    local vertical = on(8) - on(4)
    if rotating then
        return RE.RaceEditorDirections.new({ yaw = horizontal, tilt = vertical, size = 0, undo = false, redo = false })
    end
    return RE.RaceEditorDirections.new({ yaw = 0, tilt = 0, size = vertical, undo = horizontal < 0, redo = horizontal > 0 })
end

RE.RaceRotationOrigin = class(function() return { yaw = 0, pitch = 0, roll = 0, captured = false } end)
function RE.RaceRotationOrigin:clear() self.captured = false end
-- Keep the first straight pose across repeated visits to Rotate.
function RE.RaceRotationOrigin:capture(y, p, r)
    if not self.captured then self.yaw = y; self.pitch = p; self.roll = r; self.captured = true end
end
-- Returns y, p (his float& y, float& p).
function RE.RaceRotationOrigin:update_aim(camera_yaw, camera_pitch, y, p, automatic_tilt)
    if not self.captured then y = camera_yaw end
    if not self.captured or automatic_tilt then p = camera_pitch end
    return y, p
end
-- Returns y, p, r (his float& y, p, r).
function RE.RaceRotationOrigin:restore(y, p, r)
    y = self.yaw; p = self.pitch; r = self.roll
    return y, p, r
end

function RE.race_rotation_degrees(value)
    if not finite(value) then return 0 end
    local angle = remainder(value, 360)
    return if math.abs(angle) < .05 then 0 else angle -- Avoid -0.0 in the readout.
end

-- past, future: lists of Settings.
RE.RaceRouteHistory = class(function() return { past = {}, future = {} } end)
function RE.RaceRouteHistory.restore_shape(route, previous)
    -- Undo edits the route, not current timer/rules/area settings.
    assign_list(route.points, previous.points); assign_list(route.yaws, previous.yaws)
    assign_list(route.widths, previous.widths); assign_list(route.gate_kinds, previous.gate_kinds)
    assign_list(route.arrow_rolls, previous.arrow_rolls); assign_list(route.gate_pitches, previous.gate_pitches)
    route.race_finish = previous.race_finish; route.has_spawn = previous.has_spawn; route.spawn = previous.spawn
end
function RE.RaceRouteHistory:reset() table.clear(self.past); table.clear(self.future) end
function RE.RaceRouteHistory:changed(before, after)
    if equal(before, after) then return end
    if #self.past == 64 then table.remove(self.past, 1) end
    table.insert(self.past, copy(before)); table.clear(self.future)
end
-- Saved routes may outlive their editor/game. Rebuild a useful history
-- only when this session has no more precise placement history to retain.
function RE.RaceRouteHistory:resume(route)
    if #self.past > 0 or #self.future > 0 or #route.points < 2 then return end
    for count = 1, #route.points - 1 do
        local prefix = copy(route)
        resize(prefix.points, count, vector.zero); resize(prefix.yaws, count, 0); resize(prefix.widths, count, 0)
        if #prefix.gate_kinds > 0 then resize(prefix.gate_kinds, count, "required") end
        if #prefix.arrow_rolls > 0 then resize(prefix.arrow_rolls, count, 0) end
        if #prefix.gate_pitches > 0 then resize(prefix.gate_pitches, count, 0) end
        prefix.race_finish = false; table.insert(self.past, prefix)
        if #self.past > 64 then table.remove(self.past, 1) end
    end
end
-- Reopening uses a newly placed native flag. History must never move
-- its logical spawn back to a previous flag that no longer exists.
function RE.RaceRouteHistory:rebase_start(route)
    if route.mode ~= "race" or #route.points == 0 or #route.yaws == 0 or #route.widths == 0 then return end
    local function update(entry)
        local finish = entry.race_finish
        RR.edit_race_route(entry, finish, RR.RaceObject.start, route.points[1], route.yaws[1], route.widths[1])
    end
    for _, entry in ipairs(self.past) do update(entry) end
    for _, entry in ipairs(self.future) do update(entry) end
end
-- Returns ok, finish.
function RE.RaceRouteHistory:undo(route, finish)
    if #self.past == 0 then return false, finish end
    table.insert(self.future, copy(route))
    RE.RaceRouteHistory.restore_shape(route, self.past[#self.past]); table.remove(self.past)
    finish = route.race_finish; return true, finish
end
-- Returns ok, finish.
function RE.RaceRouteHistory:redo(route, finish)
    if #self.future == 0 then return false, finish end
    table.insert(self.past, copy(route))
    RE.RaceRouteHistory.restore_shape(route, self.future[#self.future]); table.remove(self.future)
    finish = route.race_finish; return true, finish
end

function RE.tilt_race_gate(pitch, direction, snap, degrees)
    return math.clamp(RR.rotate_race_gate(pitch, direction, snap, degrees), -90, 90)
end
RE.default_race_editor_width = 7.5
RE.default_race_editor_snap_angle = 4
function RE.race_camera_yaw(camera, offset, arrow)
    return remainder(camera + offset + (if arrow then 180 else 0), 360)
end
function RE.race_camera_pitch(camera, offset, arrow, surface)
    -- Looking across open air keeps a vertical sign. A real surface hit still
    -- supplies the floor/wall tilt, and X retains an explicit manual offset.
    return math.clamp((if arrow and surface then camera else 0) + offset, -90, 90)
end
-- Returns at, snapped (his bool& snapped).
function RE.snap_race_arrow_height(settings, at, enabled, snapped)
    snapped = false
    if not enabled then return at, snapped end
    local nearest = 3.4028234663852886e38 -- std::numeric_limits<float>::max()
    local original_height = at.y
    for i = 1, #settings.points - 1 do
        if arrow_marker(settings, i) then
            local other = settings.points[i + 1]
            local dx, dz = at.x - other.x, at.z - other.z
            local distance = dx * dx + dz * dz
            local reach, height_reach = math.max(24, gate_half_width(settings, i) * 4), 1
            if distance <= reach * reach and distance <= nearest and math.abs(original_height - other.y) <= height_reach then
                nearest = distance; at = vector.create(at.x, other.y, at.z); snapped = true
            end
        end
    end
    return at, snapped
end

-- Capture a row on the previous marker's authored axes, never the noisy
-- segment between two placements. Lock its whole pose so camera movement
-- cannot give consecutive upright arrows different headings or tilts.
RE.RaceArrowSnapPose = class(function() return { at = vector.zero, yaw = 0, pitch = 0, roll = 0 } end)
local RaceArrowSnapPose = RE.RaceArrowSnapPose
function RE.race_arrow_snap_angle(angle, step)
    return if step > 0 then remainder(math.round(angle / step) * step, 360) else angle
end
-- pose is taken by value: the result is a copy.
function RE.snap_race_arrow_angles(pose, enabled, step)
    pose = RaceArrowSnapPose.copy(pose)
    if enabled then
        pose.yaw = RE.race_arrow_snap_angle(pose.yaw, step)
        pose.pitch = math.clamp(RE.race_arrow_snap_angle(pose.pitch, step), -90, 90)
        pose.roll = RE.race_arrow_snap_angle(pose.roll, step)
    end
    return pose
end

-- rotation_count: std::optional<std::size_t>, nil when empty.
RE.RaceArrowLineSnap = class(function()
    return {
        locked = false, upright_locked = false, anchor = vector.zero, direction = vector.zero,
        yaw = 0, pitch = 0, roll = 0,
        last_raw = vector.zero, input_bias = vector.zero, raw_valid = false, upright_count = 0,
        rotation_count = nil,
    }
end)
local RaceArrowLineSnap = RE.RaceArrowLineSnap
function RaceArrowLineSnap.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function RaceArrowLineSnap.sub(a, b) return vector.create(a.x - b.x, a.y - b.y, a.z - b.z) end
function RaceArrowLineSnap:reset()
    self.locked = false; self.upright_locked = false; self.raw_valid = false; self.input_bias = vector.zero
    self.upright_count = 0; self.rotation_count = nil
end
function RaceArrowLineSnap:begin_rotation(count) self:reset(); self.rotation_count = count end
-- Returns the pose, snapped (his bool& snapped keeps its place in the arguments).
function RaceArrowLineSnap:update(route, pose, enabled, step, snapped, upright)
    local dot, sub = RaceArrowLineSnap.dot, RaceArrowLineSnap.sub
    upright = upright or false
    snapped = false
    if not enabled then self:reset(); return RaceArrowSnapPose.copy(pose), snapped end
    pose = RE.snap_race_arrow_angles(pose, true, step)
    -- An explicit X rotation starts a new row; do not pull its preview
    -- back to the previous row before the first new marker is placed.
    if self.rotation_count ~= nil then
        if self.rotation_count == #route.points then return pose, snapped end
        self.rotation_count = nil
    end
    if upright and math.abs(pose.pitch) < .001 and math.abs(pose.roll) < .001 then
        local recent = nil
        local nearest = 24 * 24
        local i = #route.points
        while i > 1 do
            i -= 1
            if not arrow_marker(route, i) then continue end
            local old_roll = if i < #route.arrow_rolls then route.arrow_rolls[i + 1] else 0
            local delta = sub(pose.at, route.points[i + 1])
            local distance = dot(delta, delta)
            if math.abs(RR.race_gate_pitch(route, i)) < .001 and math.abs(old_roll) < .001 and distance < nearest then
                recent = i; nearest = distance
            end
        end
        if recent == nil then self:reset(); return pose, snapped end
        local i = recent
        local next = route.points[i + 1]
        local delta = sub(pose.at, next)
        local old_yaw = if i < #route.yaws then route.yaws[i + 1] else 0
        if self.upright_locked and self.yaw == old_yaw and #route.points >= self.upright_count then
            local shift = sub(next, self.anchor)
            local along = dot(shift, self.direction)
            local off = vector.create(shift.x - self.direction.x * along, shift.y - self.direction.y * along,
                shift.z - self.direction.z * along)
            if dot(off, off) < .0001 then
                if dot(shift, shift) > .0001 then
                    -- Rebase aim drift only onto a newly appended arrow.
                    -- An older collinear reference must not move the aim.
                    -- PORT: upright_count-(race_finish?1u:0u) is unsigned; below zero it wraps and i>= is false.
                    local floor_count = self.upright_count - (if route.race_finish then 1 else 0)
                    local appended = #route.points > self.upright_count and floor_count >= 0 and i >= floor_count
                    if appended and self.raw_valid then
                        self.input_bias = sub(self.last_raw, next)
                    else
                        self:reset()
                    end
                end
                self.anchor = next
            else
                self:reset()
            end
        else
            self:reset()
        end
        local intent = sub(delta, self.input_bias)
        local basis = RR.race_arrow_transform(vector.zero, old_yaw, 0, 1.5, 0)
        local axes = { vector.create(basis[1], 0, basis[3]), vector.create(0, 1, 0), vector.create(basis[9], 0, basis[11]) }
        local best = axes[3]
        local strongest = math.abs(dot(intent, best))
        for _, axis in ipairs(axes) do
            local amount = math.abs(dot(intent, axis))
            if amount > strongest then best = axis; strongest = amount end
        end
        -- Keep small hand/camera drift on the current rail, but a clear
        -- movement toward any of the other two axes switches immediately.
        if not self.upright_locked or strongest > math.abs(dot(intent, self.direction)) * 1.4 + 1 then self.direction = best end
        self.anchor = next; self.yaw = old_yaw; self.pitch = 0; self.roll = 0
        local along = dot(intent, self.direction)
        local projected = vector.create(next.x + self.direction.x * along, next.y + self.direction.y * along,
            next.z + self.direction.z * along)
        -- A narrow rail can be escaped without toggling Snap. Re-evaluate
        -- every arrow on the next update, including an older nearby row.
        local error = sub(projected, pose.at)
        if dot(error, error) > 9 then self:reset(); return pose, snapped end
        self.upright_locked = self.locked or strongest >= 1
        self.locked = self.upright_locked
        self.last_raw = pose.at; self.raw_valid = true; self.upright_count = #route.points; snapped = true
        return RaceArrowSnapPose.new({ at = projected, yaw = self.yaw, pitch = 0, roll = 0 }), snapped
    end
    if self.upright_locked then self.locked = false; self.upright_locked = false end
    local recent = nil
    local nearest = 24 * 24
    local i = #route.points
    while i > 1 do
        i -= 1
        if not arrow_marker(route, i) then continue end
        local old_yaw = if i < #route.yaws then route.yaws[i + 1] else 0
        local old_roll = if i < #route.arrow_rolls then route.arrow_rolls[i + 1] else 0
        local prior = RE.snap_race_arrow_angles(RaceArrowSnapPose.new({
            at = route.points[i + 1], yaw = old_yaw, pitch = RR.race_gate_pitch(route, i), roll = old_roll,
        }), true, step)
        if math.abs(prior.pitch - pose.pitch) > 35 or math.abs(remainder(prior.roll - pose.roll, 360)) > 35 then continue end
        local delta = sub(pose.at, route.points[i + 1])
        local distance = dot(delta, delta)
        if distance < nearest then recent = i; nearest = distance end
    end
    if recent == nil then self:reset(); return pose, snapped end
    local i = recent
    local next_anchor = route.points[i + 1]
    local delta = sub(pose.at, next_anchor)
    local prior = RE.snap_race_arrow_angles(RaceArrowSnapPose.new({
        at = next_anchor, yaw = if i < #route.yaws then route.yaws[i + 1] else 0,
        pitch = RR.race_gate_pitch(route, i), roll = if i < #route.arrow_rolls then route.arrow_rolls[i + 1] else 0,
    }), true, step)
    local function project(axis)
        local along = dot(delta, axis)
        return vector.create(next_anchor.x + axis.x * along, next_anchor.y + axis.y * along, next_anchor.z + axis.z * along)
    end
    local function error(point)
        local d = sub(pose.at, point)
        return dot(d, d)
    end
    local function aligned(at)
        snapped = true
        return RaceArrowSnapPose.new({ at = at, yaw = self.yaw, pitch = self.pitch, roll = self.roll })
    end
    if self.locked and self.yaw == prior.yaw and self.pitch == prior.pitch and self.roll == prior.roll then
        -- Re-anchor to a newly placed marker only if it remains on the
        -- same axis. Undo/Redo and a genuinely new row cannot retain it.
        local shift = sub(next_anchor, self.anchor)
        local along = dot(shift, self.direction)
        local off = vector.create(shift.x - self.direction.x * along, shift.y - self.direction.y * along,
            shift.z - self.direction.z * along)
        if dot(off, off) < .0001 and error(project(self.direction)) <= 9 then
            self.anchor = next_anchor
            local result = aligned(project(self.direction))
            return result, snapped
        end
    end
    self:reset()
    local best = 9
    local selected = vector.zero
    local found = false
    local basis = RR.race_arrow_transform(vector.zero, prior.yaw, prior.roll, 1.5, prior.pitch)
    for _, start in ipairs({ 0, 4, 8 }) do
        local axis = vector.create(basis[start + 1], basis[start + 2], basis[start + 3])
        local point = project(axis)
        local distance = error(point)
        if distance <= best then best = distance; selected = axis; found = true end
    end
    if not found then return pose, snapped end
    self.anchor = next_anchor; self.direction = selected; self.yaw = prior.yaw; self.pitch = prior.pitch
    self.roll = prior.roll; self.locked = true
    local result = aligned(project(self.direction))
    return result, snapped
end

RE.RaceRotationPose = class(function() return { at = vector.zero, yaw = 0, pitch = 0, width = 7.5, roll = 0 } end)
local RaceRotationPose = RE.RaceRotationPose
RE.RaceRotationVisual = class(function()
    return { current = RaceRotationPose.new(), previous = 0, initialized = false }
end)
function RE.RaceRotationVisual:reset() self.initialized = false; self.previous = 0 end
-- target is taken by value and the result is a copy of the current pose.
function RE.RaceRotationVisual:update(target, now)
    if not self.initialized or now < self.previous or now - self.previous > 250 then
        self.current = RaceRotationPose.copy(target); self.initialized = true; self.previous = now
        return RaceRotationPose.copy(self.current)
    end
    local current = self.current
    local dt = (now - self.previous) / 1000
    self.previous = now
    local blend = 1 - math.exp(-dt / .045)
    current.at = vector.create(current.at.x + (target.at.x - current.at.x) * blend,
        current.at.y + (target.at.y - current.at.y) * blend, current.at.z + (target.at.z - current.at.z) * blend)
    current.yaw = remainder(current.yaw + remainder(target.yaw - current.yaw, 360) * blend, 360)
    current.pitch += (target.pitch - current.pitch) * blend
    current.width += (target.width - current.width) * blend
    current.roll = remainder(current.roll + remainder(target.roll - current.roll, 360) * blend, 360)
    return RaceRotationPose.copy(current)
end

return RE
