-- SmokeyDawg58's race_momentum.h (HIS/Modes/race_momentum.h), line for line.
-- RaceRecoveryDelivery is the skater push service (core M.recovery, reskate.skater.push). Vec3 is a Luau vector.
-- `until` is a Luau keyword: his members of that name are self["until"].
local RM = {}

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

-- ---- race_momentum.h -----------------------------------------------------------------------------
-- Unknown samples during a fall must not rearm its edge. A real return to
-- riding/walking rearms it so a second fast fall gets its own recovery.
RM.RagdollBailEdge = class(function() return { falling = false } end)
function RM.RagdollBailEdge:observe(known, ragdoll)
    if not known then return false end
    local began = ragdoll and not self.falling
    self.falling = ragdoll
    return began
end

-- The physics publisher counts native runout edges, even if their short pulse
-- ends between mode ticks. Establish a baseline before consuming later events.
-- seen: std::optional<std::uint64_t>, nil when empty.
RM.RaceRunoutWatch = class(function() return { seen = nil } end)
function RM.RaceRunoutWatch:observe(valid, count)
    if self.seen == nil then
        if valid then self.seen = count end
        return false
    end
    local changed = self.seen ~= count
    self.seen = count
    return changed
end

-- Hippy jumps and walking share offboard states in the 500 range. Riding/air -> offboard
-- transition followed by upward motion identifies the jump; state alone
-- cannot distinguish it from an accidental loss of the board.
RM.RaceHippyJump = class(function()
    return {
        candidate_until = 0, jump_until = 0, landed_until = 0, board_until = 0, intent_until = 0,
        input_down = false, last = 0,
    }
end)
function RM.RaceHippyJump:input(down, board, now)
    if down and not self.input_down and board then self.intent_until = now + 600 end
    self.input_down = down
end
function RM.RaceHippyJump:taking_off(now) return now < self.intent_until or self:active(now) end
function RM.RaceHippyJump:observe(valid, state, previous, vertical, bail, now, airborne)
    airborne = airborne or false
    if bail then
        self.candidate_until = 0; self.jump_until = 0; self.landed_until = 0; self.board_until = 0
        self.intent_until = 0; self.last = state
        return false
    end
    -- A missing sample must not turn an intentional jump into board loss.
    -- Keep its existing deadline; do not grant or extend immunity here.
    if not valid or not finite(vertical) then return self:active(now) end
    local board, offboard = state >= 100 and state < 300, state >= 500 and state < 700
    if board then self.board_until = now + 350 end
    if state ~= self.last then
        self.candidate_until = if offboard and ((previous >= 100 and previous < 300) or now < self.board_until)
            then now + 350 else 0
        if not offboard then
            if self.jump_until ~= 0 and now < self.jump_until and state < 300 then self.landed_until = now + 750 end
            self.jump_until = 0
        end
        self.last = state
    end
    if offboard and ((now < self.intent_until) or (self.candidate_until ~= 0 and now <= self.candidate_until and
        (vertical > .2 or (airborne and vertical >= -1.5)))) then
        self.jump_until = now + 4000; self.candidate_until = 0; self.intent_until = 0
    end
    if not offboard or now >= self.jump_until then self.jump_until = 0 end
    return self.jump_until ~= 0 or (state < 300 and now < self.landed_until)
end
function RM.RaceHippyJump:active(now) return now < self.jump_until or now < self.landed_until end

-- The offboard animation flag can pulse at a hippy takeoff. A native 300
-- state/counter is immediate; this secondary flag must persist to prove a bail.
-- since: std::optional<std::uint64_t>, nil when empty.
RM.RaceOffboardRagdoll = class(function() return { since = nil, reported = false } end)
function RM.RaceOffboardRagdoll:reset() self.since = nil; self.reported = false end
function RM.RaceOffboardRagdoll:active() return self.reported end
function RM.RaceOffboardRagdoll:observe(known, ragdoll, now)
    if not known then return false end
    if not ragdoll then self.since = nil; self.reported = false; return false end
    if self.since == nil then self.since = now end
    if self.reported or now < self.since or now - self.since < 250 then return false end
    self.reported = true
    return true
end

RM.RaceRecoveryGrace = class(function() return { ["until"] = 0, full_bail = false } end)
function RM.RaceRecoveryGrace:reset() self["until"] = 0; self.full_bail = false end
function RM.RaceRecoveryGrace:cancel_runout() if not self.full_bail then self:reset() end end
function RM.RaceRecoveryGrace:pending() return self["until"] ~= 0 end
function RM.RaceRecoveryGrace:waiting(now) return self["until"] ~= 0 and now <= self["until"] end
function RM.RaceRecoveryGrace:ready(now) return self["until"] ~= 0 and now >= self["until"] end
function RM.RaceRecoveryGrace:observe(bail, runout, now)
    if not bail and not runout then return false end
    if self["until"] == 0 then self.full_bail = bail; self["until"] = now + 1000; return true end
    -- The same fall may acquire a stronger native signal. Preserve its
    -- original one-second deadline instead of restarting the wait.
    if bail then self.full_bail = true end
    return false
