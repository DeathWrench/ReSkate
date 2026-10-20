local h = require("harness")
local t = h.module("wider")

-- What ptest all checks of the wider set reads the game and changes nothing. What changes things
-- is by hand: ptest noclip, boost, hidehud, object, night, day, ai, screen, bind, music, chat, web.

reskate.on("action", function(name) reskate.console.print("ptest bind: " .. name .. " pressed") end)
reskate.on("screen_closed", function(title) reskate.console.print("ptest screen: " .. title .. " closed") end)
reskate.on("chat", function(line)
    if line.text:find("ptest", 1, true) then reskate.console.print("ptest chat: heard " .. line.name) end
end)
reskate.on("track_changed", function(track) reskate.console.print("ptest music: now " .. track.title .. " by " .. track.artist) end)

-- Libraries: what this plugin offers others, as reskate.require_plugin("ReSkate_Test") gets it.
reskate.expose({version = function() return "0.1.0" end, add = function(a, b) return a + b end})

t.check("the skater's state is a name, or nil without one", function()
    local state = reskate.skater.state()
    local names = {"riding", "air", "wipeout", "grinding", "off_board", "planted", "other", "none"}
    assert(state == nil or table.find(names, state), tostring(state))
end)
t.check("a boost must be forward, up or offboard", function() h.refused(reskate.skater.boost, "sideways") end)
t.check("the object catalog and the map's objects are lists", function()
    local catalog, list = reskate.objects.catalog(), reskate.objects.list()
    assert(type(catalog) == "table" and type(list) == "table")
    if catalog[1] then assert(type(catalog[1].key) == "string" and type(catalog[1].title) == "string") end
    if list[1] then assert(typeof(list[1].position) == "vector" and type(list[1].id) == "string") end
    h.refused(reskate.objects.remove, "not an id")
    h.refused(reskate.objects.place, "x", vector.create(0 / 0, 0, 0))
end)
t.check("travel lists its destinations and levels", function()
    assert(type(reskate.travel.locations()) == "table" and type(reskate.travel.levels()) == "table")
end)
t.check("AI skaters are counted, and 1 to 8 at a time", function()
    assert(type(reskate.ai.count()) == "number")
    h.refused(reskate.ai.spawn, 20)
end)
t.check("other players' skaters are a list", function()
    for _, s in reskate.session.skaters() do assert(type(s.id) == "string" and typeof(s.position) == "vector") end
end)
t.check("nametags and voice want a player", function()
    h.refused(reskate.session.tag, "not a player", "x")
    h.refused(reskate.voice.set_volume, "7", 20)
end)
t.check("a chat line is not a command", function() h.refused(reskate.chat.send, "/kick someone") end)
t.check("throwdowns, music, progress and settings read", function()
    local throwdown = reskate.throwdowns.state()
    assert(type(throwdown.active) == "boolean" and type(throwdown.skate) == "table")
    local track = reskate.music.current()
    assert(track == nil or type(track.title) == "string")
    local progress = reskate.progression.get()
    assert(progress == nil or (type(progress.districts) == "table" and type(progress.score) == "number"))
    assert(type(reskate.settings.names()) == "table")
end)
t.check("keys and pad combos bind, others are refused", function()
    assert(reskate.input.bind("ptest", "F8"))
    h.refused(reskate.input.bind, "ptest-bad", "Esc")
end)
t.check("a library refuses a call into itself", function()
    local me = reskate.require_plugin(reskate.id)
    assert(me and me.version, "it lists its own functions")
    local ok, err = pcall(me.version)
    assert(not ok and err:find("own functions", 1, true), err)
end)
t.check("a web request goes only to the manifest's domains", function()
    h.refused(reskate.http.request, {url = "https://example.com/"}, function() end)
    h.refused(reskate.http.request, {url = "http://api.github.com/"}, function() end)
end)

-- ---- by hand ---------------------------------------------------------------------------------
local function said(name, ok, why)
    reskate.console.print("ptest " .. name .. ": " .. (ok and "done" or ("refused: " .. tostring(why))))
end
local noclip = false
reskate.console.command("ptest noclip", "Switches noclip on or off", function()
    noclip = not noclip
    said("noclip " .. (noclip and "on" or "off"), reskate.skater.noclip(noclip))
end)
reskate.console.command("ptest boost", "Boosts the skater up", function() said("boost", reskate.skater.boost("up")) end)
local hidden = false
reskate.console.command("ptest hidehud", "Hides or shows the game's HUD", function()
    hidden = not hidden
    reskate.hud.hide(hidden)
    reskate.console.print("ptest hidehud: " .. (hidden and "hidden" or "shown"))
end)
reskate.console.command("ptest object", "Places the first catalog object 4 m ahead", function()
    local s, item = reskate.skater.get(), reskate.objects.catalog()[1]
    if not s or not item then
        reskate.console.print("ptest object: no skater, or no objects to place")
        return
    end
    local at = s.position + vector.create(math.sin(s.heading), 0, math.cos(s.heading)) * 4
    said("object " .. item.title, reskate.objects.place(item.key, at, s.heading))
end)
reskate.console.command("ptest night", "Makes it night on this map", function() said("night", reskate.world.set_time("night")) end)
reskate.console.command("ptest day", "Gives the map its own time of day back", function() said("day", reskate.world.set_time("default")) end)
reskate.console.command("ptest ai", "Spawns 2 AI skaters, or clears them", function()
    if reskate.ai.count() > 0 then said("ai clear", reskate.ai.clear()) else said("ai spawn", reskate.ai.spawn(2)) end
end)
local presses = 0
reskate.ui.screen("reskate-test", function(ui)
    ui:heading("A full-screen screen")
    ui:label("Esc closes it. The button counts its presses.")
    if ui:button("press", "PRESS ME") then presses += 1 end
    ui:label("Pressed " .. presses .. " times")
end)
reskate.console.command("ptest screen", "Opens reskate-test's full-screen screen", function() reskate.ui.open("reskate-test") end)
reskate.console.command("ptest bind", "Says when F8 is pressed", function()
    assert(reskate.input.bind("ptest", "F8"))
    reskate.console.print("ptest bind: press F8")
end)
reskate.console.command("ptest music", "Skips the outside player's song", function() said("music next", reskate.music.next()) end)
reskate.console.command("ptest chat", "Says hello in the session's chat", function() said("chat", reskate.chat.send("ptest says hello")) end)
reskate.console.command("ptest web", "Asks api.github.com for a zen line", function()
    local id, why = reskate.http.request({url = "https://api.github.com/zen"}, function(status, body, err)
        reskate.console.print("ptest web: " .. status .. " " .. (err or body))
    end)
    if not id then reskate.console.print("ptest web: " .. tostring(why)) end
end)
