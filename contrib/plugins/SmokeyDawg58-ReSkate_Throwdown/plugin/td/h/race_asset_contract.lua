-- race_asset_contract.h: the checkpoint world's lifetime across level transitions.
local RAC = {}

local CheckpointWorldLifetime = {}
CheckpointWorldLifetime.__index = CheckpointWorldLifetime
RAC.CheckpointWorldLifetime = CheckpointWorldLifetime

function CheckpointWorldLifetime.new()
    return setmetatable({blocked_ = true, shutdown_ = false, retired_game_ = 0}, CheckpointWorldLifetime)
end
function CheckpointWorldLifetime.copy(x)
    return setmetatable({blocked_ = x.blocked_, shutdown_ = x.shutdown_, retired_game_ = x.retired_game_}, CheckpointWorldLifetime)
end
function CheckpointWorldLifetime:blocked()
    return self.blocked_
end
function CheckpointWorldLifetime:can_publish(game)
    return not self.blocked_ and game ~= nil and game ~= 0 and game ~= self.retired_game_
end
function CheckpointWorldLifetime:before_transition(next, current_game)
    if next == 13 or next == 21 then
        if not self.shutdown_ then self.blocked_ = false end
        return false
    end
    if next ~= 14 and next ~= 22 and next ~= 3 and next ~= 24 then return false end
    local release = not self.blocked_
    self.blocked_ = true
    if current_game ~= nil and current_game ~= 0 then self.retired_game_ = current_game end
    if next == 24 then self.shutdown_ = true end
    return release
end

-- PORT: checkpoint_blueprint(asset, base, read) and checkpoint_resident(cached, resolved, base, read)
-- walk native type pointers (ObjectBlueprint's type chain) and compare cached asset pointers. A
-- plugin holds no pointers: reskate.entities resolves each blueprint by name and makes the same
-- checks itself (Extension/World/world_entities_contract.h object_blueprint / object_resident).
-- Its result is reskate.entities.status(id): "missing" where these returned false.

return RAC
