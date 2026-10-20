-- Other players' drones, as Extension/Skater/drone_beacon.h and the drone HUD had them, over the
-- plugin's own messages instead of the core's drone packet: a flying drone sends where it is, its
-- throttle and speed about 12 times a second; each receiver glides a marker from one position to
-- the next, tags the pilot's nametag "FLYING DRONE" and plays their motor where the drone is.
-- (Their drone models are left out: spawning props from a plugin is not possible yet.)
local flight = require("flight")
local osd = require("osd")
local beacon = {}

local V = vector.create
local dot, cross, len, norm = vector.dot, vector.cross, vector.magnitude, flight.norm
local UP = V(0, 1, 0)

beacon.send_every_ms = 80   -- about 12 a second
beacon.stale_ms = 1500      -- a drone not heard from this long is gone
beacon.snap_distance = 50   -- a jump further than this (a reset) is shown at once
beacon.most = 32
beacon.tag = "FLYING DRONE"
beacon.tag_colour = 0x5AE8FFFF
local FORMAT = "<c2BfffhhhhBH"
local MAGIC = "FD"

-- Which way the drone faces as a unit quaternion {x, y, z, w}, from its basis.
function beacon.rotation(body)
    local m00, m01, m02 = body.r.x, body.r.y, body.r.z
    local m10, m11, m12 = body.u.x, body.u.y, body.u.z
    local m20, m21, m22 = body.b.x, body.b.y, body.b.z
    local trace = m00 + m11 + m22
    local x, y, z, w
    if trace > 0 then
        local s = math.sqrt(trace + 1) * 2
        x, y, z, w = (m12 - m21) / s, (m20 - m02) / s, (m01 - m10) / s, 0.25 * s
    elseif m00 > m11 and m00 > m22 then
        local s = math.sqrt(1 + m00 - m11 - m22) * 2
        x, y, z, w = 0.25 * s, (m01 + m10) / s, (m20 + m02) / s, (m12 - m21) / s
    elseif m11 > m22 then
        local s = math.sqrt(1 + m11 - m00 - m22) * 2
        x, y, z, w = (m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m20 - m02) / s
    else
        local s = math.sqrt(1 + m22 - m00 - m11) * 2
        x, y, z, w = (m20 + m02) / s, (m12 + m21) / s, 0.25 * s, (m01 - m10) / s
    end
    local l = math.sqrt(x * x + y * y + z * z + w * w)
    if not (l > 1e-6) or not flight.finite(l) then return {0, 0, 0, 1} end
    return {x / l, y / l, z / l, w / l}
end

-- A message: flying (or stopped), where, which way it faces, throttle (0-1) and speed (m/s).
function beacon.encode(flying, position, rotation, throttle, speed)
    local function q(v) return math.clamp(math.round(v * 32767), -32767, 32767) end
    return string.pack(FORMAT, MAGIC, flying and 1 or 0, position.x, position.y, position.z,
        q(rotation[1]), q(rotation[2]), q(rotation[3]), q(rotation[4]),
        math.clamp(math.round(throttle * 255), 0, 255), math.clamp(math.round(speed * 100), 0, 65535))
end
-- The message's fields, or nil for one that is not a drone's.
function beacon.decode(payload)
    if type(payload) ~= "string" or #payload ~= string.packsize(FORMAT) then return nil end
    local ok, magic, kind, x, y, z, qx, qy, qz, qw, throttle, speed = pcall(string.unpack, FORMAT, payload)
    if not ok or magic ~= MAGIC then return nil end
    local position = V(x, y, z)
    if not flight.finite_vector(position) then return nil end
    return {flying = kind == 1, position = position, rotation = {qx / 32767, qy / 32767, qz / 32767, qw / 32767},
            throttle = throttle / 255, speed = speed / 100}
end

-- ---- sending ----------------------------------------------------------------------------------
local sending = {last = -1e9, announced = false}
-- Each tick: the local drone (a flight state, or nil when not flying) and whether to share it.
-- Returns the message to send now, or nil.
function beacon.outgoing(now, drone, share)
    if drone and share then
        if sending.announced and now - sending.last < beacon.send_every_ms then return nil end
        sending.announced = true
        sending.last = now
        return beacon.encode(true, drone.position, beacon.rotation(drone.body), drone.throttle, drone.speed)
    end
    if sending.announced then
        sending.announced = false
        sending.last = now
        local at = drone and drone.position or V(0, 0, 0)
        return beacon.encode(false, at, {0, 0, 0, 1}, 0, 0)
    end
    return nil
