-- SmokeyDawg58's in-game HUD for his game modes (HIS/UI/NativeMenu/throwdown_modes_ui.inl: mode_hud,
-- mode_letters_hud, mode_race_standings, mode_results, mode_world_markers, mode_gate_compass,
-- race_editor_information and the placement editor), as the kit's hud document. Every caption,
-- number and layout choice is his; the SDK's throwdown_kit_hud.inl draws them with his widgets
-- (HUD_<theme>_*, the Race* cells, the editor panels).
local M = require("td/core")
local RE = require("td/h/race_editor")
local RN = require("td/h/race_navigation")

local white = 0xffffffff
-- R.E.S.K.A.T.E.'s letters: skate.'s white style tinted {1, .18, .16} (red) under the red glow.
local letter_red = M.colour(255, 46, 41)
local function hypot3(a, b) return math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2) end

-- flick_image(steps): the first flick-it picture of the Skatepedia steps ("[img {0}]FLICKIT_Kickflip_RS[/img]").
-- PORT: his tried four folders (RStick/LStick, Arrows/Terminals) for the first loaded picture; the
-- kit's card takes one texture path, so the stick's arrows folder is named by its _RS/_LS suffix.
local function flick_image(steps)
    local name = string.match(steps, "%]FLICKIT_([^%[]*)%[")
    if not name or name == "" then return "" end
    local folder = (string.find(name, "_LS", 1, true) or string.find(name, "LStick", 1, true)) and "LStick_Arrows_Yellow" or "RStick_Arrows_Yellow"
    return "UI/Textures/FlickItGestureImages/" .. folder .. "/img_FlickIt_" .. name
end

