-- Checks of Board Break, run by `boardbreak test` (and by dingosdk_plugin_tests, without the game):
-- the geometry and the numbers as ReSkate's own Board Break has them (its board_break_tests.cpp),
-- then the rules at play, with a game faked here.
local model = require("model")
local feel = require("feel")
local breaker = require("breaker")
local v = model.vec

local checks = {}
local function check(title, fn) table.insert(checks, {title = title, fn = fn}) end
local function near(a, b, within)
    within = within or 1e-4
    if type(a) == "number" then return math.abs(a - b) < within end
    return model.length(a - b) < within
end
-- Where a point of a part ends up after the part's motion.
local function moved(motion, point) return model.turn(motion.facing, point) + motion.at end
-- The rig's mount: a quarter turn about the upright axis.
local mount = model.about(v(0, 1, 0), 1.5707963)

-- ---- the geometry --------------------------------------------------------------------------------
check("a break leaves two pieces, or one that hangs together", function()
    for _, place in model.places do
        local clean = model.broken_at(place, false)
        assert(clean.hinge == "none" and clean.loose ~= 0, "a clean break has a piece that comes off")
        assert(bit32.bor(clean.kept, clean.loose) == model.whole_board and bit32.band(clean.kept, clean.loose) == 0, "each part once")
        local joined = model.broken_at(place, true)
        assert(joined.kept == model.whole_board and joined.loose == 0 and joined.hinge ~= "none", "held by the grip tape, nothing comes off")
    end
    assert(model.broken_at("nose", false).loose == model.nose and model.broken_at("tail", false).loose == model.tail)
    local halves = model.broken_at("mid", false)
    assert(halves.kept == model.nose + model.front + model.front_truck and halves.loose == model.back + model.tail + model.back_truck)
    assert(model.broken_at("nose", true).hinge == "nose" and model.broken_at("mid", true).hinge == "fold" and model.broken_at("tail", true).hinge == "tail")
end)
check("a harder slam breaks a board more often", function()
    assert(model.break_chance(10, 10) == 1 and model.break_chance(30, 10) == 1)
    assert(model.break_chance(0, 10) == 0 and model.break_chance(6, 10) == 0)
    assert(near(model.break_chance(8, 10), 0.5))
    local before = 0
    for force = 0, 12, 0.5 do
        local chance = model.break_chance(force, 10)
        assert(chance >= before and chance <= 1, "it never falls with more force")
        before = chance
    end
end)
check("the size of a break picks its sound", function()
    assert(model.break_size("mid", false, 0) == "heavy")
    assert(model.break_size("mid", true, 0.9) == "heavy" and model.break_size("mid", true, 0.4) == "medium")
    assert(model.break_size("nose", false, 0) == "medium" and model.break_size("tail", false, 0) == "medium")
    assert(model.break_size("nose", true, 0) == "light" and model.break_size("tail", true, 0) == "light")
end)
local function hidden_stretches()
    local s = {}
    for i = 1, 4 do s[i] = {shown = false, motion = model.rigid()} end
    return s
