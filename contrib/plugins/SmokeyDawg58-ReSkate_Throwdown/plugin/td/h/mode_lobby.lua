-- SmokeyDawg58's mode_lobby.h (HIS/Modes/mode_lobby.h), line for line.
local ML = {}

-- ---- helpers -------------------------------------------------------------------------------------
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return setmetatable(out, getmetatable(value))
end

-- ---- mode_lobby.h --------------------------------------------------------------------------------
function ML.lobby_departure_blocks_rejoin(phase)
    return phase ~= "setup"
end
-- settings is taken by value: the result is a copy.
function ML.advertised_lobby_settings(settings, editing)
    local advertised = copy(settings)
    -- An unsaved Deathrace is a draft, even after its red finish is placed.
    -- The existing route-validity check withdraws its flag on every peer.
    if advertised.mode == "race" and editing then
        advertised.race_finish = false; advertised.has_spawn = false; advertised.spawn = vector.zero
        table.clear(advertised.points); table.clear(advertised.yaws); table.clear(advertised.widths)
        table.clear(advertised.gate_kinds)
        table.clear(advertised.arrow_rolls); table.clear(advertised.gate_pitches); table.clear(advertised.corners)
        advertised.area_radius = 0
    end
    return advertised
end
-- Enrollment is the complete guest action. The wire's historical `up` bit
-- is a gameplay indicator and must not gate lobby start or the player count.
function ML.lobby_enrolled_count(state)
    if state.phase ~= "setup" then return 0 end
    local count = 0
    for _, p in ipairs(state.standings) do
        if not p.out then count += 1 end
    end
    return count
end

return ML
