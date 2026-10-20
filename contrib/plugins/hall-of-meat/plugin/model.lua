-- Hall of Meat, the model: what a bail did to the skater, and what it scores. Fed one physics step at
-- a time (the physics_step event): what each body touched, how the skater moves and whether the game
-- simulates the body as a ragdoll. No game access.
--
-- A bail follows the skater, not a clock:
--   riding  -> bailing     the game's wipeout, and nothing else: a fall from height ragdolls in the
--                          air before the wipeout of its impact (its flight and its hits of just
--                          before carry into the bail), and skate.'s flumps (a dive, a roll along the
--                          ground, from any height) are ragdolls the game never wipes out
--   bailing -> down        the body has come to rest: the bail's time and points are final
--   bailing, down -> getting_up   the ragdoll ends (the skater stands up), or the skater is gone
--                          (a respawn, a teleport); the bail is over, stays and fades out
-- Measured in play: the ragdoll begins with the wipeout or in the flight before it, and ends exactly
-- once, when the skater stands up on foot. The bail shows only once it has hurt a bone: a fall that
-- leaves the skater unbruised shows nothing.
--
-- Two clocks. The bail runs on the game's: its steps' own lengths added up, so in slow motion (a
-- break) the moment the ragdoll has to begin, the rest, the impacts and every stat still measure what
-- the body did. What the player sees runs on the real one (the steps' `at`, reskate.time.now): a
-- hit's flash, a break's effect, the linger and the fade after the bail.
local model = {}

-- Impact speeds along the contact normal, as measured in play: a fall on flat ground hits the bones
-- it lands on at 3 to 9 m/s and grazes the rest at 2 to 3, a hard landing hits the legs at 8 to 10,
-- a drop from height everything at 13 to 35. So a hard fall on flat ground bruises, and only a drop
-- from height breaks bones.
model.hit_speed = 7.0
model.broken_speed = 12.0
-- A wipeout whose ragdoll does not begin within this long was a stumble: its bail ends.
model.ragdoll_wait_ms = 500
-- The body has come to rest once it moves slower than still_speed for rest_ms: from then on nothing
-- counts. A rest is final: getting up starts inside the ragdoll, moving the body fast again.
model.still_speed = 0.5
model.rest_ms = 750
-- Once the skater gets up, the skeleton and the card stay linger_ms, then fade out over fade_ms.
model.linger_ms = 1000
model.fade_ms = 800
model.flash_ms = 350 -- a fresh hit flashes this long
-- A bone breaking hits the whole screen: its edges pulse red and the game slows down to
-- break_game_speed (single player only), together, by one effect: easing in over break_rise_ms, held
-- break_hold_ms, easing out over break_fall_ms; in real time, from the step that saw the break. Each
-- break has its own and the strongest counts.
model.break_rise_ms = 150
model.break_hold_ms = 1000
model.break_fall_ms = 1000
model.break_effect_ms = model.break_rise_ms + model.break_hold_ms + model.break_fall_ms
model.break_game_speed = 0.3
-- A bone's contact lasts several physics steps: hits of one bone closer together than this are one
-- impact, as hard as its hardest step.
model.impact_gap_ms = 200
model.max_impacts = 64
-- The game reports the wipeout of an impact a few physics steps after it: a bail takes the flight
-- and the hits of this long before it starts.
model.wipeout_after_impact_ms = 250

-- The Meat a bail scores: every hit by how hard it was, and each bone broken a bonus once. The
-- lightest hit (hit_speed) scores 100, a 30 m/s slam about 900. A hit to the head counts double, one
-- from a vehicle half again.
model.points_per_reference_hit = 100.0
model.hit_points_exponent = 1.5
model.points_per_break = 1000
model.head_multiplier = 2.0
model.vehicle_multiplier = 1.5
-- Road rash: a body sliding along the ground or a wall, not the board, at least this fast scrapes.
-- The skater's road rash is how far it slid: in each step, how fast its scraping bodies slid on
-- average. A metre scores what four of the lightest hits do.
model.scrape_speed = 1.5
model.points_per_scraped_metre = 400.0
model.bruising_scrape = 1.0 -- metres one bone slid: it shows as bruised
-- The rest of the bail scores as skate. 3's Hall of Meat did, each stat its own points (a fall half of it).
model.points_per_second = 600.0
model.points_per_air_second = 2000.0
model.points_per_metre_fallen = 125.0
model.points_per_speed = 130.0 -- per metre per second
model.points_per_rotation = 600.0
model.radians_per_rotation = 2 * math.pi

-- The bodies as the physics_step event names them; the board is never a body hit. The ragdoll has no
-- head body of its own: the upper neck, which the head rides on, is shown as the head.
model.bodies = {
    "Head", "Neck", "Left hand", "Left forearm", "Left upper arm", "Left collarbone",
    "Right hand", "Right forearm", "Right upper arm", "Right collarbone", "Upper chest", "Chest",
    "Lower back", "Spine", "Left toes", "Left foot", "Left shin", "Left thigh",
    "Right toes", "Right foot", "Right shin", "Right thigh", "Pelvis",
}
local known = {}
for _, name in model.bodies do known[name] = true end
-- The feet touch the ground and the board all the time.
local feet = {["Left toes"] = true, ["Left foot"] = true, ["Right toes"] = true, ["Right foot"] = true}

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function speed_of(v) return finite(v) and v > 0 and v or 0 end
local function length_ms(seconds) return finite(seconds) and seconds > 0 and seconds * 1000 or 0 end
local function elapsed(now, since) return now > since and now - since or 0 end
local function points(amount, per) return math.floor(amount * per + 0.5) end
local function length(v) return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) end

