-- Checks of Hall of Meat's model and card with made-up physics steps, run by `hallofmeat test` (and by
-- dingosdk_plugin_tests, without the game).
local model = require("model")
local card = require("card")

local checks = {}
local function check(title, fn) table.insert(checks, {title = title, fn = fn}) end
local function near(a, b, within) return math.abs(a - b) < (within or 1e-4) end
local t0 = 100000

-- The game stepping its physics at `speed` (1 full speed): each step as long in the game's time as
-- the real time since the one before, times the speed.
local function game(speed)
    local g = {tracker = model.tracker(), speed = speed or 1, last = nil}
    function g:step(now, step)
        local s = table.clone(step)
        s.seconds = self.last and now > self.last and (now - self.last) / 1000 * self.speed or 0
        self.last = now
        return self.tracker:step(now, s)
    end
    function g:view(now) return self.tracker:view(now) end
    function g:phase(now) return self.tracker:phase_at(now) end
    -- Steps `step` from `now` on, every 16 ms, for `ms`; returns the time after the last.
    function g:keep(now, ms, step)
        local stop = now + ms
        while now < stop do
            self:step(now, step)
            now += 16
        end
        return now
    end
    return g
end
local function lying() return {ragdoll = true, bodies = {}} end
local function standing_up() return {ragdoll = false, bodies = {}} end
local function hit(body, speed, wipeout)
    local s = lying()
    s.wipeout = wipeout == true
    s.bodies[body] = {impact = speed, slide = 0, world = true}
    return s
end
local function riding_hit(body, speed)
    local s = hit(body, speed)
    s.ragdoll = false
    return s
end
local function wipeout() return {ragdoll = true, wipeout = true, bodies = {}} end
local function flying(ragdoll) return {airborne = true, ragdoll = ragdoll ~= false, bodies = {}} end
local function slide(body, speed, wipeout)
    local s = lying()
    s.wipeout = wipeout == true
    s.bodies[body] = {impact = 0, slide = speed, world = true}
    return s
end
local function moving(speed)
    local s = lying()
    s.velocity = {speed, 0, 0}
    return s
end

