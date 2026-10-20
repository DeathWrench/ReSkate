-- Throwdown modes test: two modes on the game's Throwdowns page, through the whole native flow of
-- the throwdown kit (card, Spot Battle's setup page relabelled from this plugin's setup document,
-- the start flag, the waiting card). It runs no match: it says in chat what it hears, and lets the
-- flag go when the host presses Start. Both use Spot Battle's own art and flag.
local function say(text)
    reskate.chat.notice(text)
    reskate.log(text)
end

local modes = {
    duel = {id = "duel", name = "Duel", description = "Beat the last total. Three misses and you're out. Last skater wins!",
            players = {min = 1, max = 6, default = 2}, timer = {caption = "Turn", min = 10, max = 120, step = 10, value = 20}, rows = {}},
    gates = {id = "gates", name = "Gates", description = "Skate through the gates. First to the finish wins.",
             players = {min = 1, max = 8, default = 4}, timer = {caption = "Finish deadline", min = 30, max = 600, step = 30, value = 180},
             rows = {{id = "laps", kind = "choice", caption = "Laps", options = {"1", "2", "3"}, value = 1},
                     {id = "boost", kind = "slider", caption = "Boost", min = 0, max = 5, step = 1, value = 2},
                     {id = "route", kind = "button", caption = "Route", label = "Place gates"}}},
}
local function register()
    for _, id in ipairs({"duel", "gates"}) do
        local m = modes[id]
        assert(reskate.throwdowns.mode{id = m.id, name = m.name, description = m.description, players = m.players})
    end
end
register()

-- The one mode being set up or waiting, and what the plugin shows for it.
local current = nil -- {mode, game, placed}
local function publish()
    local doc = {}
    if current then
        local m = modes[current.mode]
        if not current.placed then
            doc.setup = {mode = m.id, title = string.upper(m.name), description = m.description,
                         players = {caption = "Players", min = m.players.min, max = m.players.max, step = 1, value = m.players.default},
                         timer = m.timer, rows = m.rows}
        else
            doc.waiting = {mode = m.id, title = string.upper(m.name), status = "Enrolled skaters  |  Host starts", enrolled = 1,
                           capacity = m.players.max, can_start = true}
        end
    end
    assert(reskate.throwdowns.ui(doc))
end

local last = "nothing yet"
reskate.on("throwdown_ui", function(e)
    local line = e.mode .. ": " .. e.action .. " (" .. table.concat(e.args, ", ") .. ")"
    last = line
    say(line)
    if e.action == "open" then
        current = {mode = e.mode, game = tonumber(e.args[1]), placed = false}
    elseif e.action == "flag_placed" and current then
        current.placed = true
    elseif e.action == "start" then
        -- A real mode would start its match here.
        reskate.throwdowns.flag.leave()
        say(e.mode .. ": the match would start now")
        current = nil
    elseif e.action == "leave" or e.action == "setup_back" or e.action == "flag_left" then
        current = nil
    end
    publish()
end)

reskate.console.command("tdmodes", "Throwdown modes test: what it heard last (tdmodes off takes the modes away, tdmodes on puts them back)", function(args)
    if args[1] == "off" then
        reskate.throwdowns.remove_mode("duel")
        reskate.throwdowns.remove_mode("gates")
        reskate.console.print("tdmodes: removed")
    elseif args[1] == "on" then
        register()
        reskate.console.print("tdmodes: registered")
    else
        reskate.console.print("tdmodes: " .. last)
    end
end)
