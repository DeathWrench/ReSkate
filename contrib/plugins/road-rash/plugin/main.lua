-- Road Rash: bails leave marks on the local skater that build up over a session. After ten bails
-- the leg and then the arm of the side that took more of them show road dust and a graze, later
-- real scrapes and bruises, and from twenty raw wounds and a bruised face; the other side follows
-- a few bails behind. A mark never gets smaller until the skater is healed (`roadrash heal`) or
-- the game is closed.
--
-- The marks are the skin items of the Road Rash item pack this plugin comes in (rules.lua has their
-- names), worn over the outfit with reskate.outfit: ReSkate gives the skater back to the game while one of its menus is up and
-- puts them on again after. A slot that holds one of the player's own tattoos or moles keeps it,
-- unless the player lets the wounds cover it.
local rules = require("rules")

local function setting(key, default)
    local value = reskate.storage.get(key)
    if type(value) == "boolean" then return value end
    return default
end
local settings = {on = setting("on", true), blood = setting("blood", true), covers = setting("covers", false)}

local tally = rules.tally()
local designs = {}     -- which design each part wears: drawn afresh whenever the skater is clean
local worn = {}        -- by part: what reskate.outfit.set last took for it
local hold_until = 0   -- nothing goes on before then, so the skater is the game's for a moment
local retry_at = 0     -- after a refusal
local last_fall = -math.huge
local status = "nothing to show"
local missing_told = false

