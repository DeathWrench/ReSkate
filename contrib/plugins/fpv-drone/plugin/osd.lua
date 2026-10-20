-- The goggle display (OSD), sticks, crosshair and analogue video look, as
-- Extension/Skater/drone_osd.h and UI/Overlay/drone_hud_overlay.cpp had them. layout() decides what
-- to show (plain, for the tests); draw() puts it on the overlay. The pixel font and the static are
-- pictures drawn by source rectangle (images/, made by contrib/plugins/tools/build_fpv_drone_images.py).
local flight = require("flight")
local osd = {}

local V = vector.create
local FONT, STATIC, SCAN, VIGNETTE = "images/font.png", "images/static.png", "images/scanlines.png", "images/vignette.png"

local function rgba(r, g, b, a)
    return ((math.floor(r) * 256 + math.floor(g)) * 256 + math.floor(b)) * 256 + math.clamp(math.floor(a), 0, 255)
end
osd.rgba = rgba
local function alpha(a)
    return math.clamp(a, 0, 1) * 255
end

-- The `osdcolor` presets: white, green, yellow, cyan, orange, pink.
osd.colours = {{255, 255, 255}, {90, 255, 90}, {255, 232, 70}, {90, 232, 255}, {255, 150, 50}, {255, 100, 220}}
function osd.colour(index, warn, a)
    if warn then return rgba(255, 60, 60, a or 255) end
    local c = osd.colours[math.clamp(math.round(index), 0, 5) + 1]
    return rgba(c[1], c[2], c[3], a or 255)
end

