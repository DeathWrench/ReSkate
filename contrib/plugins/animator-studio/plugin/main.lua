-- Animator Studio, by 22sh, Fourth Studio and Norms (pull request 297), as a plugin. Record a trick,
-- change the body and the board on a timeline, save it, and from then on doing that trick in game
-- plays your version (reskate.animation.replace); every other trick stays the game's own.
--   - A recording is the skater as the game draws it (reskate.animation.record), cut down to the
--     trick: from a little before its takeoff to a little after its landing (trim).
--   - Keys turn a joint in its own frame and move it in its parent's (the hips, the board), on top of
--     the recording; the studio bakes them into a clip (reskate.animation.edit) and shows it on the
--     skater, held at the timeline's time (play paused, seek).
--   - The studio is a panel down the right of the screen (reskate.ui.screen docked) with an orbit
--     camera round the skater, held still; the joints are dots on the skater, picked with the mouse.
--   - Saved animations are a clip file and the keys beside it in the plugin's data folder
--     (anims/<name>.fas and .json); those set to play in game are put back at every start.
-- The PR's studio room (the game menu's character room) and its loading screen are not here: the
-- studio opens where the skater is.
local title = "Animator Studio"
local pops = {"any", "low", "mid", "high"}
local frame = 1 / 30
local joints = reskate.animation.joints() -- {joint, label, moves}, the board first

-- ---- the animation being edited --------------------------------------------------------------------
local anim = {
    name = "", trick = "", pop = 1, speed = 1, in_game = false,
    source = nil, -- the clip the keys go on
    tracks = {},  -- by tostring(joint): {joint = 7, keys = {{t, a = {x, y, z} degrees, o = {x, y, z} metres, e}}}
}
local info = nil -- reskate.animation.info(anim.source)
local studio = {open = false, tab = 1, joint = 2, time = 0, playing = false, auto_key = true, status = ""}
local undo, redo = {}, {}
local last_change = 0
local preview_due, last_preview = false, -1e9
local orbit = {yaw = 0.6, pitch = 0.18, distance = 3.2, anchor = nil}
local cursor_was = nil
local screen_points = {} -- joint index into `joints` -> screen point, from the last draw
local recording = nil   -- {trick} while a recording is going on

local function say(text)
    studio.status = text
    reskate.log(text)