function model.injury(peak)
    if peak >= model.broken_speed then return "broken" end
    if peak >= model.hit_speed then return "hit" end
    return "none"
end
-- A hit's points by its speed alone.
function model.hit_points(speed)
    if not (speed >= model.hit_speed) then return 0 end
    return math.floor(model.points_per_reference_hit * (speed / model.hit_speed) ^ model.hit_points_exponent + 0.5)
end
local function head_bonus(impact)
    return impact.body == "Head" and math.floor(model.hit_points(impact.speed) * (model.head_multiplier - 1) + 0.5) or 0
end
local function vehicle_bonus(impact)
    return impact.vehicle and math.floor(model.hit_points(impact.speed) * (model.vehicle_multiplier - 1) + 0.5) or 0
end
function model.impact_points(impact) return model.hit_points(impact.speed) + head_bonus(impact) + vehicle_bonus(impact) end
-- A bail's score against the best on the same map before it.
function model.standing(best, score)
    if score > best then return {best = score, new_best = true} end
    return {best = best, new_best = false}
end

local Tracker = {}
Tracker.__index = Tracker

function model.tracker()
    local self = setmetatable({}, Tracker)
    self:reset()
    return self
end
function Tracker:reset()
    self.phase = "riding" -- riding, bailing or down; getting_up is the linger and the fade after a bail's end
    self.ragdolled = false
    self.hurt = false
    self.breaks, self.seen_breaks = 0, 0
    self.breaks_seen_at = {} -- real times of the steps that saw breaks
    self.played = 0      -- the game's clock: every step's length added up
    self.started = 0     -- the game's clock at the bail's wipeout
    self.ended = nil     -- real time: when the bail ended
    self.still_since = nil
    self.stopped_at = nil
    self.flight_ms, self.flight_fallen = 0, 0 -- while riding: the last flight, which a bail takes over
    self.landed = nil
    self.airtime_ms, self.fallen, self.top_speed, self.turned, self.scraped = 0, 0, 0, 0, 0
    self.bones = {}
    self.impacts = {}
end
function Tracker:bone(name)
    local bone = self.bones[name]
    if not bone then
        bone = {peak = 0, hit_at = nil, flashed_at = nil, impact = 0, scraped = 0, lead = {}}
        self.bones[name] = bone
    end
    return bone
end

