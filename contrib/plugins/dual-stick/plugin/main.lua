-- Dual Stick: the settings of GoalTrains' Dual Stick Controls companion on a page in the ReSkate
-- menu's PLUGINS section (from pull request 254). The companion itself is separate: it translates
-- Skate's controls across two sticks, and reads session_controls.ini every two seconds. This plugin
-- only edits that file, in its own data folder (reskate.files:
-- <game>/Mods/.reskate_plugin_data/<this mod's folder>/session_controls.ini), where a companion
-- that knows ReSkate's plugins reads it. It never creates the file: without it there is nothing to
-- set, and the page says how to get the companion.
--
-- controls.lua holds the companion's settings, ini.lua the file, tests.lua their checks.
local ini = require("ini")
local controls = require("controls")

local file = "session_controls.ini"
local doc = nil          -- the file as last read, parsed
local read_at = -math.huge
local missing = false
local notice = nil       -- what the last change did, for the page
local slot = 1
local overwrite = 0      -- the slot a second Save replaces

-- The file again at most once a second: the companion's own menu changes it too.
local function refresh(force)
    local now = reskate.time.now()
    if not force and now - read_at < 1000 then return doc end
    read_at = now
    local ok, text = pcall(reskate.files.read, file)
    if ok and type(text) == "string" then
        doc, missing = ini.parse(text), false
    else
        doc, missing = nil, true
    end
    return doc
end
-- Changes the file with `change(doc)` and writes it; what happened, for the page and the console.
local function change(what)
    local current = refresh(true)
    if not current then return "session_controls.ini is not in this plugin's folder: install the Dual Stick Controls companion." end
    if what(current) == false then return "nothing changed." end
    local ok, why = reskate.files.write(file, ini.dump(current))
    if not ok then
        refresh(true)
        return "session_controls.ini could not be saved: " .. tostring(why)
    end
    return "saved. The companion picks up the change within two seconds."
end
local function apply(what)
    overwrite = 0
    notice = change(what)
end

-- ---- the page ---------------------------------------------------------------------------------------
local function dropdown(ui, id, label, names, chosen, help)
    local picked = ui:dropdown(id, label, names, chosen, help)
    return if picked ~= chosen then picked else nil
end

reskate.menu.page("Dual Stick", function(ui)
    local d = refresh(false)
    ui:card("DUAL STICK CONTROLS", if d then "Settings of the companion's session_controls.ini" else "Companion not found")
    if not d then
        ui:warn("Install the Dual Stick Controls companion, in a version that reads ReSkate's plugin folder.")
        ui:note("It keeps its settings in Mods/.reskate_plugin_data/" .. reskate.id .. "/session_controls.ini, which this page edits. " ..
            "ReSkate does not include the control translator.")
        return
    end

    ui:card("PRESETS")
    if ui:button("session", if controls.active(d, false) then "Session-style preset (active)" else "Apply the Session-style preset") then
        apply(function(x) return controls.preset(x, false) end)
    end
    if ui:button("xl", if controls.active(d, true) then "XL-style preset (active)" else "Apply the XL-style preset") then
        apply(function(x) return controls.preset(x, true) end)
    end
    ui:note("Both presets translate Skate controls across two sticks. Their inputs differ from Session and Skater XL.")
    ui:note("Session: front/back feet, flick pop, trigger steering, one-stick flips blocked. XL: fixed physical setup directions, " ..
        "jobs swap in switch, release pop, left-stick steering, one-stick flips allowed.")

    ui:card("CUSTOM SLOTS", "Shared with the companion's own menu")
    local names = {}
    for i = 1, controls.slots do names[i] = "Slot " .. i .. (if controls.filled(d, i) then "" else " (empty)") end
    local picked = ui:dropdown("slot", "Custom slot", names, slot)
    if picked ~= slot then slot, overwrite = picked, 0 end
    if controls.filled(d, slot) and ui:button("load", "Load slot " .. slot) then
        apply(function(x) return controls.load(x, slot) end)
    end
    if ui:button("save", if overwrite == slot then "Confirm: replace slot " .. slot else "Save to slot " .. slot) then
        if controls.filled(d, slot) and overwrite ~= slot then
            overwrite = slot
            notice = "slot " .. slot .. " holds controls already: press again to replace them."
        else
            apply(function(x) return controls.save(x, slot) end)
        end
    end
    ui:note("Loading restores the controls below; the controller, your base stance, menu preferences and other tuning stay as they are.")

    ui:card("YOUR SETTINGS")
    local stance = dropdown(ui, "stance", "Stance", controls.stances, controls.stance(d) + 1)
    if stance then apply(function(x) controls.set_stance(x, stance - 1) end) end
    local layout = controls.layout(d)
    local layouts = {controls.layouts[1], controls.layouts[2], controls.layouts[3]}
    if layout == 3 then layouts[4] = controls.layouts[4] end
    local picked_layout = dropdown(ui, "layout", "Stick layout", layouts, layout + 1)
    if picked_layout and picked_layout <= 3 then apply(function(x) return controls.set_layout(x, picked_layout - 1) end) end
    for i, c in controls.choices do
        local value, index = controls.choice(d, c)
        local labels = table.clone(c.labels)
        if not index then
            table.insert(labels, "Custom (" .. value .. ")")
            index = #labels
        end
        local chosen = dropdown(ui, "c" .. i, c.label, labels, index)
        if chosen and chosen <= #c.values then apply(function(x) controls.set_choice(x, c, chosen) end) end
    end
    local angle = controls.angle(d)
    local moved = math.floor(ui:slider("angle", "Stick steering angle", math.clamp(angle, 5, 60), 5, 60, "%d deg") + 0.5)
    if moved ~= math.clamp(angle, 5, 60) then apply(function(x) controls.set_angle(x, moved) end) end
    local ramp = dropdown(ui, "ramp", "Stock ramp controls", controls.ramps, controls.ramp(d) + 1,
        "Experimental. Qualified transitions use physical Skate stick controls and trigger grabs; flat tricks keep foot controls. Pumping stays on R3.")
    if ramp then apply(function(x) controls.set_ramp(x, ramp - 1) end) end
    local start = ui:toggle("start", "Dual Stick on next launch", controls.enabled_at_start(d),
        "The startup choice only: use the companion's menu to switch the running translator now.")
    if start ~= controls.enabled_at_start(d) then apply(function(x) controls.set_enabled_at_start(x, start) end) end
    ui:note("Manual Catch uses L3/R3; some tricks settle at an angle and still need catch timing.")
    ui:note("The companion's own menu stays on its hotkey (End by default), with the control diagrams and more tuning.")
    if notice then ui:info("Last change", string.sub(notice, 1, 200)) end
end)

-- ---- the console ------------------------------------------------------------------------------------
reskate.console.command("dualstick", "Dual Stick Controls' settings: status, preset session|xl, load <slot>, save <slot>, test", function(args)
    local function say(text) reskate.console.print("dualstick: " .. text) end
    local what = args[1]
    if what == "test" then
        local passed, failures = require("tests").run()
        for _, failure in failures do say("FAIL " .. failure) end
        return say(string.format("%d passed, %d failed", passed, #failures))
    end
    local d = refresh(true)
    if not d then return say("session_controls.ini is not in Mods/.reskate_plugin_data/" .. reskate.id .. "/: install the Dual Stick Controls companion.") end
    if what == nil or what == "status" then
        local preset = if controls.active(d, false) then "Session-style" elseif controls.active(d, true) then "XL-style" else "custom"
        return say(string.format("%s controls, %s layout, %s stance, steering angle %d deg", preset, controls.layouts[controls.layout(d) + 1],
            string.lower(controls.stances[controls.stance(d) + 1]), controls.angle(d)))
    elseif what == "preset" and (args[2] == "session" or args[2] == "xl") then
        return say(change(function(x) return controls.preset(x, args[2] == "xl") end))
    elseif (what == "load" or what == "save") and tonumber(args[2]) then
        local n = math.floor(tonumber(args[2]))
        if n < 1 or n > controls.slots then return say("a slot is 1 to " .. controls.slots) end
        if what == "load" and not controls.filled(d, n) then return say("slot " .. n .. " is empty") end
        return say(change(function(x) return if what == "load" then controls.load(x, n) else controls.save(x, n) end))
    end
    say("say dualstick status, preset session|xl, load <slot>, save <slot> or test")
end)

reskate.log("Dual Stick settings: " .. (if refresh(true) then "session_controls.ini found" else "no session_controls.ini in the plugin's folder yet"))
