-- Checks of Road Rash's rules, run by `roadrash test` (and by dingosdk_plugin_tests, without the game).
local rules = require("rules")

local checks = {}
local function check(title, fn) table.insert(checks, {title = title, fn = fn}) end
local function near(a, b) return math.abs(a - b) < 1e-5 end
local function levels(tally)
    local out = {}
    for _, part in rules.parts do table.insert(out, tally.levels[part]) end
    return table.concat(out, " ")
end

check("a fall is on the side whose limbs took three fifths of it", function()
    assert(rules.side(10, 2) == "left" and rules.side(2, 10) == "right")
    assert(rules.side(6, 4) == "left" and rules.side(4, 6) == "right")
    assert(rules.side(5, 5) == "both" and rules.side(5.5, 4.5) == "both")
end)
check("a fall the limbs hardly felt is on both", function()
    assert(rules.side(1.5, 0) == "both" and rules.side(0, 0) == "both")
    assert(rules.side(0 / 0, 1) == "both", "not a number")
end)
check("the leg of the side that took more marks at 10, 14 and 20 bails", function()
    for bails, level in {[9] = 0, [10] = 1, [13] = 1, [14] = 2, [19] = 2, [20] = 3, [100] = 3} do
        assert(rules.level_for("left_leg", bails, true) == level, bails .. " bails")
        assert(rules.level_for("right_leg", bails, false) == level, bails .. " bails on the right")
    end
end)
check("its arm one bail behind, the other side four behind", function()
    assert(rules.level_for("left_arm", 10, true) == 0 and rules.level_for("left_arm", 11, true) == 1)
    assert(rules.level_for("left_arm", 15, true) == 2 and rules.level_for("left_arm", 21, true) == 3)
    assert(rules.level_for("right_leg", 13, true) == 0 and rules.level_for("right_leg", 14, true) == 1)
    assert(rules.level_for("right_leg", 24, true) == 3)
    assert(rules.level_for("right_arm", 14, true) == 0 and rules.level_for("right_arm", 15, true) == 1)
    assert(rules.level_for("right_arm", 25, true) == 3 and rules.level_for("left_arm", 25, false) == 3)
end)
check("the face from 20 and 24", function()
    for bails, level in {[19] = 0, [20] = 1, [23] = 1, [24] = 2, [60] = 2} do
        assert(rules.level_for("face", bails, true) == level and rules.level_for("face", bails, false) == level, bails .. " bails")
    end
end)
check("bails are counted on their side, and a mark never gets smaller", function()
    local tally = rules.tally()
    for _ = 1, 9 do assert(not rules.count(tally, "right")) end
    assert(rules.count(tally, "right"), "the tenth marks the right leg")
    assert(levels(tally) == "0 0 1 0 0", levels(tally))
    -- Now the left takes more: its leg is marked, and the right keeps what it has.
    for _ = 1, 12 do rules.count(tally, "left") end
    assert(tally.left == 12 and tally.right == 10 and rules.left_first(tally))
    assert(levels(tally) == "3 3 2 2 1", levels(tally))
end)
check("a fall on both counts half on each side, and the last one-sided fall breaks a tie", function()
    local tally = rules.tally()
    rules.count(tally, "left")
    rules.count(tally, "right")
    rules.count(tally, "both")
    assert(tally.left == 1.5 and tally.right == 1.5 and not rules.left_first(tally), "the right was last")
    rules.count(tally, "left")
    rules.count(tally, "right")
    rules.count(tally, "left")
    rules.count(tally, "right")
    assert(not rules.left_first(tally))
    rules.count(tally, "both")
    assert(rules.left_first(tally) == false)
end)
check("bails 20 puts the right side first, half on each", function()
    local tally = rules.counted(20)
    assert(tally.bails == 20 and tally.left == 10 and tally.right == 10)
    assert(levels(tally) == "2 2 3 2 1", levels(tally))
    assert(levels(rules.counted(0)) == "0 0 0 0 0")
end)
check("items are roadrash_<set>_<design><level>, the worst dry or with blood", function()
    assert(rules.item_name("left_leg", false, 1, 1, true) == "roadrash_leg_1")
    assert(rules.item_name("right_leg", true, 2, 3, true) == "roadrash_legr_b_3_blood")
    assert(rules.item_name("right_leg", false, 2, 2, true) == "roadrash_leg_b_2")
    assert(rules.item_name("left_arm", false, 1, 3, false) == "roadrash_arm_3_dry")
    assert(rules.item_name("face", false, 3, 2, false) == "roadrash_face_c_2_dry")
    assert(rules.item_name("face", false, 1, 1, true) == "roadrash_face_1")
end)
check("a missing item falls back to the first design, the unmirrored set, then a lower level", function()
    local installed = {roadrash_leg_2 = true, roadrash_leg_b_1 = true, roadrash_face_2_dry = true}
    local function find(name) return installed[name] and ("Pack/" .. name) or nil end
    local item, at = rules.wanted("right_leg", 3, 3, true, find)
    assert(item == "Pack/roadrash_leg_2" and at == 2, tostring(item))
    item, at = rules.wanted("left_leg", 1, 2, true, find)
    assert(item == "Pack/roadrash_leg_b_1" and at == 1, tostring(item))
    assert(rules.wanted("face", 2, 1, false, find) == "Pack/roadrash_face_2_dry")
    assert(rules.wanted("face", 2, 1, true, find) == nil, "no bloody face installed, and level 1 is missing too")
    assert(rules.wanted("left_arm", 3, 1, true, find) == nil)
end)
check("a limb's decal sits at its kneecap or elbow, mirrored on the right", function()
    local p = rules.placement("left_leg", 1)
    assert(#p == 5 and near(p[1], 0.37) and near(p[2], 0.59) and near(p[3], 20 / 76) and p[4] == 0.5 and p[5] == 0.5)
    p = rules.placement("right_leg", 3)
    assert(near(p[1], 0.63) and near(p[2], 0.59 - 7 * 0.01073) and near(p[3], 38 / 76))
    p = rules.placement("left_arm", 2)
    assert(near(p[1], 0.635) and near(p[2], 0.505 - 3 * 0.01192) and near(p[3], 24 / 51))
    p = rules.placement("right_arm", 3)
    assert(near(p[1], 0.365) and near(p[2], 0.505 - 16 * 0.01192) and near(p[3], 46 / 51))
    assert(near(rules.placement("left_leg", 9)[3], 38 / 76), "levels past the worst are the worst")
end)

local tests = {}
-- The number that passed, and a line for each that failed.
function tests.run()
    local passed, failures = 0, {}
    for _, c in checks do
        local ok, why = pcall(c.fn)
        if ok then passed += 1 else table.insert(failures, c.title .. ": " .. tostring(why)) end
    end
    return passed, failures
end
return tests
