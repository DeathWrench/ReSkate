-- SmokeyDawg58's one_up_wire.h / one_up_wire.cpp, line for line, and the part of his
-- throwdown_wire.cpp that carries it (ThrowdownMessage::Kind::one_up = 16). The bytes are his:
-- little-endian, written into a Lua string with string.pack. 64-bit ids are decimal strings and
-- are packed as two 32-bit halves (low first), which is the same 8 bytes.
local MT = require("td/oneup/match")
local SP = require("td/oneup/spawn")
local W = {}

local nz, finite = MT.nz, MT.finite
local TWO32 = 4294967296

-- ---- uint64 as a decimal string -------------------------------------------------------------------
-- (lo, hi) of a decimal id, or nil when it is not one (or does not fit 64 bits).
function W.u64_parts(s)
    if type(s) ~= "string" or not string.match(s, "^%d+$") then return nil end
    local lo, hi = 0, 0
    for i = 1, #s do
        lo = lo * 10 + (string.byte(s, i) - 48)
        local carry = math.floor(lo / TWO32)
        lo -= carry * TWO32
        hi = hi * 10 + carry
        if hi >= TWO32 then return nil end
    end
    return lo, hi
end
function W.u64_text(lo, hi)
    local digits = {}
    repeat
        local r = hi % 10
        hi = (hi - r) / 10
        local current = r * TWO32 + lo
        local q = math.floor(current / 10)
        table.insert(digits, 1, string.char(48 + (current - q * 10)))
        lo = q
    until hi == 0 and lo == 0
    return table.concat(digits)
end
-- A decimal id with its leading zeros dropped ("0" for zero), or nil.
function W.u64_normal(s)
    local lo, hi = W.u64_parts(s)
    if lo == nil then return nil end
    return W.u64_text(lo, hi)
end
-- static_cast<std::uint32_t>(id)
function W.low32(id)
    local lo = W.u64_parts(id)
    return lo or 0
end
local function id_bytes(id)
    local lo, hi = W.u64_parts(id)
    if lo == nil then lo, hi = 0, 0 end
    return string.pack("<I4I4", lo, hi)
end
-- Counters (revision, sequence, line) stay numbers.
-- PORT: a uint64 counter is a Lua double; above 2^53 it is no longer exact (they count up from 1).
local function count_bytes(n)
    local hi = math.floor(n / TWO32)
    return string.pack("<I4I4", n - hi * TWO32, hi)
end

local function steam(id)
    local lo, hi = W.u64_parts(id)
    if lo == nil then return false end
    return bit32.rshift(hi, 24) == 1 and bit32.band(bit32.rshift(hi, 20), 15) == 1 and lo ~= 0
end
W.steam = steam

W.wire_version = 5
-- enum class Action : std::uint8_t { snapshot, join, ready, leave, trick_score, bail };
W.action_names = {"snapshot", "join", "ready", "leave", "trick_score", "bail"}
W.action_number = {}
for i, name in ipairs(W.action_names) do W.action_number[name] = i - 1 end

W.Message = {}
function W.Message.new()
    return {action = "snapshot",
        match = "0", world = "0", leader = "0", sequence = 0, line = 0,
        turn = 0, elapsed = 0, remaining = 0,
        flag = false,
        score = 0,
        spot = vector.zero,
        facing = SP.copy(SP.default_facing),
        state = MT.State.new()}
end
function W.Message.copy(m)
    return {action = m.action, match = m.match, world = m.world, leader = m.leader, sequence = m.sequence, line = m.line,
        turn = m.turn, elapsed = m.elapsed, remaining = m.remaining, flag = m.flag, score = m.score,
        spot = m.spot, facing = SP.copy(m.facing), state = MT.State.copy(m.state)}
end

function W.valid_message(m)
    if not nz(m.match) or not nz(m.world) or not steam(m.leader) or W.action_number[m.action] == nil then return false end
    if m.action == "snapshot" then
        if not (m.state.match == m.match and m.state.world == m.world and m.state.leader == m.leader and MT.valid_state(m.state)) then return false end
        for _, p in ipairs(m.state.players) do
            if not steam(p.id) then return false end
        end
        if not (m.remaining <= 120000 and SP.valid_facing(m.facing)) then return false end
        for _, x in ipairs({m.spot.x, m.spot.y, m.spot.z}) do
            if not (finite(x) and math.abs(x) < 1000000) then return false end
        end
        return true
    end
    -- PORT: UINT64_MAX is 2^64 as a double; any sequence that rounds to it is refused.
    if m.sequence == 0 or m.sequence >= 18446744073709551615 then return false end
    if m.action == "bail" and (m.score ~= 0 or m.flag) then return false end
    if m.action == "trick_score" or m.action == "bail" then
        return m.turn ~= 0 and m.line ~= 0 and m.elapsed <= 125000 and finite(m.score) and m.score >= 0 and m.score <= 2147483647.0
    end
    return true
