-- SmokeyDawg58's race_arrow_placement.h (HIS/Modes/race_arrow_placement.h), line for line.
-- Vec3 is a Luau vector. A `Cast` is a Lua function cast(origin, direction, length) that
-- returns a RaceArrowRay (a table {available, hit, at}).
local RR = require("td/h/race_route")
local RA = {}

-- ---- helpers -------------------------------------------------------------------------------------
local function finite(x) return x == x and x ~= math.huge and x ~= -math.huge end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return setmetatable(out, getmetatable(value))
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

-- ---- race_arrow_placement.h ----------------------------------------------------------------------
RA.RaceArrowRay = class(function() return { available = false, hit = false, at = vector.zero } end)
RA.RaceArrowSurface = class(function() return { contact = false, at = vector.zero, normal = vector.zero } end)
RA.RaceArrowAim = class(function()
    return { valid = false, align_surface = false, at = vector.zero, surface = RA.RaceArrowSurface.new() }
end)

RA.RaceArrowFloorAlignment = class(function() return { flat = false } end)
function RA.RaceArrowFloorAlignment:reset() self.flat = false end
function RA.RaceArrowFloorAlignment:update(floor_contact, forward_y, manual)
    -- Engage only on a direct floor hit while looking down at least 45
    -- degrees; release at 30 degrees. No distant/downward ground search.
    self.flat = not manual and floor_contact and finite(forward_y) and
        forward_y <= (if self.flat then -.5 else -.70710678)
    return self.flat
end

function RA.arrow_add(a, b, scale)
    if scale == nil then scale = 1 end
    return vector.create(a.x + b.x * scale, a.y + b.y * scale, a.z + b.z * scale)
end
function RA.arrow_dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function RA.arrow_unit(value)
    local length = math.sqrt(RA.arrow_dot(value, value))
    return if length > .0001 then vector.create(value.x / length, value.y / length, value.z / length) else vector.zero