-- A standing's board row, as mode_race_standings built its three cells.
local function board_rows(n, feed, now)
    local mode = n.settings.mode
    local race, letters = mode == "race", mode == "skate"
    local st = n.state
    local rows, local_place = {}, 0
    if not st then return rows, local_place end
    local playing = st.phase == "playing"
    for i, player in ipairs(st.standings) do
        if i > #feed.rows or i > 6 then break end
        if player.player == n["local"] and not player.out then local_place = i end
        local row = {rank = (player.out and not letters) and "--" or M.ordinal(i - 1), name = feed.rows[i].name,
                     self = player.player == n["local"], out = player.out, color = white}
        if race then
            -- mode_racer_time: (DNF) and the racer's own clock, running while racing.
            row.value = player.out and "DNF  " or ""
            row.clock = {base_ms = math.max(0, player.aux), sampled_ms = n.state_sampled_ms, cap_ms = n.settings.duration_s * 1000,
                         running = playing and not player.out and math.max(0, player.score) < #n.settings.points}
        elseif letters then
            -- R.E.S.K.A.T.E.: the letters earned so far ("R E S"), in skate.'s red; none yet, a grey dash.
            row.marks = {}
            for ch in string.gmatch(feed.rows[i].value, "%S") do
                table.insert(row.marks, {text = ch, on = ch >= "A" and ch <= "Z"})
            end
            row.value = feed.rows[i].value
            row.color = letter_red
        else
            row.value = player.out and "OUT" or feed.rows[i].value
        end
        table.insert(rows, row)
    end
    return rows, local_place
end

-- race_editor_information: the builder's information panel, and the object's fading label.
local function race_editor_info(n, now)
    local s = n.settings
    local required, guides, arrows, length, previous = 0, 0, 0, 0, 0
    for i = 1, #s.points - 1 do
        if M.arrow_marker(s, i) then
            arrows += 1
        else
            if M.guiding_gate(s, i) then guides += 1
            elseif not (s.race_finish and i + 1 == #s.points) then required += 1 end
            length += hypot3(s.points[previous + 1], s.points[i + 1])
            previous = i
        end
    end
    local rows = {string.format("Required gates: %d", required), string.format("Finish gate: %s", n.route_finish and "Placed" or "Needed"),
                  string.format("Guide gates: %d   Arrows: %d", guides, arrows),
                  string.format("Placing: %s", RE.race_editor_object_name(n.route_object)),
                  string.format("Height: %.1f m", n.cursor.y),
                  string.format("Size: %d%%   Route: %.0f m", math.round(n.cursor_width / 6 * 100), length),
                  n.route_saved and "SAVED" or "LOCAL DRAFT"}
    local title = "ROUTE INFO"
    if n.rotating then
        title = "ROTATION INFO"
        rows[1] = string.format("Yaw: %.1f deg", RE.race_rotation_degrees(n.cursor_yaw))
        rows[2] = string.format("Tilt: %.1f deg", RE.race_rotation_degrees(n.cursor_pitch))
        rows[3] = string.format("Roll: %.1f deg", n.route_object == 4 and RE.race_rotation_degrees(n.cursor_roll) or 0)
    end
    local info = {title = title, rows = {}}
    for i, text in ipairs(rows) do info.rows[i] = {caption = text, value = ""} end
    local toast = nil
    local alpha = RE.race_object_label_alpha(now, n.object_changed_ms)
    if alpha > 0 then toast = {text = RE.race_placement_label(n.route_object), alpha = alpha} end
    return info, toast
end

-- The placement editor's controls: his sixteen actions, a pair of glyphs where two share a row.
local actions = {
    {"UI_TabSecondaryNavLeft", ""}, {"UI_TabSecondaryNavRight", "Gate types"},
    {"UI_TabPrimaryNavLeft", ""}, {"UI_TabPrimaryNavRight", "Camera down / up"},
    {"UI_PrimaryAction", "Place object"}, {"UI_SecondaryAction", "Rotate"},
    {"UI_DpadLeft", ""}, {"UI_DpadRight", "Undo / Redo"},
    {"UI_DpadUp", ""}, {"UI_DpadDown", "Size"},
    {"UI_Activities_AccessPause", "Tap: Save / Hold: Load"}, {"UI_Back", "Close editor"},
    {"UI_TertiaryAction", "Toggle snapping"}, {"UI_L3Click", ""}, {"UI_R3Click", "Snap angle - / +"},
    {"UI_SelectButton", "Hold: Clear route"},
}
local function editor_doc(n, now, cone_editor)
    local prompts = {}
    local i = 0
    while i < #actions do
        local pair = i == 0 and 0 or i == 2 and 1 or i == 6 and 2 or i == 8 and 3 or i == 13 and 4 or -1
        local skip = false
        -- The cone editor keeps the gate editor's buttons, minus gate-only ones.
        if cone_editor and pair >= 0 and pair ~= 1 and pair ~= 2 and pair ~= 4 then
            i += 1
            skip = true
        elseif cone_editor and i == 5 then
            skip = true
        end
        if not skip then
            local inputs = {actions[i + 1][1]}
            local caption = actions[i + 1][2]
            if pair >= 0 then
                table.insert(inputs, actions[i + 2][1])
                i += 1
                caption = actions[i + 1][2]
                if not cone_editor and n.rotating and i == 14 and n.route_object ~= 4 then inputs = {actions[14][1]} end
            end
            local dynamic = caption
            if i == 1 then dynamic = "Object: " .. RE.race_editor_object_name(n.route_object) end
            if i == 5 then dynamic = n.rotating and "Finish rotating" or "Rotate (5 deg)" end
            if i == 7 then dynamic = n.rotating and "Yaw - / +" or "Undo / Redo" end
            if i == 10 and n.editor_warning ~= "" then dynamic = n.route_finish and "Check route" or "Finish line required" end
            if i == 9 then
                dynamic = n.rotating and (n.editor_roll_axis and "Arrow up / down" or "Tilt up / down")
                    or "Size " .. tostring(math.round(n.cursor_width / 6 * 100)) .. "%"
            end
            if i == 12 then dynamic = n.route_snap and (n.arrow_height_snapped and "Snap ON: line locked" or "Snap ON") or "Snap OFF" end
            if i == 14 then
                dynamic = n.rotating and (n.route_object == 4 and (n.editor_roll_axis and "Reset / Switch tilt" or "Reset / Switch arrow") or "Reset orientation")
                    or "Placement snap: " .. tostring(math.floor(n.snap_degrees)) .. " deg"
            end
            if cone_editor then
                local cones = #n.settings.corners
                -- How long the edge to the next cone would be, so sides can be matched.
                if i == 4 and cones > 0 and n.cursor_valid then
                    local last = n.settings.corners[cones]
                    dynamic = string.format("Place cone (%.0f m)", math.sqrt((n.cursor.x - last.x) ^ 2 + (n.cursor.z - last.z) ^ 2))
                elseif i == 4 then dynamic = "Place cone" end
                if i == 12 then dynamic = n.route_snap and "Snap ON" or "Snap OFF" end
                if i == 7 then dynamic = "Undo / Redo cone" end
                if i == 3 then dynamic = "Camera height" end
                if i == 10 then dynamic = cones >= 3 and "Finish zone" or "Finish zone (3+ cones)" end
                if i == 11 then dynamic = "Close" end
                if i == 14 then dynamic = "Snap angle " .. tostring(math.floor(n.snap_degrees)) .. " deg" end
                if i == 15 then dynamic = "Hold: clear all" end
            end
            local prompt = {inputs = inputs, caption = dynamic}
            -- The hold rings: Select's clear, and (the builder) Start's save/load.
            if i == 15 then prompt.hold = n.clear_progress end
            if i == 10 and not cone_editor then prompt.hold = n.save_progress end
            table.insert(prompts, prompt)
        end
        i += 1
    end
    local editor = {prompts = prompts}
    if cone_editor then
        -- A title over the cone set's rows, in skate.'s accent: "TRICK ZONE - 4 CONES".
        local cones = #n.settings.corners
        editor.variant = "compact"
        editor.title = cones > 0 and string.format("TRICK ZONE  -  %d CONE%s", cones, cones == 1 and "" or "S") or "TRICK ZONE"
    else
        editor.variant = "builder"
        editor.title = "Deathrace builder"
        editor.info, editor.toast = race_editor_info(n, now)
    end
    if n.exit_confirm then
        editor.modal = {text = cone_editor and "STOP PLACING CONES?" or "LEAVE THE EDITOR?\nDraft kept locally. Save to share.",
                        actions = {{input = "UI_PrimaryAction", caption = "Leave editor"}, {input = "UI_Back", caption = "Keep editing"}}}
    end
    return editor
end

-- mode_world_markers: the points, the cursor, whoever is it and the tags, over the world.
local function markers_of(n, feed)
    local markers = {}
    -- Native arches already identify the route.
    if feed.route or feed.blind ~= "" or feed.results then return markers end
    local function mark(at, text)
        if #markers < 32 then table.insert(markers, {at = at, text = text, distance = feed.have_me}) end
    end
    for i, at in ipairs(feed.points) do
        local label = "CAPTURE " .. tostring(i)
        if i - 1 == feed.next_point then label = "NEXT: " .. label end
        mark(at, label)
    end
    -- R.E.S.K.A.T.E.'s preview cone already shows where the next one goes.
    if feed.placing and n.cursor_valid and not (n.settings.mode == "skate" and n.placing_corners) then mark(feed.cursor, "PLACE HERE") end
    for _, player in ipairs(feed.players) do
        if not player.self and player.it then mark(player.at, player.name .. (feed.infection and "  INFECTED" or "  IT")) end
    end
    for _, tag in ipairs(feed.tags) do
        if #tag.path > 0 then mark(tag.path[#tag.path // 2 + 1], "TAGGED") end
    end
    return markers
end

-- mode_hud: the whole HUD of the game mode on, or nil (the setup page and waiting card own setup).
-- Deathrace's board cells: his Race* widgets (RaceRank, RaceName, RaceTime sized to the column), a
-- time column of at least 320 px and room for "DNF  " before a capped clock.
local function race_cells(board, race)
    if race then
        board.rank_art, board.name_art, board.value_art, board.value_width, board.reserve = "RaceRank", "RaceName", "RaceTime", 320, "DNF  "
    end
    return board
end
function M.ui_game_hud(s, now)
    local n, feed = s.native, s.hud
    if not n or not n.active or not feed then return nil end
    local d = M.definitions[n.settings.mode]
    local st = n.state
    if not d or (not n.placing and (not st or st.phase == "setup")) then return nil end
    local mode = n.settings.mode
    local race, letters = mode == "race", mode == "skate"
    local cone_editor = feed.placing and letters and n.placing_corners -- R.E.S.K.A.T.E.'s trick-zone cones
    local placing_layout = feed.placing and (race or cone_editor)
    local results = feed.results
    local phase = st and st.phase or "setup"
    local playing = phase == "playing"
    local hud = {theme = mode, layout = letters and "bottom" or "side", score_width = letters and 900 or 480}
    -- The title frame: R.E.S.K.A.T.E. has none (its trick card says whose turn it is).
    if letters then
        hud.header = {title = "", art = d.art}
    elseif race then
        hud.header = {title = "DEATHRACE", art = d.art, offset = {16, -6}, icon_size = 96, frame_width = 704}
    else
        local status = feed.placing and feed.hint or feed.status
        if feed.blind == "" and feed.heat >= 0 then status = feed.status .. "  |  " .. feed.heat_label end
        hud.header = {title = d.name, art = d.art, status = status}
    end
    if feed.blind ~= "" then hud.blackout = {text = "Hiding time: " .. feed.blind} end
    if race and n.missed_gate > 0 then
        hud.warning = {text = "MISSED GATE " .. tostring(n.missed_gate) .. (n.recovering and " - RETURNING TO CHECKPOINT" or " - CHECKPOINT RECOVERY"),
                       art = "RaceWarning"}
    end
    local best, mine = 0, 0
    if st then
        for _, standing in ipairs(st.standings) do
            best = math.max(best, standing.score)
            if standing.player == n["local"] then mine = standing.score end
        end
    end
    if not race and not letters and not placing_layout then
        hud.counters = {"LEADER   " .. tostring(best), "SCORE   " .. tostring(mine)}
    end
    -- The bottom clock: the game's time (R.E.S.K.A.T.E.'s turn); Deathrace has its own clocks.
    if not race and feed.clock ~= "" and not placing_layout then
        hud.clock = {remaining_ms = st and st.remaining_ms or 0, total_ms = (letters and n.settings.turn_s or n.settings.duration_s) * 1000,
                     sampled_ms = n.state_sampled_ms, ticking = phase == "playing" or phase == "countdown"}
    end
    if letters and not placing_layout and not results then
        -- R.E.S.K.A.T.E.: whose turn it is and the trick with its stick picture, laid out as Skate 3's S.K.A.T.E.
        local my_turn = not st or not M.nz(st.turn) or st.turn == n["local"]
        local up = "SOMEONE"
        if st then
            for _, player in ipairs(n.names) do
                if player.id == st.turn then up = player.name end
            end
        end
        up = string.upper(up)
        local kinds = n.settings.trick_kinds
        local only = kinds == M.trick_flips and "  -  FLIPS ONLY" or kinds == M.trick_grinds and "  -  GRINDS ONLY"
            or kinds == M.trick_grabs and "  -  GRABS ONLY" or ""
        local copying = st ~= nil and st.trick ~= ""
        -- What the player just did, while it is fresh ("LANDED: Heelflip 180"), else whose turn it is.
        local caption = copying and (my_turn and "COPY THIS" or up .. " IS COPYING") or (my_turn and "SET A TRICK" .. only or up .. " IS SETTING" .. only)
        local line = feed.line
        if my_turn and (M.starts_with(line, "Landed") or M.starts_with(line, "Missed") or M.starts_with(line, "Trick copied") or
            M.starts_with(line, "Failed") or M.starts_with(line, "Not a valid")) then
            caption = line
        elseif my_turn and feed.warning ~= "" then
            caption = feed.warning -- out of the trick zone
        end
        local image = copying and flick_image(feed.trick_steps) or ""
        if M.flick_test() and copying then image = "UI/ReSkate/OneUp/img_OneUp_Blue_1024" end -- diagnostics: an image this HUD draws
        hud.card = {caption = string.upper(caption), title = copying and st.trick or "", image = image}
        -- Already been done: the newest five tricks set this game.
        if #feed.done_tricks > 0 then
            local items = {}
            for i = #feed.done_tricks, 1, -1 do table.insert(items, feed.done_tricks[i]) end
            hud.list = {caption = "ALREADY BEEN DONE", items = items}
        end
        -- The callout: shown for 2.5 s after each new one.
        hud.callout = {text = feed.callout, serial = feed.callout_serial, ms = 2500, style = "neon"}
    end
    -- The 3-2-1: the native Throwdown intro while more than three seconds are left, then the count.
    if st and phase == "countdown" then
        if st.remaining_ms > 3000 then
            hud.intro = {title = d.name, art_key = mode, until_ms = n.state_sampled_ms + st.remaining_ms - 3000,
                         rules = race and "Pass Required gates in order, then the Finish gate.\nD-pad Up: return to your previous gate." or d.description}
        end
        hud.countdown = {remaining_ms = st.remaining_ms, total_ms = 3000, sampled_ms = n.state_sampled_ms, ticking = true}
    end
    -- The compass: the next Required gate on the native compass strip.
    if race and not n.placing and st then
        local next = RN.race_compass_gate(n.settings, st, n["local"])
        if next then
            hud.compass = {at = n.settings.points[next + 1],
                           art = (n.settings.race_finish and next + 1 == #n.settings.points) and "UI/ReSkate/Throwdowns/img_FinishGateCompass"
                               or "UI/ReSkate/Throwdowns/img_GateCompass"}
        end
    end
    hud.markers = markers_of(n, feed)
    if placing_layout then hud.editor = editor_doc(n, now, cone_editor) end
    local columns = {"POS", "NAME", race and "TIME" or letters and "LETTERS" or "SCORE"}
    if st and playing and not results and not feed.placing then
        local rows, local_place = board_rows(n, feed, now)
        hud.board = race_cells({title = "LEADERBOARD", columns = columns, style = letters and "outlined" or "plain", rows = rows}, race)
        if race then
            -- Deathrace's top left: the position medal, the race clock, the time to beat and the
            -- Required gates cleared.
            hud.position = {place = local_place, medal = local_place == 1 and "gold" or local_place == 2 and "silver" or local_place == 3 and "bronze" or "white",
                            art = "RacePosition"}
            hud.timer_art = "RaceElapsed"
            local limit = n.settings.duration_s * 1000
            hud.timers = {{caption = "", clock = {remaining_ms = math.min(limit, st.remaining_ms), total_ms = limit, sampled_ms = n.state_sampled_ms, ticking = true}},
                          {caption = "TIME TO BEAT", clock = {remaining_ms = limit, total_ms = limit, ticking = false}}}
            local cleared = 0
            for _, row in ipairs(st.standings) do
                if row.player == n["local"] then cleared = M.mandatory_gates(n.settings, math.max(0, row.score)) end
            end
            hud.counters = {"REQUIRED " .. tostring(cleared) .. " / " .. tostring(M.mandatory_gates(n.settings, #n.settings.points))}
        end
    end
    if results then
        local rows = board_rows(n, feed, now)
        hud.board = race_cells({columns = columns}, race)
        -- R.E.S.K.A.T.E.'s results as its board: outlined, the red glow on tinted letters. Deathrace's
        -- heading is its own (his RaceResultsHeading, a 608 px title).
        hud.results = {title = d.name .. " RESULTS", heading_art = race and "RaceResultsHeading" or nil, title_width = race and 608 or nil,
                       style = letters and "outlined" or "plain", caption = columns[3], rows = rows,
                       notice = feed.winner == "" and (race and "NO FINISHERS / DNF" or "MATCH COMPLETE") or feed.winner .. " WINS!"}
    end
    return hud
end

return nil
