-- SmokeyDawg58's one_up_native.h / one_up_native.cpp: the local player's own lines and landed
-- tricks, for 1-Up's scoring. His C++ binds the game's scripting graphs in memory (LineEnd,
-- SequenceEnd payloads) and switches the game's DisableLineMultiplierRule on while 1-Up runs.
-- A plugin reaches neither: the same events come from the plugin API's trick feed
-- (trick_started, trick_landed, line_broken, read from the score HUD), and every place that
-- differs says so in a PORT note. The state machine (armed, running, line numbers, the events
-- and their limits) is his, unchanged.
local MT = require("td/oneup/match")
local N = {}

local nz = MT.nz
-- PORT: his logging::Level::debug lines; reskate.log has no debug level, so they are off unless this is set.
local debug_log = false

local function now_ms() return math.floor(reskate.time.now()) end

-- struct NativeLine { Token token; std::uint64_t line; double score; std::uint32_t elapsed; bool ended, landed, scored_trick; };
local function NativeLine(token, line, score, elapsed, ended, landed, scored_trick)
    return {token = token, line = line, score = score, elapsed = elapsed,
        ended = ended or false, landed = landed or false, scored_trick = scored_trick or false}
end
-- struct Capture { Token token; bool starts{}; Time at{}; };
local function Capture() return {token = MT.Token.new(), starts = false, at = 0} end
local function copy_capture(c) return {token = MT.Token.new(c.token.match, c.token.turn, c.token.player), starts = c.starts, at = c.at} end

local r = {
    world = "0",
    ready = false, scanning = false,
    multiplier_disabled = false,
    next_scan = 0, next_line = 0,
    end_failures = 0,
    binding = false, -- PORT: his Binding (graph types and field offsets); here only whether the score HUD is readable
    armed = Capture(), running = Capture(),
    line = 0,
    events = {},
}
-- struct ScoringRule { manager, world, retry, report, originals }
local rule = {world = "0", retry = 0, report = 0}

function N.prepare_native_lines(world, in_world)
    local wanted = in_world and world or "0"
    local previous = r.world
    r.world = wanted
    if previous ~= wanted then
        r.ready = false; r.binding = false; r.running = Capture(); r.armed = Capture(); r.line = 0; r.events = {}; r.next_scan = 0
    end
    if not nz(wanted) or r.ready or now_ms() < r.next_scan or r.scanning then return end
    r.scanning = true
    r.next_scan = now_ms() + 2000
    -- PORT: his find_native_types scan on a thread (the LineEnd, Line, SequenceEnd and Sequence types
    -- and their fields) becomes: the score HUD the trick feed reads is there.
    local ok, score = pcall(reskate.score.current)
    if ok and score ~= nil and r.world == wanted then
        r.binding = true; r.ready = true
        reskate.log("1-Up: native finalized line scoring bound (the score HUD's line score).", "info")
        reskate.log("1-Up: native landed trick scoring bound (the trick feed's landed tricks).", "info")
    end
    r.scanning = false
end
function N.native_lines_available() return r.ready end

-- Client-thread only. Uses the game's DisableLineMultiplierRule setting;
-- restores its previous value when 1-Up ends or the world changes.
function N.update_native_scoring_rule(world, active)
    -- PORT: he writes the game's DisableLineMultiplierRule (and a second multiplier flag) into the
    -- active scoring model's settings while a participant's match runs, restoring the originals after.
    -- The plugin API has no way to change it (reskate.settings.game only reads). The rule stays the
    -- game's; trick_landed's points are divided by their multiplier instead (observe_trick_landed),
    -- which is the unscaled rise the multiplier rule would have left. multiplier_disabled stands for
    -- "the rule would be bound": true exactly while he would have it on.
    if rule.world ~= world or not active then
        rule.world = world
        r.multiplier_disabled = false; rule.retry = 0
        if not active then return end
    end
    local was = r.multiplier_disabled
    r.multiplier_disabled = true
    if not was then
        reskate.log("1-Up: native line and stale multipliers disabled; skating sequence points are used directly.", "info")
    end
end

function N.arm_native_lines(token, starts, at)
    r.armed = {token = MT.Token.new(token.match, token.turn, token.player), starts = starts, at = at}
    if not MT.Token.same(r.running.token, token) then r.running = Capture(); r.line = 0 end
end

