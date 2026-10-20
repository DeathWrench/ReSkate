-- Hall of Meat's score card, as in skate. 3: a row per stat, with skate.'s own icon for it, then the
-- Meat. No game access.
local model = require("model")
local card = {}

-- When a stat comes onto the card: once the bail has done something worth showing, so a small bail's
-- card stays short and a big one grows as it goes. The time shows from the start; the Meat counts
-- every stat whether shown or not.
card.hits_shown, card.broken_shown = 5, 5
card.road_rash_shown_feet, card.airtime_shown_seconds, card.fall_shown_feet = 15, 3, 100
card.speed_shown_mph, card.rotations_shown = 20, 2
-- skate. shows lengths in feet and speeds in miles per hour.
card.feet_per_metre = 3.28084
card.mph_per_metre_per_second = 2.23694
-- Each stat's row, by the game's picture it shows, in the card's order.
card.icons = {
    time = "stopwatch", hits = "wipeout", broken = "wipeout_broken", road_rash = "spread_eagle",
    airtime = "airtime", fall = "gap_height", speed = "flaming_wheel", rotations = "roll",
}

-- 12,345 and -1,234, as skate. shows its numbers.
function card.grouped(value)
    value = math.floor(value + 0.5)
    local negative = value < 0
    local digits = tostring(math.abs(value))
    local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return (negative and "-" or "") .. out
end

-- The card for what is drawn now, against the map's best before the bail (nil: unknown). No card
-- while riding.
function card.make(view, against)
    if view.phase == "riding" then return {opacity = 0, rows = {}, total = 0, badge = ""} end
    local t = view.tally
    local result = {opacity = view.alpha, rows = {}, total = t.score, badge = "", highlight = false}
    local function row(shown, stat, value, points)
        if shown then table.insert(result.rows, {stat = stat, value = value, points = points}) end
    end
    local road_rash, fallen = t.scraped * card.feet_per_metre, t.fallen * card.feet_per_metre
    local speed = t.top_speed * card.mph_per_metre_per_second
    row(true, "time", string.format("%.1f s", t.seconds), t.time_points)
    row(t.impacts >= card.hits_shown, "hits", card.grouped(t.impacts) .. (t.impacts == 1 and " hit" or " hits"),
        t.hit_points + t.head_bonus + t.vehicle_bonus)
    row(t.broken >= card.broken_shown, "broken", card.grouped(t.broken) .. " broken", t.broken * model.points_per_break)
    row(road_rash >= card.road_rash_shown_feet, "road_rash", string.format("%.1f ft", road_rash), t.scrape_points)
    row(t.airtime >= card.airtime_shown_seconds, "airtime", string.format("%.1f s", t.airtime), t.airtime_points)
    row(fallen >= card.fall_shown_feet, "fall", string.format("%.1f ft", fallen), t.fall_points)
    row(speed >= card.speed_shown_mph, "speed", string.format("%.1f MPH", speed), t.speed_points)
    row(t.rotations >= card.rotations_shown, "rotations", string.format("%.1f rotations", t.rotations), t.rotation_points)
    if against and against.new_best then
        result.badge, result.highlight = "NEW BEST", true
    elseif against and against.best > 0 then
        result.badge = "BEST " .. card.grouped(against.best)
    end
    return result
end

return card