end

-- ---- receiving --------------------------------------------------------------------------------
-- By player id: {id, name, from, to, seen, glide (ms), throttle, speed, sound, tagged}.
beacon.remotes = {}
local count = 0

local function glide_fraction(r, now)
    if r.glide <= 0 then return 1 end
    return math.clamp((now - r.seen) / r.glide, 0, 1)
end
function beacon.position(r, now)
    return r.from + (r.to - r.from) * glide_fraction(r, now)
end

local function forget(id)
    local r = beacon.remotes[id]
    if not r then return end
    if r.sound then pcall(reskate.audio.stop, r.sound) end
    if r.tagged then pcall(reskate.session.tag, id, nil) end
    beacon.remotes[id] = nil
    count -= 1
end
beacon.forget = forget

function beacon.receive(player, payload, now)
    local message = beacon.decode(payload)
    if not message or not player or not player.id then return end
    local id = player.id
    local r = beacon.remotes[id]
    if not message.flying then
        forget(id)
        return
    end
    if not r then
        if count >= beacon.most then return end
        r = {id = id, name = player.name or "", from = message.position, to = message.position, seen = now, glide = 0,
             throttle = message.throttle, speed = message.speed}
        beacon.remotes[id] = r
        count += 1
        return
    end
    if player.name and player.name ~= "" then r.name = player.name end
    local shown = beacon.position(r, now)
    -- The glide lasts as long as this update took to arrive, within sensible bounds.
    local gap = math.clamp(now - r.seen, 20, 250)
    local snap = len(message.position - shown) > beacon.snap_distance
    r.from = snap and message.position or shown
    r.to = message.position
    r.glide = gap
    r.seen = now
    r.throttle += (message.throttle - r.throttle) * 0.5
    r.speed += (message.speed - r.speed) * 0.5
end

-- Each tick: drops stale drones, keeps tags and motors going. `volume` is the motor volume
-- setting, `show` whether other drones are shown at all.
function beacon.tick(now, show, volume)
    for id, r in beacon.remotes do
        if now - r.seen > beacon.stale_ms then forget(id) end
    end
    local tags_ok = true
    for id, r in beacon.remotes do
        if show and not r.tagged and tags_ok then
            tags_ok = pcall(reskate.session.tag, id, beacon.tag, beacon.tag_colour)
            r.tagged = tags_ok
        elseif not show and r.tagged then
            pcall(reskate.session.tag, id, nil)
            r.tagged = false
        end
        local at = beacon.position(r, now)
        if show and volume > 0.001 then
            -- Other players' drones a little under the pilot's own motor at the same volume.
            local options = {position = at, throttle = math.clamp(r.throttle, 0, 1), speed = math.clamp(r.speed, 0, 200),
                             volume = math.clamp(volume * 0.75, 0, 1), range = 150}
            if r.sound then
                pcall(reskate.audio.set, r.sound, options)
            elseif now >= (r.sound_retry or 0) then
                -- (A plugin plays 8 sounds at most: the rest wait and try again now and then.)
                options.loop = true
                local ok, id_or_false = pcall(reskate.audio.play, "motor", options)
                if ok and id_or_false then r.sound = id_or_false else r.sound_retry = now + 2000 end
            end
        elseif r.sound then
            pcall(reskate.audio.stop, r.sound)
            r.sound = nil
        end
    end
end

-- Everything let go (the plugin unloads, or the level changes).
function beacon.clear()
    for id in beacon.remotes do forget(id) end
    sending.announced = false
end

function beacon.count()
    return count
end

-- ---- markers -----------------------------------------------------------------------------------
local function metres_text(m)
    if m < 1000 then return string.format("%.0f m", math.floor(m)) end
    return string.format("%.1f km", m / 1000)
end

-- A little quadcopter: an X with a propeller circle at each end, around (x, y).
local function drone_icon(d, k, x, y, size, colour, shadow)
    local arm, prop, t = size * 0.5, size * 0.2, math.max(1.5, size * 0.09)
    for pass = 1, 2 do
        local c = pass == 1 and shadow or colour
        local style = {colour = c, thickness = (pass == 1 and t * 2.4 or t) / k}
        d:line(V(x - arm, y - arm, 0), V(x + arm, y + arm, 0), style)
        d:line(V(x + arm, y - arm, 0), V(x - arm, y + arm, 0), style)
        d:circle(V(x - arm, y - arm, 0), prop, style)
        d:circle(V(x + arm, y - arm, 0), prop, style)
        d:circle(V(x + arm, y + arm, 0), prop, style)
        d:circle(V(x - arm, y + arm, 0), prop, style)
    end
    d:circle(V(x, y, 0), size * 0.1, {colour = colour, fill = true})
