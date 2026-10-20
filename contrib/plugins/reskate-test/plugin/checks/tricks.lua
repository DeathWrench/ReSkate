local h = require("harness")
local t = h.module("tricks")

-- What the trick events said so far, and `ptest trick` waiting for one.
local seen = {started = 0, landed = 0, broken = 0}
local last_landed = nil
local waiting_until = nil

local function shown(v)
    return string.format("(%.1f, %.1f, %.1f)", v.x, v.y, v.z)
end

reskate.on("trick_started", function(e)
    seen.started += 1
    if waiting_until then reskate.console.print("ptest trick: started at " .. shown(e.at)) end
end)
reskate.on("trick_landed", function(e)
    seen.landed += 1
    last_landed = e
    if waiting_until then
        waiting_until = nil
        reskate.console.print(string.format("ptest trick: landed %.0f points at x%.1f in %.0f ms, from %s to %s",
            e.points, e.multiplier, e.ms, shown(e.started_at), shown(e.landed_at)))
    end
end)
reskate.on("line_broken", function(e)
    seen.broken += 1
    if waiting_until then reskate.console.print("ptest trick: the line broke: " .. e.reason) end
end)
reskate.on("tick", function()
    if waiting_until and reskate.time.now() > waiting_until then
        waiting_until = nil
        reskate.console.print("ptest trick: no trick landed in 30 s")
    end
end)

-- By hand: ptest trick, then land a trick within 30 s.
reskate.console.command("ptest trick", "Waits 30 s for a trick and prints what the trick events say", function()
    waiting_until = reskate.time.now() + 30000
    reskate.console.print("ptest trick: land a trick")
end)

t.check("a trick event needs a function", function()
    h.refused(reskate.on, "trick_landed", 5)
end)
t.check("score.current is nil without a score HUD, else the line", function()
    local s = reskate.score.current()
    if s == nil then return h.skip("no score HUD (in the menu, or on foot)") end
    assert(type(s.line) == "number" and s.line >= 0, "line " .. tostring(s.line))
    assert(type(s.multiplier) == "number" and s.multiplier >= 0, "multiplier " .. tostring(s.multiplier))
    assert(type(s.in_trick) == "boolean")
end)
t.check("a landed trick says its points, multiplier, places and time", function()
    if last_landed == nil then return h.skip("no trick landed since it loaded") end
    local e = last_landed
    assert(e.points >= 0 and e.multiplier >= 0 and e.ms >= 0, "points, multiplier, ms")
    assert(typeof(e.started_at) == "vector" and typeof(e.landed_at) == "vector", "places are vectors")
    assert(vector.magnitude(e.landed_at - e.started_at) < 200, "it went more than 200 m in one trick")
end)
t.check("tricks land after they start", function()
    if seen.landed == 0 then return h.skip("no trick landed since it loaded") end
    assert(seen.started >= seen.landed, seen.started .. " started, " .. seen.landed .. " landed")
end)
