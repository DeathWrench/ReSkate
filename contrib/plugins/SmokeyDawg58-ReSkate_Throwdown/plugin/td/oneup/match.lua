-- SmokeyDawg58's one_up_match.h / one_up_match.cpp, line for line. No game calls and no transport:
-- only the leader owns a Match; everyone else consumes validated snapshots.
-- Ids (match, world, leader, players) are decimal strings ("0" none); revision and turn numbers.
-- Phase is his enum class as strings; MT.phase_number / MT.phase_names give its wire numbers.
local MT = {}

local function nz(id) return id ~= nil and id ~= "" and id ~= "0" end
-- His PlayerId (uint64) order: by length, then by digits (decimal strings without leading zeros).
local function id_less(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
end
MT.nz, MT.id_less = nz, id_less
local function finite(x) return x == x and x ~= math.huge and x ~= -math.huge end
MT.finite = finite

MT.UINT32_MAX = 4294967295

-- enum class Phase : std::uint8_t { lobby, countdown, playing, settling, feedback, finished, cancelled };
MT.phase_names = {"lobby", "countdown", "playing", "settling", "feedback", "finished", "cancelled"}
MT.phase_number = {}
for i, name in ipairs(MT.phase_names) do MT.phase_number[name] = i - 1 end

-- ---- Config ------------------------------------------------------------------------------------
MT.Config = {}
function MT.Config.new()
    return {turn_ms = 20000, grace_ms = 0, countdown_ms = 3000,
        -- Reliable score delivery may finish after the visible clock. This is not skating time.
        delivery_ms = 1500, feedback_ms = 2500,
        max_players = 6}
end
function MT.Config.copy(c)
    return {turn_ms = c.turn_ms, grace_ms = c.grace_ms, countdown_ms = c.countdown_ms,
        delivery_ms = c.delivery_ms, feedback_ms = c.feedback_ms, max_players = c.max_players}
end
function MT.Config.valid(c)
    return c.turn_ms >= 10000 and c.turn_ms <= 120000 and c.grace_ms == 0 and
        c.countdown_ms >= 1000 and c.countdown_ms <= 10000 and c.delivery_ms <= 3000 and c.feedback_ms <= 10000 and
        c.max_players >= 1 and c.max_players <= 6
end

-- ---- Player ------------------------------------------------------------------------------------
MT.Player = {}
function MT.Player.new(id) return {id = id or "0", penalties = 0, ready = false, connected = true} end
function MT.Player.copy(p) return {id = p.id, penalties = p.penalties, ready = p.ready, connected = p.connected} end
function MT.Player.eligible(p) return p.connected and p.penalties < 3 end

-- ---- Token: every native scoring event carries the turn that was active when it occurred. ------
MT.Token = {}
function MT.Token.new(match, turn, player) return {match = match or "0", turn = turn or 0, player = player or "0"} end
function MT.Token.same(a, b) return a.match == b.match and a.turn == b.turn and a.player == b.player end

-- ---- State -------------------------------------------------------------------------------------
MT.State = {}
function MT.State.new()
    return {match = "0", world = "0", revision = 0,
        leader = "0", active = "0", winner = "0", judged_player = "0",
        config = MT.Config.new(),
        phase = "lobby",
        turn = 0,
        target = 0, best = 0, judged_score = 0,
        judged_success = false,
        players = {},
        notice = ""}
end
function MT.State.copy(s)
    local players = {}
    for i, p in ipairs(s.players) do players[i] = MT.Player.copy(p) end
    return {match = s.match, world = s.world, revision = s.revision,
        leader = s.leader, active = s.active, winner = s.winner, judged_player = s.judged_player,
        config = MT.Config.copy(s.config), phase = s.phase, turn = s.turn,
        target = s.target, best = s.best, judged_score = s.judged_score, judged_success = s.judged_success,
        players = players, notice = s.notice}
end
-- `current = m.state` on a State someone else holds: the same table takes the copy's values.
function MT.State.assign(current, from)
    local c = MT.State.copy(from)
    for k in pairs(current) do current[k] = nil end
    for k, v in pairs(c) do current[k] = v end
end

-- ---- Match -------------------------------------------------------------------------------------
local Match = {}
Match.__index = Match
MT.Match = Match

function Match.new(identity, world, leader, config)
    config = config or MT.Config.new()
    if not nz(identity) or not nz(world) or not nz(leader) or not MT.Config.valid(config) then error("Invalid 1-Up match", 0) end
    local self = setmetatable({}, Match)
    self.state_ = MT.State.new()
    self.phase_at_, self.turn_at_ = 0, 0
    self.last_trick_ = 0
    self.score_cutoff_ = 120000
    self.solo_test_ = false
    self.cursor_ = 0 -- std::size_t, 0-based
    local s = self.state_
    s.match = identity; s.world = world; s.leader = leader; s.config = MT.Config.copy(config)
    table.insert(s.players, MT.Player.new(leader)); s.notice = "Enrolled. Waiting for the host to start."; self:changed()
    return self
end
function Match:state() return self.state_ end
function Match:phase_at() return self.phase_at_ end
function Match:turn_at() return self.turn_at_ end
function Match:token() return MT.Token.new(self.state_.match, self.state_.turn, self.state_.active) end
function Match:solo_test() return self.solo_test_ end

function Match:changed() self.state_.revision += 1 end
function Match:player(id)
    for _, p in ipairs(self.state_.players) do
        if p.id == id then return p end
    end
    return nil
end
function Match:join(id)
    local s = self.state_
    if s.phase ~= "lobby" or not nz(id) or self:player(id) or #s.players >= s.config.max_players then return false end
    table.insert(s.players, MT.Player.new(id))
    -- The host leads, then Steam IDs: crossing join messages do not change turn order.
    local rest = {}
    for i = 2, #s.players do table.insert(rest, s.players[i]) end
    table.sort(rest, function(a, b) return id_less(a.id, b.id) end)
    for i, p in ipairs(rest) do s.players[i + 1] = p end
    self:changed(); return true
end
function Match:ready(id, value)
    local p = self:player(id)
    if self.state_.phase ~= "lobby" or not p or not p.connected or p.ready == value then return false end
    p.ready = value; self:changed(); return true
end
function Match:start(now)
    local s = self.state_
    if s.config.max_players == 1 then return self:start_solo_test(now) end
    if s.phase ~= "lobby" or #s.players < 2 then return false end
    for _, p in ipairs(s.players) do
        if not p.connected then return false end
    end
    self.cursor_ = 0; s.target = 0; s.winner = "0"
    self:countdown(now); return true
end
function Match:start_solo_test(now)
    local s = self.state_
    if s.phase ~= "lobby" or #s.players ~= 1 or not s.players[1].connected then return false end
    self.solo_test_ = true; self.cursor_ = 0; s.target = 0; s.winner = "0"
    self:countdown(now); return true
end
function Match:position_confirmed(token_value, now)
    if self.state_.phase ~= "countdown" or not MT.Token.same(token_value, self:token()) or now < self.phase_at_ then return false end
    self.phase_at_ = now; self:changed(); return true
end
function Match:rematch(_now)
    local s = self.state_
    if s.phase ~= "finished" then return false end
    for i = #s.players, 1, -1 do
        if not s.players[i].connected then table.remove(s.players, i) end
    end
    for _, p in ipairs(s.players) do p.penalties = 0; p.ready = false end
    s.phase = "lobby"; s.target = 0; s.best = 0; s.winner = "0"; s.active = "0"
    s.judged_player = "0"; s.notice = "Rematch opened. Waiting for the host to start."; self:changed(); return true
end
function Match:cancel(reason)
    local s = self.state_
    if s.phase == "cancelled" then return end
    s.phase = "cancelled"; s.active = "0"; s.winner = "0"; s.notice = reason; self:changed()
end
function Match:winner()
    local s = self.state_
    local live, last = 0, "0"
    for _, p in ipairs(s.players) do
        if MT.Player.eligible(p) then live += 1; last = p.id end
    end
    -- Practice uses real local turns and real scoring, with no fabricated rival.
    -- Keep playing against the previous target until all three penalties accrue.
    if self.solo_test_ then
        if live > 0 then return false end
        self:cancel("Solo test complete: 1UP. Place a new flag to try again."); return true
    end
    if live > 1 then return false end
    s.active = "0"; s.winner = last
    s.phase = live > 0 and "finished" or "cancelled"
    s.notice = live > 0 and "Last skater standing!" or "Everyone left the match."; self:changed(); return true
end
function Match:leave(id, now)
    local s = self.state_
    local p = self:player(id)
    if not p or not p.connected then return false end
    if id == s.leader then self:cancel("The host left. Create a new match to play again."); return true end
    if s.phase == "lobby" then
        for i = #s.players, 1, -1 do
            if s.players[i].id == id then table.remove(s.players, i) end
        end
        self:changed(); return true
    end
    p.connected = false; self:changed()
    if s.phase == "finished" or s.phase == "cancelled" then return true end
    if self:winner() then return true end
    if s.active == id then
        s.target = 0; s.best = 0; s.notice = "The active skater left. Set a fresh target."
        self:advance(now)
    end
    return true
end
function Match:countdown(now)
    local s = self.state_
    s.active = s.players[self.cursor_ + 1].id
    if s.turn == MT.UINT32_MAX then self:cancel("Match turn limit reached."); return end
    s.turn += 1; s.best = 0; self.last_trick_ = 0; self.score_cutoff_ = s.config.turn_ms
    s.phase = "countdown"; self.phase_at_ = now
    s.notice = s.target > 0 and "Beat the target! Every landed trick counts." or "Build your total before time runs out!"; self:changed()
end
function Match:accepts(t)
    return MT.Token.same(t, self:token()) and (self.state_.phase == "playing" or self.state_.phase == "settling")
end
-- elapsed is measured from the owner's received turn start, not from wall clock time.
-- A landed trick/sequence's final native points, accepted before the visible
-- turn deadline. Earlier points stay banked if a later trick is bailed.
function Match:trick_scored(t, id, points, elapsed, received)
    local s = self.state_
    if not self:accepts(t) or id == 0 or id <= self.last_trick_ or not finite(points) or points <= 0 or
        points > 2147483647.0 - s.best or elapsed >= self.score_cutoff_ or received < self.turn_at_ or
        received - self.turn_at_ > s.config.turn_ms + s.config.delivery_ms then return false end
    self.last_trick_ = id; s.best += points; self:changed(); return true
end
function Match:bailed(token, elapsed, received)
    local s = self.state_
    if not MT.Token.same(token, self:token()) or s.phase ~= "playing" or elapsed >= s.config.turn_ms or
        received < self.turn_at_ or received - self.turn_at_ > s.config.turn_ms + s.config.delivery_ms then return false end
    -- End skating immediately; allow only already-landed, reliably delivered
    -- points stamped before this bail. Stale tokens cannot end another turn.
    self.score_cutoff_ = elapsed; s.phase = "settling"; self.phase_at_ = received
    s.notice = "Bailed! Turn ended."; self:changed(); return true
end
function Match:resolve(now)
    -- This transition is called once. Inputs cannot mutate feedback/finished states.
    local s = self.state_
    local p = self:player(s.active)
    if not p then self:cancel("The active skater is unavailable."); return end
    local success = s.best > s.target and s.best > 0
    s.judged_player = p.id; s.judged_score = s.best; s.judged_success = success
    if success then s.target = s.best; s.notice = "Target beaten!"
    else
        p.penalties += 1; s.target = 0
        s.notice = p.penalties == 3 and "1UP - eliminated!" or "Penalty earned. The next skater sets a fresh target."
    end
    s.phase = "feedback"; self.phase_at_ = now; self:changed()
    self:winner()
end
function Match:advance(now)
    local s = self.state_
    if self:winner() then return end
    for _ = 0, #s.players - 1 do
        self.cursor_ = (self.cursor_ + 1) % #s.players
        if MT.Player.eligible(s.players[self.cursor_ + 1]) then self:countdown(now); return end
    end
    self:cancel("No skaters remain.")
end
function Match:tick(now)
    local s = self.state_
    if now < self.phase_at_ then return end
    if s.phase == "countdown" and now - self.phase_at_ >= s.config.countdown_ms then
        s.phase = "playing"; self.turn_at_ = now; self.phase_at_ = now; self:changed()
    end
    if s.phase == "playing" and now >= self.turn_at_ and now - self.turn_at_ >= s.config.turn_ms then
        s.phase = "settling"; self.phase_at_ = self.turn_at_ + s.config.turn_ms; self:changed()
    end
    if s.phase == "settling" then
        -- Delivery allowance accepts only events stamped BEFORE zero. It never
        -- extends skating time or waits for a combo/multiplier to finish.
        if now >= self.phase_at_ + s.config.delivery_ms then self:resolve(now) end
    end
    if s.phase == "feedback" and now - self.phase_at_ >= s.config.feedback_ms then self:advance(now) end
end
function Match:remaining(now)
    local s = self.state_
    local finish = 0
    if s.phase == "countdown" then finish = self.phase_at_ + s.config.countdown_ms end
    if s.phase == "playing" then finish = self.turn_at_ + s.config.turn_ms end
    return now < finish and (finish - now) or 0
end

function MT.valid_state(s)
    if not nz(s.match) or not nz(s.world) or s.revision == 0 or not nz(s.leader) or not MT.Config.valid(s.config) or #s.players == 0 or
        #s.players > s.config.max_players or #s.notice > 192 or MT.phase_number[s.phase] == nil or
        s.players[1].id ~= s.leader or not finite(s.target) or not finite(s.best) or not finite(s.judged_score) or
        s.target < 0 or s.best < 0 or s.judged_score < 0 or s.target > 2147483647.0 or s.best > 2147483647.0 or s.judged_score > 2147483647.0 then
        return false
    end
    local ids = {}
    for _, p in ipairs(s.players) do
        if not nz(p.id) or p.penalties > 3 or ids[p.id] then return false end
        ids[p.id] = true
    end
    local function eligible(id)
        for _, p in ipairs(s.players) do
            if p.id == id and MT.Player.eligible(p) then return true end
        end
        return false
    end
    if s.phase == "countdown" or s.phase == "playing" or s.phase == "settling" then
        if s.turn == 0 or not eligible(s.active) then return false end
    end
    if s.phase == "finished" then
        local count = 0
        for _, p in ipairs(s.players) do
            if MT.Player.eligible(p) then count += 1 end
        end
        if not eligible(s.winner) or nz(s.active) or count ~= 1 then return false end
    end
    return not nz(s.judged_player) or ids[s.judged_player] == true
end

return MT
