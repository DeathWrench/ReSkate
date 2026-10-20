-- SmokeyDawg58's placement editor (game_modes.cpp lines 1476-1877): the cursor where the next
-- thing goes, and placing the area, the cones or the points (Deathrace's route editor) with the
-- controller, the keyboard, the mouse wheel and the free camera.
local M = require("td/core")
local RR = require("td/h/race_route")
local RE = require("td/h/race_editor")
local RA = require("td/h/race_arrow_placement")

-- game_modes.cpp:1445.
local pad_up, pad_down, pad_left, pad_right = 0x1, 0x2, 0x4, 0x8

-- Windows virtual keys (WinUser.h) and WHEEL_DELTA.
local VK_LBUTTON, VK_BACK, VK_RETURN, VK_ESCAPE = 0x01, 0x08, 0x0D, 0x1B
local VK_PRIOR, VK_NEXT, VK_END = 0x21, 0x22, 0x23
local VK_OEM_4, VK_OEM_6 = 0xDB, 0xDD
local KEY_F, KEY_G, KEY_R, KEY_X, KEY_Z = 0x46, 0x47, 0x52, 0x58, 0x5A
local WHEEL_DELTA = 120

local band, bor, bnot = bit32.band, bit32.bor, bit32.bnot

local function hypot(a: number, b: number): number
    return math.sqrt(a * a + b * b)
end

-- PORT: his queue_world_ray / tick_local_world_rays / world_ray (a ray queued for the client
-- collision thread, read back with cast / available / hit / at / when) is the plugin API's
-- synchronous reskate.world.raycast(from, to): the ray is always cast, the world always
-- available, and the hit always fresh.
local function world_ray(origin, direction, length)
    local at = reskate.world.raycast(origin, origin + direction * length)
    return {cast = true, available = true, hit = at ~= nil, at = at or vector.zero, when = M.now_ms()}
end

-- `Vec3 cursor`: where the next thing goes, on the real ground: where the free camera looks, or
-- under the skater.
function M.update_cursor(s)
    s.arrow_preview_ready = false
    if s.free_place then
        -- PORT: client_free_camera_view() (the selected free camera's pointer) and
        -- latest_game_view() (the published view, its camera and world matrix) are one
        -- reskate.camera.get(), whose `free` is true when the selected free camera is the view.
        -- So the second check below never fails, and a published view other than the free
        -- camera says "waiting for selected freecam" instead of "published view differs from
        -- selected freecam". There is no camera pointer: the diagnostic gets 0.
        local camera_view = reskate.camera.get()
        local camera = camera_view ~= nil and camera_view.free
        if not camera then
            s.cursor_ok = false
            M.cursor_diagnostic(s, "waiting for selected freecam")
            return
        end
        local view = camera_view
        if not view or not view.free then
            s.cursor_ok = false
            M.cursor_diagnostic(s, view and "published view differs from selected freecam" or "waiting for a fresh camera view", 0)
            return
        end
        -- m[12..14], -m[8..10], m[0..2], m[4..6]: the API's position, forward, right, up.
        local origin, forward = M.V(view.position), M.V(view.forward)
        local right, up = M.V(view.right), M.V(view.up)
        s.cursor_pitch = math.atan2(forward.y, hypot(forward.x, forward.z)) * 180 / 3.14159265
        if s.game and s.game.settings.mode == "race" and s.race_object == 4 then
            local aim = RA.aim_race_arrow(origin, forward, right, up, M.cast_arrow_ray)
            s.cursor = aim.at
            s.cursor_ok = aim.valid
            s.arrow_surface = aim.surface
            s.arrow_preview_ready = true
            if hypot(forward.x, forward.z) > .05 then
                s.cursor_heading = math.atan2(forward.x, forward.z) * 180 / 3.14159265
            end
            local floor = aim.surface.contact and aim.surface.normal.y >= .7
            local flat = s.arrow_floor_alignment:update(floor, forward.y, s.editor_manual_rotation or s.editor_rotating)
            if aim.surface.contact and aim.align_surface and (not floor or flat) then
                local angles = RA.race_arrow_surface_angles(aim.surface.normal)
                if math.abs(aim.surface.normal.y) < .98 then s.cursor_heading = angles[1] - 180 end
                s.cursor_pitch = angles[2]
            elseif floor then
                s.cursor_pitch = 0
            end
            return
        end
        local hit = world_ray(origin, forward, 400.0)
        s.cursor_ok = hit.hit and M.now_ms() - hit.when < 500
        if s.cursor_ok then s.cursor = hit.at end
        if s.game and s.game.settings.mode == "race" then
            -- Gates can float at the aimed depth; only a nearby direct surface
            -- hit mounts them. Distant buildings do not steal the air cursor.
            local distance = 16
            if s.cursor_ok then distance = vector.magnitude(hit.at - origin) end
            if not s.cursor_ok or distance > 30 then s.cursor = origin + forward * 16 end
            s.cursor_ok = true
        end
        M.cursor_diagnostic(s, not hit.cast and "waiting for client ray dispatch" or not hit.available and "client collision world unavailable" or
            s.cursor_ok and "ready" or "aim does not hit a surface", 0, origin, forward)
        -- The gate faces the way the camera looks.
        if hypot(forward.x, forward.z) > 0.05 then s.cursor_heading = math.atan2(forward.x, forward.z) * 180 / 3.14159265 end
        return
    end
    local hit = world_ray(vector.create(s.position.x, s.position.y + 0.5, s.position.z), vector.create(0, -1, 0), 6.0)
    s.cursor = s.position
    if hit.hit and M.now_ms() - hit.when < 500 and hypot(hit.at.x - s.position.x, hit.at.z - s.position.z) < 2.0 then
        s.cursor = vector.create(s.cursor.x, hit.at.y, s.cursor.z)
    end
    s.cursor_heading = s.heading
    s.cursor_pitch = 0
    s.cursor_ok = true
    if s.game and s.game.settings.mode == "race" and s.race_object == 4 then
        s.arrow_preview_ready = true
        -- PORT: without a hit his `at` was whatever the ray left there; here it is the origin.
        s.arrow_surface = {contact = hit.hit and hit.available and M.now_ms() - hit.when < 500, at = hit.at, normal = vector.create(0, 1, 0)}
        s.cursor_pitch = -90
    end
end

-- Placing: D-pad or keys, read on the game thread while ReSkate's menu is closed.
function M.run_placing(s, now)
    if s.placing ~= "none" and (not s.game or not s.game.leading or s.game.referee ~= nil or (not s.skater and not s.free_place)) then
        s.placing = "none"
    end
    -- While placing, the D-pad is ours: skate. would open its replay editor and quick menus. It
    -- stays ours after placing ends until it is let go: the D-pad Down that drops the finish must
    -- not reach skate. still held (its replay editor takes the camera).
    local dpad = bor(pad_up, pad_down, pad_left, pad_right, 0x10) -- also retain editor Start until release
    local still_held = 0
    if s.placing ~= "none" then
        s.dpad_release = true
    elseif s.dpad_release then
        local pad = reskate.input.pad_bits()
        still_held = if pad ~= nil then band(pad, dpad) else 0
        if still_held == 0 then s.dpad_release = false end
    end
    local race_me = if s.game then M.standing(s.game, M.self_id(s)) else nil
    local race_playing = s.game ~= nil and s.game.settings.mode == "race" and M.playing(s.game) and race_me ~= nil and
        not race_me.out and race_me.score >= 0 and race_me.score < #s.game.settings.points
    local back_focus = reskate.input.focus()
    local back_allowed = race_playing and back_focus.gameplay and not back_focus.interface_open and back_focus.focused
    -- PORT: his read here is the bypass sample (DingoSDKOverlayReadControllerInput(&pad, true)),
    -- the pad before the menu masks it; reskate.input.pad_bits() is the masked one.
    local back_pad = reskate.input.pad_bits()
    local back_held = back_pad ~= nil and band(back_pad, pad_up) ~= 0
    if s.checkpoint_back_press:update(back_held, back_allowed) then
        local g = s.game
        local me = M.standing(g, M.self_id(s))
        if me and not me.out and me.score >= 0 and me.score < #g.settings.points then
            local target = g.checkpoint_fallback:step_back(g.settings, me.score)
            M.recovery("reset")
            if not g.recovery_pending and not g.recovery_grace:pending() then
                g.recovery_speed = g.recovery_speed_guard:limit(g.momentum:before_bail(now), now)
            end
            g.recovery_grace:reset()
            g.recovery_pending = true
            g.recovery_to_safe = false
            g.last_safe_spot:reset()
            g.recovery_queued = 0
            g.have_along = false
            g.gate_crossed = false
            g.miss_pending = false
            M.popup(s, if target == 0 then "Back to the start"
                else string.format("Back to Required gate %d", M.mandatory_gates(g.settings, target + 1)))
        end
    end
    s.hidden_buttons = if s.placing ~= "none" or s.dpad_release then dpad elseif back_allowed then pad_up else 0
    M.game_buttons(s)
    if s.placing == "none" then
        s.held_buttons = band(still_held, 0xFFFF)
        M.game_buttons(s)
    end
    -- Placing with the free camera, like skate.'s quick drop: on while placing, off after.
    local want_freecam = s.placing ~= "none" and s.free_place
    M.set_placement_flight(s, want_freecam)
    -- The sticks fly the camera, so the skater does not roll off meanwhile.
    if want_freecam or M.seeker_blind(s) or M.skate_watching(s) then
        s.pause_input = true
        M.game_buttons(s)
    end
    local free_view = reskate.camera.get()
    local request = s.placement_camera:update(want_freecam, free_view ~= nil and free_view.free, now)
    if request ~= nil then reskate.camera.free(request) end
    if want_freecam ~= s.freecam_requested then
        s.freecam_requested = want_freecam
    end
    if s.placing == "none" then return end
    M.update_cursor(s)
    if s.editor_rotating and s.game.settings.mode == "race" then
        s.cursor = s.rotation_pivot
        s.cursor_ok = s.editor_angles_ready
    end
    local g = s.game
    local seconds = if s.placing_tick ~= 0 and now > s.placing_tick then math.min(0.1, (now - s.placing_tick) / 1000.0) else 0.0
    s.placing_tick = now
    local pad = reskate.input.pad_bits()
    local buttons = if pad ~= nil then pad else 0
    local pressed = band(buttons, bnot(s.pad_previous))
    s.pad_previous = buttons
    s.held_buttons = band(buttons, bor(pad_up, pad_down, pad_left, pad_right))
    M.game_buttons(s)
    local function held(key) return reskate.input.key(key) end -- past the pause while the free camera flies
    -- Mouse and keyboard work as well as the D-pad: with the free camera, left click drops (the
    -- right button is the camera's look) and F finishes; the wheel turns a gate or sizes a circle.
    local mouse = s.free_place
    local keys = {held(VK_RETURN) or (mouse and held(VK_LBUTTON)), held(VK_BACK), held(VK_END) or (mouse and held(KEY_F)), held(VK_ESCAPE)}
    local wheel = reskate.input.wheel() -- only gathered while the free camera flies
    local notches = wheel / WHEEL_DELTA
    local struck = {false, false, false, false}
    for i = 1, #keys do struck[i] = keys[i] and not s.keys_previous[i] end
    s.keys_previous = keys
    if s.route_dialog ~= 0 then
        s.route_input_release:arm()
        s.save_hold:update(false, false, now)
        s.editor_presses:suppress()
        return
    end
    -- The UI intentionally masks its controller presses from gameplay. That
    -- filtered zero is not a physical release: inspect the bypass sample until
    -- the menu is gone AND its confirm/cancel controls have actually come up.
    -- PORT: the bypass sample is not in the plugin API: reskate.input.pad_bits() is the masked pad.
    local route_pad = reskate.input.pad_bits()
    local any_key = keys[1] or keys[2] or keys[3] or keys[4]
    local route_focus = reskate.input.focus()
    if s.route_input_release:blocked(if route_pad ~= nil then route_pad else 0, any_key, route_focus.interface_open or not route_focus.focused) then
        s.save_hold:update(false, false, now)
        s.clear_hold:update(false, false, now)
        s.editor_presses:suppress()
        return
    end
    -- Presses meant for ReSkate's menu, the chat or another window do nothing here.
    local window = reskate.input.focus()
    local focus = not window.interface_open and window.focused
    if not focus then
        s.clear_hold:update(false, false, now)
        s.save_hold:update(false, false, now)
        s.editor_presses:suppress()
        s.rotate_key_previous = held(KEY_R)
        return
    end
    local close = band(pressed, 0x2000) ~= 0 or struck[4]
    -- R.E.S.K.A.T.E.'s cones use the Deathrace gate editor's controls: A place, D-pad left / right
    -- undo and redo, Start done, B close (confirmed), hold Select clear all.
    local cone_editor = g.settings.mode == "skate" and s.placing == "corners"
    -- `goto editor_continue` becomes `closing = false`.
    local closing = true
    if (g.settings.mode == "race" or cone_editor) and s.editor_exit_confirm then
        if close then
            s.editor_exit_confirm = false
            return
        end
        if not (band(pressed, M.pad_a) ~= 0) and not struck[1] then return end
        s.editor_exit_confirm = false
    elseif close and (g.settings.mode == "race" or cone_editor) then
        s.editor_exit_confirm = true
        s.clear_hold = RR.RaceClearHold.new()
        return
    elseif not close then
        closing = false
    end
    if closing then -- Confirmed B / Escape: retain the draft and release input.
        s.placing = "none"
        s.cursor_ok = false
        M.set_placement_flight(s, false)
        -- overlay::pause_game_input(false): nothing (the pause lapses by itself).
        if g.settings.mode == "race" and g.native_lobby then
            M.placement("left")
            g.native_flag_placed = false
            s.race_resume_editor = false
        end
        if g.settings.mode == "race" then M.end_game(s, "") end
        if cone_editor then
            M.notice(s, if #g.settings.corners >= 3 then string.format("Trick zone set: %d cones.", #g.settings.corners)
                else "Fewer than 3 cones: tricks count anywhere.")
        else
            M.popup(s, "Placement closed. Your draft is kept; open Throwdowns to continue.")
        end
        return
    end
    -- editor_continue:
    local race_editor = s.placing == "points" and g.settings.mode == "race"
    -- The cone editor follows the gate editor: D-pad left / right undo and redo (Backspace holds Clear All).
    local back
    if cone_editor then
        back = band(pressed, pad_left) ~= 0
    else
        back = not race_editor and (band(pressed, pad_left) ~= 0 or struck[2])
    end
    local editor = race_editor or cone_editor
    local confirm = band(pressed, if editor then M.pad_a else bor(pad_right, M.pad_a)) ~= 0 or struck[1]
    local done = band(pressed, if editor then 0x10 else pad_down) ~= 0 or struck[3]
    if race_editor then
        local down = band(buttons, 0x10) ~= 0 or keys[3]
        local action = s.save_hold:update(down, focus, now)
        done = action == "save"
        if action == "load" then M.open_route_dialog(s, 2) end
        if s.route_dialog ~= 0 then return end
        if done then confirm = false end -- Opening Save owns this tick too.
    end
    if not s.cursor_ok and confirm then
        M.popup(s, if s.game.settings.mode == "race" and s.race_object == 4 then "Move the Arrow clear of the surface." else "Aim at the ground")
        confirm = false
        done = false
    end
    if s.placing == "circle" then
        local grow = band(buttons, pad_up) ~= 0 or held(VK_PRIOR)
        local shrink = band(buttons, pad_down) ~= 0 or held(VK_NEXT)
        -- Faster the bigger it gets, so a whole plaza is a couple of seconds away.
        local rate = 6.0 + s.draft_radius * 0.6
        if grow ~= shrink then s.draft_radius += (if grow then rate else -rate) * seconds end
        s.draft_radius *= 1.12 ^ notches -- each wheel notch: 12% bigger or smaller
        s.draft_radius = math.clamp(s.draft_radius, M.min_area_radius, M.max_area_radius)
        if confirm then
            g.settings.corners = {s.cursor}
            g.settings.area_radius = math.round(s.draft_radius)
            M.settings_changed(g)
            s.placing = "none"
            M.popup(s, string.format("Area set: a circle %.0f m across.", g.settings.area_radius * 2))
        elseif back then
            s.placing = "none"
        end
        return
    end
    local corners = s.placing == "corners"
    -- `auto &list`: a reference to the member, so read it again each time (the helpers may give
    -- the member a new table).
    local function list() return if corners then g.settings.corners else g.settings.points end
    local limit = if corners then M.max_corners else M.max_points
    local route = not corners and g.settings.mode == "race"
    if route then
        if s.editor_pose_game ~= g.id or s.editor_pose_world ~= s.world then
            s.arrow_floor_alignment:reset()
            s.editor_pose_game = g.id
            s.arrow_line_snap:reset()
            s.editor_pose_world = s.world
            s.editor_angles_ready = false
            s.editor_rotating = false
            s.editor_manual_rotation = false
            s.rotation_original:clear()
            s.editor_roll_axis = false
            s.editor_object_changed = now
            s.yaw_offset = 0
            s.pitch_offset = 0
            s.arrow_roll = 0
            s.draft_width = RE.default_race_editor_width
            s.snap_angle = RE.default_race_editor_snap_angle
            s.route_snap = true
        end
        if not s.editor_angles_ready and s.cursor_ok then
            s.editor_yaw = RE.race_camera_yaw(s.cursor_heading, s.yaw_offset, s.race_object == 4)
            s.editor_pitch = RE.race_camera_pitch(s.cursor_pitch, s.pitch_offset, s.race_object == 4, s.arrow_surface.contact)
            s.editor_angles_ready = true
        end
        local before_clear = M.copy(g.settings)
        if s.clear_hold:update(band(buttons, 0x20) ~= 0 or held(VK_BACK), focus, now) then
            -- clear_race_gates(route, bool& finish): the finish comes back.
            g.race_finish_placed = RR.clear_race_gates(g.settings, g.race_finish_placed)
            s.route_history:changed(before_clear, g.settings)
            M.settings_changed(g)
            s.race_object = 1
            M.popup(s, "All gates and finish cleared.")
            return
        end
        local snap_angles = {5.0, 15.0, 30.0, 45.0, 90.0}
        if not s.editor_rotating and band(pressed, 0x40) ~= 0 then s.snap_angle = (s.snap_angle + 4) % 5 end
        if band(pressed, 0x80) ~= 0 then
            if s.editor_rotating and s.race_object == 4 then
                s.editor_roll_axis = not s.editor_roll_axis
            elseif not s.editor_rotating then
                s.snap_angle = (s.snap_angle + 1) % 5
            end
        end
        local held_editor = bor(
            if band(buttons, pad_left) ~= 0 or held(VK_PRIOR) then 1 else 0,
            if band(buttons, pad_right) ~= 0 or held(VK_NEXT) then 2 else 0,
            if band(buttons, pad_down) ~= 0 or held(VK_OEM_4) then 4 else 0,
            if band(buttons, pad_up) ~= 0 or held(VK_OEM_6) then 8 else 0)
        local rotate_key = held(KEY_R)
        if not s.editor_rotating then
            -- update_aim(camera_yaw, camera_pitch, float& y, float& p, automatic): y and p come back.
            s.editor_yaw, s.editor_pitch = s.rotation_original:update_aim(RE.race_camera_yaw(s.cursor_heading, s.yaw_offset, s.race_object == 4),
                RE.race_camera_pitch(s.cursor_pitch, s.pitch_offset, s.race_object == 4, s.arrow_surface.contact), s.editor_yaw, s.editor_pitch,
                s.race_object == 4 and not s.editor_manual_rotation)
        end
        local function snap_arrow()
            -- update(route, pose, enabled, step, bool& snapped, upright): the pose, then snapped.
            local pose, snapped = s.arrow_line_snap:update(g.settings, {at = s.cursor, yaw = s.editor_yaw, pitch = s.editor_pitch, roll = s.arrow_roll},
                s.route_snap, if s.arrow_surface.contact or s.editor_manual_rotation then 0.0 else snap_angles[s.snap_angle + 1], s.arrow_height_snapped,
                not s.arrow_surface.contact)
            s.arrow_height_snapped = snapped
            s.cursor = pose.at
            s.editor_yaw = pose.yaw
            s.editor_pitch = pose.pitch
            s.arrow_roll = pose.roll
        end
        local raw_arrow_cursor = s.cursor
        if not s.editor_rotating and s.race_object == 4 then snap_arrow() end
        if (band(pressed, 0x4000) ~= 0 or (rotate_key and not s.rotate_key_previous)) and (s.cursor_ok or s.editor_rotating) then
            s.editor_rotating = not s.editor_rotating
            if s.editor_rotating then
                if not s.rotation_original.captured and s.race_object ~= 4 then
                    s.editor_yaw = RR.snap_race_gate(g.settings, s.cursor, s.editor_yaw, s.route_snap, snap_angles[s.snap_angle + 1]).yaw
                end
                s.rotation_original:capture(s.editor_yaw, s.editor_pitch, s.arrow_roll)
                s.editor_roll_axis = RE.race_default_roll_axis(s.race_object)
                s.rotation_pivot = s.cursor
                s.rotation_surface = s.arrow_surface
            end
            s.editor_presses:suppress(held_editor)
        end
        s.rotate_key_previous = rotate_key
        if s.editor_rotating then
            s.cursor = s.rotation_pivot
            s.cursor_ok = s.editor_angles_ready
        end
        if s.editor_rotating and band(pressed, 0x40) ~= 0 then
            -- restore(float& y, float& p, float& r): all three come back.
            s.editor_yaw, s.editor_pitch, s.arrow_roll = s.rotation_original:restore(s.editor_yaw, s.editor_pitch, s.arrow_roll)
            s.editor_manual_rotation = false
            s.arrow_line_snap:reset()
            s.editor_presses:suppress(held_editor)
        end
        local step = s.editor_presses:update(held_editor, now, s.editor_rotating)
        local controls = RE.race_editor_directions(s.editor_rotating, step)
        local wheel_steps = M.trunc(notches)
        local yaw_steps = controls.yaw + (if s.editor_rotating then wheel_steps else 0)
        if yaw_steps ~= 0 or controls.tilt ~= 0 then
            s.editor_manual_rotation = true
            s.arrow_line_snap:begin_rotation(#g.settings.points)
        end
        if yaw_steps ~= 0 then
            s.editor_yaw = RR.rotate_race_gate(s.editor_yaw, yaw_steps, false, 5.0)
        end
        if controls.tilt ~= 0 then
            if s.race_object == 4 and s.editor_roll_axis then
                s.arrow_roll = RR.rotate_race_gate(s.arrow_roll, controls.tilt, false, 5.0)
            else
                s.editor_pitch = RE.tilt_race_gate(s.editor_pitch, controls.tilt, false, 5.0)
            end
        end
        s.draft_width = RR.size_race_gate(s.draft_width, controls.size + (if not s.editor_rotating then wheel_steps else 0))
        -- undo / redo(route, bool& finish): the result, then the finish.
        local undone = false
        if controls.undo then
            local ok, finish = s.route_history:undo(g.settings, g.race_finish_placed)
            if ok then g.race_finish_placed = finish end
            undone = ok
        end
        if undone then
            M.settings_changed(g)
            M.popup(s, "Last placement undone.")
        elseif controls.redo then
            local ok, finish = s.route_history:redo(g.settings, g.race_finish_placed)
            if ok then
                g.race_finish_placed = finish
                M.settings_changed(g)
                M.popup(s, "Placement restored.")
            end
        end
        local old_object = s.race_object
        local lt = band(buttons, 0x10000) ~= 0 or held(KEY_Z)
        local rt = band(buttons, 0x20000) ~= 0 or held(KEY_X)
        if lt and not s.cycle_left then s.race_object = RR.cycle_race_object(s.race_object, true) end
        if rt and not s.cycle_right then s.race_object = RR.cycle_race_object(s.race_object, false) end
        s.cycle_left = lt
        s.cycle_right = rt
        if old_object ~= s.race_object then
            s.editor_object_changed = now
            s.editor_rotating = false
            s.editor_manual_rotation = false
            s.rotation_original:clear()
            s.yaw_offset = 0
            s.pitch_offset = 0
            s.arrow_roll = 0
            s.editor_roll_axis = false
            s.editor_angles_ready = false
            s.arrow_line_snap:reset()
            s.arrow_floor_alignment:reset()
        end
        local snap = band(buttons, 0x8000) ~= 0 or held(KEY_G)
        if snap and not s.snap_previous then s.route_snap = not s.route_snap end
        s.snap_previous = snap
        if not s.editor_rotating then
            s.editor_yaw, s.editor_pitch = s.rotation_original:update_aim(RE.race_camera_yaw(s.cursor_heading, s.yaw_offset, s.race_object == 4),
                RE.race_camera_pitch(s.cursor_pitch, s.pitch_offset, s.race_object == 4, s.arrow_surface.contact), s.editor_yaw, s.editor_pitch,
                s.race_object == 4 and not s.editor_manual_rotation)
        end
        s.arrow_height_snapped = false
        if s.race_object == 4 and not s.editor_rotating then
            s.cursor = raw_arrow_cursor
            snap_arrow()
        elseif s.race_object ~= 4 then
            s.arrow_line_snap:reset()
        end
        local pose = if s.race_object == 4 or s.editor_rotating then {at = s.cursor, yaw = s.editor_yaw}
            else RR.snap_race_gate(g.settings, s.cursor, s.editor_yaw, s.route_snap, snap_angles[s.snap_angle + 1])
        s.cursor = pose.at
        s.snapped_yaw = if s.editor_manual_rotation then s.editor_yaw else pose.yaw
        if s.race_object == 4 then
            local prior_height = s.cursor.y
            s.cursor = RA.clear_race_arrow_surface(s.cursor, s.snapped_yaw, s.editor_pitch, s.arrow_roll, s.draft_width,
                if s.editor_rotating then s.rotation_surface else s.arrow_surface)
            local supported = RA.clear_race_arrow_ground(s.cursor, s.snapped_yaw, s.editor_pitch, s.arrow_roll, s.draft_width, M.cast_arrow_ray)
            s.cursor = supported.at
            s.cursor_ok = s.cursor_ok and supported.available
            if math.abs(s.cursor.y - prior_height) > .01 then s.arrow_height_snapped = false end
            local view = reskate.camera.get()
            s.cursor_ok = s.cursor_ok and view ~= nil and RA.race_arrow_clear(M.V(view.position),
                s.cursor, s.snapped_yaw, s.editor_pitch, s.arrow_roll, s.draft_width, M.cast_arrow_ray)
            if confirm and not s.cursor_ok then
                M.popup(s, "Move the Arrow clear of the surface.")
                confirm = false
            end
        end
        local function place(object)
            local before = M.copy(g.settings)
            -- edit_race_route(settings, bool& finish, ...): the result, then the finish.
            local ok, finish = RR.edit_race_route(g.settings, g.race_finish_placed, object, s.cursor, s.snapped_yaw, s.draft_width, s.arrow_roll, s.editor_pitch)
            if not ok then return false end
            g.race_finish_placed = finish
            s.route_history:changed(before, g.settings)
            s.editor_save_blocked = false
            M.settings_changed(g)
            return true
        end
        if confirm and (s.race_object == 1 or s.race_object == 3 or s.race_object == 4) then
            if #list() == 0 then
                M.popup(s, "Place the starting flag first.")
            elseif place(s.race_object) then
                M.popup(s, if s.race_object == 4 then "Arrow placed." elseif s.race_object == 3 then "Gray guiding gate placed (optional)." else "Required gate placed.")
            else
                M.popup(s, "Gate could not be placed.")
            end
        elseif confirm and s.race_object == 2 then
            if M.mandatory_gates(g.settings, #list()) == 0 then
                M.popup(s, "Place a start and at least one required gate first.")
            else
                if place(RR.RaceObject.finish) then
                    M.popup(s, "Finish placed. Tap Start to name and save the route.")
                else
                    M.popup(s, "Finish could not be placed.")
                end
            end
        elseif done then
            local issue = RR.race_route_save_error(g.settings, g.race_finish_placed)
            if issue ~= nil and issue ~= "" then
                s.editor_save_blocked = true
                M.popup(s, issue)
                reskate.ui.toast("Deathrace route not saved" .. ": " .. issue, "warn")
            else
                s.editor_save_blocked = false
                M.open_route_dialog(s, 1)
            end
        end
        return
    end
    if cone_editor then
        -- Snapping, with the gate editor's buttons (Y on/off, L3/R3 the angle): from the third cone
        -- on, the edge from the last one keeps to steps of the snap angle from the first edge, and a
        -- cone near the first one's line lands on it, so a square comes out square.
        local snap_angles = {5.0, 15.0, 30.0, 45.0, 90.0}
        if band(pressed, 0x40) ~= 0 then s.snap_angle = (s.snap_angle + 4) % 5 end
        if band(pressed, 0x80) ~= 0 then s.snap_angle = (s.snap_angle + 1) % 5 end
        local snap = band(buttons, 0x8000) ~= 0 or held(KEY_G)
        if snap and not s.snap_previous then s.route_snap = not s.route_snap end
        s.snap_previous = snap
        local placed = g.settings.corners
        if s.route_snap and #placed >= 2 then
            local first, last = placed[1], placed[#placed]
            local ex, ez = placed[2].x - first.x, placed[2].z - first.z
            local edge = hypot(ex, ez)
            local dx, dz = s.cursor.x - last.x, s.cursor.z - last.z
            local length = hypot(dx, dz)
            if edge > .5 and length > .5 then
                local ux, uz = ex / edge, ez / edge -- the first edge, and across it
                local step = snap_angles[s.snap_angle + 1] * 3.14159265 / 180
                local angle = math.round(math.atan2(dx * -uz + dz * ux, dx * ux + dz * uz) / step) * step
                local du, dv = math.cos(angle), math.sin(angle)
                local reach = length
                -- Line up with the first cone along either axis when close (1.5 m).
                local lu = (last.x - first.x) * ux + (last.z - first.z) * uz
                local lv = (last.x - first.x) * -uz + (last.z - first.z) * ux
                for _, pair in {{du, lu}, {dv, lv}} do
                    local along, from = pair[1], pair[2]
                    if math.abs(along) > .2 then
                        local fit = -from / along
                        if fit > .5 and math.abs(fit - reach) < 1.5 then reach = fit end
                    end
                end
                s.cursor = vector.create(last.x + (du * ux - dv * uz) * reach, s.cursor.y, last.z + (du * uz + dv * ux) * reach)
            end
        end
    end
    if cone_editor and s.clear_hold:update(band(buttons, 0x20) ~= 0 or held(VK_BACK), focus, now) then
        g.settings.corners = {} -- list.clear(): the cone editor's list is the corners
        table.clear(s.cone_redo)
        M.settings_changed(g)
        M.popup(s, "All cones cleared.")
        return
    end
    if cone_editor and confirm and #list() >= limit then
        M.popup(s, string.format("%d cones is the most. Press Start to finish.", limit))
    elseif cone_editor and band(pressed, pad_right) ~= 0 and #s.cone_redo ~= 0 and #list() < limit then
        table.insert(list(), s.cone_redo[#s.cone_redo])
        table.remove(s.cone_redo)
        M.settings_changed(g)
        M.popup(s, string.format("Cone %d restored", #list()))
    elseif confirm and #list() < limit then
        if cone_editor then table.clear(s.cone_redo) end
        table.insert(list(), s.cursor)
        M.settings_changed(g)
        M.popup(s, string.format("%s %d placed", if cone_editor then "Cone" elseif corners then "Corner" else M.point_name(g), #list()))
    elseif back then
        if #list() == 0 then
            if not cone_editor then s.placing = "none" end
        else
            local lst = list()
            if cone_editor then table.insert(s.cone_redo, lst[#lst]) end
            table.remove(lst)
            -- resize(list.size()) only ever shrinks here.
            if not corners and #g.settings.yaws > #lst then
                for i = #g.settings.yaws, #lst + 1, -1 do g.settings.yaws[i] = nil end
            end
            if not corners and #g.settings.widths > #lst then
                for i = #g.settings.widths, #lst + 1, -1 do g.settings.widths[i] = nil end
            end
            M.settings_changed(g)
            M.popup(s, string.format("Removed the last one (%d left)", #list()))
        end
    elseif done and cone_editor and #list() < 3 then
        M.popup(s, "Place at least 3 cones.")
    elseif done and (if corners then #list() >= 3 else #list() ~= 0) then
        s.placing = "none"
        if cone_editor then
            M.notice(s, string.format("Trick zone set: %d cones.", #list()))
        else
            M.popup(s, if corners then string.format("Area set: %d corners.", #list()) else string.format("%d %ss placed.", #list(), M.point_name(g)))
        end
    end
end

return nil
