-- His mode_rules.h / mode_rules.cpp (Extension/Modes), line for line: the modes, their names, the
-- tricks and their Skatepedia steps, the area, gates, tags and spots, and the scoring. His Referee is
-- td/referee.lua and his wire (encode, decode, mode_transport.h) td/wire.lua; both add themselves to
-- this table, and td/core.lua copies every field of it onto M.
-- Values as PORT.md says: positions are Luau vectors, Steam IDs decimal strings ("0" none), gate and
-- spot indices 0-based as his, enums their names (modes "jam" ... "oneup" ..., gate kinds "required",
-- "guide", "arrow", tag kinds "grind", "gap"). His floats are plain Lua numbers with his formulas.
local SP = require("td/skatepedia")
local R = {}

-- ---- mode_rules.h's modes and constants ----------------------------------------------------------
-- enum class Mode : std::uint8_t { jam = 1, one_up = 2, meat = 3, race = 4, domination = 5, graffiti = 6, tag = 7,
-- skate = 8, infection = 9, hide = 10 }: the names, and the numbers the wire carries.
R.all_modes = {"jam", "oneup", "meat", "race", "domination", "graffiti", "tag", "skate", "infection", "hide"}
R.mode_number = {}
for i, mode in ipairs(R.all_modes) do R.mode_number[mode] = i end
-- Played on where everyone is (position events): Skate Tag, Infection and Hide & Seek.
function R.tag_like(m) return m == "tag" or m == "infection" or m == "hide" end
-- The caught join the hunters: Infection and Hide & Seek.
function R.hunt_like(m) return m == "infection" or m == "hide" end

-- enum class Phase : std::uint8_t { setup = 1, countdown = 2, playing = 3, results = 4 }
R.phases = {"setup", "countdown", "playing", "results"}
R.phase_number = {setup = 1, countdown = 2, playing = 3, results = 4}

R.wire_magic = 0xD5 -- never a throwdown message's first byte (1..15)
R.wire_version = 16 -- pitched checkpoint planes require matching referee/renderers
R.max_corners, R.max_points, R.max_players, R.max_zones, R.max_calls = 16, 16, 16, 64, 4
R.max_call_length, R.max_tags, R.max_tag_points, R.max_line_tags = 96, 64, 6, 6
R.countdown_ms, R.results_ms = 5000, 12000
R.race_deadline_ms, R.race_warning_ms = 120000, 30000
-- enum class RaceGateKind : std::uint8_t { mandatory, guiding, arrow }: "required", "guide", "arrow".
R.gate_kinds = {"required", "guide", "arrow"}
R.gate_kind_number = {required = 0, guide = 1, arrow = 2}

