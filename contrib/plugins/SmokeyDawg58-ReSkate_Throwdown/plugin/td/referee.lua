-- His Referee (mode_rules.h lines 219-299, mode_rules.cpp lines 738-1360), the leader's referee, line
-- for line: `local r = R.Referee.new(settings, leader, game)`. Players and the leader are Steam ID strings
-- ("0" none); the turn and the setter are 0-based indices into the players, as his. His public names
-- (add_player, remove_player, has_player, take_calls, set_name) and the short ones ReSkate's API gave
-- them (add, remove, has, calls, name) are the same methods.
local R = require("td/rules")
local RR = require("td/h/race_route")

local Referee = {}
Referee.__index = Referee
R.Referee = Referee

-- ---- helpers --------------------------------------------------------------------------------------
local finite, isfinite, horizontal_distance = R.finite, R.isfinite, R.horizontal_distance
local function nz(id) return id ~= nil and id ~= "" and id ~= "0" and id ~= 0 end
-- An id as the API took it: a number or a decimal string.
local function id_of(id)
    if type(id) == "number" then return string.format("%.0f", id) end
    if type(id) ~= "string" or id == "" then return "0" end
    return id
end
local TWO64 = 18446744073709551616
-- `a - b` on his std::uint64_t milliseconds: a time after `a` wraps to a huge one.
-- PORT: kept by adding 2^64 (as a double) when b > a; every such comparison then fails as his do.
local function udiff(a, b)
    if a >= b then return a - b end
    return a - b + TWO64
end
local function count_if(list, f)
    local n = 0
    for _, x in ipairs(list) do
        if f(x) then n += 1 end
    end
    return n
end
local function any_of(list, f)
    for _, x in ipairs(list) do
        if f(x) then return true end
    end
    return false
end
local function all_of(list, f)
    for _, x in ipairs(list) do
        if not f(x) then return false end
    end
    return true
end
-- std::stable_sort with his comparator: an insertion sort keeps equal rows in their order.
local function stable_sort(list, less)
    for i = 2, #list do
        local x = list[i]
        local j = i - 1
        while j >= 1 and less(x, list[j]) do
            list[j + 1] = list[j]
            j -= 1
        end
        list[j + 1] = x
    end
end
local function lower(text) return string.lower(text) end
-- static_cast<std::int32_t>(std::min<std::uint64_t>(x, 0x7fffffff))
local function capped(x) return math.min(x, 0x7fffffff) end

local function Player(id)
    return {id = id, score = 0, aux = 0, strikes = 0, out = false, finished = false, sequence = 0, name = "",
            at = vector.zero, -- Skate Tag: where they last said they were
            at_time = 0,      -- and when (0: never)
            it_ms = 0,        -- Skate Tag: time spent it; Infection: time survived
            infected = false} -- Infection; Hide & Seek: seeking
end

function Referee.new(settings, leader, game)
    local self = setmetatable({}, Referee)
    self.settings_ = R.deep_copy(settings) -- his Settings by value
    self.leader_ = id_of(leader)
    self.game_ = game
    self.phase_ = "setup"
    self.phase_at_, self.turn_at_, self.last_second_ = 0, 0, 0
    self.players_ = {}
    self.turn_ = 0
    self.target_ = 0
    self.it_, self.tagged_by_, self.it_since_, self.it_counted_ = "0", "0", 0, 0 -- Skate Tag
    self.released_ = false -- Hide & Seek: the hiding time is over
    self.play_at_ = 0
    self.tags_ = {}   -- Graffiti
    self.owners_ = {} -- one per Domination spot or Graffiti tag (owner "0": unclaimed)
    self.calls_ = {}  -- not yet taken
    self.recent_ = {} -- the last few, for the state message
    self.call_serial_ = 0
    -- R.E.S.K.A.T.E.
    self.setter_ = 0
    self.set_trick_ = ""   -- the trick to copy; empty while the setter sets
    self.done_tricks_ = {} -- set already this game
    -- Graffiti's tags are found as they are skated; Domination's spots are set up front.
    if self.settings_.mode == "domination" then
        for _ = 1, #self.settings_.points do table.insert(self.owners_, R.ZoneOwner()) end
    end
    for i, o in ipairs(self.owners_) do o.zone = i - 1 end
    return self
end
-- Copying one (C++ value semantics).
function Referee.copy(r) return setmetatable(R.deep_copy(r), Referee) end

