-- Grind exit triggers: pick the side you pop out of a grind to with LT / RT, independently of the
-- trick and of the body's rotation (skate.'s own controls tie both to the left stick).
--
-- triggers.lua decides, each tick, which trigger picks the side and what the game must not see of
-- the pad (reskate.input.hide). At the pop ReSkate replaces only the sideways part of the game's
-- launch with the side asked for (reskate.skater.grind_exit): the game's own sideways speed when it
-- had one, mirrored to that side, else the game's usual 1.8 m/s, times the pop-out strength. Along
-- the rail, the pop's height, the trick, the flip and the rotation stay the game's.
local triggers = require("triggers")

local function setting(key, default, kind)
    local value = reskate.storage.get(key)
    if type(value) == kind then return value end
    return default
end
local settings = {
    on = setting("on", true, "boolean"),
    toe_heel = setting("toe_heel", true, "boolean"), -- else left/right of travel
    stance = setting("stance", "", "string"),        -- "", "regular" or "goofy"
    strength = setting("strength", 100, "number"),   -- percent of the full sideways speed, 10 to 100
    guard = setting("guard", true, "boolean"),
    lean_guard = setting("lean_guard", true, "boolean"),
    prewindow = setting("prewindow", 1, "number"),   -- seconds a trigger may be pressed before the grind connects
}
local state = triggers.new()
local grinding = false
local wished = nil   -- the side last asked of ReSkate ("toe", "heel", "left", "right"), or nil
local hidden_key = ""
local pops, applied = 0, 0
local last_pop = "none yet"
local why_not = nil  -- ReSkate's refusal, when it refused

local function save(key, value)
    settings[key] = value
    reskate.storage.set(key, value)
end
local function wish(side)
    if side == wished then return end
    wished = side
    local ok, why
    if side then
        local stance = settings.stance ~= "" and settings.stance or nil
        ok, why = reskate.skater.grind_exit({side = side, stance = stance, strength = settings.strength / 100})
    else
        ok, why = reskate.skater.grind_exit(nil)
    end
    why_not = not ok and tostring(why) or nil
end
local function hide(h)
    local key = tostring(h.left_trigger) .. tostring(h.right_trigger) .. tostring(h.left_x)
    if key == hidden_key then return end
    hidden_key = key
    reskate.input.hide(h)
end
local function reset()
    state = triggers.new()
    wish(nil)
    hide({})
end

reskate.on("skater_state", function(now) grinding = now == "grinding" end)

reskate.on("tick", function()
    if not settings.on then return end
    local now = reskate.time.now()
    local pad = reskate.input.gamepad()
    triggers.step(state, now, pad and pad.left_trigger, pad and pad.right_trigger, grinding, settings.prewindow * 1000)
    hide(triggers.hidden(state, settings.guard, settings.lean_guard))
    local trigger = triggers.chosen(state, now)
    wish(trigger and triggers.side(trigger, settings.toe_heel) or nil)
end)

-- Each pop out of a grind, as it went.
reskate.on("grind_exit", function(pop)
    pops += 1
    if pop.applied then applied += 1 end
    last_pop = pop.applied and string.format("%s of travel (%s), sideways %+.2f -> %+.2f m/s", pop.side, pop.basis or "-", pop.before, pop.after)
        or pop.reason == "kept" and "the game already chose that side"
        or pop.reason == "none" and "no trigger: the game's own exit"
        or pop.reason == "slow" and "too slow to tell the rail's direction"
        or "the launch did not match the skater's grind"
end)

-- ---- the switches ----------------------------------------------------------------------------

local function set_on(on)
    if on == settings.on then return end
    save("on", on)
    if not on then reset() end
end
local function status()
    local stance = settings.stance ~= "" and settings.stance or "NOT SET (grindexit stance goofy|regular)"
    local text = string.format("%s. Sides: %s. Stance: %s. Pop-out strength %d%%. Grab guard %s, lean guard %s, pre-press window %.2f s. " ..
        "Pops out of grinds seen: %d, sides set: %d. Last: %s.",
        settings.on and "ON" or "off", settings.toe_heel and "LT toe / RT heel" or "LT left / RT right of travel", stance, settings.strength,
        settings.guard and "on" or "off", settings.lean_guard and "on" or "off", settings.prewindow, pops, applied, last_pop)
    if settings.on and settings.toe_heel and settings.stance == "" then text ..= " Until the stance is set, LT/RT are left/right of travel." end
    if why_not then text ..= " ReSkate refused: " .. why_not end
    return text
end

