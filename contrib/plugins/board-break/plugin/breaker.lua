-- Board Break's rules at play: when the local skater's board breaks, how it is drawn broken, when
-- it is whole again, and how it wears. Everything it needs of the game comes in `game` (main.lua
-- hands it reskate's; tests.lua a fake one):
--   now() ms; random() 0 to 1; bones() the board's 16 bones as last drawn, or nil; velocity() the
--   board's, or nil; skater() the skater's position, or nil; raycast(from, to) a vector or nil;
--   board, reskate.board's set, hide, toss, clear and park; sound(kind) whether it has one,
--   play(kind, volume); wipeout(force); toast(text, level); log(text); load(key), save(key, value).
local feel = require("feel")
local model = require("model")
local v = model.vec

-- The board's rig (Extension/Skater/board_pose.h): 1 its place in the world, 2 the deck's mount,
-- 3 the deck, 4 and 8 the trucks (each with its baseplate's effector right after it), and the
-- spare bones that carry the four stretches of a breakable deck: nose, front, back, tail (the
-- tail's hangs on the front's).
local place_bone, mount_bone, deck_bone = 1, 2, 3
local back_truck_bone, front_truck_bone, back_plate_bone, front_plate_bone = 4, 8, 5, 9
local carrier = {12, 13, 15, 14}
local stretch_bones = {12, 13, 14, 15}
-- The board is back in the skater's hand: close to the skater and not lying flat.
local hand_reach, hand_upright = 1.3, 0.8
local riding_states = {riding = true, air = true, grinding = true}

local Breaker = {}
Breaker.__index = Breaker

local function axes_of(bones)
    local facing = model.unit(model.mul(bones[place_bone].rotation, bones[mount_bone].rotation))
    return model.turn(facing, v(0, 0, 1)), model.turn(facing, v(0, 1, 0))
end

local function new(game)
    local self = setmetatable({game = game}, Breaker)
    self.settings = feel.load(game.load("settings"))
    self.on = game.load("on") ~= false
    local worn = game.load("wear")
    self.wear = if type(worn) == "number" and worn == worn then math.clamp(worn, 0, 1) else 0
    self.dirty, self.saved_at = false, game.now()
    self.broken = nil      -- {since, parts, angle, place, joined, gave_way, asked, tossed}
    self.state, self.previous = "none", "none"
    self.ride_height, self.ride_when = 0, -math.huge
    self.board_seen, self.back_since, self.body_at = -math.huge, nil, -math.huge
    self.refused = nil     -- why the board was refused, told once
    game.board.park(stretch_bones)
    return self
end

-- ---- settings and wear ---------------------------------------------------------------------------
function Breaker:set_on(on)
    self.on = on
    self.game.save("on", on)
end
function Breaker:setting(name) return self.settings[name] end
function Breaker:set_setting(name, value)
    if not feel.set(self.settings, name, value) then return false end
    self.game.save("settings", self.settings)
    return true
end
function Breaker:save_wear()
    self.dirty, self.saved_at = false, self.game.now()
    self.game.save("wear", self.wear)
end
function Breaker:set_wear(wear)
    self.wear = math.clamp(wear, 0, 1)
    self:save_wear()
end
function Breaker:add_wear(amount)
    if not (amount > 0) or self.settings.wear == 0 then return end
    local before = self.wear
    self.wear = feel.add_wear(before, amount, self.settings.wearrate)
    if self.wear ~= before then self.dirty = true end
    local was, now = feel.condition(before), feel.condition(self.wear)
    if was ~= now then
        self.game.log(string.format("the board is %s now (%.0f%% worn).", now, self.wear * 100))
        -- Told as it gets close, so a break that follows is no surprise.
        if now == "beat" then
            self.game.toast("Your board is beat: it breaks from smaller slams now. New board: menu, PLUGINS, Board Break.", "info")
        elseif now == "done" then
            self.game.toast("Your board is done: the next big drop snaps it. New board: menu, PLUGINS, Board Break.", "warn")
        end
    end
end

-- ---- sounds --------------------------------------------------------------------------------------
-- A crack size with no sounds of its own takes the nearest that has some.
local nearest = {light = {"light", "medium", "heavy"}, medium = {"medium", "heavy", "light"}, heavy = {"heavy", "medium", "light"}}
function Breaker:crack(size)
    if self.settings.cracks == 0 then return end
    for _, kind in nearest[size] do
        if self.game.sound(kind) then return self.game.play(kind, 1) end
    end
end
-- The body's hits in a bail, each as hard as it hit; one every 70 ms at most.
function Breaker:body_hit(impact)
    if not self.on or self.settings.bodysounds == 0 then return end
    local loudness = feel.body_loudness(impact or 0)
    local now = self.game.now()
    if loudness <= 0 or now - self.body_at < 70 or not self.game.sound("body") then return end
    self.body_at = now
    self.game.play("body", loudness)
end

-- ---- drawing -------------------------------------------------------------------------------------
-- One refusal is told once a break, not every tick's.
function Breaker:asked(ok, why)
    if not ok and why ~= self.refused then
        self.refused = why
        self.game.log("the board cannot be drawn broken: " .. tostring(why))
    end
    return ok
end
function Breaker:set(bone, motion)
    return self:asked(self.game.board.set(bone, {position = motion.at, rotation = motion.facing, space = "local"}))
end
-- The local board, broken: the real deck goes away, the trucks come back (their baseplates with
-- them), each stretch goes to where its piece lies and one that belongs to no piece goes away too.
-- Every tick from the bones as the animation left them: the trucks steer, and how the pieces hang
-- depends on which way up the board lies.
function Breaker:draw(bones)
    local b = self.broken
    local root, mount = bones[place_bone], bones[mount_bone]
    local up = model.turn(root.rotation, v(0, 1, 0)).y
    -- A tossed tail hangs on the front stretch's bone, which board.toss does not know: the front
    -- stays level while the tail flies, or it would take the tail with it.
    if b.tossed[14] then up = 0 end
    local layout = model.lay_out(b.parts.kept, b.parts.hinge, b.angle, up, mount.rotation)
    local deck = bones[deck_bone]
    self:set(deck_bone, model.rigid(deck.rotation, deck.position + model.deck_away))
    local function truck(kept, bone, plate, motion, place, rest)
        if not kept then return self:asked(self.game.board.hide(bone)) end
        local now = model.rigid(bones[bone].rotation, bones[bone].position)
        if model.length(now.at - rest.at) < 0.05 then self:set(plate, model.baseplate_bone(now, rest)) end
        self:set(bone, model.truck_bone(motion, mount.rotation, mount.position, now.facing, place))
    end
    truck(layout.back_truck, back_truck_bone, back_plate_bone, layout.back_motion, model.back_truck_place, model.back_truck_rest)
    truck(layout.front_truck, front_truck_bone, front_plate_bone, layout.front_motion, model.front_truck_place, model.front_truck_rest)
    local placed = model.bones_of(layout.stretch)
    for i, bone in carrier do
        if b.tossed[bone] then continue end
        if layout.stretch[i].shown then self:set(bone, placed[i]) else self:asked(self.game.board.hide(bone)) end
    end
end

-- The ground under the board: where it rolled a moment ago, else what is below it (on a rail,
-- from under the rail), else its own height.
function Breaker:ground(bones, rail)
    if self.game.now() - self.ride_when < 400 then return self.ride_height end
    local at = bones[place_bone].position
    local from = at + (if rail then v(0, -0.3, 0) else v(0, 0.5, 0))
    local hit = self.game.raycast(from, from - v(0, 30, 0))
    return if hit then hit.y else at.y
end
-- The piece that comes off: a kick and a spin from the board's place, onto the ground.
function Breaker:toss(bones, rail)
    local b = self.broken
    local list = {}
    for i, bone in carrier do
        if model.has(b.parts.loose, bit32.lshift(1, i - 1)) then table.insert(list, bone) end
    end
    -- Each leaves from its place in the whole board (a stretch is kept far below the board until
    -- then, and the tail's place, on the front's, is that too while the front lies level).
    for _, bone in list do self:set(bone, model.rigid()) end
    local function roll(low, high) return low + (high - low) * self.game.random() end
    local flight = model.flight(b.parts.loose, roll)
    local facing = model.mul(bones[place_bone].rotation, bones[mount_bone].rotation)
    local ok = self:asked(self.game.board.toss(list, {
        velocity = model.turn(facing, flight.kick),
        spin = model.turn(facing, flight.spin),
        ground = self:ground(bones, rail) + flight.rest,
    }))
    if ok then
        for _, bone in list do b.tossed[bone] = true end
    end
end

-- ---- breaking and mending ------------------------------------------------------------------------
-- `how`: gave_way (it went under the rider: it stays broken while it is ridden), carried (on foot
-- with the board: the grip tape always holds then), asked (from the console, to be looked at: it
-- stays until mended there), rail (on a rail), why (for the log). False when it did not break.
function Breaker:snap(place, how)
    if self.broken then return false end
    local bones = self.game.bones()
    if not bones then return false end
    local game = self.game
    place = place or model.places[math.clamp(math.floor(game.random() * 3) + 1, 1, 3)]
    local joined = how.carried or game.random() < self.settings.joined / 100
    local parts = model.broken_at(place, joined)
    local angle = if parts.hinge == "fold" then 0.35 + 0.65 * game.random() else 0.30 + 0.35 * game.random()
    self.broken = {since = game.now(), parts = parts, angle = angle, place = place, joined = joined,
                   gave_way = how.gave_way, asked = how.asked, tossed = {}}
    self.back_since = nil
    self:crack(model.break_size(place, joined, angle))
    if parts.loose ~= 0 then self:toss(bones, how.rail) end
    self:draw(bones)
    game.log(string.format("the board broke at the %s%s (%s).", place, if joined then ", held together by the grip tape" else "", how.why or "asked for"))
    return true
end
-- A board that really broke is a new one now; one broken from the console was only looked at.
function Breaker:mend(why)
    if not self.broken then return false end
    if not self.broken.asked then
        self.wear = 0
        self:save_wear()
    end
    self.game.log(string.format("the board is whole again after %.1f s (%s).", (self.game.now() - self.broken.since) / 1000, why))
    self.broken, self.refused = nil, nil
    self.game.board.clear()
    self.game.board.park(stretch_bones)
    return true
end

-- ---- the game's news -----------------------------------------------------------------------------
function Breaker:skater_state(now, previous)
    self.state, self.previous = now, previous or self.state
    -- A respawn: the skater has no state for a moment, and the next board is whole.
    if now == "none" and self.broken and self.game.now() - self.broken.since > 300 then self:mend("a respawn") end
    if now == "wipeout" and self.broken then self.broken.gave_way = false end
end

-- A bail: the slam's force decides whether the board breaks.
function Breaker:bail(force)
    if not self.on then return end
    force = if type(force) == "number" and force == force then force else 0
    self:add_wear(feel.slam_wear(force))
    local chance = if self.settings.always == 1 then 1 else feel.slam_chance(force, self.settings.sensitivity, self.wear)
    if self.broken or not (self.game.random() < chance) then return end
    -- Nose first it goes at the nose, tail first at the tail, flat mostly in the middle.
    local bones = self.game.bones()
    local slope = 0
    if bones then
        local along = axes_of(bones)
        slope = -along.y
    end
    local carried = self.state == "off_board" or (self.state == "wipeout" and self.previous == "off_board")
    self:snap(feel.place_of_break(slope, false, self.game.random()), {carried = carried,
        why = string.format("a slam of force %.1f%s", force, if self.settings.always == 1 then ", set to always break" else "")})
end

-- How the board touches a rail now: from its axes and its velocity.
function Breaker:contact(bones)
    local velocity = self.game.velocity()
    if not bones or not velocity then return "grind" end
    local along, up = axes_of(bones)
    return feel.contact_of(along, up, velocity)
end

-- The board came down from the air, onto the ground or a rail.
function Breaker:landed(onto, down_speed)
    if not self.on then return end
    down_speed = down_speed or 0
    local rail = onto == "rail"
    local contact = if rail then self:contact(self.game.bones()) else "grind"
    local wear = self.wear -- as it was before this landing
    self:add_wear(if rail then feel.rail_wear(down_speed, contact ~= "grind") else feel.landing_wear(down_speed))
    if self.broken then return end
    local s = self.settings
    if not rail then
        -- A done board gives way on a landing hard enough for how worn it is: the nose goes, and they ride on.
        if s.wear == 1 and feel.gives_way_on_landing(down_speed, s.sensitivity, wear) then
            self:snap("nose", {gave_way = true, why = string.format("a landing at %.1f m/s on a board that was done", down_speed)})
        end
        return
    end
    if s.rails == 0 or contact == "grind" then return end
    local chance = if s.always == 1 then (if down_speed > 1.5 then 1 else 0) else feel.rail_chance(down_speed, contact, s.sensitivity, wear)
    if self.game.random() < chance and self:snap("mid", {rail = true, why = string.format("a %s onto a rail at %.1f m/s", contact, down_speed)}) then
        -- The board snaps under the rider: the rider goes down with it. Gently: a slam's force
        -- with the board flat on the ground throws the rider high into the air.
        self.game.wipeout(2.5)
    end
end

-- Every tick (`dt` in ms): wear while grinding, the ground under the board, the broken board drawn,
-- and whether it is whole again.
function Breaker:tick(dt)
    local game = self.game
    local now = game.now()
    local bones = game.bones()
    if not bones then
        -- No board (a respawn, a level change): the next one is whole. One that is only out of
        -- sight for a moment stays as it is.
        if self.broken and now - self.board_seen < 500 then return end
        self:mend("the board is gone")
        return
    end
    self.board_seen = now
    local state = self.state
    if self.on and state == "grinding" then
        self:add_wear(feel.grind_wear_per_second(self:contact(bones) ~= "grind") * (dt or 0) / 1000)
    end
    -- Rolling on the ground, the right way up: the board's own height is the ground's.
    local root = bones[place_bone]
    if state == "riding" and model.turn(root.rotation, v(0, 1, 0)).y > 0.9 then
        self.ride_height, self.ride_when = root.position.y, now
    end
    if self.dirty and now - self.saved_at > 5000 then self:save_wear() end
    local b = self.broken
    if not b then return end
    -- Whole again once the skater rides it, or has picked it up after the fall. A board that gave
    -- way under the rider stays as it is while it is ridden; after a fall it is broken like any other.
    local on_it = riding_states[state] == true
    local skater = game.skater()
    local in_hand = false
    if skater then
        local upright = math.abs(model.turn(root.rotation, v(0, 1, 0)).y)
        in_hand = model.length(root.position - skater) < hand_reach and upright < hand_upright
    end
    local back = if b.gave_way then not on_it and in_hand else on_it or (state ~= "wipeout" and in_hand)
    if b.asked or not back then
        self.back_since = nil
    elseif not self.back_since then
        self.back_since = now
    elseif now - self.back_since > 300 and now - b.since > 1200 then
        self:mend(if on_it then "riding again" else "back in hand")
        return
    end
    self:draw(bones)
end

function Breaker:status()
    local s = self.settings
    local function word(n) return if n == 1 then "on" else "off" end
    return string.format("%s; the board is %s (%.0f%% worn)%s; sensitivity %d%%, always break %s, rail snaps %s, wear %s at %d%%, " ..
        "grip holds %d%% of breaks, crack sounds %s, body sounds %s",
        if self.on then "on" else "off", feel.condition(self.wear), self.wear * 100, if self.broken then ", broken" else "",
        s.sensitivity, word(s.always), word(s.rails), word(s.wear), s.wearrate, s.joined, word(s.cracks), word(s.bodysounds))
end

return {new = new}
