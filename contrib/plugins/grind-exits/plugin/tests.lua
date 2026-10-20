-- Checks of the trigger rules, run by `grindexit test` (and by dingosdk_plugin_tests, without the game).
local triggers = require("triggers")

local checks = {}
local function check(title, fn) table.insert(checks, {title = title, fn = fn}) end

check("a trigger pressed in a grind picks the side and is kept from the game", function()
    local s = triggers.new()
    triggers.step(s, 0, 0, 0, true)
    triggers.step(s, 16, 1, 0, true)
    assert(triggers.chosen(s, 16) == "lt")
    local h = triggers.hidden(s, true, true)
    assert(h.left_trigger and not h.right_trigger and h.left_x == "grinding")
end)
check("a trigger pressed before the grind counts within the window", function()
    local s = triggers.new()
    triggers.step(s, 0, 0, 1, false) -- pressed in the air
    assert(triggers.chosen(s, 0) == nil, "not before the grind connects")
    triggers.step(s, 600, 0, 1, true, 1000)
    assert(triggers.chosen(s, 600) == "rt", "it counts once it does")
    local late = triggers.new()
    triggers.step(late, 0, 0, 1, false)
    triggers.step(late, 1500, 0, 1, true, 1000)
    assert(triggers.chosen(late, 1500) == nil, "pressed too long before: the game's own")
end)
check("both triggers are the game's own exit", function()
    local s = triggers.new()
    triggers.step(s, 0, 1, 1, true)
    assert(triggers.chosen(s, 0) == nil)
end)
check("a trigger let go just before the pop still counts, then not", function()
    local s = triggers.new()
    triggers.step(s, 0, 1, 0, true)
    triggers.step(s, 50, 0, 0, true)
    assert(triggers.chosen(s, 100) == "lt", "within the grace")
    assert(triggers.chosen(s, 200) == nil, "past it")
    assert(not triggers.hidden(s, true, true).left_trigger, "let go, it is the game's again")
end)
check("a press needs 40 %, a release 20 %", function()
    local s = triggers.new()
    triggers.step(s, 0, 0.3, 0, true)
    assert(triggers.chosen(s, 0) == nil)
    triggers.step(s, 16, 0.5, 0, true)
    triggers.step(s, 32, 0.3, 0, true)
    assert(triggers.chosen(s, 32) == "lt", "still held at 30 %")
end)
check("the guards can be off", function()
    local s = triggers.new()
    triggers.step(s, 0, 1, 0, true)
    local h = triggers.hidden(s, false, false)
    assert(not h.left_trigger and h.left_x == nil)
end)
check("toe and heel, or left and right of travel", function()
    assert(triggers.side("lt", true) == "toe" and triggers.side("rt", true) == "heel")
    assert(triggers.side("lt", false) == "left" and triggers.side("rt", false) == "right")
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
