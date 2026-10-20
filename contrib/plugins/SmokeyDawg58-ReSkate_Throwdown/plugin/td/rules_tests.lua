-- Self-tests of the rules, the referee and the wire in Lua (`tdm test`): his
-- Extension/Modes/Test/mode_rules_tests.cpp's flows for them, check for check, with his numbers, plus a
-- few for the Lua itself (64-bit ids, scores worked out by hand, the FNV hash). Loaded only when run.
local R = require("td/rules")
require("td/referee")
require("td/wire")
local ML = require("td/h/mode_lobby")

local T = {}

local passed, failed = 0, {}
local current = ""
local function check(condition, what)
    if condition then
        passed += 1
    else
        table.insert(failed, current .. ": " .. what)
    end
end

-- ---- helpers ---------------------------------------------------------------------------------------
local function v(x, y, z) return vector.create(x, y, z) end
local zero = vector.zero
local a, b, c = "76561198000000001", "76561198000000002", "76561198000000003"
local square = {v(0, 0, 0), v(40, 0, 0), v(40, 0, 40), v(0, 0, 40)}
local countdown_ms, results_ms = R.countdown_ms, R.results_ms

local function same(x, y)
    if x == y then return true end
    if type(x) ~= "table" or type(y) ~= "table" then return false end
    for k, value in pairs(x) do
        if not same(value, y[k]) then return false end
    end
    for k in pairs(y) do
        if x[k] == nil then return false end
    end
    return true
end
local function S(fields)
    local s = R.Settings()
    for k, value in pairs(fields or {}) do s[k] = value end
    return s
end
local function Msg(fields)
    local m = R.Message()
    for k, value in pairs(fields or {}) do m[k] = value end
    return m
end
local function standing(player, score, aux, out, up)
    local st = R.Standing()
    st.player, st.score, st.aux, st.out, st.up = player, score or 0, aux or 0, out == true, up == true
    return st
end
local function roundtrip(m) return same(R.decode(R.encode(m)), m) end
local function refused(m)
    local ok = pcall(R.encode, m)
    return not ok
end
local function of(m, id)
    for _, st in ipairs(m.standings) do
        if st.player == id then return st end
    end
    return R.Standing()
end
local function tag(kind, path) return {kind = kind, path = path} end
local function with_byte(bytes, index, value) -- index 0-based, as his
    return string.sub(bytes, 1, index) .. string.char(value) .. string.sub(bytes, index + 2)
end

-- ---- his flows -------------------------------------------------------------------------------------
local flows = {}

function flows.area()
    check(R.inside_corners(square, v(20, 0, 20)), "the middle of a square is inside it")
    check(not R.inside_corners(square, v(50, 0, 20)), "a point past its edge is outside")
    check(R.inside_corners({}, v(1e6, 0, 1e6)), "without an area everywhere counts")
    local centre = R.area_centre(square)
    check(centre.x == 20 and centre.z == 20, "the area's centre")
    check(R.missing(S({mode = "graffiti"})) == "", "Graffiti needs nothing set up: what gets skated is tagged")
    check(R.missing(S({mode = "race"})) ~= "", "a race without checkpoints is not ready")
    check(R.missing(S({corners = {v(0, 0, 0), v(1, 0, 1)}})) ~= "", "two corners are not an area")
    -- A circle, like skate.'s own jam drops: a centre and how far it reaches.
    local circle = S({mode = "graffiti", corners = {v(100, 0, 100)}, area_radius = 20})
    check(R.has_area(circle) and R.missing(circle) == "", "a centre and a radius are an area")
    check(R.inside(circle, v(115, 0, 100)) and not R.inside(circle, v(121, 0, 100)), "inside the circle and past it")
    local setup = Msg({kind = "setup", leader = a, game = 3, settings = circle})
    check(roundtrip(setup), "a circle round trips")
    table.insert(circle.corners, v(0, 0, 0))
    check(refused(setup), "a circle has exactly one centre")
end

function flows.scoring()
    check(R.trick_score({air_time = 0.1}) == 0, "a hop scores nothing")
    local ollie = R.trick_score({air_time = 0.5, height = 0.5, distance = 3})
    local kickflip = R.trick_score({air_time = 0.5, height = 0.5, distance = 3, spin = 0, flip = 0, board_turn = 1000})
    local three_sixty = R.trick_score({air_time = 0.8, height = 1.0, distance = 4, spin = 360})
    check(ollie > 0 and kickflip > ollie and three_sixty > kickflip, "flips and spins beat an ollie")
    check(R.line_score(1000, 1) == 1000 and R.line_score(1000, 3) == 2000, "a line multiplies its tricks")
    check(R.line_score(1000, 50) == 6000, "the multiplier is capped")
    check(R.bail_score({speed = 15, drop = 4, tumble = 2}) > R.bail_score({speed = 5, drop = 0, tumble = 1}), "a faster, higher bail is more meat")
    -- ReSkate: his formulas worked out by hand.
    check(ollie == 340 and kickflip == 540 and three_sixty == 1000, "trick scores: 340, 540 and 1000")
    check(R.bail_score({speed = 15, drop = 4, tumble = 2}) == 2650 and R.bail_score({speed = 5, drop = 0, tumble = 1}) == 400, "bail scores: 2650 and 400")
    check(R.line_score(0, 3) == 0 and R.line_score(500, 0) == 0, "no line without a sum and tricks")
end

