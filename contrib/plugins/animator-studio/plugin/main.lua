-- Animator Studio, by 22sh, Fourth Studio and Norms (pull request 297), as a plugin. Record a trick,
-- change the body and the board on a timeline, save it, and from then on doing that trick in game
-- plays your version (reskate.animation.replace); every other trick stays the game's own.
--
-- The screen is the PR's (animation_studio_overlay.cpp), drawn here with the overlay's shapes: the
-- skater in the middle on the studio's own camera, skate.'s Trick List menu on the left with its
-- tabs, the white card under it, a timeline of the body's joints along the bottom, the prompts and
-- KEY / SAVE in the lower right, the unsaved-changes card, the recording strip and the loading screen.
-- It works from the keyboard and mouse or from a controller, the prompts following whichever was
-- used last. What the studio does (the PR's anim_studio.cpp):
--   - A recording is the skater as the game draws it (reskate.animation.record), cut to the trick:
--     from a little before its takeoff to a little after its landing (trim). It records again until a
--     trick is landed in it, or Esc.
--   - Keys turn a joint in its own frame and move it in its parent's (the hips, the board), on top of
--     the recording. They are baked into a clip (reskate.animation.edit) shown on the skater, held at
--     the playhead (play paused, seek); a change shows at once through reskate.skater.pose until the
--     next bake has it.
--   - Saved animations are the recording as a clip file and the keys beside it in the data folder
--     (anims/<name>.fas and .json). With Custom tricks in game on, each plays on its trick and pop.
--   - The game's own tricks, its clips read out of its data (reskate.animation.game_clips, "game:"
--     clips), are listed in TRICKS to start from.
--   - The studio opens in its room, the character room of the game menu's Skaters page
--     (reskate.room walks the game's menu there and shows the skater in it), or where the skater is
--     with the Studio room setting off or when the walk fails.
--   - The card's NAME, TRICK and numbers are typed into in place (reskate.input.text).
local title = "Animator Studio"
local fps = 30
local joints = reskate.animation.joints() -- {joint, label, moves}, the board first
local joint_row = {}
for i, j in joints do joint_row[tostring(j.joint)] = i end
local function label_of(joint)
    local i = joint_row[tostring(joint)]
    return if i then joints[i].label else "Joint " .. tostring(joint)
end
local function moves(joint)
    local i = joint_row[tostring(joint)]
    return i ~= nil and joints[i].moves
end
local function upper(s) return string.upper(s) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function same(a, b) return tostring(a) == tostring(b) end

-- ---- colours: skate.'s look --------------------------------------------------------------------------
local function rgba(r, g, b, a) return r * 16777216 + g * 65536 + b * 256 + (a or 255) end
local white, black = rgba(245, 245, 245), rgba(0, 0, 0)
local soft, faint = rgba(168, 170, 176), rgba(112, 114, 120)
local blue, blue_dim, blue_light = rgba(1, 131, 255), rgba(1, 131, 255, 110), rgba(90, 180, 255)
local danger = rgba(255, 92, 92)
-- The colour with its alpha scaled by `a` (0 to 1).
local function with_alpha(c, a) return c - (c % 256) + math.floor(clamp(a, 0, 1) * (c % 256)) end

-- ---- quaternions {x, y, z, w}, as anim_core's ---------------------------------------------------------
local function qmul(a, b)
    return {a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2], a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
            a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4], a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3]}
end
local function qconj(q) return {-q[1], -q[2], -q[3], q[4]} end
local function qnorm(q)
    local l = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    if not (l > 1e-8) then return {0, 0, 0, 1} end
    return {q[1] / l, q[2] / l, q[3] / l, q[4] / l}
end
local function qslerp(a, b, t)
    local c = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
    if c < 0 then
        a = {-a[1], -a[2], -a[3], -a[4]}
        c = -c
    end
    if c > 0.9995 then
        return qnorm({a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t})
    end
    local angle = math.acos(clamp(c, -1, 1))
    local s = math.sin(angle)
    local wa, wb = math.sin((1 - t) * angle) / s, math.sin(t * angle) / s
    return {a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb, a[4] * wa + b[4] * wb}
end
local function axis_angle(axis, radians)
    local l = math.sqrt(axis[1] * axis[1] + axis[2] * axis[2] + axis[3] * axis[3])
    if not (l > 1e-8) then return {0, 0, 0, 1} end
    local s = math.sin(radians * 0.5) / l
    return {axis[1] * s, axis[2] * s, axis[3] * s, math.cos(radians * 0.5)}
end
local function rotate(q, v)
    local ux, uy, uz, s = q[1], q[2], q[3], q[4]
    local tx, ty, tz = 2 * (uy * v[3] - uz * v[2]), 2 * (uz * v[1] - ux * v[3]), 2 * (ux * v[2] - uy * v[1])
    return {v[1] + s * tx + (uy * tz - uz * ty), v[2] + s * ty + (uz * tx - ux * tz), v[3] + s * tz + (ux * ty - uy * tx)}
end
local function from_euler(d)
    local k = math.pi / 180
    return qnorm(qmul(qmul(axis_angle({1, 0, 0}, d[1] * k), axis_angle({0, 1, 0}, d[2] * k)), axis_angle({0, 0, 1}, d[3] * k)))
end
local function to_euler(raw)
    local q = qnorm(raw)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local m00, m01, m02 = 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)
    local m12, m22 = 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)
    local k = 180 / math.pi
    local b = math.asin(clamp(m02, -1, 1))
    if math.abs(m02) > 0.9999 then
        local m10, m11 = 2 * (x * y + z * w), 1 - 2 * (x * x + z * z)
        return {math.atan2(m10, m11) * k, b * k, 0}
    end
    return {math.atan2(-m12, m22) * k, b * k, math.atan2(-m01, m00) * k}
end
local function v3(v) return {v.x, v.y, v.z} end
local function vec(t) return vector.create(t[1], t[2], t[3]) end

