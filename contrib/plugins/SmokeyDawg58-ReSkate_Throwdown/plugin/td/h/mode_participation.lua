-- SmokeyDawg58's mode_participation.h (HIS/Modes/mode_participation.h), line for line.
-- Ids are strings. `local` is a Luau keyword: that argument is local_id.
local MP = {}

-- ---- mode_participation.h ------------------------------------------------------------------------
-- Message::Kind: "end" | "leave".
function MP.local_quit_kind(leader) return if leader then "end" else "leave" end
-- Restrict tools only while this player can still affect the result. Their
-- saved settings/bindings are never edited by a temporary competition lease.
function MP.local_competition_active(settings, state, local_id)
    if state.phase ~= "countdown" and state.phase ~= "playing" then return false end
    local player = nil
    for _, row in ipairs(state.standings) do
        if row.player == local_id then player = row; break end
    end
    if player == nil or player.out then return false end
    return settings.mode ~= "race" or player.score < #settings.points
end

return MP