end

local function b(v) return v and 1 or 0 end

-- Throws (error) for an invalid message, as his encode does.
function W.encode(m)
    if not W.valid_message(m) then error("Invalid 1-Up message", 0) end
    local w = {}
    local function put(fmt, ...) table.insert(w, string.pack(fmt, ...)) end
    put("<I1I1", W.wire_version, W.action_number[m.action])
    table.insert(w, id_bytes(m.match)); table.insert(w, id_bytes(m.world)); table.insert(w, id_bytes(m.leader))
    if m.action == "snapshot" then
        local s = m.state
        table.insert(w, count_bytes(s.revision)); table.insert(w, id_bytes(s.active)); table.insert(w, id_bytes(s.winner)); table.insert(w, id_bytes(s.judged_player))
        put("<I1I4dddI1", MT.phase_number[s.phase], s.turn, s.target, s.best, s.judged_score, b(s.judged_success))
        for _, v in ipairs({s.config.turn_ms, s.config.grace_ms, s.config.countdown_ms, s.config.delivery_ms, s.config.feedback_ms, s.config.max_players}) do
            put("<I4", v)
        end
        put("<I4", m.remaining); put("<fff", m.spot.x, m.spot.y, m.spot.z)
        for _, v in ipairs(m.facing) do put("<f", v) end
        put("<I1", #s.players)
        for _, p in ipairs(s.players) do
            table.insert(w, id_bytes(p.id)); put("<I1I1I1", p.penalties, b(p.ready), b(p.connected))
        end
        put("<I1", #s.notice); table.insert(w, s.notice)
    else
        table.insert(w, count_bytes(m.sequence)); put("<I1", b(m.flag))
        if m.action == "trick_score" or m.action == "bail" then
            put("<I4", m.turn); table.insert(w, count_bytes(m.line)); put("<I4d", m.elapsed, m.score)
        end
    end
    return table.concat(w)
end

-- His Reader: get(n) throws when the bytes run out; flag() throws on a value above 1.
local function reader(bytes)
    local r = {at = 0}
    function r.get(n)
        if n > #bytes - r.at then error("Truncated 1-Up message", 0) end
        local v
        if n == 8 then
            local lo, hi = string.unpack("<I4I4", bytes, r.at + 1)
            r.at += 8
            return lo, hi
        end
        v = string.unpack("<I" .. n, bytes, r.at + 1)
        r.at += n
        return v
    end
    function r.id() local lo, hi = r.get(8); return W.u64_text(lo, hi) end
    function r.count() local lo, hi = r.get(8); return hi * TWO32 + lo end
    function r.flag()
        local v = r.get(1)
        if v > 1 then error("Invalid flag", 0) end
        return v ~= 0
    end
    function r.real()
        if 8 > #bytes - r.at then error("Truncated 1-Up message", 0) end
        local v = string.unpack("<d", bytes, r.at + 1); r.at += 8; return v
    end
    function r.float()
        if 4 > #bytes - r.at then error("Truncated 1-Up message", 0) end
        local v = string.unpack("<f", bytes, r.at + 1); r.at += 4; return v
    end
    return r
end

-- The Message, or nil.
function W.decode(bytes)
    local ok, result = pcall(function()
        if #bytes > 1024 then return nil end
        local r = reader(bytes)
        if r.get(1) ~= W.wire_version then return nil end
        local m = W.Message.new()
        local action = r.get(1)
        m.action = W.action_names[action + 1] or ("action " .. action)
        m.match = r.id(); m.world = r.id(); m.leader = r.id()
        if m.action == "snapshot" then
            local s = m.state; s.match = m.match; s.world = m.world; s.leader = m.leader
            s.revision = r.count(); s.active = r.id(); s.winner = r.id(); s.judged_player = r.id()
            local phase = r.get(1)
            s.phase = MT.phase_names[phase + 1] or ("phase " .. phase); s.turn = r.get(4)
            s.target = r.real(); s.best = r.real(); s.judged_score = r.real(); s.judged_success = r.flag()
            for _, key in ipairs({"turn_ms", "grace_ms", "countdown_ms", "delivery_ms", "feedback_ms", "max_players"}) do s.config[key] = r.get(4) end
            m.remaining = r.get(4)
            local x = r.float(); local y = r.float(); local z = r.float()
            m.spot = vector.create(x, y, z)
            for i = 1, 9 do m.facing[i] = r.float() end
            local count = r.get(1); if count > 6 then return nil end
            for _ = 1, count do
                local p = MT.Player.new(); p.id = r.id(); p.penalties = r.get(1); p.ready = r.flag(); p.connected = r.flag(); table.insert(s.players, p)
            end
            local count_text = r.get(1); if count_text > 192 then return nil end
            local chars = {}
            for _ = 1, count_text do
                local c = r.get(1); if c < 32 or c > 126 then return nil end
                table.insert(chars, string.char(c))
            end
            s.notice = table.concat(chars)
        else
            m.sequence = r.count(); m.flag = r.flag()
            if m.action == "trick_score" or m.action == "bail" then
                m.turn = r.get(4); m.line = r.count(); m.elapsed = r.get(4); m.score = r.real()
            end
        end
        if r.at ~= #bytes or not W.valid_message(m) then return nil end
        return m
    end)
    if not ok then return nil end
    return result
end

-- One reliable ordered stream per sender and match. Repeated messages do nothing. A bounded
-- reorder window preserves trick order without duplicating any native points.
local InputOrder = {}
InputOrder.__index = InputOrder
W.InputOrder = InputOrder
function InputOrder.new(first)
    return setmetatable({next_ = first or 1, held_ = {}}, InputOrder)
end
function InputOrder:push(m)
    local ready = {}
    if m.sequence == 0 or m.sequence < self.next_ or m.sequence - self.next_ >= 64 or not W.valid_message(m) or m.action == "snapshot" then return ready end
    if self.held_[m.sequence] == nil then self.held_[m.sequence] = m end
    while true do
        local item = self.held_[self.next_]
        if item == nil then break end
        table.insert(ready, item); self.held_[self.next_] = nil; self.next_ += 1
    end
    return ready
end
function InputOrder:reset() self.next_ = 1; self.held_ = {} end

function W.apply_snapshot(current, m, sender, world)
    if m.action ~= "snapshot" or sender ~= m.leader or m.world ~= world or not W.valid_message(m) or
        (nz(current.match) and (current.match ~= m.match or current.leader ~= m.leader or m.state.revision <= current.revision)) then return false end
    MT.State.assign(current, m.state); return true
end

-- ---- throwdown_wire.cpp, Kind::one_up ---------------------------------------------------------------
W.kind_one_up = 16 -- the envelope's first byte (game modes use 0xD5)

local function individual(id) return steam(id) end
-- valid_throwdown for Kind::one_up
local function valid_throwdown(e)
    if not individual(e.leader) or e.id == 0 then return false end
    return #e.one_up >= 26 and #e.one_up <= 1024 and string.byte(e.one_up, 1) == W.wire_version
end
-- e = {leader, id (uint32), one_up (bytes)}. Throws for an invalid one.
function W.encode_throwdown(e)
    if not valid_throwdown(e) then error("Invalid throwdown message", 0) end
    return string.pack("<I1", W.kind_one_up) .. id_bytes(e.leader) .. string.pack("<I4I2", e.id, #e.one_up) .. e.one_up
end
-- {leader, id, one_up} for a Kind::one_up message, or nil.
-- PORT: his decode_throwdown reads every kind; only one_up is 1-Up's (receive drops the rest).
function W.decode_throwdown(bytes)
    local ok, result = pcall(function()
        if #bytes < 15 then return nil end
        local kind = string.unpack("<I1", bytes, 1)
        if kind ~= W.kind_one_up then return nil end
        local lo, hi = string.unpack("<I4I4", bytes, 2)
        local id, length = string.unpack("<I4I2", bytes, 10)
        if length > 1024 or length > #bytes - 15 then return nil end
        local e = {leader = W.u64_text(lo, hi), id = id, one_up = string.sub(bytes, 16, 15 + length)}
        if 15 + length ~= #bytes or not valid_throwdown(e) then return nil end
        return e
    end)
    if not ok then return nil end
    return result
end

return W