-- What to show: items {x, y (fractions of the screen), align ("left", "centre", "right"), bottom
-- (y is the text's bottom), warn (red), text}, and the sticks. `t` is the flight state (flight.lua)
-- with `sticks` from the last command; `v` the settings' values.
function osd.layout(t, v)
    local out = {items = {}, scale = v.osdscale, font = v.osdfont >= 0.5 and 1 or 0, colour = math.round(v.osdcolor),
                 margin = math.clamp(v.osdmargin, 0, 0.3), crosshair = v.crosshair >= 0.5}
    local m = out.margin
    local function add(on, x, y, align, bottom, text, warn)
        if on then table.insert(out.items, {x = x, y = y, align = align, bottom = bottom, text = text, warn = warn or false}) end
    end
    local throttle, seconds = t.throttle, t.flight_time
    local volts = flight.battery_volts(seconds, throttle)
    local low = volts < 14
    local blink = math.floor(seconds * 2) % 2 == 1
    local total = math.floor(seconds)
    -- The goggle display as a whole (`osd`): off hides every readout. The range warnings still
    -- show, since flying on without them loses the drone.
    local shown = v.osd >= 0.5
    add(shown and v.osdbattery >= 0.5, m, m, "left", false, string.format("%.1fV", volts), low and blink)
    local armed = t.armed_now ~= false
    add(shown and v.osdarmed >= 0.5, 0.5, m, "centre", false, armed and "ARMED" or "DISARMED", not armed)
    add(shown and v.osdtimer >= 0.5, 1 - m, m, "right", false, string.format("%02d:%02d", total // 60, total % 60))
    add(shown and v.osdthrottle >= 0.5, m, 1 - m, "left", true, string.format("THR %.0f%%", throttle * 100))
    add(shown and v.osdalt >= 0.5, 0.5, 1 - m, "centre", true, string.format("ALT %.1fM", t.altitude))
    add(shown and v.osdspeed >= 0.5, 1 - m, 1 - m, "right", true, string.format("%.0fKM/H", t.speed * 3.6))
    -- A crash cut the motors: say how to fly on (with or without the goggle display).
    if t.crashed then add(true, 0.5, 0.42, "centre", false, "CRASHED - ARM TO FLY AGAIN", true) end
    -- Range: link quality and the way home, and what happens at the edge.
    if v.range > 0 then
        add(shown, 1 - m, m + 0.05, "right", false, string.format("RSSI %.0f%%  %.0fM", t.signal * 100, t.home), t.signal < 0.35 and blink)
        if t.failsafe then
            add(true, 0.5, t.crashed and 0.47 or 0.42, "centre", false, "FAILSAFE - RESET TO FLY AGAIN", true)
        elseif t.signal <= 0 then
            local left = math.max(0, flight.failsafe_after - t.signal_lost)
            add(true, 0.5, 0.42, "centre", false, string.format("NO SIGNAL - TURN BACK (%.0f)", math.ceil(left)), true)
        end
    end
    local sticks = t.sticks or {}
    out.sticks = {show = v.sticks >= 0.5, size = v.sticksize, yaw = sticks.yaw or 0, roll = sticks.roll or 0, pitch = sticks.pitch or 0}
    -- A throttle stick that springs back is shown where it is; one that stays put, by the throttle.
    out.sticks.throttle = sticks.throttle and math.clamp(sticks.throttle, -1, 1) or math.clamp(throttle, 0, 1) * 2 - 1
    return out
end

-- ---- the pixel font -----------------------------------------------------------------------------
local font = nil -- font.json, read once
local glyph_uv = {} -- character: {fill uv, outline uv}
local function load_font()
    if font then return font end
    local ok, data = pcall(reskate.package.read_json, "images/font.json")
    font = ok and data or {order = "", columns = 1, cell = {36, 48}, pad = 1, size = {1, 1}, outline_offset = 0}
    local w, h = font.size[1], font.size[2]
    local cw, ch, pad = font.cell[1], font.cell[2], font.pad
    local function uv(cell)
        local x0 = (cell % font.columns) * (cw + 2 * pad) + pad
        local y0 = (cell // font.columns) * (ch + 2 * pad) + pad
        return {x0 / w, y0 / h, (x0 + cw) / w, (y0 + ch) / h}
    end
    for i = 1, #font.order do
        local c = string.sub(font.order, i, i)
        glyph_uv[c] = {uv(i - 1), uv(i - 1 + font.outline_offset)}
    end
    return font
end
osd.load_font = load_font

-- Width of a pixel-font string, `px` being one font pixel on screen.
local function pixel_width(text, px)
    if #text == 0 then return 0 end
    return (#text * 6 - 1) * px
end
osd.pixel_width = pixel_width

local TALL = 1.45 -- goggle glyphs are taller than wide
-- The text at `x, y` (its top left): every outline first, then every glyph, as the C++ drew it.
local function pixel_text(d, x, y, text, px, colour, shadow)
    load_font()
    text = string.upper(text)
    for pass = 2, 1, -1 do
        local style = {colour = pass == 2 and shadow or colour, uv = nil}
        for i = 1, #text do
            local uv = glyph_uv[string.sub(text, i, i)]
            if uv then
                local left = x + (i - 1) * 6 * px - 0.5 * px
                local top = y - 0.5 * px * TALL
                style.uv = uv[pass]
                d:image(FONT, V(left, top, 0), V(left + 6 * px, top + 8 * px * TALL, 0), style)
            end
        end
    end
end
osd.pixel_text = pixel_text

local function draw_stick(d, k, cx, cy, half, x, y, colour, shadow)
    local t = math.max(1.5, half * 0.04)
    local lo, hi = V(cx - half, cy - half, 0), V(cx + half, cy + half, 0)
    d:rect(lo, hi, {colour = rgba(0, 0, 0, 70), fill = true})
    d:rect(lo, hi, {colour = shadow, thickness = t * 2.4 / k})
    d:rect(lo, hi, {colour = colour, thickness = t / k})
    d:line(V(cx - half, cy, 0), V(cx + half, cy, 0), {colour = rgba(255, 255, 255, 60), thickness = t * 0.6 / k})
    d:line(V(cx, cy - half, 0), V(cx, cy + half, 0), {colour = rgba(255, 255, 255, 60), thickness = t * 0.6 / k})
    local limit = half * 0.86
    local dot = V(cx + math.clamp(x, -1, 1) * limit, cy - math.clamp(y, -1, 1) * limit, 0)
    local radius = half * 0.12
    d:circle(dot, radius + t, {colour = shadow, fill = true})
    d:circle(dot, radius, {colour = colour, fill = true})
end

-- ---- the analogue look ------------------------------------------------------------------------
local rng = 0x9e3779b9
local function random()
    rng = bit32.bxor(rng, bit32.lshift(rng, 13))
    rng = bit32.bxor(rng, bit32.rshift(rng, 17))
    rng = bit32.bxor(rng, bit32.lshift(rng, 5))
    return bit32.band(rng, 0xffffff) / 16777216
end

-- The static picture over the screen in tiles of a random part of it each, so it moves every frame.
local function static_layer(d, w, h, a)
    if a <= 0 then return end
    local columns = 4
    local rows = 2
    local tw, th = w / columns, h / rows
    local span_x = math.min(1, tw / (512 * 1.6 * h / 1080)) -- about 1.6 screen pixels a speck at 1080 lines
    local span_y = math.min(1, th / (512 * 1.6 * h / 1080))
    local colour = rgba(255, 255, 255, alpha(a))
    for r = 0, rows - 1 do
        for c = 0, columns - 1 do
            local u, v = random() * (1 - span_x), random() * (1 - span_y)
            d:image(STATIC, V(c * tw, r * th, 0), V((c + 1) * tw, (r + 1) * th, 0), {colour = colour, uv = {u, v, u + span_x, v + span_y}})
        end
    end
end

-- Scanlines, static, dark corners and rolling glitches drawn over the game; and the picture
-- breaking up near the range's edge or after a hit, with or without the look.
function osd.analog(d, w, h, t, v, time)
    local signal = math.clamp(t.signal or 1, 0, 1)
    local breakup = math.max(1 - signal, math.clamp(t.glitch or 0, 0, 1))
    local look = v.analog >= 0.5
    if not look and breakup <= 0 then return end
    local noise = math.max(look and math.clamp(v.analognoise, 0, 1) or 0, breakup)
    local scan = look and math.clamp(v.analogscan, 0, 1) or 0
    local vignette = math.max(look and math.clamp(v.analogvignette, 0, 1) or 0, breakup * 0.6)
    local glitch = math.max(look and math.clamp(v.analogglitch, 0, 1) or 0, breakup)
    local unit = h / 1080
    local full0, full1 = V(0, 0, 0), V(w, h, 0)

    -- A cold, slightly washed-out cast, and a faint brightness flicker.
    local flicker = 0.02 + 0.02 * math.sin(time * 37) + 0.02 * random()
    d:rect(full0, full1, {colour = rgba(40, 70, 70, alpha(0.05 + 0.07 * scan)), fill = true})
    d:rect(full0, full1, {colour = rgba(0, 0, 0, alpha(flicker * (0.4 + noise))), fill = true})
    -- Scanlines: 512 dark lines down the picture (one every other line of 1080), the picture's 256
    -- in each half.
    if scan > 0 then
        local colour = rgba(255, 255, 255, alpha(0.10 + 0.35 * scan))
        d:image(SCAN, V(0, 0, 0), V(w, h * 0.5, 0), {colour = colour})
        d:image(SCAN, V(0, h * 0.5, 0), V(w, h, 0), {colour = colour})
    end
    if vignette > 0 then d:image(VIGNETTE, full0, full1, {colour = rgba(255, 255, 255, alpha(0.65 * vignette))}) end
    -- Static: specks, and short streaks.
    if noise > 0 then
        static_layer(d, w, h, 0.25 + 0.75 * noise)
        for _ = 1, math.floor(14 * noise) do
            local x, y = random() * w, random() * h
            local length = (20 + random() * 160) * unit
            d:rect(V(x, y, 0), V(x + length, y + math.max(1, unit), 0), {colour = rgba(220, 235, 235, alpha(0.10 + 0.2 * noise)), fill = true})
        end
    end
    -- Glitches: a pale band rolling down the picture, and now and then a burst of torn lines.
    if glitch > 0 then
        local cycle = 5
        local phase = (time % cycle) / cycle
        local band = h * 0.09
        local y = -band + phase * (h + band * 2)
        d:rect(V(0, y, 0), V(w, y + band, 0), {colour = rgba(200, 230, 230, alpha(0.05 + 0.07 * glitch)), fill = true})
        d:rect(V(0, y + band * 0.45, 0), V(w, y + band * 0.55, 0), {colour = rgba(255, 255, 255, alpha(0.04 + 0.06 * glitch)), fill = true})
        if time % 7 < 0.25 * (0.4 + glitch) then
            for _ = 1, 3 + math.floor(8 * glitch) do
                local ty = random() * h
                local th = (2 + random() * 10) * unit
                local shift = (random() - 0.5) * w * 0.08 * glitch
                d:rect(V(math.max(0, shift), ty, 0), V(w + math.min(0, shift), ty + th, 0), {colour = rgba(230, 240, 240, alpha(0.10 + 0.18 * glitch)), fill = true})
                d:rect(V(0, ty + th, 0), V(w, ty + th + math.max(1, unit), 0), {colour = rgba(0, 0, 0, alpha(0.35 * glitch)), fill = true})
            end
        end
    end
    -- Range: as the link weakens the picture sinks under grey snow, until only snow is left.
    if breakup > 0 then
        local b = math.clamp(breakup, 0, 1)
        local fade = b * b * (3 - 2 * b)
        d:rect(full0, full1, {colour = rgba(24, 26, 26, alpha(0.92 * fade * fade)), fill = true})
        local layers = math.ceil(4 * b ^ 1.4)
        for _ = 1, layers do static_layer(d, w, h, 0.4 + 0.6 * b) end
        for _ = 1, math.floor(40 * b * b) do
            local y, lh = random() * h, (1 + random() * 3) * unit
            local g = 150 + random() * 100
            d:rect(V(0, y, 0), V(w, y + lh, 0), {colour = rgba(g, g, g, alpha(0.08 + 0.3 * b * random())), fill = true})
        end
    end
end

-- The goggle display, crosshair and sticks.
function osd.draw(d, layout, w, h)
    local k = h / 1080
    local px = math.max(1, layout.scale * 2 * k) -- one font pixel
    local text_height = 7 * px * TALL
    local shadow = rgba(0, 0, 0, 220)
    local normal = osd.colour(layout.colour, false)
    for _, item in layout.items do
        local colour = osd.colour(layout.colour, item.warn)
        local width
        if layout.font == 0 then width = pixel_width(item.text, px)
        else width = #item.text * text_height * 0.55 end
        local x, y = item.x * w, item.y * h
        if item.bottom then y -= text_height end
        if layout.font == 0 then
            if item.align == "centre" then x -= width * 0.5 elseif item.align == "right" then x -= width end
            pixel_text(d, x, y, item.text, px, colour, shadow)
        else
            -- The game's own font: the overlay aligns it.
            d:text(V(x, y, 0), item.text, {colour = colour, size = text_height / k, align = item.align, shadow = true})
        end
    end
    if layout.crosshair then
        local arm, gap = 14 * k * layout.scale, 4 * k * layout.scale
        local t = math.max(2, 2 * k * layout.scale)
        local cx, cy = w * 0.5, h * 0.5
        for pass = 1, 2 do
            local style = {colour = pass == 1 and shadow or normal, thickness = (pass == 1 and t * 2.2 or t) / k}
            d:line(V(cx - gap - arm, cy, 0), V(cx - gap, cy, 0), style)
            d:line(V(cx + gap, cy, 0), V(cx + gap + arm, cy, 0), style)
            d:line(V(cx, cy - gap - arm, 0), V(cx, cy - gap, 0), style)
            d:line(V(cx, cy + gap, 0), V(cx, cy + gap + arm, 0), style)
        end
    end
    local sticks = layout.sticks
    if sticks.show then
        -- Mode 2: left stick yaw (side to side) and throttle (up and down); right stick roll and pitch.
        local half = 0.5 * 0.17 * h * math.clamp(sticks.size, 0.4, 3)
        local margin = layout.margin * w
        local cy = h * (1 - layout.margin) - text_height * 1.6 - half
        draw_stick(d, k, margin + half, cy, half, sticks.yaw, sticks.throttle, normal, shadow)
        draw_stick(d, k, w - margin - half, cy, half, sticks.roll, sticks.pitch, normal, shadow)
    end
end

return osd