-- One physics step, at `now` in real time (ms). Returns the bail's summary when this step ended one.
function Tracker:step(now, step)
    local step_ms = length_ms(step.seconds)
    self.played += step_ms
    local flown = step.airborne and step_ms or 0
    if step.airborne then
        self.landed = nil
    elseif self.landed == nil then
        self.landed = self.played
    end
    local ragdoll = step.ragdoll == true
    local v = step.velocity
    local descent = v and math.max(0, -(v[2] or 0)) * step_ms / 1000 or 0
    local began = false
    if self.phase == "riding" then
        if step.airborne then
            self.flight_ms += flown
            self.flight_fallen += descent
        elseif self.played - self.landed > model.wipeout_after_impact_ms then -- landed, and stayed up
            self.flight_ms, self.flight_fallen = 0, 0
        end
        -- Each body's hardest recent hit, for a bail that starts a few steps after it.
        for name, contact in step.bodies or {} do
            if not known[name] then continue end
            local speed = speed_of(contact.impact)
            local lead = self:bone(name).lead
            if speed <= 0 or (lead.at and self.played - lead.at <= model.wipeout_after_impact_ms and speed <= lead.speed) then continue end
            self:bone(name).lead = {speed = speed, vehicle = contact.vehicle == true, at = self.played}
        end
        if not step.wipeout then return nil end
        self:begin(now) -- the flight it came from holds this step's airtime and fall
        began = true
    end
    self.ragdolled = self.ragdolled or ragdoll
    local speed = v and length(v) or nil
    self:rest(speed)
    if self.phase == "bailing" then
        if not began then
            self.airtime_ms += flown
            self.fallen += descent
        end
        if speed then self.top_speed = math.max(self.top_speed, speed) end
        if step.spin then self.turned += speed_of(step.spin) * step_ms / 1000 end
        self:count(now, step, step_ms)
    end
    -- The skater stood up, or never went down.
    local stood_up
    if self.ragdolled then stood_up = step.ragdoll == false else stood_up = self.played - self.started >= model.ragdoll_wait_ms end
    if self.breaks ~= self.seen_breaks then -- a break this step: its effect runs from now
        self.seen_breaks = self.breaks
        if #self.breaks_seen_at < #model.bodies then table.insert(self.breaks_seen_at, now) end
    end
    if stood_up then return self:finish(now) end
    return nil
end

-- Whether the body has come to rest, by how fast it moves: then the bail's time and points are final.
function Tracker:rest(speed)
    if self.phase ~= "bailing" or not speed then return end
    if speed >= model.still_speed then
        self.still_since = nil
    elseif not self.still_since then
        self.still_since = self.played
    elseif self.played - self.still_since >= model.rest_ms then
        self.phase = "down"
        self.stopped_at = self.still_since -- it has rested since it went still
    end
end

-- What each body hit and how far it slid in one step of the bail.
function Tracker:count(now, step, step_ms)
    local seconds = step_ms / 1000
    local sliding, scraping = 0, 0
    for name, contact in step.bodies or {} do
        if not known[name] then continue end
        local speed = speed_of(contact.impact)
        if speed > 0 then self:hit(name, speed, contact.vehicle == true, self.played, now) end
        -- Sliding along anything but the board scrapes: the feet ride on it all the time.
        local slide = contact.slide
        if feet[name] or not (contact.world or contact.vehicle) or not finite(slide) or slide < model.scrape_speed then continue end
        local bone = self:bone(name)
        bone.scraped += slide * seconds
        if bone.scraped >= model.bruising_scrape then self.hurt = true end
        sliding += slide
        scraping += 1
    end
    if scraping > 0 then self.scraped += sliding / scraping * seconds end
end

-- The skater is gone (a respawn, a teleport, a map change): a bail ends now. Its summary when one did.
function Tracker:lose(now)
    -- Nothing from before the skater went carries over to the one that comes back.
    self.flight_ms, self.flight_fallen = 0, 0
    self.landed = nil
    self.breaks, self.seen_breaks = 0, 0
    self.breaks_seen_at = {}
    for _, bone in self.bones do bone.lead = {} end
    if self.phase ~= "riding" then return self:finish(now) end
    return nil
end

-- A bail from this step, with the flight it came from and the hits just before it.
function Tracker:begin(now)
    local played, flight, fallen, before = self.played, self.flight_ms, self.flight_fallen, self.bones
    self:reset()
    self.played = played
    self.phase = "bailing"
    self.started = played
    self.airtime_ms = flight -- this step's share is in it
    self.fallen = fallen
    for name, bone in before do
        local lead = bone.lead
        if lead.at and played - lead.at <= model.wipeout_after_impact_ms then self:hit(name, lead.speed, lead.vehicle, lead.at, now) end
    end
end

-- A hit of one bone at `at` on the game's clock, shown from `now`: a new impact, or the harder step of
-- the contact it belongs to.
function Tracker:hit(name, speed, vehicle, at, now)
    local bone = self:bone(name)
    if bone.peak < model.broken_speed and speed >= model.broken_speed then self.breaks += 1 end
    bone.peak = math.max(bone.peak, speed)
    if speed < model.hit_speed then return end
    self.hurt = true
    if bone.hit_at and at - bone.hit_at <= model.impact_gap_ms then
        local impact = self.impacts[bone.impact]
        impact.speed = math.max(impact.speed, speed)
        impact.vehicle = impact.vehicle or vehicle
    elseif #self.impacts < model.max_impacts then
        table.insert(self.impacts, {body = name, speed = speed, vehicle = vehicle})
        bone.impact = #self.impacts
    end
    bone.hit_at = at
    bone.flashed_at = now