-- graph == start_graph: the native line started (trick_started; his graph runs once a line, and
-- `if (r.line) return;` keeps the later tricks of a running line out, as here).
function N.observe_line_start()
    if not r.ready then return end
    local now = now_ms()
    if debug_log then reskate.log("1-Up native line start.", "info") end
    if r.line ~= 0 then return end
    r.running = Capture(); r.line = 0
    if nz(r.armed.token.match) and r.armed.starts and now >= r.armed.at and now - r.armed.at <= 120000 then
        r.running = copy_capture(r.armed); r.next_line += 1; r.line = r.next_line
        if #r.events < 128 then
            table.insert(r.events, NativeLine(r.running.token, r.line, 0, now - r.running.at, false, false))
        end
    end
end

-- graph == sequence_end_graph: a scored sequence ended. `points` and `multiplier` are trick_landed's.
function N.observe_trick_landed(points, multiplier)
    if not r.ready then return end
    local now = now_ms()
    -- PORT: he reads WasSuccess and the sequence's kind and trick categories
    -- (skating_sequence(kind, skating_trick_category(...)), one_up_skating_score.h): Roll and trickless
    -- air count, bonus/challenge actions, flumping and wipeouts do not. trick_landed is a landed rise
    -- of the HUD's line score after a trick: landed is true, and every such trick is taken as eligible.
    local landed = true
    local eligible = true
    -- PORT: his SequenceScore is the landed trick's base points, read as an integer with the
    -- multiplier rule on. trick_landed's points are at the multiplier the trick raised the line to:
    -- divided back to the unscaled rise and rounded to whole points.
    local score = points or 0
    if multiplier ~= nil and multiplier > 0.01 then score = score / multiplier end
    score = math.floor(score + 0.5)
    if not MT.finite(score) or score < 0 or score > 2147483647.0 then return end
    if debug_log then
        reskate.log(string.format("1-Up native trick scored: points %s, multiplier %s, skating %s, landed %s, armed %s.",
            tostring(score), tostring(multiplier), tostring(eligible), tostring(landed), tostring(r.armed.starts)), "info")
    end
    -- DisableLineMultiplierRule makes this the landed trick's base
    -- points. Preserve prior landed tricks after a later bail and do
    -- not wait for the line or multiplier UI to finish.
    if eligible and landed and score > 0 and r.multiplier_disabled and nz(r.armed.token.match) and r.armed.starts and
        now >= r.armed.at and now - r.armed.at < 120000 and #r.events < 128 then
        r.next_line += 1
        table.insert(r.events, NativeLine(r.armed.token, r.next_line, score, now - r.armed.at, true, true, true))
    end
end

-- end_graph / stats_end_graph: the native line finalized with `reason` (1 timer, 6 stall: landed).
-- PORT: the plugin API tells of a line ending only when it breaks (line_broken: a slam or a
-- wipeout), which is never reason 1 or 6, so `landed` is false here; a line that ends by its own
-- timer or stall has no event and is not observed. The runtime takes only scored_trick events, so
-- this changes no score; it keeps his line bookkeeping.
function N.observe_line_end(line_score, landed)
    if not r.ready then return end
    local now = now_ms()
    local score = line_score or 0
    if not MT.finite(score) or score < 0 or score > 2147483647.0 then
        if r.end_failures < 8 and debug_log then
            reskate.log(string.format("1-Up native end payload rejected: score %s.", tostring(score)), "info")
        end
        r.end_failures += 1
        return
    end
    if debug_log then reskate.log(string.format("1-Up native line finalized: score %s, eligible %s.", tostring(score), tostring(landed)), "info") end
    if r.line ~= 0 and MT.Token.same(r.running.token, r.armed.token) and now >= r.running.at and now - r.running.at <= 125000 and #r.events < 128 then
        table.insert(r.events, NativeLine(r.running.token, r.line, score, now - r.running.at, true, landed))
    end
    r.running = Capture(); r.line = 0
end

function N.take_native_lines()
    local out = r.events
    r.events = {}
    return out
end

-- His expression hooks call observe_native_line before the game's graph consumes its input; the
-- plugin's trick feed stands in for them.
reskate.on("trick_started", function() N.observe_line_start() end)
reskate.on("trick_landed", function(trick)
    N.observe_trick_landed(trick and trick.points or 0, trick and trick.multiplier)
end)
reskate.on("line_broken", function()
    local ok, score = pcall(reskate.score.current)
    N.observe_line_end(ok and score and score.line or 0, false)
end)

return N
