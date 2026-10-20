-- game_modes.cpp lines 1879-2347, line for line: the game (record_result, run_leader,
-- run_player) and R.E.S.K.A.T.E.'s turn (trick_kinds_text, skate_trick, skate_rolling,
-- skate_return_spot, run_skate).
local M = require("td/core")
local ML = require("td/h/mode_lobby")

-- File-local helpers (the C++ had them as std library calls or lambdas).

-- std::map / std::set keyed by a 64-bit id iterate in numeric order: decimal id strings (no
-- leading zeros) compare by length, then text.
local function id_less(a: string, b: string): boolean
    if #a ~= #b then return #a < #b end
    return a < b
end

-- A table's size, for std::map::size() / std::set::size().
local function count(t): number
    local n = 0
    for _ in t do n += 1 end
    return n
end

-- `std::format("{:x}", entry)`: a trick list entry (a decimal string) in hex.
local function hex(entry: string): string
    return string.format("%x", tonumber(entry) or 0)
end

-- `entry >> 32`: the item number of a trick list entry.
-- PORT: entries are 64-bit; this is exact while they stay below 2^53 (they are small counters).
local function high32(entry: string): number
    return math.floor((tonumber(entry) or 0) / 4294967296)
end

-- `trainer::telemetry()`: a default-constructed one (physics state 0, not airborne) when there is none.
local function telemetry()
    return M.telemetry() -- skater.lua: keeps the Bone Cam's slam for track_bail
end
local function physics_state_of(tel): number
    return tel.physics_state or 0
end

local function lower_ascii(name: string): string
    return string.lower(name)
end

local function hypot(x: number, y: number): number
    return math.sqrt(x * x + y * y)
end

-- ---- the game ------------------------------------------------------------------------
-- A game's final standings onto the lobby leaderboard, once per game, from whichever copy of its
-- state arrives first; a solo game counts for nothing. A new leader is called out in chat.
function M.record_result(s, leader: string, game: number, mode: string, m)
    if m.phase ~= "results" or #m.standings < 2 then return end
    local key = M.pair_key(leader, game)
    if s.lobby_counted[key] then return end
    s.lobby_counted[key] = true
    if mode == "race" and m.standings[1].out then return end
    for i = 0, #m.standings - 1 do
        local player = m.standings[i + 1].player
        local e = s.lobby[player]
        if e == nil then
            e = {name = "", points = 0, wins = 0, podiums = 0, games = 0, streak = 0, best_streak = 0, mode_wins = {}}
            s.lobby[player] = e
        end
        e.name = M.name_of(s, player)
        e.games += 1
        if i == 0 then
            e.wins += 1
            e.mode_wins[mode] = (e.mode_wins[mode] or 0) + 1
            e.streak += 1
            e.best_streak = math.max(e.best_streak, e.streak)
        else
            e.streak = 0
        end
        if i < 3 and (mode ~= "race" or not m.standings[i + 1].out) then
            e.podiums += 1
            e.points += 3 - i
        end
    end
    s.lobby_played[mode] = (s.lobby_played[mode] or 0) + 1
    table.insert(s.lobby_recent, 1, {
        mode = mode,
        winner = M.name_of(s, m.standings[1].player),
        second = M.name_of(s, m.standings[2].player),
        players = #m.standings,
        at = M.now_ms(),
    })
    if #s.lobby_recent > 6 then table.remove(s.lobby_recent) end
    -- std::max_element over the map (ids in order): the first of the highest (points, wins).
    local ids = {}
    for id in s.lobby do table.insert(ids, id) end
    table.sort(ids, id_less)
    local top = nil
    for _, id in ids do
        if top == nil then
            top = id
        else
            local a, b = s.lobby[top], s.lobby[id]
            if a.points < b.points or (a.points == b.points and a.wins < b.wins) then top = id end
        end
    end
    if top ~= nil and top ~= s.lobby_leader then
        s.lobby_leader = top
    end
end

