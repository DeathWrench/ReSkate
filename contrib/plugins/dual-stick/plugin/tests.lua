-- The checks `dualstick test` runs (and ReSkate's plugin tests with it): the file as Windows reads
-- it, and the companion's settings as pull request 254's tests had them (dual_stick_settings_tests).
local ini = require("ini")
local controls = require("controls")
local M = {}

local function cases()
    local list = {}
    local function check(name, fn) table.insert(list, {name = name, fn = fn}) end

    check("a file comes back as it was when nothing changes", function()
        local text = "; Dual Stick\r\n[SessionControls]\r\nPopOnRelease=1\r\n  Unknown = keep me \r\n\r\n[Menu]\r\nHotkey=End\r\n"
        assert(ini.dump(ini.parse(text)) == text, "every line as it was")
        assert(ini.get(ini.parse(text), "SessionControls", "unknown") == "keep me", "a value without the spaces around it")
    end)
    check("keys and sections are read without regard to case", function()
        local doc = ini.parse("[sessioncontrols]\npoponrelease = 1\n")
        assert(ini.number(doc, "SessionControls", "PopOnRelease", 0) == 1, "found")
        ini.set(doc, "SessionControls", "POPONRELEASE", 0)
        assert(ini.dump(doc) == "[sessioncontrols]\npoponrelease=0\n", "changed in its place, with its own spelling")
    end)
    check("a number is the whole number a value starts with", function()
        local doc = ini.parse("[S]\nA=34 ; deg\nB=\nC=-5\n")
        assert(ini.number(doc, "S", "A", 0) == 34 and ini.number(doc, "S", "B", 7) == 7 and ini.number(doc, "S", "C", 0) == -5, "numbers")
    end)
    check("a new key goes at the end of its section, a new section at the end of the file", function()
        local doc = ini.parse("[SessionControls]\nA=1\n\n[Menu]\nB=2\n")
        ini.set(doc, "SessionControls", "C", 3)
        ini.set(doc, "CustomPreset1", "PresetSaved", 1)
        assert(ini.dump(doc) == "[SessionControls]\nA=1\nC=3\n\n[Menu]\nB=2\n\n[CustomPreset1]\nPresetSaved=1\n", ini.dump(doc))
    end)
    check("the Session-style preset sets its keys and keeps the others", function()
        local doc = ini.parse("[SessionControls]\nFrontBackFoot=0\nSwitchStance=3\nXLFootDirections=1\nPopOnRelease=1\nStickSteering=2\nManualCatch=1\nControllerIndex=2\n")
        assert(not controls.active(doc, false) and controls.active(doc, true) == false, "neither yet (no SwitchSource, OneFootFlips 0)")
        controls.preset(doc, false)
        assert(controls.active(doc, false) and not controls.active(doc, true), "Session-style active")
        assert(controls.layout(doc) == 0, "front / back")
        assert(ini.number(doc, controls.section, "ManualCatch", 0) == 1 and ini.number(doc, controls.section, "ControllerIndex", 0) == 2,
            "catch and controller kept")
    end)
    check("the XL-style preset is the XL layout, release pop, left-stick steering, one-stick flips", function()
        local doc = ini.parse("[SessionControls]\n")
        controls.preset(doc, true)
        assert(controls.active(doc, true) and controls.layout(doc) == 2, "XL active")
        assert(ini.number(doc, controls.section, "StickSteering", 0) == 2 and ini.number(doc, controls.section, "PopOnRelease", 0) == 1, "keys")
    end)
    check("layouts read as the companion reads them", function()
        local doc = ini.parse("[SessionControls]\nFrontBackFoot=0\nSwitchStance=1\n")
        assert(controls.layout(doc) == 3, "legacy left / right")
        controls.set_layout(doc, 1)
        assert(controls.layout(doc) == 1 and ini.number(doc, controls.section, "SwitchSource", 0) == 4, "left / right")
        assert(not controls.set_layout(doc, 3), "the legacy layout is not set from here")
    end)
    check("a slot keeps the controls, and loading brings back the gameplay keys only", function()
        local doc = ini.parse("[SessionControls]\nPopOnRelease=1\nStickSteeringAngleDegrees=37\nControllerIndex=1\nMenuScale=2\n")
        assert(not controls.filled(doc, 2), "empty at first")
        controls.save(doc, 2)
        assert(controls.filled(doc, 2), "saved")
        assert(ini.get(doc, "CustomPreset2", "ManualCatch") == "0" and ini.get(doc, "CustomPreset2", "ControllerIndex") == "1",
            "fallbacks written, the rest of the section copied")
        ini.set(doc, controls.section, "PopOnRelease", 0)
        ini.set(doc, controls.section, "StickSteeringAngleDegrees", 20)
        ini.set(doc, controls.section, "ControllerIndex", 3)
        ini.set(doc, controls.section, "MenuScale", 1)
        assert(controls.load(doc, 2), "loaded")
        assert(ini.number(doc, controls.section, "PopOnRelease", 0) == 1 and controls.angle(doc) == 37, "gameplay back, angle exact")
        assert(ini.number(doc, controls.section, "ControllerIndex", 0) == 3 and ini.number(doc, controls.section, "MenuScale", 0) == 1,
            "controller and menu preferences kept")
    end)
    check("an older slot leaves the newer settings as they are", function()
        local doc = ini.parse("[SessionControls]\nManualCatch=1\n[CustomPreset1]\nPresetSaved=1\nPopOnRelease=1\n")
        assert(controls.load(doc, 1), "loaded")
        assert(ini.number(doc, controls.section, "ManualCatch", 0) == 1 and ini.number(doc, controls.section, "PopOnRelease", 0) == 1, "merged")
        assert(not controls.load(doc, 4), "an empty slot loads nothing")
    end)
    check("saving again replaces the slot", function()
        local doc = ini.parse("[SessionControls]\nPopOnRelease=1\n[CustomPreset3]\nPresetSaved=1\nOld=1\n")
        controls.save(doc, 3)
        assert(ini.get(doc, "CustomPreset3", "Old") == nil and ini.get(doc, "CustomPreset3", "PopOnRelease") == "1", "replaced")
    end)
    check("stance, ramp controls, the steering angle and the startup choice", function()
        local doc = ini.parse("[SessionControls]\n")
        assert(controls.stance(doc) == 0 and controls.ramp(doc) == 0 and controls.angle(doc) == 34 and controls.enabled_at_start(doc), "fallbacks")
        controls.set_stance(doc, 2)
        assert(controls.stance(doc) == 2 and ini.get(doc, controls.section, "Stance") == "goofy", "goofy")
        controls.set_ramp(doc, 2)
        assert(controls.ramp(doc) == 2, "early on ramp")
        controls.set_angle(doc, 90)
        assert(controls.angle(doc) == 60, "the angle is 5 to 60")
        controls.set_enabled_at_start(doc, false)
        assert(not controls.enabled_at_start(doc), "off at the next launch")
    end)
    check("a setting the page has no name for shows as custom", function()
        local doc = ini.parse("[SessionControls]\nRevertDoubleTapMs=275\n")
        local c
        for _, each in controls.choices do if each.key == "RevertDoubleTapMs" then c = each end end
        local value, index = controls.choice(doc, c)
        assert(value == 275 and index == nil, "custom")
    end)
    return list
end

function M.run()
    local passed, failures = 0, {}
    for _, case in cases() do
        local ok, why = pcall(case.fn)
        if ok then passed += 1 else table.insert(failures, case.name .. ": " .. tostring(why)) end
    end
    return passed, failures
end

return M