-- ---- the animation being edited (the PR's anim_studio) --------------------------------------------------
local anim = {
    name = "", trick = "", pop = "", speed = 1, loop = true,
    source = nil, -- the clip the keys go on
    -- By tostring(joint): {joint, keys = {{t, r = {x, y, z, w}, o = {x, y, z}, e = "smooth"}}, hidden, locked}.
    tracks = {},
}
local info = nil -- reskate.animation.info(anim.source)
local settings = {in_game = true, room = true}
local studio = {open = false, time = 0, playing = false, dirty = false, status = "", failure = "", confirm_close = false}
local undo_stack, redo_stack = {}, {}
local orbit = {yaw = 0.6, pitch = 0.18, distance = 3.4, pan = {0, 0, 0}, focus = nil}
local anchor = nil        -- the skater's middle, where the studio opened (before his pose is read)
local in_room, room_walk = false, false -- the studio shows in the character room; the walk there goes on
local face_skater = false -- now() from which the orbit turns to face the skater, once his placement is read
local camera = nil        -- {position, forward, right, up, fov} as last set
local recording = nil     -- {trick, air, status} while a recording is going on
local stale_recording = false -- a recording given up on: its clip is let go when it comes
local loading = nil       -- {what = "opening" | "leaving", since, until_, close}
local clipboard = nil     -- copy_pose

local function now() return reskate.time.now() / 1000 end
local function safe(name)
    local s = string.gsub(name, "[^%w%-_ ]", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return string.sub(s, 1, 40)
end

local function track_of(joint, make)
    local key = tostring(joint)
    if not anim.tracks[key] and make then anim.tracks[key] = {joint = joint, keys = {}, hidden = false, locked = false} end
    return anim.tracks[key]
end
-- A track's edit at `t`, as anim_core's evaluate: before the first key and after the last, the nearest.
local function hermite(p0, p1, p2, p3, u)
    local u2, u3 = u * u, u * u * u
    local h00, h10, h01, h11 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
    local out = {}
    for i = 1, 3 do
        local m1, m2 = (p2[i] - p0[i]) * 0.5, (p3[i] - p1[i]) * 0.5
        out[i] = h00 * p1[i] + h10 * m1 + h01 * p2[i] + h11 * m2
    end
    return out
end
local function evaluate(track, t)
    if not track or #track.keys == 0 then return {0, 0, 0, 1}, {0, 0, 0} end
    local keys = track.keys
    if t <= keys[1].t then return keys[1].r, keys[1].o end
    if t >= keys[#keys].t then return keys[#keys].r, keys[#keys].o end
    local i = 1
    while i + 1 <= #keys and keys[i + 1].t <= t do i += 1 end
    local a, b = keys[i], keys[i + 1]
    local span = b.t - a.t
    local u = if span > 1e-6 then clamp((t - a.t) / span, 0, 1) else 1
    if a.e == "step" then return a.r, a.o end
    if a.e == "linear" then
        return qslerp(a.r, b.r, u), {a.o[1] + (b.o[1] - a.o[1]) * u, a.o[2] + (b.o[2] - a.o[2]) * u, a.o[3] + (b.o[3] - a.o[3]) * u}
    end
    local eased = u * u * (3 - 2 * u)
    local before = if i > 1 then keys[i - 1].o else a.o
    local after = if i + 2 <= #keys then keys[i + 2].o else b.o
    return qslerp(a.r, b.r, eased), hermite(before, a.o, b.o, after, u)
end
local function offset_of(joint) return evaluate(track_of(joint, false), studio.time) end
local function key_here(joint)
    local track = track_of(joint, false)
    if not track then return nil end
    for i, k in track.keys do
        if math.abs(k.t - studio.time) < 0.5 / fps then return k, i end
    end
    return nil
end

-- ---- changes, undo, the live preview -------------------------------------------------------------------
local pending = {}      -- joints changed since the last bake
local baked = {}        -- the tracks as last baked
local baked_clip = nil  -- "edit:studio" once there is one
local preview_due, last_bake = false, -1e9
local posing = false
local last_change = 0
local function copy_tracks(tracks) return reskate.json.decode(reskate.json.encode(tracks)) end
local function begin_change()
    table.insert(undo_stack, reskate.json.encode(anim.tracks))
    if #undo_stack > 50 then table.remove(undo_stack, 1) end
    redo_stack = {}
end
local function changed(joint)
    studio.dirty = true
    preview_due = true
    if joint ~= nil then pending[tostring(joint)] = joint end
end
local function changed_all()
    studio.dirty = true
    preview_due = true
    for key, track in anim.tracks do pending[key] = track.joint end
    for key, track in baked do pending[key] = track.joint end
end
local function set_offset(joint, r, o)
    local track = track_of(joint, true)
    if track.locked then return end
    local t = math.floor(studio.time * fps + 0.5) / fps
    local existing = nil
    for _, k in track.keys do
        if math.abs(k.t - t) < 0.5 / fps then existing = k end
    end
    if existing then
        existing.r, existing.o = qnorm(r), o
    else
        local at = #track.keys + 1
        for i, e in track.keys do
            if e.t > t then at = i break end
        end
        table.insert(track.keys, at, {t = t, r = qnorm(r), o = o, e = "smooth"})
    end
    changed(joint)
end
local function delete_key_at(joint, t)
    local track = track_of(joint, false)
    if not track or track.locked then return end
    for i, k in track.keys do
        if math.abs(k.t - t) < 1e-4 then
            table.remove(track.keys, i)
            changed(joint)
            return
        end
    end
end
local function move_key(joint, from, to)
    local track = track_of(joint, false)
    if not track or track.locked then return end
    to = clamp(to, 0, if info then info.duration else to)
    for i, k in track.keys do
        if math.abs(k.t - from) < 1e-4 then
            table.remove(track.keys, i)
            for j = #track.keys, 1, -1 do
                if math.abs(track.keys[j].t - to) < 0.5 / fps then table.remove(track.keys, j) end
            end
            k.t = to
            local at = #track.keys + 1
            for n, e in track.keys do
                if e.t > to then at = n break end
            end
            table.insert(track.keys, at, k)
            changed(joint)
            return
        end
    end
end
local function undo()
    if #undo_stack == 0 then return end
    table.insert(redo_stack, reskate.json.encode(anim.tracks))
    anim.tracks = reskate.json.decode(table.remove(undo_stack))
    changed_all()
end
local function redo()
    if #redo_stack == 0 then return end
    table.insert(undo_stack, reskate.json.encode(anim.tracks))
    anim.tracks = reskate.json.decode(table.remove(redo_stack))
    changed_all()
end

local function edit_tracks(tracks)
    local list = {}
    for _, track in tracks do
        if #track.keys > 0 and not track.hidden then
            local keys = {}
            for _, k in track.keys do table.insert(keys, {time = k.t, rotation = k.r, offset = vec(k.o), ease = k.e}) end
            table.insert(list, {joint = track.joint, keys = keys})
        end
    end
    return list
end
local function set_playing(on)
    if on == studio.playing then return end
    studio.playing = on
    reskate.animation.pause(not on)
end
local function bake()
    if not anim.source then return end
    local ok, clip = pcall(reskate.animation.edit, anim.source, edit_tracks(anim.tracks), {name = "studio"})
    if not ok then
        studio.failure = "The keys could not be put on the clip: " .. tostring(clip)
        preview_due = false
        return
    end
    baked_clip = clip
    local played, why = reskate.animation.play(clip, {paused = not studio.playing, at = clamp(studio.time, 0, info.duration),
        loop = anim.loop, blend = 0, speed = anim.speed, floor = true})
    if played then
        preview_due = false
        last_bake = reskate.time.now()
        baked = copy_tracks(anim.tracks)
        pending = {}
        studio.failure = ""
    elseif why ~= "asked more than 4 times in a second" then
        studio.failure = "The studio cannot show it: " .. why
        preview_due = false
    end
end
-- What changed since the last bake, on the skater now: each joint turned and moved by the difference.
local function show_pending()
    local offsets, any = {}, false
    for key, joint in pending do
        if joint ~= "board" then
            local now_track, then_track = anim.tracks[key], baked[key]
            local r1, o1 = evaluate(if now_track and not now_track.hidden then now_track else nil, studio.time)
            local r0, o0 = evaluate(if then_track and not then_track.hidden then then_track else nil, studio.time)
            offsets[joint] = {rotation = qnorm(qmul(qconj(r0), r1)), offset = vector.create(o1[1] - o0[1], o1[2] - o0[2], o1[3] - o0[3])}
            any = true
        end
    end
    if any then
        reskate.skater.pose(offsets)
        posing = true
    elseif posing then
        reskate.skater.pose(nil)
        posing = false
    end
end

local function set_time(t)
    if not info then return end
    studio.time = clamp(t, 0, info.duration)
    reskate.animation.seek(studio.time)
end
local function use_source(clip)
    if anim.source and anim.source ~= clip then reskate.animation.forget(anim.source) end
    anim.source = clip
    info = reskate.animation.info(clip)
    studio.time = 0
    baked, pending = {}, {}
    preview_due = true
end

-- ---- settings, the library, the game's tricks -----------------------------------------------------------
local function save_settings() reskate.files.write("studio.json", reskate.json.encode(settings)) end
do
    local ok, s = pcall(reskate.json.decode, reskate.files.read("studio.json") or "")
    if ok and type(s) == "table" then
        if s.in_game ~= nil then settings.in_game = s.in_game == true end
        if s.room ~= nil then settings.room = s.room == true end
    end
end
local library_cache, library_at = {}, -1e9
local function library()
    if reskate.time.now() - library_at < 1000 then return library_cache end
    library_at = reskate.time.now()
    local names = {}
    for _, entry in reskate.files.list("anims") or {} do
        local base = string.match(entry, "^(.+)%.json$")
        if base then table.insert(names, base) end
    end
    table.sort(names)
    library_cache = names
    return names
end
local function profile()
    return {format = "animator-studio-plugin", version = 2, name = anim.name, trick = anim.trick, pop = anim.pop,
            speed = anim.speed, loop = anim.loop, tracks = anim.tracks}
end
-- Older profiles kept angles: turned into rotations.
local function read_tracks(tracks)
    for _, track in tracks or {} do
        for _, k in track.keys or {} do
            if not k.r and k.a then k.r = from_euler(k.a) end
            k.r = k.r or {0, 0, 0, 1}
            k.o = k.o or {0, 0, 0}
            k.e = k.e or "smooth"
        end
        track.hidden = track.hidden == true
        track.locked = track.locked == true
    end
    return tracks or {}
end
-- A saved animation on the game's trick and pop, or taken off it.
local function put_in_game(file, p, source)
    if not p.trick or p.trick == "" then return false, "it has no trick" end
    local pop = if p.pop and p.pop ~= "" and p.pop ~= "any" then p.pop else nil
    if not settings.in_game or not source then return reskate.animation.replace(p.trick, nil, {pop = pop}) end
    local ok, clip = pcall(reskate.animation.edit, source, edit_tracks(read_tracks(p.tracks)), {name = "game " .. file})
    if not ok then return false, tostring(clip) end
    return reskate.animation.replace(p.trick, clip, {pop = pop, speed = p.speed or 1})
end
local function each_saved(fn)
    for _, file in library() do
        local ok, p = pcall(reskate.json.decode, reskate.files.read("anims/" .. file .. ".json") or "")
        if ok and type(p) == "table" then fn(file, p) end
    end
end
local function apply_in_game()
    local count = 0
    library_at = -1e9
    each_saved(function(file, p)
        local ok, placed = pcall(put_in_game, file, p, if settings.in_game then "data:anims/" .. file .. ".fas" else nil)
        if ok and placed and settings.in_game then count += 1 end
    end)
    return count
end
local function save(name)
    name = name or anim.name
    if name == "" then name = if anim.trick ~= "" then anim.trick else "Untitled" end
    local file = safe(name)
    if file == "" then return "A name is letters, digits, spaces, - and _." end
    if not anim.source then return "Record a trick first." end
    anim.name = name
    local ok, why = reskate.animation.save(anim.source, "anims/" .. file .. ".fas")
    if not ok then return "Not saved: " .. why end
    ok, why = reskate.files.write("anims/" .. file .. ".json", reskate.json.encode(profile()))
    if not ok then return "Not saved: " .. why end
    reskate.animation.forget("data:anims/" .. file .. ".fas")
    library_at = -1e9
    put_in_game(file, profile(), anim.source)
    studio.dirty = false
    return "Saved " .. file .. "."
end
local function load(file)
    local text = reskate.files.read("anims/" .. file .. ".json")
    if not text then return "No animation is called " .. file .. "." end
    local ok, p = pcall(reskate.json.decode, text)
    if not ok or type(p) ~= "table" then return file .. " is not an animation." end
    local data = "data:anims/" .. file .. ".fas"
    reskate.animation.forget(data)
    local read, why = pcall(reskate.animation.info, data)
    if not read then return file .. "'s clip cannot be read: " .. tostring(why) end
    anim.name, anim.trick, anim.speed = p.name or file, p.trick or "", p.speed or 1
    anim.loop = p.loop ~= false
    anim.pop = if p.pop == "any" then "" else (p.pop or "")
    anim.tracks = read_tracks(p.tracks)
    undo_stack, redo_stack = {}, {}
    use_source(data)
    studio.dirty = false
    return "Opened " .. file .. "."
end
local function remove(file)
    local ok, p = pcall(reskate.json.decode, reskate.files.read("anims/" .. file .. ".json") or "")
    if ok and type(p) == "table" then put_in_game(file, p, nil) end
    reskate.files.remove("anims/" .. file .. ".json")
    reskate.files.remove("anims/" .. file .. ".fas")
    reskate.animation.forget("data:anims/" .. file .. ".fas")
    library_at = -1e9
    return "Took " .. file .. " out of the library."
end
local function copy_to_pops()
    if not anim.source then return "Pick a trick first." end
    if anim.trick == "" then return "Give it a trick first (SAVED)." end
    local name, pop = anim.name, anim.pop
    local base = safe(if name ~= "" then name else anim.trick)
    for _, p in {"low", "mid", "high"} do
        anim.pop = p
        save(base .. " " .. p)
    end
    anim.name, anim.pop = name, pop
    return "Saved a low, a mid and a high pop copy."
end
-- The game's own tricks: its clips, read out of its data (reskate.animation.game_clips), one for each pop.
-- {the clip's family, the game's name for the trick in the air, the name shown, the category}.
local trick_table = {
    {"o_ollie", "ollie", "Ollie", "Flip tricks"},
    {"o_kickflip", "kickflip", "Kickflip", "Flip tricks"},
    {"o_heelflip", "heelflip", "Heelflip", "Flip tricks"},
    {"o_popshuv_bs", "popshuvit", "Pop Shuv-it", "Flip tricks"},
    {"o_popshuv_fs", "fspopshuvit", "FS Pop Shuv-it", "Flip tricks"},
    {"o_360popshuv_bs", "360popshuvit", "360 Pop Shuv-it", "Flip tricks"},
    {"o_360popshuv_fs", "fs360popshuvit", "FS 360 Pop Shuv-it", "Flip tricks"},
    {"o_varialflip", "varialkickflip", "Varial Kickflip", "Flip tricks"},
    {"o_varialheel", "varialheelflip", "Varial Heelflip", "Flip tricks"},
    {"o_360flip", "360flip", "360 Flip", "Flip tricks"},
    {"o_hardflip", "hardflip", "Hardflip", "Flip tricks"},
    {"o_inwardheel", "inwardheelflip", "Inward Heelflip", "Flip tricks"},
    {"o_360inwardheel", "360inwardheelflip", "360 Inward Heelflip", "Flip tricks"},
    {"o_360hardflip", "360hardflip", "360 Hardflip", "Flip tricks"},
    {"o_laserflip", "laserflip", "Laser Flip", "Flip tricks"},
    {"o_impossible", "bsimpossible", "BF Impossible", "Flip tricks"},
    {"o_frontfoot_impossible", "fsimpossible", "FF Impossible", "Flip tricks"},
    {"n_nollie", "nollie", "Nollie", "Nollie tricks"},
    {"n_kickflip", "nolliekickflip", "Nollie Kickflip", "Nollie tricks"},
    {"n_heelflip", "nollieheelflip", "Nollie Heelflip", "Nollie tricks"},
    {"n_popshuv_bs", "n_popshuvit", "Nollie Pop Shuv-it", "Nollie tricks"},
    {"n_popshuv_fs", "n_fspopshuvit", "Nollie FS Pop Shuv-it", "Nollie tricks"},
    {"n_360popshuv_bs", "n_360popshuvit", "Nollie 360 Pop Shuv-it", "Nollie tricks"},
    {"n_360popshuv_fs", "n_fs360popshuvit", "Nollie FS 360 Pop Shuv-it", "Nollie tricks"},
    {"n_varialflip", "nollievarialkickflip", "Nollie Varial Kickflip", "Nollie tricks"},
    {"n_varialheel", "nollievarialheelflip", "Nollie Varial Heelflip", "Nollie tricks"},
    {"n_360flip", "nollie360flip", "Nollie 360 Flip", "Nollie tricks"},
    {"n_hardflip", "nolliehardflip", "Nollie Hardflip", "Nollie tricks"},
    {"n_inwardheel", "nollieinwardheelflip", "Nollie Inward Heelflip", "Nollie tricks"},
    {"n_360inwardheel", "nollie360inwardheelflip", "Nollie 360 Inward Heelflip", "Nollie tricks"},
    {"n_360hardflip", "nollie360hardflip", "Nollie 360 Hardflip", "Nollie tricks"},
    {"n_laserflip", "nollielaserflip", "Nollie Laser Flip", "Nollie tricks"},
    {"n_impossible", "nolliebsimpossible", "Nollie BF Impossible", "Nollie tricks"},
}
local game_tricks, game_tricks_why, game_tricks_at = nil, "the game's animations are still being read", -1e9
local function catalog()
    if game_tricks then return game_tricks end
    if reskate.time.now() - game_tricks_at < 1000 then return {} end
    game_tricks_at = reskate.time.now()
    -- An older ReSkate has no game clips: the studio works without them.
    if not reskate.animation.game_clips then
        game_tricks_why = "this ReSkate does not read the game's animations; update it"
        return {}
    end
    local names, why = reskate.animation.game_clips("c_proto_onb_trick_")
    if not names then
        game_tricks_why = why
        return {}
    end
    local have = {}
    for _, name in names do have[name] = true end
    local list = {}
    for _, t in trick_table do
        for _, pop in {"low", "mid", "high"} do
            local asset = "animation/dingo/c_proto_onb_trick_" .. t[1] .. "_" .. pop
            if have[asset] then table.insert(list, {trick = t[2], label = t[3], category = t[4], pop = pop, clip = "game:" .. asset}) end
        end
    end
    game_tricks = list
    return list
end
local function load_game_trick(t)
    local data = t.clip
    local ok, why = pcall(reskate.animation.info, data)
    if not ok then return "The game's " .. t.label .. " cannot be read: " .. tostring(why) end
    -- The game's clips stand one way and the game mirrors them for the other stance: so does the studio,
    -- or the trick turned round on the skater's board in game.
    local note = ""
    local goofy = reskate.skater.goofy()
    if goofy ~= nil and why.stance and (why.stance == "goofy") ~= goofy then
        local mirrored = reskate.animation.mirror(data)
        if mirrored then
            data = mirrored
            note = ", mirrored for your " .. (if goofy then "goofy" else "regular") .. " stance"
        end
    end
    anim.name, anim.trick, anim.pop, anim.speed, anim.loop = t.label .. " " .. t.pop, t.trick, t.pop, 1, true
    anim.tracks = {}
    undo_stack, redo_stack = {}, {}
    use_source(data)
    studio.dirty = false
    return "Opened the game's " .. t.label .. " (" .. t.pop .. " pop" .. note .. ")."
end

-- ---- the camera: an orbit round the skater, placed in the free space beside the menu --------------------
local view_shift = {0, 0} -- the view's middle from the screen's, as shares of its height (right, up)
-- Where the skater is drawn (in the room, when it shows there): over his placement, at the height of his
-- hips, so a trick's rise stays in the picture. Eased, as the PR's camera is.
local eased = nil
local function focus_point()
    local place, hips = reskate.skater.joint(1), reskate.skater.joint(7)
    local centre = if place and hips then {place.position.x, hips.position.y + 0.05, place.position.z} else anchor
    if not centre then return nil end
    if face_skater and now() >= face_skater and place then
        -- The PR's facing_yaw: a camera on the placement joint's -Z side shows the skater's left side, so
        -- his front is a quarter turn from it; the orbit starts 0.6 rad round from his front.
        local f = rotate(place.rotation, {0, 0, -1})
        orbit.yaw = math.atan2(f[1], f[3]) - math.pi / 2 + 0.6
        face_skater = false
    end
    if orbit.focus ~= nil then
        local at = reskate.skater.joint(orbit.focus)
        if at then centre = v3(at.position) end
    end
    if not eased or math.abs(eased[1] - centre[1]) + math.abs(eased[3] - centre[3]) > 5 then eased = {centre[1], centre[2], centre[3]} end
    for i = 1, 3 do eased[i] += (centre[i] - eased[i]) * 0.12 end
    return eased
end
local function update_camera()
    local centre = focus_point()
    if not centre then return end
    orbit.pitch = clamp(orbit.pitch, -1.35, 1.45)
    orbit.distance = clamp(orbit.distance, 0.6, 12)
    local cp = math.cos(orbit.pitch)
    local forward = vector.normalize(vector.create(-math.sin(orbit.yaw) * cp, -math.sin(orbit.pitch), -math.cos(orbit.yaw) * cp))
    local right = vector.normalize(vector.cross(forward, vector.create(0, 1, 0)))
    local up = vector.cross(right, forward)
    local fov = 50
    local focal = 1 / (2 * math.tan(fov * math.pi / 360)) -- in screen heights
    local target = vec(centre) + vec(orbit.pan)
    -- The skater sits in the middle of the free space: the camera slides the other way.
    local position = target - forward * orbit.distance - right * (view_shift[1] * orbit.distance / focal)
        - up * (view_shift[2] * orbit.distance / focal)
    reskate.camera.set(position, forward, up, fov)
    camera = {position = position, forward = forward, right = right, up = up, fov = fov}
end

-- ---- open, close, record ------------------------------------------------------------------------------
local ui -- the screen's state, below
local typing_field -- the field being typed into, drawn (below)
local function finish_close()
    studio.open = false
    studio.confirm_close = false
    reskate.ui.close()
    reskate.animation.stop()
    if posing then
        reskate.skater.pose(nil)
        posing = false
    end
    reskate.camera.release()
    reskate.hud.hide(false)
    if in_room or room_walk then
        reskate.room.leave()
        in_room, room_walk = false, false
    end
end
-- Closing: the loading screen over the walk back from the room, then the studio goes.
local function begin_leave()
    local t = now()
    if in_room or room_walk then
        reskate.room.leave()
        in_room, room_walk = false, false
        loading = {what = "leaving", since = t, until_ = t + 1.2, close = true}
    else
        loading = {what = "leaving", since = t, until_ = t + 0.8, close = true}
    end
end
local last_bail = -1e9 -- now() of the skater's last bail
reskate.on("bail", function() last_bail = now() end)
local function open_studio()
    if studio.open then return end
    local s = reskate.skater.get()
    if not s then
        reskate.ui.toast("The studio needs a skater.", "warn")
        return
    end
    -- Held still in the middle of a bail, the skater is lost when the game takes the hold away, and he
    -- goes on bailing behind the studio. A bail lasts about 3.5 s.
    if reskate.skater.state() == "wipeout" or now() - last_bail < 4 then
        reskate.ui.toast("Get back on your board first: the studio opens once the bail is over.", "warn")
        return
    end
    anchor = {s.position.x, s.position.y + 0.9, s.position.z}
    orbit.yaw = s.heading + 0.6
    eased, face_skater = nil, now()
    -- The board stopped where it is, as the PR's studio has the skater: on his board, stood still. Held
    -- with noclip instead, he left his board and the game's flight pose showed through the clip.
    pcall(reskate.skater.set_velocity, vector.create(0, 0, 0))
    reskate.ui.open(title)
    studio.open = true
    studio.playing = false
    preview_due = true
    local t = now()
    loading = {what = "opening", since = t, until_ = t + 1.2}
    -- To the room first: the studio shows there once the walk has got there.
    if settings.room then
        local ok, why = reskate.room.open()
        if ok then
            room_walk = true
            loading.until_ = t + 1.5
        else
            studio.status = "The character room did not open: " .. tostring(why) .. ". The studio opens where you are."
        end
    end
    -- The game's HUD (and its menu's pages) goes once the menu is where the studio wants it: the walk
    -- goes through the menu as the player would, under the loading screen.
    if not room_walk then reskate.hud.hide(true) end
end
local function request_close()
    if studio.dirty and anim.source then
        studio.confirm_close = true
        return
    end
    begin_leave()
end
local function record_next_trick()
    local ok, why = reskate.animation.record(10)
    if not ok then
        studio.failure = "Cannot record: " .. why
        return
    end
    if studio.open then finish_close() end
    recording = recording or {}
    recording.trick, recording.air = nil, false
end
local function cancel_recording()
    recording = nil
    stale_recording = true
end
local function recording_done(clip)
    local trick = recording.trick
    local i = reskate.animation.info(clip)
    if not i.takeoff or not i.landing then
        reskate.animation.forget(clip)
        recording.status = "No trick was landed: still recording."
        record_next_trick()
        return
    end
    recording = nil
    local cut = reskate.animation.trim(clip, math.max(0, i.takeoff - 0.6), math.min(i.duration, i.landing + 0.8))
    reskate.animation.forget(clip)
    anim.tracks, undo_stack, redo_stack = {}, {}, {}
    anim.name, anim.trick, anim.pop = "", trick or "", ""
    use_source(cut)
    studio.dirty = true
    studio.status = "Recorded " .. (trick or "a trick") .. "."
    open_studio()
end
local function save_now() studio.status = save() end

-- ==========================================================================================================
-- The screen (the PR's animation_studio_overlay.cpp)
-- ==========================================================================================================
ui = {
    selected = 7, timeline_zoom = 1, timeline_scroll = 0, rows_scroll = 0, followed_row = -1,
    dragging_playhead = false, dragging_gizmo = false, orbiting = false, panning = false, drag_start = {0, 0},
    key_joint = nil, key_from = 0, key_to = 0, key_moved = false,
    picked = {}, -- {joint, t}
    drag = nil, axis = -1, local_axes = true, move_mode = false,
    message = "", message_until = 0, confirm_delete = "",
    pad_mode = false, playstation = false, held_since = {}, repeat_at = {},
    l3_combo = false, combo_armed = true, stick_turning = false, stick_zoom = false, scrubbing = false, scrub_time = 0,
    stick_dx = 0, stick_dy = 0, stick_idle_since = 0,
    tab = 1, row = 2, menu_hidden = false, warning_choice = 1, zoom_to_playhead = false,
    list_scroll = {0, 0, 0, 0, 0}, list_followed = {-1, -1, -1, -1, -1}, open_trick = "", trick_row = 2,
    last_mouse = {0, 0}, dialog = nil, typing = nil, number_drag = nil, last_click = {0, 0, -1}, hovered_any = false,
}
local function say(text)
    ui.message = text
    ui.message_until = now() + 4
end
local function is_picked(joint, t)
    for _, p in ui.picked do
        if same(p[1], joint) and math.abs(p[2] - t) < 1e-4 then return true end
    end
    return false
end
local function pick_all()
    ui.picked = {}
    for _, track in anim.tracks do
        if not track.locked then
            for _, k in track.keys do table.insert(ui.picked, {track.joint, k.t}) end
        end
    end
    say(if #ui.picked == 0 then "There are no keys yet." else #ui.picked .. " keys chosen: drag one to move them all, Delete takes them off.")
end
local function move_picked(by)
    if math.abs(by) < 1e-4 or #ui.picked == 0 then return end
    table.sort(ui.picked, function(a, b) if by > 0 then return a[2] > b[2] else return a[2] < b[2] end end)
    begin_change()
    for _, p in ui.picked do
        local to = math.max(0, p[2] + by)
        move_key(p[1], p[2], to)
        p[2] = to
    end
end
local function delete_picked()
    if #ui.picked == 0 then return end
    begin_change()
    for _, p in ui.picked do delete_key_at(p[1], p[2]) end
    say(#ui.picked .. " keys taken off.")
    ui.picked = {}
end
local function title_of()
    return upper(if anim.name == "" then (if anim.trick == "" then "Untitled" else anim.trick) else anim.name)
end
local function key_joint()
    if not anim.source then return end
    begin_change()
    local r, o = offset_of(ui.selected)
    set_offset(ui.selected, r, o)
end
local function delete_key()
    local k = key_here(ui.selected)
    if k then
        begin_change()
        delete_key_at(ui.selected, k.t)
    end
end
local function step_frame(frames) set_time((math.floor(studio.time * fps + 0.5) + frames) / fps) end
local function jump_key(direction)
    local track = track_of(ui.selected, false)
    if not track or #track.keys == 0 then return end
    local best = nil
    for _, k in track.keys do
        if direction > 0 and k.t > studio.time + 0.5 / fps and (not best or k.t < best) then best = k.t end
        if direction < 0 and k.t < studio.time - 0.5 / fps and (not best or k.t > best) then best = k.t end
    end
    if best then set_time(best) end
end
local function select_row(delta)
    local i = joint_row[tostring(ui.selected)] or 2
    ui.selected = joints[clamp(i + delta, 1, #joints)].joint
end
local function zoom_timeline(factor)
    ui.timeline_zoom = clamp(ui.timeline_zoom * factor, 1, 16)
    ui.zoom_to_playhead = true
end
local function copy_pose()
    clipboard = {}
    for key, track in anim.tracks do
        local r, o = evaluate(track, studio.time)
        clipboard[key] = {joint = track.joint, r = r, o = o}
    end
    say("Pose copied.")
end
local function paste_pose()
    if not clipboard or not anim.source then return end
    begin_change()
    for _, c in clipboard do set_offset(c.joint, c.r, c.o) end
    say("Pose pasted on this frame.")
end
local function set_track_flags(joint, hidden, locked)
    local track = track_of(joint, true)
    track.hidden, track.locked = hidden, locked
    changed(joint)
end
local function reset_joint(joint)
    local track = track_of(joint, false)
    if track and not track.locked then
        anim.tracks[tostring(joint)] = nil
        changed(joint)
    end
end
local function toggle_focus()
    orbit.focus = if same(orbit.focus, ui.selected) or ui.selected == "board" then nil else ui.selected
end

-- ---- drawing -------------------------------------------------------------------------------------------
local D -- the draw object of this frame
local S, K = 1, 1 -- the window's pixels a 1080-line pixel is; the screen's own scale (the PR's k)
local measured = {}
local function sz(px) return px / S end
local function text(font, px, x, y, colour, value, align, wrap)
    D:text(vector.create(x, y, 0), value, {font = font, size = sz(px), colour = colour, shadow = false, align = align,
        wrap = if wrap then sz(wrap) else nil})
end
local function text_size(font, px, value)
    local key = font .. px .. value
    local m = measured[key]
    if not m then
        m = D:measure(value, {font = font, size = sz(px)})
        measured[key] = m
    end
    return m
end
local function seed_of(x, y) return math.floor(x * 7 + y * 13) % 4294967296 end
local function rough(ax, ay, bx, by, colour, seed, scale)
    D:rough_rect(vector.create(ax, ay, 0), vector.create(bx, by, 0), {colour = colour, seed = seed, scale = clamp(scale / S, 0.1, 10)})
end
local function fill(ax, ay, bx, by, colour, rounding)
    D:rect(vector.create(ax, ay, 0), vector.create(bx, by, 0), {colour = colour, fill = true, rounding = if rounding then sz(rounding) else nil})
end
local function outline(ax, ay, bx, by, colour, thickness)
    D:rect(vector.create(ax, ay, 0), vector.create(bx, by, 0), {colour = colour, thickness = sz(thickness)})
end
local function line(ax, ay, bx, by, colour, thickness)
    D:line(vector.create(ax, ay, 0), vector.create(bx, by, 0), {colour = colour, thickness = sz(thickness)})
end
local function circle(x, y, r, colour, filled, thickness)
    D:circle(vector.create(x, y, 0), r, {colour = colour, fill = filled, thickness = if thickness then sz(thickness) else nil})
end
local function poly(points, colour)
    local list = {}
    for _, p in points do table.insert(list, vector.create(p[1], p[2], 0)) end
    D:poly(list, {colour = colour, fill = true})
end
local function diamond(x, y, r, colour) poly({{x, y - r}, {x + r, y}, {x, y + r}, {x - r, y}}, colour) end
local function bezier(p0, p1, p2, p3, colour, thickness)
    local last = p0
    for i = 1, 8 do
        local t = i / 8
        local u = 1 - t
        local p = {u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
                   u * u * u * p0[2] + 3 * u * u * t * p1[2] + 3 * u * t * t * p2[2] + t * t * t * p3[2]}
        line(last[1], last[2], p[1], p[2], colour, thickness)
        last = p
    end
end
local function halftone(x, y, columns, rows, colour) D:halftone(vector.create(x, y, 0), columns, rows, {colour = colour}) end

-- ---- the mouse, keys and pad of this frame ----------------------------------------------------------------
local mouse = {x = 0, y = 0, down = {false, false, false}, pressed = {false, false, false}, released = {false, false, false},
               wheel = 0, dx = 0, dy = 0, press_at = {0, 0}, double = false}
local hovered_this = false
local function inside(ax, ay, bx, by, x, y)
    x, y = x or mouse.x, y or mouse.y
    return x >= ax and y >= ay and x <= bx and y <= by
end
-- A clickable box: hovered, and clicked when the press began and ended in it.
local function hit(ax, ay, bx, by)
    local over = inside(ax, ay, bx, by)
    if over then hovered_this = true end
    return over and mouse.released[1] and inside(ax, ay, bx, by, mouse.press_at[1], mouse.press_at[2]), over
end
local keys_down, keys_pressed, keys_repeat = {}, {}, {}
local key_codes = {space = 0x20, left = 0x25, up = 0x26, right = 0x27, down = 0x28, enter = 0x0D, q = 0x51, e = 0x45, home = 0x24, ["end"] = 0x23,
    z = 0x5A, y = 0x59, c = 0x43, v = 0x56, s = 0x53, a = 0x41, plus = 0xBB, numplus = 0x6B, minus = 0xBD, numminus = 0x6D, f = 0x46,
    k = 0x4B, delete = 0x2E, x = 0x58, r = 0x52, g = 0x47, l = 0x4C, tab = 0x09, one = 0x31, two = 0x32, three = 0x33, four = 0x34,
    five = 0x35, zero = 0x30, ctrl = 0x11, shift = 0x10, alt = 0x12, backspace = 0x08, escape = 0x1B}
local function read_keys(t)
    for name, code in key_codes do
        local down = reskate.input.key(code)
        local was = keys_down[name]
        keys_pressed[name] = down and not was
        keys_repeat[name] = false
        if down and not was then
            keys_repeat[name] = true
            ui.repeat_at["k" .. name] = t + 0.38
        elseif down and t >= (ui.repeat_at["k" .. name] or 1e9) then
            keys_repeat[name] = true
            ui.repeat_at["k" .. name] = t + 0.07
        end
        keys_down[name] = down
    end
end
local function read_mouse(t)
    local c = reskate.input.cursor()
    local was = mouse.down
    local down = if c then {c.left, c.right, c.middle} else {false, false, false}
    local x = if c then c.position.x else mouse.x
    local y = if c then c.position.y else mouse.y
    mouse.dx, mouse.dy = x - mouse.x, y - mouse.y
    mouse.x, mouse.y = x, y
    for i = 1, 3 do
        mouse.pressed[i] = down[i] and not was[i]
        mouse.released[i] = was[i] and not down[i]
    end
    mouse.down = down
    mouse.wheel = if c then c.wheel else 0
    mouse.double = false
    if mouse.pressed[1] then
        mouse.press_at = {x, y}
        if t - ui.last_click[3] < 0.35 and math.abs(x - ui.last_click[1]) < 6 and math.abs(y - ui.last_click[2]) < 6 then mouse.double = true end
        ui.last_click = {x, y, t}
    end
end
local pad_names = {"up", "down", "left", "right", "start", "back", "left_stick", "right_stick", "lb", "rb", "a", "b", "x", "y"}
local pad_down, pad_pressed, pad_released = {}, {}, {}
local function read_pad(t)
    local pad = reskate.input.gamepad()
    if not pad then
        for _, n in pad_names do pad_down[n], pad_pressed[n], pad_released[n] = false, false, false end
        return nil
    end
    ui.playstation = pad.playstation
    for _, n in pad_names do
        local down = pad.buttons[n] == true
        pad_pressed[n] = down and not pad_down[n]
        pad_released[n] = (pad_down[n] == true) and not down
        if pad_pressed[n] then ui.held_since[n] = t end
        pad_down[n] = down
    end
    return pad
end
local function repeats(name, t)
    if pad_pressed[name] then
        ui.repeat_at[name] = t + 0.38
        return true
    end
    if pad_down[name] and t >= (ui.repeat_at[name] or 1e9) then
        ui.repeat_at[name] = t + 0.07
        return true
    end
    return false
end
local function held_for(name, t) return if pad_down[name] then t - (ui.held_since[name] or t) else 0 end

-- ---- typing into the card's fields (reskate.input.text: Esc is the field's while it types) -----------------
-- The byte after `chars` characters of `text`.
local function byte_at(text_value, chars)
    if chars <= 0 then return 0 end
    local at = utf8.offset(text_value, chars + 1)
    return (at or (#text_value + 1)) - 1
end
local function length_of(text_value) return utf8.len(text_value) or #text_value end
-- A field starts typing with all of it chosen: what is typed replaces it.
local function edit_start(id, value, max, apply)
    ui.editing = {id = id, text = value, caret = length_of(value), all = true, max = max, apply = apply}
    ui.blink_from = now()
end
local function edit_stop(commit)
    local e = ui.editing
    ui.editing = nil
    reskate.input.text(false)
    if commit and e then e.apply(e.text) end
end
-- What was typed and pressed this frame, into the field.
local function edit_keys(typed)
    local e = ui.editing
    if not e then return end
    local function clear_chosen()
        if e.all then e.text, e.caret, e.all = "", 0, false end
    end
    if typed ~= "" then
        clear_chosen()
        local room = e.max - length_of(e.text)
        if room > 0 then
            local add = typed
            if length_of(add) > room then add = string.sub(add, 1, byte_at(add, room)) end
            local at = byte_at(e.text, e.caret)
            e.text = string.sub(e.text, 1, at) .. add .. string.sub(e.text, at + 1)
            e.caret += length_of(add)
            ui.blink_from = now()
        end
    end
    if keys_repeat.backspace then
        if e.all then clear_chosen()
        elseif e.caret > 0 then
            e.text = string.sub(e.text, 1, byte_at(e.text, e.caret - 1)) .. string.sub(e.text, byte_at(e.text, e.caret) + 1)
            e.caret -= 1
        end
        ui.blink_from = now()
    end
    if keys_repeat.delete then
        if e.all then clear_chosen()
        elseif e.caret < length_of(e.text) then
            e.text = string.sub(e.text, 1, byte_at(e.text, e.caret)) .. string.sub(e.text, byte_at(e.text, e.caret + 1) + 1)
        end
    end
    if keys_repeat.left then e.caret, e.all = math.max(0, if e.all then 0 else e.caret - 1), false end
    if keys_repeat.right then e.caret, e.all = math.min(length_of(e.text), e.caret + 1), false end
    if keys_pressed.home then e.caret, e.all = 0, false end
    if keys_pressed["end"] then e.caret, e.all = length_of(e.text), false end
    if keys_down.ctrl and keys_pressed.a then e.all = true end
    if keys_pressed.enter then edit_stop(true)
    elseif keys_pressed.escape then edit_stop(false) end
end

-- ---- controller glyphs and prompts -----------------------------------------------------------------------
local function glyph(x, y, g)
    local k = K
    local r = 11 * k
    local cx, cy = x + r, y + r
    local function label(s, w)
        fill(x, y + 2 * k, x + w, y + 2 * r - 2 * k, white, 5 * k)
        text("bold", 11 * k, x + w * 0.5, cy - 7 * k, black, s, "centre")
        return w
    end
    if g == "a" or g == "b" or g == "x" or g == "y" then
        circle(cx, cy, r, white, true)
        if not ui.playstation then
            text("bold", 14 * k, cx, cy - 9 * k, black, upper(g), "centre")
        else
            local s, w = r * 0.48, 2.2 * k
            if g == "a" then
                line(cx - s, cy - s, cx + s, cy + s, black, w)
                line(cx - s, cy + s, cx + s, cy - s, black, w)
            elseif g == "b" then circle(cx, cy, s, black, false, w)
            elseif g == "x" then outline(cx - s, cy - s, cx + s, cy + s, black, w)
            else
                line(cx, cy - s, cx + s, cy + s * 0.75, black, w)
                line(cx + s, cy + s * 0.75, cx - s, cy + s * 0.75, black, w)
                line(cx - s, cy + s * 0.75, cx, cy - s, black, w)
            end
        end
        return 2 * r
    end
    local ps = ui.playstation
    if g == "lb" then return label(if ps then "L1" else "LB", 30 * k) end
    if g == "rb" then return label(if ps then "R1" else "RB", 30 * k) end
    if g == "lt" then return label(if ps then "L2" else "LT", 30 * k) end
    if g == "rt" then return label(if ps then "R2" else "RT", 30 * k) end
    if g == "l3" then return label("L3", 30 * k) end
    if g == "r3" then return label("R3", 30 * k) end
    if g == "menu" then return label(if ps then "OPT" else "MENU", 40 * k) end
    if g == "view" then return label(if ps then "SHARE" else "VIEW", 44 * k) end
    if g == "ls" or g == "rs" then
        circle(cx, cy, r, white, false, 2 * k)
        text("bold", 12 * k, cx, cy - 8 * k, white, if g == "ls" then "L" else "R", "centre")
        return 2 * r
    end
    if g == "dpad_ud" or g == "dpad_lr" then
        local a, t = r * 0.9, r * 0.34
        fill(cx - t, cy - a, cx + t, cy + a, if g == "dpad_ud" then white else with_alpha(white, 90 / 255))
        fill(cx - a, cy - t, cx + a, cy + t, if g == "dpad_lr" then white else with_alpha(white, 90 / 255))
        return 2 * r
    end
    return 0
end
local function key_cap(x, y, key)
    local w = text_size("bold", 11 * K, key).x
    fill(x, y + 2 * K, x + w + 12 * K, y + 20 * K, white, 3 * K)
    text("bold", 11 * K, x + 6 * K, y + 4 * K, black, key)
    return w + 12 * K
end
local function prompt(x, y, g, key, what)
    local w = if ui.pad_mode and g then glyph(x, y, g) else key_cap(x, y, key)
    text("bold", 13 * K, x + w + 7 * K, y + 3 * K, white, what)
    return w + 7 * K + text_size("bold", 13 * K, what).x + 20 * K
end

-- ---- turning the chosen joint (mouse drag or left stick) ---------------------------------------------------
-- The joint in the world (with its edits), and its parent's turn and scale.
local function joint_world(joint)
    if joint == "board" then
        if not info or not info.board or not anim.source then return nil end
        local place = reskate.skater.joint(1)
        local ok, b = pcall(reskate.animation.sample, baked_clip or anim.source, "board", studio.time)
        if not place or not ok or not b then return nil end
        local pr = place.rotation
        local p = rotate(pr, {b.position.x * place.scale, b.position.y * place.scale, b.position.z * place.scale})
        return {position = {place.position.x + p[1], place.position.y + p[2], place.position.z + p[3]}, rotation = qmul(pr, b.rotation),
                parent_rotation = pr, parent_scale = place.scale}
    end
    local at = reskate.skater.joint(joint)
    if not at then return nil end
    local parent = if at.parent then reskate.skater.joint(at.parent) else nil
    return {position = v3(at.position), rotation = at.rotation, parent_rotation = if parent then parent.rotation else {0, 0, 0, 1},
            parent_scale = if parent then parent.scale else 1}
end
local function begin_turn()
    local sel = joint_world(ui.selected)
    if not sel then return false end
    local r, o = offset_of(ui.selected)
    ui.drag = {r = r, o = o, world = sel.rotation, parent = sel.parent_rotation, parent_scale = sel.parent_scale}
    begin_change()
    set_playing(false)
    return true
end
-- `dx`, `dy`: how far the turn has gone, in screen pixels at 1080 lines.
local function apply_turn(dx, dy, move)
    local d = ui.drag
    if not d or not camera then return end
    local right, up = v3(camera.right), v3(camera.up)
    local r, o = d.r, {d.o[1], d.o[2], d.o[3]}
    local radians = 0.0085
    if move and moves(ui.selected) then
        local metres = 1 / 400
        local world = {}
        for i = 1, 3 do world[i] = right[i] * dx * metres - up[i] * dy * metres end
        if ui.axis >= 0 then
            for i = 1, 3 do
                if i ~= ui.axis + 1 then world[i] = 0 end
            end
        end
        local l = rotate(qconj(d.parent), world)
        for i = 1, 3 do o[i] += l[i] / math.max(d.parent_scale, 0.01) end
    else
        local turn
        if ui.axis >= 0 then
            local axis = {0, 0, 0}
            axis[ui.axis + 1] = 1
            local q = axis_angle(axis, (dx - dy) * radians)
            turn = if ui.local_axes then q else qmul(qmul(qconj(d.world), q), d.world)
        else
            local world = qmul(axis_angle(up, dx * radians), axis_angle(right, dy * radians))
            turn = qmul(qmul(qconj(d.world), world), d.world)
        end
        r = qnorm(qmul(d.r, turn))
        if ui.selected == "board" then
            -- The board's keys turn it about the ground's axes.
            local ground
            if ui.axis >= 0 then
                local axis = {0, 0, 0}
                axis[ui.axis + 1] = 1
                ground = axis_angle(axis, (dx - dy) * radians)
            else
                local world = qmul(axis_angle(up, dx * radians), axis_angle(right, dy * radians))
                ground = qmul(qmul(qconj(d.parent), world), d.parent)
            end
            r = qnorm(qmul(ground, d.r))
        end
    end
    set_offset(ui.selected, r, o)
end

-- ---- the menu: skate.'s own list menu (Trick List), with tabs -----------------------------------------------
local tab_names = {"TRICKS", "SAVED", "JOINTS", "KEYS", "PLAYBACK"}
local record_about = "Skate and land the trick you want: you are back in the studio with it, the board where the game had it. Esc: back without one."
local function rows_of(tab)
    local rows = {}
    local function row(label, value, about, act, enabled, on, saved)
        table.insert(rows, {label = label, value = value or "", about = about or "", act = act, enabled = enabled ~= false, on = on, library = saved})
    end
    if tab == 1 then
        local list = catalog()
        if ui.open_trick ~= "" then
            local label = ""
            for _, t in list do
                if t.trick == ui.open_trick then label = t.label end
            end
            row("< Back", "", "Back to the list of tricks.", function()
                ui.open_trick = ""
                ui.row = ui.trick_row
            end)
            row(upper(label), "", "", nil, false)
            for _, t in list do
                if t.trick == ui.open_trick then
                    local pop = if t.pop == "low" then "Low pop" elseif t.pop == "mid" then "Mid pop" else "High pop"
                    row(pop, "", "Opens the game's " .. t.label .. " with a " .. t.pop .. " pop to change it. Save it and it plays on your " .. t.label .. "s. "
                        .. "In flips the game places the board with its physics, which these clips do not hold.", function() say(load_game_trick(t)) end,
                        true, anim.trick == t.trick and anim.pop == t.pop)
                end
            end
            return rows
        end
        row("RECORD", "", "", nil, false)
        row("Record a trick", "", record_about, record_next_trick)
        local category, trick = nil, nil
        for _, t in list do
            if t.category ~= category then
                category = t.category
                row(upper(category or "GAME TRICKS"), "", "", nil, false)
            end
            if t.trick ~= trick then
                trick = t.trick
                local index = #rows + 1
                row(t.label, ">", "Choose the pop next: low, mid or high.", function()
                    ui.open_trick = t.trick
                    ui.trick_row = index
                    ui.row = 3
                end, true, anim.trick == t.trick)
            end
        end
    elseif tab == 2 then
        local names = library()
        if #names == 0 then row("Nothing saved yet", "", "Pick a trick in TRICKS, change it and save it: it shows up here.", nil, false) end
        for _, name in names do
            local value = if safe(anim.name) == name then "open" else ""
            if ui.confirm_delete == name then value = "delete again" end
            row(name, value, "A saved animation: choose it to open it. Delete takes it out of the library (press it twice).",
                function() say(load(name)) end, true, safe(anim.name) == name, name)
        end
    elseif tab == 3 then
        for _, j in joints do
            local track = track_of(j.joint, false)
            local count = if track then #track.keys else 0
            local value = if count > 0 then count .. (if count == 1 then " key" else " keys") else ""
            if track and track.hidden then value ..= "  off" end
            if track and track.locked then value ..= "  locked" end
            row(j.label, value, "", function() ui.selected = j.joint end)
        end
    elseif tab == 4 then
        local key = key_here(ui.selected)
        local track = track_of(ui.selected, false)
        local locked = track ~= nil and track.locked
        local joint = upper(label_of(ui.selected))
        local has_keys = track ~= nil and #track.keys > 0
        row("Key this frame", joint, "Keys the joint as it is now on this frame.", key_joint, anim.source ~= nil and not locked)
        row("Delete key", "", "Takes the joint's key on this frame off.", delete_key, key ~= nil and not locked)
        row("Select all keys", if #ui.picked == 0 then "Ctrl A" else tostring(#ui.picked),
            "Chooses every key of every joint and the board: drag one to move them all, Delete takes them off. Shift + click adds or takes one key; Esc lets go.",
            pick_all, anim.source ~= nil)
        row("Delete chosen keys", "", "Takes every chosen key off.", delete_picked, #ui.picked > 0)
        row("Previous key", "", "The playhead to the joint's key before this frame.", function() jump_key(-1) end, has_keys)
        row("Next key", "", "The playhead to the joint's key after this frame.", function() jump_key(1) end, has_keys)
        if key then
            local names = {smooth = "Smooth", linear = "Linear", step = "Step"}
            local next_ease = {smooth = "linear", linear = "step", step = "smooth"}
            row("Blend into the next key", names[key.e], "Smooth eases in and out, Linear goes straight, Step holds this key until the next.", function()
                begin_change()
                key.e = next_ease[key.e]
                changed(ui.selected)
            end, not locked)
        end
        row("Turn about", if ui.axis == 0 then "X" elseif ui.axis == 1 then "Y" elseif ui.axis == 2 then "Z" else "any axis",
            "Which axis a drag or the left stick turns the joint about.", function() ui.axis = if ui.axis >= 2 then -1 else ui.axis + 1 end)
        row("Axes", if ui.local_axes then "the joint's own" else "the world's", "X, Y and Z of the joint itself or of the world.",
            function() ui.local_axes = not ui.local_axes end)
        row("Follow joint", "", "The camera keeps the joint in the middle (again: the whole skater).", toggle_focus)
        row("Copy pose", "", "Remembers every joint's edit on this frame.", copy_pose)
        row("Paste pose", "", "Keys the remembered pose on this frame.", paste_pose, anim.source ~= nil)
        row("Reset joint", joint, "Takes all of the joint's keys off.", function()
            begin_change()
            reset_joint(ui.selected)
        end, track ~= nil and not locked)
        row("Hide joint's keys", if track and track.hidden then "hidden" else "", "Plays the trick as if the joint had no keys.",
            function() set_track_flags(ui.selected, not (track ~= nil and track.hidden), locked) end)
        row("Lock joint", if locked then "locked" else "", "A locked joint's keys cannot be changed.",
            function() set_track_flags(ui.selected, track ~= nil and track.hidden, not locked) end)
        row("Undo", "", "", undo, #undo_stack > 0)
        row("Redo", "", "", redo, #redo_stack > 0)
    else
        row(if studio.playing then "Pause" else "Play", "", "Plays the trick with your keys.", function() set_playing(not studio.playing) end, anim.source ~= nil)
        row("Loop", if anim.loop then "on" else "off", "", function()
            anim.loop = not anim.loop
            preview_due = true
        end)
        row("Speed", string.format("%.2fx", anim.speed), "How fast the trick plays, here and in game. Choose it to step through the speeds.", function()
            local speeds = {0.25, 0.5, 0.75, 1, 1.25, 1.5, 2}
            local nxt = speeds[1]
            for _, s in speeds do
                if s > anim.speed + 0.01 then nxt = s break end
            end
            anim.speed = nxt
            studio.dirty = true
            preview_due = true
        end)
        row("Studio room", if settings.room then "on" else "off",
            "On: the studio opens in the game's own lit studio room, as skate.'s Skaters page shows it. Off: it opens where you are. Takes effect the next time it opens.",
            function()
                settings.room = not settings.room
                save_settings()
                studio.status = if settings.room then "From the next time it opens, the studio opens in its room."
                    else "From the next time it opens, the studio opens where you are."
            end)
        row("Custom tricks in game", if settings.in_game then "on" else "off",
            "On: when you do a trick you saved an animation for (its TRICK, as ollie or kickflip), yours plays instead of the game's.", function()
                settings.in_game = not settings.in_game
                save_settings()
                apply_in_game()
            end)
        row("Pop", if anim.pop == "" then "any" else anim.pop,
            "Which pop this plays on: any, or only a low, mid or high pop (one of each can be saved for a trick). Choose it to step through.", function()
                anim.pop = if anim.pop == "" then "low" elseif anim.pop == "low" then "mid" elseif anim.pop == "mid" then "high" else ""
                studio.dirty = true
            end, anim.source ~= nil)
        row("Copy to low, mid and high pop", "", "Saves this trick three times, one for each pop, to change each on its own. In game every pop is timed to its own air.",
            function() say(copy_to_pops()) end, anim.source ~= nil)
        row("Save", if studio.dirty then "not saved" else "", "Saves the animation in the library.", save_now, anim.source ~= nil)
        row("Close the studio", "", "Back to skating. The camera and the game's HUD come back.", request_close)
    end
    return rows
end
local function switch_tab(delta)
    ui.tab = (ui.tab - 1 + delta) % #tab_names + 1
    ui.row = if ui.tab == 1 then (if ui.open_trick == "" then 2 else 3) else 1
    ui.confirm_delete = ""
end
local function move_row(delta)
    if ui.tab == 3 then
        select_row(delta)
        return
    end
    local rows = rows_of(ui.tab)
    local count = #rows
    local at = ui.row
    for _ = 1, count do
        at = clamp(at + delta, 1, math.max(1, count))
        if rows[at] and (rows[at].act or at == 1 or at == count) then break end
    end
    if count > 0 and not rows[at].act then at = ui.row end
    ui.row = at
end
local function activate_row()
    if ui.tab == 3 then
        key_joint()
        return
    end
    local r = rows_of(ui.tab)[ui.row]
    if r and r.enabled and r.act then r.act() end
end
local function delete_row()
    local r = rows_of(ui.tab)[ui.row]
    if not r or not r.library then return end
    if ui.confirm_delete == r.library then
        say(remove(r.library))
        ui.confirm_delete = ""
    else
        ui.confirm_delete = r.library
    end
end

-- ---- the controller ----------------------------------------------------------------------------------------
local function controller(pad, t, dt)
    if not pad then return end
    local any = false
    for _, n in pad_names do any = any or pad_pressed[n] end
    local sticks = math.abs(pad.left_x) > 0.35 or math.abs(pad.left_y) > 0.35 or math.abs(pad.right_x) > 0.35 or math.abs(pad.right_y) > 0.35
        or pad.left_trigger > 0.4 or pad.right_trigger > 0.4
    if any or sticks then ui.pad_mode = true end
    -- L3 + R3 held: close the studio (the same hold opens it from the game).
    if pad_down.left_stick and pad_down.right_stick then
        ui.l3_combo = true
        if ui.combo_armed and held_for("left_stick", t) > 0.5 and held_for("right_stick", t) > 0.5 then
            request_close()
            ui.combo_armed = false
        end
        return
    end
    if ui.l3_combo then
        if not pad_down.left_stick and not pad_down.right_stick then
            ui.l3_combo = false
            ui.combo_armed = true
        end
        return
    end
    if studio.confirm_close then return end
    if pad_pressed.lb then switch_tab(-1) end
    if pad_pressed.rb then switch_tab(1) end
    if pad_pressed.a then activate_row() end
    if pad_pressed.x then
        if ui.tab == 2 then delete_row() else delete_key() end
    end
    if pad_pressed.y then set_playing(not studio.playing) end
    if pad_pressed.b then undo() end
    if pad_pressed.back then
        if ui.timeline_zoom > 1.01 then ui.timeline_zoom = 1 else zoom_timeline(3) end
    end
    if pad_pressed.start then save_now() end
    -- L3: turn about any axis, X, Y, Z, then move (the hips and the board).
    if pad_released.left_stick and t - (ui.held_since.left_stick or t) < 0.5 then
        if ui.move_mode then ui.move_mode, ui.axis = false, -1
        elseif ui.axis >= 2 then ui.move_mode, ui.axis = true, -1
        else ui.axis += 1 end
    end
    if pad_released.right_stick and t - (ui.held_since.right_stick or t) < 0.5 then ui.stick_zoom = not ui.stick_zoom end
    if repeats("up", t) then move_row(-1) end
    if repeats("down", t) then move_row(1) end
    -- RT plays forward and LT backward, as fast as they are pressed (fully: real time), to watch it.
    local scrub = pad.right_trigger - pad.left_trigger
    if math.abs(scrub) > 0.08 and anim.source then
        local sign = if scrub > 0 then 1 else -1
        local amount = (math.abs(scrub) - 0.08) / 0.92
        ui.scrub_time = clamp((if ui.scrubbing then ui.scrub_time else studio.time) + sign * amount * amount * dt, 0, info.duration)
        ui.scrubbing = true
        set_playing(false)
        set_time(ui.scrub_time)
    elseif ui.scrubbing then
        ui.scrubbing = false
        set_time(math.floor(studio.time * fps + 0.5) / fps)
    end
    if repeats("left", t) then step_frame(-1) end
    if repeats("right", t) then step_frame(1) end
    -- Left stick turns the chosen joint (or moves the hips or the board); a turn is one undo step.
    local dz = 0.22
    local lx = if math.abs(pad.left_x) > dz then pad.left_x else 0
    local ly = if math.abs(pad.left_y) > dz then pad.left_y else 0
    if lx ~= 0 or ly ~= 0 then
        local track = track_of(ui.selected, false)
        if not ui.stick_turning and anim.source and not (track and track.locked) and begin_turn() then
            ui.stick_turning = true
            ui.stick_dx, ui.stick_dy = 0, 0
        end
        if ui.stick_turning then
            ui.stick_dx += lx * 300 * dt
            ui.stick_dy -= ly * 300 * dt
            apply_turn(ui.stick_dx, ui.stick_dy, ui.move_mode)
        end
        ui.stick_idle_since = t
    elseif ui.stick_turning and t - ui.stick_idle_since > 0.25 then
        ui.stick_turning = false
    end
    -- Right stick orbits; after R3 it zooms (up / down) and pans (left / right).
    local rx = if math.abs(pad.right_x) > dz then pad.right_x else 0
    local ry = if math.abs(pad.right_y) > dz then pad.right_y else 0
    if rx ~= 0 or ry ~= 0 then
        if ui.stick_zoom then
            orbit.distance *= 1 - ry * 1.6 * dt
            if camera then
                local r = v3(camera.right)
                for i = 1, 3 do orbit.pan[i] += r[i] * rx * orbit.distance * 0.5 * dt end
            end
        else
            orbit.yaw -= rx * 2.2 * dt
            orbit.pitch -= ry * 1.6 * dt
        end
    end
end

-- ---- the parts of the screen ---------------------------------------------------------------------------
-- The page title, brushed like the game's ("TRICK LIST"), with its spray of dots.
local function page_title(x, y)
    local k = K
    halftone(x - 18 * k, y + 6 * k, 3, 9, rgba(255, 255, 255, 70))
    text("title_large", 74 * k, x, y, white, "ANIMATOR")
    local w = text_size("title_large", 74 * k, "ANIMATOR")
    text("title_large", 74 * k, x + w.x + 22 * k, y, white, "STUDIO")
    local w2 = text_size("title_large", 74 * k, "STUDIO")
    halftone(x + w.x + w2.x + 30 * k, y + 10 * k, 3, 7, rgba(255, 255, 255, 60))
    text("bold", 15 * k, x + 6 * k, y - 14 * k, blue_light, "RESKATE")
end
-- The tab row: Q / E (LB / RB) either side, the chosen tab outlined with a blue brush stroke under it.
local function tab_row(x0, y)
    local k = K
    local h, fs = 36 * k, 25 * k
    local x = x0
    local function cap(key, g)
        if ui.pad_mode then
            x += glyph(x, y + 7 * k, g) + 12 * k
        else
            outline(x, y + 7 * k, x + 22 * k, y + 29 * k, white, 2 * k)
            text("bold", 13 * k, x + 11 * k, y + 10 * k, white, key, "centre")
            x += 22 * k + 14 * k
        end
    end
    cap("Q", "lb")
    for i, name in tab_names do
        local t = text_size("heading", fs, name)
        local ax, ay, bx, by = x, y, x + t.x + 20 * k, y + h
        if hit(ax, ay, bx, by) then
            ui.tab = i
            ui.row = 1
        end
        local chosen = ui.tab == i
        rough(ax, ay, bx, by, if chosen then rgba(22, 22, 24, 250) else rgba(26, 26, 28, 236), seed_of(ax, ay), k * 0.6)
        if chosen then
            outline(ax - 3 * k, ay - 3 * k, bx + 3 * k, by + 3 * k, white, 2.6 * k)
            bezier({ax - 2 * k, by + 6 * k}, {ax + (bx - ax) * 0.3, by + 9 * k}, {ax + (bx - ax) * 0.7, by + 3 * k}, {bx + 4 * k, by + 5 * k}, blue, 4 * k)
        end
        text("heading", fs, ax + 10 * k, ay + (h - t.y) * 0.5, white, name)
        x = bx + 14 * k
    end
    cap("E", "rb")
end
-- The list: dark rough rows; the chosen one a blue brush stroke with a screen-print fade at its end.
local function list(x0, y0, w, h)
    local k = K
    local row_h, gap = 50 * k, 8 * k
    local rows = rows_of(ui.tab)
    local chosen = ui.row
    if ui.tab == 3 then chosen = joint_row[tostring(ui.selected)] or 1 end
    chosen = clamp(chosen, 1, math.max(1, #rows))
    if ui.tab ~= 3 then ui.row = chosen end
    rough(x0 - 18 * k, y0 - 10 * k, x0 + w + 18 * k, y0 + h + 10 * k, rgba(48, 50, 56, 150), 61, k)
    local content = #rows * (row_h + gap)
    local scroll = ui.list_scroll[ui.tab]
    if ui.list_followed[ui.tab] ~= chosen then
        ui.list_followed[ui.tab] = chosen
        local top = (chosen - 1) * (row_h + gap)
        if top < scroll then scroll = top end
        if top + row_h > scroll + h then scroll = top + row_h - h end
    end
    if inside(x0, y0, x0 + w, y0 + h) and mouse.wheel ~= 0 then scroll -= mouse.wheel * (row_h + gap) end
    scroll = clamp(scroll, 0, math.max(0, content - h))
    ui.list_scroll[ui.tab] = scroll
    D:clip(vector.create(x0, y0, 0), vector.create(x0 + w + 4 * k, y0 + h, 0))
    for i, r in rows do
        local y = y0 + (i - 1) * (row_h + gap) - scroll
        if y + row_h >= y0 and y <= y0 + h then
            local ax, ay, bx, by = x0, y, x0 + w - 24 * k, y + row_h
            local clicked, hovered = hit(ax, math.max(ay, y0), bx, math.min(by, y0 + h))
            local here = i == chosen
            if here then
                rough(ax, ay, bx, by, blue, seed_of(ax, ay), k * 1.2)
                halftone(bx - 70 * k, ay + 8 * k, 9, 5, rgba(255, 255, 255, 46))
                D:scribble(vector.create(ax, ay - 2 * k, 0), vector.create(ax + 4 * k, by + 2 * k, 0), {seed = 7 + i, scale = clamp(k / S, 0.1, 10)})
            else
                rough(ax, ay, bx, by, if hovered then rgba(40, 41, 44, 246) else rgba(24, 24, 26, 246), seed_of(ax, ay), k)
                fill(ax + 2 * k, by, bx - 2 * k, by + 3 * k, rgba(0, 0, 0, 120))
            end
            text("bold", 21 * k, ax + 30 * k, ay + row_h * 0.5 - 12 * k, if r.enabled then white else faint, r.label)
            if r.value ~= "" then text("bold", 16 * k, bx - 22 * k, ay + row_h * 0.5 - 9 * k, if here then white else soft, r.value, "right") end
            if r.on and not here then fill(ax, ay + 6 * k, ax + 4 * k, by - 6 * k, blue) end
            if clicked then
                if ui.tab == 3 then ui.selected = joints[i].joint
                else
                    ui.row = i
                    if r.enabled and r.act then r.act() end
                end
            end
        end
    end
    D:clip()
    -- The thin scroll bar at the right, as the game's lists have.
    local bar_x = x0 + w - 8 * k
    fill(bar_x, y0, bar_x + 3 * k, y0 + h, rgba(220, 220, 225, 120))
    if content > h then
        local bh = math.max(30 * k, h * h / content)
        local y = y0 + (h - bh) * scroll / (content - h)
        fill(bar_x - 4 * k, y, bar_x + 7 * k, y + bh, rgba(235, 235, 240), 2 * k)
    end
end
-- The field being typed into, drawn: its text (all of it chosen, at first), the caret blinking after
-- the last character typed. A click outside it ends the typing and keeps what was typed.
typing_field = function(id, ax, ay, w, h, px, ink, over, align)
    local k = K
    local e = ui.editing
    e.seen = true
    fill(ax, ay, ax + w, ay + h, rgba(215, 230, 250), 2 * k)
    outline(ax, ay, ax + w, ay + h, blue, 1.6 * k)
    D:clip(vector.create(ax, ay, 0), vector.create(ax + w - 4 * k, ay + h, 0))
    local full = text_size("bold", px, e.text)
    local x = if align == "centre" then ax + (w - full.x) * 0.5 else ax + 8 * k
    local y = ay + (h - px) * 0.5 - 1 * k
    if e.all and e.text ~= "" then fill(x - 2 * k, y, x + full.x + 2 * k, y + px + 2 * k, blue_dim) end
    text("bold", px, x, y, ink, e.text)
    if not e.all and math.floor((now() - (ui.blink_from or 0)) * 2) % 2 == 0 then
        local before = text_size("bold", px, string.sub(e.text, 1, byte_at(e.text, e.caret))).x
        line(x + before + 1 * k, y, x + before + 1 * k, y + px + 2 * k, ink, 1.6 * k)
    end
    D:clip()
    if mouse.pressed[1] and not over then edit_stop(true) end
end
-- A labelled number that drags left and right, and takes typing on a double click.
local function number(id, x, y, w, label, value, speed, format, ink, on_change)
    local k = K
    text("bold", 14 * k, x, y + 4 * k, ink, label)
    local ax, ay, bx, by = x + 22 * k, y, x + 22 * k + w, y + 26 * k
    local _, over = hit(ax, ay, bx, by)
    if ui.editing and ui.editing.id == id then
        typing_field(id, ax, ay, bx - ax, by - ay, 14 * k, ink, over, "centre")
        return
    end
    local active = ui.number_drag ~= nil and ui.number_drag.id == id
    fill(ax, ay, bx, by, if active then rgba(150, 200, 255) elseif over then rgba(190, 192, 196) else rgba(205, 205, 204), 2 * k)
    text("bold", 14 * k, (ax + bx) * 0.5, ay + 5 * k, ink, string.format(format, value), "centre")
    if over and mouse.double then
        ui.number_drag = nil
        edit_start(id, string.format(format, value), 16, function(typed)
            local n = tonumber(typed)
            if n then
                begin_change()
                on_change(n)
            end
        end)
        return
    end
    if over and mouse.pressed[1] then ui.number_drag = {id = id, start = mouse.x, value = value} end
    if active then
        if mouse.down[1] then
            local next_value = ui.number_drag.value + (mouse.x - ui.number_drag.start) / k * speed
            if math.abs(next_value - value) > 1e-6 then on_change(next_value) end
        else
            ui.number_drag = nil
        end
    end
end
-- The white card under the list, as the game's trick description: the chosen joint's numbers, or what
-- the highlighted row does.
local function card(x, y0, w, h)
    local k = K
    rough(x + 6 * k, y0 + 6 * k, x + w + 6 * k, y0 + h + 6 * k, rgba(0, 0, 0, 140), 71, k)
    rough(x, y0, x + w, y0 + h, rgba(234, 234, 232, 252), 73, k)
    halftone(x + w - 40 * k, y0 + 10 * k, 4, 10, rgba(0, 0, 0, 22))
    local ink, ink_soft = rgba(20, 20, 22), rgba(90, 90, 96)
    local y = y0 + 16 * k
    if ui.tab == 3 or ui.tab == 4 then
        text("heading", 22 * k, x + 22 * k, y, ink, upper(label_of(ui.selected)))
        local key = key_here(ui.selected)
        text("bold", 13 * k, x + w - 22 * k, y + 6 * k, if key then blue else ink_soft, if key then "KEY ON THIS FRAME" else "NO KEY ON THIS FRAME", "right")
        y += 40 * k
        local r, o = offset_of(ui.selected)
        local euler, position = to_euler(r), {o[1], o[2], o[3]}
        -- The board: where it is and how it is turned, from where it starts on the ground.
        local base = nil
        if ui.selected == "board" and anim.source and info.board then
            local at = reskate.animation.sample(anim.source, "board", studio.time)
            local start = reskate.animation.sample(anim.source, "board", 0)
            if at and start then
                base = {position = {at.position.x - start.position.x, at.position.y - start.position.y, at.position.z - start.position.z},
                        rotation = qmul(qconj(start.rotation), at.rotation)}
                for i = 1, 3 do position[i] = base.position[i] + o[i] end
                euler = to_euler(qmul(r, base.rotation))
            end
        end
        local track = track_of(ui.selected, false)
        local locked = track ~= nil and track.locked
        local col_w = (w - 44 * k) / 3
        local axes = {"X", "Y", "Z"}
        local function edit_change(next_euler, next_position)
            if locked or not anim.source then return end
            if now() - last_change > 0.4 then begin_change() end
            last_change = now()
            if base then
                local no = {}
                for i = 1, 3 do no[i] = next_position[i] - base.position[i] end
                set_offset(ui.selected, qnorm(qmul(from_euler(next_euler), qconj(base.rotation))), no)
            else
                set_offset(ui.selected, from_euler(next_euler), next_position)
            end
        end
        text("bold", 13 * k, x + 22 * k, y, ink_soft, if base then "ROTATION (0, 0, 0 = AS IT STARTS)" else "ROTATION")
        for i = 1, 3 do
            number("r" .. i, x + 22 * k + (i - 1) * col_w, y + 18 * k, col_w - 34 * k, axes[i], euler[i], 0.4, "%.1f", ink, function(v)
                local e = {euler[1], euler[2], euler[3]}
                e[i] = v
                edit_change(e, position)
            end)
        end
        if moves(ui.selected) then
            text("bold", 13 * k, x + 22 * k, y + 52 * k, ink_soft, if base then "POSITION (0, 0, 0 = WHERE IT STARTS, ON THE GROUND)" else "POSITION")
            for i = 1, 3 do
                number("p" .. i, x + 22 * k + (i - 1) * col_w, y + 70 * k, col_w - 34 * k, axes[i], position[i], 0.002, "%.3f", ink, function(v)
                    local p = {position[1], position[2], position[3]}
                    p[i] = v
                    edit_change(euler, p)
                end)
            end
        end
        if ui.tab == 4 then
            local r2 = rows_of(ui.tab)[ui.row]
            if r2 then text("bold", 14 * k, x + 22 * k, y0 + h - 30 * k, ink_soft, r2.about, nil, w - 44 * k) end
        end
        return
    end
    if ui.tab == 2 then
        -- The name and trick of the one being edited, typed here.
        local fw = (w - 60 * k) / 2
        text("bold", 13 * k, x + 22 * k, y, ink_soft, "NAME")
        text("bold", 13 * k, x + 38 * k + fw, y, ink_soft, "TRICK")
        local fields = {
            {x + 22 * k, anim.name, "name", 40, function(v)
                if v ~= anim.name then
                    anim.name = v
                    studio.dirty = true
                end
            end},
            {x + 38 * k + fw, anim.trick, "trick", 48, function(v)
                v = string.lower(v)
                if v ~= anim.trick then
                    anim.trick = v
                    studio.dirty = true
                end
            end},
        }
        for _, field in fields do
            local ax, ay = field[1], y + 18 * k
            local clicked, over = hit(ax, ay, ax + fw, ay + 30 * k)
            if ui.editing and ui.editing.id == field[3] then
                typing_field(field[3], ax, ay, fw, 30 * k, 16 * k, ink, over)
            else
                fill(ax, ay, ax + fw, ay + 30 * k, if over then rgba(195, 197, 200) else rgba(205, 205, 204), 2 * k)
                D:clip(vector.create(ax, ay, 0), vector.create(ax + fw - 6 * k, ay + 30 * k, 0))
                text("bold", 16 * k, ax + 8 * k, ay + 6 * k, ink, field[2])
                D:clip()
                if clicked then edit_start(field[3], field[2], field[4], field[5]) end
            end
        end
        y += 62 * k
    end
    local r3 = rows_of(ui.tab)[ui.row]
    if r3 then text("bold", 19 * k, x + 22 * k, y, ink, r3.about, nil, w - 44 * k) end
end
-- A flat button: rough tile, white type, blue when on. Returns whether it was clicked.
local function button(x, y, w, h, label, on, enabled)
    enabled = enabled ~= false
    local clicked, over = hit(x, y, x + w, y + h)
    clicked = clicked and enabled
    over = over and enabled
    rough(x, y, x + w, y + h, if on then blue elseif over then rgba(64, 66, 72, 240) else rgba(34, 35, 38, 240), seed_of(x, y), K * 0.7)
    text("bold", 14 * K, x + w * 0.5, y + (h - 16 * K) * 0.5, if enabled then white else faint, label, "centre")
    return clicked
end
-- The bottom of the screen: the whole trick from start to end, one row of keys per joint with a row of
-- every key on top, the playhead across all of them.
local function timeline(x0, y0, w, h)
    local k = K
    local label_w, header_h, summary_h, row_h, gap = 280 * k, 70 * k, 30 * k, 40 * k, 4 * k
    local has_clip = anim.source ~= nil
    rough(x0 - 10 * k, y0, x0 + w + 10 * k, y0 + h + 10 * k, rgba(14, 14, 16, 236), 81, k * 1.4)
    text("title", 30 * k, x0 + 20 * k, y0 + 4 * k, white, title_of())
    local bx, by = x0 + 20 * k, y0 + 42 * k
    local cw, ch = 30 * k, 22 * k
    if button(bx, by, cw, ch, "|<", false, has_clip) then set_time(0) end
    bx += cw + 4 * k
    if button(bx, by, cw, ch, "<", false, has_clip) then step_frame(-1) end
    bx += cw + 4 * k
    if button(bx, by, 62 * k, ch, if studio.playing then "PAUSE" else "PLAY", studio.playing, has_clip) then set_playing(not studio.playing) end
    bx += 62 * k + 4 * k
    if button(bx, by, cw, ch, ">", false, has_clip) then step_frame(1) end
    bx += cw + 4 * k
    if button(bx, by, cw, ch, ">|", false, has_clip) then set_time(if info then info.duration else 0) end
    bx += cw + 4 * k
    if button(bx, by, 40 * k, ch, "LOOP", anim.loop) then
        anim.loop = not anim.loop
        preview_due = true
    end
    local duration = math.max(if info then info.duration else 0, 0.5)
    local pad = 22 * k
    do
        local zx = x0 + w - 16 * k - 3 * 34 * k
        if button(zx, y0 + 6 * k, 30 * k, 24 * k, "-", false, ui.timeline_zoom > 1) then zoom_timeline(1 / 1.5) end
        zx += 34 * k
        if button(zx, y0 + 6 * k, 30 * k, 24 * k, "FIT", ui.timeline_zoom <= 1.001) then ui.timeline_zoom = 1 end
        zx += 34 * k
        if button(zx, y0 + 6 * k, 30 * k, 24 * k, "+", false, ui.timeline_zoom < 16) then zoom_timeline(1.5) end
        if has_clip then
            text("bold", 13 * k, x0 + w - 16 * k, y0 + 36 * k, soft,
                string.format("%.2f / %.2f s   frame %d", studio.time, info.duration, math.floor(studio.time * fps + 0.5)), "right")
        end
    end
    local ruler_left, ruler_right = x0 + label_w, x0 + w - 130 * k
    local ruler_w = ruler_right - ruler_left
    local seconds_w = (ruler_w - 2 * pad) / duration * ui.timeline_zoom
    if ui.zoom_to_playhead or ui.timeline_zoom <= 1.001 then
        ui.timeline_scroll = studio.time * seconds_w - (ruler_w - 2 * pad) * 0.5
        ui.zoom_to_playhead = false
    else
        local px = pad + studio.time * seconds_w - ui.timeline_scroll
        if studio.playing and (px < pad or px > ruler_w - pad) then ui.timeline_scroll = studio.time * seconds_w - (ruler_w - 2 * pad) * 0.5 end
    end
    ui.timeline_scroll = clamp(ui.timeline_scroll, 0, math.max(0, duration * seconds_w - (ruler_w - 2 * pad)))
    local function x_of(t) return ruler_left + pad + t * seconds_w - ui.timeline_scroll end
    local function t_of(x) return clamp((x - ruler_left - pad + ui.timeline_scroll) / seconds_w, 0, if info then info.duration else 0) end
    local lanes_right = x0 + w
    -- The ruler: frame numbers.
    D:clip(vector.create(ruler_left, y0, 0), vector.create(ruler_right, y0 + h, 0))
    local frames = math.ceil(duration * fps)
    local frame_w = seconds_w / fps
    local every = if frame_w > 26 * k then 1 elseif frame_w > 9 * k then 5 else 10
    for i = 0, frames do
        local x = x_of(i / fps)
        if x >= ruler_left - 20 and x <= ruler_right + 20 then
            local labelled = i % every == 0
            line(x, y0 + header_h - (if labelled then 16 else 7) * k, x, y0 + header_h - 3 * k, if labelled then white else faint, 1.6 * k)
            if labelled then text("bold", 16 * k, x, y0 + 26 * k, white, tostring(i), "centre") end
        end
    end
    if has_clip then
        for _, mark in {{info.takeoff, "POP"}, {info.landing, "LAND"}} do
            if mark[1] then
                local x = x_of(mark[1])
                line(x, y0 + header_h, x, y0 + h, rgba(1, 131, 255, 80), 1.5 * k)
                text("bold", 12 * k, x + 4 * k, y0 + 8 * k, blue_light, mark[2])
            end
        end
    end
    D:clip()
    -- The ruler drags the playhead.
    if inside(ruler_left, y0, ruler_right, y0 + header_h) then
        hovered_this = true
        if mouse.pressed[1] then ui.dragging_playhead = true end
    end
    if ui.dragging_playhead then
        if mouse.down[1] and has_clip then
            local t = t_of(mouse.x)
            if not keys_down.alt then t = math.floor(t * fps + 0.5) / fps end
            set_time(t)
            set_playing(false)
        else
            ui.dragging_playhead = false
        end
    end
    -- Every key of every joint, in one row: the whole animation at a glance.
    local summary_y = y0 + header_h + 4 * k
    rough(x0 + 8 * k, summary_y, lanes_right - 8 * k, summary_y + summary_h, rgba(30, 31, 34, 240), 83, k * 0.6)
    text("heading", 15 * k, x0 + 22 * k, summary_y + 6 * k, soft, "ALL KEYS")
    D:clip(vector.create(ruler_left, summary_y, 0), vector.create(ruler_right, summary_y + summary_h, 0))
    for _, track in anim.tracks do
        for _, key in track.keys do diamond(x_of(key.t), summary_y + summary_h * 0.5, 6 * k, if track.hidden then faint else soft) end
    end
    D:clip()
    -- Rows, one per joint, following the chosen one.
    local rows_top = summary_y + summary_h + 6 * k
    local rows_h = y0 + h - rows_top
    local content_h = #joints * (row_h + gap)
    local chosen_row = joint_row[tostring(ui.selected)] or 1
    if ui.followed_row ~= chosen_row then
        ui.followed_row = chosen_row
        local top = (chosen_row - 1) * (row_h + gap)
        if top < ui.rows_scroll then ui.rows_scroll = top end
        if top + row_h > ui.rows_scroll + rows_h then ui.rows_scroll = top + row_h - rows_h end
    end
    ui.rows_scroll = clamp(ui.rows_scroll, 0, math.max(0, content_h - rows_h))
    D:clip(vector.create(x0, rows_top, 0), vector.create(lanes_right, y0 + h, 0))
    for r, j in joints do
        local y = rows_top + (r - 1) * (row_h + gap) - ui.rows_scroll
        if y + row_h >= rows_top and y <= y0 + h then
            local chosen = same(j.joint, ui.selected)
            local track = track_of(j.joint, false)
            local ax, ay, bx2, by2 = x0 + 8 * k, y, lanes_right - 8 * k, y + row_h
            if chosen then
                rough(ax, ay, ax + label_w - 12 * k, by2, blue, seed_of(ax, ay), k)
                halftone(ax + label_w - 70 * k, ay + 6 * k, 8, 4, rgba(255, 255, 255, 46))
                rough(ax + label_w - 4 * k, ay, bx2, by2, rgba(44, 50, 62, 236), seed_of(ax, ay) + 1, k)
            else
                rough(ax, ay, ax + label_w - 12 * k, by2, rgba(24, 24, 26, 246), seed_of(ax, ay), k)
                rough(ax + label_w - 4 * k, ay, bx2, by2, if r % 2 == 0 then rgba(30, 31, 34, 220) else rgba(34, 35, 38, 220), seed_of(ax, ay) + 1, k)
            end
            local has_keys = track ~= nil and #track.keys > 0
            text("bold", 17 * k, ax + 20 * k, y + row_h * 0.5 - 10 * k, if chosen or has_keys then white else soft, upper(j.label))
            local top, bottom = math.max(ay, rows_top), math.min(by2, y0 + h)
            if hit(ax, top, ax + label_w - 12 * k, bottom) then ui.selected = j.joint end
            local lane_over = inside(ruler_left, top, ruler_right, bottom)
            local lane_pressed = lane_over and mouse.pressed[1]
            if lane_over then hovered_this = true end
            local on_key = false
            if track then
                D:clip(vector.create(ruler_left, rows_top, 0), vector.create(ruler_right, y0 + h, 0))
                for _, key in track.keys do
                    local dragged_with = ui.key_joint ~= nil and is_picked(j.joint, key.t) and is_picked(ui.key_joint, ui.key_from)
                    local shown = key.t
                    if ui.key_joint ~= nil and same(ui.key_joint, j.joint) and math.abs(key.t - ui.key_from) < 1e-4 then shown = ui.key_to
                    elseif dragged_with then shown = key.t + (ui.key_to - ui.key_from) end
                    local cx, cy = x_of(shown), y + row_h * 0.5
                    local current = math.abs(key.t - studio.time) < 0.5 / fps
                    local close_to = lane_over and math.abs(mouse.x - cx) < 9 * k
                    local in_pick = is_picked(j.joint, key.t)
                    if (current and chosen) or in_pick then diamond(cx, cy, 13 * k, if in_pick then blue else blue_dim) end
                    diamond(cx, cy, (if close_to then 10.5 else 9) * k, if track.hidden then faint elseif in_pick or (current and chosen) then blue_light else white)
                    if key.e == "step" then line(cx, cy - 4 * k, cx, cy + 4 * k, rgba(40, 40, 40), 2 * k) end
                    if close_to and lane_pressed and not track.locked and not on_key then
                        on_key = true
                        if keys_down.shift then
                            local found = nil
                            for n, p in ui.picked do
                                if same(p[1], j.joint) and math.abs(p[2] - key.t) < 1e-4 then found = n end
                            end
                            if found then table.remove(ui.picked, found) else table.insert(ui.picked, {j.joint, key.t}) end
                        else
                            if not in_pick then ui.picked = {} end
                            ui.key_joint, ui.key_from, ui.key_to, ui.key_moved = j.joint, key.t, key.t, false
                            ui.selected = j.joint
                            set_time(key.t)
                        end
                    end
                end
                D:clip()
            end
            if lane_pressed and not on_key and has_clip then
                ui.picked = {}
                ui.selected = j.joint
                set_time(math.floor(t_of(mouse.x) * fps + 0.5) / fps)
                set_playing(false)
            end
        end
    end
    D:clip()
    if ui.key_joint ~= nil then
        if mouse.down[1] then
            local to = math.floor(t_of(mouse.x) * fps + 0.5) / fps
            if math.abs(to - ui.key_to) > 1e-4 then ui.key_moved = true end
            ui.key_to = to
        else
            if ui.key_moved and math.abs(ui.key_to - ui.key_from) > 1e-4 then
                if is_picked(ui.key_joint, ui.key_from) and #ui.picked > 1 then move_picked(ui.key_to - ui.key_from)
                else
                    begin_change()
                    move_key(ui.key_joint, ui.key_from, ui.key_to)
                end
                set_time(ui.key_to)
            end
            ui.key_joint = nil
        end
    end
    if has_clip then
        local x = x_of(studio.time)
        if x >= ruler_left and x <= ruler_right then
            line(x, y0 + 4 * k, x, y0 + h, blue, 2.4 * k)
            poly({{x - 8 * k, y0 + 2 * k}, {x + 8 * k, y0 + 2 * k}, {x, y0 + 12 * k}}, blue)
        end
    end
    -- Wheel: scroll the rows; Ctrl + wheel zooms; Shift + wheel scrolls the time.
    if inside(x0, y0, x0 + w, y0 + h) and mouse.wheel ~= 0 then
        if keys_down.ctrl then zoom_timeline(if mouse.wheel > 0 then 1.25 else 1 / 1.25)
        elseif keys_down.shift then ui.timeline_scroll -= mouse.wheel * 60 * k
        else ui.rows_scroll -= mouse.wheel * (row_h + gap) end
    end
end
-- The skater: dots on the joints that can be chosen, the glowing ring on the chosen one, and the drag.
local function viewport(vx0, vy0, vx1, vy1, t)
    local k = K
    local over = inside(vx0, vy0, vx1, vy1) and not ui.hovered_any
    local points = {}
    local hovered, best = nil, 22 * k
    for _, j in joints do
        local w = joint_world(j.joint)
        if w then
            local on = D:world_to_screen(vec(w.position))
            if on then
                points[tostring(j.joint)] = on
                if not ui.pad_mode and over then
                    local dist = math.sqrt((on.x - mouse.x) ^ 2 + (on.y - mouse.y) ^ 2)
                    if dist < best then best, hovered = dist, j.joint end
                end
            end
        end
    end
    for key, on in points do
        if key ~= tostring(ui.selected) then
            local hot = hovered ~= nil and tostring(hovered) == key
            circle(on.x, on.y, (if hot then 6 else 3.5) * k, if hot then blue_light else rgba(255, 255, 255, 90), true)
        end
    end
    local sel_at = points[tostring(ui.selected)]
    if sel_at then
        -- The chosen joint: a small blue ring around it, softly glowing.
        local r = 11 * k
        local pulse = 0.8 + 0.2 * math.sin(t * 3.2)
        for i = 3, 1, -1 do circle(sel_at.x, sel_at.y, r + i * 2.2 * k, rgba(1, 131, 255, math.floor(40 * (4 - i) * pulse)), false, 2.4 * k) end
        circle(sel_at.x, sel_at.y, r, rgba(60, 165, 255), false, 2.6 * k)
        circle(sel_at.x, sel_at.y, 3 * k, rgba(230, 240, 255), true)
        if ui.pad_mode then text("bold", 13 * k, sel_at.x + 30 * k, sel_at.y - 8 * k, blue_light, upper(label_of(ui.selected))) end
    end
    if hovered ~= nil and not same(hovered, ui.selected) then
        local on = points[tostring(hovered)]
        if on then text("bold", 13 * k, on.x + 10 * k, on.y - 22 * k, white, upper(label_of(hovered))) end
    end
    if sel_at then
        local r, o = offset_of(ui.selected)
        local e = to_euler(r)
        local x, y = vx0 + 24 * k, vy1 - 92 * k
        if moves(ui.selected) then
            text("heading", 15 * k, x, y - 44 * k, rgba(255, 255, 255, 110), "POSITION")
            text("body", 13 * k, x, y - 24 * k, rgba(255, 255, 255, 90), string.format("X: %.2f    Y: %.2f    Z: %.2f", o[1], o[2], o[3]))
        end
        text("heading", 15 * k, x, y, rgba(255, 255, 255, 110), "ROTATION")
        text("body", 13 * k, x, y + 20 * k, rgba(255, 255, 255, 90), string.format("X: %.0f    Y: %.0f    Z: %.0f", e[1], e[2], e[3]))
        local axis = if ui.axis == 0 then "X" elseif ui.axis == 1 then "Y" elseif ui.axis == 2 then "Z" else "FREE"
        text("body", 12 * k, x, y + 42 * k, rgba(120, 190, 255, 150),
            string.format("%s  axis %s  (%s)", if ui.move_mode then "MOVE" else "TURN", axis, if ui.local_axes then "local" else "world"))
    end
    if not over and not ui.dragging_gizmo and not ui.orbiting and not ui.panning then return end
    if over and mouse.pressed[1] then
        if hovered ~= nil and not same(hovered, ui.selected) then ui.selected = hovered
        elseif sel_at and anim.source then
            local track = track_of(ui.selected, false)
            if not (track and track.locked) and begin_turn() then
                ui.dragging_gizmo = true
                ui.drag_start = {mouse.x, mouse.y}
            end
        end
    end
    if ui.dragging_gizmo then
        if not mouse.down[1] then ui.dragging_gizmo = false
        else apply_turn((mouse.x - ui.drag_start[1]) / k, (mouse.y - ui.drag_start[2]) / k, ui.move_mode) end
    end
    if over and mouse.pressed[2] then ui.orbiting = true end
    if over and mouse.pressed[3] then ui.panning = true end
    if ui.orbiting then
        if not mouse.down[2] then ui.orbiting = false
        else
            orbit.yaw -= mouse.dx * 0.006
            orbit.pitch += mouse.dy * 0.005
        end
    end
    if ui.panning then
        if not mouse.down[3] then ui.panning = false
        elseif camera then
            local metres = orbit.distance / (900 * k)
            local right, up = v3(camera.right), v3(camera.up)
            for i = 1, 3 do orbit.pan[i] += -right[i] * mouse.dx * metres + up[i] * mouse.dy * metres end
        end
    end
    if over and mouse.wheel ~= 0 then orbit.distance *= if mouse.wheel > 0 then 0.9 else 1.1 end
end
local function keyboard()
    if ui.editing then return end
    local ctrl = keys_down.ctrl
    local any = false
    local function pressed(name, repeat_too)
        local p = if repeat_too then keys_repeat[name] else keys_pressed[name]
        any = any or p
        return p
    end
    if pressed("space") then set_playing(not studio.playing) end
    if pressed("left", true) then step_frame(-1) end
    if pressed("right", true) then step_frame(1) end
    if pressed("up", true) then move_row(-1) end
    if pressed("down", true) then move_row(1) end
    if pressed("enter") then activate_row() end
    if not ctrl and pressed("q") then switch_tab(-1) end
    if not ctrl and pressed("e") then switch_tab(1) end
    if pressed("home") then set_time(0) end
    if pressed("end") then set_time(if info then info.duration else 0) end
    if ctrl and pressed("z", true) then undo() end
    if ctrl and pressed("y", true) then redo() end
    if ctrl and pressed("c") then copy_pose() end
    if ctrl and pressed("v") then paste_pose() end
    if ctrl and pressed("s") then save_now() end
    if ctrl and pressed("a") then pick_all() end
    if pressed("plus") or pressed("numplus") then zoom_timeline(1.5) end
    if pressed("minus") or pressed("numminus") then zoom_timeline(1 / 1.5) end
    if not ctrl and pressed("f") then toggle_focus() end
    if not ctrl and pressed("k") and anim.source then key_joint() end
    if pressed("delete") then
        if ui.tab == 2 then delete_row() elseif #ui.picked > 0 then delete_picked() else delete_key() end
    end
    if not ctrl and pressed("x") then ui.axis = if ui.axis == 0 then -1 else 0 end
    if not ctrl and pressed("y") then ui.axis = if ui.axis == 1 then -1 else 1 end
    if not ctrl and pressed("z") then ui.axis = if ui.axis == 2 then -1 else 2 end
    if not ctrl and pressed("r") then ui.move_mode = false end
    if not ctrl and pressed("g") then ui.move_mode = true end
    if not ctrl and pressed("l") then ui.local_axes = not ui.local_axes end
    if not ctrl and pressed("tab") then ui.menu_hidden = not ui.menu_hidden end
    if pressed("one") then orbit.yaw, orbit.pitch = 0, 0.1
    elseif pressed("two") then orbit.yaw, orbit.pitch = math.pi, 0.1
    elseif pressed("three") then orbit.yaw, orbit.pitch = math.pi / 2, 0.1
    elseif pressed("four") then orbit.yaw, orbit.pitch = -math.pi / 2, 0.1
    elseif pressed("five") then orbit.yaw, orbit.pitch = 0.6, 0.18
    elseif pressed("zero") then orbit.yaw, orbit.pitch, orbit.distance, orbit.pan, orbit.focus = 0.6, 0.18, 3.4, {0, 0, 0}, nil end
    if any or math.sqrt((mouse.x - ui.last_mouse[1]) ^ 2 + (mouse.y - ui.last_mouse[2]) ^ 2) > 4 or mouse.pressed[1] then ui.pad_mode = false end
    ui.last_mouse = {mouse.x, mouse.y}
end
-- An action button like the game's "P UN-PIN": its key or button, then what it does.
local function action_button(x, y, w, h, g, key, what, fill_colour, fill_hot, ink)
    local k = K
    local clicked, over = hit(x, y, x + w, y + h)
    rough(x, y, x + w, y + h, if over then fill_hot else fill_colour, seed_of(x, y), k)
    local cx = x + 18 * k
    if ui.pad_mode and g then
        cx += glyph(cx, y + h * 0.5 - 11 * k, g) + 12 * k
    else
        local t = text_size("bold", 14 * k, key)
        local kw = math.max(26 * k, t.x + 12 * k)
        outline(cx, y + h * 0.5 - 13 * k, cx + kw, y + h * 0.5 + 13 * k, ink, 2.2 * k)
        text("bold", 14 * k, cx + kw * 0.5, y + h * 0.5 - 8 * k, ink, key, "centre")
        cx += kw + 12 * k
    end
    text("heading", 22 * k, cx, y + h * 0.5 - 13 * k, ink, what)
    return clicked
end
-- The lower right: KEY and SAVE, and under them the controls in a tidy two-column panel.
local function prompts(vx1, vy1)
    local k = K
    local move = if ui.move_mode then "Move (L3: turn)" elseif ui.axis < 0 then "Turn (L3: axis)" elseif ui.axis == 0 then "Turn X (L3)"
        elseif ui.axis == 1 then "Turn Y (L3)" else "Turn Z (L3)"
    local list_rows
    if ui.pad_mode then
        list_rows = {{"ls", "", move}, {"rs", "", if ui.stick_zoom then "Zoom / pan (R3)" else "Orbit (R3: zoom)"}, {"rt", "", "Play forward"},
            {"lt", "", "Play back"}, {"dpad_ud", "", "Choose"}, {"dpad_lr", "", "One frame"}, {"y", "", if studio.playing then "Pause" else "Play"},
            {"x", "", "Delete key"}, {"b", "", "Undo"}, {"view", "", "Zoom timeline"}, {"lb", "", "Tabs (RB)"}, {"l3", "", "+ R3 hold: back"}}
    else
        list_rows = {{nil, "LMB", "Pick / turn"}, {nil, "RMB", "Orbit"}, {nil, "MMB", "Pan"}, {nil, "G / R", if ui.move_mode then "Move" else "Turn"},
            {nil, "X Y Z", "Axis"}, {nil, "UP DN", "Choose"}, {nil, "< >", "One frame"}, {nil, "SPACE", if studio.playing then "Pause" else "Play"},
            {nil, "DEL", "Delete key"}, {nil, "CTRL Z", "Undo"}, {nil, "- / +", "Zoom timeline"}, {nil, "F8", "Back"}}
    end
    local col_w, row_h, pad = 205 * k, 30 * k, 14 * k
    local rows = math.floor((#list_rows + 1) / 2)
    local panel_w, panel_h = 2 * col_w + 2 * pad, rows * row_h + 2 * pad
    local bx, by = vx1 - 20 * k, vy1 - 50 * k
    local ax, ay = bx - panel_w, by - panel_h
    rough(ax, ay, bx, by, rgba(12, 12, 14, 200), 93, k)
    if inside(ax, ay, bx, by) then hovered_this = true end
    for i, r in list_rows do
        local x, y = ax + pad + ((i - 1) % 2) * col_w, ay + pad + math.floor((i - 1) / 2) * row_h
        if r[1] then glyph(x, y, r[1]) else key_cap(x, y, r[2]) end
        text("bold", 13 * k, x + 66 * k, y + 3 * k, white, r[3])
    end
    local sw, sh = panel_w * 0.5 - 6 * k, 48 * k
    local sy = ay - 12 * k - sh
    if action_button(ax, sy, sw, sh, "menu", "CTRL S", if studio.dirty then "SAVE *" else "SAVE", rgba(236, 236, 234, 250), rgba(255, 255, 255), black)
        and anim.source then save_now() end
    if action_button(ax + sw + 12 * k, sy, sw, sh, "a", "K", "KEY", rgba(234, 214, 96), rgba(246, 226, 120), black) and anim.source then key_joint() end
end
-- Closing with changes not saved: the game's white card asks first.
local function close_warning(dx, dy, t)
    local k = K
    fill(0, 0, dx, dy, rgba(0, 0, 0, 150))
    local w, h = 640 * k, 260 * k
    local ax, ay = (dx - w) * 0.5, (dy - h) * 0.45
    local bx, by = ax + w, ay + h
    rough(ax + 6 * k, ay + 6 * k, bx + 6 * k, by + 6 * k, rgba(0, 0, 0, 160), 95, k)
    rough(ax, ay, bx, by, rgba(236, 236, 234, 252), 97, k)
    local ink = rgba(20, 20, 22)
    text("title", 40 * k, ax + 30 * k, ay + 18 * k, ink, "UNSAVED CHANGES")
    text("bold", 19 * k, ax + 30 * k, ay + 84 * k, rgba(60, 60, 66),
        "\"" .. title_of() .. "\" has changes that are not saved. Save them before you go back to skating?", nil, w - 60 * k)
    local labels = {"SAVE", "DON'T SAVE", "STAY"}
    ui.warning_choice = clamp(ui.warning_choice, 1, 3)
    local bw, bh = (w - 60 * k - 2 * 12 * k) / 3, 48 * k
    local y = by - 30 * k - bh
    local taken = nil
    for i = 1, 3 do
        local x = ax + 30 * k + (i - 1) * (bw + 12 * k)
        local clicked, over = hit(x, y, x + bw, y + bh)
        if over and (mouse.dx ~= 0 or mouse.dy ~= 0) then ui.warning_choice = i end
        local chosen = ui.warning_choice == i
        rough(x, y, x + bw, y + bh, if chosen then blue else rgba(32, 32, 35, 250), seed_of(x, y), k)
        if chosen then halftone(x + bw - 44 * k, y + 6 * k, 6, 5, rgba(255, 255, 255, 46)) end
        text("heading", 22 * k, x + bw * 0.5, y + (bh - 26 * k) * 0.5, white, labels[i], "centre")
        if clicked then taken = i end
    end
    if pad_pressed.left then ui.warning_choice = math.max(1, ui.warning_choice - 1) end
    if pad_pressed.right then ui.warning_choice = math.min(3, ui.warning_choice + 1) end
    if pad_pressed.a then taken = ui.warning_choice end
    if pad_pressed.b then taken = 3 end
    if not ui.editing then
        if keys_pressed.left then ui.warning_choice = math.max(1, ui.warning_choice - 1) end
        if keys_pressed.right then ui.warning_choice = math.min(3, ui.warning_choice + 1) end
        if keys_pressed.enter or keys_pressed.space then taken = ui.warning_choice end
    end
    local x, py = ax + 30 * k, by + 16 * k
    x += prompt(x, py, "dpad_lr", "< >", "Choose")
    x += prompt(x, py, "a", "ENTER", "Select")
    prompt(x, py, "b", "ESC", "Stay")
    if taken then
        ui.warning_choice = 1
        studio.confirm_close = false
        if taken == 1 then
            save_now()
            begin_leave()
        elseif taken == 2 then
            studio.dirty = false
            begin_leave()
        end
    end
end

-- ---- the loading screen and the recording strip --------------------------------------------------------
local tips = {
    "Pick a trick in TRICKS, then its pop: low, mid or high.",
    "Click a dot on the skater, or choose a joint in JOINTS, then drag to turn it.",
    "K keys the pose on this frame. Keys always sit on whole frames.",
    "G moves the hips or the board. X, Y and Z lock an axis.",
    "Save your trick and do it in game: your version plays on that trick.",
    "Copy to low, mid and high pop in PLAYBACK to fit every pop.",
    "On a controller: the left stick turns, RT and LT step frames, A keys.",
}
-- Over the studio opening and closing: dark grainy concrete, the reskate. wordmark with animator
-- studio on a strip of blue tape, who built it on a paper strip, a tip with a bar, and skate.'s own
-- "Loading..." box with its kickflipping board.
local function draw_loading(dx, dy, t)
    if not loading then return end
    local seconds = t - loading.since
    local alpha = clamp(math.min(seconds / 0.15, (loading.until_ + 0.3 - t) / 0.3), 0, 1)
    if alpha <= 0 then return end
    local H = dy
    local k = clamp(H / 1080, 0.45, 3)
    local function fade(c) return with_alpha(c, alpha) end
    local paper, ink = rgba(236, 233, 226), rgba(17, 18, 21)
    fill(0, 0, dx, dy, fade(rgba(19, 19, 19)))
    D:game_image("scratches", vector.create(0, 0, 0), vector.create(dx, dy, 0), {colour = fade(rgba(255, 255, 255, 150)), fit = "panel", edge = 0})
    local clear, dark = rgba(0, 0, 0, 0), fade(rgba(0, 0, 0, 170))
    D:gradient(vector.create(0, 0, 0), vector.create(dx, H * 0.25, 0), {dark, dark, clear, clear})
    D:gradient(vector.create(0, H * 0.75, 0), vector.create(dx, dy, 0), {clear, clear, dark, dark})
    D:gradient(vector.create(0, 0, 0), vector.create(dx * 0.15, H, 0), {dark, clear, clear, dark})
    D:gradient(vector.create(dx * 0.85, 0, 0), vector.create(dx, dy, 0), {clear, dark, dark, clear})
    local word_size = 0.30 * H
    local ww = text_size("title_large", word_size, "reskate.")
    local wx, wy = dx * 0.5 - ww.x * 0.5, H * 0.215
    text("title_large", word_size, wx + 5 * k, wy + 7 * k, fade(rgba(0, 0, 0, 140)), "reskate.")
    text("title_large", word_size, wx, wy, fade(paper), "reskate.")
    D:game_image("scratches", vector.create(wx - 20 * k, wy, 0), vector.create(wx + ww.x + 20 * k, wy + word_size * 1.1, 0),
        {colour = fade(rgba(30, 28, 25, 230)), fit = "panel", edge = 0})
    local sub_size = 0.085 * H
    local sw = text_size("title_large", sub_size, "animator studio")
    local tape_top, tape_h = wy + word_size * 0.99, 0.098 * H
    D:game_image("brush_bar", vector.create(dx * 0.5 - sw.x * 0.5 - 0.03 * H, tape_top, 0), vector.create(dx * 0.5 + sw.x * 0.5 + 0.03 * H, tape_top + tape_h, 0),
        {colour = fade(blue), fit = "shape"})
    text("title_large", sub_size, dx * 0.5, tape_top + (tape_h - sw.y) * 0.5 - 0.004 * H, fade(ink), "animator studio", "centre")
    do
        local label_size, names_size = 0.020 * H, 0.026 * H
        local names = "22SH, FOURTH STUDIO, NORMS"
        local lw, nw = text_size("bold", label_size, "BUILT BY"), text_size("heading", names_size, names)
        local strip_w, strip_h = lw.x + nw.x + 0.06 * H, 0.06 * H
        local px, py = dx * 0.5 - strip_w * 0.5, tape_top + tape_h + 0.03 * H
        D:game_image("rough_tile", vector.create(px, py, 0), vector.create(px + strip_w, py + strip_h, 0), {colour = fade(paper), fit = "panel", edge = 6})
        text("bold", label_size, px + 0.022 * H, py + (strip_h - lw.y) * 0.5, fade(rgba(40, 40, 44)), "BUILT BY")
        text("heading", names_size, px + 0.038 * H + lw.x, py + (strip_h - nw.y) * 0.5, fade(ink), names)
    end
    do
        local tip = tips[math.floor(seconds / 4) % #tips + 1]
        local tx, ty = 0.034 * dx, H - 0.115 * H
        text("heading", 0.022 * H, tx, ty, fade(blue), "TIP")
        text("bold", 0.019 * H, tx, ty + 0.03 * H, fade(rgba(225, 225, 228)), tip)
        local bax, bay, bbx, bby = tx, H - 0.05 * H, dx * 0.415, H - 0.04 * H
        local r = (bby - bay) * 0.5
        fill(bax, bay, bbx, bby, fade(rgba(255, 255, 255, 38)), r)
        local f = if t >= loading.until_ then 1 else 0.92 * (1 - math.exp(-seconds / 3))
        if f > 0.01 then fill(bax, bay, bax + (bbx - bax) * f, bby, fade(blue), r) end
    end
    do
        local what = if loading.what == "leaving" then "BACK TO THE STREETS" else "SETTING UP THE STUDIO"
        local box_h, box_w = 0.062 * H, 0.205 * H
        local bbx, bby = dx - 0.034 * dx, H - 0.045 * H
        local bax, bay = bbx - box_w, bby - box_h
        local rim = 2.5 * k
        D:game_image("rough_tile", vector.create(bax, bay, 0), vector.create(bbx, bby, 0), {colour = fade(rgba(205, 205, 205)), fit = "panel", edge = 8})
        D:game_image("rough_tile", vector.create(bax + rim, bay + rim, 0), vector.create(bbx - rim, bby - rim, 0), {colour = fade(rgba(8, 8, 9)), fit = "panel", edge = 8})
        local dots = {"Loading", "Loading.", "Loading..", "Loading..."}
        local lw = text_size("bold", 0.021 * H, "Loading...")
        text("bold", 0.021 * H, bax + 0.024 * H, bay + (box_h - lw.y) * 0.5, fade(white), dots[math.floor(seconds * 2.5) % 4 + 1])
        D:game_image("loading_board", vector.create(bbx - box_h * 1.25 - 0.012 * H, bay + box_h * 0.1, 0), vector.create(bbx - 0.012 * H, bby - box_h * 0.1, 0),
            {colour = fade(white), frame = math.floor(seconds * 30) % 27})
        local ww2 = text_size("heading", 0.021 * H, what)
        text("heading", 0.021 * H, bax - 0.022 * H - ww2.x, bay + (box_h - ww2.y) * 0.5, fade(white), what)
    end
end
-- While a trick is being recorded (the studio steps out so you can skate): a strip across the top, and
-- Esc (Back on a controller) goes back to the studio without one.
local function draw_recording(dx, dy, t)
    local H = dy
    fill(0, 0, dx, 0.085 * H, rgba(12, 12, 13, 225))
    fill(0, 0.085 * H - 0.004 * H, dx, 0.085 * H, blue)
    local what = if recording.air then "IN THE AIR..." else "RECORD A TRICK"
    text("heading", 0.026 * H, 0.034 * dx, 0.014 * H, white, what)
    text("bold", 0.019 * H, 0.034 * dx, 0.048 * H, rgba(200, 200, 204), recording.status or "Skate and land the trick you want.")
    local hint = "ESC / BACK: BACK TO THE STUDIO"
    local hw = text_size("heading", 0.019 * H, hint)
    text("heading", 0.019 * H, dx - 0.034 * dx - hw.x, 0.03 * H, white, hint)
    local pulse = 0.6 + 0.4 * math.sin(t * 5)
    circle(dx - 0.034 * dx - hw.x - 0.022 * H, 0.03 * H + hw.y * 0.5, 0.008 * H, rgba(235, 50, 50, math.floor(255 * pulse)), true)
end

-- ---- the frame -------------------------------------------------------------------------------------------
local last_frame = nil
reskate.on("draw", function(d)
    D = d
    measured = {}
    local size = d:size()
    local dx, dy = size.x, size.y
    S = dy / 1080
    local t = now()
    local dt = if last_frame then math.min(t - last_frame, 0.1) else 0
    last_frame = t
    if recording then
        draw_recording(dx, dy, t)
        return
    end
    if not studio.open then
        if loading then draw_loading(dx, dy, t) end
        return
    end
    hovered_this = false
    read_mouse(t)
    read_keys(t)
    local pad = read_pad(t)
    -- A field being typed into takes what was typed (and its keys) first.
    if ui.editing then
        edit_keys(reskate.input.text(true))
        if ui.editing then ui.editing.seen = false end
    end
    -- Laid out on a 1920 x 1080 page, scaled to fit the height and the game's menu frame (the whole width
    -- up to 21:9, a 21:9 frame in the middle of anything wider).
    local frame_w = math.min(dx, dy * 21 / 9)
    local left = (dx - frame_w) * 0.5
    local right = left + frame_w
    K = clamp(math.min(dy / 1080, frame_w / 1700), 0.45, 3)
    local k = K
    local timeline_h = math.min(dy * 0.34, 360 * k)
    local menu_x, menu_w = left + 60 * k, 520 * k
    local vx0 = if ui.menu_hidden then left else menu_x + menu_w + 30 * k
    local vy0, vx1, vy1 = 0, right, dy - timeline_h
    view_shift = {((vx0 + vx1) * 0.5 - dx * 0.5) / dy, (dy * 0.5 - (vy0 + vy1) * 0.5) / dy}
    if loading and t < loading.until_ then
        draw_loading(dx, dy, t)
        return
    end
    if not studio.confirm_close then controller(pad, t, dt) end
    viewport(vx0, vy0, vx1, vy1, t)
    if not ui.menu_hidden then
        page_title(menu_x, 40 * k)
        tab_row(menu_x, 140 * k)
        local list_top, card_h = 205 * k, 190 * k
        local list_bottom = dy - timeline_h - card_h - 40 * k
        list(menu_x + 16 * k, list_top, menu_w - 16 * k, math.max(120 * k, list_bottom - list_top))
        card(menu_x, list_bottom + 18 * k, menu_w + 10 * k, card_h)
    end
    timeline(left, dy - timeline_h, frame_w, timeline_h)
    local status = if studio.failure ~= "" then studio.failure else studio.status
    if t < ui.message_until then status = ui.message end
    if not anim.source then
        local first, second = "PICK A TRICK", "Choose a trick in TRICKS: it opens here to be changed."
        local w1 = text_size("heading", 30 * k, first)
        local bw = math.max(w1.x + 60 * k, 520 * k)
        local ax, ay = left + (frame_w - bw) * 0.5, dy - timeline_h * 0.5 - 30 * k
        rough(ax, ay, ax + bw, ay + 120 * k, rgba(234, 234, 232, 250), 101, k)
        text("heading", 30 * k, ax + bw * 0.5, ay + 16 * k, rgba(20, 20, 22), first, "centre")
        text("bold", 17 * k, ax + 30 * k, ay + 60 * k, rgba(60, 60, 66), second, nil, bw - 60 * k)
    end
    if status ~= "" then
        local w = text_size("bold", 15 * k, status)
        local ax, ay = vx0 + 24 * k, vy1 - 40 * k
        rough(ax - 14 * k, ay - 7 * k, ax + w.x + 14 * k, ay + w.y + 7 * k, rgba(16, 16, 18, 230), 41, k * 0.6)
        text("bold", 15 * k, ax, ay, if studio.failure ~= "" and t >= ui.message_until then danger else white, status)
    end
    prompts(vx1, vy1)
    if studio.confirm_close then close_warning(dx, dy, t) else keyboard() end
    -- A field no longer drawn (another tab, the menu hidden) keeps what was typed into it.
    if ui.editing and not ui.editing.seen then edit_stop(true) end
    if loading then draw_loading(dx, dy, t) end -- fading out
    ui.hovered_any = hovered_this
end)

-- ---- every tick: the camera, the preview, a recording -----------------------------------------------------
reskate.on("tick", function()
    local t = now()
    if stale_recording then
        local clip = reskate.animation.recorded()
        if clip then
            reskate.animation.forget(clip)
            stale_recording = false
        end
    end
    if recording then
        local trick = reskate.animation.trick()
        if trick then
            recording.air = true
            if not recording.trick then recording.trick = trick end
        end
        local pad = reskate.input.gamepad()
        if (reskate.input.key(0x1B) and reskate.input.focus()) or (pad and pad.buttons.back) then
            cancel_recording()
            open_studio()
            return
        end
        local clip = reskate.animation.recorded()
        if clip then recording_done(clip) end
        return
    end
    -- The walk to the room: the loading screen stays up while it goes on, then 3 s more while the board
    -- settles there; if it fails, the studio opens where the skater is.
    if room_walk then
        local state, why = reskate.room.state()
        if state == "open" then
            room_walk, in_room = false, true
            -- A quarter second on: the joints read then are the room's, not where he stood.
            eased, face_skater = nil, now() + 0.25
            reskate.hud.hide(true)
            if loading then loading.until_ = t + 3.8 end
        elseif state == "failed" or state == "idle" then
            room_walk = false
            reskate.hud.hide(true)
            studio.status = (why or "The character room did not open.") .. " The studio opens where you are."
            if loading then loading.until_ = t + 0.3 end
        elseif loading then
            loading.until_ = math.max(loading.until_, t + 0.5)
        end
    end
    -- The room gone from under the studio (Esc closed the game's menu, or it went to another page): the
    -- skater is back where he is, and the studio closes with the room.
    if in_room and not room_walk and not loading then
        local state, why = reskate.room.state()
        if state ~= "open" then
            reskate.ui.toast((why or "The character room closed.") .. " The studio closed with it.", "warn")
            finish_close()
            return
        end
    end
    if loading and loading.close and t >= loading.until_ then
        if reskate.room.state() == "leaving" then
            loading.until_ = t + 0.3 -- still walking back
        else
            loading = nil
            finish_close()
            return
        end
    end
    if loading and t >= loading.until_ + 0.3 then loading = nil end
    if not studio.open then return end
    update_camera()
    if studio.playing then
        local at = reskate.animation.time()
        if at then studio.time = at end
    end
    if preview_due and reskate.time.now() - last_bake > 350 then bake() end
    show_pending()
end)

reskate.on("screen_closed", function(screen)
    if screen ~= title or not studio.open then return end
    -- Esc: lets go of chosen keys first, asks first with unsaved changes, and the close card's Esc stays.
    if ui.editing then
        edit_stop(false)
        reskate.ui.open(title)
        return
    end
    if #ui.picked > 0 then
        ui.picked = {}
        reskate.ui.open(title)
        return
    end
    if studio.confirm_close then
        studio.confirm_close = false
        reskate.ui.open(title)
        return
    end
    if studio.dirty and anim.source then
        studio.confirm_close = true
        reskate.ui.open(title)
        return
    end
    finish_close()
end)

-- ---- at start: what plays in game, how to open it ----------------------------------------------------------
local in_game = apply_in_game()
if in_game > 0 then reskate.log(string.format("%d saved animation(s) play in game", in_game)) end

reskate.ui.screen(title, function() end, {panel = false})
reskate.input.bind("studio", "F8")
reskate.input.bind("studio pad", "Pad.L3+Pad.R3")
reskate.on("action", function(name)
    if name ~= "studio" and name ~= "studio pad" then return end
    if studio.open then
        request_close()
        return
    end
    open_studio()
    if name == "studio pad" then
        ui.pad_mode = true
        ui.combo_armed = false
        ui.l3_combo = true
    end
end)
-- ---- its own checks (studio test): the editing, the key maths against the baked clip, every screen ---------
local test_frames = nil -- the screens still to draw: {tab, pad_mode, confirm_close, menu_hidden}
local function self_test()
    local passed, failed = 0, 0
    local function check(ok, what)
        if ok then passed += 1 else
            failed += 1
            reskate.console.print("studio test: FAIL " .. what)
        end
    end
    if not anim.source then
        reskate.console.print("studio test: record a trick first (studio record)")
        return
    end
    -- What is being edited stays as it is: its keys, names and clip are put back after.
    local tracks, name, trick, pop, source, source_info = copy_tracks(anim.tracks), anim.name, anim.trick, anim.pop, anim.source, info
    anim.tracks, undo_stack, redo_stack = {}, {}, {}
    ui.selected = 7
    set_time(0.21)
    key_joint()
    check(#track_of(7, false).keys == 1, "K keys the joint on this frame")
    check(math.abs(track_of(7, false).keys[1].t - 0.2) < 1e-6, "on a whole frame")
    camera = camera or {right = vector.create(-1, 0, 0), up = vector.create(0, 1, 0)}
    check(begin_turn(), "a turn begins on the hips")
    apply_turn(30, 0, false)
    local r = track_of(7, false).keys[1].r
    check(math.abs(r[4]) < 0.9999, "a drag turns it")
    ui.axis = 1
    apply_turn(20, 0, false)
    check(math.abs(to_euler(track_of(7, false).keys[1].r)[2]) > 1, "about Y with the axis locked")
    ui.axis = -1
    apply_turn(10, 10, true)
    local o = track_of(7, false).keys[1].o
    check(math.abs(o[1]) + math.abs(o[2]) + math.abs(o[3]) > 1e-4, "G moves the hips")
    set_time(0.5)
    key_joint()
    step_frame(-3)
    check(math.abs(studio.time - 0.4) < 1e-4, "frames step")
    jump_key(-1)
    check(math.abs(studio.time - 0.2) < 1e-4, "to the previous key")
    jump_key(1)
    check(math.abs(studio.time - 0.5) < 1e-4, "and the next")
    pick_all()
    check(#ui.picked == 2, "every key chosen")
    move_picked(-1 / fps)
    check(math.abs(track_of(7, false).keys[1].t - (0.2 - 1 / fps)) < 1e-4 and math.abs(track_of(7, false).keys[2].t - (0.5 - 1 / fps)) < 1e-4,
        "the chosen keys move together")
    delete_picked()
    check(#track_of(7, false).keys == 0, "and are taken off")
    undo()
    check(#track_of(7, false).keys == 2, "undo brings them back")
    redo()
    check(#track_of(7, false).keys == 0, "redo takes them off again")
    undo()
    -- The sliders' maths is the baked clip's: the hips between two keys, at the clip's own frames (between
    -- them the clip blends its frames).
    anim.tracks = {}
    set_time(0)
    set_offset(7, from_euler({0, 0, 0}), {0, 0, 0})
    set_time(0.5)
    set_offset(7, from_euler({20, 60, -30}), {0, 0.3, 0})
    local baked_ok, clip = pcall(reskate.animation.edit, anim.source, edit_tracks(anim.tracks), {name = "test"})
    check(baked_ok, "the keys bake: " .. tostring(clip))
    if baked_ok then
        -- A recording has a frame every 60th of a second or so: anywhere is near one. A short clip, only its own.
        for _, at in (if info.frames > 10 then {0.1, 0.25, 0.4} else {0.25}) do
            studio.time = at
            local lr, lo = evaluate(track_of(7, false), at)
            local base = reskate.animation.sample(anim.source, 7, at)
            local native = reskate.animation.sample(clip, 7, at)
            local want = qnorm(qmul(base.rotation, lr))
            local dot = math.abs(want[1] * native.rotation[1] + want[2] * native.rotation[2] + want[3] * native.rotation[3] + want[4] * native.rotation[4])
            check(dot > 0.9999, string.format("the turn at %.2f s is the baked clip's", at))
            check(math.abs(native.position.y - base.position.y - lo[2]) < 1e-3, string.format("so is the move at %.2f s", at))
        end
        reskate.animation.forget(clip)
    end
    set_time(0.25)
    copy_pose()
    set_time(0)
    paste_pose()
    check(#track_of(7, false).keys == 2, "a pose pasted keys its joints")
    ui.tab = 4
    set_time(0.5)
    for _, row in rows_of(4) do
        if row.label == "Blend into the next key" then row.act() end
    end
    check(key_here(7).e == "linear", "the ease steps on")
    set_track_flags(7, true, true)
    check(#edit_tracks(anim.tracks) == 0, "a hidden joint's keys are left out")
    set_offset(7, {0, 0, 0, 1}, {0, 0, 0})
    check(#track_of(7, false).keys == 2, "a locked joint keeps its keys")
    set_track_flags(7, false, false)
    anim.trick = "kickflip"
    check(save("Studio Test") == "Saved Studio Test.", "it saves")
    anim.tracks = {}
    anim.source = nil -- opening another must not let the edited clip go
    check(load("Studio Test") == "Opened Studio Test.", "and opens again")
    check(#track_of(7, false).keys == 2, "with its keys")
    check(copy_to_pops() == "Saved a low, a mid and a high pop copy.", "a copy for each pop")
    for _, file in {"Studio Test", "Studio Test low", "Studio Test mid", "Studio Test high"} do remove(file) end
    library_at = -1e9
    check(not table.find(library(), "Studio Test"), "taken out of the library")
    anim.tracks, anim.name, anim.trick, anim.pop, anim.source, info = tracks, name, trick, pop, source, source_info
    baked, baked_clip = {}, nil
    undo_stack, redo_stack, ui.picked = {}, {}, {}
    changed_all()
    -- Typing into a field: all of it chosen at first, then a caret that moves, a length it stops at,
    -- characters of more than a byte, Enter keeping it and Esc not.
    do
        local kept = nil
        local function press(name, value)
            keys_repeat[name], keys_pressed[name] = value, value
        end
        edit_start("test", "Kick", 6, function(v) kept = v end)
        check(ui.editing.all, "a field starts with all of it chosen")
        edit_keys("Heel")
        check(ui.editing.text == "Heel" and ui.editing.caret == 4, "what is typed replaces it")
        press("backspace", true)
        edit_keys("")
        press("backspace", false)
        check(ui.editing.text == "Hee", "Backspace takes one off")
        press("left", true)
        edit_keys("")
        press("left", false)
        edit_keys("l")
        check(ui.editing.text == "Hele" and ui.editing.caret == 3, "the caret moves and typing goes in at it")
        edit_keys("\u{e9}xyz")
        check(ui.editing.text == "Hel\u{e9}xe" and length_of(ui.editing.text) == 6, "up to its length, a two-byte letter as one")
        press("enter", true)
        edit_keys("")
        press("enter", false)
        check(kept == "Hel\u{e9}xe" and ui.editing == nil, "Enter keeps it")
        edit_start("test", "Kick", 6, function(v) kept = v end)
        edit_keys("Grab")
        press("escape", true)
        edit_keys("")
        press("escape", false)
        check(kept == "Hel\u{e9}xe" and ui.editing == nil, "Esc does not")
    end
    -- Every screen drawn: each tab with the keyboard's prompts and the pad's, the menu hidden, the close card.
    test_frames = {}
    for tab = 1, 5 do
        table.insert(test_frames, {tab, false, false, false})
        table.insert(test_frames, {tab, true, false, false})
    end
    table.insert(test_frames, {3, false, false, true})
    table.insert(test_frames, {4, false, true, false})
    reskate.console.print(string.format("studio test: %d passed, %d failed", passed, failed))
end
reskate.on("draw", function()
    if not test_frames or not studio.open then return end
    if loading and now() < loading.until_ then return end
    local f = table.remove(test_frames, 1)
    if not f then
        test_frames = nil
        ui.tab, ui.pad_mode, studio.confirm_close, ui.menu_hidden = 1, false, false, false
        reskate.console.print("studio test: every screen drawn")
        return
    end
    ui.tab, ui.pad_mode, studio.confirm_close, ui.menu_hidden = f[1], f[2], f[3], f[4]
    ui.selected = if f[1] == 3 then "board" else 7
end)

reskate.console.command("studio", "Animator Studio: open, close, record, save <name>, ingame on|off, list, status, test", function(args)
    local word = args[1] or "open"
    if word == "test" then
        local ok, why = pcall(self_test)
        if not ok then reskate.console.print("studio test: FAIL " .. tostring(why)) end
    elseif word == "open" then open_studio()
    elseif word == "close" then finish_close()
    elseif word == "record" then record_next_trick()
    elseif word == "save" then
        local name = table.concat(args, " ", 2)
        reskate.console.print("studio: " .. save(if name ~= "" then name else nil))
    elseif word == "ingame" then
        settings.in_game = args[2] == "on"
        save_settings()
        apply_in_game()
        reskate.console.print("studio: custom tricks in game " .. (if settings.in_game then "on" else "off"))
    elseif word == "list" then reskate.console.print("studio: " .. table.concat(library(), ", "))
    elseif word == "status" then
        reskate.console.print(string.format("studio: %s; %s; %d saved; %d game tricks", if studio.open then "open" else "closed",
            if anim.source then (if anim.trick ~= "" then anim.trick else "a trick") .. string.format(", %.2f s", info.duration) else "nothing recorded",
            #library(), #catalog()))
    else reskate.console.print("studio: say open, close, record, save <name>, ingame on|off, list or status") end
end)
reskate.menu.page(title, function(page)
    page:card("ANIMATOR STUDIO", "Change the game's trick animations")
    page:note("F8 (or L3 + R3) opens the studio. Record a trick, key the joints on the timeline, save it, and doing that trick plays your version.")
    if page:button("open", "Open the studio", true) then open_studio() end
    page:info("Saved", tostring(#library()))
    page:info("Game tricks", if #catalog() > 0 then tostring(#catalog()) .. " from the game's data" else "none yet: " .. game_tricks_why)
end)
reskate.on("unload", function() if studio.open then finish_close() end end)