local function answer(args)
    local function say(text) reskate.console.print("grindexit: " .. text) end
    local verb, arg = args[1] or "status", args[2]
    if verb == "status" then return say(status()) end
    if verb == "exits" then
        if arg == "on" or arg == "off" then set_on(arg == "on") end
        return say(status())
    end
    if verb == "stance" then
        if arg ~= "goofy" and arg ~= "regular" then return say("grindexit stance goofy|regular (your skater's stance in the game settings)") end
        save("stance", arg)
        wished = nil -- asked again with the stance
        return say(status())
    end
    if verb == "sides" then
        if arg ~= "toeheel" and arg ~= "travel" then return say("grindexit sides toeheel|travel") end
        save("toe_heel", arg == "toeheel")
        return say(status())
    end
    if verb == "strength" then
        local value = tonumber(arg)
        if not value or value ~= math.floor(value) or value < 10 or value > 100 then
            return say("grindexit strength <10 to 100> (percent of the full pop-out to the side; 100 is the game's own)")
        end
        save("strength", value)
        wished = nil
        return say(status())
    end
    if verb == "guard" or verb == "leanguard" then
        if arg ~= "on" and arg ~= "off" then return say("grindexit " .. verb .. " on|off") end
        save(verb == "guard" and "guard" or "lean_guard", arg == "on")
        return say(status())
    end
    if verb == "prewindow" then
        local value = tonumber(arg)
        if not value or value < 0 or value > 2 then return say("grindexit prewindow <0 to 2> (seconds a trigger may be pressed before the grind connects; 1)") end
        save("prewindow", value)
        return say(status())
    end
    if verb == "test" then
        local passed, failures = require("tests").run()
        for _, failure in failures do say("FAIL " .. failure) end
        return say(string.format("%d passed, %d failed", passed, #failures))
    end
    say("grindexit exits on|off|status, stance goofy|regular, sides toeheel|travel, strength <10-100>, guard on|off, leanguard on|off, prewindow <s>, test")
end
reskate.console.command("grindexit", "Pick the side you pop out of a grind with LT / RT: exits on|off, stance, sides, strength, guard, leanguard",
    answer)

-- Its page in the menu's PLUGINS section.
reskate.menu.page("Grind Exits", function(ui)
    ui:card("GRIND EXITS", "Choose the side you pop out of a grind using LT/RT")
    set_on(ui:toggle("on", "Grind exit triggers", settings.on,
        "Press LT or RT while grinding (or up to a second before the grind connects) to pick the side you pop out to. Keep it held until you land."))
    local mode = ui:dropdown("mode", "Input mode", {"Toe / Heel", "Left / Right"}, settings.toe_heel and 1 or 2,
        settings.toe_heel and "LT pops out to your toe side, RT to your heel side." or "LT pops out to the left of your direction of travel, RT to the right.")
    if (mode == 1) ~= settings.toe_heel then save("toe_heel", mode == 1) end
    if settings.toe_heel then
        local stance = ui:dropdown("stance", "Your stance", {"Not set", "Regular", "Goofy"},
            settings.stance == "regular" and 2 or settings.stance == "goofy" and 3 or 1, "Your skater's stance in the game's settings.")
        local wanted = stance == 2 and "regular" or stance == 3 and "goofy" or ""
        if wanted ~= settings.stance then
            save("stance", wanted)
            wished = nil
        end
        if settings.stance == "" then ui:warn("Pick your stance. Until then LT / RT are left / right of travel.") end
    end
    local strength = math.floor(ui:slider("strength", "Pop-out strength", settings.strength, 10, 100, "%d%%") + 0.5)
    if strength ~= settings.strength then
        save("strength", strength)
        wished = nil
    end
    ui:note("How far to the side a trigger exit pops. 100% is the full exit; lower it for rails next to a wall.")

    ui:card("GUARDS")
    if ui:toggle("guard", "Grab guard", settings.guard,
        "The trigger that picked the side is kept from the game until you let go, so holding it through the pop does not grab.") ~= settings.guard then
        save("guard", not settings.guard)
    end
    if ui:toggle("lean", "Lean guard", settings.lean_guard,
        "While the trigger is held in a grind, the left stick's left/right waits for the pop, so the game's lean exit cannot pull the board the other way.")
        ~= settings.lean_guard then
        save("lean_guard", not settings.lean_guard)
    end

    ui:card("POPS")
    ui:info("Seen", string.format("%d out of grinds, %d sides set", pops, applied))
    ui:info("Last", last_pop)
    if why_not then ui:warn("ReSkate refused: " .. why_not) end
end)

-- Its pops are heard from the start, before any trigger picks a side.
reskate.on("load", function() reskate.skater.grind_exit(nil) end)
reskate.on("unload", reset)
reskate.log("grind exits " .. (settings.on and "on" or "off") .. ": grindexit status")
