-- How a board wears and how hard it has to be hit to break, apart from the game: the player's
-- settings, the damage each kind of hit does, and what kind of contact a board makes with a rail.
-- Plain numbers, so the tests can hold them. (Ported from ReSkate's
-- Extension/BoardBreak/board_break_feel.h.)
local model = require("model")
local feel = {}

-- ---- the player's settings -----------------------------------------------------------------------
-- Kept in reskate.storage, each set from the console as `boardbreak <name> <value>` and from the menu.
--   always       every slam breaks the board, for replay clips
--   sensitivity  percent: at 200 half the force breaks a board, at 50 twice as much
--   joined       percent of breaks the grip tape holds together
--   rails        a hard boardslide or darkslide onto a rail or ledge can break it
--   wear         boards wear out and break more easily as they do
--   wearrate     percent: how fast they wear
--   cracks       the crack sound of a break
--   bodysounds   the body's hits during a bail
feel.sensitivity_min, feel.sensitivity_max, feel.rate_min, feel.rate_max = 10, 400, 0, 500
feel.settings = {
    {name = "always", on_off = true, low = 0, high = 1, default = 0},
    {name = "sensitivity", on_off = false, low = feel.sensitivity_min, high = feel.sensitivity_max, default = 100},
    {name = "joined", on_off = false, low = 0, high = 100, default = 50},
    {name = "rails", on_off = true, low = 0, high = 1, default = 1},
    {name = "wear", on_off = true, low = 0, high = 1, default = 1},
    {name = "wearrate", on_off = false, low = feel.rate_min, high = feel.rate_max, default = 100},
    {name = "cracks", on_off = true, low = 0, high = 1, default = 1},
    {name = "bodysounds", on_off = true, low = 0, high = 1, default = 1},
}
function feel.info(name)
    for _, info in feel.settings do
        if info.name == name then return info end
    end
    return nil
end
-- Every setting at its default, as numbers (on/off as 1/0).
function feel.defaults()
    local out = {}
    for _, info in feel.settings do out[info.name] = info.default end
    return out
end
-- Sets `name` in `values`, kept within its range; false for no such setting or no number.
function feel.set(values, name, value)
    local info = feel.info(name)
    if not info or type(value) ~= "number" or value ~= value then return false end
    value = math.clamp(math.floor(value + 0.5), info.low, info.high)
    values[name] = value
    return true
end
-- What was kept, read back over the defaults: anything that is not a setting's number is left out.
function feel.load(kept)
    local values = feel.defaults()
    if type(kept) == "table" then
        for name, value in kept do
            if type(name) == "string" then feel.set(values, name, value) end
        end
    end
    return values
end

-- ---- how hard a slam has to be -------------------------------------------------------------------
-- The slam forces measured in play run from about 2 (a stumble) to 10 and more (a hard slam).
feel.heavy_slam = 10
-- A worn board takes less: at the end of its life about half the force it took new.
feel.worn_strength = 0.5
local function sensitivity_of(percent) return math.clamp(percent, feel.sensitivity_min, feel.sensitivity_max) / 100 end
local function strength_of(wear) return 1 - (1 - feel.worn_strength) * math.clamp(wear, 0, 1) end
-- How likely a slam of `force` breaks the board, with the player's sensitivity (percent) and the
-- board's wear (0 new, 1 worn out). A new board at 100%: never under 6, half the time at 8, always
-- from 10. A bail whose force is not known (0) never breaks it.
function feel.slam_chance(force, sensitivity, wear)
    if not (force > 0) then return 0 end
    return model.break_chance(force, feel.heavy_slam * strength_of(wear) / sensitivity_of(sensitivity))
end

-- ---- wear and tear -------------------------------------------------------------------------------
-- A board's wear runs from 0 (new) to 1 (worn out). Every hit adds some, at the player's rate.
-- A landing, by how fast the board was coming down as it touched (m/s): nothing up to an ollie off
-- a curb's speed, then more and more.
feel.landing_free = 3.5
function feel.landing_wear(down_speed)
    local over = math.max(0, down_speed - feel.landing_free)
    return math.min(0.0008 * over * over, 0.04)
