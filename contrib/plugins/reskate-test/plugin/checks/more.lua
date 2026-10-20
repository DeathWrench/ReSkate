local h = require("harness")
local t = h.module("more")

-- The set after phase 3: chat notices, the camera, freezing, pictures, the game's own songs, the
-- trick's name and manuals, and the server copy. What ptest all checks reads the game and changes
-- nothing; the rest is by hand: ptest notice, camera, follow, freeze, picture, song, skip, manual,
-- server.

t.check("this copy is the player's", function() assert(reskate.side == "client", tostring(reskate.side)) end)
t.check("a chat notice is one line", function() h.refused(reskate.chat.notice, "two\nlines") end)
t.check("the camera reads, and a view needs a direction and a sane field of view", function()
    local view = reskate.camera.get()
    assert(view == nil or (typeof(view.position) == "vector" and typeof(view.forward) == "vector" and view.fov > 1), "camera.get")
    h.refused(reskate.camera.look, vector.create(1, 1, 1), vector.create(1, 1, 1))
    h.refused(reskate.camera.look, vector.create(0, 0, 0), vector.create(0, 0, 1), 400)
    local held, why = reskate.camera.held()
    assert(not held and type(why) == "string", "it holds no camera before it asks")
end)
t.check("the game's own song is a track or nothing", function()
    local song = reskate.music.game()
    assert(song == nil or type(song.title) == "string", "music.game")
end)
t.check("the score names its trick", function()
    local score = reskate.score.current()
    if not score then return h.skip("no score HUD now") end
    assert(type(score.trick) == "string" and type(score.detail) == "string" and type(score.manual) == "boolean")
end)
t.check("only the server copy rules", function()
    local err = h.refused(reskate.server.kick, "76561197960287930")
    assert(err:find("server copy", 1, true), err)
end)
t.check("clips: the trick's name, nothing playing, and a clip from the package only", function()
    local trick = reskate.animation.trick()
    assert(trick == nil or type(trick) == "string")
    assert(reskate.animation.playing() == false)
    h.refused(reskate.animation.play, "clips/missing.fas")
    h.refused(reskate.animation.play, "../reskate-hostile/plugin/main.lua")
end)
t.check("a drop is for players in a linked mode", function()
    h.refused(reskate.throwdowns.host, "bowling", {"76561197960287930"})
    h.refused(reskate.throwdowns.host, "jam", {})
end)
t.check("pictures come from the package only", function()
    local ok = pcall(reskate.package.read, "icons/ptest.png")
    assert(ok, "the test picture is in the package")
end)

-- ---- by hand ---------------------------------------------------------------------------------
local function said(name, ok, why)
    reskate.console.print("ptest " .. name .. ": " .. (ok and "done" or ("refused: " .. tostring(why))))
