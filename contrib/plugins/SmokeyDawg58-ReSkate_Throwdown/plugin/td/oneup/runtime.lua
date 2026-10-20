-- SmokeyDawg58's one_up_runtime.h / one_up_runtime.cpp, line for line: 1-Up's offers, hosting,
-- joining, turns and scoring, and the View his UI read (td/ui_oneup.lua turns it into the throwdown
-- kit's documents, as his one_up_menu.cpp turned it into native widgets).
--
-- The lead wires it: tick(now) every tick, receive(sender_id, payload) for a plugin message,
-- command(verb, args) for what his UI queued (td/ui_oneup.lua sends the kit's events here). His session called
-- one_up::receive for each throwdown message, then one_up::tick with its ThrowdownRelayInput, and
-- sent what tick returned to every other player; here tick builds that input from the plugin API
-- (relay_input below) and sends with reskate.net.send.
local MT = require("td/oneup/match")
local W = require("td/oneup/wire")
local N = require("td/oneup/native")
local SP = require("td/oneup/spawn")

local O = {}
local nz, id_less = MT.nz, MT.id_less
local Token, State = MT.Token, MT.State

-- td/core (his dingosdk::modes): modes::active(), native_view(), request_native_quit(). Read
-- when used, so the two modules may load in either order.
local function core() return require("td/core") end

-- ---- struct Offer, struct View, struct SpawnRequest --------------------------------------------------
local function View()
    return {state = State.new(), ["local"] = "0", world = "0", names = {}, offers = {}, remaining = 0, published = 0,
        scoring_ready = false, can_create = false, participant = false, solo_test = false, positioning = false, status = ""}
end
-- std::string View::name(PlayerId id) const
local function view_name(v, id)
    local found = v.names[id]
    return (found == nil or found == "") and "Skater" or found
end
local function SpawnRequest()
    return {position = vector.zero, world = "0", ["local"] = "0", seconds = 20, players = 4, facing = SP.copy(SP.default_facing)}
end
-- struct ThrowdownRelayInput
local function RelayInput()
    return {["local"] = "0", peers = {}, in_world = false, world = "0", local_name = "", position = nil, barred = false, local_only = false}
end

-- ---- struct Runtime -----------------------------------------------------------------------------------
-- struct Seen { Message message; Time at{}; };
local r = {
    published = View(),
    commands = {},
    bails = {},          -- {token, at}
    spawn_request = nil, -- SpawnRequest or nil
    inbox = {},          -- {sender, message}
    outgoing = {},
    hosted = nil,        -- Match or nil
    selected = State.new(),
    spot = vector.zero,
    facing = SP.copy(SP.default_facing),
    offers = {},         -- leader id: Seen
    inputs = {},         -- sender id: InputOrder
    sequences = {},      -- "leader:match": sequence
    names = {},          -- id: name
    input = RelayInput(),
    snapshot_at = 0, next_send = 0, position_until = 0, turn_at = 0,
    sequence = 0, wire_revision = 0,
    remaining = 0,
    placed = Token.new(), clock_token = Token.new(),
    positioned = false,
    status = "",
    waiting = false, playing = false, countdown_input = false, markers_restricted = false,
    active = "0",
}

local function member(s, id)
    for _, p in ipairs(s.players) do
        if p.id == id and p.connected then return true end
    end
    return false
end
local function running(s) return s.phase ~= "lobby" and s.phase ~= "finished" and s.phase ~= "cancelled" end
local function distance(a, b)
    local result = 0
    for _, d in ipairs({a.x - b.x, a.y - b.y, a.z - b.z}) do result += d * d end
    return math.sqrt(result)
end
local function present(id)
    if id == r.input["local"] then return true end
    for _, p in ipairs(r.input.peers) do
        if p.id == id then return true end
    end
    return false
end
local function position(id)
    if id == r.input["local"] then return r.input.position end
    for _, p in ipairs(r.input.peers) do
        if p.id == id then return p.position end
    end
    return nil
end
local function emit(m)
    if r.input.local_only then return end
    if r.hosted and r.hosted:solo_test() then return end
    local envelope = {leader = m.leader, id = bit32.bor(W.low32(m.match), 1), one_up = W.encode(m)}
    table.insert(r.outgoing, W.encode_throwdown(envelope))
end
local function apply_input(sender, m, now)
    if not r.hosted or m.match ~= r.hosted:state().match or m.world ~= r.input.world or m.leader ~= r.input["local"] or not present(sender) then return end
    local match = r.hosted
    local ready = {}
    if r.input.local_only and sender == r.input["local"] then table.insert(ready, m)
    else
        local stream = r.inputs[sender]
        if stream == nil then
            stream = W.InputOrder.new(m.action == "join" and m.sequence or 1)
            r.inputs[sender] = stream
        end
        ready = stream:push(m)
    end
    for _, item in ipairs(ready) do
        local at = position(sender)
        local token = Token.new(item.match, item.turn, sender)
        if item.action == "join" then match:join(sender)
        elseif item.action == "ready" then
            if not item.flag or (at and distance(at, r.spot) <= 2) then match:ready(sender, item.flag) end
        elseif item.action == "leave" then match:leave(sender, now)
        elseif item.action == "trick_score" then match:trick_scored(token, item.line, item.score, item.elapsed, now)
        elseif item.action == "bail" then match:bailed(token, item.elapsed, now)
        elseif item.action == "snapshot" then -- nothing
        end
    end
end
local function send_input(m, now)
    if not nz(r.selected.match) then return end
    m.match = r.selected.match; m.world = r.selected.world; m.leader = r.selected.leader; r.sequence += 1; m.sequence = r.sequence
    r.sequences[m.leader .. ":" .. m.match] = r.sequence
    if r.hosted then apply_input(r.input["local"], m, now) else emit(m) end
end
local function clear()
    r.hosted = nil; r.selected = State.new(); r.inputs = {}; r.sequence = 0; r.wire_revision = 0
    r.placed = Token.new(); r.clock_token = Token.new(); r.waiting = false; r.playing = false; r.countdown_input = false; r.markers_restricted = false; r.active = "0"
    N.arm_native_lines(Token.new(), false, 0); reskate.session.spectate("0")
end

-- modes::active(), local_throwdown_active()
local function modes_active()
    local ok, M = pcall(core)
    return ok and M.state().active == true
end
local function local_throwdown_active() return reskate.throwdowns.state().active == true end

local function publish(now)
    local v = View(); v.state = State.copy(r.selected); v["local"] = r.input["local"]; v.world = r.input.world; v.names = table.clone(r.names)
    v.remaining = r.hosted and r.hosted:remaining(now) or (now - r.snapshot_at < r.remaining and r.remaining - (now - r.snapshot_at) or 0)
    if r.selected.phase == "countdown" then
        if r.hosted then v.positioning = not r.positioned else v.positioning = r.remaining == 0 end
    end
    if v.positioning then v.remaining = r.selected.config.countdown_ms end
    v.published = now; v.scoring_ready = N.native_lines_available(); v.participant = member(r.selected, r.input["local"])
    v.can_create = nz(r.input["local"]) and nz(r.input.world) and r.input.in_world and r.input.position ~= nil and not r.input.barred and v.scoring_ready and
        not local_throwdown_active() and not modes_active()
    v.status = r.status; v.solo_test = r.hosted ~= nil and r.hosted:solo_test()
    local leaders = {}
    for id in pairs(r.offers) do table.insert(leaders, id) end
    table.sort(leaders, id_less) -- std::map order
    for _, id in ipairs(leaders) do
        local offer = r.offers[id]
        if id ~= r.input["local"] and present(id) and now - offer.at < 4000 and offer.message.state.phase ~= "finished" and offer.message.state.phase ~= "cancelled" then
            local connected = 0
            for _, p in ipairs(offer.message.state.players) do
                if p.connected then connected += 1 end
            end
            table.insert(v.offers, {leader = id, match = offer.message.match, name = view_name(v, id), started = offer.message.state.phase ~= "lobby",
                spot = offer.message.spot, facing = SP.copy(offer.message.facing),
                players = connected,
                turn_seconds = offer.message.state.config.turn_ms // 1000, capacity = offer.message.state.config.max_players})
        end
    end
    -- His View is what his UI read; td/ui_oneup.lua builds the kit's documents from it.
    r.published = v
end

-- His istringstream: words read in order; a failed read fails every later one.
local function words(list)
    local w = {i = 0, failed = false}
    function w.word()
        w.i += 1
        return list[w.i]
    end
    -- `args >> unsigned` / `args >> std::uint64_t`: a decimal number, kept as a number or an id string.
    function w.unsigned()
        if w.failed then return nil end
        local text = w.word()
        local digits = text and string.match(text, "^%+?(%d+)$")
        local n = digits and tonumber(digits)
        if n == nil or n > 4294967295 then w.failed = true; return nil end
        return n
    end
    function w.id()
        if w.failed then return nil end
        local text = w.word()
        local digits = text and string.match(text, "^%+?(%d+)$")
        local id = digits and W.u64_normal(digits)
        if id == nil then w.failed = true; return nil end
        return id
    end
    return w
end
local function split(text)
    local list = {}
    for word in string.gmatch(text, "%S+") do table.insert(list, word) end
    return list
end

local seeded = false
local function new_identity(now)
    -- PORT: std::random_device. The plugin VM's math.random starts from the same seed on every
    -- machine, so it is seeded once from the clock and the local id before the first match.
    if not seeded then
        seeded = true
        local seed = math.floor(now) % 2147483647
        for i = 1, #r.input["local"] do seed = (seed * 31 + string.byte(r.input["local"], i)) % 2147483647 end
        math.randomseed(seed)
    end
    local hi, lo = math.floor(math.random() * 4294967296), math.floor(math.random() * 4294967296)
    local identity = W.u64_text(lo, hi)
    if not nz(identity) then identity = W.u64_text(bit32.bor(now % 4294967296, 1), math.floor(now / 4294967296)) end
    return identity
end

local function command(text, now)
    local args = words(split(text)); local action = args.word() or ""
    if action == "leave" then
        -- Native Rime can retain the earlier 1-Up delegate when its waiting
        -- card is reused for Deathrace. Resolve the registration's current
        -- owner before retiring it, so Leave also ends that owner's route.
        -- native_flag_mode_game(): the game of the kit's native flag registration, when it is one
        -- of the game modes' (1-UP's own has none).
        local ok, M = pcall(core)
        if ok then
            local mode = M.state().native
            local flag = reskate.throwdowns.flag.state()
            local game = (flag.mine and flag.busy and flag.mode ~= "oneup") and flag.game or 0
            if game ~= 0 then
                if mode and mode.active and mode.game == game and M.request_native_quit then
                    M.request_native_quit(mode.world, game)
                end
            end
        end
        if nz(r.selected.match) then local m = W.Message.new(); m.action = "leave"; send_input(m, now) end
        if r.hosted then
            local m = W.Message.new(); m.match = r.selected.match; m.world = r.selected.world; m.leader = r.selected.leader
            m.state = State.copy(r.hosted:state()); r.wire_revision += 1; m.state.revision = r.wire_revision; m.spot = r.spot; m.facing = SP.copy(r.facing); emit(m)
        end
        -- ReSkate: "leave keep-flag" is his arm_native_setup's leave of an ended match, after the kit
        -- already opened the next setup's flag (his armed the setup after the leave).
        if args.word() ~= "keep-flag" then reskate.throwdowns.flag.leave() end
        clear(); r.status = "You left 1-Up."; return
    end
    if not nz(r.input["local"]) or not nz(r.input.world) or not r.input.in_world or r.input.position == nil or r.input.barred then
        r.status = "Join a session and load the map before playing 1-Up."; return
    end
    if not N.native_lines_available() then r.status = "Waiting for the game's scoring system."; return end
    if local_throwdown_active() or modes_active() then r.status = "Leave your current throwdown before playing 1-Up."; return end
    if action == "create" then
        if nz(r.selected.match) then r.status = "Exit your current 1-Up match first."; return end
        local seconds = args.unsigned(); if seconds == nil then seconds = 20 end
        local players = args.unsigned(); if players == nil then players = 6 end
        if seconds < 10 or seconds > 120 then r.status = "Choose a turn from 10 to 120 seconds."; return end
        local config = MT.Config.new(); config.turn_ms = seconds * 1000; config.max_players = players
        -- Native Throwdowns announce the activity before their turn countdown.
        -- Both happen while the player is positioned on the board and locked.
        config.countdown_ms = 6000
        if not MT.Config.valid(config) then r.status = "Choose 1 to 6 players and a turn from 10 to 120 seconds."; return end
        local identity = new_identity(now)
        r.hosted = MT.Match.new(identity, r.input.world, r.input["local"], config); r.selected = State.copy(r.hosted:state()); r.spot = r.input.position; r.facing = SP.copy(SP.default_facing)
        r.sequence = 0; r.wire_revision = 0; r.next_send = 0; r.status = "Spot placed. Enrolled skaters wait for you to start."
    elseif action == "join" then
        local leader = args.id(); local identity = args.id()
        if leader == nil or identity == nil or nz(r.selected.match) then return end
        local it = r.offers[leader]
        if it == nil or it.message.match ~= identity or now - it.at >= 4000 then r.status = "That match is no longer available."; return end
        local m = it.message
        r.selected = State.copy(m.state); r.spot = m.spot; r.facing = SP.copy(m.facing); r.remaining = m.remaining; r.snapshot_at = now
        r.sequence = r.sequences[m.leader .. ":" .. m.match] or 0
        if r.selected.phase == "lobby" then local input = W.Message.new(); input.action = "join"; send_input(input, now); r.status = "Joining the match..."
        else r.status = "Watching this match. Join the next lobby after the host chooses Rematch." end
    elseif action == "enroll" and r.selected.phase == "lobby" and not member(r.selected, r.input["local"]) then
        local m = W.Message.new(); m.action = "join"; send_input(m, now); r.status = "Joining the next match..."
    elseif action == "start" and r.hosted then
        local solo = (r.hosted:state().config.max_players == 1 or #r.input.peers == 0) and #r.hosted:state().players == 1
        local started
        if solo then started = r.hosted:start_solo_test(now) else started = r.hosted:start(now) end
        if started then r.status = solo and "Solo test started. Get ready!" or "Get ready!"
        else r.status = solo and "Unable to start this lobby." or "At least two skaters must enroll." end
        reskate.log("1-Up: " .. r.status, "info")
    elseif action == "solo" then
        if not r.hosted then r.status = "Place a 1-Up flag before starting a solo test."; return end
        if #r.input.peers ~= 0 and r.hosted:state().config.max_players ~= 1 then r.status = "Select Players 1 to practice alone in a shared session."; return end
        r.status = r.hosted:start_solo_test(now) and "Solo test started. Beat your previous line; three penalties end the test." or
            "Solo testing needs exactly one enrolled skater in a waiting 1-Up lobby."
        reskate.log("1-Up: " .. r.status, "info")
    elseif action == "rematch" and r.hosted then
        if r.hosted:rematch(now) then r.placed = Token.new(); r.status = "Rematch opened. Enrolled skaters are waiting for the host." end
    end
end

local function create_selected_spawn(request, now)
    local finite = true
    for _, n in ipairs({request.position.x, request.position.y, request.position.z}) do
        if not (MT.finite(n) and math.abs(n) < 100000) then finite = false end
    end
    if nz(r.selected.match) or request.world ~= r.input.world or request["local"] ~= r.input["local"] or
        not SP.valid_facing(request.facing) or not finite then
        r.status = "The selected flag is no longer available. Place it again."; return
    end
    -- Reuse all creation eligibility and configuration checks, then publish the
    -- selected spawn before the first snapshot can leave this client tick.
    command("create " .. string.format("%d", request.seconds) .. " " .. string.format("%d", request.players), now)
    if r.hosted then
        r.spot = request.position
        r.facing = SP.copy(request.facing)
        reskate.log(string.format("1-Up: flag handed to elimination rules, Players %d, turn %d seconds.", request.players, request.seconds), "info")
        -- Flag placement uses the native picker. After confirmation use the
        -- existing arrival check, then wait for the host's explicit Start.
    end
end

-- ---- the session's ThrowdownRelayInput, from the plugin API ---------------------------------------------
-- His session.cpp built it (relay_throwdowns) and, with no session, ticked 1-Up with
-- one_up::local_input (one_up_local_input.h): local practice that never advertises a peer.
local function relay_input()
    local input = RelayInput()
    local world = reskate.session.world()
    -- PORT: "the world is loaded and playing" is the session's own flag; the closest the API has is
    -- a loaded level.
    local in_world = reskate.level.current() ~= nil
    local skater = in_world and reskate.skater.position() or nil
    if reskate.session.active() then
        local me = reskate.session.me()
        input["local"] = me and me.id or "0"
        -- PORT: his `listed` also leaves out peers the server flagged for game speed or scoring mods;
        -- the API shows only the local player's flag (reskate.session.world().barred).
        input.barred = world.barred == true
        local positions = {}
        for _, p in ipairs(reskate.session.skaters()) do positions[p.id] = p.position end
        if not input.barred then
            for _, p in ipairs(reskate.session.players()) do
                if not p.me and not p.server and nz(p.id) then
                    table.insert(input.peers, {id = p.id, name = p.name, position = positions[p.id]})
                end
            end
        end
        input.world = world.world or "0"
        input.in_world = in_world
        input.position = skater
        input.local_name = me and me.name or ""
    else
        -- local_input(source, local_native_player_id(), native_throwdown_world(), position)
        -- PORT: local_native_player_id() (the game's own player number) is not in the API; "1"
        -- stands for it, as core's self_id does. The local name offline (Steam's, or the profile
        -- card's custom name) is not in the API either: it stays empty.
        local native_player = "1"
        local level_generation = world.world or "0"
        input.peers = {}
        input.local_only = true
        input["local"] = native_player
        input.world = nz(native_player) and level_generation or "0"
        input.position = in_world and skater or nil
        -- The map and respawn can temporarily omit the captured skater pose.
        -- World lifetime comes from the loaded level, not that optional sample.
        input.in_world = in_world and nz(native_player) and nz(level_generation)
    end
    return input
end

-- ---- one_up_runtime.h ---------------------------------------------------------------------------
-- View view()
function O.view() return r.published end
-- view().state.match, for the game modes (M.one_up_match()).
function O.match_id()
    local match = r.published.state.match
    return nz(match) and match or "0"
end
-- void queue(std::string_view command)
function O.queue(text)
    if #text <= 128 and #r.commands < 8 then table.insert(r.commands, text) end
end
-- void create_at_spawn(const SpawnRequest& request)
function O.create_at_spawn(request) r.spawn_request = request end

-- What his UI queued (td/ui_oneup.lua now): queue(text) as its verb and words, and
-- create_at_spawn as "create" x y z yaw(degrees) seconds players.
function O.command(verb, args)
    args = args or {}
    if verb == "create" and #args >= 6 then
        local request = SpawnRequest()
        local x, y, z, yaw = tonumber(args[1]), tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
        request.position = vector.create(x or 0 / 0, y or 0 / 0, z or 0 / 0)
        request.facing = SP.from_yaw_degrees(yaw or 0)
        request.seconds = tonumber(args[5]) or 20
        request.players = tonumber(args[6]) or 4
        -- PORT: his SpawnRequest carries the world and local player the native picker placed it
        -- for; the bridge passes neither, so they are the ones this runtime last saw.
        request.world = r.input.world; request["local"] = r.input["local"]
        O.create_at_spawn(request)
        return
    end
    local text = verb
    for _, word in ipairs(args) do text ..= " " .. tostring(word) end
    O.queue(text)
end

-- void receive(PlayerId sender, std::span<const std::uint8_t> bytes): true for a 1-Up message.
function O.receive(sender, bytes)
    if type(bytes) ~= "string" or #bytes == 0 or string.byte(bytes, 1) ~= W.kind_one_up then return false end
    local envelope = W.decode_throwdown(bytes); if not envelope then return true end
    local message = W.decode(envelope.one_up)
    if not message or envelope.leader ~= message.leader or envelope.id ~= bit32.bor(W.low32(message.match), 1) then return true end
    if #r.inbox < 256 then table.insert(r.inbox, {sender = tostring(sender), message = message}) end
    return true
end

local phase_names = MT.phase_names
local function fmt(x) return tostring(x) end -- std::format("{}") of a number or bool

function O.tick(now_value)
    -- PORT: GetTickCount64() is whole milliseconds; the plugin clock is truncated to match.
    local now = math.floor(now_value or reskate.time.now())
    local input = relay_input()
    local before = Token.new(r.selected.match, r.selected.turn, r.selected.active)
    local before_phase = r.selected.phase
    N.prepare_native_lines(nz(input.world) and input.world or "1", input.in_world)
    if nz(r.selected.match) and (input.world ~= r.selected.world or not nz(input["local"]) or not input.in_world or input.barred or local_throwdown_active()) then
        reskate.log(string.format("1-Up ended: world %s -> %s, local %s, loaded %s, barred %s, native activity %s.",
            r.selected.world, input.world, input["local"], fmt(input.in_world), fmt(input.barred), fmt(local_throwdown_active())), "info")
        clear(); r.status = "1-Up ended because the session, map, or eligibility changed."
    end
    r.input = input
    if input.local_name ~= "" and input.local_name ~= "Unknown Player" then r.names[input["local"]] = input.local_name end
    if r.hosted and r.hosted:solo_test() and r.hosted:state().config.max_players ~= 1 and #input.peers ~= 0 then
        clear(); r.status = "Solo test ended because another player joined. Create a normal 1-Up match to play together."
    end
    for _, p in ipairs(input.peers) do
        if p.name ~= "" and p.name ~= "Unknown Player" then r.names[p.id] = p.name end
    end
    if r.hosted then
        local players = State.copy(r.hosted:state()).players
        for _, p in ipairs(players) do
            if p.connected and not present(p.id) then r.hosted:leave(p.id, now); r.inputs[p.id] = nil end
        end
    elseif nz(r.selected.match) and not present(r.selected.leader) then
        r.selected.phase = "cancelled"; r.selected.active = "0"; r.selected.winner = "0"
        r.selected.notice = "The host left. Exit and create a new match."
    end
    for _, item in ipairs(r.inbox) do
        local sender, m = item.sender, item.message
        if not present(sender) or m.world ~= input.world then continue end
        if m.action == "snapshot" then
            if sender ~= m.leader then continue end
            local count = 0
            for _ in pairs(r.offers) do count += 1 end
            if count < 64 or r.offers[sender] ~= nil then
                local offer = r.offers[sender]
                if offer == nil or offer.message.match ~= m.match or m.state.revision > offer.message.state.revision then r.offers[sender] = {message = m, at = now} end
            end
            if not r.hosted and r.selected.match == m.match and W.apply_snapshot(r.selected, m, sender, input.world) then
                r.spot = m.spot; r.facing = SP.copy(m.facing); r.remaining = m.remaining; r.snapshot_at = now
            end
        else apply_input(sender, m, now) end
    end
    r.inbox = {}
    local commands = r.commands; r.commands = {}
    local spawn = r.spawn_request; r.spawn_request = nil
    if spawn then create_selected_spawn(spawn, now) end
    for _, text in ipairs(commands) do command(text, now) end
    -- Publish Start before positioning and arming its countdown.
    if r.hosted then r.selected = State.copy(r.hosted:state()) end
    local token = Token.new(r.selected.match, r.selected.turn, r.selected.active)
    r.markers_restricted = nz(r.selected.match) and running(r.selected) and member(r.selected, input["local"])
    -- Teleport may execute synchronously before the new View is published.
    -- Arm board-start and input locking before requesting the native move.
    r.countdown_input = nz(r.selected.match) and r.selected.phase == "countdown" and
        r.selected.active == input["local"] and member(r.selected, input["local"])
    if nz(r.selected.match) and r.selected.phase == "countdown" and not Token.same(r.placed, token) then
        r.placed = token; r.positioned = false; r.position_until = now + 8000
        if r.selected.active == input["local"] and member(r.selected, input["local"]) then
            -- PORT: teleport_local_skater_transform(spawn_transform(spot, facing)) takes the whole
            -- facing; reskate.skater.teleport takes a heading about world up (the facing's yaw).
            local ok, sent = pcall(reskate.skater.teleport, r.spot, SP.yaw(r.facing))
            if not ok or not sent then r.status = "Starting position unavailable." end
        end
    end
    if r.hosted and r.selected.phase == "countdown" and not r.positioned then
        local at = position(r.selected.active)
        local pending = false
        if r.selected.active == input["local"] then
            local telemetry = reskate.skater.telemetry()
            pending = telemetry ~= nil and telemetry.teleport_pending == true
        end
        if at and distance(at, r.spot) <= 2 and (r.selected.active ~= input["local"] or not pending) then
            r.positioned = true; r.hosted:position_confirmed(token, now)
        elseif now >= r.position_until then r.hosted:cancel("The active skater could not reach the starting spot. Exit and try again.") end
    end
    if r.hosted and (r.selected.phase ~= "countdown" or r.positioned) then r.hosted:tick(now); r.selected = State.copy(r.hosted:state()) end
    -- Feedback can advance to a new countdown during this tick. Hold its
    -- presenters immediately; the next frame will queue the new token's move.
    if r.hosted and r.selected.phase == "countdown" and
        not Token.same(r.placed, Token.new(r.selected.match, r.selected.turn, r.selected.active)) then r.positioned = false end
    local armed = Token.new(r.selected.match, r.selected.turn, r.selected.active)
    if r.selected.phase == "playing" and not Token.same(r.clock_token, armed) then
        r.clock_token = armed
        local left = r.hosted and r.hosted:remaining(now) or r.remaining
        r.turn_at = now - (r.selected.config.turn_ms - math.min(left, r.selected.config.turn_ms))
    end
    local participating = member(r.selected, input["local"])
    N.update_native_scoring_rule(input.world, input.in_world and nz(r.selected.match) and
        r.selected.phase ~= "finished" and r.selected.phase ~= "cancelled" and participating)
    local on_turn = participating and r.selected.active == input["local"] and (r.selected.phase == "playing" or r.selected.phase == "settling")
    local left = r.hosted and r.hosted:remaining(now) or (now - r.snapshot_at < r.remaining and r.remaining - (now - r.snapshot_at) or 0)
    N.arm_native_lines(on_turn and armed or Token.new(), on_turn and r.selected.phase == "playing" and left > 0, r.turn_at)
    for _, event in ipairs(N.take_native_lines()) do
        if on_turn and Token.same(event.token, armed) and event.scored_trick then
            local m = W.Message.new(); m.action = "trick_score"
            m.turn = event.token.turn; m.line = event.line; m.elapsed = event.elapsed; m.score = event.score; m.flag = event.landed
            send_input(m, now)
        end
    end
    local bails = r.bails; r.bails = {}
    for _, item in ipairs(bails) do
        local bail, at = item.token, item.at
        if on_turn and Token.same(bail, armed) and at >= r.turn_at then
            local m = W.Message.new(); m.action = "bail"; m.turn = bail.turn; m.line = 1
            m.elapsed = math.min(at - r.turn_at, r.selected.config.turn_ms)
            send_input(m, now)
        end
    end
    if r.hosted then
        r.selected = State.copy(r.hosted:state())
        if now >= r.next_send then
            r.next_send = now + 250
            local m = W.Message.new(); m.state = State.copy(r.selected); r.wire_revision += 1; m.state.revision = r.wire_revision
            m.match = m.state.match; m.world = m.state.world; m.leader = m.state.leader
            -- Zero holds remote startup presenters until the host confirms arrival.
            m.remaining = (r.selected.phase == "countdown" and not r.positioned) and 0 or r.hosted:remaining(now); m.spot = r.spot; m.facing = SP.copy(r.facing)
            emit(m)
        end
    end
    local showing = nz(r.selected.match) and running(r.selected)
    r.markers_restricted = showing and participating
    r.playing = showing; r.active = showing and r.selected.active or "0"
    -- The active skater waits on the board during countdown. Other skaters
    -- remain off board until their own turn starts.
    r.waiting = showing and r.selected.active ~= input["local"]
    r.countdown_input = showing and participating and r.selected.active == input["local"] and r.selected.phase == "countdown"
    if nz(r.selected.match) then reskate.session.spectate((showing and r.selected.active ~= input["local"]) and r.selected.active or "0") end
    for id, offer in pairs(r.offers) do
        if now - offer.at >= 4000 then r.offers[id] = nil end
    end
    if nz(r.selected.match) and (not Token.same(Token.new(r.selected.match, r.selected.turn, r.selected.active), before) or r.selected.phase ~= before_phase) then
        reskate.log(string.format("1-Up: turn %s %s, target %s, total %s. %s", fmt(r.selected.turn),
            phase_names[MT.phase_number[r.selected.phase] + 1], fmt(r.selected.target), fmt(r.selected.best), r.selected.notice), "info")
    end
    publish(now)
    -- return std::exchange(r.outgoing, {}): his session sent each to every other player.
    local outgoing = r.outgoing; r.outgoing = {}
    if reskate.session.active() then
        for _, payload in ipairs(outgoing) do
            local ok, why = pcall(reskate.net.send, "all", payload)
            if not ok then reskate.log("1-Up: a message was not sent: " .. tostring(why), "warn") end
        end
    end
end

-- void report_bail(Time when) noexcept: the game modes call it when their bail watch sees one.
function O.report_bail(when)
    local view = r.published
    if view.participant and view["local"] == view.state.active and view.state.phase == "playing" and #r.bails < 8 then
        table.insert(r.bails, {token = Token.new(view.state.match, view.state.turn, view["local"]), at = math.floor(when or reskate.time.now())})
    end
end
-- His other exports, from what the last tick set (td/ui_oneup.lua's match document reads them).
function O.waits_offboard() return r.waiting end
function O.countdown_locks_input() return r.countdown_input end
function O.restricts_session_markers() return r.markers_restricted end
function O.hides(id) return r.playing and r.active ~= id end
-- ReSkate: the kit's match document asks for the hidden players as a list (his hides(id) was asked per
-- remote skater): every other player present who is not the one up.
function O.hidden()
    local hidden = {}
    if r.playing then
        for _, p in ipairs(r.input.peers) do
            if p.id ~= r.active then table.insert(hidden, p.id) end
        end
    end
    return hidden
end
-- ReSkate: where the hosted match's flag stands (its spot and facing), for the kit's flags document.
function O.spot() return r.spot, SP.copy(r.facing), r.hosted ~= nil end

return O
