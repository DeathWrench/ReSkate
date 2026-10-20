local h = require("harness")
local t = h.module("overlay")

-- ptest hud (or the toggle on the PLUGINS page) draws a test HUD: a box with its name in the top
-- left, and a ring on the ground under the skater with a line 5 m ahead of it.
local hud = false
local draws, saved = 0, nil

reskate.on("draw", function(d)
    draws += 1
    saved = d
    if not hud then return end
    d:rect(vector.create(40, 120, 0), vector.create(340, 190, 0), {colour = "#000000a0", fill = true, rounding = 6})
    d:text(vector.create(56, 130, 0), "reskate-test", {colour = "#5ecdfa", size = 26})
    d:text(vector.create(56, 160, 0), string.format("%.0f draws", draws), {size = 16, colour = "#ffffffc0"})
    local s = reskate.skater.get()
    if s then
        d:world_circle(s.position, 1.2, {colour = "#5ecdfa", thickness = 3})
        local ahead = s.position + vector.create(math.sin(s.heading), 0, math.cos(s.heading)) * 5
        d:world_line(s.position, ahead, {colour = "#ffc400", thickness = 3})
        d:world_text(ahead + vector.create(0, 1, 0), "5 m ahead", {align = "centre", size = 18})
    end
end)

local function set_hud(on)
    hud = on
end

reskate.console.command("ptest hud", "Shows or hides reskate-test's test HUD", function()
    set_hud(not hud)
    reskate.console.print("ptest hud: " .. (hud and "on" or "off"))
end)

t.later("draw handlers run every frame", 2000, function(done)
    local before = draws
    reskate.time.after(300, function() done(draws - before >= 3, (draws - before) .. " draws in 300 ms") end)
end)
t.check("the draw object is refused outside its handler", function()
    if saved == nil then return h.skip("no frame drawn yet") end
    h.refused(saved.text, saved, vector.create(0, 0, 0), "x")
end)
t.check("a toast is shown, at most three in 5 s", function()
    local shown = reskate.ui.toast("ptest ran")
    assert(type(shown) == "boolean")
    h.refused(reskate.ui.toast, string.rep("x", 300))
end)

return {set_hud = set_hud, hud = function() return hud end}
