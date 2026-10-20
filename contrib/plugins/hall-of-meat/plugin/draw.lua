-- What Hall of Meat draws: from the local skater's bail until they get up, the bones it hurt as an
-- x-ray over the world, the bail's score card in the bottom left corner (where skate.'s own HUD shows,
-- hidden meanwhile with reskate.hud.corner), and the screen's red edge when a bone breaks. Drawn with
-- skate.'s own icons, logo and brush strokes (d:game_image), read from the installed game.
local card = require("card")
local draw = {}

-- skate.'s colours, as the overlay's theme has them: dark tiles, its blue, white numbers.
local tile, blue, white, good, grey = {26, 26, 26, 240}, {1, 131, 255, 255}, {245, 245, 245, 255}, {46, 184, 92, 255}, {150, 152, 158, 255}
local bruised, broken, dark_red, hot = {255, 196, 36, 255}, {232, 32, 32, 255}, {150, 12, 12, 255}, {255, 255, 255, 255}

-- "#RRGGBBAA" for a colour at `opacity` of its own alpha.
local function hex(c, opacity)
    local a = math.clamp(math.floor(c[4] * math.clamp(opacity or 1, 0, 1) + 0.5), 0, 255)
    return string.format("#%02X%02X%02X%02X", c[1], c[2], c[3], a)
end
local function mix(from, to, amount)
    amount = math.clamp(amount, 0, 1)
    local out = {}
    for i = 1, 4 do out[i] = math.floor(from[i] + (to[i] - from[i]) * amount + 0.5) end
    return out
end
local function v(x, y) return vector.create(x, y, 0) end

-- The hurt bodies, painted: bruised ones yellow, broken ones a slowly pulsing red, a fresh hit
-- flashing white-hot; the rest are left out.
function draw.skeleton(d, view, seconds)
    local paint, any = {}, false
    for name, injury in view.injuries do
        if injury == "none" then continue end
        local colour = injury == "broken" and mix(dark_red, broken, 0.5 + 0.5 * math.sin(seconds * 6)) or bruised
        paint[name] = hex(mix(colour, hot, (view.flashes[name] or 0) * 0.8))
        any = true
    end
    if any then d:skeleton(paint, math.clamp(view.alpha, 0, 1)) end
end

-- The screen at `strength` (0 to 1), as a hard hit shows it: darkened a little, the broken bones' red
-- washing in from all four edges, top and bottom deeper than the sides.
function draw.break_pulse(d, strength)
    strength = math.clamp(strength, 0, 1)
    if strength <= 0 then return end
    local size = d:size()
    local w, h = size.x, size.y
    d:rect(v(0, 0), v(w, h), {colour = hex({0, 0, 0, 255}, 0.3 * strength), fill = true})
    local edge, clear = hex(broken, 0.7 * strength), hex(broken, 0)
    local vertical, horizontal = h * 0.3 * strength, w * 0.18 * strength
    -- Each band from its edge (the colour) inwards (clear); corners: top left, top right, bottom right, bottom left.
    d:gradient(v(0, 0), v(w, vertical), {edge, edge, clear, clear})
    d:gradient(v(0, h - vertical), v(w, h), {clear, clear, edge, edge})
    d:gradient(v(0, 0), v(horizontal, h), {edge, clear, clear, edge})
    d:gradient(v(w - horizontal, 0), v(w, h), {clear, edge, edge, clear})
end

-- The card from frame to frame: the total counts up from what it last showed, and a row fades in from
-- when it came.
local motion = {total = 0, at = 0, since = {}}

