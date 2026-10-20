-- SmokeyDawg58's mode_announcements.h (HIS/Modes/mode_announcements.h), line for line.
-- Modes are their key strings, phases strings.
local MA = {}

-- ---- helpers -------------------------------------------------------------------------------------
local R = require("td/rules")
local timed = R.timed
-- mode_rules.h's mode_name(Mode) (td/rules.lua); "" for a word that names no mode.
local function mode_name(mode)
    local m = R.parse_mode(mode)
    return if m then R.mode_name(m) else ""
end
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

-- ---- mode_announcements.h ------------------------------------------------------------------------
function MA.match_time(ms)
    return string.format("%02d:%02d.%03d", ms // 60000, (ms // 1000) % 60, ms % 1000)
end

MA.MatchAnnouncements = class(function() return { started = false, ended = false, playing_at = 0 } end)
-- Returns the announcement, or nil.
function MA.MatchAnnouncements:observe(host, settings, state, now)
    if not self.started and (state.phase == "countdown" or state.phase == "playing") then
        self.started = true
        self.playing_at = now + (if state.phase == "countdown" then state.remaining_ms else 0)
        local timer = if timed(settings.mode) then settings.duration_s else settings.turn_s
        return string.format("%s has started %s (%s).", host, mode_name(settings.mode), MA.match_time(timer * 1000))
    end
    if self.started and not self.ended and state.phase == "results" then
        self.ended = true
        local elapsed = if now > self.playing_at then now - self.playing_at else 0
        if timed(settings.mode) then elapsed = math.min(elapsed, settings.duration_s * 1000) end
        if settings.mode == "race" and #state.standings > 0 then
            local first = state.standings[1]
            if not first.out and first.aux >= 0 and first.score >= #settings.points then elapsed = first.aux end
        end
        return string.format("%s has ended %s (%s).", host, mode_name(settings.mode), MA.match_time(elapsed))
    end
    return nil
end

return MA
