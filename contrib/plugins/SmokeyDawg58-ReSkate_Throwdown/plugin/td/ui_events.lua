-- What the player does in SmokeyDawg58's Throwdowns UI, as the throwdown kit reports it (the
-- `throwdown_ui` event), mapped onto his game layer the way his one_up_menu.cpp and the C++ bridge
-- (mode_bridge.cpp) did: the card's open (his mode-open: `new`, then `setup`), the setup page's rows
-- and buttons (his native_setup_capabilities' commands and mode-setup-area / mode-setup-join), the
-- start flag (his tick_flag_placement's accept_race_start / accept_native_start_flag), the waiting
-- card's Start and Leave (flag-wait-start / flag-wait-leave), the panel's Quit (mode-panel-quit), a
-- Join on another player's flag (join_native_flag_offer) and the route dialog's answers. 1-UP's go to
-- td/ui_oneup.lua. Also his overlays in Lua: the route library dialog (race_routes_overlay.cpp), the
-- builder's gate numbers (race_editor_numbers.inl) and rotation gizmo (race_rotation_gizmo.inl).
local M = require("td/core")
local RR = require("td/h/race_route")
local RE = require("td/h/race_editor")

local function popup_error(s, result)
    if type(result) == "string" and M.starts_with(result, "error:") then
        M.popup(s, string.sub(result, 8))
        reskate.log("Throwdown: " .. result, "warn")
        return true
    end
    return false
end
-- discard_mode_setup(): the open draft goes before another mode's card opens.
local function discard_mode_setup(s)
    local g = s.game
    if not g then return true end
    if not g.leading or (g.state and g.state.phase ~= "setup" and g.state.phase ~= "results") then return false end
    return not M.starts_with(M.command("stop", {}), "error:")
end
-- A setup row's value as his command took it: an unsigned number.
local function whole(text)
    local n = tonumber(text or "")
    return n and math.round(n) or nil
end
-- The setup page's rows, as his official_setup sent each changed slider and choice.
local function setup_row(s, id, value)
    local g = s.game
    if not g or not g.leading or value == nil then return end
    local mode = g.settings.mode
    if id == "players" then
        if value ~= g.capacity then M.command("players", {tostring(value)}) end
    elseif id == "timer" then
        if mode == "skate" then
            if value ~= g.settings.turn_s then M.command("turn", {tostring(value)}) end
        elseif value ~= g.settings.duration_s then
            M.command("time", {tostring(value)})
        end
    elseif id == "hide_time" then
        if value ~= g.settings.turn_s then M.command("turn", {tostring(value)}) end
    elseif id == "letters" then
        if value ~= g.settings.strikes then M.command("strikes", {tostring(value)}) end
    elseif id == "tricks" then
        local word = M.trick_words[value + 1]
        if word then M.command("tricks", {word}) end
    elseif id == "zone" then
        if value == 5 then M.command("zone", {"custom"})
        elseif M.zone_sizes[value + 1] then M.command("zone", {tostring(M.zone_sizes[value + 1])}) end
    end
end

-- His mode-setup-area / mode-setup-join: the native setup is closed first; once its registration is
-- gone the command runs (s.mode_start_game, s.mode_setup_command, s.mode_setup_argument).
local pending = nil -- {game, command, argument, until}
local setup_back_game = 0 -- a setup page's Back ends its registration too: that flag_left is no cancel
function M.ui_tick(s, now)
    if not pending then return end
    local g = s.game
    if now >= pending.until_ms or not g or g.id ~= pending.game or (g.state and g.state.phase ~= "setup") then
        pending = nil
        return
    end
    if M.placement("race_owned") or M.placement("mode_owned") then return end
    local result
    if pending.command == "join" then
        -- The native page reserved our unstarted draft. Discard that draft before joining the offer
        -- selected on the page.
        local available = false
        for _, offer in ipairs(s.hud.offers or {}) do
            if not offer.own and offer.open and offer.id == pending.argument then available = true end
        end
        if not available then result = "error: that challenge is no longer accepting players."
        else
            result = M.command("stop", {})
            if not M.starts_with(result, "error:") then result = M.command("join", {pending.argument}) end
        end
    else
        result = M.command("place", {pending.argument})
    end
    reskate.log("Throwdown native setup action: " .. tostring(result), "info")
    popup_error(s, result)
    pending = nil
end

function M.on_throwdown_ui(e)
    local s = M.state()
    local action, mode, args = e.action or "", e.mode or "", e.args or {}
    if action == "dialog" then return M.on_route_dialog(s, args) end
    if mode == "oneup" or (action == "quit" and mode == "" and not s.game and M.nz(M.one_up_match())) then
        return M.on_oneup_ui(e)
    end
    local now = M.now_ms()
    if action == "open" then
        -- His mode-open: the draft of another mode (or a finished one) goes, a new one is made with
        -- the game id the kit's card chose, and `setup` follows (the kit opened the native setup).
        local game = tonumber(args[1] or "") or 0
        local g = s.game
        if g and (g.settings.mode ~= mode or (g.state and g.state.phase == "results")) then
            if not discard_mode_setup(s) then
                popup_error(s, "error: quit the active challenge first.")
                reskate.throwdowns.flag.leave()
                return
            end
        end
        local result = ""
        if not s.game then
            result = M.command("new", {mode, s.world, tostring(game)})
        elseif s.game.leading and not s.game.referee and s.game.id ~= game then
            -- PORT: his card reopened the same draft under its own game id; the kit's card makes a
            -- new one each time, and the draft takes it (its offer is announced again under it).
            s.game.id = game
            M.settings_changed(s.game)
        end
        if not M.starts_with(result, "error:") then result = M.command("setup", {"from-kit"}) end
        if popup_error(s, result) then reskate.throwdowns.flag.leave() end
    elseif action == "setup_row" then
        setup_row(s, args[1], whole(args[2]))
    elseif action == "setup_button" then
        local g = s.game
        local id = args[1] or ""
        if g and g.leading and (not g.state or g.state.phase == "setup") then
            local command, argument
            if id == "area" then command, argument = "place", "circle"
            elseif id == "capture-spots" then command, argument = "place", "points"
            elseif M.starts_with(id, "join-") then command, argument = "join", string.sub(id, 6) end
            if command then
                pending = {game = g.id, command = command, argument = argument, until_ms = now + 15000}
                setup_back_game = g.id
                reskate.throwdowns.flag.leave() -- close_race_setup_for_start
            end
        end
    elseif action == "setup_confirm" then
        -- The page's Players and Timer as Confirm left them.
        setup_row(s, "players", whole(args[1]))
        setup_row(s, "timer", whole(args[2]))
    elseif action == "setup_back" then
        setup_back_game = tonumber(args[1] or "") or 0
    elseif action == "flag_placed" then
        -- The native start flag: Deathrace's start gate, any other mode's flag.
        local start = {s.world, args[1] or "", args[2] or "", args[3] or "", args[4] or "", args[5] or ""}
        popup_error(s, M.on_ui_command(mode == "race" and "race-start" or "start-flag", start))
    elseif action == "flag_left" then
        -- observe_flag_exit(cancelling): the native placement was backed out of, so the game quits.
        local game = tonumber(args[1] or "") or 0
        if game ~= 0 and game ~= setup_back_game and s.game and s.game.id == game then M.request_native_quit(s.world, game) end
    elseif action == "start" then
        local g = s.game
        if g and g.leading then M.request_native_start(s.world, tonumber(args[1] or "") or 0) end
    elseif action == "leave" then
        M.request_native_quit(s.world, tonumber(args[1] or "") or 0)
    elseif action == "quit" then
        -- mode-panel-quit / the pause menu's Quit.
        if s.game then M.command("quit", {}) end
    elseif action == "join" then
        -- join_native_flag_offer after the kit's adopt: {flag id, leader, game}.
        popup_error(s, M.on_ui_command("join-flag", {args[2] or "", args[3] or "", "1"}))
    elseif action == "panel_command" then
        -- "rewind": his D-pad Up, which placing.lua's checkpoint_back_press reads itself.
    end
end

-- ---- the route library dialog (race_routes_overlay.cpp draw_race_routes) -----------------------------------
local function route_map_title(map)
    local title = string.match(map, "([^/\\]*)$") or map
    for _, prefix in ipairs({"dingolevel_reskate_", "dingolevel_"}) do
        if M.starts_with(title, prefix) then
            title = string.sub(title, #prefix + 1)
            break
        end
    end
    return (string.gsub(title, "_", " "))
end
local shown = nil -- {id, serial, world, game, key}
local function dialog_spec(n)
    local renaming = n.route_dialog == 3
    local saving = n.route_dialog == 1 or renaming
    local message = "Map: " .. route_map_title(n.route_map)
    local error_text = n.route_dialog_error ~= "" and "\n\n" .. n.route_dialog_error or ""
    if saving then
        if not renaming then message ..= string.format("\n%d Required gates + Finish", M.mandatory_gates(n.settings, #n.settings.points)) end
        return renaming and "route-rename" or "route-save", {
            title = renaming and "RENAME ROUTE" or "SAVE DEATHRACE ROUTE", message = message .. "\nRoute name" .. error_text,
            field = {text = n.route_name, max = 64},
            buttons = {{id = renaming and "rename-save" or "save", label = renaming and "Save name" or "Save route"}, {id = "cancel", label = "Cancel"}},
        }
    end
    local rows = {}
    for _, route in ipairs(n.saved_routes) do
        if route.map == n.route_map and #rows < 64 then
            -- PORT: his rows had a folder button (Show JSON file in folder); there is no plugin API for it.
            table.insert(rows, {text = route.name, sub = string.format("%d Required + Finish  |  %d objects", route.required, math.max(0, route.objects)),
                                buttons = {"rename"}})
        end
    end
    return "route-load", {
        title = "LOAD DEATHRACE ROUTE", message = message .. "\nChoose a saved route. Only routes saved on this map are shown." .. error_text,
        list = {rows = rows, empty = "No saved routes yet. Build your course, then tap Start to name and save it."},
        buttons = {{id = "cancel", label = "Back to builder"}}, file = {label = "Load .json file", filter = "*.json"},
    }
end
function M.route_dialog_tick(s)
    local n = s.native
    local open = n and n.active and n.leading and n.placing and n.route_dialog ~= 0
    if not open then
        if shown then
            pcall(reskate.ui.close_dialog, shown.id)
            shown = nil
        end
        return
    end
    local id, spec = dialog_spec(n)
    local key = reskate.json.encode(spec)
    local fresh = not shown or shown.id ~= id or shown.serial ~= n.route_dialog_serial or shown.world ~= n.world or shown.game ~= n.game
    if fresh and shown then pcall(reskate.ui.close_dialog, shown.id) end
    if fresh or shown.key ~= key then
        local ok, done, why = pcall(reskate.ui.dialog, id, spec)
        if not ok or not done then reskate.log("Deathrace routes: the dialog did not open: " .. tostring(ok and why or done), "warn") end
        shown = {id = id, serial = n.route_dialog_serial, world = n.world, game = n.game, key = key}
    end
end
-- The dialog's answers: {id, button, text, row, file_text}, sent as his buttons did.
function M.on_route_dialog(s, args)
    local n = s.native
    if not shown or args[1] ~= shown.id or not n then return end
    local button, text, row = args[2] or "", args[3] or "", tonumber(args[4] or "") or 0
    local function send(action, argument) popup_error(s, M.on_ui_command("route-" .. action, {argument or ""})) end
    if button == "cancel" then return send("cancel") end
    if shown.id == "route-save" and button == "save" then
        if text ~= "" then send("save", text) end
    elseif shown.id == "route-rename" and button == "rename-save" then
        if text ~= "" then send("rename-save", text) end
    elseif shown.id == "route-load" then
        local routes = {}
        for _, route in ipairs(n.saved_routes) do
            if route.map == n.route_map then table.insert(routes, route) end
        end
        local route = routes[row]
        if button == "row" and route then send("load", tostring(route.id))
        elseif button == "rename" and route then send("rename", tostring(route.id))
        elseif button == "file" then send("import", args[5] or "")
        elseif button == "file_error" then s.route_dialog_error = text end
    end
end

-- ---- the builder's world guides (race_editor_numbers.inl, race_rotation_gizmo.inl) ------------------------
local function editor_open(n, focus)
    return n and n.active and n.placing and n.settings.mode == "race" and not n.exit_confirm and not focus.interface_open
end
local visual = RE.RaceRotationVisual.new()
local visual_key = ""
local function colour(r, g, b, a) return string.format("#%02X%02X%02X%02X", r, g, b, a) end
function M.draw(d)
    local s = M.state()
    local n = s.native
    local focus = reskate.input.focus()
    -- PORT: his guides also hid while the native match panel was open; no plugin API says so.
    if not editor_open(n, focus) then
        visual:reset()
        return
    end
    local display = d:size()
    if display.x <= 0 or display.y <= 0 then return end
    local scale = math.clamp(display.y / 1080, .75, 3)
    -- draw_race_editor_numbers: each gate's number over its top edge, in a dark box.
    if n.leading then
        local font = 24 * scale
        for i = 1, #n.settings.points - 1 do
            local text = RE.race_editor_gate_number(n.settings, i)
            if text ~= "" then
                local at = d:world_to_screen(RE.race_editor_gate_number_position(n.settings, i))
                if at and at.z >= .5 and at.z <= 350 and at.x >= 0 and at.x <= display.x and at.y >= 0 and at.y <= display.y then
                    -- PORT: his box was the font's measured text; here an estimate of its width.
                    local w, h = #text * font * .55, font
                    local left = vector.create(at.x - w * .5, at.y - h * .5, 0)
                    local padding = 7 * scale
                    d:rect(left - vector.create(padding, padding, 0), left + vector.create(w + padding, h + padding, 0),
                           {colour = colour(10, 13, 18, 210), fill = true, rounding = 4 * scale})
                    local tint = (n.settings.race_finish and i + 1 == #n.settings.points) and colour(255, 115, 115, 255) or colour(255, 255, 255, 255)
                    d:text(left, text, {colour = tint, size = font})
                end
            end
        end
    end
    -- draw_race_rotation: the active rotation tool's three rings about the gate's centre.
    if not (n.rotating and n.cursor_valid) then
        visual:reset()
        return
    end
    local key = tostring(n.world) .. ":" .. tostring(n.game) .. ":" .. tostring(n.route_object)
    if key ~= visual_key then
        visual:reset()
        visual_key = key
    end
    local target = RE.RaceRotationPose.new()
    target.at, target.yaw, target.pitch, target.width = n.cursor, n.cursor_yaw, n.cursor_pitch, n.cursor_width
    target.roll = n.route_object == 4 and n.cursor_roll or 0
    local pose = visual:update(target, M.now_ms())
    local camera = reskate.camera.get()
    if not camera or not (camera.fov > 1 and camera.fov < 175) then return end
    local axes = RR.race_gate_axes(pose.yaw, pose.pitch, pose.roll)
    local center = pose.at
    if n.route_object ~= 4 then center = center + axes.up * (1.70747 * pose.width / 6) end
    local origin = d:world_to_screen(center)
    if not origin or not (origin.z > .1) then return end
    local focal = display.y / (2 * math.tan(camera.fov * 3.14159265 / 360))
    local pixels = 90 * scale
    local radius = pixels * origin.z / focal
    local colours = {colour(244, 94, 103, 235), colour(111, 224, 131, 235), colour(85, 159, 255, 220)}
    local first = {axes.up, vector.create(1, 0, 0), axes.right}
    local second = {axes.forward, vector.create(0, 0, 1), axes.up}
    d:circle(vector.create(origin.x, origin.y, 0), pixels * 1.18, {colour = colour(245, 245, 245, 220), thickness = 1.5 * scale})
    for ring = 1, 3 do
        local previous = nil
        for segment = 0, 96 do
            local angle = segment * 2 * 3.14159265 / 96
            local point = center + (first[ring] * math.cos(angle) + second[ring] * math.sin(angle)) * radius
            if previous then d:world_line(previous, point, {colour = colours[ring], thickness = 2 * scale}) end
            previous = point
        end
        local axis = ring == 1 and axes.right or ring == 2 and vector.create(0, 1, 0) or axes.forward
        local tip = d:world_to_screen(center + axis * radius)
        if tip then d:text(vector.create(tip.x + 5 * scale, tip.y - 6 * scale, 0), ring == 1 and "X" or ring == 2 and "Y" or "Z", {colour = colours[ring]}) end
    end
    d:circle(vector.create(origin.x, origin.y, 0), 3 * scale, {colour = colour(255, 255, 255, 235), fill = true})
end

return nil
