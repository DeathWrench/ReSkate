-- SmokeyDawg58's race_navigation.h (HIS/Modes/race_navigation.h), line for line.
-- Gate indices are 0-based as in his C++. `local` is a Luau keyword: that argument is local_id.
local RN = {}

local function finite(x) return x == x and x ~= math.huge and x ~= -math.huge end

-- ---- race_navigation.h ---------------------------------------------------------------------------
RN.race_compass_icon_size = 96
RN.race_compass_center_y = 209
RN.race_compass_max_offset = (1184 - RN.race_compass_icon_size) * .5
-- The compass is local presentation; it never advances the referee or changes
-- a player's map waypoint. Guide gates and decorative arrows are not targets.
-- Returns the gate index, or nil.
function RN.race_compass_gate(route, state, local_id)
    if route.mode ~= "race" or state.phase ~= "playing" then return nil end
    for _, row in ipairs(state.standings) do
        if row.player == local_id and not row.out then
            if row.score < 0 then return nil end
            for i = row.score, #route.points - 1 do
                if i > 0 and (i >= #route.gate_kinds or route.gate_kinds[i + 1] == "required") then return i end
            end
        end
    end
    return nil
end
-- Native compass projection: ahead is the center; +/-90 degrees reaches
-- either end of its 1184-unit strip. A target behind stays at the nearer end.
-- camera: a list of 16 numbers (element k is his [k-1]). Returns the offset, or nil.
function RN.race_compass_offset(target, camera)
    local dx, dz = target.x - camera[13], target.z - camera[15]
    local right, forward = dx * camera[1] + dz * camera[3], -dx * camera[9] - dz * camera[11]
    if not finite(right) or not finite(forward) or math.sqrt(camera[9] * camera[9] + camera[11] * camera[11]) < .001 then
        return nil
    end
    return math.clamp(math.atan2(right, forward) / (3.14159265 * .5), -1, 1) * RN.race_compass_max_offset
end

return RN
