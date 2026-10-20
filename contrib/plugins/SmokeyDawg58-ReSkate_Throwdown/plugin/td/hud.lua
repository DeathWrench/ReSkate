-- SmokeyDawg58's game_modes.cpp, lines 2350-2826: fill_trick_parts, build_hud, number, help.
-- build_hud fills s.hud (his overlay::ModesHud), s.menu (overlay::ModesMenu) and s.native (his
-- NativeView) with his member names, and the State booleans his atomics were.
local M = require("td/core")
local RR = require("td/h/race_route")
local RE = require("td/h/race_editor")
local RA = require("td/h/race_arrow_placement")
local MP = require("td/h/mode_participation")

-- mode_rules.h's Mode, in its enum order (all_modes, and the order a std::map<Mode, int> iterates).
-- PORT: Mode::one_up is "oneup" as PORT.md says; mode_json.cpp writes mode_key ("1up"), so
-- M.settings_from has to give "oneup" for the 1-UP comparisons here to hold.
local all_modes = {"jam", "oneup", "meat", "race", "domination", "graffiti", "tag", "skate", "infection", "hide"}
-- static_cast<int>(Phase): setup = 1, countdown = 2, playing = 3, results = 4.
local phase_number = {setup = 1, countdown = 2, playing = 3, results = 4}