end
check("a whole board keeps its stretches away", function()
    local bones = model.bones_of(hidden_stretches())
    for i = 1, 3 do assert(near(bones[i].at, model.away), "a stretch that does not show goes far away") end
    assert(near(bones[4].at, v(0, 0, 0)) and near(bones[4].facing[4], 1), "and the tail's goes with the front's")
end)
check("the tail is placed from the front stretch", function()
    local front_motion = model.rigid(model.about(v(1, 0, 0), 0.3), v(0.01, 0.02, -0.03))
    local tail_motion = model.rigid(model.unit(model.mul(model.about(v(0, 1, 0), 1.1), model.about(v(1, 0, 0), -0.4))), v(0.5, -0.2, 0.7))
    for _, front_shown in {true, false} do
        local stretch = hidden_stretches()
        stretch[2] = {shown = front_shown, motion = front_motion}
        stretch[4] = {shown = true, motion = tail_motion}
        local bones = model.bones_of(stretch)
        local parent = if front_shown then front_motion else model.rigid(model.identity(), model.away)
        for _, point in {v(0, 0.09, -0.3), v(0.1, 0.1, -0.4)} do
            assert(near(moved(parent, moved(bones[4], point)), moved(tail_motion, point), 2e-3), "the tail lies where its piece does")
        end
    end
end)
check("a piece shows only its own stretches, and a half tips onto its broken end", function()
    local clean = model.broken_at("mid", false)
    local layout = model.lay_out(clean.kept, clean.hinge, 0, 1, mount)
    local s = layout.stretch
    assert(s[1].shown and s[2].shown and not s[3].shown and not s[4].shown, "the front half is the nose and the front stretch")
    assert(layout.front_truck and not layout.back_truck, "on its front truck")
    assert(near(model.bones_of(s)[3].at, model.away), "and the back stretch is nowhere to be seen")
    local broken_end = moved(s[2].motion, model.turn(mount, v(0, 0.09, model.mid_row)))
    assert(broken_end.y < 0.09 - 0.03, "the half tips onto its broken end")
    local upside_down = model.lay_out(clean.kept, clean.hinge, 0, -1, mount)
    assert(near(upside_down.stretch[2].motion.at, v(0, 0, 0)), "lying on its grip it stays as it is")
end)
check("a folded board meets at the break", function()
    for _, depth in {0.2, 0.6, 1.0} do
        local front_half, back_half = model.folded(depth)
        local grip = v(0, 0.095, model.mid_row)
        local ahead, behind = moved(front_half, grip), moved(back_half, grip)
        assert(near(ahead.y, behind.y, 1e-3), "both halves' grip is at one height at the break")
        assert(near(ahead.z - behind.z, model.crack, 1e-3), "with the crack between them")
        assert(ahead.y < grip.y, "and the break has sagged")
        assert(near(moved(front_half, v(0, model.axle_height, model.front_axle)).y, model.axle_height) and
               near(moved(back_half, v(0, model.axle_height, model.back_axle)).y, model.axle_height), "the axles keep their height")
    end
    local whole = model.lay_out(model.whole_board, "fold", 0.8, 1, mount)
    for _, one in whole.stretch do assert(one.shown, "a folded board shows all four stretches") end
    assert(not near(whole.stretch[2].motion.at, whole.stretch[3].motion.at), "its two halves moved apart")
    assert(near(whole.stretch[1].motion.at, whole.stretch[2].motion.at) and near(whole.stretch[3].motion.at, whole.stretch[4].motion.at))
end)
check("a hanging end turns about the break", function()
    local layout = model.lay_out(model.whole_board, "nose", 0.5, 1, mount)
    for i = 2, 4 do assert(near(layout.stretch[i].motion.at, v(0, 0, 0)), "the rest of the board stays where it is") end
    local tip = moved(layout.stretch[1].motion, model.turn(mount, v(0, 0.14, 0.41)))
    assert(tip.y < 0.14 - 0.05, "and the nose droops")
    local hinge = moved(model.hung_on_grip(model.nose_row, 1, 0.5), v(0, model.grip_height - 0.004, model.nose_row))
    assert(near(hinge, v(0, model.grip_height - 0.004, model.nose_row + model.crack * 0.5)), "about the break line, a hair away")
end)
check("a truck goes with its piece, from under the hidden deck", function()
    local mount_at = v(0, 0.0856, 0)
    local still = model.truck_bone(model.rigid(), mount, mount_at, model.identity(), model.front_truck_place)
    assert(near(still.at + model.deck_away, model.front_truck_place) and near(still.facing[4], 1), "a piece that has not moved leaves its truck")
    assert(model.length(still.at) < 1000, "and reskate.board.set takes it")
    local up = model.truck_bone(model.rigid(nil, v(0, 0.25, 0)), mount, mount_at, model.identity(), model.front_truck_place)
    assert(near(up.at + model.deck_away, model.front_truck_place + v(0, 0.25, 0)), "a piece that is lifted takes its truck up")
end)
check("a baseplate stays on the deck while its truck steers", function()
    for _, rest in {model.back_truck_rest, model.front_truck_rest} do
        local still = model.baseplate_bone(model.rigid(rest.facing, rest.at), rest)
        assert(near(still.at, rest.effector) and near(math.abs(still.facing[4]), 1), "at rest the effector is where the rig has it")
        local bolt = v(0.03, 0.08, rest.at.z + 0.02)
        local on_deck = moved(model.rigid(rest.facing, rest.at), moved(model.rigid(nil, rest.effector), bolt))
        for _, lean in {-0.4, 0.15, 0.6} do
            local steered = model.rigid(model.unit(model.mul(rest.facing, model.about(v(0, 0, 1), lean))), rest.at)
            assert(near(moved(steered, moved(model.baseplate_bone(steered, rest), bolt)), on_deck), "steered, the baseplate has not moved")
        end
    end
end)

