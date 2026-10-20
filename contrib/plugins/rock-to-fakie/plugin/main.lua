-- Rock to Fakie, by TheRealEJR (his Rock to Fakie mod, TheRealEJR/ReSkate-Rock-to-Fakie-mod, ported
-- to ReSkate in pull request 285), as a plugin. skate. has no button for a rock to fakie, but the
-- move is in the game: ride up to a coping, Board Stall or Lip Stall on it, and press B to roll back
-- in fakie. With this on, the game calls it what it is:
--   - the trick ticker shows Rock to Fakie for a Board Stall or a Lip Stall while the skater holds
--     it (reskate.tricks.label, only while the stall is held);
--   - a stall left with B is recorded as the game's own fakie_rock (reskate.tricks.record_as: B
--     pressed while the stall is held asks that the stall the game records within a moment of it be
--     recorded as fakie_rock).
-- The stall is the physics state the game chose (reskate.skater.telemetry's watch): 400 or 401
-- holds a stall or a grind, and only a stall's label or trick id is changed. Off until switched on.
local held_states = {[400] = true, [401] = true}
local board_stall, lip_stall, fakie_rock = 9, 12, 187 -- the game's trick ids (bs_board, bs_lip, fakie_rock)
local stall_labels = {"Board Stall", "Lip Stall"}
local name = "Rock to Fakie"
local b_button = 0x2000 -- XInput B, Circle on a PlayStation pad
-- B pressed while the stall is held, then the stall left: the game records it a moment later.
local record_window_ms = 250

local on = reskate.storage.get("on") == true
local labelled = false
local b_down = false
local asked, refused = 0, nil

local function show_labels(show)
    if show == labelled then return end
    labelled = show
    for _, label in stall_labels do
        local ok, why = reskate.tricks.label(label, if show then name else nil)
        if not ok then refused = why end
    end
end

reskate.on("tick", function()
    if not on then
        show_labels(false)
        b_down = false
        return
    end
    local t = reskate.skater.telemetry()
    local watch = t and t.watch
    local stalled = watch ~= nil and watch.valid and held_states[watch.state] == true
    show_labels(stalled)
    local pad = reskate.input.pad_bits()
    local down = pad ~= nil and bit32.band(pad, b_button) ~= 0
    if down and not b_down and stalled then
        local ok, why = reskate.tricks.record_as({board_stall, lip_stall}, fakie_rock, record_window_ms)
        if ok then asked += 1 else refused = why end
    end
    b_down = down
end)

local function set_on(value)
    on = value
    reskate.storage.set("on", value)
    if not value then show_labels(false) end
end
local function status()
    return string.format("%s. %d rock to fakie(s) asked for this game%s.", if on then "on" else "off", asked,
        if refused then "; last refusal: " .. refused else "")
end

reskate.console.command("rocktofakie", "Rock to Fakie: on|off|status", function(args)
    local word = args[1] or "status"
    if word == "on" or word == "1" then set_on(true)
    elseif word == "off" or word == "0" then set_on(false)
    elseif word ~= "status" then return reskate.console.print("rocktofakie: say on, off or status") end
    reskate.console.print("rocktofakie: " .. status())
end)

reskate.menu.page("Rock to Fakie", function(ui)
    ui:card("ROCK TO FAKIE", "Board Stall or Lip Stall, then B")
    local value = ui:toggle("on", "Rock to Fakie", on,
        "Ride up to a coping, Board Stall or Lip Stall on it, and press B to roll back in fakie: the ticker shows Rock to Fakie, and the trick is recorded as one.")
    if value ~= on then set_on(value) end
    ui:note("Any Board Stall or Lip Stall counts, wherever it is done: the game does not say whether it is on a coping.")
    ui:info("Status", status())
end)

reskate.on("unload", function() show_labels(false) end)
reskate.log("Rock to Fakie " .. (if on then "on" else "off"))