function Referee:settings() return R.deep_copy(self.settings_) end
function Referee:phase() return self.phase_ end
function Referee:game() return self.game_ end
function Referee:hide_end() return self.play_at_ + self.settings_.turn_s * 1000 end

function Referee:find(id)
    for _, p in ipairs(self.players_) do
        if p.id == id then return p end
    end
    return nil
end
function Referee:has_player(player) return self:find(id_of(player)) ~= nil end
function Referee:set_name(player, name)
    local p = self:find(id_of(player))
    -- PORT: the API cut a name to 64 bytes; kept.
    if p then p.name = string.sub(tostring(name), 1, 64) end
end
function Referee:name_of(id)
    local p = self:find(id)
    return if p and p.name ~= "" then p.name else "A player"
end
function Referee:still_in()
    return count_if(self.players_, function(p) return not p.out end)
end
-- Players can be added until the countdown ends; 1-Up turns go in the order added.
function Referee:add_player(player)
    player = id_of(player)
    if not nz(player) or self:find(player) or #self.players_ >= R.max_players then return end
    if self.phase_ ~= "setup" and self.phase_ ~= "countdown" then return end
    table.insert(self.players_, Player(player))
end
function Referee:remove_player(player, now_ms)
    player = id_of(player)
    local p = self:find(player)
    if not p or p.out then return end
    if self.phase_ == "setup" or self.phase_ == "countdown" then
        for i = #self.players_, 1, -1 do
            if self.players_[i].id == player then table.remove(self.players_, i) end
        end
        return
    end
    local s = self.settings_
    -- A completed race result belongs to this run even when its owner leaves
    -- the waiting/results UI while the other racers are still finishing.
    if s.mode == "race" and p.finished then return end
    if s.mode == "race" and self.phase_ == "playing" and not p.finished then
        p.aux = capped(if now_ms >= self.play_at_ then now_ms - self.play_at_ else 0)
    end
    p.out = true
    self:call(self:name_of(player) .. " left the game")
    if self.phase_ ~= "playing" then return end
    -- Skate Tag: the one who is it leaving hands it to the next player still in.
    if s.mode == "tag" then
        if player == self.it_ then
            for _, q in ipairs(self.players_) do
                if not q.out then
                    self:make_it(q.id, "0", now_ms)
                    break
                end
            end
        end
        if #self.players_ > 1 and self:still_in() <= 1 then self:finish(now_ms) end
        return
    end
    -- Infection (and Hide & Seek): the last survivor leaving, or the last of the infected, ends it.
    if R.hunt_like(s.mode) then
        local hunters = any_of(self.players_, function(q) return not q.out and q.infected end)
        if #self.players_ > 1 and (self:survivors() == 0 or not hunters or self:still_in() <= 1) then self:finish(now_ms) end
        return
    end
    if s.mode == "oneup" and self.turn_ < #self.players_ and self.players_[self.turn_ + 1].id == player then
        self:next_turn(now_ms)
    elseif s.mode == "oneup" and (self:still_in() == 0 or (#self.players_ > 1 and self:still_in() <= 1)) then
        self:finish(now_ms)
    end
    if s.mode == "skate" then
        if self.setter_ < #self.players_ and self.players_[self.setter_ + 1].id == player then self:pass_set(now_ms)
        elseif self.turn_ < #self.players_ and self.players_[self.turn_ + 1].id == player then self:next_copier(now_ms)
        elseif self:still_in() == 0 or (#self.players_ > 1 and self:still_in() <= 1) then self:finish(now_ms) end
    end
end
function Referee:start(now_ms)
    if self.phase_ ~= "setup" then return end
    self.phase_ = "countdown"
    self.phase_at_ = now_ms
end
-- The leader ends the game early: straight to the results, standings as they are.
function Referee:end_now(now_ms)
    if self.phase_ == "playing" or self.phase_ == "countdown" then self:finish(now_ms) end
end
function Referee:begin_play(now_ms)
    local s = self.settings_
    self.phase_ = "playing"
    self.phase_at_, self.last_second_, self.turn_at_, self.play_at_ = now_ms, now_ms, now_ms, now_ms
    self.released_ = false
    self.turn_ = 0
    self.target_ = 0
    -- Point zero is the native start flag, already accepted during setup.
    -- The first visible gate is point one; crossing the flag is never required.
    if s.mode == "race" then
        for _, player in ipairs(self.players_) do player.score = R.next_race_gate(s, 1) end
    end
    self:call("GO!")
    if s.mode == "oneup" and #self.players_ > 0 then
        self:call(self:name_of(self.players_[1].id) .. " is up: set a score")
    end
    if s.mode == "skate" and #self.players_ > 0 then
        self.setter_ = 0
        self.set_trick_ = ""
        self.done_tricks_ = {}
        self:call(self:name_of(self.players_[1].id) .. " sets first")
    end
    -- Skate Tag: someone starts it, picked by the game's id so every game starts differently.
    if s.mode == "tag" and #self.players_ > 0 then self:make_it(self.players_[self.game_ % #self.players_ + 1].id, "0", now_ms) end
    -- Infection: patient zero, picked the same way; everyone else starts clean.
    if s.mode == "infection" and #self.players_ > 0 then
        local zero = self.players_[self.game_ % #self.players_ + 1]
        zero.infected = true
        self.it_counted_ = now_ms
        self:call(self:name_of(zero.id) .. " is patient zero!")
    end
    -- Hide & Seek: the seeker, picked the same way; everyone else hides.
    if s.mode == "hide" and #self.players_ > 0 then
        local seeker = self.players_[self.game_ % #self.players_ + 1]
        seeker.infected = true
        self.it_counted_ = now_ms
        self:call(string.format("%s is seeking! Hide! (%d s)", self:name_of(seeker.id), s.turn_s))
    end
end
function Referee:survivors()
    return count_if(self.players_, function(p) return not p.out and not p.infected end)
end
-- Infection: every infected player whose position is fresh infects each survivor within reach whose
-- position is fresh too. A game of more than one player ends when nobody is left clean.
function Referee:try_infections(now_ms)
    local s = self.settings_
    if s.mode == "hide" and now_ms < self:hide_end() then return end -- nobody is found while the seekers count
    local reach = s.radius
    local function fresh(p) return not p.out and p.at_time ~= 0 and udiff(now_ms, p.at_time) <= R.position_fresh_ms end
    local caught = {} -- {victim, by}
    for _, hunter in ipairs(self.players_) do
        if not hunter.infected or not fresh(hunter) then continue end
        for _, q in ipairs(self.players_) do
            if q.infected or not fresh(q) then continue end
            local dx, dy, dz = q.at.x - hunter.at.x, q.at.y - hunter.at.y, q.at.z - hunter.at.z
            if dx * dx + dy * dy + dz * dz <= reach * reach and not any_of(caught, function(c) return c[1] == q.id end) then
                table.insert(caught, {q.id, hunter.id})
            end
        end
    end
    for _, c in ipairs(caught) do
        local victim, by = c[1], c[2]
        local p = self:find(victim)
        p.infected = true
        if s.mode == "hide" then
            local finder = self:find(by)
            finder.aux += 1 -- finds
            self:call(string.format("%s found %s!", self:name_of(by), self:name_of(victim)))
        else
            self:call(string.format("%s infected %s!", self:name_of(by), self:name_of(victim)))
        end
    end
    if #caught > 0 and #self.players_ > 1 and self:survivors() == 0 then
        self:call(self:name_of(caught[#caught][1]) .. (if s.mode == "hide" then " was the last one hiding" else " was the last survivor"))
        self:finish(now_ms)
    end
end
-- Skate Tag: player is it from now on.
function Referee:make_it(player, by, now_ms)
    self.it_ = player
    self.tagged_by_ = by
    self.it_since_, self.it_counted_ = now_ms, now_ms
    self:call(if nz(by) then string.format("%s tagged %s!", self:name_of(by), self:name_of(player)) else self:name_of(player) .. " is it!")
end
-- Skate Tag: whoever is it, within reach of another player who is not the one that just tagged
-- them, tags them. Both positions must be fresh: an old one is somewhere they no longer are.
function Referee:try_tags(now_ms)
    local it = self:find(self.it_)
    if not it or it.out or it.at_time == 0 or udiff(now_ms, it.at_time) > R.position_fresh_ms then return end
    local reach = self.settings_.radius
    for _, q in ipairs(self.players_) do
        if q.id == self.it_ or q.out or q.at_time == 0 or udiff(now_ms, q.at_time) > R.position_fresh_ms then continue end
        if q.id == self.tagged_by_ and udiff(now_ms, self.it_since_) < R.no_tag_back_ms then continue end -- no tag-backs
        local dx, dy, dz = q.at.x - it.at.x, q.at.y - it.at.y, q.at.z - it.at.z
        if dx * dx + dy * dy + dz * dz <= reach * reach then
            self:make_it(q.id, self.it_, now_ms)
            return
        end
    end
end
function Referee:finish(now_ms)
    if self.phase_ == "results" then return end
    self.phase_ = "results"
    self.phase_at_ = now_ms
    local standings = self:state(now_ms).standings
    if #standings > 0 then self:call(self:name_of(standings[1].player) .. " wins!") end
end
function Referee:strike(p, now_ms, why)
    p.strikes += 1
    p.aux = p.strikes
    self:call(string.format("%s %s: strike %d of %d", self:name_of(p.id), why, p.strikes, self.settings_.strikes))
    if p.strikes >= self.settings_.strikes then
        p.out = true
        self:call(self:name_of(p.id) .. " is out")
    end
    self:next_turn(now_ms)
end
function Referee:next_turn(now_ms)
    local players = self.players_
    if self:still_in() == 0 or (#players > 1 and self:still_in() <= 1) then
        self:finish(now_ms)
        return
    end
    for step = 1, #players do
        local index = (self.turn_ + step) % #players
        if not players[index + 1].out then
            self.turn_ = index
            break
        end
    end
    self.turn_at_ = now_ms
    local up = self:name_of(players[self.turn_ + 1].id)
    self:call(if self.target_ > 0 then string.format("%s is up: beat %d", up, self.target_) else up .. " is up: set a score")
end

-- ---- R.E.S.K.A.T.E. --------------------------------------------------------------------------------
local function same_trick(a, b)
    if #a ~= #b then return false end
    return lower(a) == lower(b)
end
function Referee:letter(p, why)
    p.strikes += 1
    p.aux = p.strikes
    self:call(string.format("%s %s: %s", self:name_of(p.id), why, R.skate_letters(p.strikes, self.settings_.strikes)))
    if p.strikes >= self.settings_.strikes then
        p.out = true
        self:call(self:name_of(p.id) .. " is out")
    end
end
-- The setter missed: the next player still in sets.
function Referee:pass_set(now_ms)
    local players = self.players_
    if self:still_in() == 0 or (#players > 1 and self:still_in() <= 1) then
        self:finish(now_ms)
        return
    end
    self.set_trick_ = ""
    for step = 1, #players do
        local index = (self.setter_ + step) % #players
        if not players[index + 1].out then
            self.setter_ = index
            break
        end
    end
    self.turn_ = self.setter_
    self.turn_at_ = now_ms
    self:call(self:name_of(players[self.setter_ + 1].id) .. " sets next")
end
-- The next player to copy, or back to the setter.
function Referee:next_copier(now_ms)
    local players = self.players_
    if self:still_in() == 0 or (#players > 1 and self:still_in() <= 1) then
        self:finish(now_ms)
        return
    end
    for step = 1, #players do
        local index = (self.turn_ + step) % #players
        if index == self.setter_ then break end -- everyone has had a go: the setter sets again
        if not players[index + 1].out then
            self.turn_ = index
            self.turn_at_ = now_ms
            self:call(string.format("%s: copy the %s", self:name_of(players[index + 1].id), self.set_trick_))
            return
        end
    end
    if self.setter_ >= #players or players[self.setter_ + 1].out then
        self:pass_set(now_ms)
        return
    end
    self.set_trick_ = ""
    self.turn_ = self.setter_
    self.turn_at_ = now_ms
    self:call(self:name_of(players[self.setter_ + 1].id) .. " sets again")
end
function Referee:skate_attempt(p, landed, trick, now_ms)
    local name = R.set_trick_name(string.sub(trick, 1, R.max_trick_length))
    if self.set_trick_ == "" and self.turn_ == self.setter_ then -- setting
        if not landed or name == "" then
            self:call(self:name_of(p.id) .. " missed the set")
            self:pass_set(now_ms)
        elseif not R.trick_allowed(self.settings_, name) then
            self:call(string.format("%s: not in this game", name))
            self:pass_set(now_ms)
        elseif any_of(self.done_tricks_, function(t) return same_trick(t, name) end) then
            self:call(string.format("%s: already set", name))
            self:pass_set(now_ms)
        else
            self.set_trick_ = name
            table.insert(self.done_tricks_, name)
            p.score += 1 -- tricks set, the tiebreak
            self:call(string.format("%s set the %s", self:name_of(p.id), name))
            if #self.players_ == 1 then -- playing alone: land your own set again, or take a letter
                self.turn_at_ = now_ms
                self:call(string.format("%s: land the %s again", self:name_of(p.id), name))
            else
                self:next_copier(now_ms)
            end
        end
        return
    end
    if landed and R.copies_trick(name, self.set_trick_) then self:call(self:name_of(p.id) .. " landed it")
    else self:letter(p, if landed and name ~= "" then string.format("did a %s", name) else "missed") end
    self:next_copier(now_ms)
end

-- event(player, event, value, at, sequence, now, tags?, trick?): one of a player's own lines, bails,
-- checkpoints, positions or tricks.
function Referee:event(player, event, value, at, sequence, now_ms, tags, trick)
    -- PORT: what ReSkate's API did to the arguments before his event(): an id string, the value clamped
    -- to +-2e9 and cut to an integer, the sequence to an integer, at most max_line_tags tags, the trick
    -- at most 256 bytes. `at` may be a list.
    player = id_of(player)
    value = math.clamp(value, -2.0e9, 2.0e9)
    value = if value >= 0 then math.floor(value) else math.ceil(value)
    sequence = math.floor(sequence) % 4294967296
    if type(at) ~= "vector" then at = vector.create(at and (at[1] or at.x) or 0, at and (at[2] or at.y) or 0, at and (at[3] or at.z) or 0) end
    tags = tags or {}
    if #tags > R.max_line_tags then tags = table.move(tags, 1, R.max_line_tags, 1, {}) end
    trick = string.sub(if type(trick) == "string" then trick else "", 1, 256)

    if self.phase_ ~= "playing" then return end
    local p = self:find(player)
    if not p or p.out or p.finished or sequence <= p.sequence then return end
    p.sequence = sequence
    local s = self.settings_
    -- Skate Tag and Infection run on where everyone is (anywhere: leaving the area is dealt with by
    -- sending them back).
    if R.tag_like(s.mode) then
        if event ~= "position" then return end
        for _, v in ipairs({at.x, at.y, at.z}) do
            if not isfinite(v) or math.abs(v) > 1e6 then return end
        end
        p.at = at
        p.at_time = now_ms
        if s.mode == "tag" then self:try_tags(now_ms) else self:try_infections(now_ms) end
        return
    end
    if event == "position" then
        if s.mode == "race" and finite(at) then
            p.at = at
            p.at_time = now_ms
        end
        return
    end
    if s.mode ~= "race" and not R.inside(s, at) then return end -- out of the area: nothing counts
    local mode = s.mode
    if mode == "tag" or mode == "infection" or mode == "hide" then
        return -- handled above, from positions
    elseif mode == "skate" then
        if event ~= "trick" or self.turn_ >= #self.players_ or self.players_[self.turn_ + 1].id ~= player then return end
        self:skate_attempt(p, value ~= 0, trick, now_ms)
    elseif mode == "jam" then
        if event ~= "line" then return end
        p.score += value
        p.aux = math.max(p.aux, value)
    elseif mode == "meat" then
        if event ~= "bail" then return end
        p.score += value
        if value > p.aux then
            p.aux = value
            self:call(string.format("%s took %d of meat", self:name_of(player), value))
        end
    elseif mode == "oneup" then
        if self.turn_ >= #self.players_ or self.players_[self.turn_ + 1].id ~= player then return end
        if event == "bail" then
            self:strike(p, now_ms, "bailed")
        elseif event == "line" then
            if value > self.target_ then
                self:call(if self.target_ > 0 then string.format("%s beat it: %d", self:name_of(player), value)
                    else string.format("%s set %d", self:name_of(player), value))
                self.target_ = value
                p.score = math.max(p.score, value)
                self:next_turn(now_ms)
            else
                self:strike(p, now_ms, string.format("fell short of %d", self.target_))
            end
        end
    elseif mode == "race" then
        if p.finished then return end
        local deadline = self.phase_at_ + s.duration_s * 1000
        if now_ms >= deadline then
            p.out = true
            return
        end
        if event ~= "checkpoint" or value ~= p.score or not finite(at) then return end
        -- (static_cast<std::size_t>(value) of a negative value is past the end.)
        if #s.points == 0 or value < 0 or value >= #s.points then return end
        local index = value
        local point = s.points[index + 1]
        if RR.race_gate_pitch(s, index) ~= 0 then
            local axes = RR.race_gate_axes(if index < #s.yaws then s.yaws[index + 1] else 0, RR.race_gate_pitch(s, index))
            if math.abs(RR.race_gate_dot(at, point, axes.right)) > R.gate_half_width(s, index) * 1.3 + 3 or
                math.abs(RR.race_gate_dot(at, point, axes.up)) > RR.race_gate_height(s, index) + 3 or
                math.abs(RR.race_gate_dot(at, point, axes.forward)) > 3 then
                return
            end
        else
            if math.abs(at.y - point.y) > 10 * R.gate_half_width(s, index) / 6 then return end
            -- Within the gate's own width (where the crossing was reported), with some slack for lag.
            if horizontal_distance(at, point) > R.gate_half_width(s, index) * 1.3 + 3.0 then return end
        end
        p.score = R.next_race_gate(s, value + 1)
        if value > 0 and value + 1 < #s.points then
            self:call(string.format("%s: required gate %d/%d", self:name_of(player), R.mandatory_gates(s, p.score), R.mandatory_gates(s, #s.points)))
        end
        if p.score == #s.points then
            p.finished = true
            p.aux = capped(udiff(now_ms, self.phase_at_))
            local place = count_if(self.players_, function(q) return q.finished end)
            self:call(string.format("%s finished #%d in %.1f s", self:name_of(player), place, p.aux / 1000.0))
        end
    elseif mode == "domination" then
        if event ~= "line" then return end
        local spot = R.spot_at(s, at)
        if spot == nil or value <= self.owners_[spot + 1].best then return end
        local owner = self.owners_[spot + 1]
        if owner.owner ~= player then self:call(string.format("%s took spot %d", self:name_of(player), spot + 1)) end
        owner.owner = player
        owner.best = value
        p.aux = math.max(p.aux, value)
    elseif mode == "graffiti" then
        if event ~= "line" then return end
        -- Every grind and gap in the line is tagged with it: a new tag, or a steal when the line
        -- beats the one that holds it.
        local tagged, stolen = 0, 0
        local from = "0"
        for t = 1, math.min(#tags, R.max_line_tags) do
            local tag = tags[t]
            if not R.valid_tag(tag) or not R.inside(s, R.tag_centre(tag)) then continue end
            local found = nil
            for i, known in ipairs(self.tags_) do
                if R.same_tag(known, tag) then
                    found = i
                    break
                end
            end
            if found == nil then
                if #self.tags_ >= R.max_tags then continue end
                table.insert(self.tags_, R.deep_copy(tag))
                table.insert(self.owners_, {zone = #self.tags_ - 1, owner = "0", best = 0})
                found = #self.tags_
            end
            local owner = self.owners_[found]
            if owner.owner == player then
                owner.best = math.max(owner.best, value)
                continue
            end
            if value <= owner.best then continue end
            if nz(owner.owner) then
                stolen += 1
                from = owner.owner
            else
                tagged += 1
            end
            owner.owner = player
            owner.best = value
        end
        if stolen ~= 0 then
            self:call(if stolen == 1 then string.format("%s stole a tag from %s", self:name_of(player), self:name_of(from))
                else string.format("%s stole %d tags", self:name_of(player), stolen))
        elseif tagged ~= 0 then
            self:call(string.format("%s tagged %d spot%s", self:name_of(player), tagged, if tagged == 1 then "" else "s"))
        end
        for _, q in ipairs(self.players_) do
            q.score, q.aux = 0, 0
            for _, o in ipairs(self.owners_) do
                if o.owner == q.id then
                    q.score += 1
                    q.aux += o.best
                end
            end
        end
    end
end
-- Advances the clock; true when the state changed in a way worth sending at once.
function Referee:tick(now_ms)
    local s = self.settings_
    local elapsed = if now_ms >= self.phase_at_ then now_ms - self.phase_at_ else 0
    if self.phase_ == "countdown" then
        if elapsed >= R.countdown_ms then
            self:begin_play(now_ms)
            return true
        end
        return false
    elseif self.phase_ == "playing" then
        if R.timed(s.mode) and s.mode ~= "race" and elapsed >= s.duration_s * 1000 then
            self:finish(now_ms)
            return true
        end
        if s.mode == "race" then
            local expired = false
            for _, p in ipairs(self.players_) do
                if not p.out and not p.finished then
                    if elapsed >= s.duration_s * 1000 then
                        p.aux = s.duration_s * 1000
                        p.out = true
                        expired = true
                        self:call(self:name_of(p.id) .. " DNF: missed the finish deadline")
                    end
                end
            end
            if expired and not all_of(self.players_, function(p) return p.finished or p.out end) then return true end
        end
        if s.mode == "race" and #self.players_ > 0 and all_of(self.players_, function(p) return p.finished or p.out end) then
            self:finish(now_ms)
            return true
        end
        if s.mode == "domination" then
            while now_ms >= self.last_second_ + 1000 do
                self.last_second_ += 1000
                for _, o in ipairs(self.owners_) do
                    local p = if nz(o.owner) then self:find(o.owner) else nil
                    if p then p.score += 1 end
                end
            end
        end
        if s.mode == "tag" then
            -- The time spent it, in tenths of a second (the score: fewer wins).
            local p = self:find(self.it_)
            if p then
                p.it_ms += udiff(now_ms, self.it_counted_)
                p.score = capped(p.it_ms // 100)
            end
            self.it_counted_ = now_ms
        end
        -- Hide & Seek: the seekers come out when the hiding time is up; hiding time scores nothing.
        if s.mode == "hide" and not self.released_ then
            if now_ms < self:hide_end() then
                self.it_counted_ = now_ms
                return false
            end
            self.released_ = true
            self.it_counted_ = self:hide_end()
            self:call("Ready or not, here they come!")
            for _, p in ipairs(self.players_) do -- the release: scored from the end of the hiding time, sent at once
                if not p.out and not p.infected then
                    p.it_ms += udiff(now_ms, self.it_counted_)
                    p.score = capped(p.it_ms // 100)
                end
            end
            self.it_counted_ = now_ms
            return true
        end
        if R.hunt_like(s.mode) then
            -- Each survivor's time clean (or hidden), in tenths of a second (the score: more wins).
            for _, p in ipairs(self.players_) do
                if not p.out and not p.infected then
                    p.it_ms += udiff(now_ms, self.it_counted_)
                    p.score = capped(p.it_ms // 100)
                end
            end
            self.it_counted_ = now_ms
        end
        if s.mode == "oneup" and self.turn_ < #self.players_ and now_ms >= self.turn_at_ + s.turn_s * 1000 then
            self:strike(self.players_[self.turn_ + 1], now_ms, "ran out of time")
            return true
        end
        if s.mode == "skate" and self.turn_ < #self.players_ and now_ms >= self.turn_at_ + s.turn_s * 1000 then
            if self.set_trick_ == "" and self.turn_ == self.setter_ then
                self:call(self:name_of(self.players_[self.turn_ + 1].id) .. " ran out of time to set")
                self:pass_set(now_ms)
            else
                self:letter(self.players_[self.turn_ + 1], "ran out of time")
                self:next_copier(now_ms)
            end
            return true
        end
        return false
    end
    return false
end
-- Results shown long enough.
function Referee:finished(now_ms)
    return self.phase_ == "results" and now_ms >= self.phase_at_ + R.results_ms
end
-- The state message everyone draws (kind "state", positions vectors).
function Referee:state(now_ms)
    local s = self.settings_
    local m = R.Message()
    m.kind = "state"
    m.leader = self.leader_
    m.game = self.game_
    m.phase = self.phase_
    local elapsed = if now_ms >= self.phase_at_ then now_ms - self.phase_at_ else 0
    local function left(total) return if total > elapsed then total - elapsed else 0 end
    if self.phase_ == "countdown" then
        m.remaining_ms = left(R.countdown_ms)
    elseif self.phase_ == "playing" then
        if s.mode == "oneup" or s.mode == "skate" then
            local turn_elapsed = if now_ms >= self.turn_at_ then now_ms - self.turn_at_ else 0
            local total = s.turn_s * 1000
            m.remaining_ms = if total > turn_elapsed then total - turn_elapsed else 0
        else
            m.remaining_ms = left(s.duration_s * 1000)
        end
    elseif self.phase_ == "results" then
        m.remaining_ms = left(R.results_ms)
    end
    local players = self.players_
    if s.mode == "oneup" and self.phase_ == "playing" and self.turn_ < #players then m.turn = players[self.turn_ + 1].id end
    if s.mode == "tag" and (self.phase_ == "playing" or self.phase_ == "results") then m.turn = self.it_ end
    if s.mode == "skate" and self.phase_ == "playing" and self.turn_ < #players then
        m.turn = players[self.turn_ + 1].id
        m.trick = self.set_trick_
        if self.setter_ < #players then m.setter = players[self.setter_ + 1].id end
    end
    m.target = self.target_
    for _, p in ipairs(players) do
        local row = {player = p.id, score = p.score, aux = p.aux, out = p.out, up = m.turn == p.id, remaining_ms = 0}
        table.insert(m.standings, row)
        if s.mode == "race" and self.phase_ == "playing" and not p.out and not p.finished then
            row.remaining_ms = left(s.duration_s * 1000)
            row.aux = math.min(if now_ms >= self.play_at_ then now_ms - self.play_at_ else 0, s.duration_s * 1000)
        end
        -- Infection: aux 1 and `up` for the infected (who wear the reaper), score the tenths survived.
        if s.mode == "infection" then
            row.aux = if p.infected then 1 else 0
            row.up = p.infected
        end
        -- Hide & Seek: `up` for the seekers, aux how many each found.
        if s.mode == "hide" then row.up = p.infected end
    end
    -- Hide & Seek: target is the hiding time left (ms), 0 once the seekers are out.
    if s.mode == "hide" and self.phase_ == "playing" then
        m.target = if now_ms < self:hide_end() then self:hide_end() - now_ms else 0
    end
    local mode = s.mode
    stable_sort(m.standings, function(a, b)
        if mode == "race" then
            local pa, pb = self:find(a.player), self:find(b.player)
            local fa, fb = pa ~= nil and pa.finished, pb ~= nil and pb.finished
            if fa ~= fb then return fa end
            if fa then return a.aux < b.aux end
            if a.out ~= b.out then return not a.out end
            if a.score ~= b.score then return a.score > b.score end
            -- Racers with the same required gate are ordered by distance to it.
            local gate = math.max(0, a.score)
            if gate < #s.points then
                local fresh_a = pa ~= nil and pa.at_time ~= 0 and now_ms >= pa.at_time and now_ms - pa.at_time <= R.position_fresh_ms
                local fresh_b = pb ~= nil and pb.at_time ~= 0 and now_ms >= pb.at_time and now_ms - pb.at_time <= R.position_fresh_ms
                if fresh_a ~= fresh_b then return fresh_a end
                if fresh_a and fresh_b then
                    return horizontal_distance(pa.at, s.points[gate + 1]) < horizontal_distance(pb.at, s.points[gate + 1])
                end
            end
            return false
        end
        if mode == "tag" then -- least time spent it first
            if a.out ~= b.out then return not a.out end
            return a.score < b.score
        end
        if mode == "infection" then -- longest survived first; a survivor before the infected on a tie
            if a.score ~= b.score then return a.score > b.score end
            return a.aux < b.aux
        end
        if mode == "hide" then -- longest hidden first; then most found
            if a.score ~= b.score then return a.score > b.score end
            return a.aux > b.aux
        end
        if mode == "oneup" or mode == "skate" then
            if a.out ~= b.out then return not a.out end
            if a.aux ~= b.aux then return a.aux < b.aux end -- fewer strikes, or letters
            return a.score > b.score
        end
        if a.score ~= b.score then return a.score > b.score end
        return a.aux > b.aux
    end)
    for _, o in ipairs(self.owners_) do
        if nz(o.owner) then table.insert(m.zones, {zone = o.zone, owner = o.owner, best = o.best}) end
    end
    m.calls = table.clone(self.recent_)
    m.call_serial = self.call_serial_
    return m
end
-- Graffiti's tag shapes, by index (copies).
function Referee:tags() return R.deep_copy(self.tags_) end
-- Short lines for everyone's HUD since the last call ("Sam took zone 4").
function Referee:take_calls()
    local out = self.calls_
    self.calls_ = {}
    return out
end
function Referee:call(text)
    if #text > R.max_call_length then text = string.sub(text, 1, R.max_call_length) end
    table.insert(self.calls_, text)
    table.insert(self.recent_, text)
    if #self.recent_ > R.max_calls then table.remove(self.recent_, 1) end
    self.call_serial_ += 1
end

-- The names ReSkate's API gave his methods.
Referee.add = Referee.add_player
Referee.remove = Referee.remove_player
Referee.has = Referee.has_player
Referee.calls = Referee.take_calls
Referee.name = Referee.set_name

return R