end

-- A native return to controlled board/on-foot physics ends an ordinary bail.
-- Offboard alone is never an automatic-recovery request.
function RM.race_recovered_control(valid, physics, ragdoll_known, ragdoll)
    if not valid or (ragdoll_known and ragdoll) then return false end
    return (physics >= 100 and physics < 300) or (physics >= 500 and physics < 700 and ragdoll_known)
end
-- Walking, jumping and getting back on the board can clear a gate. A
-- confirmed ragdoll retains the finish-only one-second bail grace.
function RM.race_offboard_progress(skater, state, hippy)
    hippy = hippy or false
    return hippy or (skater and state >= 500 and state < 700)
end
-- Only restore measured horizontal motion. This is a safety ceiling for bad
-- telemetry, not a recovery boost or the speed assigned to a stopped rider.
RM.max_race_recovery_speed = 120
local max_race_recovery_speed = RM.max_race_recovery_speed
function RM.valid_race_recovery_velocity(velocity)
    return finite(velocity.x) and finite(velocity.y) and finite(velocity.z) and velocity.y == 0 and
        math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z) <= max_race_recovery_speed + .001
end

-- samples: list of {first = time, second = speed}; offboard_speed: nil when empty.
RM.RaceMomentum = class(function() return { samples = {}, sample_after = 0, offboard_speed = nil } end)
function RM.RaceMomentum:suspend_until(until_) self.sample_after = until_ end
function RM.RaceMomentum:observe_onboard(onboard, speed, now)
    if now < self.sample_after then return end
    if not onboard then
        if self.offboard_speed == nil then self.offboard_speed = self:before_bail(now) end
        return
    end
    if not finite(speed) or speed < 0 or speed > max_race_recovery_speed then return end
    if self.offboard_speed ~= nil then self.offboard_speed = nil; table.clear(self.samples) end
    self:observe(speed, now)
end
function RM.RaceMomentum:observe(speed, now)
    if now < self.sample_after then return end
    local samples = self.samples
    if #samples > 0 and now < samples[#samples].first then table.clear(samples) end
    while #samples > 0 and now - samples[1].first > 750 do table.remove(samples, 1) end
    if finite(speed) and speed >= 0 and speed <= max_race_recovery_speed then
        table.insert(samples, { first = now, second = speed })
    end
end
function RM.RaceMomentum:before_bail(now)
    if self.offboard_speed ~= nil then return self.offboard_speed end
    local speed, recent = 0, 0
    -- A collision can report zero before the bail state changes. Retain
    -- the approach velocity for this short detection window only.
    for _, sample in ipairs(self.samples) do
        local at, value = sample.first, sample.second
        if now >= at and now - at <= 750 then
            if value > 0 then speed = value end
            if now - at <= 250 then recent = math.max(recent, value) end
        end
    end
    return if recent > 0 then recent else speed
end
function RM.RaceMomentum:current(now)
    if self.offboard_speed ~= nil then return self.offboard_speed end
    local samples = self.samples
    if #samples == 0 or now < samples[#samples].first or now - samples[#samples].first > 250 then return 0 end
    return samples[#samples].second
end

-- Repeated returns must never raise the first trusted approach-speed budget.
-- A clean riding interval or genuine new checkpoint starts another budget.
-- ceiling: std::optional<float>, nil when empty.
RM.RaceRecoverySpeedGuard = class(function() return { ceiling = nil, ["until"] = 0 } end)
function RM.RaceRecoverySpeedGuard:limit(measured, now)
    if not finite(measured) or measured < 0 then measured = 0 end
    measured = math.min(measured, max_race_recovery_speed)
    if self.ceiling ~= nil and now < self["until"] then measured = math.min(measured, self.ceiling) end
    self.ceiling = measured; self["until"] = now + 3000
    return measured
end
function RM.RaceRecoverySpeedGuard:completed(now) if self.ceiling ~= nil then self["until"] = now + 3000 end end
function RM.RaceRecoverySpeedGuard:reset() self.ceiling = nil; self["until"] = 0 end

function RM.race_recovery_motion(speed, yaw)
    if not finite(speed) or speed < 0 or speed > max_race_recovery_speed or not finite(yaw) then return vector.zero end
    local angle = yaw * 3.14159265 / 180
    return vector.create(math.sin(angle) * speed, 0, math.cos(angle) * speed)
end

-- RaceRecoveryDelivery: not ported, it is the skater push service (core M.recovery("request" | "wait" | "reset"), reskate.skater.push).

return RM
