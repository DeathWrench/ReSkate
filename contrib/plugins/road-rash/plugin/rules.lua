-- Road Rash's rules, apart from the game: which side of the body a fall hit, how many bails it
-- takes for a part's marks to show and to get worse, what the items that draw them are called and
-- where on a limb they sit. Plain data and pure functions (tests.lua checks them).
local rules = {}

-- Where marks can sit: the skater has one tattoo layer per arm and leg, and one moles layer on the face.
rules.parts = {"left_leg", "left_arm", "right_leg", "right_arm", "face"}
rules.names = {left_leg = "left leg", left_arm = "left arm", right_leg = "right leg", right_arm = "right arm", face = "face"}
-- The recipe slot each part's item goes into.
rules.slots = {left_leg = "tattoo_legl", left_arm = "tattoo_arml", right_leg = "tattoo_legr", right_arm = "tattoo_armr", face = "moles"}

local function leg(part) return part == "left_leg" or part == "right_leg" end
local function left(part) return part == "left_leg" or part == "left_arm" end

-- A limb's marks have three levels, the face's two.
local worst_limb, worst_face = 3, 2
function rules.worst(part) return part == "face" and worst_face or worst_limb end
-- The bails it takes for the first marks, the bigger ones and the worst ones.
rules.steps = {10, 14, 20}
-- The face follows the worst level of the limbs, and gets worse four bails later.
local face_later = 4
-- How many bails after the leg of the side that took more falls a limb follows: that side's arm,
-- then the other side's leg and arm.
local arm_later, other_side_later = 1, 4

-- ---- a fall --------------------------------------------------------------------------------

-- The side that took a fall, from how hard the limbs of each side hit something (bail_end's left
-- and right): the one whose limbs took three fifths of it or more. A fall the limbs hardly felt,
-- or felt alike, is on both.
function rules.side(left_hits, right_hits)
    local total = left_hits + right_hits
    if not (total >= 2) then return "both" end
    local share = left_hits / total
    return share >= 0.6 and "left" or share <= 0.4 and "right" or "both"
end

-- ---- the session ---------------------------------------------------------------------------

-- The level `bails` give a part, when the left (or the right) side took more of them.
function rules.level_for(part, bails, left_first)
    local steps = rules.steps
    if part == "face" then
        return bails >= steps[3] + face_later and 2 or bails >= steps[3] and 1 or 0
    end
    local later = (left(part) == left_first and 0 or other_side_later) + (leg(part) and 0 or arm_later)
    if bails < later then return 0 end
    local count = bails - later
    return count >= steps[3] and 3 or count >= steps[2] and 2 or count >= steps[1] and 1 or 0
end

-- Bails counted since the skater was last clean, and the marks they left. A mark never gets
-- smaller: only healing takes it off.
function rules.tally()
    local levels = {}
    for _, part in rules.parts do levels[part] = 0 end
    -- left, right: falls on each side; one on both counts half for each. last_left: the side of
    -- the last one-sided fall, which breaks a tie.
    return {bails = 0, left = 0, right = 0, last_left = false, levels = levels}
end
function rules.left_first(tally)
    return tally.left > tally.right or (tally.left == tally.right and tally.last_left)
end
-- Raises each part to the level the count gives it; true when one changed.
function rules.grow(tally)
    local first, changed = rules.left_first(tally), false
    for _, part in rules.parts do
        local level = math.max(tally.levels[part], rules.level_for(part, tally.bails, first))
        changed = changed or level ~= tally.levels[part]
        tally.levels[part] = level
    end
    return changed
end
-- One more bail, on "left", "right" or "both"; true when a mark changed.
function rules.count(tally, side)
    tally.bails += 1
    if side == "both" then
        tally.left += 0.5
        tally.right += 0.5
    else
        if side == "left" then tally.left += 1 else tally.right += 1 end
        tally.last_left = side == "left"
    end
    return rules.grow(tally)
end
-- A tally as if the skater had bailed `bails` times, half of them on each side.
function rules.counted(bails)
    local tally = rules.tally()
    tally.bails = bails
    tally.left, tally.right = bails / 2, bails / 2
    rules.grow(tally)
    return tally
end
-- "left leg 1, left arm 0, ..."
function rules.describe(tally)
    local out = {}
    for _, part in rules.parts do table.insert(out, rules.names[part] .. " " .. tally.levels[part]) end
    return table.concat(out, ", ")
end

-- ---- the items -----------------------------------------------------------------------------

-- The marks are cosmetic items of a content mod: tattoo items for the limbs, moles items for the
-- face, found by the end of their names: RoadRash_<Set>_[<design>_]<level>[_Dry|_Blood].
--   Set     Leg, Arm, Face; LegR is the left leg's set mirrored, for the right leg: a decal sits
--           on a limb like a sticker read from the front, so only a mirrored one puts the marks
--           of the left leg's outer side on the right leg's outer side.
--   design  nothing for the first, B_ and C_ for the others: each part wears one design for as
--           long as its marks last.
--   level   1 .. the part's worst; the worst comes dry (scabs) and with fresh blood.
rules.designs = {"", "b_", "c_"}
-- In lower case. `mirrored` asks for the right leg's own set; `design` is 1 to 3.
function rules.item_name(part, mirrored, design, level, blood)
    local set = part == "face" and "face_" or not leg(part) and "arm_" or mirrored and "legr_" or "leg_"
    local name = "roadrash_" .. set .. (rules.designs[design] or "") .. level
    if level >= rules.worst(part) then name ..= blood and "_blood" or "_dry" end
    return name
end
-- The item a part wears at a level: of its own design or else the first, from its own set or else
-- the unmirrored one, at that level or else the nearest lower one that is installed. `find` turns
-- a name's ending into the installed item, or nil. Returns the item and the level it is of.
function rules.wanted(part, level, design, blood, find)
    for at = level, 1, -1 do
        for _, d in {design, 1} do
            for _, mirrored in {part == "right_leg", false} do
                local found = find(rules.item_name(part, mirrored, d, at, blood))
                if found then return found, at end
            end
        end
    end
    return nil, 0
end

-- ---- where a limb's decal goes -------------------------------------------------------------

-- A tattoo slot places its item with five numbers: x across and y up the limb's piece of the
-- body's tattoo layout (0..1), its size, its turn (0.5 is upright) and one unused.
-- The middle of the kneecap or the point of the elbow on a left limb (the right one mirrors x),
-- how much y changes per centimetre down the limb, and how many centimetres a size of 1 covers.
local leg_spot = {x = 0.37, y = 0.59, y_per_cm = 0.01073, cm_per_size = 76}
local arm_spot = {x = 0.635, y = 0.505, y_per_cm = 0.01192, cm_per_size = 51}
-- A level's picture covers `side` centimetres with its centre `down` centimetres below that point.
local leg_cuts = {{side = 20, down = 0}, {side = 27, down = 2}, {side = 38, down = 7}}
local arm_cuts = {{side = 16, down = 0}, {side = 24, down = 3}, {side = 46, down = 16}}
function rules.placement(part, level)
    local spot = leg(part) and leg_spot or arm_spot
    local cut = (leg(part) and leg_cuts or arm_cuts)[math.clamp(level, 1, worst_limb)]
    return {left(part) and spot.x or 1 - spot.x, spot.y - cut.down * spot.y_per_cm, cut.side / spot.cm_per_size, 0.5, 0.5}
end

return rules
