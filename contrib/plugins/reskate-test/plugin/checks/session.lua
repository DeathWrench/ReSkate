local h = require("harness")
local t = h.module("session")

-- ptest ping: every other player running reskate-test answers pong.
reskate.on("message", function(from, text)
    if text == "ping" then
        reskate.net.send(from, "pong")
    elseif text == "pong" then
        reskate.console.print("ptest ping: pong from " .. from.name)
    end
end)
reskate.on("player_joined", function(p)
    if not p.me then reskate.console.print("ptest: " .. p.name .. " joined") end
end)
reskate.console.command("ptest ping", "Asks every other player running reskate-test to answer", function()
    if not reskate.session.active() then
        reskate.console.print("ptest ping: not in a session")
        return
    end
    reskate.console.print("ptest ping: " .. (reskate.net.send("all", "ping") and "sent" or "not sent"))
end)

t.check("the session says whether it is on", function()
    assert(type(reskate.session.active()) == "boolean" and type(reskate.session.is_dedicated()) == "boolean")
end)
t.check("in a session, the players include you", function()
    if not reskate.session.active() then return h.skip("not in a session") end
    local me = reskate.session.me()
    assert(me and me.me and type(me.id) == "string" and #me.id > 0, "me")
    local found = false
    for _, p in reskate.session.players() do found = found or p.id == me.id end
    assert(found, "you are not among the players")
end)
t.check("bad messages are refused", function()
    h.refused(reskate.net.send, "nobody", "x")
    h.refused(reskate.net.send, "all", string.rep("x", 5000))
end)
