-- The Dual Stick Controls companion's settings (its session_controls.ini), as GoalTrains' settings
-- pages for ReSkate change them (pull request 254, dual_stick_settings.h), with the same keys,
-- fallbacks, presets and custom slots. Everything works on a parsed file (ini.lua); main.lua reads
-- and writes it.
local ini = require("ini")
local M = {}

M.section = "SessionControls"

-- Each setting the page lists: its key, its name, the companion's own value when the key is missing,
-- and its values with their names.
M.choices = {
    {key = "ManualCatch", label = "Manual catch", fallback = 0, values = {0, 1}, labels = {"Off", "On"}},
    {key = "DpadCameraSide", label = "D-pad camera sides", fallback = 1, values = {0, 1}, labels = {"Off", "On"}},
    {key = "SplitGrindControls", label = "Foot setup grinds", fallback = 1, values = {0, 1}, labels = {"Off", "On"}},
    {key = "PopOnRelease", label = "Pop style", fallback = 0, values = {0, 1}, labels = {"Flick", "Release"}},
    {key = "OneFootFlips", label = "One-stick flips", fallback = 0, values = {0, 1}, labels = {"Blocked", "Allowed"}},
    {key = "StickSteering", label = "Stick steering", fallback = 0, values = {0, 1, 2}, labels = {"Off", "Front foot", "Left stick"}},
    {key = "SwitchInvertX", label = "Switch flick / scoop directions", fallback = 0, values = {0, 1}, labels = {"Standard", "Reversed"}},
    {key = "SwitchInvertY", label = "Switch up / down directions", fallback = 0, values = {0, 1}, labels = {"Standard", "Reversed"}},
    {key = "DisableHoldFakie", label = "Disable hold-fakie", fallback = 1, values = {0, 1}, labels = {"Off", "On"}},
    {key = "RevertDoubleTapMs", label = "Revert double-tap window", fallback = 300, values = {150, 300, 450, 600},
     labels = {"150 ms", "300 ms", "450 ms", "600 ms"}},
    {key = "SpinWindUpSteer", label = "Crouched trigger handling", fallback = 0, values = {0, 1}, labels = {"Normal", "Light steers"}},
    {key = "SpinWindUpTriggerPercent", label = "Wind-up trigger strength", fallback = 90, values = {50, 65, 80, 90},
     labels = {"50%", "65%", "80%", "90%"}},
    {key = "RevertInput", label = "Reverts", fallback = 2, values = {0, 1, 2}, labels = {"Off", "Double tap", "Both triggers"}},
    {key = "SpinWindUp", label = "Spin wind-up", fallback = 1, values = {0, 1}, labels = {"Off", "On"}},
    {key = "BodyFlips", label = "Body flips", fallback = 1, values = {0, 1}, labels = {"Off", "On"}},
    {key = "AirControls", label = "Air controls", fallback = 1, values = {0, 1}, labels = {"Off", "On"}},
    {key = "Powerslides", label = "Powerslides", fallback = 1, values = {0, 1}, labels = {"Off", "On"}},
    {key = "GrindBumpMs", label = "Grind bump", fallback = 250, values = {0, 250}, labels = {"Off", "On"}},
}
M.layouts = {"Front / back foot", "Left / right foot", "Skater XL", "Legacy left / right"}
M.stances = {"Automatic", "Regular", "Goofy"}
M.ramps = {"Off", "Air only", "Early on ramp"}
M.slots = 5

local function number(doc, key, fallback) return ini.number(doc, M.section, key, fallback) end
local function text(doc, key, fallback) return ini.get(doc, M.section, key) or fallback end
local function set(doc, key, value) ini.set(doc, M.section, key, value) end

-- 0 front/back, 1 left/right, 2 Skater XL, 3 the legacy left/right.
function M.layout(doc)
    if number(doc, "FrontBackFoot", 1) ~= 0 then return 0 end
    if number(doc, "SwitchStance", 1) ~= 3 then return 3 end
    return if number(doc, "XLFootDirections", 0) ~= 0 then 2 else 1
end
local function layout_keys(doc, kind)
    set(doc, "FrontBackFoot", if kind == 0 then 1 else 0)
    set(doc, "SwitchStance", if kind == 0 then 1 else 3)
    set(doc, "XLFootDirections", if kind == 2 then 1 else 0)
    set(doc, "SwitchSource", 4)
    set(doc, "PresetFeetSwapped", 0)
end
function M.set_layout(doc, kind)
    if kind < 0 or kind > 2 then return false end
    layout_keys(doc, kind)
    return true
end

-- The Session-style or the XL-style preset (xl).
function M.preset(doc, xl)
    layout_keys(doc, if xl then 2 else 0)
    for _, key in {"PopOnRelease", "OneFootFlips"} do set(doc, key, if xl then 1 else 0) end
    set(doc, "StickSteering", if xl then 2 else 0)
    for _, key in {"SwitchInvertX", "SwitchInvertY", "MirrorFlicks"} do set(doc, key, 0) end
    return true