end
-- Onto a rail or ledge: the board's own hit, harder on a slide (the deck takes it) than on the trucks.
function feel.rail_wear(down_speed, slide)
    return feel.landing_wear(down_speed + (if slide then 1 else 0)) + (if slide then 0.001 else 0.0003)
end
-- Every second of grinding or sliding.
function feel.grind_wear_per_second(slide) return if slide then 0.0005 else 0.00015 end
-- A slam, by its force.
function feel.slam_wear(force) return math.clamp((force - 4) / 6, 0, 1) * 0.025 end
function feel.add_wear(wear, amount, rate)
    return math.clamp(wear + amount * math.clamp(rate, feel.rate_min, feel.rate_max) / 100, 0, 1)
end
-- What a board's state is called. A board is "done" from `done_wear` on.
feel.done_wear = 0.85
function feel.condition(wear)
    return if wear < 0.15 then "new" elseif wear < 0.4 then "used" elseif wear < 0.65 then "worn" elseif wear < feel.done_wear then "beat" else "done"
end
-- A done board gives way under the rider on a landing (the nose goes, and they ride on): from a
-- big drop (6.5 m/s coming down) as it becomes done, down to any real drop (3.5 m/s) when it is
-- worn right out. Never a board less worn. Sensitivity as for a slam.
function feel.gives_way_on_landing(down_speed, sensitivity, wear)
    if wear < feel.done_wear then return false end
    local t = math.clamp((wear - feel.done_wear) / (1 - feel.done_wear), 0, 1)
    return down_speed >= (6.5 - 3 * t) / sensitivity_of(sensitivity)
end

-- ---- the board on a rail -------------------------------------------------------------------------
-- From the board's long axis and its up axis in the world, and how it moves: a board lying across
-- its way (a boardslide, a lipslide) slides, one on its grip is in a darkslide, the rest grind on
-- their trucks. A board that hardly moves grinds.
function feel.contact_of(along, up, velocity)
    if up.y < -0.35 then return "darkslide" end
    local a, s = math.sqrt(along.x * along.x + along.z * along.z), math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
    if a < 0.2 or s < 0.5 then return "grind" end
    local cosine = math.abs((along.x * velocity.x + along.z * velocity.z) / (a * s))
    return if cosine < 0.5 then "slide" else "grind"
end
-- How likely a board snaps as it comes down onto a rail in a slide, by how fast it was coming down
-- (m/s): from 3 m/s up (a hop onto a rail is about 2), certain 3 m/s above that; a darkslide on the
-- grip goes sooner. Grinds on the trucks do not snap a board. Sensitivity and wear as for a slam.
function feel.rail_chance(down_speed, contact, sensitivity, wear)
    if contact == "grind" then return 0 end
    local s, strength = sensitivity_of(sensitivity), strength_of(wear)
    local start = (if contact == "darkslide" then 2.2 else 3) * strength / s
    local span = 3 * strength / s
    return math.clamp((down_speed - start) / span, 0, 1)
end

-- ---- where a board breaks ------------------------------------------------------------------------
-- From how the board came down: nose first it breaks at the nose, tail first at the tail, flat (or
-- across a rail) in the middle. `slope` is how far the nose points down (-1 to 1); `roll` is 0 to 1,
-- chance. Flat landings still break at an end now and then, as real boards do.
function feel.place_of_break(slope, across_rail, roll)
    if across_rail then return "mid" end
    if slope > 0.35 then return if roll < 0.75 then "nose" else "mid" end
    if slope < -0.35 then return if roll < 0.75 then "tail" else "mid" end
    return if roll < 0.5 then "mid" elseif roll < 0.75 then "nose" else "tail"
end

-- ---- a body's hit, for its sound -----------------------------------------------------------------
-- A graze is 2 to 3 m/s along the contact's normal, a fall on flat ground 3 to 9, a drop from height
-- 13 and more. Below `body_hit` nothing is heard; the loudness rises to full at `body_full`.
feel.body_hit, feel.body_full = 3, 11
function feel.body_loudness(speed)
    if not (speed >= feel.body_hit) then return 0 end
    return math.clamp(0.3 + 0.7 * (speed - feel.body_hit) / (feel.body_full - feel.body_hit), 0.3, 1)
end
return feel
