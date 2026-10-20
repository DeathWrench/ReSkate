-- Board Break: a hard slam can break the local skater's board. It snaps at the nose, in the middle
-- or at the tail; half the time the grip tape holds the pieces together and the board folds or an
-- end hangs, otherwise a piece comes off, flies and lies where it lands. A hard boardslide or
-- darkslide onto a rail can snap it too, and boards wear out with every hit, breaking more easily
-- as they do. The board is whole (and new) again once the skater has picked it up, rides again or
-- respawns.
--
-- The pieces are not drawn here: they are in the deck model of the Board Break deck pack this
-- plugin comes in, four stretches of deck (nose, front, back, tail) on spare bones of the board's
-- rig (contrib/board-break.md says how such a model is made). This only moves bones, with
-- reskate.board: the stretches are kept out of sight on every board, and on a broken board the
-- real deck goes away and each stretch goes to where its piece lies. The sounds are the pack's,
-- sounds/light|medium|heavy|body/*.wav.
--
-- The game has one deck model for every board, so the pack's decks (decks/<name>/) are variants of
-- it, as reskate-plugin.json declares them: one is in the game at a time, the one chosen on this
-- plugin's page or with `boardbreak deck`.
--
-- The rules are in breaker.lua, the geometry in model.lua, the numbers in feel.lua.
local breaker = require("breaker")

-- ---- sounds --------------------------------------------------------------------------------------
-- A few of each kind: a plugin plays at most 32 different waves. A crack size with no folder of
-- its own takes the wave files in sounds/ itself.
local per_kind = 6
local function waves(folder)
    local out = {}
    local ok, names = pcall(reskate.package.list, folder)
    if not ok or type(names) ~= "table" then return out end
    for _, name in names do
        if #out < per_kind and string.lower(string.sub(name, -4)) == ".wav" then table.insert(out, folder .. "/" .. name) end
    end
    return out
end
local sounds = {}
local loose = waves("sounds")
for _, kind in {"light", "medium", "heavy", "body"} do
    sounds[kind] = waves("sounds/" .. kind)
    if #sounds[kind] == 0 and kind ~= "body" then sounds[kind] = loose end
end
local function play(kind, volume)
    local list = sounds[kind]
    if #list == 0 then return end
    local index = math.random(1, #list)
    local ok, played, why = pcall(reskate.audio.play, list[index], {volume = math.clamp(volume, 0, 1)})
    if not ok then
        -- A file that is no wave the game can play: left out from now on.
        reskate.log("the sound " .. list[index] .. " cannot be played: " .. tostring(played))
        table.remove(list, index)
    elseif not played and why then
        reskate.log("a sound was not played: " .. tostring(why))
    end
end

-- ---- the game, as breaker.lua takes it -------------------------------------------------------------
math.randomseed(math.floor(reskate.time.now()) % 1000003)
local game = {
    now = reskate.time.now,
    random = function() return math.random() end,
    bones = reskate.board.bones,
    velocity = function()
        local motion = reskate.board.motion()
        return motion and motion.velocity
    end,
    skater = reskate.skater.position,
    raycast = reskate.world.raycast,
    board = reskate.board,
    sound = function(kind) return sounds[kind] ~= nil and #sounds[kind] > 0 end,
    play = play,
    wipeout = function(force)
        local ok, why = reskate.skater.wipeout(force)
        if not ok then reskate.log("the rider stays up: " .. tostring(why)) end
    end,
    toast = function(text, level) reskate.ui.toast(text, level) end,
    log = reskate.log,
    load = reskate.storage.get,
    save = reskate.storage.set,
}
local bb = breaker.new(game)
bb.state = reskate.skater.state() or "none"

-- ---- the deck --------------------------------------------------------------------------------------
-- Each deck says of itself in its deck.ini what it is called (label) and how far apart its wheels sit
-- (axle: 1 a standard board's, more on a wider deck).
local setups = {}
local function deck_setup(name)
    if setups[name] then return setups[name] end
    local setup = {axle = 1}
    local ok, text = pcall(reskate.package.read, "decks/" .. name .. "/deck.ini")
    if ok and type(text) == "string" then
        for line in string.gmatch(text, "[^\r\n]+") do
            local key, value = string.match(string.gsub(line, "[#;].*", ""), "^%s*([%w_]+)%s*=%s*(.-)%s*$")
            key = key and string.lower(key)
            if key == "label" and value ~= "" then
                setup.label = value
            elseif key == "axle" and tonumber(value) then
                setup.axle = math.clamp(tonumber(value), 0.8, 1.6)
            end
        end
    end
    -- Else its folder's name, in words.
    setup.label = setup.label or (string.gsub(string.gsub(name, "_", " "), "(%a)(%w*)", function(first, rest) return string.upper(first) .. rest end))
    setups[name] = setup
    return setup
end
local function decks()
    local ok, state = pcall(reskate.package.variants)
    return if ok and type(state) == "table" then state else {list = {}}
end
-- Every board in the game, other players' too, has the deck in the game: its trucks' baseplates are
-- held on the deck and its wheels sit as far apart as its trucks have them. Looked at again every
-- 2 s, as a deck chosen here is in the game once the level has loaded again.
local fitted = false
local function fit_boards()
    local deck = decks().in_play
    if deck == fitted then return end
    fitted = deck
    local ok, why = reskate.board.fit(if deck then {plates = true, axle = deck_setup(deck).axle} else nil)
    if not ok and why then reskate.log("the boards are not fitted for the deck: " .. tostring(why)) end
end
fit_boards()
reskate.time.every(2000, fit_boards)
-- The deck `word` means (a name, its number in the list, or "next"), put in the game. What happened.
local function choose_deck(word)
    local state = decks()
    if #state.list == 0 then return "none of the pack's decks is in its decks folder." end
    local chosen
    if word == "next" then
        chosen = state.list[1]
        for i, name in state.list do
            if name == state.in_play then chosen = state.list[i % #state.list + 1] end
        end
    elseif tonumber(word) then
        chosen = state.list[tonumber(word)]
    else
        chosen = string.lower(string.gsub(word, " ", "_"))
    end
    if not chosen then return "there is no such deck." end
    if chosen == state.in_play then return "the " .. deck_setup(chosen).label .. " deck is the one in the game." end
    local done, why = reskate.package.choose(chosen)
    if not done then return "the " .. chosen .. " deck: " .. tostring(why) end
    return "the " .. deck_setup(chosen).label .. " deck: the mods are applied and the level loads again with it."
end
local function deck_list()
    local state, parts = decks(), {}
    for i, name in state.list do
        table.insert(parts, i .. " " .. deck_setup(name).label .. (if name == state.in_play then " (in the game)" else ""))
    end
    return if #parts > 0 then table.concat(parts, ", ") else "none of the pack's decks is in its decks folder."
end

reskate.on("tick", function(dt) bb:tick(dt) end)
reskate.on("skater_state", function(now, previous) bb:skater_state(now, previous) end)
reskate.on("bail", function(e) bb:bail(e.force) end)
reskate.on("board_landed", function(e) bb:landed(e.onto, e.down_speed) end)
reskate.on("body_hit", function(e) bb:body_hit(e.impact) end)
reskate.on("level_unloading", function() bb:mend("the level unloads") end)
reskate.on("unload", function() reskate.board.clear() end)

-- A new board: no wear, and whole if it was broken.
local function new_board()
    bb:mend("a new board")
    bb:set_wear(0)
end
local function snap(place)
    if bb.broken then return "it is broken already: mend it first." end
    local carried = bb.state == "off_board"
    if not bb:snap(place, {asked = true, carried = carried, why = "asked for"}) then return "there is no board." end
    return "snapped" .. (if carried then " (the grip tape holds while you carry it)" else "") .. "; it stays so until mended or you respawn."
end

-- ---- the console ---------------------------------------------------------------------------------
local function answer(name)
    local function say(text) reskate.console.print(name .. ": " .. text) end
    local function switch(word)
        if word == "1" or word == "on" or word == "yes" then return 1 end
        if word == "0" or word == "off" or word == "no" then return 0 end
        return tonumber(word)
    end
    return function(args)
        local what = args[1]
        if what == nil or what == "status" then return say(bb:status()) end
        local value = switch(what)
        if value == 0 or value == 1 then
            bb:set_on(value == 1)
            return say(if bb.on then "on" else "off: boards hold; one that is broken stays so until it is picked up")
        end
        if what == "deck" then
            return say(if args[2] then choose_deck(table.concat(args, " ", 2)) else deck_list())
        elseif what == "snap" then
            local place = args[2]
            if place ~= nil and place ~= "nose" and place ~= "mid" and place ~= "tail" then return say("snap nose, mid, tail, or nothing for anywhere") end
            return say(snap(place))
        elseif what == "mend" then
            return say(if bb:mend("asked for") then "mended" else "the board is whole")
        elseif what == "new" then
            new_board()
            return say("a new board")
        elseif what == "worn" then
            if args[2] then
                local percent = tonumber(args[2])
                if not percent then return say("give a percent, 0 to 100") end
                bb:set_wear(percent / 100)
            end
            return say(string.format("the board is %s, %d%% worn", require("feel").condition(bb.wear), math.floor(bb.wear * 100 + 0.5)))
        elseif what == "test" then
            local passed, failures = require("tests").run()
            for _, failure in failures do say("FAIL " .. failure) end
            return say(string.format("%d passed, %d failed", passed, #failures))
        elseif bb:setting(what) ~= nil then
            if args[2] then
                local number = switch(args[2])
                if not number or not bb:set_setting(what, number) then return say("give a number (or on/off)") end
            end
            return say(what .. " is " .. bb:setting(what))
        end
        say("say " .. name .. " 0|1, status, deck [name|number|next], snap [nose|mid|tail], mend, new, worn [percent], or a setting: " ..
            "always, sensitivity, joined, rails, wear, wearrate, cracks, bodysounds")
    end
end
local help = "A hard slam can snap your board (needs the Board Break deck pack): 0|1, status, deck, snap, mend, new, worn, settings"
-- While ReSkate has a Board Break of its own, boardbreak is its command: this one answers to board break.
local name = "boardbreak"
if not pcall(reskate.console.command, name, help, answer(name)) then
    name = "board break"
    reskate.console.command(name, help, answer(name))
end

-- ---- the menu: its page in the menu's PLUGINS section -------------------------------------------
local function toggle(ui, id, text, help)
    local on = ui:toggle(id, text, bb:setting(id) == 1, help)
    if on ~= (bb:setting(id) == 1) then bb:set_setting(id, if on then 1 else 0) end
end
local function slider(ui, id, text, low, high)
    local value = math.floor(ui:slider(id, text, bb:setting(id), low, high, "%d%%") + 0.5)
    if value ~= bb:setting(id) then bb:set_setting(id, value) end
end
reskate.menu.page("Board Break", function(ui)
    local feel = require("feel")
    ui:card("BOARD BREAK", "A hard slam can snap your board")
    local on = ui:toggle("on", "Board Break", bb.on,
        "A hard slam can snap your board: at the nose, in the middle or at the tail. Whole again once you pick it up. Needs the Board Break deck pack.")
    if on ~= bb.on then bb:set_on(on) end

    -- The deck: a button for each, the one in the game marked. Picking another loads the level again.
    local state = decks()
    if #state.list > 0 then
        ui:card("DECK", if state.in_play then deck_setup(state.in_play).label else "none in the game")
        for i, name in state.list do
            local label = i .. " " .. deck_setup(name).label .. (if name == state.in_play then " *" else "")
            if ui:button("deck_" .. name, label) and name ~= state.in_play then reskate.ui.toast(choose_deck(name)) end
        end
        if state.chosen and state.chosen ~= state.in_play then
            ui:note(deck_setup(state.chosen).label .. " is chosen and shows once the level has loaded again.")
        end
        ui:note("The deck every board in the game has, and the one that breaks. Picking another loads the level again.")
    end

    ui:card("YOUR BOARD", string.format("%d%% worn (%s)%s", math.floor(bb.wear * 100 + 0.5), feel.condition(bb.wear),
        if bb.broken then ", broken" else ""))
    ui:bar("Wear", bb.wear * 100, 0, 100)
    if ui:button("new", "NEW BOARD", true) then new_board() end
    if ui:button("snap", "SNAP IT, TO LOOK AT") then snap(nil) end
    if ui:button("mend", "MEND") then bb:mend("asked for") end

    ui:card("BREAKING")
    if not bb.on then ui:note("Switch Board Break on to change these.") end
    toggle(ui, "always", "Always break", "Every slam breaks the board, and every slide that comes down onto a rail: for replay clips.")
    toggle(ui, "rails", "Rail snaps", "A boardslide or darkslide that comes down too hard onto a rail or ledge can snap the board, and you go down with it.")
    slider(ui, "sensitivity", "Break sensitivity", feel.sensitivity_min, feel.sensitivity_max)
    ui:note("How easily a board breaks. 200% takes half the force, 50% twice as much.")
    slider(ui, "joined", "Grip tape holds", 0, 100)
    ui:note("How many breaks the grip tape holds together instead of a piece coming off.")

    ui:card("WEAR")
    toggle(ui, "wear", "Wear and tear", "Every hit wears your board. A worn board turns lazier, wobbles and breaks more easily; worn out, it can give way.")
    slider(ui, "wearrate", "Wear speed", feel.rate_min, feel.rate_max)
    ui:note("How fast boards wear. 0% keeps a board as it is.")

    ui:card("SOUNDS")
    toggle(ui, "cracks", "Break sounds", "The crack of a break, and metal when it breaks on metal.")
    toggle(ui, "bodysounds", "Body hit sounds", "Each hit of your body in a bail, as hard as it hits.")
end)

reskate.log(string.format("Board Break loaded (%s): %s", name, bb:status()))
