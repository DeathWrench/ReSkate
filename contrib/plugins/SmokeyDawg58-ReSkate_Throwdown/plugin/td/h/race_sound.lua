-- SmokeyDawg58's race_sound.h (HIS/Modes/race_sound.h), line for line.
-- Phases are strings ("setup" | "countdown" | "playing" | "results").
local RS = {}

-- ---- helpers -------------------------------------------------------------------------------------
local R = require("td/rules")
local mandatory_gates = R.mandatory_gates
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

-- ---- race_sound.h --------------------------------------------------------------------------------
-- enum class RaceCountdownCue { count,go }: "count" | "go" (nil: std::nullopt)
RS.RaceCountdownAudio = class(function() return { last_second = 0, counted = false, started = false } end)
function RS.RaceCountdownAudio:update(phase, remaining)
    if phase == "setup" then
        self.last_second = 0; self.counted = false; self.started = false -- *this={}
        return nil
    end
    if phase == "countdown" then
        local seconds = (remaining + 999) // 1000
        if seconds >= 1 and seconds <= 3 and (self.last_second == 0 or seconds < self.last_second) then
            self.last_second = seconds; self.counted = true
            return "count"
        end
    end
    if phase == "playing" and not self.started then
        self.started = true
        if self.counted then return "go" end
    end
    return nil
end

-- enum class RaceGateCue { none,required,finish }: "none" | "required" | "finish"
function RS.race_gate_cue(route, before, after)
    if before < 0 or after <= before or #route.points == 0 then return "none" end
    if after >= #route.points then return "finish" end
    return if mandatory_gates(route, after) > mandatory_gates(route, before) then "required" else "none"
end
-- Observe authoritative progress even after the final gate changes Playing to
-- Results. Gameplay-only checkpoint polling cannot see a solo race's finish.
RS.RaceProgressAudio = class(function() return { heard = 0 } end)
function RS.RaceProgressAudio:update(route, phase, score, out)
    if phase == "setup" or phase == "countdown" then self.heard = 0; return "none" end
    if out or score <= self.heard then return "none" end
    local cue = RS.race_gate_cue(route, self.heard, score)
    self.heard = score
    return cue
end

return RS