check("impacts count only during a bail", function()
    local g = game()
    assert(g:step(t0, riding_hit("Head", 9)) == nil and g:view(t0).phase == "riding")
    local later = t0 + model.wipeout_after_impact_ms + 16
    g:step(later, wipeout())
    assert(g:phase(later) == "bailing", "a wipeout starts a bail")
    assert((g:view(later).injuries["Head"] or "none") == "none", "an impact long before the bail is not counted")
end)
check("the hit that causes the wipeout counts, at its hardest", function()
    local g = game()
    g:step(t0, riding_hit("Right thigh", 35))
    g:step(t0 + 16, riding_hit("Right thigh", 12))
    g:step(t0 + 32, wipeout())
    local view = g:view(t0 + 32)
    assert(view.phase == "bailing" and view.injuries["Right thigh"] == "broken")
    assert(view.tally.impacts == 1 and view.tally.hit_points == model.hit_points(35))
end)
check("nothing shows until a bone is hurt", function()
    local g = game()
    g:step(t0, wipeout())
    g:step(t0 + 16, hit("Spine", model.hit_speed - 0.5))
    assert(g:phase(t0 + 16) == "bailing" and g:view(t0 + 16).phase == "riding")
    g:step(t0 + 32, hit("Spine", model.hit_speed))
    local view = g:view(t0 + 32)
    assert(view.phase == "bailing" and near(view.alpha, 1) and view.tally.impacts == 1)
    local unhurt = game()
    unhurt:step(t0, hit("Spine", model.hit_speed - 0.5, true))
    local summary = unhurt:step(t0 + 16, standing_up())
    assert(summary and not summary.shown and unhurt:view(t0 + 32).phase == "riding")
end)
check("hard hits break, light ones bruise, a fresh hit flashes", function()
    local g = game()
    g:step(t0, hit("Left forearm", model.hit_speed + 0.1, true))
    g:step(t0 + 16, hit("Head", model.broken_speed + 0.1))
    g:step(t0 + 32, hit("Spine", model.hit_speed - 0.1))
    g:step(t0 + 48, hit("Left forearm", 1))
    local view = g:view(t0 + 48)
    assert(view.injuries["Left forearm"] == "hit" and view.injuries["Head"] == "broken" and view.injuries["Spine"] == "none")
    assert(view.flashes["Head"] > 0.9 and (g:view(t0 + 16 + model.flash_ms).flashes["Head"] or 0) == 0)
end)
check("a flump starts no bail", function()
    local g = game()
    local now = g:keep(t0, 1500, flying())
    for i = 1, 60 do
        local s = hit(i % 2 == 0 and "Left upper arm" or "Spine", model.broken_speed + 5)
        s.velocity = {8, -6, 0}
        g:step(now, s)
        now += 16
    end
    assert(g:view(now).phase == "riding" and g:step(now, standing_up()) == nil)
end)
check("a break pulses the screen edge and slows the game as one", function()
    local g = game()
    g:step(t0, hit("Left hand", model.hit_speed + 1, true))
    assert(g:view(t0 + 16).break_pulse == 0 and g.tracker:game_speed(t0 + 16) == 1)
    g:step(t0 + 16, hit("Left forearm", model.broken_speed + 1))
    local broke = t0 + 16
    assert(near(g:view(broke + model.break_rise_ms / 2).break_pulse, 0.5), "pulses up")
    assert(near(g:view(broke + model.break_rise_ms).break_pulse, 1), "to its full strength")
    assert(near(g.tracker:game_speed(broke + model.break_rise_ms), model.break_game_speed), "slow")
    assert(near(g:view(broke + model.break_rise_ms + model.break_hold_ms + model.break_fall_ms / 2).break_pulse, 0.5), "and fades")
    assert(g:view(broke + model.break_effect_ms).break_pulse == 0 and g.tracker:game_speed(broke + model.break_effect_ms) == 1)
    g:step(broke + model.break_effect_ms, hit("Left forearm", model.broken_speed + 5))
    assert(g:view(broke + model.break_effect_ms + model.break_rise_ms).break_pulse == 0, "a broken bone hit again does not pulse")
end)
check("the board and bad values are ignored", function()
    local g = game()
    local s = wipeout()
    s.bodies["Board"] = {impact = 20}
    s.bodies["Pelvis"] = {impact = 0 / 0}
    s.bodies["Lower back"] = {impact = -8}
    g:step(t0, s)
    for _, injury in g:view(t0).injuries do assert(injury == "none") end
end)
check("a bail lasts until the skater gets up, then lingers and fades", function()
    local g = game()
    g:step(t0, hit("Pelvis", model.hit_speed + 1, true))
    local now = g:keep(t0 + 16, 3000, hit("Chest", 2))
    now = g:keep(now, 6000, lying())
    g:step(now, hit("Head", model.hit_speed + 1))
    now = g:keep(now + 16, 1000, lying())
    assert(g:view(now).phase == "bailing" and g:view(now).tally.impacts == 2)
    local summary = g:step(now, standing_up())
    assert(summary and near(summary.tally.seconds, (now - t0) / 1000, 0.02) and summary.shown)
    assert(g:view(now + model.linger_ms - 16).phase == "getting_up" and near(g:view(now + model.linger_ms - 16).alpha, 1))
    assert(near(g:view(now + model.linger_ms + model.fade_ms / 2).alpha, 0.5))
    assert(g:view(now + model.linger_ms + model.fade_ms).phase == "riding")
end)
check("a rest ends the counting", function()
    local g = game()
    g:step(t0, hit("Pelvis", model.hit_speed + 1, true))
    local now = g:keep(t0 + 16, 1000, moving(4))
    local went_still = now
    now = g:keep(now, model.rest_ms - 16, moving(0.2))
    assert(g:phase(now - 16) == "bailing")
    now = g:keep(now, 32, moving(0.1))
    assert(g:phase(now) == "down" and near(g:view(now).tally.seconds, (went_still - t0) / 1000, 0.02))
    local rested = g:view(now).tally.score
    local getting_up = hit("Left foot", model.hit_speed + 1)
    getting_up.velocity = {0, 3, 2}
    now = g:keep(now + 3000, 600, getting_up)
    assert(g:view(now).tally.score == rested, "getting up adds nothing")
end)
check("a fall from height bails at its wipeout, with the whole flight's airtime", function()
    local g = game()
    local now = g:keep(t0, 500, flying(false))
    now = g:keep(now, 2000, flying())
    assert(g:phase(now) == "riding")
    g:step(now, hit("Head", 20, true))
    assert(g:view(now).phase == "bailing" and g:view(now).tally.impacts == 1)
    assert(math.abs(g:view(now).tally.airtime - 2.5) < 0.02)
end)
check("a stumble without a ragdoll ends", function()
    local g = game()
    local stumble = wipeout()
    stumble.ragdoll = false
    g:step(t0, stumble)
    assert(g:phase(g:keep(t0 + 16, model.ragdoll_wait_ms - 32, standing_up())) == "bailing")
    assert(g:step(t0 + model.ragdoll_wait_ms, standing_up()) ~= nil)
end)
check("a lost skater ends the bail", function()
    local g = game()
    assert(g.tracker:lose(t0) == nil)
    g:step(t0, hit("Pelvis", model.hit_speed + 1, true))
    local summary = g.tracker:lose(t0 + 500)
    assert(summary and summary.shown and g:view(t0 + 500).phase == "getting_up" and g.tracker:lose(t0 + 516) == nil)
end)
check("one contact is one impact; points grow faster than speed", function()
    local g = game()
    local light, harder = model.hit_speed + 0.5, model.broken_speed - 1
    g:step(t0, hit("Spine", light, true))
    g:step(t0 + 16, hit("Spine", harder))
    g:step(t0 + 32, hit("Spine", 2))
    local tally = g:view(t0 + 32).tally
    assert(tally.impacts == 1 and tally.damage == model.hit_points(harder))
    g:step(t0 + 32 + model.impact_gap_ms + 16, hit("Spine", light))
    tally = g:view(t0 + 32 + model.impact_gap_ms + 16).tally
    assert(tally.impacts == 2 and tally.damage == model.hit_points(harder) + model.hit_points(light))
    assert(model.hit_points(model.hit_speed - 0.1) == 0 and model.hit_points(model.hit_speed) == 100 and model.hit_points(30) == 887)
end)
check("the Meat adds up: a hit to the head counts double, a vehicle half again", function()
    local g = game()
    local breaks, bruises = model.broken_speed + 1, model.hit_speed + 1
    g:step(t0, hit("Head", breaks, true))
    g:step(t0 + 16, hit("Left hand", bruises))
    local tally = g:view(t0 + 16).tally
    assert(tally.broken == 1 and tally.impacts == 2 and tally.head_bonus == model.hit_points(breaks))
    assert(tally.score == 2 * model.hit_points(breaks) + model.hit_points(bruises) + model.points_per_break + tally.time_points)
    local car = game()
    local s = hit("Spine", 10, true)
    s.bodies["Spine"].vehicle = true
    car:step(t0, s)
    car:step(t0 + 16, hit("Spine", 12))
    assert(car:view(t0 + 16).tally.vehicle_bonus == math.floor(model.hit_points(12) * 0.5 + 0.5))
end)
check("sliding along the ground is road rash, the board and the feet are not", function()
    local g = game()
    g:step(t0, slide("Pelvis", 5, true))
    local now = t0
    for _ = 1, 50 do
        now += 20
        g:step(now, slide("Pelvis", 5))
    end
    local view = g:view(now)
    assert(math.abs(view.tally.scraped - 5) < 1e-3 and view.injuries["Pelvis"] == "hit" and view.tally.impacts == 0)
    local board = game()
    local on_board = slide("Spine", 5, true)
    on_board.bodies["Spine"] = {impact = 0, slide = 5, board = true}
    board:step(t0, on_board)
    board:step(t0 + 1000, on_board)
    board:step(t0 + 1020, slide("Left foot", 5))
    board:step(t0 + 1040, slide("Spine", model.scrape_speed - 0.1))
    assert(board.tracker:tally().scraped == 0)
end)
check("the fall, the top speed and the turning score", function()
    local g = game()
    local falling = flying(false)
    falling.velocity = {3, -10, 0}
    local now = g:keep(t0, 2000, falling)
    local impact = hit("Pelvis", model.hit_speed + 2, true)
    impact.velocity = {12, -16, 0}
    g:step(now, impact)
    local rolling = lying()
    rolling.velocity = {0, 2, 4}
    rolling.spin = 2 * model.radians_per_rotation
    now = g:keep(now + 16, 500, rolling)
    local t = g:view(now).tally
    assert(math.abs(t.fallen - 19.84) < 0.05 and near(t.top_speed, 20, 0.01))
    assert(t.score == t.damage + t.broken * model.points_per_break + t.time_points + t.airtime_points + t.fall_points + t.speed_points +
        t.rotation_points)
end)
check("a bail runs on the game's clock", function()
    local slow = game(model.break_game_speed)
    local thrown = hit("Left shin", model.hit_speed + 1, true)
    thrown.ragdoll = false
    slow:step(t0, thrown)
    local falling = flying(false)
    falling.velocity = {0, -10, 0}
    local now = slow:keep(t0 + 16, 1000, falling)
    assert(slow:phase(now) == "bailing", "the ragdoll still has the game's moment to begin")
end)
check("a best is set only by beating it", function()
    assert(model.standing(0, 300).new_best and model.standing(0, 300).best == 300)
    assert(not model.standing(500, 300).new_best and not model.standing(500, 500).new_best)
end)
check("the card shows the bail", function()
    assert(card.grouped(0) == "0" and card.grouped(999) == "999" and card.grouped(1000) == "1,000" and card.grouped(1234567) == "1,234,567")
    assert(card.grouped(-1234) == "-1,234")
    local g = game()
    assert(card.make(g:view(t0), nil).opacity == 0)
    g:step(t0, hit("Head", model.broken_speed + 1, true))
    g:step(t0 + 16, hit("Left hand", model.hit_speed + 1))
    g:step(g:keep(t0 + 32, 1456, lying()) + 12, lying())
    local view = g:view(t0 + 1500)
    local shown = card.make(view, model.standing(0, view.tally.score))
    assert(near(shown.opacity, 1) and shown.total == view.tally.score)
    assert(#shown.rows == 1 and shown.rows[1].stat == "time" and shown.rows[1].value == "1.5 s")
    assert(shown.badge == "NEW BEST" and shown.highlight)
    shown = card.make(view, model.standing(99999, view.tally.score))
    assert(shown.badge == "BEST 99,999" and not shown.highlight and card.make(view, nil).badge == "")
end)

local tests = {}
function tests.run()
    local passed, failures = 0, {}
    for _, c in checks do
        local ok, why = pcall(c.fn)
        if ok then passed += 1 else table.insert(failures, c.title .. ": " .. tostring(why)) end
    end
    return passed, failures
end
return tests