end
local function safe(name)
    local s = string.gsub(name, "[^%w%-_ ]", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return string.sub(s, 1, 40)
end
local function pop_name() return if anim.pop == 1 then nil else pops[anim.pop] end

-- ---- keys --------------------------------------------------------------------------------------------
local function joint_id() return joints[studio.joint].joint end
local function track_of(joint, make)
    local key = tostring(joint)
    if not anim.tracks[key] and make then anim.tracks[key] = {joint = joint, keys = {}} end
    return anim.tracks[key]
end
local function lerp3(a, b, u) return {a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u} end
-- The joint's edit at `t` as the sliders show it (angles blended straight; the baked clip blends the
-- turns themselves).
local function value_at(joint, t)
    local track = track_of(joint, false)
    if not track or #track.keys == 0 then return {0, 0, 0}, {0, 0, 0} end
    local keys = track.keys
    if t <= keys[1].t then return keys[1].a, keys[1].o end
    if t >= keys[#keys].t then return keys[#keys].a, keys[#keys].o end
    for i = 1, #keys - 1 do
        local a, b = keys[i], keys[i + 1]
        if t >= a.t and t <= b.t then
            if a.e == "step" then return a.a, a.o end
            local u = if b.t > a.t then (t - a.t) / (b.t - a.t) else 0
            if a.e ~= "linear" then u = u * u * (3 - 2 * u) end
            return lerp3(a.a, b.a, u), lerp3(a.o, b.o, u)
        end
    end
    return {0, 0, 0}, {0, 0, 0}
end
local function key_at(joint, t)
    local track = track_of(joint, false)
    if not track then return nil end
    for i, k in track.keys do
        if math.abs(k.t - t) < frame * 0.5 then return k, i end
    end
    return nil
end
-- Before a change: what it was, for undo (one entry a gesture: changes within 0.6 s are one).
local function changing()
    local now = reskate.time.now()
    if now - last_change > 600 then
        table.insert(undo, reskate.json.encode(anim.tracks))
        if #undo > 50 then table.remove(undo, 1) end
        redo = {}
    end
    last_change = now
    preview_due = true
end
local function set_key(joint, t, angles, offset)
    changing()
    local existing = key_at(joint, t)
    if existing then
        existing.a, existing.o = angles, offset
        return
    end
    local track = track_of(joint, true)
    local key = {t = t, a = angles, o = offset, e = "smooth"}
    local at = #track.keys + 1
    for i, k in track.keys do
        if k.t > t then at = i break end
    end
    table.insert(track.keys, at, key)
end
local function step_history(from, to)
    if #from == 0 then return end
    table.insert(to, reskate.json.encode(anim.tracks))
    anim.tracks = reskate.json.decode(table.remove(from))
    preview_due = true
end

-- ---- the clip on the skater --------------------------------------------------------------------------
local function tracks_for_edit()
    local list = {}
    for _, track in anim.tracks do
        if #track.keys > 0 then
            local keys = {}
            for _, k in track.keys do
                table.insert(keys, {time = k.t, angles = vector.create(k.a[1], k.a[2], k.a[3]),
                    offset = vector.create(k.o[1], k.o[2], k.o[3]), ease = k.e})
            end
            table.insert(list, {joint = track.joint, keys = keys})
        end
    end
    return list
end
local function bake(name)
    if not anim.source then return nil end
    local ok, clip = pcall(reskate.animation.edit, anim.source, tracks_for_edit(), {name = name})
    if not ok then
        say("The keys could not be put on the clip: " .. tostring(clip))
        return nil
    end
    return clip
end
local function show_preview()
    local clip = bake("studio")
    if not clip then return end
    local ok, why = reskate.animation.play(clip, {paused = not studio.playing, at = studio.time, loop = true, blend = 0, speed = anim.speed})
    if ok then
        preview_due = false
        last_preview = reskate.time.now()
    elseif why ~= "asked more than 4 times in a second" then
        say("The studio cannot show it: " .. why)
        preview_due = false
    end
end
local function use_source(clip, trick)
    if anim.source and anim.source ~= clip then reskate.animation.forget(anim.source) end
    anim.source = clip
    info = reskate.animation.info(clip)
    if trick then anim.trick = trick end
    studio.time = math.clamp(studio.time, 0, info.duration)
    preview_due = true
end

-- ---- playing in game ---------------------------------------------------------------------------------
-- The saved animation `file` (its profile `p`) on the game's trick, or taken off it.
local function put_in_game(file, p, source)
    if not p.trick or p.trick == "" then return false, "it has no trick" end
    local pop = if p.pop and p.pop ~= "any" then p.pop else nil
    if not p.in_game then return reskate.animation.replace(p.trick, nil, {pop = pop}) end
    local saved_tracks = anim.tracks
    anim.tracks = p.tracks or {}
    local ok, clip = pcall(reskate.animation.edit, source, tracks_for_edit(), {name = "game " .. file})
    anim.tracks = saved_tracks
    if not ok then return false, tostring(clip) end
    return reskate.animation.replace(p.trick, clip, {pop = pop, speed = p.speed or 1})
end
local function profile()
    return {format = "animator-studio-plugin", version = 1, name = anim.name, trick = anim.trick, pop = pops[anim.pop],
            speed = anim.speed, in_game = anim.in_game, tracks = anim.tracks}
end

-- ---- the library -------------------------------------------------------------------------------------
local function library()
    local names = {}
    local list = reskate.files.list("anims") or {}
    for _, entry in list do
        local base = string.match(entry, "^(.+)%.json$")
        if base then table.insert(names, base) end
    end
    table.sort(names)
    return names
end
local function save_as(name)
    local file = safe(name)
    if file == "" then return say("A name is letters, digits, spaces, - and _.") end
    if not anim.source then return say("Record a trick first.") end
    anim.name = name
    local ok, why = reskate.animation.save(anim.source, "anims/" .. file .. ".fas")
    if not ok then return say("Not saved: " .. why) end
    ok, why = reskate.files.write("anims/" .. file .. ".json", reskate.json.encode(profile()))
    if not ok then return say("Not saved: " .. why) end
    local data = "data:anims/" .. file .. ".fas"
    reskate.animation.forget(data)
    local placed, refused = put_in_game(file, profile(), anim.source)
    say("Saved " .. file .. (if anim.in_game and not placed then " (not in game: " .. tostring(refused) .. ")" else ""))
end
local function load_saved(file)
    local text = reskate.files.read("anims/" .. file .. ".json")
    if not text then return say("No animation is called " .. file) end
    local ok, p = pcall(reskate.json.decode, text)
    if not ok or type(p) ~= "table" then return say(file .. " is not an animation") end
    local data = "data:anims/" .. file .. ".fas"
    reskate.animation.forget(data)
    local read, why = pcall(reskate.animation.info, data)
    if not read then return say(file .. "'s clip cannot be read: " .. tostring(why)) end
    anim.name, anim.trick, anim.speed, anim.in_game = p.name or file, p.trick or "", p.speed or 1, p.in_game == true
    anim.pop = table.find(pops, p.pop or "any") or 1
    anim.tracks = p.tracks or {}
    undo, redo = {}, {}
    use_source(data)
    say("Loaded " .. file)
end
local function remove_saved(file)
    local text = reskate.files.read("anims/" .. file .. ".json")
    if text then
        local ok, p = pcall(reskate.json.decode, text)
        if ok and type(p) == "table" then
            p.in_game = false
            put_in_game(file, p, nil)
        end
    end
    reskate.files.remove("anims/" .. file .. ".json")
    reskate.files.remove("anims/" .. file .. ".fas")
    reskate.animation.forget("data:anims/" .. file .. ".fas")
    say("Removed " .. file)
end
-- A low, a mid and a high copy of it, each playing in game for its pop.
local function copy_to_pops()
    if anim.trick == "" then return say("Set the trick first.") end
    local name, pop, in_game = anim.name, anim.pop, anim.in_game
    local base = safe(if name ~= "" then name else anim.trick)
    for i = 2, 4 do
        anim.pop, anim.in_game = i, true
        save_as(base .. " " .. pops[i])
    end
    anim.name, anim.pop, anim.in_game = name, pop, in_game
    say("Copied to low, mid and high pop")
end

-- ---- opening, closing, recording ---------------------------------------------------------------------
local function open_studio()
    local s = reskate.skater.get()
    if not s then return say("The studio needs a skater.") end
    orbit.anchor = s.position + vector.create(0, 0.9, 0)
    orbit.yaw = s.heading + math.pi * 0.8
    reskate.skater.freeze(true)
    reskate.hud.hide(true)
    reskate.ui.open(title)
    studio.open = true
    preview_due = true
end
local function close_studio()
    if not studio.open then return end
    studio.open = false
    reskate.ui.close()
    reskate.animation.stop()
    reskate.camera.release()
    reskate.hud.hide(false)
    reskate.skater.freeze(false)
end
local function record_trick()
    close_studio()
    local ok, why = reskate.animation.record(10)
    if not ok then return say("Cannot record: " .. why) end
    recording = {trick = nil}
    reskate.ui.toast("Recording: skate and land a trick in the next 10 seconds", "info")
end
local function recording_done(clip)
    local trick = recording.trick
    recording = nil
    local i = reskate.animation.info(clip)
    if not i.takeoff or not i.landing then
        reskate.animation.forget(clip)
        say("No trick was landed while it recorded: record again.")
        return open_studio()
    end
    local cut = reskate.animation.trim(clip, math.max(0, i.takeoff - 0.6), math.min(i.duration, i.landing + 0.8))
    reskate.animation.forget(clip)
    anim.tracks, undo, redo = {}, {}, {}
    anim.name = trick or ""
    studio.time = 0
    use_source(cut, trick)
    say("Recorded " .. (trick or "a trick"))
    open_studio()
end

-- ---- the panel ---------------------------------------------------------------------------------------
local function joint_labels()
    local labels = {}
    for _, j in joints do table.insert(labels, j.label) end
    return labels
end
local labels = joint_labels()

local function build_timeline(ui)
    if not info then return end
    ui:info("Time", string.format("%.2f of %.2f s", studio.time, info.duration))
    local t = ui:slider("time", "Timeline", studio.time, 0, info.duration, "%.2f s")
    if math.abs(t - studio.time) > 1e-4 then
        studio.time = t
        reskate.animation.seek(t)
    end
    if ui:button("play", if studio.playing then "Pause" else "Play", true) then
        studio.playing = not studio.playing
        reskate.animation.pause(not studio.playing)
    end
    if ui:button("back", "One frame back") then
        studio.time = math.max(0, studio.time - frame)
        reskate.animation.seek(studio.time)
    end
    if ui:button("ahead", "One frame on") then
        studio.time = math.min(info.duration, studio.time + frame)
        reskate.animation.seek(studio.time)
    end
end

local function build_joints(ui)
    if not anim.source then
        ui:note("Record a trick first (TRICKS).")
        return
    end
    studio.joint = ui:dropdown("joint", "Joint", labels, studio.joint, "Or click a dot on the skater.")
    build_timeline(ui)
    local j = joints[studio.joint]
    local angles, offset = value_at(j.joint, studio.time)
    ui:card(string.upper(j.label), if key_at(j.joint, studio.time) then "A key here" else "No key here")
    local a = {ui:slider("ax", "Turn X", angles[1], -180, 180, "%.0f deg"), ui:slider("ay", "Turn Y", angles[2], -180, 180, "%.0f deg"),
               ui:slider("az", "Turn Z", angles[3], -180, 180, "%.0f deg")}
    local o = offset
    if j.moves then
        local reach = if j.joint == "board" then 1 else 0.5
        o = {ui:slider("ox", "Move X", offset[1], -reach, reach, "%.2f m"), ui:slider("oy", "Move Y", offset[2], -reach, reach, "%.2f m"),
             ui:slider("oz", "Move Z", offset[3], -reach, reach, "%.2f m")}
    end
    local moved = false
    for i = 1, 3 do
        if math.abs(a[i] - angles[i]) > 1e-3 or math.abs(o[i] - offset[i]) > 1e-5 then moved = true end
    end
    if moved and studio.auto_key then set_key(j.joint, studio.time, a, o) end
    studio.auto_key = ui:toggle("auto", "Key as you change it", studio.auto_key)
    if ui:button("key", "Key it here") then set_key(j.joint, studio.time, a, o) end
    local key, index = key_at(j.joint, studio.time)
    if key then
        local eases = {"smooth", "linear", "step"}
        local e = ui:dropdown("ease", "Into the next key", eases, table.find(eases, key.e) or 1)
        if eases[e] ~= key.e then
            changing()
            key.e = eases[e]
        end
        if ui:button("unkey", "Take this key off") then
            changing()
            table.remove(track_of(j.joint, false).keys, index)
        end
    end
    local track = track_of(j.joint, false)
    if track and #track.keys > 0 then
        local times = {}
        for _, k in track.keys do table.insert(times, string.format("%.2f", k.t)) end
        ui:note("Keys at " .. table.concat(times, ", ") .. " s")
        if ui:button("previous", "Previous key") then
            for i = #track.keys, 1, -1 do
                if track.keys[i].t < studio.time - 1e-3 then studio.time = track.keys[i].t break end
            end
            reskate.animation.seek(studio.time)
        end
        if ui:button("next", "Next key") then
            for _, k in track.keys do
                if k.t > studio.time + 1e-3 then studio.time = k.t break end
            end
            reskate.animation.seek(studio.time)
        end
        if ui:button("reset", "Take all its keys off") then
            changing()
            anim.tracks[tostring(j.joint)] = nil
        end
    end
    if #undo > 0 and ui:button("undo", "Undo") then step_history(undo, redo) end
    if #redo > 0 and ui:button("redo", "Redo") then step_history(redo, undo) end
end

local function build_tricks(ui)
    ui:card("TRICKS", if anim.source then (if anim.trick ~= "" then anim.trick else "a trick") else "Nothing recorded yet")
    if ui:button("record", "Record a trick", true) then record_trick() end
    ui:note("The studio steps out: skate and land the trick within 10 seconds, and you are back with it.")
    if anim.source then
        ui:info("Trick", if anim.trick ~= "" then anim.trick else "unknown")
        ui:info("Length", string.format("%.2f s", info.duration))
        if info.takeoff then ui:info("Air", string.format("%.2f to %.2f s", info.takeoff, info.landing or info.duration)) end
    end
end

local function build_playback(ui)
    if not anim.source then
        ui:note("Record a trick first (TRICKS).")
        return
    end
    ui:card("PLAYBACK", "How it plays in game")
    anim.pop = ui:dropdown("pop", "Pop", {"Any pop", "Low pop", "Mid pop", "High pop"}, anim.pop)
    local speed = ui:slider("speed", "Speed", anim.speed, 0.1, 4, "x%.2f")
    if math.abs(speed - anim.speed) > 1e-4 then
        anim.speed = speed
        preview_due = true
    end
    anim.in_game = ui:toggle("in_game", "Play it in game", anim.in_game, "When saved, doing the trick plays this.")
    if ui:button("pops", "Copy to low, mid and high pop") then copy_to_pops() end
end

local function build_library(ui)
    ui:card("LIBRARY", if anim.name ~= "" then anim.name else "Not saved")
    if ui:button("save", "Save", true) then
        if anim.name ~= "" then save_as(anim.name)
        else
            reskate.ui.dialog("save", {title = "SAVE ANIMATION", field = {text = anim.trick, max = 40}, buttons = {{id = "save", label = "Save"}, "Cancel"}})
        end
    end
    if anim.source and ui:button("save_as", "Save as...") then
        reskate.ui.dialog("save", {title = "SAVE ANIMATION", field = {text = anim.name, max = 40}, buttons = {{id = "save", label = "Save"}, "Cancel"}})
    end
    for i, name in library() do
        if i > 24 then break end
        if ui:button("load" .. i, "Open " .. name) then load_saved(name) end
    end
    if anim.name ~= "" and ui:button("remove", "Remove " .. anim.name) then remove_saved(safe(anim.name)) end
end

reskate.ui.screen(title, function(ui)
    studio.tab = ui:tabs("tabs", {"TRICKS", "JOINTS", "PLAYBACK", "LIBRARY"}, studio.tab)
    if studio.tab == 1 then build_tricks(ui)
    elseif studio.tab == 2 then build_joints(ui)
    elseif studio.tab == 3 then build_playback(ui)
    else build_library(ui) end
    ui:separator()
    if studio.status ~= "" then ui:note(studio.status) end
    if ui:button("close", "Close the studio") then close_studio() end
end, {dock = "right", width = 0.3})

reskate.on("screen_closed", function(screen)
    if screen ~= title or not studio.open then return end
    studio.open = true -- Esc shut the screen: the rest goes too
    close_studio()
end)
reskate.on("throwdown_ui", function(e)
    if e.action ~= "dialog" or e.args[1] ~= "save" then return end
    reskate.ui.close_dialog("save")
    if e.args[2] == "save" then save_as(e.args[3]) end
end)

-- ---- every tick: the camera, the mouse, the preview, a recording -------------------------------------
reskate.on("tick", function()
    if recording then
        local trick = reskate.animation.trick()
        if trick and not recording.trick then recording.trick = trick end
        local clip = reskate.animation.recorded()
        if clip then recording_done(clip) end
        return
    end
    if not studio.open then return end
    -- The mouse beside the panel: right drag turns round the skater, the wheel comes closer, a left
    -- click picks the nearest dot.
    local c = reskate.input.cursor()
    if c and not c.over_screen then
        if c.right and cursor_was and cursor_was.right then
            orbit.yaw = orbit.yaw - (c.position.x - cursor_was.position.x) * 0.008
            orbit.pitch = math.clamp(orbit.pitch + (c.position.y - cursor_was.position.y) * 0.006, -1.2, 1.3)
        end
        if c.wheel ~= 0 then orbit.distance = math.clamp(orbit.distance - c.wheel * 0.25, 1, 8) end
        if c.left and not (cursor_was and cursor_was.left) then
            local best, best_distance = nil, 28
            for index, point in screen_points do
                local d = math.sqrt((point.x - c.position.x) ^ 2 + (point.y - c.position.y) ^ 2)
                if d < best_distance then best, best_distance = index, d end
            end
            if best then
                studio.joint = best
                studio.tab = 2
            end
        end
    end
    cursor_was = c
    if orbit.anchor then
        local forward = vector.create(math.sin(orbit.yaw) * math.cos(orbit.pitch), -math.sin(orbit.pitch), math.cos(orbit.yaw) * math.cos(orbit.pitch))
        reskate.camera.set(orbit.anchor - forward * orbit.distance, forward, vector.create(0, 1, 0), 55)
    end
    if studio.playing then studio.time = reskate.animation.time() or studio.time end
    if preview_due and reskate.time.now() - last_preview > 300 then show_preview() end
end)

-- The joints as dots on the skater, the one picked larger.
reskate.on("draw", function(d)
    if not studio.open then return end
    screen_points = {}
    for index, j in joints do
        if j.joint ~= "board" then
            local at = reskate.skater.joint(j.joint)
            if at then
                local on = d:world_to_screen(at.position)
                if on then screen_points[index] = on end
                local picked = index == studio.joint
                d:world_circle(at.position, if picked then 0.04 else 0.025, {colour = if picked then "#ffb000" else "#40c0ff", fill = true})
            end
        end
    end
end)

-- ---- at start: what plays in game --------------------------------------------------------------------
local function put_saved_in_game()
    local count = 0
    for _, file in library() do
        local text = reskate.files.read("anims/" .. file .. ".json")
        local ok, p = pcall(reskate.json.decode, text or "")
        if ok and type(p) == "table" and p.in_game then
            local data = "data:anims/" .. file .. ".fas"
            local placed = pcall(put_in_game, file, p, data)
            if placed then count += 1 end
        end
    end
    return count
end
local in_game = put_saved_in_game()
if in_game > 0 then reskate.log(string.format("%d saved animation(s) play in game", in_game)) end

reskate.input.bind("studio", "F8")
reskate.input.bind("studio pad", "Pad.L3+Pad.R3")
reskate.on("action", function(name)
    if name == "studio" or name == "studio pad" then
        if studio.open then close_studio() else open_studio() end
    end
end)
reskate.console.command("studio", "Animator Studio: open, close, record, save <name>, ingame on|off, list, status", function(args)
    local word = args[1] or "open"
    if word == "open" then open_studio()
    elseif word == "save" then
        local name = table.concat(args, " ", 2)
        save_as(if name ~= "" then name else anim.name)
        reskate.console.print("studio: " .. studio.status)
    elseif word == "ingame" then
        anim.in_game = args[2] == "on"
        reskate.console.print("studio: " .. (if anim.in_game then "plays in game once saved" else "stays in the studio"))
    elseif word == "close" then close_studio()
    elseif word == "record" then record_trick()
    elseif word == "list" then reskate.console.print("studio: " .. table.concat(library(), ", "))
    elseif word == "status" then
        reskate.console.print(string.format("studio: %s; %s; %d saved", if studio.open then "open" else "closed",
            if anim.source then (anim.trick ~= "" and anim.trick or "a trick") .. string.format(", %.2f s", info.duration) else "nothing recorded",
            #library()))
    else reskate.console.print("studio: say open, close, record, save <name>, ingame on|off, list or status") end
end)
reskate.menu.page(title, function(ui)
    ui:card("ANIMATOR STUDIO", "Change the game's trick animations")
    ui:note("F8 (or L3 + R3) opens the studio. Record a trick, key the joints on the timeline, save it, and doing that trick plays your version.")
    if ui:button("open", "Open the studio", true) then open_studio() end
    ui:info("Saved", tostring(#library()))
end)
reskate.on("unload", function() close_studio() end)