function flows.wire()
    local setup = Msg({kind = "setup", leader = a, game = 7})
    setup.settings.mode = "domination"
    setup.settings.corners = square
    setup.settings.points = {v(10, 1, 10), v(30, 1, 30)}
    local bytes = R.encode(setup)
    check(R.is_mode_message(bytes) and string.byte(bytes, 1) ~= 25, "game mode messages are told apart by their first byte")
    check(string.byte(bytes, 1) == 0xD5 and string.byte(bytes, 2) == 16, "his magic byte and version")
    check(same(R.decode(bytes), setup), "setup round trip")
    local state = Msg({kind = "state", leader = a, game = 7, phase = "playing", remaining_ms = 1234,
                       standings = {standing(a, 10, 2, false, true), standing(b, 5, 0, true, false)},
                       zones = {{zone = 1, owner = b, best = 900}}, calls = {"GO!", "Sam stole a tag from Alex"}, call_serial = 12})
    check(roundtrip(state), "state round trip")
    check(roundtrip(Msg({kind = "join", leader = a, game = 7})), "join round trip")
    local event = Msg({kind = "event", leader = a, game = 7, value = 4000, extra = 3, at = v(1, 2, 3), sequence = 9})
    check(roundtrip(event), "event round trip")
    local future = with_byte(R.encode(event), 1, R.wire_version + 1)
    check(R.decode(future) == nil and R.message_version(future) == R.wire_version + 1, "another version is recognised, not read")
    local cut = R.encode(state)
    cut = string.sub(cut, 1, #cut - 1)
    check(R.decode(cut) == nil, "a cut message is rejected")
    check(R.decode("\1\2\3") == nil, "a throwdown message is not a game mode message")
    -- ReSkate: the whole 64-bit range of an id, and signed numbers.
    local wide = Msg({kind = "state", leader = "18446744073709551615", game = 4294967295, phase = "results", turn = "9007199254740993",
                      target = -5, standings = {standing("18446744073709551614", -7, -2147483648)}, setter = "1"})
    check(roundtrip(wide), "64-bit ids, the largest game and negative scores round trip")
    check(R.decode(R.encode(Msg({kind = "hello", leader = "0", game = 1}))) == nil, "a message without a leader is not read")
    check(refused(Msg({kind = "nonsense", leader = a, game = 1})), "an unknown kind is refused")
end

function flows.jam()
    local s = S({mode = "jam", duration_s = 60, corners = square})
    local r = R.Referee.new(s, a, 1)
    r:add_player(a)
    r:add_player(b)
    r:start(0)
    r:event(a, "line", 500, v(10, 0, 10), 1, 1000)
    check(r:state(1000).standings[1].score == 0, "nothing counts during the countdown")
    check(r:tick(countdown_ms), "the countdown ends")
    r:event(a, "line", 500, v(10, 0, 10), 2, 6000)
    r:event(a, "line", 500, v(10, 0, 10), 2, 6100) -- a repeat
    r:event(b, "line", 900, v(10, 0, 10), 1, 7000)
    r:event(b, "line", 5000, v(99, 0, 99), 2, 7500) -- outside the area
    local st = r:state(8000)
    check(st.standings[1].player == b and st.standings[1].score == 900, "b leads with one line")
    check(st.standings[2].score == 500, "a's repeated event counted once")
    r:tick(countdown_ms + 60000)
    check(r:phase() == "results", "the clock runs out")
    check(r:finished(countdown_ms + 60000 + results_ms), "results show, then the game is over")
end

function flows.one_up()
    local s = S({mode = "oneup", strikes = 2})
    local r = R.Referee.new(s, a, 2)
    r:add(a)
    r:add(b)
    r:start(0)
    r:tick(countdown_ms)
    local st = r:state(countdown_ms)
    check(st.turn == a, "the leader goes first")
    r:event(b, "line", 9999, zero, 1, countdown_ms + 10) -- not b's turn
    check(r:state(countdown_ms + 10).turn == a, "only the player up counts")
    r:event(a, "line", 1000, zero, 1, countdown_ms + 100)
    st = r:state(countdown_ms + 100)
    check(st.turn == b and st.target == 1000, "a set 1000, b is up")
    r:event(b, "line", 800, zero, 2, countdown_ms + 200)
    st = r:state(countdown_ms + 200)
    check(st.turn == a, "b fell short: a strike, a is up")
    r:event(a, "bail", 100, zero, 2, countdown_ms + 300)
    st = r:state(countdown_ms + 300)
    check(r:phase() == "playing" and st.turn == b, "a bailed: one strike each, b is up")
    r:tick(countdown_ms + 300 + s.turn_s * 1000)
    check(r:phase() == "results", "b ran out of time: two strikes and out, the last one standing wins")
    check(r:state(countdown_ms + 300 + s.turn_s * 1000).standings[1].player == a, "a wins")
end

function flows.race()
    local s = S({mode = "race", points = {v(0, 0, 0), v(50, 0, 0), v(100, 0, 0)}})
    local r = R.Referee.new(s, a, 3)
    r:add(a)
    r:add(b)
    r:start(0)
    r:tick(countdown_ms)
    r:event(a, "checkpoint", 2, v(100, 0, 0), 1, countdown_ms + 100)
    check(r:state(countdown_ms + 100).standings[1].score == 1, "race starts at first visible gate and refuses skipped gates")
    r:event(a, "checkpoint", 0, v(0, 0, 0), 2, countdown_ms + 200)
    r:event(a, "checkpoint", 1, v(50, 0, 0), 3, countdown_ms + 300)
    r:event(a, "checkpoint", 2, v(100, 0, 0), 4, countdown_ms + 400)
    r:event(b, "checkpoint", 0, v(0, 0, 0), 1, countdown_ms + 500)
    r:event(b, "checkpoint", 1, v(500, 0, 0), 2, countdown_ms + 600) -- nowhere near it
    local st = r:state(countdown_ms + 600)
    check(st.standings[1].player == a and st.standings[1].aux == 400, "a finished in 0.4 s")
    check(st.standings[2].score == 1, "b's far-off checkpoint was refused")
    r:remove(b, countdown_ms + 700)
    r:tick(countdown_ms + 700)
    check(r:phase() == "results", "everyone still racing finished")
end

function flows.race_clock()
    local s = S({mode = "race", duration_s = 120, race_finish = true, points = {v(0, 0, 0), v(20, 0, 0), v(40, 0, 0), v(60, 0, 0)}})
    local r = R.Referee.new(s, a, 3)
    r:add(a)
    r:add(b)
    r:start(0)
    r:tick(countdown_ms)
    local function at(id, t) return of(r:state(t), id) end
    check(at(a, countdown_ms).remaining_ms == 120000, "race uses its selected shared deadline")
    check(at(a, countdown_ms).aux == 0 and at(b, countdown_ms).aux == 0, "elapsed race timers start at zero on GO")
    check(at(a, countdown_ms + 500).aux == 500, "elapsed timer advances before the first gate")
    r:event(a, "checkpoint", 1, v(20, 0, 0), 1, countdown_ms + 1000)
    check(at(a, countdown_ms + 1000).remaining_ms == 119000 and at(b, countdown_ms + 1000).remaining_ms == 119000,
          "gate awards no time and racers share deadline")
    r:tick(countdown_ms + 89999)
    check(not R.race_clock_visible(at(a, countdown_ms + 89999).remaining_ms), "timer hidden until ninety seconds")
    r:tick(countdown_ms + 90000)
    check(R.race_clock_visible(at(a, countdown_ms + 90000).remaining_ms), "timer appears with thirty seconds remaining")
    r:event(a, "checkpoint", 2, v(40, 0, 0), 2, countdown_ms + 119998)
    r:event(a, "checkpoint", 3, v(60, 0, 0), 3, countdown_ms + 119999)
    r:tick(countdown_ms + 120000)
    check(r:phase() == "results" and at(b, countdown_ms + 120000).out and not at(a, countdown_ms + 120000).out and
          r:state(countdown_ms + 120000).standings[1].player == a, "unfinished racer DNF; finish just before deadline wins")
    check(at(a, countdown_ms + 120000).aux == 119999 and at(a, countdown_ms + 125000).aux == 119999, "finisher elapsed time freezes through results")
    check(at(b, countdown_ms + 125000).aux == 120000, "DNF elapsed time freezes at deadline")
    check(roundtrip(r:state(countdown_ms + 120000)), "per-player elapsed times survive state transfer")
    check(not R.race_clock_visible(0), "no clock left after deadline")
    local late = R.Referee.new(s, a, 4)
    late:add(a)
    late:start(0)
    late:tick(countdown_ms)
    late:event(a, "checkpoint", 1, v(20, 0, 0), 1, countdown_ms + 1)
    late:event(a, "checkpoint", 2, v(40, 0, 0), 2, countdown_ms + 2)
    late:event(a, "checkpoint", 3, v(60, 0, 0), 3, countdown_ms + 120000)
    late:tick(countdown_ms + 120000)
    check(late:phase() == "results" and late:state(countdown_ms + 120000).standings[1].out, "finish at exact deadline is DNF")
    local early = R.Referee.new(s, a, 5)
    early:add(a)
    early:start(0)
    early:tick(countdown_ms)
    for i = 1, 3 do early:event(a, "checkpoint", i, s.points[i + 1], i, countdown_ms + i) end
    early:tick(countdown_ms + 4)
    check(early:phase() == "results", "all finished ends race without waiting two minutes")
    check(early:state(countdown_ms + 9000).standings[1].aux == 3, "results do not restart the race timer")
    local leaving = R.Referee.new(s, a, 6)
    leaving:add(a)
    leaving:add(b)
    leaving:start(0)
    leaving:tick(countdown_ms)
    leaving:remove(b, countdown_ms + 1234)
    local departed = of(leaving:state(countdown_ms + 9000), b)
    check(departed.player == b and departed.out and departed.aux == 1234, "departed racer timer freezes when leaving")
end

function flows.race_optional()
    local s = S({mode = "race", race_finish = true,
                 points = {v(0, 0, 0), v(5, 0, 0), v(10, 0, -5), v(10, 0, 5), v(20, 0, 0), v(30, 0, -5), v(30, 0, 5), v(40, 0, 0), v(50, 0, 0)},
                 gate_kinds = {"required", "guide", "guide", "guide", "required", "guide", "guide", "required", "required"}})
    check(R.mandatory_gates(s, #s.points) == 2, "required count ignores both fork branches and finish")
    local r = R.Referee.new(s, a, 13)
    r:add(a)
    r:add(b)
    r:add(c)
    r:start(0)
    r:tick(countdown_ms)
    local function at(id, t) return of(r:state(t), id) end
    check(at(a, countdown_ms).score == 4, "race begins at first required gate beyond white guides")
    r:event(a, "checkpoint", 8, s.points[9], 1, countdown_ms + 1)
    r:event(a, "checkpoint", 7, s.points[8], 2, countdown_ms + 2)
    check(at(a, countdown_ms + 2).score == 4, "finish and later required gate blocked while mandatory gate missing")
    for i = 1, 3 do r:event(a, "checkpoint", i, s.points[i + 1], i + 2, countdown_ms + 10 + i) end
    check(at(a, countdown_ms + 15).score == 4, "either or both guide branches never alter required progress")
    r:event(a, "checkpoint", 4, v(20, 30, 0), 6, countdown_ms + 16)
    check(at(a, countdown_ms + 16).score == 4, "crossing above mandatory arch refused")
    r:event(a, "checkpoint", 4, s.points[5], 7, countdown_ms + 20)
    check(at(a, countdown_ms + 20).score == 7 and R.mandatory_gates(s, 7) == 1, "required crossing advances past all optional guides")
    r:event(b, "position", 0, v(10, 0, 0), 1, countdown_ms + 21)
    r:event(c, "position", 0, v(19, 0, 0), 1, countdown_ms + 21)
    local ranked = r:state(countdown_ms + 22)
    check(ranked.standings[1].player == a and ranked.standings[2].player == c, "required progress then fresh distance determines racing places")
    r:event(a, "checkpoint", 7, s.points[8], 8, countdown_ms + 30)
    r:event(a, "checkpoint", 8, s.points[9], 9, countdown_ms + 40)
    check(at(a, countdown_ms + 40).score == 9 and at(a, countdown_ms + 40).aux == 40, "required route finishes without crossing any guides")
end

function flows.gate_width()
    local s = S({mode = "race", points = {v(0, 0, 0), v(50, 0, 0), v(100, 0, 0)}, yaws = {90, 90, 90}, widths = {6, 25, 6}})
    local setup = Msg({kind = "setup", leader = a, game = 9, settings = s})
    check(roundtrip(setup), "gate widths round trip")
    check(R.gate_half_width(s, 1) == 25 and R.gate_half_width(R.Settings(), 0) == R.Settings().radius, "a gate's own width, else the radius")
    local bad = Msg({kind = "setup", leader = a, game = 9, settings = S({mode = "race", points = s.points, yaws = s.yaws, widths = {6, 6}})})
    check(refused(bad), "one width per gate")
    bad.settings.widths = {6, 0.1, 6}
    check(refused(bad), "a gate is at least a few metres wide")
    local r = R.Referee.new(s, a, 9)
    r:add(a)
    r:add(b)
    r:start(0)
    r:tick(countdown_ms)
    r:event(a, "checkpoint", 0, v(0, 0, 2), 1, countdown_ms + 100)
    r:event(a, "checkpoint", 1, v(50, 0, 20), 2, countdown_ms + 200) -- 20 m off the middle of a 50 m gate
    r:event(b, "checkpoint", 1, v(50, 0, 40), 1, countdown_ms + 300) -- outside the wide gate's accepted edge
    local st = r:state(countdown_ms + 300)
    check(of(st, a).score == 2, "a wide gate takes a crossing near its edge")
    check(of(st, b).score == 1, "a gate does not take a crossing far outside it")
end

-- Skate Tag: positions decide who tags whom; no tag-backs for a few seconds; least time it wins.
function flows.skate_tag()
    local s = S({mode = "tag", radius = R.default_tag_reach, duration_s = 60})
    local r = R.Referee.new(s, a, 4) -- game 4 with three players: players[4 % 3] = b starts it
    r:add(a)
    r:add(b)
    r:add(c)
    r:start(0)
    r:tick(countdown_ms)
    local t = countdown_ms
    check(r:state(t).turn == b, "the game's id picks who starts it")
    local seq_a, seq_b, seq_c = 0, 0, 0
    local function move(id, at)
        if id == a then seq_a += 1 r:event(a, "position", 0, at, seq_a, t)
        elseif id == b then seq_b += 1 r:event(b, "position", 0, at, seq_b, t)
        else seq_c += 1 r:event(c, "position", 0, at, seq_c, t) end
    end
    move(a, v(0, 0, 0))
    move(c, v(50, 0, 0))
    move(b, v(10, 0, 0))
    check(r:state(t).turn == b, "out of reach: nobody tagged")
    t += 2000
    r:tick(t)
    move(a, v(0, 0, 0))
    move(b, v(2, 0, 0))
    check(r:state(t).turn == a, "within reach: b tagged a")
    t += 1000
    r:tick(t)
    move(b, v(1, 0, 0))
    move(a, v(1.5, 0, 0))
    check(r:state(t).turn == a, "no tag-backs straight away")
    t += R.no_tag_back_ms
    r:tick(t)
    move(b, v(1, 0, 0))
    move(a, v(1.5, 0, 0))
    check(r:state(t).turn == b, "a tag-back once the wait is over")
    t += 2000
    move(c, v(1.2, 0, 0)) -- c's position is fresh, b's is not
    check(r:state(t).turn == b, "an old position tags nobody")
    r:tick(countdown_ms + 60000)
    local st = r:state(countdown_ms + 60000)
    check(r:phase() == "results" and st.standings[1].player == c, "c was never it and wins")
    check(st.standings[#st.standings].score > st.standings[1].score, "time spent it is counted")
    local position = Msg({kind = "event", leader = a, game = 4, event = "position", at = v(12.5, 3, -7), sequence = 3})
    check(roundtrip(position), "a position round trips")
end

function flows.domination()
    local s = S({mode = "domination", points = {v(0, 0, 0), v(100, 0, 0)}})
    local r = R.Referee.new(s, a, 4)
    r:add(a)
    r:add(b)
    r:start(0)
    r:tick(countdown_ms)
    r:event(a, "line", 500, v(1, 0, 1), 1, countdown_ms)
    r:tick(countdown_ms + 3000)
    check(r:state(countdown_ms + 3000).standings[1].score == 3, "a spot held for 3 s is 3 points")
    r:event(b, "line", 400, v(1, 0, 1), 1, countdown_ms + 3000)
    check(r:state(countdown_ms + 3000).zones[1].owner == a, "a smaller line does not take it")
    r:event(b, "line", 600, v(1, 0, 1), 2, countdown_ms + 3000)
    check(r:state(countdown_ms + 3000).zones[1].owner == b, "a bigger line does")
end

function flows.tag()
    -- A curb ground twice from different ends is one curb; a ledge beside it is another.
    local curb = tag("grind", {v(0, 0.2, 0), v(2, 0.2, 0), v(4, 0.2, 0)})
    local same_curb = tag("grind", {v(3, 0.25, 0.3), v(5, 0.2, 0.2), v(6, 0.2, 0)})
    local ledge = tag("grind", {v(0, 0.5, 5), v(4, 0.5, 5)})
    check(R.same_tag(curb, same_curb) and not R.same_tag(curb, ledge), "grinds on one curb are the same tag")
    local stairs, stairs_again = tag("gap", {v(10, 2, 10), v(13, 0, 10)}), tag("gap", {v(10.5, 2, 9), v(14, 0, 11)})
    check(R.same_tag(stairs, stairs_again) and not R.same_tag(stairs, curb), "a gap jumped again is the same gap")
    local long_path = {}
    for i = 0, 30 do table.insert(long_path, v(i, 0, 0)) end
    local thin = R.thin_path(long_path)
    check(#thin == R.max_tag_points and thin[1].x == 0 and thin[#thin].x == 30, "a long grind keeps its ends")
    check(thin[2].x == 6 and thin[3].x == 12, "ReSkate: spread evenly along it")
    local event = Msg({kind = "event", leader = a, game = 4, value = 900, sequence = 1, tags = {curb, stairs}})
    check(roundtrip(event), "a line's tags round trip")
    local shapes = Msg({kind = "tags", leader = a, game = 4, first = 3, tags = {ledge}})
    check(roundtrip(shapes), "tag shapes round trip")
    check(R.tag_centre(stairs) == v(13, 0, 10), "ReSkate: a gap belongs where it lands")
end

function flows.graffiti()
    local s = S({mode = "graffiti", corners = square})
    local r = R.Referee.new(s, a, 5)
    r:add(a)
    r:add(b)
    r:add(c)
    r:start(0)
    r:tick(countdown_ms)
    local curb = tag("grind", {v(5, 0.2, 5), v(10, 0.2, 5)})
    local rail = tag("grind", {v(30, 0.8, 30), v(35, 0.8, 30)})
    local outside = tag("grind", {v(90, 0.2, 90), v(95, 0.2, 90)})
    r:event(a, "line", 500, v(10, 0, 5), 1, countdown_ms, {curb})
    r:event(a, "line", 500, v(35, 0, 30), 2, countdown_ms, {rail, outside})
    check(#r:tags() == 2, "two tags; the one outside the area is not")
    r:event(b, "line", 400, v(10, 0, 5), 1, countdown_ms, {tag("grind", {v(6, 0.2, 5), v(9, 0.2, 5)})})
    check(r:state(countdown_ms).zones[1].owner == a, "a smaller line does not steal the curb")
    r:event(b, "line", 800, v(10, 0, 5), 2, countdown_ms, {tag("grind", {v(6, 0.2, 5), v(9, 0.2, 5)})})
    local st = r:state(countdown_ms)
    check(#r:tags() == 2 and #st.zones == 2, "the same curb, still two tags")
    check(st.standings[1].score == 1 and st.standings[2].score == 1, "b stole one of a's")
    local calls = r:calls()
    check(#calls > 0 and string.find(calls[#calls], "stole", 1, true) ~= nil, "the steal is called out")
    local shown = r:state(countdown_ms)
    check(#shown.calls <= R.max_calls and shown.calls[#shown.calls] == calls[#calls], "the state carries the latest calls")
    check(roundtrip(shown), "a real state round trips")
    check(#r:state(countdown_ms).standings == 3, "everyone is on the board")
end

function flows.infection()
    local s = S({mode = "infection", radius = R.default_tag_reach, duration_s = 120})
    local r = R.Referee.new(s, a, 9) -- game 9 with three players: players[9 % 3] = a is patient zero
    r:add(a)
    r:add(b)
    r:add(c)
    r:start(0)
    r:tick(countdown_ms)
    local t = countdown_ms
    local sa, sb, sc = 0, 0, 0
    local st = r:state(t)
    check(of(st, a).up and of(st, a).aux == 1 and not of(st, b).up and not of(st, c).up, "a is patient zero")
    sa += 1 r:event(a, "position", 0, v(0, 0, 0), sa, t)
    sb += 1 r:event(b, "position", 0, v(20, 0, 0), sb, t)
    sc += 1 r:event(c, "position", 0, v(60, 0, 0), sc, t)
    t += 10000
    r:tick(t)
    st = r:state(t)
    check(of(st, b).score == 100 and of(st, c).score == 100 and of(st, a).score == 0, "survivors score their time clean")
    sb += 1 r:event(b, "position", 0, v(20, 0, 0), sb, t)
    sa += 1 r:event(a, "position", 0, v(18, 0, 0), sa, t)
    st = r:state(t)
    check(of(st, b).up and not of(st, c).up and r:phase() == "playing", "a infected b; c survives")
    t += 5000
    r:tick(t)
    sc += 1 r:event(c, "position", 0, v(60, 0, 0), sc, t)
    sb += 1 r:event(b, "position", 0, v(58, 0, 0), sb, t) -- the newly infected hunt too
    check(r:phase() == "results", "b infected c, the last survivor: game over")
    st = r:state(t)
    check(st.standings[1].player == c and of(st, c).score == 150 and of(st, b).score == 100, "c survived longest and wins")
    check(roundtrip(st), "an Infection state round trips")
    check(roundtrip(Msg({kind = "setup", leader = a, game = 9, settings = s})) and R.parse_mode("zombies") == "infection",
          "the Infection setup round trips")
end

function flows.hide()
    local s = S({mode = "hide", radius = R.default_tag_reach, duration_s = 120, turn_s = 20}) -- 20 s hiding time
    local r = R.Referee.new(s, a, 9) -- players[9 % 3] = a seeks
    r:add(a)
    r:add(b)
    r:add(c)
    r:start(0)
    r:tick(countdown_ms)
    local t = countdown_ms
    local sa, sb, sc = 0, 0, 0
    local st = r:state(t)
    check(of(st, a).up and not of(st, b).up and st.target == 20000, "a seeks; 20 s to hide")
    -- Right next to b while still counting: nobody is found, and hiding scores nothing.
    t += 10000
    r:tick(t)
    sb += 1 r:event(b, "position", 0, v(1, 0, 0), sb, t)
    sa += 1 r:event(a, "position", 0, v(0, 0, 0), sa, t)
    st = r:state(t)
    check(not of(st, b).up and of(st, b).score == 0 and st.target == 10000, "nobody is found while the seeker counts")
    t += 10000
    check(r:tick(t), "the seekers come out at once")
    t += 5000
    r:tick(t)
    st = r:state(t)
    check(st.target == 0 and of(st, b).score == 50 and of(st, c).score == 50, "hidden time counts from the release")
    sb += 1 r:event(b, "position", 0, v(40, 0, 0), sb, t)
    sc += 1 r:event(c, "position", 0, v(80, 0, 0), sc, t)
    sa += 1 r:event(a, "position", 0, v(39, 0, 0), sa, t)
    st = r:state(t)
    check(of(st, b).up and of(st, a).aux == 1 and not of(st, c).up, "a found b, who seeks now")
    t += 3000
    r:tick(t)
    sc += 1 r:event(c, "position", 0, v(80, 0, 0), sc, t)
    sb += 1 r:event(b, "position", 0, v(79, 0, 0), sb, t)
    check(r:phase() == "results", "b found c, the last one hiding")
    st = r:state(t)
    check(st.standings[1].player == c and of(st, c).score == 80 and of(st, b).aux == 1, "c hid longest and wins")
    check(roundtrip(st) and R.parse_mode("hideandseek") == "hide", "a Hide & Seek state round trips")
end

-- Alone, a set trick is landed again by its setter, or it takes a letter.
function flows.skate_solo()
    local s = S({mode = "skate", strikes = 2})
    local r = R.Referee.new(s, a, 9)
    r:add(a)
    r:start(0)
    r:tick(countdown_ms)
    local t = countdown_ms
    local sa = 0
    local function try(landed, trick)
        sa += 1
        r:event(a, "trick", landed, zero, sa, t, {}, trick)
    end
    try(1, "Kickflip")
    local st = r:state(t)
    check(st.turn == a and st.trick == "Kickflip", "alone: the setter copies their own kickflip")
    try(1, "Kickflip")
    st = r:state(t)
    check(st.turn == a and st.trick == "" and st.standings[1].aux == 0, "landed again: no letter, set the next")
    try(1, "Heelflip")
    try(0, "")
    st = r:state(t)
    check(st.standings[1].aux == 1 and st.trick == "" and r:phase() == "playing", "missed it again: a letter")
    try(1, "Hardflip")
    try(1, "Kickflip")
    check(r:phase() == "results", "all the letters alone: the game is over")
end

function flows.reskate_merge_scope()
    local settings = S({mode = "skate", strikes = R.max_strikes, corners = square})
    local setup = Msg({kind = "setup", leader = a, game = 72, settings = settings})
    local guest = R.decode(R.encode(setup))
    check(guest ~= nil and R.reskate_custom_zone(guest.settings), "a guest reconstructs the custom trick zone from the existing shared settings")
    settings.corners = {square[1], square[2]}
    check(not R.reskate_custom_zone(settings) and R.reskate_custom_zone(settings, true), "unfinished cone placement is local until it has a polygon")
    settings.corners = {square[1]}
    settings.area_radius = 10
    check(not R.reskate_custom_zone(settings), "a circular trick zone keeps its circle presentation")
    for _, mode in ipairs(R.all_modes) do
        setup.settings = S({mode = mode, strikes = if mode == "skate" then R.max_strikes else 5})
        local limit = R.decode(R.encode(setup))
        check(limit ~= nil and limit.settings.strikes == setup.settings.strikes, "the merge preserves each mode's previous valid letter/strike limit")
        local lobby = Msg({kind = "state", leader = a, game = 73, standings = {standing(a), standing(b)}})
        lobby.settings.mode = mode
        local enrolled = R.decode(R.encode(lobby))
        check(enrolled ~= nil and ML.lobby_enrolled_count(enrolled) == 2, "every mode, including R.E.S.K.A.T.E., counts enrollment without Ready")
        if mode == "skate" then continue end
        check(not R.reskate_custom_zone(setup.settings, true), "other modes never become a R.E.S.K.A.T.E. cone editor")
        setup.settings.strikes = 6
        check(refused(setup), "R.E.S.K.A.T.E.'s seven letters do not relax the limits for other challenges")
    end
end

function flows.reskate_seven_letters()
    check(R.mode_name("skate") == "R.E.S.K.A.T.E." and R.parse_mode("R.E.S.K.A.T.E.") == "skate" and R.parse_mode("skate") == "skate",
          "new branding and existing command aliases resolve to the same mode")
    check(R.skate_letters(7, 7) == "R.E.S.K.A.T.E" and R.skate_letters(99, 7) == "R.E.S.K.A.T.E", "all seven penalty letters have the correct order and are bounded")
    local s = S({mode = "skate", strikes = 7, turn_s = 10})
    check(roundtrip(Msg({kind = "setup", leader = a, game = 71, settings = s})), "seven-letter settings roundtrip to guests")
    local r = R.Referee.new(s, a, 71)
    r:add(a)
    r:add(b)
    r:start(1000)
    r:tick(6000)
    local t = 6000
    local serial = 0
    -- Every setter lands a new allowed trick; the copier times out. Five
    -- misses must leave them playing, while the seventh eliminates them.
    local tricks = {"Kickflip", "Heelflip", "Hardflip", "Varial Kickflip", "Laser Flip", "FS Kickflip", "BS Heelflip"}
    for i, trick in ipairs(tricks) do
        check(r:state(t).turn == a, "setter retains the set after a failed copy")
        serial += 1
        r:event(a, "trick", 1, zero, serial, t, {}, trick)
        check(r:state(t).turn == b, "other player must copy the trick")
        t += s.turn_s * 1000
        r:tick(t)
        check(of(r:state(t), b).aux == i, "one missed copy earns exactly one letter")
        check(r:phase() == (if i == 7 then "results" else "playing"), "elimination occurs on the seventh letter, never the fifth")
    end
    check(r:state(t).standings[1].player == a, "last remaining skater wins the seven-letter match")
end

function flows.skate()
    check(R.trick_kinds_of("Kickflip") == R.trick_flips and R.trick_kinds_of("BS 50-50 Grind") == R.trick_grinds, "flips and grinds are told apart")
    check(R.trick_kinds_of("Heelflip + Seatbelt") == bit32.bor(R.trick_flips, R.trick_grabs) and R.trick_kinds_of("Manual") == R.trick_manuals,
          "a combo is every kind its parts are")
    check(R.trick_kinds_of("Rocket Air") == R.trick_grabs and R.trick_kinds_of("FS Powerslide") == R.trick_grinds, "grabs and slides")
    check(R.trick_kinds_of("Tail Nosebone") == R.trick_grabs and R.trick_kinds_of("Fastplant") == R.trick_grabs and
          R.trick_kinds_of("Stalefish") == R.trick_grabs and R.trick_kinds_of("Ollie FS 180") == R.trick_flips, "skate.'s grabs, plants and spins")
    check(R.skate_letters(3, 7) == "R.E.S" and R.skate_letters(7, 7) == "R.E.S.K.A.T.E" and R.skate_letters(0, 7) == "", "letters spell R.E.S.K.A.T.E.")
    check(R.mode_name("skate") == "R.E.S.K.A.T.E." and R.parse_mode("reskate") == "skate" and R.parse_mode("skate") == "skate",
          "ReSkate's letters game is R.E.S.K.A.T.E.")
    local steps = R.trick_steps
    check(steps("Kickflip", false) == "[img {0}]FLICKIT_Kickflip_RS[/img]" and steps("Kickflip", true) == "[img {0}]FLICKIT_Heelflip_RS[/img]",
          "a kickflip's flick-it picture, by stance")
    local function has(text, part) return string.find(text, part, 1, true) ~= nil end
    check(steps("FS 180 Nollie Kickflip", false) == "[img {0}]FLICKIT_NollieKickflip_RS[/img]", "steps: FS 180 Nollie Kickflip")
    check(has(steps("Inward Heelflip", false), "FLICKIT_Inwardheelflip_RS"), "steps: Inward Heelflip")
    check(has(steps("BS Pop-Shuvit", false), "FLICKIT_BSPopshuvit_RS"), "steps: BS Pop-Shuvit")
    check(has(steps("Impossible", false), "FLICKIT_Impossible_RS"), "steps: Impossible")
    check(steps("BS 50-50 Grind", false) ~= "" and steps("Trick #42", false) == "", "steps: a grind has some, a made-up trick none")
    check(steps("Kickflip Underflip", false) ~= "" and steps("Nollie Heelflip Underflip", false) ~= "", "steps: underflips")
    check(steps("Late Kickflip", false) == "In air [img {0}]FLICKIT_Kickflip_RS[/img]", "steps: a late flip is in the air")
    check(has(steps("360 Flip", false), "FLICKIT_360Flip_RS"), "steps: 360 Flip")
    check(steps("Switch Kickflip", false) == steps("Kickflip", true), "steps: switch is the other stance")
    check(steps("Double Kickflip", false) == steps("Kickflip", false), "steps: a double kickflip is a kickflip's flick")
    check(has(steps("Fakie 360 Inward Heelflip FS 180", false), "Inwardheelflip"), "steps: spins and sides around the name")
    check(steps("Switch FS 360 Pop-Shuvit", false) ~= "" and has(steps("FS 180 Ollie", false), "FLICKIT_Ollie"), "steps: pop-shuvits and ollies")
    check(R.set_trick_name("Ollie + BS 50-50 Grind") == "BS 50-50 Grind" and R.set_trick_name("Ollie") == "Ollie" and
          R.set_trick_name("Nollie + Kickflip") == "Nollie + Kickflip", "an ollie into the trick is not part of it; a nollie is")
    check(R.copies_trick("Ollie + BS 50-50 Grind", "BS 50-50 Grind") and R.copies_trick("Heelflip + Seatbelt", "heelflip + seatbelt") and
          R.copies_trick("FS 180 Kickflip", "fs 180 kickflip"), "copies: an ollie into it and case aside")
    check(not R.copies_trick("FS 50-50 Grind", "BS 50-50 Grind") and not R.copies_trick("Seatbelt + Heelflip", "Heelflip + Seatbelt") and
          not R.copies_trick("Kickflip", "Kickflip + Indy") and not R.copies_trick("Kickflip + Indy", "Kickflip") and
          not R.copies_trick("Nollie + Kickflip", "Kickflip") and not R.copies_trick("FS 360 Kickflip", "FS 180 Kickflip") and
          not R.copies_trick("", "Kickflip"), "a different side, spin, order, nollie, more or less is not a copy")
    do
        local seven = S({mode = "skate", strikes = R.max_strikes})
        check(R.max_strikes == 7 and roundtrip(Msg({kind = "setup", leader = a, game = 7, settings = seven})), "seven letters are valid settings that reach everyone")
    end
    local s = S({mode = "skate", strikes = 2, trick_kinds = bit32.bor(R.trick_flips, R.trick_grinds)}) -- no grabs, no manuals
    check(R.trick_allowed(s, "Kickflip") and R.trick_allowed(s, "Heelflip + Seatbelt") and not R.trick_allowed(s, "Seatbelt") and
          not R.trick_allowed(s, "Manual"), "the leader's kinds: any part of an allowed kind will do")
    local r = R.Referee.new(s, a, 8)
    r:add(a)
    r:add(b)
    r:add(c)
    r:start(0)
    r:tick(countdown_ms)
    local t = countdown_ms
    local seq = {[a] = 0, [b] = 0, [c] = 0}
    local function try(id, landed, trick)
        seq[id] += 1
        r:event(id, "trick", landed, zero, seq[id], t, {}, trick)
    end
    local st = r:state(t)
    check(st.turn == a and st.setter == a and st.trick == "", "a sets first")
    try(b, 1, "Kickflip")
    check(r:state(t).trick == "", "only the player up counts")
    try(a, 1, "Seatbelt")
    st = r:state(t)
    check(st.setter == b and st.turn == b and st.trick == "", "a set a grab in a game without grabs: b sets")
    try(b, 1, "Kickflip")
    st = r:state(t)
    check(st.trick == "Kickflip" and st.turn == c, "b set the kickflip; c copies")
    try(c, 1, "kickflip")
    check(r:state(t).turn == a, "c landed it (any case); a copies")
    try(a, 1, "Heelflip")
    st = r:state(t)
    check(st.turn == b and st.trick == "", "round over: b sets again")
    check(of(st, a).aux == 1, "a did the wrong trick: S")
    try(b, 1, "Kickflip")
    st = r:state(t)
    check(st.setter == c and st.turn == c, "a trick set already cannot be set again: c sets")
    try(c, 0, "")
    check(r:state(t).setter == a, "a missed set passes it on, no letter")
    try(a, 1, "BS 50-50 Grind")
    try(b, 1, "BS 50-50 Grind")
    t += s.turn_s * 1000 -- c never tries
    r:tick(t)
    st = r:state(t)
    check(of(st, c).aux == 1, "running out of time is a letter")
    check(st.turn == a and st.setter == a, "back to the setter")
    try(a, 1, "Varial Kickflip")
    try(b, 0, "")
    try(c, 0, "")
    check(r:phase() == "playing" and r:state(t).turn == a, "c spelled S.K. (two letters) and is out; b has an S")
    try(a, 1, "Hardflip")
    try(b, 1, "Kickflip")
    check(r:phase() == "results", "b missed the hardflip: S.K., out, a wins")
    st = r:state(t)
    check(st.standings[1].player == a, "a is first")
    check(roundtrip(st), "a S.K.A.T.E. state round trips")
    check(roundtrip(Msg({kind = "event", leader = a, game = 8, event = "trick", value = 1, trick = "Heelflip + Seatbelt"})), "an attempt round trips")
    check(roundtrip(Msg({kind = "setup", leader = a, game = 8, settings = s})), "the trick kinds go with the setup")
    local hello = Msg({kind = "hello", leader = b, game = 1})
    check(roundtrip(hello), "a hello round trips")
    local other = with_byte(R.encode(hello), 1, R.wire_version - 1)
    check(R.decode(other) == nil and R.message_version(other) == R.wire_version - 1, "another version's hello is told apart, not read")
end

-- His race_builder_flow's long route (mode_rules_tests.cpp lines 317-339): fragments and reassembly.
function flows.fragments()
    local s = S({mode = "race", race_finish = true})
    for i = 0, 1026 do
        table.insert(s.points, v(i * 5, 0, 0))
        table.insert(s.yaws, 90)
        table.insert(s.widths, 6)
        table.insert(s.gate_kinds, if i == 1025 then "guide" else "required")
    end
    check(R.mandatory_gates(s, #s.points) == 1024, "guide and finish excluded from mandatory count")
    local long_route = Msg({kind = "setup", leader = a, game = 99, settings = s})
    local packets = R.transport_messages(long_route)
    check(#packets > 1, "long route is fragmented")
    local fits = true
    for _, packet in ipairs(packets) do
        if #packet > 4082 then fits = false end
    end
    check(fits, "each route fragment fits a plugin message (4082 bytes)")
    check(#packets[1] == 4082 and string.byte(packets[1], 3) == 9, "a full fragment: 27 header bytes and 4055 of the setup")
    check(#R.transport_messages(Msg({kind = "join", leader = a, game = 1})) == 1, "a short message is one packet")
    local incoming = R.ModeTransfers.new()
    local decoded = nil
    for i = #packets, 1, -1 do
        check(incoming:receive(b, packets[i], 1) == nil, "foreign sender cannot supply another host's route")
        local result = incoming:receive(a, packets[i], 1)
        if result then decoded = result end
    end
    check(same(decoded, long_route), "1024 mandatory gates, guide kind, poses and finish reconstruct out of order")
    incoming:clear()
    check(incoming:receive(a, packets[1], 1) == nil and incoming:receive(a, packets[1], 2) == nil, "duplicate fragment cannot complete a partial route")
    local corrupt = table.clone(packets)
    local last = corrupt[#corrupt]
    corrupt[#corrupt] = string.sub(last, 1, #last - 1) .. string.char(bit32.bxor(string.byte(last, #last), 1))
    decoded = nil
    for _, packet in ipairs(corrupt) do
        local result = incoming:receive(a, packet, 3)
        if result then decoded = result end
    end
    check(decoded == nil, "corrupt assembled route rejected")
    local invalid = packets[1]
    for i = 19, 22 do invalid = with_byte(invalid, i, 255) end
    check(incoming:receive(a, invalid, 4) == nil, "advertised huge allocation rejected before buffering")
    incoming:clear()
    incoming:receive(a, packets[1], 1)
    decoded = nil
    for i = 2, #packets do
        local result = incoming:receive(a, packets[i], 10002)
        if result then decoded = result end
    end
    check(decoded == nil, "expired incomplete route discarded")
    incoming:clear()
    for _, packet in ipairs(packets) do
        local result = incoming:receive(a, packet, 10003)
        if result then decoded = result end
    end
    check(same(decoded, long_route), "next periodic route publication recovers from missing fragments")
    local m, why = R.receive_mode_bytes(incoming, a, packets[1], 10004)
    check(m == nil and why == "partial", "a piece is partial")
    m, why = R.receive_mode_bytes(incoming, a, "\1\2\3", 10004)
    check(m == nil and why == "none", "a throwdown message is none of ours")
    local bad = Msg({kind = "setup", leader = a, game = 99, settings = R.deep_copy(s)})
    bad.settings.gate_kinds[#bad.settings.gate_kinds] = "guide"
    check(refused(bad), "finish cannot be optional")
    check(R.mode_transfer_hash("") == 2166136261 and R.mode_transfer_hash("a") == 0xe40c292c, "ReSkate: FNV-1a as his")
end

local order = {"area", "scoring", "wire", "jam", "one_up", "race", "race_clock", "race_optional", "gate_width", "skate_tag", "domination",
               "tag", "graffiti", "infection", "hide", "skate_solo", "reskate_merge_scope", "reskate_seven_letters", "skate", "fragments"}

-- Runs every flow: "N passed, M failed" and the failures, one a line.
function T.run()
    passed, failed = 0, {}
    for _, name in ipairs(order) do
        current = name
        local ok, err = pcall(flows[name])
        if not ok then table.insert(failed, name .. ": error: " .. tostring(err)) end
    end
    local text = string.format("%d passed, %d failed", passed, #failed)
    for _, line in ipairs(failed) do text ..= "\n  " .. line end
    return text
end

return T