-- The score card as skate. 3's Hall of Meat shows it, in the bottom left corner, growing upwards as rows
-- come: a brush bar per stat with its icon, value and points, then a scratched panel with the THRASHER
-- logo, the title in its arch, the total on a blue stroke and the badge.
function draw.card(d, shown, now)
    local size = d:size()
    if shown.opacity <= 0 or size.x <= 0 or size.y <= 0 then
        motion = {total = 0, at = 0, since = {}}
        return
    end
    -- The total catches up with its value in about a quarter of a second.
    local step = math.clamp((now - motion.at) / 1000, 0, 0.1)
    motion.at = now
    motion.total += (shown.total - motion.total) * (1 - math.exp(-step * 12))
    if math.abs(shown.total - motion.total) < 1 then motion.total = shown.total end

    -- From the screen's bottom left corner, in 1080p pixels; as wide as the logo it carries.
    local k, o = size.y / 1080, shown.opacity
    local left = 64 * k
    local right, pad = left + 250 * k, 14 * k
    local logo_height, title_size, total_size, badge_size = 72 * k, 22, 56, 18 -- text sizes are at 1080 lines
    local logo_step = logo_height * 0.70 + 4 * k -- the wordmark's arch leaves room beneath it
    local height = pad * 2 + logo_step + (title_size + total_size) * k + (shown.badge == "" and 0 or (badge_size + 4) * k)
    local row_height, row_gap, icon, text = 30 * k, 10 * k, 22 * k, 18

    -- A bar per stat. A new one opens and fades in, and the card grows upwards by it.
    local lines, rows_height = {}, 0
    for _, row in shown.rows do
        motion.since[row.stat] = motion.since[row.stat] or now
        local opened = math.clamp((now - motion.since[row.stat]) / 300, 0, 1)
        table.insert(lines, {row = row, top = rows_height, shown = opened})
        rows_height += (row_height + row_gap) * opened * (2 - opened) -- eases out
    end
    local y = size.y - 96 * k - height - rows_height
    for _, line in lines do line.top += y end
    y += rows_height
    -- Every bar before any row's content, so no bar's splatter covers another's numbers.
    for _, line in lines do
        d:game_image("brush_bar", v(left, line.top), v(right, line.top + row_height), {colour = hex(tile, o * line.shown * 0.92), fit = "shape"})
    end
    for _, line in lines do
        local row, middle = line.row, line.top + row_height / 2
        local x = left + pad
        d:game_image(card.icons[row.stat], v(x, middle - icon / 2), v(x + icon, middle + icon / 2), {colour = hex(blue, o * line.shown)})
        x += icon + 10 * k
        local style = {colour = hex(white, o * line.shown), size = text, font = "bold"}
        d:text(v(x, middle - text * k / 2), row.value, style)
        d:text(v(right - pad, middle - text * k / 2), card.grouped(row.points), {colour = style.colour, size = text, font = "bold", align = "right"})
    end

    local edge = 16 * k
    d:game_image("rough_tile", v(left, y), v(right, y + height), {colour = hex(tile, o * 0.92), fit = "panel", edge = 16})
    d:game_image("scratches", v(left + edge, y + edge), v(right - edge, y + height - edge), {colour = hex(white, o * 0.5), fit = "shape"})
    local centre = (left + right) / 2
    y += pad
    d:game_image("thrasher", v(left + pad, y), v(right - pad, y + logo_height), {colour = hex(blue, o)})
    y += logo_step
    d:text(v(centre, y), "Hall of Meat", {colour = hex(white, o), size = title_size, font = "heading", align = "centre"})
    y += title_size * k
    local total = card.grouped(motion.total)
    -- The blue stroke under the total, about as wide as its digits.
    local stroke = #total * total_size * k * 0.3 + 20 * k
    d:game_image("streak", v(centre - stroke, y + total_size * k * 0.55), v(centre + stroke, y + total_size * k * 0.95),
        {colour = hex(blue, o), fit = "shape"})
    d:text(v(centre, y), total, {colour = hex(white, o), size = total_size, font = "title", align = "centre"})
    y += total_size * k
    if shown.badge ~= "" then
        y += 4 * k
        d:text(v(centre, y), shown.badge, {colour = hex(shown.highlight and good or grey, o), size = badge_size, font = "bold", align = "centre"})
    end
end

return draw
