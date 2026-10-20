-- SmokeyDawg58's ReSkate Throwdowns as a plugin mod, on ReSkate's throwdown kit. His game layer is
-- this plugin: td/ is his game_modes.cpp in Lua, td/oneup/ his 1-UP runtime, td/world.lua his
-- race_world.cpp (gates, cones, the beacon), td/h/ his helper headers, td/routes.lua his route
-- library, all line for line. His native UI's mode branches are td/ui*.lua: they turn his game layer
-- into the kit's documents (the setup page, the waiting card, the HUD, the match panel, his flags and
-- what a match asks of the game), which ReSkate's general native UI draws with his widgets, and turn
-- what the player does there (the `throwdown_ui` events) into his commands.
local modes = require("modes")
-- His game layer is about 470 KB of Lua: compiling it all in one call would pass a call's 50 ms, so
-- it loads one part a tick (the modes are on the page at once; a game starts only after).
local parts = {"td/skatepedia", "td/rules", "td/h/race_route", "td/h/race_editor", "td/h/race_arrow_placement", "td/h/race_momentum", "td/h/race_sound",
               "td/h/mode_announcements", "td/h/mode_lobby", "td/h/mode_participation", "td/h/placement_camera", "td/h/race_navigation",
               "td/h/race_group_reconciliation", "td/h/race_asset_contract", "td/routes", "td/referee", "td/wire", "td/core", "td/skater", "td/lobby",
               "td/placing", "td/play", "td/hud", "td/command", "td/tick", "td/world", "td/ui", "td/ui_hud", "td/ui_oneup", "td/ui_events",
               "td/oneup/match", "td/oneup/spawn", "td/oneup/wire", "td/oneup/native", "td/oneup/runtime"}
local loaded = 0
local M, oneup -- his game modes (td/core) and his 1-UP runtime, once loaded
local function load_next()
    loaded += 1
    local part = parts[loaded]
    local result = require(part)
    if part == "td/core" then M = result end
    if loaded == #parts then
        oneup = result
        M.one_up = oneup
        reskate.log("SmokeyDawg58's game modes are ready")
    end
end

-- His modes on the Throwdowns page (his challenge_registry): R.E.S.K.A.T.E. in S.K.A.T.E.'s place, then
-- 1-UP and his game modes, each with its donor card, colour, order and flag prefab.
for _, mode in ipairs(modes) do
    local ok, why = reskate.throwdowns.mode({id = mode.id, name = mode.name, description = mode.description, art = mode.art, color = mode.color,
                                             card = mode.card, replaces = mode.replaces, order = mode.order, flag = mode.flag, players = mode.players,
                                             cursor_height = mode.cursor_height})
    if not ok then reskate.log("could not add " .. mode.name .. ": " .. tostring(why), "warn") end
end

-- ---- the session ------------------------------------------------------------------------------------
-- His session tick's input (game_modes.h SessionInput).
local function session_input()
    local active = reskate.session.active()
    local me = active and reskate.session.me() or nil
    local peers = {}
    if active then
        for _, player in ipairs(reskate.session.players()) do
            if not player.me then table.insert(peers, {id = tostring(player.id), name = player.name}) end
        end
    end
    local world = reskate.session.world()
    return {["local"] = me and tostring(me.id) or "0", local_name = me and me.name or "", peers = peers,
            in_world = reskate.level.current() ~= nil, world = world.world, barred = world.barred, map = world.map}
end

-- What goes out: his packets, in order, within a plugin's 16 KB a second.
local outgoing, second, spent = {}, 0, 0
local function flush(now)
    if now - second >= 1000 then
        second = now
        spent = 0
    end
    while #outgoing > 0 and spent + #outgoing[1] <= 15000 do
        local packet = table.remove(outgoing, 1)
        spent += #packet
        local ok, why = pcall(reskate.net.send, "all", packet)
        if not ok then reskate.log("Game modes: a message did not go: " .. tostring(why), "warn") end
    end
    while #outgoing > 256 do table.remove(outgoing, 1) end
end

-- His UI's documents for the kit, every tick (the SDK compares them with the last).
local refused = nil
local function publish(now)
    local s = M.state()
    local ok, done, why = pcall(function() return reskate.throwdowns.ui(M.build_ui(s, now)) end)
    local refusal = not ok and tostring(done) or (done == false and tostring(why) or nil)
    if refusal ~= refused then
        refused = refusal
        if refusal then reskate.log("Game modes: the documents were not taken: " .. refusal, "warn") end
    end
    M.route_dialog_tick(s)
end

reskate.on("tick", function()
    if not oneup then return load_next() end
    local now = M.now_ms()
    for _, packet in ipairs(M.tick(session_input())) do table.insert(outgoing, packet) end
    oneup.tick(now)
    M.ui_tick(M.state(), now)
    flush(now)
    for _, text in ipairs(M.take_notices()) do reskate.chat.notice(text) end
    publish(now)
end)

reskate.on("message", function(from, payload)
    if not oneup then return end
    local sender = tostring(from.id)
    if M.receive(sender, payload) then return end
    oneup.receive(sender, payload)
end)

-- What the player does in the native Throwdowns UI (the kit's events), and the trick list's writes.
reskate.on("throwdown_ui", function(e)
    if not oneup then
        -- Still loading: a card opened now is refused, as his UI refused a busy setup.
        if e.action == "open" then reskate.throwdowns.flag.leave() end
        return
    end
    local ok, why = pcall(M.on_throwdown_ui, e)
    if not ok then reskate.log("Game modes: " .. tostring(e.action) .. " failed: " .. tostring(why), "error") end
end)
reskate.on("trick_notes", function(e) if M then M.queue_trick_notes(e.notes or {}) end end)
-- His builder's gate numbers and rotation gizmo, over the world.
reskate.on("draw", function(d) if oneup then M.draw(d) end end)
-- His ReSkate-menu 1-UP card (one_up_overlay.cpp), as this plugin's page.
reskate.menu.page("1-UP", function(ui)
    if oneup then M.one_up_card(ui) else ui:note("The game modes are still loading.") end
end)

-- His `mode` console verbs, under "tdm" (ReSkate's own "mode" is the game's).
reskate.console.command("tdm", "SmokeyDawg58's game modes: tdm <verb> [arguments] (tdm help)", function(args)
    if not oneup then return reskate.console.print("tdm: the game modes are still loading") end
    local verb = args[1] or "help"
    local rest = {}
    for i = 2, #args do rest[i - 1] = args[i] end
    reskate.console.print(M.command(verb, rest))
end)