-- ---- the numbers ---------------------------------------------------------------------------------
check("the settings keep to their ranges", function()
    local s = feel.defaults()
    assert(feel.set(s, "sensitivity", 9999) and s.sensitivity == feel.sensitivity_max)
    assert(feel.set(s, "always", 5) and s.always == 1)
    assert(feel.set(s, "joined", -3) and s.joined == 0)
    assert(not feel.set(s, "nonsense", 1) and not feel.set(s, "joined", 0 / 0))
    local kept = feel.load({sensitivity = 150, joined = "lots", nonsense = 3})
    assert(kept.sensitivity == 150 and kept.joined == 50 and kept.nonsense == nil, "what was kept is read back, the rest is the default")
end)
check("a worn or touchy board breaks sooner", function()
    assert(feel.slam_chance(feel.heavy_slam, 100, 0) == 1)
    assert(feel.slam_chance(6, 100, 0) < feel.slam_chance(6, 100, 1))
    assert(feel.slam_chance(feel.heavy_slam * 0.5, 200, 0) == 1)
    assert(feel.slam_chance(8, 50, 0) < feel.slam_chance(8, 100, 0))
    assert(feel.slam_chance(2, 100, 0) == 0 and feel.slam_chance(2, 100, 0.6) == 0)
    assert(feel.slam_chance(0, 400, 1) == 0, "a bail whose force is not known never breaks it")
end)
check("every hit wears a board", function()
    assert(feel.landing_wear(3) == 0 and feel.landing_wear(5) > 0 and feel.landing_wear(9) > feel.landing_wear(5))
    assert(feel.rail_wear(3, true) > feel.rail_wear(3, false))
    assert(feel.grind_wear_per_second(true) > feel.grind_wear_per_second(false))
    assert(feel.slam_wear(2) == 0 and feel.slam_wear(12) > feel.slam_wear(7))
    assert(feel.add_wear(0.5, 0.1, 0) == 0.5 and near(feel.add_wear(0.5, 0.1, 200), 0.7) and feel.add_wear(0.95, 1, 100) == 1)
end)
check("a done board gives way on a landing", function()
    assert(not feel.gives_way_on_landing(20, 400, feel.done_wear - 0.01))
    assert(not feel.gives_way_on_landing(6, 100, feel.done_wear) and feel.gives_way_on_landing(6.5, 100, feel.done_wear))
    assert(not feel.gives_way_on_landing(3, 100, 1) and feel.gives_way_on_landing(3.5, 100, 1))
    assert(feel.gives_way_on_landing(4, 200, feel.done_wear) and not feel.gives_way_on_landing(4, 100, feel.done_wear))
    assert(feel.condition(0) == "new" and feel.condition(0.5) == "worn" and feel.condition(0.9) == "done")
end)
check("a board across its way slides", function()
    local level_up, ahead, across, upside_down, going = v(0, 1, 0), v(0, 0, 1), v(1, 0, 0), v(0, -1, 0), v(0, -1, 5)
    assert(feel.contact_of(ahead, level_up, going) == "grind")
    assert(feel.contact_of(across, level_up, going) == "slide")
    assert(feel.contact_of(across, upside_down, going) == "darkslide")
    assert(feel.contact_of(across, level_up, v(0, -2, 0.1)) == "grind")
    assert(feel.rail_chance(9, "grind", 100, 0) == 0)
    assert(feel.rail_chance(2, "slide", 100, 0) == 0 and feel.rail_chance(6, "slide", 100, 0) == 1)
    assert(feel.rail_chance(3.5, "darkslide", 100, 0) > feel.rail_chance(3.5, "slide", 100, 0))
end)
check("a board breaks where it hit, and hits sound by how hard", function()
    assert(feel.place_of_break(0.8, false, 0.1) == "nose" and feel.place_of_break(-0.8, false, 0.1) == "tail")
    assert(feel.place_of_break(0.8, true, 0.1) == "mid")
    assert(feel.place_of_break(0, false, 0.2) == "mid" and feel.place_of_break(0, false, 0.9) == "tail")
    assert(feel.body_loudness(2) == 0 and feel.body_loudness(feel.body_full) == 1 and feel.body_loudness(5) < feel.body_loudness(9))
end)