math.randomseed(math.floor(reskate.time.now()) % 1000003)
local function draw_designs()
    for _, part in rules.parts do designs[part] = math.random(1, #rules.designs) end
end
draw_designs()

-- Takes every mark off. With `again` they go back on a moment later, worked out afresh over the
-- outfit as it is by then: the player's own tattoos come back first when wounds no longer cover them.
local function take_off(again)
    reskate.outfit.clear()
    table.clear(worn)
    if again then hold_until = reskate.time.now() + 1500 end
end
local function heal()
    tally = rules.tally()
    draw_designs()
    missing_told = false
    take_off(false)
end

-- Puts on the item each part's level wants, a few at a time: ReSkate takes 4 changes a second.
local function wear()
    local now = reskate.time.now()
    if now < hold_until or now < retry_at then return end
    if not settings.on then
        status = "off"
        return
    end
    local shown, missing = 0, false
    for _, part in rules.parts do
        local level = tally.levels[part]
        if level == 0 then continue end
        local item, at = rules.wanted(part, level, designs[part], settings.blood, reskate.outfit.find)
        if not item then
            missing = true
            continue
        end
        local key = item .. (settings.covers and " covers" or "")
        if worn[part] ~= key then
            local placement = part ~= "face" and rules.placement(part, at) or nil
            local ok, why = reskate.outfit.set(rules.slots[part], item, {placement = placement, covers = settings.covers})
            if not ok then
                status = "waiting: " .. tostring(why)
                retry_at = now + (tostring(why):find("in a second", 1, true) and 300 or 2000)
                return
            end
            worn[part] = key
        end
        shown += 1
    end
    -- Items are only found while there is a skater: without one, nothing is missing yet.
    if missing and shown == 0 then
        if not missing_told and #reskate.outfit.slots() > 0 then
            missing_told = true
            reskate.log("the skater has marks to show, but the Road Rash items are not in the game (this plugin ships inside the Road Rash item pack)")
        end
        status = missing_told and "the Road Rash items are not in the game (this plugin ships inside the Road Rash item pack)" or "waiting for the skater"
    else
        status = shown > 0 and string.format("%d mark(s) worn", shown) or "nothing to show"
    end
end
reskate.time.every(250, wear)

-- A fall's side from what the limbs of each side hit.
reskate.on("bail_end", function(fall)
    if not settings.on then return end
    local started = reskate.time.now() - (tonumber(fall.seconds) or 0) * 1000
    -- One slam can enter the wipeout more than once.
    if started - last_fall < 1500 then return end
    last_fall = started
    rules.count(tally, rules.side(tonumber(fall.left) or 0, tonumber(fall.right) or 0))
end)

-- ---- the switches --------------------------------------------------------------------------

local function save(key, value)
    settings[key] = value
    reskate.storage.set(key, value)
end
local function set_on(on)
    if on == settings.on then return end
    save("on", on)
    -- Off: the marks go, and so does the count.
    if not on then heal() end
end
local function set_blood(blood)
    if blood == settings.blood then return end
    save("blood", blood)
    take_off(true)
end
local function set_covers(covers)
    if covers == settings.covers then return end
    save("covers", covers)
    take_off(true)
end
-- Counts as if the skater had bailed this often, half of it on each side, to look at a stage.
local function set_bails(bails)
    heal()
    tally = rules.counted(math.min(bails, 1000))
end

local function word(on) return on and "on" or "off" end
local function switch(text)
    if text == "1" or text == "on" or text == "true" then return true end
    if text == "0" or text == "off" or text == "false" then return false end
    return nil
end

-- ---- the console ---------------------------------------------------------------------------

local function answer(name)
    return function(args)
        local function say(text) reskate.console.print(name .. ": " .. text) end
        local what = args[1]
        if what == nil then
            say(string.format("%s, %d bail(s) counted (%s); blood %s, covers tattoos %s; %s (outfit: %s)", word(settings.on), tally.bails,
                rules.describe(tally), word(settings.blood), word(settings.covers), status, reskate.outfit.status()))
        elseif switch(what) ~= nil then
            set_on(switch(what))
            say(word(settings.on))
        elseif what == "heal" then
            heal()
            say("healed")
        elseif what == "bails" then
            local count = tonumber(args[2])
            if not count or count < 0 or count ~= math.floor(count) then return say("bails needs a count (10, 14 and 20 are the steps)") end
            if not settings.on then return say("it is off: " .. name .. " 1 switches it on") end
            set_bails(count)
            say("counted " .. tally.bails .. " (" .. rules.describe(tally) .. ")")
        elseif what == "blood" or what == "tattoos" then
            local value = switch(args[2])
            if value ~= nil then
                if what == "blood" then set_blood(value) else set_covers(value) end
            end
            say(what .. " " .. word(if what == "blood" then settings.blood else settings.covers))
        elseif what == "test" then
            local passed, failures = require("tests").run()
            for _, failure in failures do say("FAIL " .. failure) end
            say(string.format("%d passed, %d failed", passed, #failures))
        else
            say("say " .. name .. " 0|1, heal, bails <count>, blood 0|1 or tattoos 0|1")
        end
    end
end
local help = "Bails leave marks that build up (needs the Road Rash items): 0|1, heal, bails <count>, blood 0|1, tattoos 0|1"
-- While ReSkate has a Road Rash of its own, roadrash is its command: this one answers to road rash.
local name = "roadrash"
if not pcall(reskate.console.command, name, help, answer(name)) then
    name = "road rash"
    reskate.console.command(name, help, answer(name))
end

-- ---- the menu: its page in the menu's PLUGINS section ---------------------------------------

reskate.menu.page("Road Rash", function(ui)
    ui:card("ROAD RASH", "Bails leave their mark")
    set_on(ui:toggle("on", "Road Rash", settings.on,
        "Bails leave marks that build up: dust, scrapes, bruises, wounds. Needs the Road Rash item pack."))
    set_blood(ui:toggle("blood", "Fresh blood", settings.blood, "Fresh blood on the worst wounds. Off, they are dry and scabbed."))
    set_covers(ui:toggle("covers", "Wounds cover your tattoos", settings.covers,
        "Wounds may take the place of your own tattoos and moles; they come back when you heal."))

    ui:card("YOUR SKATER", string.format("%d bail(s) counted", tally.bails))
    ui:info("Marks", rules.describe(tally))
    ui:info("Now", status)
    if ui:button("heal", "HEAL", true) then heal() end
    ui:note("Healing takes every mark off and starts the count again.")
end)

reskate.log(string.format("Road Rash %s (blood %s): %s heal takes the marks off", word(settings.on), word(settings.blood), name))
