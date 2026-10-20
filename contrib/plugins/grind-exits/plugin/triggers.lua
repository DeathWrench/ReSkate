-- The triggers, as grind exits reads them each tick: which one picks the side of the next pop out of
-- a grind, and which the game must not see. No game access.
--
--   - A trigger pressed DURING a grind, or up to `prewindow` seconds before the grind connects, is
--     "claimed": it picks the side of the next pop. Both claimed: the game's own exit.
--   - A claimed trigger let go shortly before the pop still counts (release_grace_ms).
--   - Grab guard: a claimed trigger is kept from the game until it is let go, so holding it through
--     the pop does not start a grab; pressed again in the air, it grabs.
--   - Lean guard: while a claimed trigger is held, the left stick's left/right is kept from the game
--     while the skater grinds (ReSkate gives it back at the pop), so the game's own lean exit cannot
--     start and pull the board the other way.
local triggers = {}

triggers.press_level, triggers.release_level = 0.4, 0.2 -- of a full pull: about 40 % in, 20 % out
triggers.release_grace_ms = 100

function triggers.new()
    return {
        sides = {lt = {pressed = false, claimed = false, pressed_at = -math.huge, released = -math.huge},
                 rt = {pressed = false, claimed = false, pressed_at = -math.huge, released = -math.huge}},
        grinding = false,
        grind_start = -math.huge,
    }
end

-- One tick at `now` (ms): the pad's triggers (0 to 1, nil without a pad) and whether the skater grinds.
function triggers.step(state, now, lt, rt, grinding, prewindow_ms)
    if grinding and not state.grinding then state.grind_start = now end
    state.grinding = grinding
    local window_start = state.grind_start - (prewindow_ms or 1000)
    for side, value in {lt = lt or 0, rt = rt or 0} do
        local t = state.sides[side]
        if not t.pressed and value >= triggers.press_level then
            t.pressed = true
            t.pressed_at = now
            if grinding then t.claimed = true end
        elseif t.pressed and value <= triggers.release_level then
            t.pressed = false
            if t.claimed then
                t.claimed = false
                t.released = now
            end
        end
        -- Pressed a moment before the grind connected: it counts too.
        if grinding and t.pressed and not t.claimed and t.pressed_at >= window_start then t.claimed = true end
    end
end

-- The trigger that picks the side now: "lt", "rt", or nil (none, or both).
function triggers.chosen(state, now)
    local lt, rt = state.sides.lt, state.sides.rt
    if lt.claimed and rt.claimed then return nil end
    if lt.claimed or rt.claimed then return lt.claimed and "lt" or "rt" end
    local recent_lt = now - lt.released < triggers.release_grace_ms
    local recent_rt = now - rt.released < triggers.release_grace_ms
    if recent_lt and recent_rt then return nil end
    if recent_lt or recent_rt then return recent_lt and "lt" or "rt" end
    return nil
end

-- What the game is kept from: each claimed trigger (with the grab guard), and the left stick's
-- left/right while grinding (with the lean guard) while any is claimed.
function triggers.hidden(state, guard, lean_guard)
    local lt, rt = state.sides.lt.claimed, state.sides.rt.claimed
    return {left_trigger = guard and lt, right_trigger = guard and rt, left_x = lean_guard and (lt or rt) and "grinding" or nil}
end

-- The side a trigger asks for: toe/heel (LT the toe side, RT the heel side) or left/right of travel.
function triggers.side(trigger, toe_heel)
    if toe_heel then return trigger == "lt" and "toe" or "heel" end
    return trigger == "lt" and "left" or "right"
end

return triggers
