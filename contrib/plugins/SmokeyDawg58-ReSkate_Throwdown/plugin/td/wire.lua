-- His wire, line for line: mode_rules.cpp's Writer, Reader, encode, decode and message_version (lines
-- 24-47 and 472-736), and mode_transport.h (transport_messages, mode_fragment, ModeTransfers). A message
-- is his Message table (td/rules.lua R.Message()); the bytes are his, little-endian, in a Lua string.
-- 64-bit ids are decimal strings, written as two 32-bit halves (low first), which is the same 8 bytes.
-- Every function is added to R (and so to M) under his name; encode throws (error) as his does.
local R = require("td/rules")
local W = {}

local finite, isfinite = R.finite, R.isfinite
local TWO32 = 4294967296

-- ---- uint64 as a decimal string -------------------------------------------------------------------
-- (lo, hi) of a decimal id, or nil when it is not one (or does not fit 64 bits).
local function u64_parts(s)
    if type(s) == "number" then s = string.format("%.0f", s) end
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
local function u64_text(lo, hi)
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
W.u64_parts, W.u64_text = u64_parts, u64_text
local function trunc(x)
    if x >= 0 then return math.floor(x) end
    return math.ceil(x)
end
-- static_cast<std::int32_t> of a std::uint32_t read off the wire.
local function i32(n)
    if n >= 2147483648 then return n - TWO32 end
    return n
end

local kinds = {"setup", "state", "event", "leave", "end", "join", "tags", "hello", "ready"}
local kind_number = {}
for i, k in ipairs(kinds) do kind_number[k] = i end
local events = {"line", "bail", "checkpoint", "position", "trick"}
local event_number = {}
for i, e in ipairs(events) do event_number[e] = i end
local tag_kinds = {"grind", "gap"}
local tag_kind_number = {grind = 1, gap = 2}

-- ---- Writer and Reader ----------------------------------------------------------------------------
local Writer = {}
Writer.__index = Writer
local function writer() return setmetatable({parts = {}, size = 0}, Writer) end
-- integer(value, size): the low `size` bytes of value (his static_cast to the unsigned type).
function Writer:integer(value, size)
    local n = trunc(value) % (2 ^ (8 * size))
    local piece
    if size == 8 then
        local hi = math.floor(n / TWO32)
        piece = string.pack("<I4I4", n - hi * TWO32, hi)
    else
        piece = string.pack("<I" .. size, n)
    end
    table.insert(self.parts, piece)
    self.size += size
end
-- A 64-bit id (a decimal string): 8 bytes. Anything that is not one is 0.
function Writer:id(id)
    local lo, hi = u64_parts(id)
    if lo == nil then lo, hi = 0, 0 end
    table.insert(self.parts, string.pack("<I4I4", lo, hi))
    self.size += 8
end
function Writer:real(value)
    table.insert(self.parts, string.pack("<f", value))
    self.size += 4
end
function Writer:vec(v)
    self:real(v.x)
    self:real(v.y)
    self:real(v.z)
end
function Writer:raw(text)
    table.insert(self.parts, text)
    self.size += #text
end
function Writer:bytes() return table.concat(self.parts) end

local Reader = {}
Reader.__index = Reader
local function reader(bytes) return setmetatable({bytes = bytes, at = 0, ok = true}, Reader) end
function Reader:integer(size)
    if not self.ok or size > #self.bytes - self.at then
        self.ok = false
        return 0
    end
    local value
    if size == 8 then
        local lo, hi = string.unpack("<I4I4", self.bytes, self.at + 1)
        value = hi * TWO32 + lo -- PORT: only compared with zero or counted; ids are read with :id()
    else
        value = string.unpack("<I" .. size, self.bytes, self.at + 1)
    end
    self.at += size
    return value
end
function Reader:id()
    if not self.ok or 8 > #self.bytes - self.at then
        self.ok = false
        return "0"
    end
    local lo, hi = string.unpack("<I4I4", self.bytes, self.at + 1)
    self.at += 8
    return u64_text(lo, hi)
end
function Reader:real()
    if not self.ok or 4 > #self.bytes - self.at then
        self.ok = false
        return 0
    end
    local value = string.unpack("<f", self.bytes, self.at + 1)
    self.at += 4
    return value
end
function Reader:vec()
    local x = self:real()
    local y = self:real()
    local z = self:real()
    return vector.create(x, y, z)
