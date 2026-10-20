-- race_group_reconciliation.h: which checkpoint groups must be rebuilt. Groups are 0-based numbers,
-- as in the C++; a std::set<unsigned> is a table keyed by the group (values true); a span is a list.
local RGR = {}

-- Each native tutorial checkpoint owns four mesh entities. A Destroy callback
-- can run inside creation, so incomplete groups must also drive reconciliation.
function RGR.pending_checkpoint_groups(dirty, live_parts, expected_parts)
    expected_parts = expected_parts or {}
    local pending = {}
    for group in pairs(dirty) do pending[group] = true end
    for i = 0, #live_parts - 1 do
        local expected = if i < #expected_parts then expected_parts[i + 1] else 4
        if live_parts[i + 1] ~= expected then pending[i] = true end
    end
    return pending
end

function RGR.take_checkpoint_groups(dirty, live_parts, expected_parts)
    -- Consume only the marks that precede this rebuild. Callbacks raised by
    -- the rebuild remain in dirty for the next tick, even for the same group.
    local taken = {}
    for group in pairs(dirty) do taken[group] = true end
    table.clear(dirty) -- taken.swap(dirty): the caller's set is left empty
    return RGR.pending_checkpoint_groups(taken, live_parts, expected_parts)
end

return RGR