-- ---- the rules at play, with a faked game -------------------------------------------------------
-- A board at rest on flat ground at (10, 0, 5), the right way up, its nose towards +x; the skater
-- 3 m away. `rolls` are the random numbers it draws, in order (0.5 once they run out).
local function fake(stored)
    local g = {t = 1000, rolls = {}, stored = stored or {}, set = {}, hidden = {}, tossed = nil, cleared = 0,
               played = {}, wipeouts = {}, toasts = {}, logs = {}, sounds = {light = true, medium = true, heavy = true, body = true},
               velocity_now = v(0, 0, 0), skater_at = v(13, 0, 5), floor = nil, refuse = nil}
    local bones = {}
    for i = 0, 15 do bones[i] = {position = v(0, 0, 0), rotation = model.identity(), scale = v(1, 1, 1)} end
    bones[1].position = v(10, 0, 5)
    bones[2] = {position = v(0, 0.0856, 0), rotation = mount, scale = v(1, 1, 1)}
    bones[4] = {position = model.back_truck_rest.at, rotation = model.back_truck_rest.facing, scale = v(1, 1, 1)}
    bones[8] = {position = model.front_truck_rest.at, rotation = model.front_truck_rest.facing, scale = v(1, 1, 1)}
    g.bones_now = bones
    g.now = function() return g.t end
    g.random = function() return table.remove(g.rolls, 1) or 0.5 end
    g.bones = function() return g.bones_now end
    g.velocity = function() return g.velocity_now end
    g.skater = function() return g.skater_at end
    g.raycast = function(from) return if g.floor then v(from.x, g.floor, from.z) else nil end
    g.board = {
        set = function(bone, value)
            if g.refuse then return false, g.refuse end
            assert(model.length(value.position) <= 1000, "board.set refuses a bone over 1000 m out")
            g.set[bone] = value
            return true
        end,
        hide = function(bone) g.hidden[bone] = true; return true end,
        toss = function(list, options) g.tossed = {list = list, options = options}; return true end,
        clear = function() g.cleared += 1; g.set, g.hidden, g.tossed = {}, {}, nil end,
        park = function(list) g.parked = list end,
    }
    g.sound = function(kind) return g.sounds[kind] == true end
    g.play = function(kind, volume) table.insert(g.played, string.format("%s %.2f", kind, volume)) end
    g.wipeout = function(force) table.insert(g.wipeouts, force) end
    g.toast = function(text) table.insert(g.toasts, text) end
    g.log = function(text) table.insert(g.logs, text) end
    g.load = function(key) return g.stored[key] end
    g.save = function(key, value) g.stored[key] = value end
    g.run = function(bb, ms) -- ticks of 50 ms
        for _ = 1, math.ceil(ms / 50) do
            g.t += 50
            bb:tick(50)
        end
    end
    return g
end
local function rider(g)
    local bb = breaker.new(g)
    bb:skater_state("riding", "none")
    g.run(bb, 100) -- rolling: the ground under the board is known
    return bb
end
local function wiped(bb, g)
    bb:skater_state("wipeout", "riding")
end

