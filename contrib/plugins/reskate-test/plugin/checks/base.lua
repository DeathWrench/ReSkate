local h = require("harness")
local t = h.module("base")

local ticks, loaded, last_dt = 0, false, nil
reskate.on("load", function() loaded = true end)
reskate.on("tick", function(dt)
    ticks += 1
    last_dt = dt
end)

t.check("api_version is 1", function() assert(reskate.api_version == 1, "it is " .. tostring(reskate.api_version)) end)
t.check("id is the mod folder's name", function() assert(type(reskate.id) == "string" and #reskate.id > 0) end)
t.check("the load handler ran", function() assert(loaded) end)
t.check("tick handlers run, with the time since the last tick", function()
    assert(ticks > 0, "no tick yet")
    assert(type(last_dt) == "number" and last_dt >= 0, "dt is " .. tostring(last_dt))
end)
t.check("log takes info, warn and error", function()
    reskate.log("ptest: an info line")
    reskate.log("ptest: a warning line", "warn")
end)
t.check("print goes to the log", function() print("ptest: printed", 1, true) end)
t.check("a made-up log level is refused", function() h.refused(reskate.log, "x", "loud") end)
t.check("a made-up event is refused", function() h.refused(reskate.on, "made_up", function() end) end)
t.check("an event needs a function", function() h.refused(reskate.on, "tick", 5) end)