-- (td/rules.lua's mode_name, mode_summary and mode_key; "" for a word that names no mode.)
local function mode_name(mode)
    local m = M.parse_mode(mode)
    return if m then M.mode_name(m) else ""
end
local function mode_summary(mode)
    local m = M.parse_mode(mode)
    return if m then M.mode_summary(m) else ""
end
local function mode_key(mode)
    local m = M.parse_mode(mode)
    return if m then M.mode_key(m) else ""
end
-- `now - t` on his unsigned milliseconds: a time after `now` wraps to a huge age.
-- PORT: the wraparound is kept by answering math.huge when t > now.
local function since(now, t)
    if t > now then return math.huge end
    return now - t
end
local function list_copy(t)
    return t and table.clone(t) or {}
end
-- std::stable_sort: an insertion sort keeps equal rows in their order.
local function stable_sort(list, before)
    for i = 2, #list do
        local item = list[i]
        local j = i - 1
        while j >= 1 and before(item, list[j]) do
            list[j + 1] = list[j]
            j -= 1
        end
        list[j + 1] = item
    end
end

-- overlay::ModesHud h; with his defaults (camera and vertical_fov were the bridge's; the kit's HUD
-- projects markers itself).
local function new_hud()
    return {
        active = false,
        trick_title = "",
        trick_steps = "",
        done_tricks = {},
        callout = "",
        callout_serial = 0,
        trick_parts = {},
        goofy = false,
        players = {},
        infection = false,
        hide = false,
        blind = "",
        heat = -1,
        heat_label = "",
        heat_seeking = false,
        offers = {},
        invite = "",
        invite_fade = 0,
        can_join = false,
        title = "",
        clock = "",
        status = "",
        line = "",
        banner = "",
        banner_serial = 0,
        warning = "",
        results = false,
        winner = "",
        winner_value = "",
        winner_color = 0xffffffff,
        closing_ms = 0,
        rows = {},
        corners = {},
        area_radius = 0,
        placing = false,
        aiming = false,
        aim_ok = false,
        cursor = vector.zero,
        hint = "",
        prompts = {},
        me = vector.zero,
        have_me = false,
        points = {},
        point_colors = {},
        next_point = -1,
        route = false,
        point_yaws = {},
        point_widths = {},
        radius = 0,
        tags = {},
    }
end
-- overlay::ModesMenu m; with his defaults.
local function new_menu()
    return {
        in_game = false,
        leading = false,
        phase = 0,
        mode = "",
        corners = 0,
        points = 0,
        players = 0,
        duration = 0,
        turn = 0,
        strikes = 0,
        radius = 0,
        missing = "",
        bone_cam = "",
        bone_cam_ringing = true,
        official_meat = false,
        meat_every_bail = false,
        trick_kinds = 0x0f,
        spectate = true,
        goofy = false,
        in_session = false,
        lobby_modded = {},
        lobby_outdated = {},
        lobby_without = 0,
        leaders = {},
        recent = {},
        lobby_games = 0,
        lobby_top_mode = "",
        area_radius = 0,
        placing = "",
        offers = {},
    }
end
-- NativeView native; with his defaults.
local function new_native()
    return {
        active = false,
        leading = false,
        placing = false,
        pending_flag = false,
        flag_placed = false,
        waiting = false,
        ["local"] = "0",
        leader = "0",
        world = "0",
        state_sampled_ms = 0,
        game = 0,
        capacity = 6,
        route_finish = false,
        cursor_valid = false,
        route_object = 1,
        route_snap = true,
        exit_confirm = false,
        recovering = false,
        rotating = false,
        arrow_height_snapped = false,
        snap_degrees = 15,
        clear_progress = 0,
        save_progress = 0,
        route_dialog = 0,
        route_dialog_serial = 0,
        route_dialog_error = "",
        route_map = "",
        route_name = "",
        saved_routes = {},
        missed_gate = 0,
        cursor = vector.zero,
        cursor_yaw = 0,
        cursor_width = 6,
        cursor_roll = 0,
        cursor_pitch = 0,
        editor_roll_axis = false,
        route_saved = false,
        gates_visible_from = 0,
        object_changed_ms = 0,
        placing_circle = false,
        draft_radius = 0,
        placing_corners = false,
        zone_custom = false,
        settings = M.Settings(),
        state = nil,
        waiting_status = "",
        editor_warning = "",
        names = {},
    }
end
-- overlay::ModesHudOffer offer; with his defaults.
local function new_offer()
    return {mode = "", host = "", detail = "", at = vector.zero, has_at = false, open = false, target = false, own = false, id = "0"}
end

-- R.E.S.K.A.T.E.'s trick to copy for the HUD: each part with its flick (or what kind of trick it is).
function M.fill_trick_parts(h, trick, title, goofy)
    h.trick_title = title
    h.goofy = goofy
    local start = 0
    while start < #trick and #h.trick_parts < 4 do
        local found = string.find(trick, " + ", start + 1, true)
        local finish = found and found - 1 or #trick
        local part = {name = "", path = {}, kind = ""}
        part.name = string.sub(trick, start + 1, finish)
        -- PORT: his path entries are std::array<float, 2>; these stay the API's {x, y} lists. His
        -- native HUD (td/ui_hud.lua) draws the flick-it picture from trick_steps, not these.
        part.path = reskate.tricks.gesture(part.name) or {}
        if #part.path == 0 then
            local kinds = M.trick_kinds_of(part.name)
            part.kind = bit32.band(kinds, M.trick_grinds) ~= 0 and "GRIND"
                or bit32.band(kinds, M.trick_manuals) ~= 0 and "MANUAL"
                or bit32.band(kinds, M.trick_grabs) ~= 0 and "GRAB"
                or "TRICK"
        end
        table.insert(h.trick_parts, part)
        start = finish + 3
    end
end

function M.build_hud(s, now)
    local goofy = reskate.skater.goofy()
    if goofy ~= nil then s.goofy = goofy end
    local h = new_hud()
    if s.game then
        local g = s.game
        local st = g.state
        local mode = g.settings.mode
        local self = M.self_id(s)
        local me = M.standing(g, self)
        local points_n = #g.settings.points
        h.active = true
        h.title = mode_name(mode)
        if not g.leading then h.title ..= "  -  " .. M.name_of(s, g.leader) .. "'s game" end
        local phase = st and st.phase or "setup"
        if phase == "setup" then
            if g.leading then
                local why = M.missing(g.settings)
                h.status = why == "" and string.format("Ready with %d player%s: `mode start` to begin.", st and #st.standings or 1,
                                                       (st and #st.standings == 1) and "" or "s")
                                     or why
            else
                h.status = me and M.name_of(s, g.leader) .. " is setting up. You're in!"
                    or s.barred and "Your mods change trick scoring: you can watch, not play."
                    or "Joining..."
            end
        elseif phase == "countdown" then
            h.clock = tostring((st.remaining_ms + 999) // 1000)
            h.status = mode == "race" and "GET READY" or mode_summary(mode)
        elseif phase == "playing" then
            -- static_cast<std::size_t>(score) < size: a negative score wraps and is never below it.
            if mode ~= "race" or (me and not me.out and me.score >= 0 and me.score < points_n and M.race_clock_visible(me.remaining_ms)) then
                h.clock = M.clock_text((mode == "race" and me) and me.remaining_ms or st.remaining_ms)
            end
            if mode == "race" and me then
                local passed = M.mandatory_gates(g.settings, math.max(0, me.score))
                local total = M.mandatory_gates(g.settings, points_n)
                h.status = string.format("REQUIRED %d/%d  /  %d LEFT", passed, total, total - passed)
                if me.out then
                    h.status = "DNF"
                elseif me.score < 0 or me.score >= points_n then
                    h.status = "FINISHED"
                elseif g.missed_warned == me.score and (g.recovery_pending or now < g.recovery_until) then
                    h.status = string.format("GO BACK: REQUIRED %d  /  %d LEFT", passed + 1, total - passed)
                end
            end
            if mode == "oneup" then
                local target = st.target > 0 and "beat " .. M.grouped(st.target) or "set a score"
                h.status = st.turn == self and "YOUR TURN: " .. target or M.name_of(s, st.turn) .. " is up: " .. target
            elseif mode == "skate" and M.nz(st.turn) then
                local setting = st.trick == ""
                -- The trick to copy, drawn the way skate.'s own R.E.S.K.A.T.E. shows it: each part's flick.
                if not setting then
                    M.fill_trick_parts(h, st.trick, st.turn == self and "COPY THIS" or M.name_of(s, st.turn) .. " IS TRYING", s.goofy)
                end
                if st.turn == self then
                    h.status = setting and "YOUR SET: land a trick (" .. M.trick_kinds_text(g.settings.trick_kinds) .. ")"
                        or "YOUR TURN: land the " .. st.trick
                else
                    h.status = setting and M.name_of(s, st.turn) .. " is setting a trick" or M.name_of(s, st.turn) .. " is trying the " .. st.trick
                end
                -- How to do it, as skate.'s Skatepedia shows it: the flick-it stick picture and buttons.
                if not setting then h.trick_steps = M.trick_steps(st.trick, s.goofy) end
                -- The trick zone: how far outside it the local player is.
                if g.settings.area_radius > 0 and #g.settings.corners > 0 and not M.inside(g.settings, s.position) then
                    local c = g.settings.corners[1]
                    h.warning = string.format("OUT OF THE ZONE  -  %.0f M",
                                              math.sqrt((s.position.x - c.x) ^ 2 + (s.position.z - c.z) ^ 2) - g.settings.area_radius)
                end
                -- Skate 3's "Already been done": every trick set this game, as states name it.
                if s.letters_done_game ~= g.id then
                    s.letters_done = {}
                    s.letters_done_game = g.id
                end
                if not setting and not table.find(s.letters_done, st.trick) then
                    table.insert(s.letters_done, st.trick)
                end
                h.done_tricks = list_copy(s.letters_done)
                -- The referee's latest calls as one short callout, the most important first.
                h.callout = M.letters_callout(st.calls)
                h.callout_serial = st.call_serial
            elseif mode == "tag" and M.nz(st.turn) then
                h.status = st.turn == self and "YOU'RE IT! Get close to someone to tag them"
                    or M.name_of(s, st.turn) .. " is it. Don't get tagged!"
            elseif mode == "infection" and me then
                local clean = 0
                for _, p in st.standings do
                    if not p.up and not p.out then clean += 1 end
                end
                h.status = me.up and string.format("YOU'RE INFECTED! Catch the survivors (%d left)", clean)
                    or string.format("SURVIVE! Stay away from the reapers (%d still clean)", clean)
            elseif mode == "hide" and me then
                local hiding = 0
                for _, p in st.standings do
                    if not p.up and not p.out then hiding += 1 end
                end
                local counting = (math.max(st.target, 0) + 999) // 1000
                if st.target > 0 then
                    h.status = me.up and string.format("YOU'RE SEEKING. Count... the hunt starts in %d s", counting)
                        or string.format("HIDE! The seekers come out in %d s", counting)
                else
                    h.status = me.up and string.format("FIND THEM! %d still hiding. Follow the heat", hiding)
                        or string.format("STAY HIDDEN! %d still hiding", hiding)
                end
                if st.target > 0 and me.up and not me.out then h.blind = tostring(counting) end
            elseif not me then
                h.status = "Watching."
            elseif mode ~= "race" then
                h.status = mode_summary(mode)
            end
        elseif phase == "results" then
            h.clock = "FINAL"
            h.status = (st and #st.standings > 0) and M.name_of(s, st.standings[1].player) .. " wins!" or "Game over."
        end
        if mode == "skate" then -- no trick lines in R.E.S.K.A.T.E.: the attempt as it is done, then how it went
            if phase == "playing" and s.skate.mine and not s.skate.sent and #s.skate.parts > 0 then
                h.line = M.skate_trick(s.skate)
            elseif s.popup ~= "" and since(now, s.popup_at) < M.popup_ms and me and phase == "playing" then
                h.line = s.popup
            end
        elseif s.line.tricks ~= 0 and me and phase == "playing" then
            h.line = string.format("%d trick line  -  %s", s.line.tricks, M.grouped(M.line_score(s.line.sum, s.line.tricks)))
        elseif s.popup ~= "" and since(now, s.popup_at) < M.popup_ms and me and phase == "playing" then
            h.line = s.popup
        end
        if st and st.call_serial ~= 0 and #st.calls > 0 then
            h.banner = st.calls[#st.calls]
            h.banner_serial = st.call_serial
        end
        -- Skate Tag: every player whose position is fresh, the one who is it marked. Infection: the
        -- infected marked (all of them hunt).
        if M.tag_like(mode) and st and (phase == "playing" or phase == "results") then
            h.infection = mode == "infection"
            h.hide = mode == "hide"
            for _, p in st.standings do
                -- PORT: s.positions[id] is taken to be {position, ms} (his std::pair<Vec3, std::uint64_t>).
                local found = s.positions[p.player]
                if not found or since(now, found[2]) > 3000 or p.out then continue end
                if mode == "hide" and not p.up and phase == "playing" then continue end -- hiders stay hidden
                local marked
                if M.hunt_like(mode) then marked = p.up else marked = p.player == st.turn end
                table.insert(h.players, {name = M.name_of(s, p.player), at = found[1], color = M.player_colour(st, p.player), it = marked,
                                         self = p.player == self})
            end
        end
        -- Hide & Seek's hot/cold meter, once the seekers are out: a seeker feels the nearest hider, a
        -- hider the nearest seeker. 60 m away or more is freezing.
        if mode == "hide" and me and not me.out and phase == "playing" and st.target <= 0 then
            local nearest = -1
            for _, p in st.standings do
                if p.player == self or p.out or p.up == me.up then continue end
                local found = s.positions[p.player]
                if not found or since(now, found[2]) > 3000 then continue end
                local a = found[1]
                local d = vector.magnitude(a - s.position)
                if nearest < 0 or d < nearest then nearest = d end
            end
            if nearest >= 0 then
                h.heat = math.clamp(1.0 - nearest / 60.0, 0.0, 1.0)
                h.heat_seeking = me.up
                h.heat_label = h.heat > 0.85 and "ON FIRE" or h.heat > 0.6 and "HOT" or h.heat > 0.35 and "WARM" or h.heat > 0.1 and "COLD" or "FREEZING"
            end
        end
        -- R.E.S.K.A.T.E. reads trick names through Hall of Meat's UI hook: without it no attempt can count.
        if mode == "skate" and me and not M.hall_of_meat.available() then
            h.warning = "This game version can't read trick names: R.E.S.K.A.T.E. won't see your tricks."
        end
        if s.outside_since ~= 0 and phase == "playing" then
            local elapsed = since(now, s.outside_since)
            local left = M.out_of_area_ms > elapsed and M.out_of_area_ms - elapsed or 0
            h.warning = string.format("OUT OF THE AREA: nothing counts. Back in %d s", (left + 999) // 1000)
        end
        if st then
            for _, p in st.standings do
                local row = {name = "", value = "", color = 0xffffffff, self = false, up = false, out = false}
                row.name = M.name_of(s, p.player)
                row.color = M.player_colour(st, p.player)
                row.self = p.player == self
                row.up = p.up
                row.out = p.out
                if mode == "jam" then
                    row.value = M.grouped(p.score)
                elseif mode == "oneup" then
                    local marks = ""
                    for i = 0, g.settings.strikes - 1 do marks ..= i < p.aux and "X" or "-" end
                    row.value = marks .. (p.score ~= 0 and "  " .. M.grouped(p.score) or "")
                elseif mode == "meat" then
                    row.value = M.grouped(p.score) .. (p.aux ~= 0 and "  (best " .. M.grouped(p.aux) .. ")" or "")
                elseif mode == "race" then
                    if (p.score < 0 or p.score >= points_n) and p.aux ~= 0 then
                        row.value = string.format("FINISH  %.1fs", p.aux / 1000.0)
                    elseif p.out then
                        row.value = "DNF"
                    else
                        row.value = string.format("%d/%d", M.mandatory_gates(g.settings, math.max(0, p.score)),
                                                  M.mandatory_gates(g.settings, points_n))
                    end
                elseif mode == "domination" then
                    row.value = M.grouped(p.score) .. " pts"
                elseif mode == "graffiti" then
                    row.value = string.format("%d zone%s", p.score, p.score == 1 and "" or "s")
                elseif mode == "tag" then
                    row.value = string.format("%.1f s it", p.score / 10.0)
                elseif mode == "infection" then
                    row.value = string.format("%s%.1f s", p.up and "INFECTED  " or "", p.score / 10.0)
                elseif mode == "hide" then
                    row.value = p.up and string.format("SEEKING  %.1f s%s", p.score / 10.0, p.aux ~= 0 and string.format(", found %d", p.aux) or "")
                        or string.format("%.1f s hidden", p.score / 10.0)
                elseif mode == "skate" then -- the game's whole word, earned letters shown, the rest dashes: "R E S - - - -"
                    local word = ""
                    local i = 0
                    while i < g.settings.strikes and i < #M.reskate_word do
                        if word ~= "" then word ..= " " end
                        word ..= i < p.aux and string.sub(M.reskate_word, i + 1, i + 1) or "-"
                        i += 1
                    end
                    row.value = word -- out: every letter of the word, spelled
                end
                if phase == "setup" then row.value = "ready" end
                table.insert(h.rows, row)
            end
        end
        -- The end: who won, big in the middle of everyone's screen, and once in the chat.
        if phase == "results" and st and #st.standings > 0 and #h.rows > 0 then
            h.results = true
            h.winner = ((mode == "race" and st.standings[1].out) or (mode == "skate" and #st.standings == 1))
                and "" or h.rows[1].name
            h.winner_value = h.rows[1].value
            h.winner_color = h.rows[1].color
            h.closing_ms = st.remaining_ms
        end
        h.corners = list_copy(g.settings.corners)
        h.points = list_copy(g.settings.points)
        h.radius = g.settings.radius
        h.point_colors = table.create(#h.points, 0)
        if mode == "domination" and st then
            for _, z in st.zones do
                if z.zone < #h.point_colors then h.point_colors[z.zone + 1] = M.player_colour(st, z.owner) end
            end
        end
        if mode == "race" and me and phase ~= "results" then h.next_point = me.score end
        h.route = mode == "race"
        h.point_yaws = list_copy(g.settings.yaws)
        h.point_widths = list_copy(g.settings.widths)
        h.area_radius = g.settings.area_radius
        h.have_me = s.skater
        h.me = s.position
        -- Placing: the area or the points follow the cursor (the ground aimed at, or under the skater) until confirmed.
        if g.leading and s.placing ~= "none" then
            h.placing = true
            h.aiming = s.free_place
            h.aim_ok = s.cursor_ok
            h.cursor = s.cursor
            local m = s.free_place -- mouse and keyboard work too
            if s.placing == "circle" then
                h.corners = {s.cursor}
                h.area_radius = s.draft_radius
                h.hint = s.free_place and "Aim at the centre of your spot" or "Skate to the centre of your spot"
                h.prompts = {
                    {dpad = "U", key = m and "Wheel up / PgUp" or "PgUp", label = "Bigger"},
                    {dpad = "D", key = m and "Wheel down / PgDn" or "PgDn", label = "Smaller"},
                    {dpad = "R", key = m and "Click / Enter" or "Enter", label = "Set"},
                    {dpad = "L", key = "Backspace", label = "Cancel"},
                }
                h.line = string.format("%.0f m across", s.draft_radius * 2)
            elseif s.placing == "corners" then
                h.area_radius = 0
                table.insert(h.corners, s.cursor)
                h.hint = s.free_place and "Aim at each corner of your spot" or "Skate to each corner of your spot"
                h.prompts = {
                    {dpad = "R", key = m and "Click / Enter" or "Enter", label = "Add corner"},
                    {dpad = "D", key = m and "F / End" or "End", label = "Done"},
                    {dpad = "L", key = "Backspace", label = "Undo"},
                }
                local placed = #g.settings.corners
                h.line = string.format("%d corner%s placed%s", placed, placed == 1 and "" or "s",
                                       placed < 3 and string.format(" - %d more needed", 3 - placed) or "")
            elseif s.placing == "points" then
                if mode == "race" then
                    h.hint = string.format("%s  /  Size %.0f%%", RE.race_editor_object_name(s.race_object), s.draft_width / 6 * 100)
                    h.prompts = {
                        {dpad = "", key = "LT/RT or Z/X", label = "Required / Finish / Guide / Arrow"},
                        {dpad = "R", key = "A / Click / Enter", label = "Place object"},
                        {dpad = "", key = "X / R", label = s.editor_rotating and "Finish rotating" or "Rotate"},
                        {dpad = "", key = "D-pad Left/Right / PgUp/PgDn", label = s.editor_rotating and "Yaw" or "Undo / Redo"},
                        {dpad = "", key = "D-pad Up/Down / [ ]",
                         label = s.editor_rotating and (s.editor_roll_axis and "Arrow up / down" or "Tilt") or "Size"},
                        {dpad = "", key = "Start / F", label = "Tap: Save / Hold: Load"},
                        {dpad = "", key = "Hold Select / Backspace", label = "Clear route"},
                    }
                    local guiding = 0
                    for _, kind in g.settings.gate_kinds do
                        if kind == "guide" then guiding += 1 end
                    end
                    h.line = string.format("%d required; %d guiding; %s; gate %.0f m wide", M.mandatory_gates(g.settings, points_n),
                                           guiding, g.race_finish_placed and "finish placed" or "finish needed", s.draft_width * 2)
                else
                    table.insert(h.points, s.cursor)
                    table.insert(h.point_colors, 0)
                    h.hint = string.format("%s each %s", s.free_place and "Aim at" or "Skate to", M.point_name(g))
                    h.prompts = {
                        {dpad = "R", key = m and "Click / Enter" or "Enter", label = "Add"},
                        {dpad = "D", key = m and "F / End" or "End", label = "Done"},
                        {dpad = "L", key = "Backspace", label = "Undo"},
                    }
                    h.line = string.format("%d %s%s placed", points_n, M.point_name(g), points_n == 1 and "" or "s")
                end
            end
        end
        if mode == "graffiti" and st then
            -- Every tag painted in its holder's colour, where it was skated.
            for _, z in st.zones do
                if M.nz(z.owner) and z.zone < #g.tags and #g.tags[z.zone + 1].path > 0 then
                    table.insert(h.tags, {path = list_copy(g.tags[z.zone + 1].path), gap = g.tags[z.zone + 1].kind == "gap",
                                          color = M.player_colour(st, z.owner)})
                end
            end
        end
        -- The area, checkpoints and tags belong to the players in the game: someone watching
        -- (they arrived late, or cannot play) sees the scoreboard but not the walls.
        if not me and not g.leading then
            h.corners = {}
            h.area_radius = 0
            h.points = {}
            h.point_colors = {}
            h.next_point = -1
            h.tags = {}
        end
    end
    -- `mode diagram <trick>`: R.E.S.K.A.T.E.'s flick diagram for a trick, without a game.
    if not h.active and now < s.diagram_until then
        h.active = true
        h.title = "R.E.S.K.A.T.E."
        h.status = "Flick diagram preview"
        M.fill_trick_parts(h, s.diagram_trick, "COPY THIS", s.goofy)
    end
    -- What the Game Modes page of the ReSkate menu shows and offers.
    local m = new_menu()
    -- The SDK names his "meat" setting "game" (shown while this plugin's game asks for it).
    m.bone_cam = reskate.skater.bone_cam()
    if m.bone_cam == "game" then m.bone_cam = "meat" end
    m.bone_cam_ringing = reskate.skater.bone_cam("ringing") == "1"
    m.spectate = s.spectate
    m.in_session = s.session
    for _, id in M.sorted_keys(s.present) do
        local heard = s.modded[id]
        if heard == nil or since(now, heard) > 20000 then
            m.lobby_without += 1
        elseif s.other_version[id] ~= nil then
            table.insert(m.lobby_outdated, M.name_of(s, id))
        else
            table.insert(m.lobby_modded, M.name_of(s, id))
        end
    end
    for _, id in M.sorted_keys(s.lobby) do
        local e = s.lobby[id]
        local row = {name = e.name, points = e.points, wins = e.wins, podiums = e.podiums, games = e.games, streak = e.streak,
                     best_streak = e.best_streak, best_mode = "", you = id == M.self_id(s)}
        local most = 0
        for _, mode in all_modes do
            local wins = e.mode_wins[mode]
            if wins ~= nil and wins > most then
                most = wins
                row.best_mode = mode_name(mode)
            end
        end
        table.insert(m.leaders, row)
    end
    stable_sort(m.leaders, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        if a.wins ~= b.wins then return a.wins > b.wins end
        return a.podiums > b.podiums
    end)
    for _, g in s.lobby_recent do
        table.insert(m.recent, {mode = mode_name(g.mode), winner = g.winner, second = g.second, players = g.players,
                                ago_s = (now - g.at) // 1000})
    end
    local counted = 0
    for _ in s.lobby_counted do counted += 1 end
    m.lobby_games = counted
    local played = 0
    for _, mode in all_modes do
        local count = s.lobby_played[mode]
        if count ~= nil and count > played then
            played = count
            m.lobby_top_mode = mode_name(mode)
        end
    end
    m.goofy = s.goofy
    m.official_meat = M.hall_of_meat.available()
    m.meat_every_bail = M.hall_of_meat.switched_on()
    if s.game then
        local g = s.game
        m.in_game = true
        m.leading = g.leading
        m.phase = g.state and phase_number[g.state.phase] or phase_number.setup
        m.mode = mode_key(g.settings.mode)
        m.corners = #g.settings.corners
        m.points = #g.settings.points
        m.players = g.state and #g.state.standings or 1
        m.duration = g.settings.duration_s
        m.turn = g.settings.turn_s
        m.strikes = g.settings.strikes
        m.trick_kinds = g.settings.trick_kinds
        m.radius = g.settings.radius
        if g.leading and not g.referee then m.missing = M.missing(g.settings) end
        m.area_radius = g.settings.area_radius
        m.placing = s.placing == "circle" and "circle" or s.placing == "corners" and "corners"
            or s.placing == "points" and "points" or ""
    end
    -- Other players' games: banners over the world, the announcement, and the menu's list.
    for _, o in s.offers do
        if not o.confirmed then continue end -- its phase is not known yet (a state message follows within half a second)
        if o.settings.mode == "race" and not M.offer_open(o) then continue end
        local offer = new_offer()
        local mode = string.upper(mode_name(o.settings.mode))
        offer.mode = mode
        offer.host = M.name_of(s, o.leader) .. ((o.leader == s.invite_leader and since(now, s.invite_at) < M.invite_ms) and "  -  NEW" or "")
        offer.open = M.offer_open(o)
        offer.detail = string.format("%d player%s  -  %s", o.players, o.players == 1 and "" or "s",
                                     o.phase == "countdown" and "starting now!" or offer.open and "join now" or "in progress")
        local spot = M.game_spot(o.settings)
        if spot then
            offer.at = spot
            offer.has_at = true
        end
        -- PORT: s.join_target is taken to be nil or {leader, game} (his std::pair<std::uint64_t, std::uint32_t>).
        offer.target = s.join_target ~= nil and s.join_target[1] == o.leader and s.join_target[2] == o.game
        offer.id = o.leader
        table.insert(h.offers, offer)
        table.insert(m.offers, table.clone(offer))
    end
    -- The local player's own game while it takes players: its flag stands where the others join,
    -- so its leader sees what they see. Not in the menu's list: there is nothing to join.
    if s.game and s.game.leading then
        local g = s.game
        local phase = g.state and g.state.phase or "setup"
        local spot = M.game_spot(g.settings)
        if spot and (phase == "setup" or phase == "countdown") then
            local own = new_offer()
            local mode = string.upper(mode_name(g.settings.mode))
            own.mode = mode
            own.host = "YOUR GAME"
            local players = g.state and #g.state.standings or 1
            own.open = phase == "countdown" or M.race_lobby_open(s, g)
            own.detail = own.open and string.format("%d player%s  -  others join at this flag", players, players == 1 and "" or "s")
                or "LOCAL DRAFT - save your route to invite players"
            own.at = spot
            own.has_at = true
            own.own = true
            table.insert(h.offers, own)
        end
    end
    h.can_join = false -- Joining belongs to the native flag/picker.
    local native = new_native()
    native["local"] = M.self_id(s)
    native.world = s.world
    if s.game then
        local g = s.game
        native.active = true
        native.leading = g.leading
        native.leader = g.leader
        native.game = g.id
        native.settings = M.copy(g.settings)
        native.state = g.state and M.copy(g.state) or nil
        native.capacity = g.capacity
        native.placing = s.placing ~= "none"
        native.state_sampled_ms = g.state_sampled_ms
        native.flag_placed = g.native_flag_placed
        native.pending_flag = g.native_lobby and not g.native_flag_placed and not g.referee
        native.waiting = g.native_lobby and g.native_flag_placed and not g.referee and not native.placing
            and (not g.leading or M.race_lobby_open(s, g))
            and (not g.state or g.state.phase == "setup")
        if native.waiting then
            native.waiting_status = M.missing(g.settings)
            local finish
            if g.leading then finish = g.race_finish_placed else finish = g.settings.race_finish end
            if g.settings.mode == "race" and not RR.race_route_ready(g.settings, finish) then
                native.waiting_status = "Place the start, checkpoints and red finish before saving the route."
            end
        end
        native.route_finish = g.settings.race_finish
        native.route_object = s.race_object
        native.cursor = s.cursor
        if s.game.settings.mode == "race" and s.race_object == 4 then
            native.cursor_valid = RA.race_arrow_preview_visible(s.arrow_preview_ready, s.editor_rotating, s.editor_angles_ready)
        else
            native.cursor_valid = s.cursor_ok
        end
        if s.placing == "points" and g.settings.mode == "race" then
            native.cursor_yaw = s.snapped_yaw
        else
            native.cursor_yaw = s.cursor_heading + s.yaw_offset
        end
        native.cursor_width = s.draft_width
        native.placing_circle = s.placing == "circle"
        native.draft_radius = s.draft_radius
        native.placing_corners = s.placing == "corners"
        native.zone_custom = M.reskate_custom_zone(g.settings, g.zone_custom)
        native.cursor_roll = s.arrow_roll
        native.cursor_pitch = s.editor_pitch
        native.rotating = s.editor_rotating
        native.arrow_height_snapped = s.arrow_height_snapped
        if native.placing and g.settings.mode == "race" and s.editor_save_blocked then
            native.editor_warning = RR.race_route_save_error(g.settings, g.race_finish_placed)
        end
        native.route_snap = s.route_snap
        native.snap_degrees = ({5, 15, 30, 45, 90})[s.snap_angle + 1]
        native.editor_roll_axis = s.editor_roll_axis
        native.object_changed_ms = s.editor_object_changed
        native.route_saved = g.settings.mode ~= "race" or not g.leading or g.race_publication:ready(g.settings)
        if g.settings.mode == "race" then
            local me = M.standing(g, native["local"])
            if me and me.score >= 0 then
                native.gates_visible_from = g.checkpoint_fallback:visible_from(me.score)
            end
        end
        native.clear_progress = s.clear_hold.progress
        native.save_progress = s.save_hold.progress
        native.exit_confirm = s.editor_exit_confirm
        native.route_dialog = s.route_dialog
        native.route_dialog_serial = s.route_dialog_serial
        native.route_dialog_error = s.route_dialog_error
        native.route_map = s.course_map
        native.route_name = s.route_name
        if s.route_dialog ~= 0 and s.route_library then
            for _, saved in s.route_library:routes() do
                if saved.map == s.course_map then
                    -- PORT: static_cast<unsigned>(size - 1) wraps for a route without points; here it is -1
                    -- (the bridge's unsigned read then falls back to 0).
                    table.insert(native.saved_routes, {id = saved.id, name = saved.name, map = saved.map,
                        required = M.mandatory_gates(saved.settings, #saved.settings.points),
                        objects = #saved.settings.points - 1})
                end
            end
        end
        if s.route_dialog == 3 and s.route_library then
            local renamed = s.route_library:find(s.route_rename_id)
            if renamed then
                native.route_name = renamed.name
                native.route_map = renamed.map
            end
        end
        native.recovering = g.recovery_pending

        if native.state and native.state.phase == "playing" then
            for _, player in native.state.standings do
                if player.player == native["local"] and not player.out and player.score >= 0 and player.score < #g.settings.points
                    and g.missed_warned == player.score and not g.gate_crossed and (g.recovery_pending or now < g.recovery_until) then
                    native.missed_gate = M.mandatory_gates(g.settings, player.score) + 1
                end
            end
        end
    end
    table.insert(native.names, {id = M.self_id(s), name = M.name_of(s, M.self_id(s))})
    for _, id in M.sorted_keys(s.names) do
        if id ~= M.self_id(s) then table.insert(native.names, {id = id, name = s.names[id]}) end
    end
    -- PORT: multiplayer::one_up::view() is the 1-UP port's; PORT.md gives only M.one_up_match(). This
    -- reads M.one_up_view() (his one_up::View: participant, local, state = {match, phase, players =
    -- {id, connected, penalties}}) when the 1-UP port provides it, and counts no 1-UP match without it.
    local oneup_competing = false
    local oneup = M.one_up_view and M.one_up_view() or nil
    if oneup and oneup.participant and M.nz(oneup.state.match) then
        local oneup_player = nil
        for _, player in oneup.state.players do
            if player.id == oneup["local"] then
                oneup_player = player
                break
            end
        end
        oneup_competing = oneup_player ~= nil and (oneup_player.connected and oneup_player.penalties < 3)
            and oneup.state.phase ~= "lobby" and oneup.state.phase ~= "finished" and oneup.state.phase ~= "cancelled"
    end
    reskate.physics.competition(oneup_competing or (native.active and native.state ~= nil
        and MP.local_competition_active(native.settings, native.state, native["local"])))
    -- His local_meat_game: the Bone Cam's "game" setting shows while a Hall of Meat game plays here.
    local meat = false
    if native.active and native.settings.mode == "meat" and native.state ~= nil and native.state.phase == "playing" then
        for _, row in ipairs(native.state.standings) do
            if row.player == native["local"] then meat = true end
        end
    end
    if meat ~= s.bone_cam_game then
        s.bone_cam_game = meat
        reskate.skater.bone_cam("game", meat and "on" or "off")
    end
    s.input_locked = native.state ~= nil and native.state.phase == "countdown"
    s.race_countdown = native.active and native.settings.mode == "race" and native.state ~= nil
        and native.state.phase == "countdown"
    s.recovering = native.recovering
    s.route_dialog_active = native.active and native.placing and native.route_dialog ~= 0
    s.markers_restricted = native.active and native.state ~= nil
        and MP.local_competition_active(native.settings, native.state, native["local"])
    s.native = native
    s.hud = h
    s.menu = m
end

-- std::from_chars on a float: an optional minus sign, digits with an optional point, an optional
-- exponent, nothing else (no spaces, no plus sign, no hex).
function M.number(arguments, index)
    if index >= #arguments then return nil end
    local text = arguments[index + 1]
    local body = string.match(text, "^%-?(.*)$")
    local mantissa, exponent = string.match(body, "^([%d%.]+)(.*)$")
    if not mantissa then return nil end
    if not (string.match(mantissa, "^%d+%.?%d*$") or string.match(mantissa, "^%.%d+$")) then return nil end
    if exponent ~= "" and not string.match(exponent, "^[eE][%+%-]?%d+$") then return nil end
    local value = tonumber(text)
    if value == nil then return nil end
    -- A float: rounded to 32 bits (a vector's component is one); out of its range is infinite.
    -- PORT: from_chars reports underflow to zero as out of range too; here a tiny value becomes 0.
    value = vector.create(value, 0, 0).x
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

function M.help()
    local text = "Game modes. Start one with `mode new <mode>`:"
    for _, m in all_modes do text ..= string.format("\n  %-11s %s: %s", mode_key(m), mode_name(m), mode_summary(m)) end
    text ..= "\nThen, as its leader: `mode corner` at each corner of the area (undo|clear), `mode point` for capture spots"
        .. " or spots (undo|clear), `mode time|turn <seconds>`, `mode strikes <n>`, `mode radius <metres>`,"
        .. " `mode start`, `mode stop`. Anyone: `mode status`, `mode leave`, `mode bonecam meat|on|off|test`."
        .. " Or select its card in the native Throwdowns menu."
    return text
end

return nil