check("the stretches are kept out of sight on every board from the start", function()
    local g = fake()
    breaker.new(g)
    assert(g.parked and #g.parked == 4 and table.find(g.parked, 12) and table.find(g.parked, 15))
end)
check("a heavy slam breaks the board in the middle, and the back half flies off", function()
    local g = fake()
    local bb = rider(g)
    wiped(bb, g)
    -- breaks; the middle (flat); the grip tape does not hold; then the angle and the flight
    g.rolls = {0, 0.1, 0.9}
    bb:bail(12)
    assert(bb.broken and bb.broken.place == "mid" and not bb.broken.joined, "it broke in the middle")
    assert(g.tossed and table.concat(g.tossed.list, ",") == "15,14", "the back and tail stretches fly")
    assert(g.tossed.options.velocity.y > 1 and near(g.tossed.options.ground, -0.071), "up, and down onto the ground it rolled on")
    assert(g.hidden[4] and not g.hidden[8], "the back truck goes, the front one stays")
    assert(near(g.set[3].position, v(0, -950, 0)), "the real deck goes away")
    assert(near(g.set[8].position + model.deck_away, model.front_truck_place, 0.01), "the front truck stays where it was")
    assert(g.set[12] and g.set[13], "the front half is drawn")
    assert(near(g.set[15].position, v(0, 0, 0)) and near(g.set[14].position, v(0, 0, 0)), "the flying stretches leave from their place in the board")
    assert(near(g.set[13].position, v(0, 0, 0)), "and lies level while its tail flies")
    assert(g.played[1] == "heavy 1.00", tostring(g.played[1]))
    assert(near(bb.wear, feel.slam_wear(12)), "a slam wears the board")
end)
check("held by the grip tape, it folds and nothing flies", function()
    local g = fake()
    local bb = rider(g)
    wiped(bb, g)
    g.rolls = {0, 0.1, 0.2, 1}
    bb:bail(12)
    assert(bb.broken.joined and bb.broken.parts.hinge == "fold" and g.tossed == nil)
    for _, bone in {12, 13, 14, 15} do assert(g.set[bone], "stretch " .. bone .. " is drawn") end
    assert(g.set[4] and g.set[8] and g.set[5] and g.set[9], "both trucks and their baseplates come back")
    assert(g.played[1] == "heavy 1.00", "a deep fold is a big break")
end)
check("light slams and bails of no known force do not break a board", function()
    local g = fake()
    local bb = rider(g)
    g.rolls = {0}
    bb:bail(3)
    assert(not bb.broken and g.tossed == nil and #g.played == 0)
    g.rolls = {0}
    bb:bail(nil)
    assert(not bb.broken)
    bb:set_setting("always", 1)
    g.rolls = {0, 0.1, 0.1}
    bb:bail(nil)
    assert(bb.broken, "set to always break, any bail does")
end)
check("on foot with the board the grip tape always holds", function()
    local g = fake()
    local bb = rider(g)
    bb:skater_state("off_board", "riding")
    bb:skater_state("wipeout", "off_board")
    g.rolls = {0, 0.9}
    bb:bail(12)
    assert(bb.broken and bb.broken.joined and g.tossed == nil)
end)
check("a slide that comes down hard onto a rail snaps the board and throws the rider", function()
    local g = fake()
    local bb = rider(g)
    g.t += 1000 -- in the air since: the ground it rolled on is old news
    g.floor = -1.2
    bb:skater_state("grinding", "air")
    g.velocity_now = v(0, -6, 4) -- the board's nose is towards +x: across its way
    g.rolls = {0, 0.9}
    bb:landed("rail", 6)
    assert(bb.broken and bb.broken.place == "mid", "it snapped in the middle")
    assert(#g.wipeouts == 1 and g.wipeouts[1] == 2.5, "and the rider went down")
    assert(near(g.tossed.options.ground, -1.2 - 0.071), "the piece falls to the ground under the rail")
end)
check("a grind on the trucks wears the board and never snaps it", function()
    local g = fake()
    local bb = rider(g)
    g.velocity_now = v(6, -6, 0) -- along the board
    g.rolls = {0}
    bb:landed("rail", 9)
    assert(not bb.broken and #g.wipeouts == 0)
    assert(near(bb.wear, feel.rail_wear(9, false)))
    bb:skater_state("grinding", "air")
    local before = bb.wear
    g.run(bb, 1000)
    assert(near(bb.wear - before, feel.grind_wear_per_second(false), 1e-5), "a second of grinding wears it a little")
    bb:set_setting("rails", 0)
    g.velocity_now = v(0, -6, 4)
    bb:landed("rail", 9)
    assert(not bb.broken, "rail snaps off: a slide does not snap it either")
end)
check("a done board gives way on a big drop and is ridden on until the next fall", function()
    local g = fake()
    local bb = rider(g)
    bb:set_wear(0.9)
    bb:landed("ground", 4)
    assert(not bb.broken, "a small drop holds")
    g.rolls = {0.9}
    bb:landed("ground", 6.5)
    assert(bb.broken and bb.broken.place == "nose" and bb.broken.gave_way)
    g.run(bb, 3000)
    assert(bb.broken, "ridden, it stays broken")
    bb:skater_state("wipeout", "riding")
    g.run(bb, 1000)
    bb:skater_state("riding", "off_board")
    g.run(bb, 1000)
    assert(not bb.broken and bb.wear == 0, "after a fall, riding again it is a new board")
end)
check("the board is whole again once it is back in hand", function()
    local g = fake()
    local bb = rider(g)
    wiped(bb, g)
    g.rolls = {0, 0.1, 0.1}
    bb:bail(12)
    g.run(bb, 2000)
    assert(bb.broken, "lying there, it stays broken")
    bb:skater_state("off_board", "wipeout")
    g.run(bb, 1000)
    assert(bb.broken, "the skater has not picked it up yet")
    -- Picked up: close to the skater, on its edge.
    g.bones_now[1] = {position = v(12.5, 0.8, 5), rotation = model.about(v(1, 0, 0), 1.5707963), scale = v(1, 1, 1)}
    g.run(bb, 200)
    assert(bb.broken, "not at once")
    g.run(bb, 300)
    assert(not bb.broken and g.cleared >= 1 and bb.wear == 0, "a moment later it is a new board")
    assert(g.parked and #g.parked == 4, "and the stretches are kept away again")
end)
check("a respawn mends it, and so does the board gone for long", function()
    local g = fake()
    local bb = rider(g)
    wiped(bb, g)
    g.rolls = {0, 0.1, 0.1}
    bb:bail(12)
    g.run(bb, 400)
    bb:skater_state("none", "wipeout")
    assert(not bb.broken, "a respawn")
    bb:skater_state("riding", "none")
    g.rolls = {0, 0.1, 0.1}
    bb:bail(12)
    local board = g.bones_now
    g.bones_now = nil
    g.run(bb, 300)
    assert(bb.broken, "out of sight for a moment it stays broken")
    g.run(bb, 400)
    assert(not bb.broken, "gone for longer, the next board is whole")
    g.bones_now = board
end)
check("one snapped to look at stays until it is mended, and keeps its wear", function()
    local g = fake()
    local bb = rider(g)
    bb:set_wear(0.3)
    g.rolls = {0.9}
    assert(bb:snap("tail", {asked = true}))
    assert(g.tossed and g.tossed.list[1] == 14 and #g.tossed.list == 1, "the tail comes off")
    assert(near(g.set[13].position, v(0, 0, 0)), "and the front stretch stays where it is")
    g.run(bb, 3000)
    assert(bb.broken, "riding, it stays broken")
    assert(not bb:snap("nose", {asked = true}), "one break at a time")
    assert(bb:mend("asked for") and near(bb.wear, 0.3), "mended, the wear is as it was")
end)
check("a refusal of the board is told once", function()
    local g = fake()
    local bb = rider(g)
    g.refuse = "other holds the board"
    g.rolls = {0.9}
    bb:snap("nose", {asked = true})
    g.run(bb, 500)
    local told = 0
    for _, line in g.logs do if line:find("other holds the board", 1, true) then told += 1 end end
    assert(told == 1, "told " .. told .. " times")
end)
check("cracks take the nearest size there are sounds of, body hits sound by how hard", function()
    local g = fake()
    g.sounds = {heavy = true, body = true}
    local bb = rider(g)
    g.rolls = {0.1} -- held by the grip tape: a light break
    bb:snap("nose", {asked = true, carried = true})
    assert(g.played[1] == "heavy 1.00", tostring(g.played[1]))
    bb:body_hit(2)
    bb:body_hit(feel.body_full)
    bb:body_hit(feel.body_full)
    assert(#g.played == 2 and g.played[2] == "body 1.00", "a graze is not heard, and two hits at once are one")
    bb:set_setting("cracks", 0)
    bb:mend("asked for")
    bb:snap("nose", {asked = true})
    assert(#g.played == 2, "cracks off")
end)
check("off, nothing breaks or wears", function()
    local g = fake()
    local bb = rider(g)
    bb:set_on(false)
    g.rolls = {0, 0, 0}
    bb:bail(20)
    bb:landed("ground", 9)
    assert(not bb.broken and bb.wear == 0 and g.stored.on == false)
end)
check("settings and wear are kept, and the board's state is told as it wears", function()
    local g = fake()
    local bb = rider(g)
    assert(bb:set_setting("sensitivity", 9999) and bb:setting("sensitivity") == 400)
    assert(not bb:set_setting("nonsense", 1))
    bb:set_wear(0.6)
    bb:add_wear(0.1)
    assert(#g.toasts == 1 and g.toasts[1]:find("beat", 1, true))
    bb:add_wear(0.2)
    assert(#g.toasts == 2 and g.toasts[2]:find("done", 1, true))
    g.run(bb, 6000)
    local again = breaker.new(fake(g.stored))
    assert(again:setting("sensitivity") == 400 and near(again.wear, 0.9), "read back: " .. tostring(again.wear))
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