-- R.E.S.K.A.T.E.'s trick kinds.
R.trick_flips, R.trick_grabs, R.trick_grinds, R.trick_manuals, R.all_trick_kinds = 1, 2, 4, 8, 0x0f
R.max_trick_length = 80
R.reskate_word = "RESKATE"
R.max_strikes = #R.reskate_word
R.min_area_radius, R.max_area_radius = 3.0, 1500.0 -- up to 3 km across (Skate Tag on a whole district)
-- Skate Tag: within this far (metres, the game's radius) the one who is it tags; the one just tagged
-- cannot tag back the one who tagged them for a while; a position older than this is not trusted.
R.default_tag_reach = 3.0
R.no_tag_back_ms, R.position_fresh_ms = 3000, 1500
-- A Deathrace gate's half width: its own, or the game's checkpoint radius.
R.min_gate_half_width, R.max_gate_half_width = 1.5, 40.0
R.gap_drop = 0.9 -- metres a landing must be below its takeoff to tag a gap
function R.race_clock_visible(remaining) return remaining > 0 and remaining <= R.race_warning_ms end

-- His Settings, Standing, ZoneOwner, Tag and Message (mode_rules.h) with their defaults.
function R.Settings()
    return {mode = "jam", duration_s = 300, turn_s = 30, strikes = 3, radius = 6.0, corners = {}, area_radius = 0, points = {},
            yaws = {}, widths = {}, gate_kinds = {}, arrow_rolls = {}, gate_pitches = {}, spawn = vector.zero, has_spawn = false,
            race_finish = false, trick_kinds = 0x0f}
end
function R.Standing()
    return {player = "0", score = 0, aux = 0, out = false, up = false, remaining_ms = 0}
end
function R.ZoneOwner()
    return {zone = 0, owner = "0", best = 0}
end
function R.Tag()
    return {kind = "grind", path = {}}
end
function R.Message()
    return {kind = "setup", version = R.wire_version, leader = "0", game = 0, settings = R.Settings(), phase = "setup", remaining_ms = 0,
            turn = "0", target = 0, standings = {}, zones = {}, calls = {}, call_serial = 0, event = "line", value = 0, extra = 0,
            at = vector.zero, sequence = 0, tags = {}, first = 0, trick = "", setter = "0"}
end

-- ---- helpers (mode_rules.cpp's anonymous namespace) ----------------------------------------------
local function isfinite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
R.isfinite = isfinite
local function finite(v) return isfinite(v.x) and isfinite(v.y) and isfinite(v.z) end
R.finite = finite
local function horizontal_distance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end
R.horizontal_distance = horizontal_distance
-- static_cast<std::int32_t>(x): toward zero.
local function trunc(x)
    if x >= 0 then return math.floor(x) end
    return math.ceil(x)
end
local function clamp_score(value)
    if not isfinite(value) or value <= 0 then return 0 end
    return trunc(math.min(value, 2.0e9))
end
local function any_of(list, f)
    for _, x in ipairs(list) do
        if f(x) then return true end
    end
    return false
end
local function all_of(list, f)
    for _, x in ipairs(list) do
        if not f(x) then return false end
    end
    return true
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return setmetatable(out, getmetatable(value))
end
R.deep_copy = copy

function R.valid_settings(s)
    if not any_of(R.all_modes, function(m) return m == s.mode end) then return false end
    if s.duration_s < 30 or s.duration_s > 3600 or s.turn_s < 10 or s.turn_s > 120 or s.strikes < 1
        or s.strikes > (if s.mode == "skate" then R.max_strikes else 5) then
        return false
    end
    if s.trick_kinds == 0 or s.trick_kinds > R.all_trick_kinds then return false end
    if not (s.radius >= 1.0 and s.radius <= 50.0) then return false end
    -- PORT: his `s.points.size() > INT32_MAX` cannot happen to a Lua list that fits in memory; not tested.
    if #s.corners > R.max_corners or (s.mode ~= "race" and #s.points > R.max_points) then return false end
    if #s.gate_kinds > 0 and (s.mode ~= "race" or #s.gate_kinds ~= #s.points or
        not all_of(s.gate_kinds, function(k) return k == "required" or k == "guide" or k == "arrow" end) or
        s.gate_kinds[1] ~= "required" or (s.race_finish and s.gate_kinds[#s.gate_kinds] ~= "required")) then
        return false
    end
    if #s.yaws > 0 and #s.yaws ~= #s.points then return false end
    if #s.widths > 0 and #s.widths ~= #s.points then return false end
    if #s.arrow_rolls > 0 and (s.mode ~= "race" or #s.arrow_rolls ~= #s.points or
        not all_of(s.arrow_rolls, function(a) return isfinite(a) and math.abs(a) <= 360 end)) then
        return false
    end
    if #s.gate_pitches > 0 and (s.mode ~= "race" or #s.gate_pitches ~= #s.points or
        not all_of(s.gate_pitches, function(a) return isfinite(a) and math.abs(a) <= 90 end)) then
        return false
    end
    if not all_of(s.widths, function(w) return w >= R.min_gate_half_width and w <= R.max_gate_half_width end) then return false end
    if not all_of(s.yaws, function(y) return isfinite(y) end) or (s.has_spawn and not finite(s.spawn)) then return false end
    if s.area_radius ~= 0.0 and not (s.area_radius >= R.min_area_radius and s.area_radius <= R.max_area_radius and #s.corners == 1) then
        return false
    end
    return all_of(s.corners, finite) and all_of(s.points, finite)
end

-- ---- the modes' names ----------------------------------------------------------------------------
local names = {jam = "Spot Jam", oneup = "1-Up", meat = "Hall of Meat", race = "Deathrace", domination = "Domination", graffiti = "Graffiti",
               tag = "Skate Tag", infection = "Infection", hide = "Hide & Seek", skate = "R.E.S.K.A.T.E."}
local keys = {jam = "jam", oneup = "1up", meat = "meat", race = "race", domination = "domination", graffiti = "graffiti", tag = "tag",
              infection = "infection", hide = "hide", skate = "skate"}
local summaries = {
    jam = "Land lines inside the area. Every line adds to your score; highest total wins.",
    oneup = "Take turns. Beat the last score or take a strike; last one standing wins.",
    meat = "Bail as hard as you can. Speed, drops and tumbling score; most meat wins.",
    race = "Cross required gates in order; gray guides are optional. Reach the red finish. Countdown only in the final 30 seconds.",
    domination = "Take spots with your best line there. Every second you hold one scores.",
    graffiti = "Grind it, manual it, gap it: what you skate takes your colour. A bigger line steals it. Most tags wins.",
    tag = "One player is it: get close to tag someone else. No tag-backs. Least time spent it wins.",
    infection = "One player starts infected. Everyone they reach is infected too and joins the hunt. Survive longest to win.",
    hide = "Hide while the seeker can't see. Then they hunt: whoever is found seeks too. Stay hidden longest to win.",
    skate = "Set a trick, everyone copies it or takes a letter. Spell R.E.S.K.A.T.E. and you're out; last one standing wins.",
}
function R.mode_name(m) return names[m] or "Game" end -- "Spot Jam"
function R.mode_key(m) return keys[m] or "" end       -- "jam": what `mode new` takes
function R.mode_summary(m) return summaries[m] or "" end -- one line on how it is played
local function lower(text)
    -- PORT: his lower() changes only A-Z; Luau's string.lower is the C locale's tolower, the same.
    return string.lower(text)
end
local aliases = {
    jam = "jam", spotjam = "jam", spot_jam = "jam",
    ["1up"] = "oneup", ["1-up"] = "oneup", oneup = "oneup",
    meat = "meat", hallofmeat = "meat", hom = "meat",
    race = "race", deathrace = "race",
    domination = "domination", dom = "domination",
    graffiti = "graffiti", thps = "graffiti",
    tag = "tag", skatetag = "tag", skate_tag = "tag",
    infection = "infection", infect = "infection", zombie = "infection", zombies = "infection",
    hide = "hide", hideandseek = "hide", hide_and_seek = "hide", hidenseek = "hide", seek = "hide",
    reskate = "skate", ["r.e.s.k.a.t.e."] = "skate", ["r.e.s.k.a.t.e"] = "skate", skate = "skate", ["s.k.a.t.e."] = "skate", ["s.k.a.t.e"] = "skate",
}
-- The mode a word names, or nil.
function R.parse_mode(text)
    if type(text) ~= "string" then return nil end
    return aliases[lower(text)]
end
-- Ends when the clock runs out (1-Up ends on strikes instead).
function R.timed(m) return m ~= "oneup" and m ~= "skate" end

-- ---- R.E.S.K.A.T.E.'s tricks ----------------------------------------------------------------------
local function has_any(text, words)
    for _, w in ipairs(words) do
        if string.find(text, w, 1, true) then return true end
    end
    return false
end
local grind_words = {"grind", "slide", "stall", "smith", "feeble", "crook", "blunt", "willy", "salad", "suski", "hurricane",
                     "rock to", "rock n", "pivot", "nosepick", "5-0", "50-50"}
local grab_words = {"grab", "indy", "melon", "stalefish", "mute", "japan", "seatbelt", "benihana", "method", "madonna", "crail",
                    "airwalk", "christ", "boned", "judo", "roast", "lien", "rocket", "stiffy", "tuck", "nuclear", "slob",
                    "weddle", "one foot", "frontside air", "backside air", "bone", "stale", "dogpiss", "dog piss", "superdude",
                    "frigid", "tweak", "shifty", "no foot", "nofoot", "onefoot", "tailwalk", "plant", "double grab"}
local flip_words = {"flip", "shuv", "varial", "impossible", "ollie", "nollie", "360", "180", "spin", "pop"}
-- One part of a trick ("Kickflip", "Seatbelt", "BS 50-50 Grind").
local function part_kinds(part)
    local kinds = 0
    if has_any(part, {"manual"}) then kinds = bit32.bor(kinds, R.trick_manuals) end
    if has_any(part, grind_words) then kinds = bit32.bor(kinds, R.trick_grinds) end
    if has_any(part, grab_words) then kinds = bit32.bor(kinds, R.trick_grabs) end
    if has_any(part, flip_words) then kinds = bit32.bor(kinds, R.trick_flips) end
    return if kinds ~= 0 then kinds else R.trick_flips -- anything else done in the air off the board's pop
end
-- His `while (start <= text.size())` loop over the parts between " + " (empty parts skipped).
local function split_parts(text)
    local parts = {}
    local start = 0 -- 0-based, as his
    while start <= #text do
        local found = string.find(text, " + ", start + 1, true)
        local stop = if found then found - 1 else #text
        if stop > start then table.insert(parts, string.sub(text, start + 1, stop)) end
        start = stop + 3
    end
    return parts
end

function R.trick_kinds_of(trick)
    local ok, kinds = pcall(function()
        local text = lower(trick)
        local kinds = 0
        for _, part in ipairs(split_parts(text)) do kinds = bit32.bor(kinds, part_kinds(part)) end
        return kinds
    end)
    return if ok then kinds else 0
end
-- A trick's parts as skate. names them ("Ollie", "BS 50-50 Grind"), without the plain ollie into the
-- part that matters: "Ollie + BS 50-50 Grind" is a 50-50 to set and to copy. A lone ollie stays one.
-- A nollie is kept: a nollie into a trick is a different trick.
local function trick_parts(trick)
    local parts = split_parts(trick)
    local function filler(part) return lower(part) == "ollie" end
    if any_of(parts, function(part) return not filler(part) end) then
        for i = #parts, 1, -1 do
            if filler(parts[i]) then table.remove(parts, i) end
        end
    end
    return parts
end

-- The trick as it is set: its parts without a plain ollie popped into the part that counts.
function R.set_trick_name(trick)
    local ok, text = pcall(function()
        local text = ""
        for _, part in ipairs(trick_parts(trick)) do
            if text ~= "" then text ..= " + " end
            text ..= part
        end
        return text
    end)
    return if ok then text else trick
end
-- An attempt copies the set trick when it has the same parts in the same order (case aside); a plain
-- ollie into it does not matter, anything more or less does.
function R.copies_trick(attempt, set)
    local ok, result = pcall(function()
        local wanted, done = trick_parts(set), trick_parts(attempt)
        if #wanted == 0 then return false end
        -- The same parts in the same order, case aside: more or less is a different trick.
        if #done ~= #wanted then return false end
        for i = 1, #done do
            if lower(done[i]) ~= lower(wanted[i]) then return false end
        end
        return true
    end)
    return ok and result
end

-- A trick list name as a Skatepedia key: lower case letters and digits, without "grab"/"grind".
local function skatepedia_key(name)
    local key = string.gsub(lower(name), "[^a-z0-9]", "")
    for _, word in ipairs({"grind", "grab"}) do
        local at = string.find(key, word, 1, true)
        if at and #key > #word then key = string.sub(key, 1, at - 1) .. string.sub(key, at + #word) end
    end
    return key
end
local function skatepedia_entry(key) return SP.by_key[key] end
local function starts_with(s, prefix) return string.sub(s, 1, #prefix) == prefix end
local function ends_with(s, suffix) return string.sub(s, -#suffix) == suffix end

local prefix_words = {"Switch ", "Fakie ", "Nollie ", "FS ", "BS ", "180 ", "360 ", "540 ", "720 ", "Late ",
                      "Double ", "Triple ", "Quad ", "Darkflip ", "Dark Catch "}
local suffix_words = {" FS", " BS", " 180", " 360", " 540", " 720"}
-- How to do a trick, as skate.'s Skatepedia card shows it: its input steps in the game's own markup
-- ("[img {0}]FLICKIT_Kickflip_RS[/img]", the flick-it stick picture) for a regular or goofy stance.
-- Empty when the Skatepedia has no entry for it.
function R.trick_steps(trick, goofy)
    goofy = goofy == true
    local ok, result = pcall(function()
        local text = ""
        for _, part in ipairs(trick_parts(trick)) do
            -- "Switch FS 180 360 Late Flip": the words before the trick's own name. The stance only
            -- changes which foot is forward; a nollie, side and spins can name a Skatepedia entry.
            local side, spin, nollie, name = "", "", "", part
            local late, mirrored = false, false
            local more = true
            while more do
                more = false
                for _, word in ipairs(prefix_words) do
                    if not starts_with(name, word) or #name == #word then continue end
                    if word == "Nollie " then nollie = "Nollie "
                    elseif word == "Switch " then mirrored = true -- the other foot forward: the other stance's flick
                    elseif word == "FS " or word == "BS " then side = string.sub(word, 1, 2)
                    elseif word == "Late " then late = true
                    elseif string.byte(word, 1) >= 48 and string.byte(word, 1) <= 57 then spin = string.sub(word, 1, 3) -- the last (the board's) names it
                    end
                    name = string.sub(name, #word + 1)
                    more = true
                end
            end
            -- The side and body spin after the name ("Inward Heelflip FS 180"), as skate. lists them.
            more = true
            while more do
                more = false
                for _, word in ipairs(suffix_words) do
                    if not ends_with(name, word) or #name == #word then continue end
                    if word == " FS" or word == " BS" then side = string.sub(word, 2) end
                    name = string.sub(name, 1, #name - #word)
                    more = true
                end
            end
            -- A late flip: the flip's own flick, done in the air (the Skatepedia's "late flip tricks").
            if late then
                if text ~= "" then text ..= " " end
                text ..= "In air"
            end
            local entry = nil
            -- The nollie versions have their own entries ("nolliekickflipunderflip"): those first.
            for _, candidate in ipairs({nollie .. side .. spin .. name, nollie .. side .. name, nollie .. spin .. name, nollie .. name,
                                        side .. spin .. name, side .. name, spin .. name, name}) do
                entry = skatepedia_entry(skatepedia_key(candidate))
                if entry then break end
            end
            if not entry then
                local heel = skatepedia_key(name) -- "Inward Heelflip" is the Skatepedia's "inwardheel"
                local at = string.find(heel, "heelflip", 1, true)
                if at then heel = string.sub(heel, 1, at - 1) .. "heel" .. string.sub(heel, at + 8) end
                if spin ~= "" then entry = skatepedia_entry(spin .. heel) end -- "360inwardheel"
                if not entry then entry = skatepedia_entry(heel) end
            end
            if not entry then continue end
            for _, step in ipairs(if goofy ~= mirrored then entry[3] else entry[2]) do
                if late and step == "ID_SKATEPEDIA_INAIR" then continue end -- said once already
                local shown = if step == "ID_SKATEPEDIA_INAIR" then "In air" elseif step == "ID_SKATEPEDIA_AND" then "+"
                    elseif starts_with(step, "ID_") then "" else step
                if shown == "" then continue end -- also an unused (empty) step
                if text ~= "" then text ..= " " end
                text ..= shown
            end
        end
        return text
    end)
    return if ok then result else ""
end
-- Infer a completed custom trick zone from the shared settings; draft is local.
function R.reskate_custom_zone(s, draft)
    return s.mode == "skate" and (draft == true or (s.area_radius <= 0 and #s.corners >= 3))
end
function R.trick_allowed(s, trick)
    local kinds = R.trick_kinds_of(trick)
    -- Any part of the chosen kind will do: a darkslide flipped into is a grind, a kickflip indy a flip and a grab.
    return bit32.band(kinds, s.trick_kinds) ~= 0
end
-- "R.E.S" for three letters of R.E.S.K.A.T.E.; the letters spell as many as `strikes` allows.
function R.skate_letters(letters, of)
    local word = R.reskate_word
    local text = ""
    local i = 0
    while i < letters and i < of and i < #word do
        if text ~= "" then text ..= "." end
        text ..= string.sub(word, i + 1, i + 1)
        i += 1
    end
    return text
end

-- What is missing before `mode start` (empty: ready).
function R.missing(s)
    if s.mode == "race" then
        if #s.points < 2 then return "Deathrace needs a route: a start and a finish (PLACE ROUTE)." end
    elseif s.mode == "domination" then
        if #s.points == 0 then return "Domination needs at least 1 spot: ride to each and use `mode point`." end
    end
    if s.area_radius == 0.0 and (#s.corners == 1 or #s.corners == 2) then
        return "An area needs at least 3 corners (or clear them to play without one)."
    end
    return ""
end

-- ---- gates (indices 0-based, as his) --------------------------------------------------------------
function R.gate_half_width(s, gate)
    if gate < #s.widths then return s.widths[gate + 1] end
    return s.radius
end
-- Both guide arches and floating arrows are optional visual route aids.
function R.guiding_gate(s, gate)
    return gate < #s.gate_kinds and s.gate_kinds[gate + 1] ~= "required"
end
function R.arrow_marker(s, gate)
    return gate < #s.gate_kinds and s.gate_kinds[gate + 1] == "arrow"
end
function R.next_race_gate(s, from)
    while from < #s.points and R.guiding_gate(s, from) do from += 1 end
    return from
end
function R.mandatory_gates(s, before)
    local stop = math.min(before, #s.points - ((s.race_finish and #s.points > 0) and 1 or 0))
    local count = 0
    for i = 1, stop - 1 do
        if not R.guiding_gate(s, i) then count += 1 end
    end
    return count
end

-- ---- the area -------------------------------------------------------------------------------------
function R.has_area(s)
    if s.area_radius > 0.0 then return #s.corners > 0 end
    return #s.corners >= 3
end
-- Inside the area seen from above. Without an area (fewer than three corners) everywhere is.
-- (His inside(const std::vector<Vec3>&, const Vec3&).)
function R.inside_corners(corners, p)
    if #corners < 3 then return true end
    local inside = false
    local j = #corners
    for i = 1, #corners do
        local a, b = corners[i], corners[j]
        if (a.z > p.z) ~= (b.z > p.z) and p.x < (b.x - a.x) * (p.z - a.z) / (b.z - a.z) + a.x then inside = not inside end
        j = i
    end
    return inside
end
-- The same for a game's area, a circle (area_radius) or the corners' shape. (His inside(const Settings&, ...).)
function R.inside(s, p)
    if s.area_radius > 0.0 and #s.corners > 0 then return horizontal_distance(p, s.corners[1]) <= s.area_radius end
    return R.inside_corners(s.corners, p)
end
-- Where to put back a player who wandered out: the corners' average height, at their middle.
-- (Vector sums are float32, as his.)
function R.area_centre(corners)
    if #corners == 0 then return vector.zero end
    local c = vector.zero
    for _, p in ipairs(corners) do c += p end
    return c / #corners
end

-- ---- Graffiti tags and Domination spots -----------------------------------------------------------
-- How far a point is from a path seen from above, and whether it is near the path's height.
local FLT_MAX = 3.4028234663852886e38
local function distance_to_path(p, path)
    local best = FLT_MAX
    for i = 1, #path - 1 do
        local a, b = path[i], path[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local length = dx * dx + dz * dz
        local t = if length > 0 then math.clamp(((p.x - a.x) * dx + (p.z - a.z) * dz) / length, 0.0, 1.0) else 0.0
        local x, y, z = a.x + dx * t - p.x, a.y + (b.y - a.y) * t - p.y, a.z + dz * t - p.z
        if math.abs(y) <= 1.0 then best = math.min(best, math.sqrt(x * x + z * z)) end
    end
    if #path == 1 and math.abs(path[1].y - p.y) <= 1.0 then best = horizontal_distance(p, path[1]) end
    return best
end
function R.valid_tag(t)
    if t.kind ~= "grind" and t.kind ~= "gap" then return false end
    if #t.path < 2 or #t.path > R.max_tag_points or (t.kind == "gap" and #t.path ~= 2) then return false end
    return all_of(t.path, finite)
end
function R.same_tag(a, b)
    if a.kind ~= b.kind or #a.path == 0 or #b.path == 0 then return false end
    if a.kind == "gap" then
        return horizontal_distance(a.path[1], b.path[1]) <= 3.0 and horizontal_distance(a.path[#a.path], b.path[#b.path]) <= 3.0 and
            math.abs(a.path[1].y - b.path[1].y) <= 1.5
    end
    -- Grinds on the same curb or rail: most of the shorter one runs along the other.
    local shorter = if #a.path <= #b.path then a else b
    local longer = if shorter == a then b else a
    local near = 0
    for _, p in ipairs(shorter.path) do
        if distance_to_path(p, longer.path) <= 1.2 then near += 1 end
    end
    return near * 2 >= #shorter.path
end
function R.tag_centre(t)
    if t.kind == "gap" and #t.path == 2 then return t.path[2] end -- a gap belongs where it lands
    return R.area_centre(t.path)
end
-- At most `count` points spread evenly along a path, its ends kept.
function R.thin_path(path, count)
    count = count or R.max_tag_points
    if #path <= count or count < 2 then return table.clone(path) end
    local along = {0}
    for i = 2, #path do
        local d = 0
        local a, b = path[i], path[i - 1]
        d += (a.x - b.x) * (a.x - b.x)
        d += (a.y - b.y) * (a.y - b.y)
        d += (a.z - b.z) * (a.z - b.z)
        along[i] = along[i - 1] + math.sqrt(d)
    end
    local result = {}
    for n = 0, count - 1 do
        local target = along[#along] * n / (count - 1)
        local i = 1 -- 0-based, as his
        while i + 1 < #path and along[i + 1] < target do i += 1 end
        local span = along[i + 1] - along[i]
        local t = if span > 0 then math.clamp((target - along[i]) / span, 0.0, 1.0) else 0.0
        local p0, p1 = path[i], path[i + 1]
        table.insert(result, vector.create(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t, p0.z + (p1.z - p0.z) * t))
    end
    return result
end
-- The Domination spot a point is on (nearest within reach): its 0-based index, or nil.
function R.spot_at(s, p)
    local best = nil
    local nearest = s.radius
    for i, point in ipairs(s.points) do
        local d = horizontal_distance(p, point)
        if d <= nearest and math.abs(p.y - point.y) <= 8.0 then
            nearest = d
            best = i - 1
        end
    end
    return best
end

-- ---- scoring --------------------------------------------------------------------------------------
-- Scoring, from what the Trainer measures of each jump: {air_time, height, distance, spin, flip, board_turn}.
function R.trick_score(j)
    local air_time, height, distance = j.air_time or 0, j.height or 0, j.distance or 0
    local spin_in, flip, board_turn = j.spin or 0, j.flip or 0, j.board_turn or 0
    -- A hop or a step off a kerb is not a trick.
    if not (air_time >= 0.2) then return 0 end
    local score = 100
    score += air_time * 300.0
    score += math.clamp(height, 0.0, 30.0) * 120.0
    score += math.clamp(distance, 0.0, 40.0) * 10.0
    local spin = math.abs(spin_in)
    score += math.floor((spin + 30.0) / 180.0) * 250.0 -- each 180 (a little short still counts)
    score += math.floor((flip + 60.0) / 360.0) * 600.0 -- body flips and rolls
    if board_turn >= 1800.0 then score += 350 -- the board spun hard: a flip trick
    elseif board_turn >= 900.0 then score += 200 end
    return math.min(clamp_score(score), 20000)
end
-- PORT: the API's static_cast<std::int64_t>(sum) and (unsigned) tricks are kept as truncations.
function R.line_score(sum, tricks)
    sum, tricks = trunc(sum), trunc(tricks)
    if sum <= 0 or tricks == 0 then return 0 end
    local multiplier = math.min(6.0, 1.0 + 0.5 * (tricks - 1))
    return clamp_score(sum * multiplier)
end
-- {speed (m/s over the ground when it began), drop (metres fallen while bailing), tumble (seconds wiped out)}.
function R.bail_score(b)
    local speed, drop, tumble = math.clamp(b.speed or 0, 0.0, 60.0), math.clamp(b.drop or 0, 0.0, 60.0), math.clamp(b.tumble or 0, 0.0, 10.0)
    return clamp_score(speed * speed * 4.0 + speed * 30.0 + drop * 250.0 + tumble * 150.0)
end

return R
