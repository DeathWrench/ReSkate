-- reskate-hostile: a plugin written to break the sandbox, one attack per command. Every attack
-- must end with this plugin stopped or refused and the game running as before. `hostile list`
-- names them; after one that stops it, `plugin on reskate-hostile` starts it again.
local attacks, order = {}, {}
local function attack(name, expect, fn)
    attacks[name] = {expect = expect, fn = fn}
    table.insert(order, name)
end

attack("loop", "stopped: longer than 50 ms", function()
    while true do end
end)
attack("caught-loop", "stopped: longer than 50 ms, though it catches the error", function()
    while true do pcall(function() while true do end end) end
end)
attack("tick-loop", "stopped at the next tick", function()
    reskate.on("tick", function() while true do end end)
end)
attack("memory", "stopped: more than 64 MB", function()
    local t = {}
    while true do t[#t + 1] = string.rep("x", 8000000) end
end)
attack("caught-memory", "stopped: more than 64 MB, though it catches the error", function()
    pcall(function()
        local t = {}
        while true do t[#t + 1] = string.rep("y", 8000000) end
    end)
    reskate.console.print("ESCAPED: carried on after a memory bomb")
end)
attack("huge-string", "stopped: more than 64 MB", function()
    local s = string.rep("x", 100000000)
    return #s
end)
attack("buffer", "stopped: more than 64 MB", function()
    local b = buffer.create(1e9)
    return buffer.len(b)
end)
attack("coroutines", "stopped: its time or its memory", function()
    while true do coroutine.wrap(function() end)() end
end)
attack("errors", "stopped after 5 errors in 10 s", function()
    reskate.on("tick", function() error("hostile: an error every tick") end)
end)
attack("slow", "stopped after 3 s over 2 ms a tick", function()
    reskate.on("tick", function()
        local start = os.clock()
        while os.clock() - start < 0.004 do end
    end)
end)
attack("log-flood", "keeps running: 50 of the 1000 lines are logged", function()
    for i = 1, 1000 do reskate.log("hostile flood " .. i) end
end)
attack("timers", "keeps running: refused past 1024 timers", function()
    for i = 1, 2000 do reskate.time.after(600000, function() end) end
end)
attack("recursion", "keeps running: an error, not a crash", function()
    local function deep(n) return deep(n + 1) + 1 end
    return deep(1)
end)
attack("slow-unload", "an unload handler that never ends: cut off at 20 ms when it is switched off", function()
    reskate.on("unload", function() while true do end end)
    reskate.console.print("hostile: now switch it off: plugin off reskate-hostile")
end)

attack("teleport-spam", "keeps running: two teleports a second, the rest refused", function()
    local sent = 0
    for i = 1, 1000 do
        if reskate.skater.teleport(vector.create(0, 0, 0)) then sent += 1 end
    end
    reskate.console.print("hostile teleport-spam: " .. sent .. " of 1000 sent")
end)
attack("raycast-flood", "keeps running: refused past 64 raycasts a tick", function()
    for i = 1, 100000 do reskate.world.raycast(vector.create(0, 100, 0), vector.create(0, -100, 0)) end
end)

attack("trick-loop", "stopped at the next trick landed", function()
    reskate.on("trick_landed", function() while true do end end)
    reskate.console.print("hostile: now land a trick")
end)

attack("draw-flood", "keeps running: 4000 shapes a frame are drawn, the rest left out", function()
    reskate.on("draw", function(d)
        for i = 1, 20000 do d:line(vector.create(0, 0, 0), vector.create(i % 1920, 500, 0)) end
    end)
end)
attack("toast-spam", "keeps running: three toasts, the rest refused", function()
    local shown = 0
    for i = 1, 100 do if reskate.ui.toast("hostile toast " .. i) then shown += 1 end end
    reskate.console.print("hostile toast-spam: " .. shown .. " of 100 shown")
end)
attack("sound-spam", "keeps running: ten sounds a second, the rest refused", function()
    local played = 0
    for i = 1, 1000 do if reskate.audio.play_ui("select") then played += 1 end end
    reskate.console.print("hostile sound-spam: " .. played .. " of 1000 played")
end)
attack("message-flood", "keeps running: refused past 16 KB of messages a second", function()
    for i = 1, 1000 do reskate.net.send("all", string.rep("x", 4000)) end
end)
attack("panel-loop", "stopped the next time the menu shows its page", function()
    reskate.menu.panel("hostile", function(ui) while true do end end)
    reskate.console.print("hostile: now open its page in the menu's PLUGINS section")
end)

attack("chat-spam", "keeps running: one chat line every 3 s, the rest refused", function()
    local sent = 0
    for i = 1, 100 do if reskate.chat.send("hostile spam " .. i) then sent += 1 end end
    reskate.console.print("hostile chat-spam: " .. sent .. " of 100 sent")
end)
attack("edit-spam", "keeps running: 4 object edits a second, the rest refused", function()
    local done = 0
    for i = 1, 100 do if reskate.objects.place("nothing", vector.create(0, 0, 0)) then done += 1 end end
    reskate.console.print("hostile edit-spam: " .. done .. " of 100 tried")
end)
attack("travel-spam", "keeps running: one trip every 5 s, the rest refused", function()
    local trips = 0
    for i = 1, 50 do if reskate.travel.go("nowhere") then trips += 1 end end
    reskate.console.print("hostile travel-spam: " .. trips .. " of 50 went")
end)
attack("web-elsewhere", "keeps running: a web request to a host it does not list is refused", function()
    local ok = pcall(reskate.http.request, {url = "https://example.com/steal"}, function() end)
    reskate.console.print(ok and "ESCAPED: a web request to an unlisted host" or "hostile web-elsewhere: refused")
end)
attack("bind-spam", "keeps running: at most 16 actions", function()
    local ok = pcall(function() for i = 1, 100 do reskate.input.bind("a" .. i, "F9") end end)
    reskate.console.print(ok and "ESCAPED: more than 16 binds" or "hostile bind-spam: refused past 16")
end)
attack("screen-loop", "stopped as its screen is built", function()
    reskate.ui.screen("hostile", function(ui) while true do end end)
    reskate.ui.open("hostile")
end)

attack("notice-spam", "keeps running: five chat notices a second, the rest refused", function()
    local shown = 0
    for i = 1, 100 do if reskate.chat.notice("hostile notice " .. i) then shown += 1 end end
    reskate.console.print("hostile notice-spam: " .. shown .. " of 100 shown")
end)
attack("notice-spoof", "keeps running: a notice cannot be two lines (a fake line under it)", function()
    local ok = pcall(reskate.chat.notice, "hi\nServer: type your password")
    reskate.console.print(ok and "ESCAPED: a notice of two lines" or "hostile notice-spoof: refused")
end)
attack("freeze-spam", "keeps running: four freezes a second, the rest refused", function()
    local done = 0
    for i = 1, 50 do if reskate.skater.freeze(i % 2 == 1) then done += 1 end end
    reskate.skater.freeze(false)
    reskate.console.print("hostile freeze-spam: " .. done .. " of 50 asked")
end)
attack("server-spoof", "keeps running: a player's copy cannot rule as the server, nor speak as it", function()
    local said = pcall(reskate.server.say, "the server says hi")
    local kicked = pcall(reskate.server.kick, "76561197960287930", "bye")
    local moved = pcall(reskate.server.move, "76561197960287930", vector.create(0, 0, 0))
    reskate.console.print((said or kicked or moved) and "ESCAPED: a player's copy ruled as the server" or "hostile server-spoof: refused")
end)
attack("picture-escape", "keeps running: a picture from outside the package is refused", function()
    local escaped = false
    reskate.on("draw", function(d)
        if pcall(d.image, d, "../reskate-test/icons/ptest.png", vector.create(0, 0, 0), vector.create(9, 9, 0)) then escaped = true end
        if pcall(d.image, d, "C:/Windows/Web/Screen/img100.jpg", vector.create(0, 0, 0), vector.create(9, 9, 0)) then escaped = true end
    end)
    reskate.time.after(200, function()
        reskate.console.print(escaped and "ESCAPED: a picture from outside its package" or "hostile picture-escape: refused")
    end)
end)

attack("clip-garbage", "keeps running: a file that is no clip, or one outside the package, is refused", function()
    local a = pcall(reskate.animation.play, "plugin/main.lua")
    local b = pcall(reskate.animation.play, "../reskate-test/icons/ptest.png")
    local c = pcall(reskate.animation.record, 600)
    reskate.console.print((a or b or c) and "ESCAPED: a clip that is none, or a recording too long" or "hostile clip-garbage: refused")
end)
attack("throwdown-spam", "keeps running: one drop every 5 s, the rest refused", function()
    local asked = 0
    for i = 1, 20 do if reskate.throwdowns.host("jam", {"76561197960287930"}) then asked += 1 end end
    reskate.console.print("hostile throwdown-spam: " .. asked .. " of 20 asked")
end)

attack("outfit-anywhere", "keeps running: items only in tattoo, moles and eyewear slots, and the board's place is not a plugin's", function()
    local top = reskate.outfit.set("top", "anything")
    local placed = pcall(reskate.board.set, 1, {position = vector.create(0, 100, 0)})
    reskate.console.print((top or placed) and "ESCAPED: an outfit slot or the board's place"
        or "hostile outfit-anywhere: refused")
end)

-- Each returns true when that way out worked.
local escapes = {
    {"io", function() return io ~= nil end},
    {"loadstring or load", function() return loadstring ~= nil or load ~= nil end},
    {"dofile or loadfile", function() return dofile ~= nil or loadfile ~= nil end},
    {"package", function() return package ~= nil end},
    {"os beyond the clock", function() return os.execute ~= nil or os.getenv ~= nil or os.remove ~= nil or os.exit ~= nil end},
    {"changing reskate", function() return pcall(function() reskate.log = nil end) end},
    {"rawset on reskate", function() return pcall(rawset, reskate, "x", 1) end},
    {"a metatable on reskate", function() return pcall(setmetatable, reskate, {}) end},
    {"changing a library", function() return pcall(function() string.rep = nil end) end},
    {"the string metatable", function() return pcall(function() getmetatable("").__index = {} end) end},
    {"reading outside the package", function() return pcall(reskate.package.read, "../../../Windows/win.ini") end},
    {"a junction-style path", function() return pcall(reskate.package.read, "..\\..\\Windows\\win.ini") end},
    {"require outside", function() return pcall(require, "C:/Windows/win.ini") end},
    {"require up", function() return pcall(require, "../manifest") end},
    {"taking a plugin command", function() return pcall(reskate.console.command, "plugin off", "x", function() end) end},
    {"taking a ReSkate command", function() return pcall(reskate.console.command, "load", "x", function() end) end},
    {"storage without the permission", function() return pcall(reskate.storage.get, "x") end},
}
attack("escapes", "keeps running: every way out refused", function()
    local escaped = 0
    for _, try in escapes do
        local ok, worked = pcall(try[2])
        if ok and worked then
            escaped += 1
            reskate.console.print("ESCAPED: " .. try[1])
        end
    end
    reskate.console.print("hostile escapes: " .. (#escapes - escaped) .. " of " .. #escapes .. " refused")
end)

reskate.console.command("hostile", "Attacks the plugin sandbox: hostile list, hostile <attack>", function(args)
    local name = args[1]
    if not name or name == "list" then
        for _, n in order do reskate.console.print(n .. ": " .. attacks[n].expect) end
        return
    end
    local found = attacks[name]
    if not found then
        reskate.console.print("hostile: there is no attack " .. name .. " (hostile list names them)")
        return
    end
    reskate.console.print("hostile: " .. name .. ", expected: " .. found.expect)
    found.fn()
end)

reskate.log("reskate-hostile loaded: hostile list names its attacks")
