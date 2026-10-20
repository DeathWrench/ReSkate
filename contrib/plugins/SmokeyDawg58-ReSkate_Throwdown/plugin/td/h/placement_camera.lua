-- SmokeyDawg58's placement_camera.h (HIS/Modes/placement_camera.h), line for line.
local PC = {}

-- ---- helpers -------------------------------------------------------------------------------------
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

-- ---- placement_camera.h --------------------------------------------------------------------------
-- A native camera request can be rejected while flag placement is closing.
-- Keep asking until the live camera acknowledges it, and drain a late enable
-- on exit. A camera already active before the editor remains the user's own.
-- sent_: std::optional<std::uint64_t>, nil when empty.
PC.PlacementCamera = class(function()
    return { requested_ = false, owned_ = false, release_until_ = 0, sent_ = nil }
end)
-- Returns true/false to request, or nil (std::nullopt) for nothing to send.
function PC.PlacementCamera:update(requested, active, now)
    if requested ~= self.requested_ then
        self.requested_ = requested
        self.sent_ = nil
        if not requested and self.owned_ then self.release_until_ = now + 1600 end
    end
    if requested and not self.owned_ and not active then self.owned_ = true end
    if not self.owned_ then return nil end
    if requested and active then return nil end
    if not requested and not active and now >= self.release_until_ then
        self.owned_ = false
        self.sent_ = nil
        return nil
    end
    if self.sent_ ~= nil and now >= self.sent_ and now - self.sent_ < 400 then return nil end
    self.sent_ = now
    return requested
end

return PC