end
reskate.console.command("ptest notice", "A chat line only you see", function()
    said("notice", reskate.chat.notice("ptest: only you see this line", 0x5ecdfaff))
end)
-- The camera 8 m behind and 4 m above the skater, looking at it, for 6 s.
reskate.console.command("ptest camera", "Takes the camera for 6 s", function()
    local s = reskate.skater.get()
    if not s then return reskate.console.print("ptest camera: no skater") end
    local back = vector.create(-math.sin(s.heading), 0, -math.cos(s.heading)) * 8
    local ok, why = reskate.camera.look(s.position + back + vector.create(0, 4, 0), s.position + vector.create(0, 1, 0), 60)
    said("camera", ok, why)
    reskate.time.after(1000, function()
        local held, status = reskate.camera.held()
        reskate.console.print("ptest camera: " .. (held and "shown" or ("not shown: " .. tostring(status))))
    end)
    reskate.time.after(6000, function()
        reskate.camera.release()
        reskate.console.print("ptest camera: released")
    end)
end)
reskate.console.command("ptest follow", "Spectate's camera on another player for 8 s", function()
    for _, p in reskate.session.players() do
        if not p.me then
            said("follow " .. p.name, reskate.camera.follow(p))
            reskate.time.after(8000, function()
                reskate.camera.follow(nil)
                reskate.console.print("ptest follow: stopped")
            end)
            return
        end
    end
    reskate.console.print("ptest follow: nobody else is in the session")
end)
local frozen = false
reskate.console.command("ptest freeze", "Holds the skater still, or lets it go", function()
    frozen = not frozen
    said("freeze " .. (frozen and "on" or "off"), reskate.skater.freeze(frozen))
end)
local picture_until = 0
reskate.on("draw", function(d)
    if reskate.time.now() > picture_until then return end
    d:image("icons/ptest.png", vector.create(60, 220, 0), vector.create(188, 348, 0), {rounding = 12})
    local s = reskate.skater.get()
    if s then d:world_image("icons/ptest.png", s.position + vector.create(0, 2.6, 0), 0.8) end
end)
reskate.console.command("ptest picture", "Draws the test picture for 8 s, on screen and over the skater", function()
    picture_until = reskate.time.now() + 8000
    reskate.console.print("ptest picture: drawn for 8 s")
end)
reskate.console.command("ptest song", "Says what the game's own music plays", function()
    local song = reskate.music.game()
    reskate.console.print("ptest song: " .. (song and (song.title .. " by " .. song.artist) or "none (a Spotify station, or no song yet)"))
end)
reskate.console.command("ptest skip", "Skips the game's own song", function() said("skip", reskate.music.game_next()) end)
local manual_until, last_named = 0, nil
reskate.on("tick", function()
    if reskate.time.now() > manual_until then return end
    local score = reskate.score.current()
    if not score then return end
    local named = score.trick .. " / " .. score.detail .. (score.manual and " (a manual)" or "")
    if named ~= last_named then
        last_named = named
        reskate.console.print("ptest manual: " .. named)
    end
end)
reskate.on("trick_landed", function(e)
    if reskate.time.now() <= manual_until then reskate.console.print("ptest manual: landed " .. tostring(e.name)) end
end)
reskate.console.command("ptest manual", "For 20 s, says what the score HUD names (do a manual)", function()
    manual_until, last_named = reskate.time.now() + 20000, nil
    reskate.console.print("ptest manual: do a manual, and some tricks")
end)
reskate.on("message", function(from, text)
    if from.server and text:sub(1, 6) == "pong: " then reskate.console.print("ptest server: the server copy said " .. text:sub(7)) end
end)
reskate.console.command("ptest server", "Asks the session's server copy for a pong", function()
    said("server", reskate.net.send("server", "ping"))
end)

-- Clips: ptest record (3 s of you), ptest anim (plays it on you), ptest replace (your kickflips play it).
local recording = nil
reskate.console.command("ptest record", "Records 3 s of your skater", function()
    local ok, why = reskate.animation.record(3)
    said("record", ok, why)
    if not ok then return end
    reskate.time.after(3500, function()
        recording = reskate.animation.recorded()
        reskate.console.print("ptest record: " .. (recording and ("recorded " .. recording) or "nothing came back"))
    end)
end)
reskate.console.command("ptest anim", "Plays the recording on your skater (ptest anim loop: over and over; ptest anim stop)", function(args)
    if args[1] == "stop" then
        reskate.animation.stop()
        return reskate.console.print("ptest anim: stopped")
    end
    if not recording then return reskate.console.print("ptest anim: run ptest record first") end
    said("anim", reskate.animation.play(recording, {blend = 0.2, loop = args[1] == "loop"}))
end)
local replaced = false
reskate.console.command("ptest replace", "Your kickflips play the recording, or the game's own again", function()
    if not recording and not replaced then return reskate.console.print("ptest replace: run ptest record first (do a kickflip in it)") end
    replaced = not replaced
    said("replace kickflip " .. (replaced and "on" or "off"), reskate.animation.replace("kickflip", replaced and recording or nil))
end)
reskate.console.command("ptest trickname", "Says the game's name for your trick for 10 s", function()
    local last, until_ms = nil, reskate.time.now() + 10000
    local id
    id = reskate.time.every(50, function()
        local name = reskate.animation.trick()
        if name and name ~= last then
            last = name
            reskate.console.print("ptest trickname: the game says " .. name)
        end
        if reskate.time.now() > until_ms then reskate.time.cancel(id) end
    end)
end)
-- Throwdowns: ptest throwdown hosts a Jam Session for everyone else in the session.
reskate.console.command("ptest throwdown", "Hosts a Jam for the other players (ptest throwdown cancel)", function(args)
    if args[1] == "cancel" then
        reskate.throwdowns.cancel()
        return reskate.console.print("ptest throwdown: cancelled")
    end
    local others = {}
    for _, p in reskate.session.players() do
        if not p.me then table.insert(others, p) end
    end
    if #others == 0 then return reskate.console.print("ptest throwdown: nobody else is in the session") end
    said("throwdown for " .. #others .. " player(s)", reskate.throwdowns.host(args[1] or "jam", others))
    for _, wait in {2000, 6000, 15000} do
        reskate.time.after(wait, function() reskate.console.print("ptest throwdown: " .. tostring(reskate.throwdowns.hosting())) end)
    end
end)