end

-- Markers for the drones, from the camera `view` ({position, forward, fov}): over each one on
-- screen its pilot's name and how far; an arrow at the screen's edge for one off it.
function beacon.draw(d, w, h, view, now)
    if count == 0 or not view then return end
    local k = h / 1080
    local centre_x, centre_y = w * 0.5, h * 0.5
    local margin = 40 * k
    local pulse = 0.78 + 0.22 * math.sin(now / 1000 * 5)
    local colour = osd.rgba(90, 232, 255, 255 * pulse)
    local shadow = osd.rgba(0, 0, 0, 200)
    local forward = norm(view.forward)
    local right = norm(cross(forward, UP))
    if len(right) < 0.5 then right = V(1, 0, 0) end
    local up = cross(right, forward)
    local fov = (view.fov and view.fov > 1 and view.fov < 175) and view.fov or 60
    local focal = h / (2 * math.tan(fov * math.pi / 360))
    local size = math.clamp(14 * k, 10, 30)
    for _, r in beacon.remotes do
        -- Anchored a little above the drone, then lifted by half the icon and a gap on screen.
        local at = beacon.position(r, now) + V(0, 0.25, 0)
        local delta = at - view.position
        local distance = len(delta)
        local label = (r.name ~= "" and r.name or "Player") .. "'s drone"
        local metres = metres_text(distance)
        local screen = d:world_to_screen(at)
        local on_screen = screen ~= nil and screen.x >= margin and screen.x <= w - margin and screen.y >= margin and screen.y <= h - margin
        if on_screen then
            -- Stacked upwards: the icon, the distance, then the name.
            local icon = math.clamp(18 * k, 12, 32)
            local icon_y = screen.y - icon * 0.5 - 6 * k
            drone_icon(d, k, screen.x, icon_y, icon, colour, shadow)
            local fine = size * 0.78
            local metres_y = icon_y - icon * 0.5 - 4 * k - fine
            d:text(V(screen.x, metres_y, 0), metres, {colour = osd.rgba(235, 235, 235, 230), size = fine / k, align = "centre"})
            d:text(V(screen.x, metres_y - size, 0), label, {colour = colour, size = size / k, align = "centre"})
        else
            -- Off screen: an arrow at the edge pointing to it, with the distance.
            local depth, side, height = dot(delta, forward), dot(delta, right), dot(delta, up)
            local ex, ey
            if depth > 0.1 then ex, ey = side * focal / depth, -height * focal / depth
            else ex, ey = side, -height end
            if math.abs(ex) < 1e-3 and math.abs(ey) < 1e-3 then ey = 1 end -- straight behind
            local hx, hy = centre_x - margin, centre_y - margin
            local scale = math.min(math.abs(ex) > 1e-6 and hx / math.abs(ex) or 1e30, math.abs(ey) > 1e-6 and hy / math.abs(ey) or 1e30)
            local edge_x, edge_y = centre_x + ex * scale, centre_y + ey * scale
            local l = math.sqrt(ex * ex + ey * ey)
            local dx, dy = ex / l, ey / l
            local px, py = -dy, dx
            local a = 13 * k
            local tip = V(edge_x + dx * a, edge_y + dy * a, 0)
            local b1 = V(edge_x - dx * a * 0.5 + px * a * 0.8, edge_y - dy * a * 0.5 + py * a * 0.8, 0)
            local b2 = V(edge_x - dx * a * 0.5 - px * a * 0.8, edge_y - dy * a * 0.5 - py * a * 0.8, 0)
            local o = V(2 * k, 2 * k, 0)
            d:poly({tip + o, b1 + o, b2 + o}, {colour = shadow, fill = true})
            d:poly({tip, b1, b2}, {colour = colour, fill = true})
            local fine = size * 0.78
            local tx = math.clamp(edge_x - dx * a * 2.2, 40 * k, w - 40 * k)
            local ty = math.clamp(edge_y - dy * a * 2.2 - fine * 0.5, 4 * k, h - fine - 4 * k)
            d:text(V(tx, ty, 0), metres, {colour = colour, size = fine / k, align = "centre"})
        end
    end
end

return beacon