function M.run_leader(s, g, now: number)
    if not g.referee then
        -- Setting up: players who left are dropped from the ones who answered.
        if s.session then
            local kept = {}
            for _, id in g.joiners do
                if s.present[id] then table.insert(kept, id) end
            end
            g.joiners = kept
        end
        if now - g.setup_sent >= M.setup_every_ms then
            local m = M.header(g, "setup")
            m.settings = ML.advertised_lobby_settings(g.settings, s.placing ~= "none" or
                (g.native_lobby and not g.native_flag_placed) or not M.race_lobby_open(s, g))
            M.send(s, m)
            g.setup_sent = now
        end
        g.state = M.setup_state(s, g)
        if now - g.state_sent >= M.state_every_ms then
            M.send(s, g.state)
            g.state_sent = now
        end
        return
    end
    local r = g.referee
    r:name(M.self_id(s), M.name_of(s, M.self_id(s)))
    if g.state then
        for _, p in g.state.standings do
            if p.player == M.self_id(s) then continue end
            r:name(p.player, M.name_of(s, p.player))
            if s.session and not s.present[p.player] then r:remove(p.player, now) end
        end
    end
    local changed = r:tick(now)
    local _ = r:calls() -- everyone reads them from the state, the leader too
    if r:finished(now) then
        M.send(s, M.header(g, "end"))
        M.end_game(s, M.mode_name(g.settings.mode) .. " is over.")
        return
    end
    if now - g.setup_sent >= M.setup_every_ms then
        local m = M.header(g, "setup")
        m.settings = g.settings
        M.send(s, m)
        g.setup_sent = now
    end
    -- Graffiti: new tag shapes go out at once, and all of them again every few seconds.
    local tags = {}
    for _, t in r:tags() do table.insert(tags, M.tag_from(t)) end
    g.tags = tags
    if #g.tags > g.tags_sent or (#g.tags ~= 0 and now - g.tags_resent >= M.setup_every_ms) then
        local all = now - g.tags_resent >= M.setup_every_ms
        local first = if all then 0 else g.tags_sent
        while first < #g.tags do
            local m = M.header(g, "tags")
            m.first = first
            local part = {}
            for i = first + 1, math.min(first + 12, #g.tags) do table.insert(part, g.tags[i]) end
            m.tags = part
            M.send(s, m)
            first += 12
        end
        if all then g.tags_resent = now end
        g.tags_sent = #g.tags
    end
    g.state = M.message_from(r:state(now))
    g.state.kind = "state"
    g.state_sampled_ms = now
    M.record_result(s, g.leader, g.id, g.settings.mode, g.state)
    M.announce_match(s, g.leader, g.id, g.settings, g.state, now)
    if changed or now - g.state_sent >= M.state_every_ms then
        M.send(s, g.state)
        g.state_sent = now
    end
end

function M.run_player(s, g, now: number)
    if now - g.heard > M.leader_timeout_ms or (s.session and not s.present[g.leader]) then
        M.end_game(s, M.name_of(s, g.leader) .. "'s game ended: they are gone.")
        return
    end
    -- Answer the setup until the leader lists us; a game already under way is watched.
    local before_start = not g.state or g.state.phase == "setup" or g.state.phase == "countdown"
    if not M.standing(g, M.self_id(s)) and before_start and not s.barred and now - g.join_sent >= M.join_every_ms then
        M.send(s, M.header(g, "join"))
        g.join_sent = now
    end
end

-- R.E.S.K.A.T.E.: the local player's turn. skate.'s trick list is read from the moment it is theirs:
-- each trick's name (with its FS / BS side) joins the attempt until the line lands, which sends it,
-- or a bail, which misses it. skate. does not list a landing for every trick (plants, some grabs and
-- grinds end without one, or list it before the name), so rolling away on the board for a moment
-- after a named trick lands it too, and stepping off the board misses it. One attempt per turn: the
-- next turn (a new call from the referee) starts over. Whoever is up is watched with the party
-- Spectate camera, when the player wants that.
function M.trick_kinds_text(kinds: number): string
    if kinds == M.all_trick_kinds then return "any trick" end
    local text = ""
    for _, pair in {{M.trick_flips, "flip tricks"}, {M.trick_grabs, "grabs"},
                    {M.trick_grinds, "grinds & slides"}, {M.trick_manuals, "manuals"}} do
        if bit32.band(kinds, pair[1]) ~= 0 then text ..= (if text == "" then "" else ", ") .. pair[2] end
    end
    return text
end

-- t.parts is a list of {entry = string, name = string} (his pair<entry, name>).
function M.skate_trick(t): string
    -- skate. lists a nollie as its own entry, before or after the trick popped from it: it goes on
    -- the trick ("Nollie Kickflip"), so the same trick reads the same whatever the order.
    local parts = {}
    for _, part in t.parts do table.insert(parts, {entry = part.entry, name = part.name}) end
    local function is_nollie(part): boolean
        return part.name == "Nollie" or part.name == "nollie" or part.name == "NOLLIE"
    end
    local nollie = false
    if #parts > 1 then
        for _, part in parts do
            if is_nollie(part) then nollie = true break end
        end
    end
    if nollie then
        local kept = {}
        for _, part in parts do
            if not is_nollie(part) then table.insert(kept, part) end
        end
        parts = kept
    end
    -- A flip trick lists no ollie of its own ("Kickflip"): an ollie listed before one is its own pop,
    -- and the flip a late flip ("Late Kickflip"). Before a grind or a grab it is just the pop into it.
    local late = {}
    local i = 0
    while i + 1 < #parts do
        if parts[i + 1].name == "Ollie" and M.trick_kinds_of(parts[i + 2].name) == M.trick_flips then
            late[parts[i + 2].entry] = true
            table.remove(parts, i + 1)
        end
        i += 1
    end
    -- A trick and what it goes into count, in order: a flip into a grind or a grab is both
    -- ("Kickflip + BS Noseslide"), and a manual landed into joins it. A pop (Ollie,
    -- Boned Ollie) is only the way into the rest, so it counts only when nothing else was done.
    if #parts > 1 then
        local function pop(part): boolean
            return M.ends_with(lower_ascii(part.name), "ollie")
        end
        local any_other = false
        for _, part in parts do
            if not pop(part) then any_other = true break end
        end
        if any_other then
            local kept = {}
            for _, part in parts do
                if not pop(part) then table.insert(kept, part) end
            end
            parts = kept
        end
        if #parts > 1 then -- std::unique on the names: a run of the same name keeps its first
            local kept = {}
            for _, part in parts do
                if #kept == 0 or kept[#kept].name ~= part.name then table.insert(kept, part) end
            end
            parts = kept
        end
        -- Two tricks at most: the trick and what it went into (a manual, a grind or a grab). A flip
        -- out of it afterwards adds nothing ("Kickflip + Manual", not "+ Kickflip"; an ollie into
        -- a noseslide and a kickflip out is just "BS Noseslide").
        local into = nil
        for k, part in parts do
            local name = lower_ascii(part.name)
            if bit32.band(M.trick_kinds_of(part.name), bit32.bor(M.trick_grinds, M.trick_manuals, M.trick_grabs)) ~= 0
                or string.find(name, "manual", 1, true) ~= nil then
                into = k
                break
            end
        end
        if into ~= nil then
            while #parts > into do table.remove(parts) end
        end
        while #parts > 2 do table.remove(parts) end
    end
    local text = ""
    for k = 0, #parts - 1 do
        local entry, name = parts[k + 1].entry, parts[k + 1].name
        if text ~= "" then text ..= " + " end
        -- As skate.'s own trick list shows it: stance, the board's spin, the trick, then its side and the
        -- body's spin ("Fakie 360 Inward Heelflip FS 180"); a side without a body spin goes first ("BS Pop-Shuvit").
        -- A nollie listed as its own entry is the trick's stance, as the stance field gives it.
        local stance = t.stances[entry]
        if stance ~= nil then
            text ..= stance .. " "
        elseif k == 0 and nollie and not M.starts_with(name, "Nollie") then
            text ..= "Nollie "
        end
        local side = t.sides[entry]
        local body = t.body_spins[entry]
        if side ~= nil and body == nil then text ..= side .. " " end
        local spin = t.board_spins[entry]
        if spin ~= nil and string.find(name, spin, 1, true) == nil then
            text ..= spin .. " "
        end
        local mods = t.modifiers[entry]
        local function has(mod: string): boolean
            return mods ~= nil and mods[mod] == true
        end
        if (late[entry] or has("Late")) and not M.starts_with(name, "Late") then text ..= "Late " end
        if has("Darkflip") then text ..= "Darkflip " end
        if has("Dark Catch") then text ..= "Dark Catch " end
        text ..= name
        if body ~= nil then text ..= (if side ~= nil then " " .. side else "") .. " " .. body end
    end
    if #text > M.max_trick_length then text = string.sub(text, 1, M.max_trick_length) end
    return text
end

M.skate_return_ms, M.skate_return_give_up_ms, M.skate_return_retry_ms, M.land_hold_ms = 1200, 20000, 6000, 1000

-- On the ground, on the board or off it (standing, walking), not in the air or a bail: where skate.
-- accepts a teleport.
function M.skate_rolling(s): boolean
    local physics = physics_state_of(telemetry())
    return s.skater and not telemetry().airborne and
        ((physics >= 100 and physics < 200) or (physics >= M.offboard_states_first and physics < 600))
end

-- Where a return sends the local player: the start when it is their turn, else their own spot round
-- it (spread like the line-up), facing it, so nobody lands inside anybody. The start faces into the
-- zone, or away from the flag, never the flag's own angle (that turned players round).
-- Returns the spot (a vector) and the heading (degrees), his pair's first and second.
function M.skate_return_spot(s)
    local st = s.game.settings
    local at = M.skate_start(st)
    local ids = {}
    if s.game.state then
        for _, p in s.game.state.standings do table.insert(ids, p.player) end
    end
    table.sort(ids, id_less)
    local self = M.self_id(s)
    local index = table.find(ids, self)
    if #ids > 1 and s.game.state and s.game.state.turn ~= self and index ~= nil then
        local n = #ids
        local idx = index - 1
        local ring, angle = 3.0 + 0.6 * n, 6.2831853 * idx / n
        local spot = vector.create(at.x + math.cos(angle) * ring, at.y, at.z + math.sin(angle) * ring)
        return spot, M.heading_towards(spot, at)
    end
    local centre = if M.has_area(st) then M.area_centre(st.corners) else at
    local facing
    if hypot(centre.x - at.x, centre.z - at.z) > 2.0 then
        facing = M.heading_towards(at, centre)
    elseif st.has_spawn and hypot(st.spawn.x - at.x, st.spawn.z - at.z) > 2.0 then
        facing = M.heading_towards(st.spawn, at)
    else
        facing = s.heading
    end
    return at, facing
end

function M.run_skate(s, now: number)
    local t = s.skate
    if not s.stance_loaded then
        s.stance_loaded = true
        s.goofy = M.load_stance()
    end
    -- The game's own stance (Gameplay Preferences) once it is known; `mode stance` until then.
    local goofy = reskate.skater.goofy()
    if goofy ~= nil then s.goofy = goofy end
    local self = M.self_id(s)
    local st = if s.game and s.game.state then s.game.state else nil
    local me = if s.game then M.standing(s.game, self) else nil
    local is_in = st ~= nil and s.game.settings.mode == "skate" and st.phase == "playing" and me ~= nil and not me.out
    if s.game and s.game.settings.mode == "skate" then
        -- PORT: prepare_trick_gestures() has no API of its own; reskate.tricks.gesture starts the
        -- reading on its first call, so it is called with no trick (once, in the background).
        reskate.tricks.gesture("")
    end
    reskate.tricks.feed(is_in)
    local notes = M.take_trick_notes()
    -- The camera on whoever is up, not on the local player's own turn; players already out keep
    -- watching until the game ends.
    local watching = st ~= nil and s.game.settings.mode == "skate" and st.phase == "playing" and me ~= nil
    local watch = if watching and s.spectate and M.nz(st.turn) and st.turn ~= self and s.present[st.turn] then st.turn else "0"
    if M.nz(watch) or M.nz(t.spectating) then reskate.session.spectate(watch) end
    t.spectating = watch
    -- After each attempt (set, landed, missed or outside the zone) back to the start flag, a
    -- moment later so the landing is seen. Refused during a bail: tried again once it is over.
    if s.skate_return_at ~= 0 and (not is_in or not s.game.settings.has_spawn or now > s.skate_return_at + M.skate_return_give_up_ms) then
        s.skate_return_at = 0
        s.skate_return_sent = 0
    elseif s.skate_return_at ~= 0 and s.skate_return_sent ~= 0 and now >= s.skate_return_sent + 500 and
        hypot(s.position.x - (M.skate_return_spot(s)).x, s.position.z - (M.skate_return_spot(s)).z) < 2.0 then
        s.skate_return_at = 0 -- arrived
        s.skate_return_sent = 0
    elseif s.skate_return_at ~= 0 and now >= s.skate_return_at and (#t.parts == 0 or t.sent) and not s.bail.active and
        now >= s.skate_return_sent + M.skate_return_retry_ms and M.skate_rolling(s) then
        -- Only once on the ground, on the board or off it: skate.'s teleport is dropped while the
        -- skater is busy (getting up from a bail). Asked again until the player is there.
        local at, facing = M.skate_return_spot(s)
        if M.teleport_to(at, facing) then
            s.skate_return_sent = now
            t.since = now -- nothing before the move counts towards the next try
        end
    end
    local mine = is_in and st.turn == self
    if not mine then
        local spectating = t.spectating
        s.skate = M.SkateTurn()
        s.skate.spectating = spectating
        return
    end
    if not t.mine or t.key ~= st.call_serial then -- a new turn: nothing done before it counts
        M.skate_note(string.format("R.E.S.K.A.T.E.: your turn, %s (%d trick list note%s before it ignored).",
            if st.trick == "" then "setting" else "copying the " .. st.trick, #notes, if #notes == 1 then "" else "s"))
        t.mine = true
        t.key = st.call_serial
        -- Every turn starts at the start flag, setting or copying (unless already there or on the way).
        if s.skate_return_at == 0 and s.game.settings.has_spawn and
            hypot(s.position.x - M.skate_start(s.game.settings).x, s.position.z - M.skate_start(s.game.settings).z) > 3.0 then
            s.skate_return_at = now + 300
        end
        t.sent = false
        t.since = now
        t.parts = {}
        t.sides = {}
        t.body_spins = {}
        t.board_spins = {}
        t.stances = {}
        t.modifiers = {}
        t.last_name, t.settled_since, t.off_since, t.landed_at = 0, 0, 0, 0
        t.touched_down = false
        return
    end
    if t.sent then return end
    local function send_attempt(landed: boolean)
        local trick = M.skate_trick(t)
        -- Outside the trick zone nothing counts, a miss neither: the player tries again inside it.
        if not M.inside(s.game.settings, s.position) then
            M.skate_note(string.format("R.E.S.K.A.T.E.: attempt \"%s\" outside the zone, not counted.", trick))
            M.popup(s, "Landed outside the zone")
            t.parts = {}
            t.sides = {}
            t.body_spins = {}
            t.board_spins = {}
            t.stances = {}
            t.modifiers = {}
            t.last_name, t.settled_since, t.off_since, t.landed_at = 0, 0, 0, 0
            t.touched_down = false
            t.since = now -- a bail before this does not miss the next try
            s.skate_return_at = now + M.skate_return_ms
            return
        end
        M.skate_note(string.format("R.E.S.K.A.T.E.: attempt \"%s\" %s.", trick,
            if landed then "landed" else "missed (a bail, stepping off or a failed landing)"))
        M.report(s, "trick", if landed then 1 else 0, 0, s.position, {}, trick)
        -- Copying: "Trick copied" when it is the trick to copy. Setting: a miss failed to set it.
        local copying = st.trick ~= ""
        M.popup(s, if landed then (if copying and trick == st.trick then "Trick copied: " .. trick else "Landed: " .. trick)
            elseif not copying then "Failed to set trick" elseif trick == "" then "Missed" else "Missed: " .. trick)
        t.sent = true
        s.skate_return_at = now + M.skate_return_ms
    end
    local lower_text = lower_ascii
    -- Reverts count for nothing: a kickflip landed into a revert is a kickflip, and copies one landed without.
    local function revert(name: string): boolean
        return string.find(lower_text(name), "revert", 1, true) ~= nil
    end
    local function has_entry(entry: string): boolean
        for _, part in t.parts do
            if part.entry == entry then return true end
        end
        return false
    end

    -- Names and sides first: a landing listed in the same tick as its trick's name still lands it.
    local landing: boolean? = nil
    for _, note in notes do
        local kind = note.kind
        M.skate_note(string.format("R.E.S.K.A.T.E.: trick list %s \"%s\" (entry %s).",
            if kind == "n" then "name" elseif kind == "s" then "side" elseif kind == "b" then "body spin"
            elseif kind == "r" then "board spin" elseif kind == "k" then "stance" elseif kind == "m" then "modifier" else "landing",
            note.text, hex(note.entry)))
        if kind == "n" then
            -- Not tricks: reverts, a bail's "Slam", and the gaps and spots skate. lists in the
            -- same list by place ("Seawall - Plot 03 - ENT").
            -- Manuals and powerslides do not count in R.E.S.K.A.T.E.: one landed into a manual is
            -- the trick before it.
            -- Menu text written through the same field (the Skatepedia's "ID_SKATEPEDIA_CATEGORY_..."
            -- while it is open) is not a trick either.
            -- A trick skate. names only by its text key ("ID_TRICK_BSBONELESSBACKGRAB": a backside
            -- boneless back grab) is a trick all the same: it gets a readable name.
            local text = if M.starts_with(note.text, "ID_TRICK_") then M.readable_trick_key(note.text) else note.text
            -- Not tricks: what keeps rewriting one name on one entry, like the music player's song
            -- title ("Billie Jean", written several times a second). A trick's entry writes its name
            -- once or twice. Dropped from the attempt, and that entry ignored for the rest of the
            -- session (the music player writes every song title through the same one).
            local writer = hex(note.entry)
            if s.not_tricks[writer] then continue end
            local w = s.name_writes[note.entry]
            if w == nil then -- std::map::operator[]: a new entry, counted in the size below
                w = {text = "", first = 0, count = 0}
                s.name_writes[note.entry] = w
            end
            if w.text == text and now - w.first < 3000 then
                w.count += 1
                if w.count >= 4 then
                    if count(s.not_tricks) > 256 then s.not_tricks = {} end
                    s.not_tricks[writer] = true
                    local kept = {}
                    for _, part in t.parts do
                        if part.entry ~= note.entry then table.insert(kept, part) end
                    end
                    t.parts = kept
                    if #t.parts == 0 then
                        t.landed_at, t.settled_since = 0, 0
                        t.touched_down = false
                    end
                    M.skate_note(string.format("R.E.S.K.A.T.E.: \"%s\" keeps being rewritten (entry %s): not a trick.", text, hex(note.entry)))
                    continue
                end
            else
                -- PORT: his clear() destroys the entry `w` refers to before writing it (undefined
                -- behaviour); here the map is cleared and the new entry recorded in the fresh one.
                if count(s.name_writes) > 512 then s.name_writes = {} end
                s.name_writes[note.entry] = {text = text, first = now, count = 1}
            end
            if text == "Slam" or string.find(text, " - ", 1, true) ~= nil or M.starts_with(text, "ID_") or
                string.find(text, "  ", 1, true) ~= nil or M.starts_with(text, "SET A TRICK") or M.starts_with(text, "COPY") or
                M.starts_with(text, "LETTERS") or (#text >= 2 and string.sub(text, 2, 2) == ".") then
                continue
            end
            -- Moves that are no trick on their own (rolling off something, a powerslide, a revert, a
            -- manual): the player is told so if nothing real follows. After a trick a revert or a
            -- powerslide is just how it was ridden away, and adds nothing.
            local low = lower_text(text)
            local manual = string.find(low, "manual", 1, true) ~= nil
            if revert(text) or string.find(low, "powerslide", 1, true) ~= nil or string.find(low, "trickless", 1, true) ~= nil or
                (manual and #t.parts == 0) then
                if #t.parts == 0 then t.invalid_at = now end
                continue
            end
            if manual then -- landed into a manual: it joins the trick ("Kickflip + Manual"), one only
                local known = has_entry(note.entry)
                if known then
                    for _, part in t.parts do
                        if part.entry == note.entry then part.name = text end
                    end
                else
                    local none_manual = true
                    for _, part in t.parts do
                        if string.find(lower_text(part.name), "manual", 1, true) ~= nil then none_manual = false break end
                    end
                    if none_manual and #t.parts < 6 then
                        table.insert(t.parts, {entry = note.entry, name = text})
                    end
                end
                t.last_name = now
                continue
            end
            -- Not board tricks: jumps on foot or a hippy jump, and anything done off the board (vaults,
            -- climbs, dives, dynos, hangs, dismounts).
            do
                local lowered = lower_text(text)
                local off_board = false
                for _, word in M.off_board_words do
                    if string.find(lowered, word, 1, true) ~= nil then off_board = true break end
                end
                if off_board then continue end
            end
            do
                local physics = physics_state_of(telemetry())
                if physics >= M.offboard_states_first and physics < 600 then continue end
            end
            local known = has_entry(note.entry)
            if known then -- the entry renamed as the trick grows ("Kickflip" to "Double Kickflip")
                for _, part in t.parts do
                    if part.entry == note.entry and part.name ~= text then
                        part.name = text
                        t.last_name = now
                    end
                end
            else
                -- One trick per attempt: what is done before the board is back on the ground is
                -- that trick (a kickflip into a darkslide, a grind and its flip out, a flip and its
                -- grab). Once on the ground, nothing more joins: trick spam adds nothing. One plain
                -- pop stays, as an ollie makes a late flip and a nollie a nollie trick.
                local function pop(name: string): boolean return name == "Ollie" or name == "Nollie" end
                local have_pop = false
                for _, part in t.parts do
                    if pop(part.name) then have_pop = true break end
                end
                if t.touched_down or (pop(text) and have_pop) or #t.parts >= 6 then continue end
                table.insert(t.parts, {entry = note.entry, name = text})
                t.last_name = now
                t.invalid_at = 0 -- a real trick followed: nothing to tell
            end
        elseif kind == "s" then
            t.sides[note.entry] = if note.text == "ID_TRICK_FS" then "FS" elseif note.text == "ID_TRICK_BS" then "BS" else ""
            if t.sides[note.entry] == "" then t.sides[note.entry] = nil end
        elseif kind == "b" then
            t.body_spins[note.entry] = note.text
        elseif kind == "r" then
            t.board_spins[note.entry] = note.text
        elseif kind == "k" then -- "ID_STANCE_SWITCH" -> "Switch"
            -- PORT: his substr(10) throws on a text shorter than 10 characters; here it is empty
            -- (and so ignored).
            local stance = string.sub(note.text, 11)
            stance = string.sub(stance, 1, 1) .. lower_ascii(string.sub(stance, 2))
            if stance ~= "" and stance ~= "Regular" then t.stances[note.entry] = stance end
        elseif kind == "m" then
            local mods = t.modifiers[note.entry]
            if mods == nil then
                mods = {}
                t.modifiers[note.entry] = mods
            end
            mods[note.text] = true
        elseif #t.parts ~= 0 and landing ~= false and
            (has_entry(note.entry) or (high32(note.entry) ~= 0 and high32(note.entry) == high32(t.parts[1].entry))) then
            -- A landing lands the attempt only from its own line (the item number of its entries):
            -- an earlier line's landing listed late must not end it mid-air.
            landing = string.find(note.text, "BAIL", 1, true) == nil and string.find(note.text, "FAIL", 1, true) == nil
        end
    end
    -- A bail during the turn misses it.
    if s.bail.active and s.bail.started >= t.since then
        send_attempt(false)
        return
    end
    -- A move that is no trick on its own, with nothing real after it: said once, a moment later.
    if #t.parts == 0 and t.invalid_at ~= 0 and t.invalid_told ~= t.invalid_at and now - t.invalid_at >= 1200 then
        t.invalid_told = t.invalid_at
        M.popup(s, "Not a valid trick")
    end
    if #t.parts == 0 then return end
    -- A landing counts once it holds: a fall straight after skate. judged it landed (a bail caught
    -- above) misses it instead.
    if t.landed_at ~= 0 then
        -- Falling or stepping off before it holds misses it, whether or not a bail was seen yet.
        local held_state = physics_state_of(telemetry())
        if s.skater and ((held_state >= M.wipeout_state and held_state < M.wipeout_state + 100) or
            (held_state >= M.offboard_states_first and held_state < 600)) then
            send_attempt(false)
        elseif now - t.landed_at >= M.land_hold_ms then
            send_attempt(true)
        end
        return
    end
    if landing ~= nil then
        if landing then t.landed_at = now else send_attempt(false) end
        return
    end
    -- One trick per attempt: back on the board on the ground (rolling, or rolling away in a manual)
    -- a moment after the last named trick lands it, without waiting for skate. to end the whole
    -- line. Getting off the board instead (not a plant, which comes back to it) misses it.
    local physics = physics_state_of(telemetry())
    local grounded = s.skater and not telemetry().airborne and physics >= 100 and physics < 200
    local off = s.skater and physics >= M.offboard_states_first and physics < 600
    t.settled_since = if grounded then (if t.settled_since ~= 0 then t.settled_since else now) else 0
    if grounded and now - t.last_name >= 150 then t.touched_down = true end -- landed: the trick is complete
    t.off_since = if off then (if t.off_since ~= 0 then t.off_since else now) else 0
    if t.settled_since ~= 0 and now - t.settled_since >= M.settle_landed_ms and now - t.last_name >= M.settle_landed_ms then
        t.landed_at = now
    elseif t.off_since ~= 0 and now - t.off_since >= M.stepped_off_ms then
        send_attempt(false)
    end
end

return nil