end
function RA.arrow_cross(a, b)
    return vector.create(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end
local arrow_add, arrow_dot, arrow_unit, arrow_cross = RA.arrow_add, RA.arrow_dot, RA.arrow_unit, RA.arrow_cross

-- Query the same verified collision API as gate placement. A clear ray keeps
-- free-air placement; a hit keeps the marker on the visible side of a surface.
-- A direct hit mounts to that visible surface. A clear ray stays in the air;
-- there is no downward ground search or attraction to another arrow's surface.
-- Nearby parallel samples recover its plane without assuming a native normal ABI.
function RA.aim_race_arrow(origin, forward, right, up, cast)
    local result = RA.RaceArrowAim.new()
    result.at = arrow_add(origin, forward, 12)
    local hit = cast(origin, forward, 12)
    if not hit.available then return result end
    result.valid = true
    if not hit.hit then return result end
    result.align_surface = true
    result.at = hit.at
    local nearby = { vector.zero, vector.zero, vector.zero, vector.zero }
    local valid = { false, false, false, false }
    for i = 0, 3 do
        local sample = cast(arrow_add(origin, if i < 2 then right else up, if i % 2 ~= 0 then .08 else -.08), forward, 14)
        nearby[i + 1] = arrow_add(sample.at or vector.zero, hit.at, -1)
        valid[i + 1] = (sample.available and sample.hit and arrow_dot(nearby[i + 1], nearby[i + 1]) < 4) and true or false
    end
    for i = 0, 1 do
        for j = 2, 3 do
            if valid[i + 1] and valid[j + 1] then
                local normal = arrow_unit(arrow_cross(nearby[i + 1], nearby[j + 1]))
                if arrow_dot(normal, normal) < .9 or math.abs(arrow_dot(normal, forward)) < .02 then continue end
                if arrow_dot(normal, forward) > 0 then normal = -normal end
                result.surface = RA.RaceArrowSurface.new({ contact = true, at = hit.at, normal = normal })
                return result
            end
        end
    end
    -- At a thin edge there may be no reliable mounting plane. Refuse this
    -- position rather than pretending the ray missed and placing behind it.
    result.valid = false
    return result
end

-- std::array<float,2>: a list {yaw, pitch}.
function RA.race_arrow_surface_angles(normal)
    return {
        math.atan2(normal.x, normal.z) * 180 / 3.14159265,
        -math.asin(math.clamp(normal.y, -1, 1)) * 180 / 3.14159265,
    }
end

function RA.clear_race_arrow_surface(at, yaw, pitch, roll, width, surface)
    if not surface.contact then return at end
    local pose = RR.race_arrow_transform(vector.zero, yaw, roll, width, pitch)
    local right, up = vector.create(pose[1], pose[2], pose[3]), vector.create(pose[5], pose[6], pose[7])
    -- Both native chevron meshes are XY quads with authored bounds +/-0.5.
    -- Account for the full rotated footprint, plus 4 cm to avoid z-fighting.
    local support = .5 * (math.abs(arrow_dot(right, surface.normal)) + math.abs(arrow_dot(up, surface.normal))) + .04
    local distance = arrow_dot(arrow_add(at, surface.at, -1), surface.normal)
    return arrow_add(at, surface.normal, math.max(0, support - distance))
end

RA.RaceArrowGroundClearance = class(function() return { at = vector.zero, available = true } end)
-- A center aim can miss the road while the bottom of an upright/tilted quad
-- intersects it. Probe the footprint from above, where one-sided road meshes
-- can be hit. Only lift an intersecting footprint; never pull free air down.
function RA.clear_race_arrow_ground(at, yaw, pitch, roll, width, cast)
    local pose = RR.race_arrow_transform(at, yaw, roll, width, pitch)
    local top = at.y + .5 * (math.abs(pose[2]) + math.abs(pose[6])) + .25
    local lift = 0
    local available = true
    for x = -1, 1 do
        for y = -1, 1 do
            local point = vector.create(
                at.x + x * .5 * pose[1] + y * .5 * pose[5],
                at.y + x * .5 * pose[2] + y * .5 * pose[6],
                at.z + x * .5 * pose[3] + y * .5 * pose[7])
            local hit = cast(vector.create(point.x, top, point.z), vector.create(0, -1, 0), top - point.y + .04)
            available = available and hit.available == true
            if hit.available and hit.hit then lift = math.max(lift, hit.at.y + .04 - point.y) end
        end
    end
    at = vector.create(at.x, at.y + lift, at.z)
    return RA.RaceArrowGroundClearance.new({ at = at, available = available })
end

function RA.race_arrow_clear(origin, at, yaw, pitch, roll, width, cast)
    local pose = RR.race_arrow_transform(at, yaw, roll, width, pitch)
    local function clear_segment(from, to)
        local delta = arrow_add(to, from, -1)
        local length = math.sqrt(arrow_dot(delta, delta))
        if not (length > .1 and length < 500) then return false end
        local direction = arrow_unit(delta)
        local hit = cast(from, direction, length)
        if not hit.available then return false end
        return not hit.hit or arrow_dot(arrow_add(hit.at, from, -1), direction) >= length - .015
    end
    -- The center cannot be placed behind the aimed obstruction. Test actual
    -- segments on the quad, rather than camera visibility rays to its corners:
    -- a foreground curb/tree must not invalidate an otherwise clear arrow.
    if not clear_segment(origin, at) then return false end
    local function point(x, y)
        return vector.create(at.x + x * pose[1] + y * pose[5], at.y + x * pose[2] + y * pose[6],
            at.z + x * pose[3] + y * pose[7])
    end
    for line = -1, 1 do
        local offset = .5 * line
        if not clear_segment(point(-.5, offset), point(.5, offset)) or
            not clear_segment(point(offset, -.5), point(offset, .5)) then
            return false
        end
    end
    if not clear_segment(point(-.5, -.5), point(.5, .5)) or
        not clear_segment(point(-.5, .5), point(.5, -.5)) then
        return false
    end
    return true
end

function RA.race_arrow_preview_visible(ready, rotating, angles_ready)
    return ready or (rotating and angles_ready)
end

return RA
