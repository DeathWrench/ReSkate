local h = require("harness")
local t = h.module("skater")

local function skater()
    return reskate.skater.get()
end

t.check("get is nil without a skater, else its state", function()
    local s = skater()
    if s == nil then return h.skip("no skater (in the menu or a load)") end
    assert(typeof(s.position) == "vector", "position is a vector")
    assert(type(s.heading) == "number" and math.abs(s.heading) <= math.pi + 0.01, "heading in radians: " .. tostring(s.heading))
    assert(type(s.speed) == "number" and s.speed >= 0 and type(s.vertical_speed) == "number")
    assert(type(s.airborne) == "boolean" and type(s.air_time) == "number")
end)
t.check("the single readers agree with get", function()
    local s = skater()
    if s == nil then return h.skip("no skater") end
    assert(reskate.skater.position() == s.position and reskate.skater.heading() == s.heading)
    assert(reskate.skater.on_ground() == not s.airborne)
end)
t.check("a ray down from the skater meets the ground under it", function()
    local s = skater()
    if s == nil then return h.skip("no skater") end
    if s.airborne then return h.skip("the skater is in the air") end
    local hit = reskate.world.raycast(s.position + vector.create(0, 2, 0), s.position - vector.create(0, 5, 0))
    assert(hit, "nothing under the skater")
    assert(math.abs(hit.y - s.position.y) < 1.5, string.format("the ground is %.2f m from the skater", hit.y - s.position.y))
end)
t.check("a ray through the air meets nothing", function()
    local s = skater()
    if s == nil then return h.skip("no skater") end
    local up = s.position + vector.create(0, 400, 0)
    assert(reskate.world.raycast(up, up + vector.create(0, 50, 0)) == nil, "something 400 m up")
end)
t.check("bad positions and long rays are refused", function()
    h.refused(reskate.skater.teleport, vector.create(0 / 0, 0, 0))
    h.refused(reskate.skater.teleport, vector.create(1e7, 0, 0))
    h.refused(reskate.skater.teleport, {1, 2, 3})
    h.refused(reskate.skater.teleport, vector.create(0, 0, 0), 0 / 0)
    h.refused(reskate.world.raycast, vector.create(0, 0, 0), vector.create(2000, 0, 0))
    h.refused(reskate.world.raycast, vector.create(0, 0, 0), "up")
end)

-- By hand, since it moves you: ptest tp teleports the skater 3 m ahead, turned a quarter turn to
-- the right. A higher heading turns the skater left, so a right turn takes a quarter off.
reskate.console.command("ptest tp", "Teleports the skater 3 m ahead, a quarter turn to the right", function()
    local s = skater()
    if s == nil then
        reskate.console.print("ptest tp: no skater")
        return
    end
    local ahead = vector.create(math.sin(s.heading), 0, math.cos(s.heading)) * 3
    local ok, why = reskate.skater.teleport(s.position + ahead + vector.create(0, 0.5, 0), s.heading - math.pi / 2)
    reskate.console.print("ptest tp: " .. (ok and "sent" or ("refused: " .. tostring(why))))
end)