end

-- ---- tags and texts -------------------------------------------------------------------------------
local max_tags_per_message = 12
local function write_tags(w, tags, limit)
    if #tags > limit then error("too many game mode tags", 0) end
    w:integer(#tags, 1)
    for _, t in ipairs(tags) do
        if not R.valid_tag(t) then error("invalid game mode tag", 0) end
        w:integer(tag_kind_number[t.kind], 1)
        w:integer(#t.path, 1)
        for _, p in ipairs(t.path) do w:vec(p) end
    end
end
local function read_tags(r, tags, limit)
    local count = r:integer(1)
    if not r.ok or count > limit then return false end
    local i = 0
    while i < count and r.ok do
        local t = R.Tag()
        local kind = r:integer(1)
        t.kind = tag_kinds[kind] or kind -- static_cast<TagKind>: another number stays one, and is not valid
        local points = r:integer(1)
        if not r.ok or points > R.max_tag_points then return false end
        local k = 0
        while k < points and r.ok do
            table.insert(t.path, r:vec())
            k += 1
        end
        if not r.ok or not R.valid_tag(t) then return false end
        table.insert(tags, t)
        i += 1
    end
    return r.ok
end
-- Shown on screen: printable text only (a byte below 0x20 is a space).
local function printable(text)
    local out = {}
    for i = 1, #text do
        local c = string.byte(text, i)
        out[i] = if c < 0x20 then " " else string.char(c)
    end
    return table.concat(out)
end
-- A trick's name: a length byte and its text (printable, at most max_trick_length).
local function write_text(w, text)
    if #text > R.max_trick_length then error("game mode trick name too long", 0) end
    w:integer(#text, 1)
    w:raw(text)
end
local function read_text(r)
    local length = r:integer(1)
    if not r.ok or length > R.max_trick_length or length > #r.bytes - r.at then return nil end
    local text = string.sub(r.bytes, r.at + 1, r.at + length)
    r.at += length
    return printable(text)
end

-- ---- encode / decode ------------------------------------------------------------------------------
-- Throws (error) for a message that breaks the limits.
function W.encode(m)
    local w = writer()
    w:integer(R.wire_magic, 1)
    w:integer(m.version or R.wire_version, 1)
    w:integer(kind_number[m.kind] or 0, 1)
    w:id(m.leader)
    w:integer(m.game, 4)
    local kind = m.kind
    if kind == "setup" then
        local s = m.settings
        if not R.valid_settings(s) then error("invalid game mode settings", 0) end
        w:integer(R.mode_number[s.mode], 1)
        w:integer(s.duration_s, 4)
        w:integer(s.turn_s, 4)
        w:integer(s.strikes, 1)
        w:real(s.radius)
        w:real(s.area_radius)
        w:integer(#s.yaws, 4)
        for _, yaw in ipairs(s.yaws) do w:real(yaw) end
        w:integer(#s.widths, 4)
        for _, width in ipairs(s.widths) do w:real(width) end
        w:integer(if s.has_spawn then 1 else 0, 1)
        w:integer(if s.race_finish then 1 else 0, 1)
        if s.has_spawn then w:vec(s.spawn) end
        w:integer(#s.corners, 1)
        for _, p in ipairs(s.corners) do w:vec(p) end
        w:integer(#s.points, 4)
        for _, p in ipairs(s.points) do w:vec(p) end
        w:integer(#s.gate_kinds, 4)
        for _, k in ipairs(s.gate_kinds) do w:integer(R.gate_kind_number[k], 1) end
        w:integer(#s.arrow_rolls, 4)
        for _, roll in ipairs(s.arrow_rolls) do w:real(roll) end
        w:integer(#s.gate_pitches, 4)
        for _, pitch in ipairs(s.gate_pitches) do w:real(pitch) end
        w:integer(s.trick_kinds, 1)
    elseif kind == "state" then
        if #m.standings > R.max_players or #m.zones > R.max_zones then error("game mode state too large", 0) end
        w:integer(R.phase_number[m.phase] or 0, 1)
        w:integer(m.remaining_ms, 4)
        w:id(m.turn)
        w:integer(m.target, 4)
        w:integer(#m.standings, 1)
        for _, s in ipairs(m.standings) do
            w:id(s.player)
            w:integer(s.score, 4)
            w:integer(s.aux, 4)
            w:integer((if s.out then 1 else 0) + (if s.up then 2 else 0), 1)
            w:integer(s.remaining_ms or 0, 4)
        end
        w:integer(#m.zones, 1)
        for _, z in ipairs(m.zones) do
            w:integer(z.zone, 1)
            w:id(z.owner)
            w:integer(z.best, 4)
        end
        if #m.calls > R.max_calls then error("too many game mode calls", 0) end
        w:integer(m.call_serial, 4)
        w:integer(#m.calls, 1)
        for _, text in ipairs(m.calls) do
            if #text > R.max_call_length then error("game mode call too long", 0) end
            w:integer(#text, 1)
            w:raw(text)
        end
        write_text(w, m.trick or "")
        w:id(m.setter)
    elseif kind == "event" then
        if not finite(m.at) then error("invalid game mode event", 0) end
        -- PORT: his Event is always one of five; an unknown Lua name is refused like a bad event.
        if event_number[m.event] == nil then error("invalid game mode event", 0) end
        w:integer(event_number[m.event], 1)
        w:integer(m.value, 4)
        w:integer(m.extra, 4)
        w:vec(m.at)
        w:integer(m.sequence, 4)
        write_tags(w, m.tags or {}, R.max_line_tags)
        write_text(w, m.trick or "")
    elseif kind == "tags" then
        if m.first + #m.tags > R.max_tags then error("game mode tags out of range", 0) end
        w:integer(m.first, 1)
        write_tags(w, m.tags, max_tags_per_message)
    elseif kind == "leave" or kind == "end" or kind == "join" or kind == "ready" or kind == "hello" then
        -- nothing more
    else
        error("unknown game mode message", 0)
    end
    return w:bytes()
end

function W.is_mode_message(bytes) return #bytes > 0 and string.byte(bytes, 1) == R.wire_magic end
-- The version a game mode message was written with (0: not one), for an "update" notice.
function W.message_version(bytes)
    if #bytes >= 2 and string.byte(bytes, 1) == R.wire_magic then return string.byte(bytes, 2) end
    return 0
end

-- The Message, or nil for bytes that are not a game mode message of this version.
function W.decode(bytes)
    local ok, result = pcall(function()
        local r = reader(bytes)
        local size = #bytes
        if r:integer(1) ~= R.wire_magic then return nil end
        local m = R.Message()
        m.version = r:integer(1)
        if m.version ~= R.wire_version then return nil end
        local kind = r:integer(1)
        if kind < 1 or kind > 9 then return nil end
        m.kind = kinds[kind]
        m.leader = r:id()
        m.game = r:integer(4)
        if m.leader == "0" or m.game == 0 then return nil end
        if m.kind == "setup" then
            local s = m.settings
            local mode = r:integer(1)
            s.mode = R.all_modes[mode] or mode -- static_cast<Mode>: another number stays one, and is not valid
            s.duration_s = r:integer(4)
            s.turn_s = r:integer(4)
            s.strikes = r:integer(1)
            s.radius = r:real()
            s.area_radius = r:real()
            local yaws = r:integer(4)
            if not r.ok or yaws > (size - r.at) // 4 then return nil end
            for _ = 1, yaws do
                if not r.ok then break end
                table.insert(s.yaws, r:real())
            end
            local widths = r:integer(4)
            if not r.ok or widths > (size - r.at) // 4 then return nil end
            for _ = 1, widths do
                if not r.ok then break end
                table.insert(s.widths, r:real())
            end
            s.has_spawn = r:integer(1) ~= 0
            s.race_finish = r:integer(1) ~= 0
            if s.has_spawn then s.spawn = r:vec() end
            local corners = r:integer(1)
            if corners > R.max_corners then return nil end
            for _ = 1, corners do
                if not r.ok then break end
                table.insert(s.corners, r:vec())
            end
            local points = r:integer(4)
            if not r.ok or points > (size - r.at) // 12 then return nil end
            for _ = 1, points do
                if not r.ok then break end
                table.insert(s.points, r:vec())
            end
            local gate_kinds = r:integer(4)
            if not r.ok or gate_kinds > size - r.at then return nil end
            for _ = 1, gate_kinds do
                if not r.ok then break end
                local k = r:integer(1)
                table.insert(s.gate_kinds, R.gate_kinds[k + 1] or k) -- another number stays one, and is not valid
            end
            local rolls = r:integer(4)
            if not r.ok or rolls > (size - r.at) // 4 then return nil end
            for _ = 1, rolls do
                if not r.ok then break end
                table.insert(s.arrow_rolls, r:real())
            end
            local pitches = r:integer(4)
            if not r.ok or pitches > (size - r.at) // 4 then return nil end
            for _ = 1, pitches do
                if not r.ok then break end
                table.insert(s.gate_pitches, r:real())
            end
            s.trick_kinds = r:integer(1)
            if not r.ok or not R.valid_settings(s) then return nil end
        elseif m.kind == "state" then
            local phase = r:integer(1)
            if phase < 1 or phase > 4 then return nil end
            m.phase = R.phases[phase]
            m.remaining_ms = r:integer(4)
            m.turn = r:id()
            m.target = i32(r:integer(4))
            local standings = r:integer(1)
            if standings > R.max_players then return nil end
            for _ = 1, standings do
                if not r.ok then break end
                local st = R.Standing()
                st.player = r:id()
                st.score = i32(r:integer(4))
                st.aux = i32(r:integer(4))
                local flags = r:integer(1)
                st.out = bit32.band(flags, 1) ~= 0
                st.up = bit32.band(flags, 2) ~= 0
                st.remaining_ms = r:integer(4)
                table.insert(m.standings, st)
            end
            local zones = r:integer(1)
            if zones > R.max_zones then return nil end
            for _ = 1, zones do
                if not r.ok then break end
                local z = R.ZoneOwner()
                z.zone = r:integer(1)
                z.owner = r:id()
                z.best = i32(r:integer(4))
                if z.zone >= R.max_zones then return nil end
                table.insert(m.zones, z)
            end
            m.call_serial = r:integer(4)
            local calls = r:integer(1)
            if calls > R.max_calls then return nil end
            for _ = 1, calls do
                if not r.ok then break end
                local length = r:integer(1)
                if not r.ok or length > R.max_call_length or length > size - r.at then return nil end
                local text = string.sub(bytes, r.at + 1, r.at + length)
                r.at += length
                -- Shown on screen: printable text only.
                table.insert(m.calls, printable(text))
            end
            local trick = read_text(r)
            if trick == nil then return nil end
            m.trick = trick
            m.setter = r:id()
        elseif m.kind == "event" then
            local event = r:integer(1)
            if event < 1 or event > 5 then return nil end
            m.event = events[event]
            m.value = i32(r:integer(4))
            m.extra = i32(r:integer(4))
            m.at = r:vec()
            m.sequence = r:integer(4)
            if not finite(m.at) or m.value < 0 or not read_tags(r, m.tags, R.max_line_tags) then return nil end
            local trick = read_text(r)
            if trick == nil then return nil end
            m.trick = trick
        elseif m.kind == "tags" then
            m.first = r:integer(1)
            if not read_tags(r, m.tags, max_tags_per_message) or m.first + #m.tags > R.max_tags then return nil end
        end -- leave, end, join, ready, hello: nothing more
        if not r.ok or r.at ~= size then return nil end
        return m
    end)
    if ok then return result end
    return nil
end

-- ---- mode_transport.h -----------------------------------------------------------------------------
-- Keep the session's packet contract. The editor has no gate cap; only a defensive transfer budget
-- bounds untrusted remote allocations.
-- PORT: his mode_packet_bytes is 4096 (his session packets); a plugin message is at most 4082 bytes,
-- so a packet here is at most 4082 and a fragment carries 4082 - 27 bytes, as ReSkate's C++ did.
W.mode_packet_bytes, W.mode_fragment_header = 4082, 27
W.mode_fragment_bytes = W.mode_packet_bytes - W.mode_fragment_header
W.mode_transfer_bytes = 64 * 1024 * 1024
-- FNV-1a over the bytes. (value ^ byte) * 16777619 mod 2^32, exact in doubles: 16777619 = 2^24 + 403.
function W.mode_transfer_hash(bytes)
    local value = 2166136261
    for i = 1, #bytes do
        value = bit32.bxor(value, string.byte(bytes, i))
        value = ((value % 256) * 16777216 + value * 403) % TWO32
    end
    return value
end
-- His encode, in pieces when it is a setup over the packet size.
function W.transport_messages(m)
    local bytes = W.encode(m)
    if #bytes <= W.mode_packet_bytes then return {bytes} end
    if m.kind ~= "setup" or #bytes > W.mode_transfer_bytes then error("route transfer exceeds resource budget", 0) end
    local hash = W.mode_transfer_hash(bytes)
    local out = {}
    local head = string.sub(bytes, 1, 2) .. string.char(9) .. string.sub(bytes, 4, 15)
    local at = 0
    while at < #bytes do
        table.insert(out, head .. string.pack("<I4I4I4", hash, #bytes, at) ..
            string.sub(bytes, at + 1, math.min(at + W.mode_fragment_bytes, #bytes)))
        at += W.mode_fragment_bytes
    end
    return out
end
function W.mode_fragment(bytes)
    return #bytes >= 3 and string.byte(bytes, 1) == R.wire_magic and string.byte(bytes, 2) == R.wire_version and string.byte(bytes, 3) == 9
end

-- class ModeTransfers: the pieces of a setup, by sender, until all of them have come.
local ModeTransfers = {}
ModeTransfers.__index = ModeTransfers
W.ModeTransfers = ModeTransfers
function ModeTransfers.new() return setmetatable({pending_ = {}}, ModeTransfers) end
function ModeTransfers:clear() self.pending_ = {} end
local function count(t)
    local n = 0
    for _ in pairs(t) do n += 1 end
    return n
end
local function pending(hash, total, leader, updated, game)
    return {hash = hash, total = total, leader = leader, updated = updated, game = game, chunks = {}, received = 0}
end
-- The setup, once its last piece came; else nil.
function ModeTransfers:receive(sender, bytes, now)
    for key, p in pairs(self.pending_) do
        if now >= p.updated and now - p.updated > 10000 then self.pending_[key] = nil end
    end
    if not W.mode_fragment(bytes) or #bytes < W.mode_fragment_header or #bytes > W.mode_packet_bytes then return nil end
    local lo, hi = string.unpack("<I4I4", bytes, 4)
    local leader = u64_text(lo, hi)
    local game, hash, total, at = string.unpack("<I4I4I4I4", bytes, 12)
    local size = #bytes - W.mode_fragment_header
    if type(sender) == "number" then sender = string.format("%.0f", sender) end
    if sender == nil or sender == "" or sender == "0" or leader ~= sender or game == 0 or total <= W.mode_packet_bytes or
        total > W.mode_transfer_bytes or at >= total or at % W.mode_fragment_bytes ~= 0 or size ~= math.min(W.mode_fragment_bytes, total - at) then
        return nil
    end
    if self.pending_[sender] == nil and count(self.pending_) >= R.max_players then return nil end
    local p = self.pending_[sender]
    if p == nil or p.hash ~= hash or p.total ~= total or p.leader ~= leader or p.game ~= game then
        p = pending(hash, total, leader, now, game)
        self.pending_[sender] = p
    end
    p.updated = now
    local part = string.sub(bytes, W.mode_fragment_header + 1)
    local known = p.chunks[at]
    if known == nil then
        p.chunks[at] = part
        p.received += size
    elseif known ~= part then
        self.pending_[sender] = nil
        return nil
    end
    if p.received ~= total then return nil end
    local offsets = {}
    for offset in pairs(p.chunks) do table.insert(offsets, offset) end
    table.sort(offsets)
    local pieces = {}
    for i, offset in ipairs(offsets) do pieces[i] = p.chunks[offset] end
    local joined = table.concat(pieces)
    self.pending_[sender] = nil
    if W.mode_transfer_hash(joined) ~= hash then return nil end
    local m = W.decode(joined)
    if not m or m.kind ~= "setup" or m.leader ~= leader or m.game ~= game then return nil end
    return m
end

-- What ReSkate's receiver:receive(sender, bytes, now) answered, for td/tick.lua: the message, or nil
-- and "none" (not a game mode message), "partial" (a piece of a setup still arriving) or "version"
-- with the sender's wire version. (His session's receive did the same with ModeTransfers and decode.)
function W.receive_mode_bytes(transfers, sender, bytes, now)
    if not W.is_mode_message(bytes) then return nil, "none" end
    local m
    if W.mode_fragment(bytes) then
        m = transfers:receive(sender, bytes, now)
        if not m then return nil, "partial" end
    else
        m = W.decode(bytes)
    end
    if not m then return nil, "version", W.message_version(bytes) end
    return m
end

for name, f in pairs(W) do R[name] = f end
return W