end
function M.active(doc, xl)
    local flag = if xl then 1 else 0
    return M.layout(doc) == (if xl then 2 else 0) and number(doc, "PopOnRelease", 0) == flag and
        number(doc, "StickSteering", 0) == (if xl then 2 else 0) and number(doc, "OneFootFlips", 0) == flag and
        number(doc, "SwitchSource", 4) == 4 and number(doc, "PresetFeetSwapped", 0) == 0 and
        number(doc, "SwitchInvertX", 0) == 0 and number(doc, "SwitchInvertY", 0) == 0 and number(doc, "MirrorFlicks", 0) == 0
end

-- ---- custom slots: [CustomPreset1] to [CustomPreset5], shared with the companion's own menu ---------
local function slot_name(slot) return "CustomPreset" .. slot end
function M.filled(doc, slot)
    return slot >= 1 and slot <= M.slots and ini.number(doc, slot_name(slot), "PresetSaved", 0) == 1
end
-- Saving copies the whole [SessionControls] section, with the settings below written out (their
-- fallbacks where the file has none), as the companion's own save does.
function M.save(doc, slot)
    if slot < 1 or slot > M.slots then return false end
    local list, index = {}, {}
    for _, pair in ini.entries(doc, M.section) do
        table.insert(list, {key = pair.key, value = pair.value})
        index[string.lower(pair.key)] = #list
    end
    local function put(key, value)
        local at = index[string.lower(key)]
        if at then list[at].value = tostring(value)
        else
            table.insert(list, {key = key, value = tostring(value)})
            index[string.lower(key)] = #list
        end
    end
    for _, c in M.choices do put(c.key, number(doc, c.key, c.fallback)) end
    put("AutoStance", number(doc, "AutoStance", 1))
    put("StockGrabAir", number(doc, "StockGrabAir", 0))
    put("StockTransitionGround", number(doc, "StockTransitionGround", 0))
    put("StickSteeringAngleDegrees", number(doc, "StickSteeringAngleDegrees", 34))
    put("Stance", text(doc, "Stance", "regular"))
    put("SwitchSource", number(doc, "SwitchSource", 4))
    put("FrontBackFoot", number(doc, "FrontBackFoot", 1))
    put("SwitchStance", number(doc, "SwitchStance", 1))
    put("XLFootDirections", number(doc, "XLFootDirections", 0))
    put("PresetFeetSwapped", number(doc, "PresetFeetSwapped", 0))
    put("MirrorFlicks", number(doc, "MirrorFlicks", 0))
    put("PresetSaved", 1)
    ini.replace_section(doc, slot_name(slot), list)
    return true
end
-- Loading brings back the gameplay settings only: the controller, the base stance and the menu,
-- launch and recording preferences stay as they are, and so do keys this page does not know. A slot
-- saved by an older companion leaves the settings it lacks as they are.
local loaded = {"FrontBackFoot", "SwitchStance", "XLFootDirections", "PresetFeetSwapped", "MirrorFlicks", "SwitchSource",
                "StockGrabAir", "StockTransitionGround", "StickSteeringAngleDegrees"}
function M.load(doc, slot)
    if not M.filled(doc, slot) then return false end
    local from = slot_name(slot)
    for _, c in M.choices do
        local value = ini.get(doc, from, c.key)
        if value ~= nil then set(doc, c.key, value) end
    end
    for _, key in loaded do
        local value = ini.get(doc, from, key)
        if value ~= nil then set(doc, key, value) end
    end
    return true
end

-- ---- the other settings on the page ---------------------------------------------------------------
-- 0 automatic, 1 regular, 2 goofy.
function M.stance(doc)
    if number(doc, "AutoStance", 1) ~= 0 then return 0 end
    return if string.lower(text(doc, "Stance", "regular")) == "goofy" then 2 else 1
end
function M.set_stance(doc, stance)
    set(doc, "AutoStance", if stance == 0 then 1 else 0)
    if stance ~= 0 then set(doc, "Stance", if stance == 2 then "goofy" else "regular") end
end
-- 0 off, 1 in the air only, 2 early on the ramp too.
function M.ramp(doc)
    if number(doc, "StockGrabAir", 0) == 0 then return 0 end
    return if number(doc, "StockTransitionGround", 0) ~= 0 then 2 else 1
end
function M.set_ramp(doc, ramp)
    set(doc, "StockGrabAir", if ramp ~= 0 then 1 else 0)
    set(doc, "StockTransitionGround", if ramp == 2 then 1 else 0)
end
function M.angle(doc) return number(doc, "StickSteeringAngleDegrees", 34) end
function M.set_angle(doc, degrees) set(doc, "StickSteeringAngleDegrees", math.clamp(math.floor(degrees + 0.5), 5, 60)) end
function M.enabled_at_start(doc) return number(doc, "EnabledAtStart", 1) ~= 0 end
function M.set_enabled_at_start(doc, on) set(doc, "EnabledAtStart", if on then 1 else 0) end
-- A setting's value and the index of its name (nil for a value the page has no name for).
function M.choice(doc, c)
    local value = number(doc, c.key, c.fallback)
    for i, v in c.values do
        if v == value then return value, i end
    end
    return value, nil
end
function M.set_choice(doc, c, index) set(doc, c.key, c.values[index]) end

return M