end

function Tracker:finish(now)
    self.phase = "riding"
    self.ended = now
    if not self.stopped_at then self.stopped_at = self.played end
    local summary = {shown = self.hurt, peaks = {}, scraped = {}, tally = self:tally()}
    for name, bone in self.bones do
        summary.peaks[name] = bone.peak
        summary.scraped[name] = bone.scraped
    end
    return summary
end

-- The bail's time, on the game's clock: until the body came to rest, or the bail ended, or the latest step.
function Tracker:bail_ms() return math.max(0, (self.stopped_at or self.played) - self.started) end

-- Where the bail is at `now`, whether it hurt a bone (and so shows) or not.
function Tracker:phase_at(now)
    if self.phase ~= "riding" then return self.phase end
    if self.ended and elapsed(now, self.ended) < model.linger_ms + model.fade_ms then return "getting_up" end
    return "riding"
end

local function injury_of(bone)
    local by_hits = model.injury(bone.peak)
    if by_hits == "none" and bone.scraped >= model.bruising_scrape then return "hit" end
    return by_hits
end

-- A bail's numbers, so far or in the end.
function Tracker:tally()
    local t = {impacts = #self.impacts, hit_points = 0, head_bonus = 0, vehicle_bonus = 0, broken = 0}
    for _, impact in self.impacts do
        t.hit_points += model.hit_points(impact.speed)
        t.head_bonus += head_bonus(impact)
        t.vehicle_bonus += vehicle_bonus(impact)
    end
    for _, bone in self.bones do
        if model.injury(bone.peak) == "broken" then t.broken += 1 end
    end
    t.scraped = self.scraped
    t.scrape_points = points(t.scraped, model.points_per_scraped_metre)
    t.damage = t.hit_points + t.head_bonus + t.vehicle_bonus + t.scrape_points
    t.seconds = self:bail_ms() / 1000
    t.time_points = points(t.seconds, model.points_per_second)
    t.airtime = self.airtime_ms / 1000
    t.airtime_points = points(t.airtime, model.points_per_air_second)
    t.fallen = self.fallen
    t.fall_points = points(t.fallen, model.points_per_metre_fallen)
    t.top_speed = self.top_speed
    t.speed_points = points(t.top_speed, model.points_per_speed)
    t.rotations = self.turned / model.radians_per_rotation
    t.rotation_points = points(t.rotations, model.points_per_rotation)
    t.score = t.damage + t.broken * model.points_per_break + t.time_points + t.airtime_points + t.fall_points + t.speed_points +
        t.rotation_points
    return t
end

-- What is drawn at `now`: riding (nothing) until the bail hurts a bone.
function Tracker:view(now)
    local phase = self:phase_at(now)
    if phase == "riding" or not self.hurt then return {phase = "riding", alpha = 0, injuries = {}, flashes = {}, break_pulse = 0} end
    local since_end = phase == "getting_up" and elapsed(now, self.ended) or 0
    local view = {phase = phase, injuries = {}, flashes = {}, tally = self:tally(), break_pulse = self:break_effect(now)}
    view.alpha = since_end > model.linger_ms and 1 - (since_end - model.linger_ms) / model.fade_ms or 1
    for name, bone in self.bones do
        view.injuries[name] = injury_of(bone)
        if bone.flashed_at then
            local since = elapsed(now, bone.flashed_at)
            if since < model.flash_ms then view.flashes[name] = 1 - since / model.flash_ms end
        end
    end
    return view
end

function Tracker:break_effect(now)
    local function smooth(part, whole)
        local t = part / whole
        return t * t * (3 - 2 * t)
    end
    local strongest = 0
    for _, at in self.breaks_seen_at do
        local since = elapsed(now, at)
        if since < model.break_effect_ms then
            local effect
            if since < model.break_rise_ms then
                effect = smooth(since, model.break_rise_ms)
            elseif since < model.break_rise_ms + model.break_hold_ms then
                effect = 1
            else
                effect = 1 - smooth(since - model.break_rise_ms - model.break_hold_ms, model.break_fall_ms)
            end
            strongest = math.max(strongest, effect)
        end
    end
    return strongest
end

-- How fast the game is to run now: down to break_game_speed as a break hits, else 1.
function Tracker:game_speed(now) return 1 - (1 - model.break_game_speed) * self:break_effect(now) end

return model
