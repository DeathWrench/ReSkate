local M = require("td/core")
-- race_world.cpp: the native objects of the current NativeView. Deathrace's gates (four meshes of
-- the tutorial checkpoint each, two for an arrow), R.E.S.K.A.T.E.'s zone cones and its beacon.
-- His native calls (create bus, descriptor, CreateEntity, InitializePlacement, MoveSpatialEntity,
-- DestroyEntity, the parent bus, the blueprint type checks, the creation scope) are ReSkate's
-- reskate.entities now (Extension/World/world_entities.cpp): this file decides which objects exist,
-- where and from which blueprint, line for line, and hands them over by id.
--
-- PORT: an entity here is the object this file `set` in reskate.entities ({id, asset, group, part}),
-- not a native pointer. Whether it exists in the world is reskate.entities.status(id) == "ready"
-- (all of ours: reskate.entities.ready()). A set on an id already set moves the object in place
-- (the C++ moves it at most every 16 ms, or recreates it when the blueprint differs); a remove
-- destroys it. Ids are numbers (the API takes whole numbers, not strings): a gate's part
-- 1 + group * 4 + part, a cone 1001 + group, the beacon 2001.
local RR = require("td/h/race_route")
local RAC = require("td/h/race_asset_contract")
local RGR = require("td/h/race_group_reconciliation")
local gates = require("gates") -- his checkpoint_names (gates.assets) and mesh_pose, number for number

local pi = 3.14159265

local gate_id_base, cone_id_base, beacon_id = 1, 1001, 2001

-- State (the file's own, as his State in race_world.cpp's anonymous namespace).
local W = {
    lifetime = RAC.CheckpointWorldLifetime.new(),
    entities = {}, -- {id, asset, group, part}
    gates = {},
    -- PORT: assets / asset_domains (the 11 resolved blueprint pointers) are the API's.
    retry = 0, preview_at = 0,
    world = "0", game = 0, ready_game = 0, ready_world = "0",
    route_ready = false, error = "", waiting = "",
    dirty = {},
    -- R.E.S.K.A.T.E.'s trick zone: skate.'s own traffic cone around the circle's edge.
    -- PORT: cone (a pointer) is true once a name is chosen; cone_name is his 0-based index.
    cone = false, cone_name = 0, cone_points = {},
    -- Which name to try next and whether the chosen one was seen in the world (see tick_zone).
    cone_try = 0, cone_confirmed = false,
    -- And a beacon over its middle, seen from afar: Deathrace's lightning bolt, high up and turning.
    bolt = false, bolt_retry = 0, bolt_moved = 0,
}

-- R.E.S.K.A.T.E.'s zone cones: a copy packed with the Throwdown assets first (resident everywhere),
-- else skate.'s own traffic cone wherever its world content has it loaded, else (custom maps,
-- which do not load it) the Throwdown pack's grey Deathrace guide bolt, which every map has.
local cone_names = {
    "World/ReSkate/Throwdowns/TrafficCone",
    "World/Props/Common/Construction/CMN_PRP_TrafficCone_01/CMN_PRP_TrafficCone_01",
    "World/ReSkate/Deathrace/SM_FX_GP_LightningBolt_A_Guide",
}

local function waiting(issue)
    if W.waiting == issue then return end
    W.waiting = issue
    -- PORT: logging::Level::debug; plugins log at info, warn or error.
    reskate.log("Native world objects (Deathrace gates, R.E.S.K.A.T.E. cones): " .. W.waiting, "info")
end

-- PORT: load_assets / assets_resident (lines 83-105) look the 11 blueprints up in every loaded
-- domain and re-validate them by pointer; reskate.entities does both per blueprint name (at most
-- once a second, as his retry), and a blueprint that streams out takes its objects with it until it
-- resolves again.
-- PORT: parent_bus (lines 106-115, race_source_contract.h) is the API's object_parent_bus.

local function set(id, asset, matrix)
    local ok, why = reskate.entities.set(id, asset, {matrix = matrix}, false)
    if not ok then error(why, 0) end
end

-- create(): his throws when the bus or the entity cannot be made; here when the API refuses.
local function create(asset, matrix, group, part, id)
    set(id, asset, matrix)
    -- One object per id in the API: a record for the same id is replaced, not counted twice.
    for k = #W.entities, 1, -1 do
        if W.entities[k].id == id then table.remove(W.entities, k) end
    end
    table.insert(W.entities, {id = id, asset = asset, group = group, part = part})
end

-- move_spatial_entity: the object keeps its blueprint and takes the new transform.
local function move(entity, matrix)
    set(entity.id, entity.asset, matrix)
end

-- mesh_pose(gate, part): gates.lua's, which takes the position as a list.
local function mesh_pose(gate, part)
    return gates.mesh_pose({at = {gate.at.x, gate.at.y, gate.at.z}, yaw = gate.yaw, width = gate.width, finish = gate.finish,
        guiding = gate.guiding, arrow = gate.arrow, roll = gate.roll, pitch = gate.pitch, hidden = gate.hidden}, part)
end

local function gate_equal(a, b)
    return a.at == b.at and a.yaw == b.yaw and a.width == b.width and a.finish == b.finish and a.guiding == b.guiding and
        a.arrow == b.arrow and a.roll == b.roll and a.pitch == b.pitch and a.hidden == b.hidden
end
local function gates_equal(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if not gate_equal(a[i], b[i]) then return false end
    end
    return true
end
local function lists_equal(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function clear()
    local old = W.entities
    W.entities = {}
    W.gates = {}
    W.dirty = {}
    W.route_ready = false
    -- PORT: his destroys only entities still owned as created (context and owner unchanged); the
    -- API makes that check itself when it takes an object away.
    for _, e0 in old do reskate.entities.remove(e0.id) end
end
local function clear_group(group)
    local old = {}
    for _, entity in W.entities do
        if entity.group == group then table.insert(old, entity) end
    end
    for k = #W.entities, 1, -1 do
        if W.entities[k].group == group then table.remove(W.entities, k) end
    end
    for _, entity in old do reskate.entities.remove(entity.id) end
end

-- The zone's edge, every 4 m or so (8 to 48 cones), at the height of its centre: the placed area,
-- or while one is being placed, the circle under the cursor (moving with it, as Deathrace's gate).
local function zone_ring(view)
    local points = {}
    local st = view.settings
    -- A custom zone: a cone at each corner placed, and along its edges every 4 m (closed once it has
    -- three corners); while placing, one more under the cursor.
    if st.area_radius <= 0 and (view.zone_custom or view.placing_corners) then
        -- While placing: the placed cones' edges only (open), and one cone where the next would go.
        -- Filling the edges to the aim point too trailed lines of cones after the camera.
        local corners = st.corners
        if view.placing_corners and view.cursor_valid then table.insert(points, view.cursor) end
        for i = 0, #corners - 1 do
            if #points >= 48 then break end
            local a = corners[i + 1]
            table.insert(points, a)
            local closing = i + 1 == #corners
            if closing and (#corners < 3 or view.placing_corners) then break end
            local b = corners[(if closing then 0 else i + 1) + 1]
            local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
            local length = math.sqrt(dx * dx + dz * dz)
            local between = M.trunc(length / 4)
            for k = 1, between - 1 do
                if #points >= 48 then break end
                local f = k / between
                table.insert(points, vector.create(a.x + dx * f, a.y + dy * f, a.z + dz * f))
            end
        end
        return points
    end
    local preview = view.placing_circle and view.cursor_valid
    if not preview and (st.area_radius <= 0 or #st.corners == 0) then return points end
    local centre = if preview then view.cursor else st.corners[1]
    local radius = if preview then view.draft_radius else st.area_radius
    -- PORT: static_cast<unsigned> of a negative draft radius wraps (48 cones); here it clamps to 8.
    local count = math.clamp(M.trunc(2 * pi * radius / 4), 8, 48)
    for i = 0, count - 1 do
        local angle = 2 * pi * i / count
        table.insert(points, vector.create(centre.x + radius * math.cos(angle), centre.y, centre.z + radius * math.sin(angle)))
    end
    return points
end

local beacon_group = 900 -- apart from the cones (0..47)
local bolt_name = "World/ReSkate/Deathrace/SM_FX_GP_LightningBolt_A_Gate"
-- The beacon's place: a finished zone's middle (none while its cones are being placed).
local function zone_beacon(view)
    local st = view.settings
    if view.placing_corners or view.placing_circle then return nil end
    if st.area_radius > 0 and #st.corners > 0 then return st.corners[1] end
    if view.zone_custom and #st.corners >= 3 then return M.area_centre(st.corners) end
    return nil
end

local function tick_beacon(view, now)
    -- PORT: checkpoint_resident(s.bolt, find(...)): the API's "missing" for the beacon's object.
    if W.bolt and reskate.entities.status(beacon_id) == "missing" then
        clear_group(beacon_group)
        W.bolt = false
    end
    local at = zone_beacon(view)
    local live = nil
    for _, entity in W.entities do
        if entity.group == beacon_group then live = entity end
    end
    if not at then
        if live then clear_group(beacon_group) end
        return
    end
    if not W.bolt then
        if now < W.bolt_retry then return end
        W.bolt_retry = now + 2000
        -- PORT: the search of every loaded domain for bolt_name is the API's, once the object is
        -- set; a bolt it cannot find shows as "missing" above and is looked for again 2 s later.
        W.bolt = true
    end
    if now < W.bolt_moved + 16 then return end
    W.bolt_moved = now
    -- Eight metres up, four times a gate bolt's size, a turn every six seconds.
    local size = 4
    local yaw = (now % 6000) / 6000 * 2 * pi
    local co, si = math.cos(yaw), math.sin(yaw)
    local matrix = {co * size, 0, -si * size, 0, 0, size, 0, 0, si * size, 0, co * size, 0, at.x, at.y + 8, at.z, 1}
    if live then
        -- PORT: his intact check (context, owner, spatial collection) is the API's; an object it
        -- lost is made again from the same set.
        move(live, matrix)
        return
    end
    create(bolt_name, matrix, beacon_group, 0, beacon_id)
end

-- The first cone object of the chosen name, if any is set.
local function cone_status()
    local name = cone_names[W.cone_name + 1]
    for _, entity in W.entities do
        if entity.group ~= beacon_group and entity.asset == name then return reskate.entities.status(entity.id) end
    end
    return nil
end

local function tick_zone(view, now)
    tick_beacon(view, now)
    -- PORT: checkpoint_resident(s.cone, ...) and the search below (lines 256-270) test each name in
    -- every loaded domain; a plugin can only set objects of a name and read their status. So a name
    -- is chosen in his order of preference and its cones set; when the API reports it "missing"
    -- the next name is chosen. A name seen in the world that later streams out starts the search
    -- again from the first, as his does.
    local status = if W.cone then cone_status() else nil
    if W.cone and status == "missing" then
        local failed, confirmed = W.cone_name, W.cone_confirmed
        clear()
        W.cone = false
        W.cone_points = {}
        W.cone_confirmed = false
        if confirmed then
            W.cone_try = 0
        else
            W.cone_try = failed + 1
            if W.cone_try < #cone_names then
                W.retry = 0 -- his search goes on to the next name at once
            else
                W.cone_try = 0
                waiting("no traffic cone or guide bolt is loaded in this part of the world; the zone shows on the HUD only")
            end
        end
    elseif W.cone and status == "ready" and not W.cone_confirmed then
        W.cone_confirmed = true
        reskate.log(string.format("R.E.S.K.A.T.E. zone: cones from %s.", cone_names[W.cone_name + 1]), "info")
    end
    if not W.cone then
        if now < W.retry then return end
        W.retry = now + 2000
        -- In order of preference, each looked for in every loaded domain before the next.
        W.cone = true
        W.cone_name = W.cone_try
    end
    local points = zone_ring(view)
    -- A cone stands on the ground. The guide bolt (custom maps) is centred on its own pivot, as the
    -- gates lift theirs: one and a half times its size, floating clear of the ground, not half in it.
    local bolt = W.cone_name == #cone_names - 1
    local function pose(at)
        local size, lift = 1.5, 1.2
        return if bolt
            then {size, 0, 0, 0, 0, size, 0, 0, 0, 0, size, 0, at.x, at.y + lift, at.z, 1}
            else {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, at.x, at.y, at.z, 1}
    end
    local live = {}
    for _, entity in W.entities do
        if entity.group ~= beacon_group then table.insert(live, entity) end
    end
    if lists_equal(points, W.cone_points) and #live == #points then return end
    if now < W.preview_at then return end
    W.preview_at = now + 16
    -- The same number of cones: move them (recreating every frame made Deathrace's preview jump).
    -- PORT: his all_of(intact) is the API's own check before it moves an object.
    if #live == #points and #W.cone_points == #points then
        for _, entity in live do
            if entity.group >= #points then continue end
            move(entity, pose(points[entity.group + 1]))
        end
        W.cone_points = points
        return
    end
    -- PORT: parent_bus / "waiting for the native local skater entity bus": the API waits for it.
    local groups = {}
    for _, entity in live do groups[entity.group] = true end
    for _, group in M.sorted_keys(groups) do clear_group(group) end -- the cones only: the beacon stays
    local name = cone_names[W.cone_name + 1]
    for i = 0, #points - 1 do
        create(name, pose(points[i + 1]), i, 0, cone_id_base + i)
    end
    W.cone_points = points
    if #points > 0 then waiting(string.format("%d zone cones placed", #points)) end
end

-- PORT: entity_destroyed (lines 307-311) marks a group dirty when the game destroys one of its
-- entities. The API hears that callback and makes the object again from the same set, so nothing
-- reaches the Lua and W.dirty is only ever emptied here; start_error asks the API instead.

function M.race_world_start_error(world, game)
    return if W.route_ready and W.ready_world == world and W.ready_game == game and reskate.entities.ready()
        then ""
        else "Native checkpoint objects are still loading. Wait a moment before starting; check the runtime log if they remain invisible."
end

local function tick(view, now)
    if W.lifetime:blocked() or (view.active and not W.lifetime:can_publish(view.game)) then return end
    local st = view.settings
    local results = view.state ~= nil and view.state.phase == "results"
    local active = view.active and st.mode == "race" and not results
    -- R.E.S.K.A.T.E.'s trick zone, when its leader placed one: cones on its edge.
    local zone = view.active and st.mode == "skate" and not results and
        ((st.area_radius > 0 and #st.corners > 0) or (view.placing_circle and view.cursor_valid) or
         (view.zone_custom and (#st.corners > 0 or (view.placing_corners and view.cursor_valid))))
    W.route_ready = false
    -- PORT: a new client context (line 331) took the native entities with it; the API keeps our
    -- objects then and makes them again. What the API drops (a level change) is the closest
    -- equivalent: our objects are no longer known to it, so forget them as he does.
    if #W.entities > 0 and reskate.entities.status(W.entities[1].id) == nil then
        W.entities = {}
        W.gates = {}
        W.dirty = {}
        W.cone = false
        W.bolt = false
        W.cone_points = {}
        W.bolt_retry, W.bolt_moved = 0, 0
    end
    -- PORT: `if(!ready || !context)` (client world readiness, line 332) is the API's tick gate.
    -- Releasing a route is independent of the native creation gate. That
    -- gate can be closed after Leave even while these entities still live.
    if not active and not zone then
        local tracked = #W.entities > 0
        if tracked or #W.gates > 0 then clear() end
        W.cone_points = {}
        W.waiting = ""
        return
    end
    -- PORT: the TLS creation scope check (lines 340-345) and the ABI prefix verification with the
    -- entity lifetime hooks (lines 348-356) are the API's.
    if W.world ~= view.world or W.game ~= view.game then
        clear()
        W.cone = false
        W.bolt = false
        W.cone_points = {}
        W.bolt_retry, W.bolt_moved = 0, 0
        W.world = view.world
        W.game = view.game
        W.error = ""
    end
    if zone then
        tick_zone(view, now)
        return
    end
    -- PORT: lines 358-369 wait, before any gate exists, until all 11 blueprints resolve (retrying
    -- each second) and say how many have. The API resolves each blueprint when an object of it is
    -- set, so the gates are set at once and each shows when its blueprint resolves; the count
    -- below is of the blueprints in use whose objects stand in the world.
    if now >= W.retry and #W.entities > 0 then
        W.retry = now + 1000
        local seen, loaded, total = {}, 0, 0
        for _, entity in W.entities do
            if seen[entity.asset] == nil then
                seen[entity.asset] = false
                total += 1
            end
            if not seen[entity.asset] and reskate.entities.status(entity.id) == "ready" then
                seen[entity.asset] = true
                loaded += 1
            end
        end
        if loaded < total then waiting(string.format("waiting for route blueprints (%d/%d loaded)", loaded, total)) end
    end
    local list = {}
    -- Start uses the real flag picker. World checkpoint meshes begin at
    -- index 1, preserving the separately stored start position and yaw.
    local yaws, rolls, pitches = st.yaws or {}, st.arrow_rolls or {}, st.gate_pitches or {}
    for i = 1, #st.points - 1 do
        table.insert(list, {
            at = st.points[i + 1],
            yaw = if i < #yaws then yaws[i + 1] else 0,
            width = M.gate_half_width(st, i),
            finish = i + 1 == #st.points and view.route_finish == true,
            guiding = M.guiding_gate(st, i) == true,
            arrow = M.arrow_marker(st, i) == true,
            roll = if i < #rolls then rolls[i + 1] else 0,
            pitch = if i < #pitches then pitches[i + 1] else 0,
            hidden = false,
        })
    end
    local racing = view.state ~= nil and view.state.phase == "playing"
    for i = 0, #list - 1 do
        list[i + 1].hidden = not RR.race_gate_visible(st, i + 1, view.gates_visible_from, racing)
    end
    if view.placing and view.cursor_valid and view.route_object ~= 0 then
        table.insert(list, {at = view.cursor, yaw = view.cursor_yaw, width = view.cursor_width, finish = view.route_object == 2,
            guiding = view.route_object == 3, arrow = view.route_object == 4, roll = view.cursor_roll, pitch = view.cursor_pitch,
            hidden = false})
    end
    if #list == 0 then waiting(if view.placing then "waiting for a valid placement surface" else "waiting for route gates") end
    local live_parts = table.create(#list, 0)
    local expected_parts, expected_total = {}, 0
    for _, gate in list do
        local parts = gates.parts(gate)
        table.insert(expected_parts, parts)
        expected_total += parts
    end
    for _, entity in W.entities do
        if entity.group < #live_parts then live_parts[entity.group + 1] += 1 end
    end
    local dirty = RGR.pending_checkpoint_groups(W.dirty, live_parts, expected_parts)
    local function publish_ready()
        W.ready_world = view.world
        W.ready_game = view.game
        -- PORT: his entities are native and live; ours are set, and the API says whether every one
        -- of them stands in the world.
        W.route_ready = not view.placing and view.route_finish == true and #list >= 2 and #W.entities == expected_total and
            next(W.dirty) == nil and lists_equal(live_parts, expected_parts) and reskate.entities.ready()
    end
    if gates_equal(list, W.gates) and next(dirty) == nil then
        publish_ready()
        return
    end
    if now < W.preview_at then return end
    W.preview_at = now + 16
    -- PORT: parent_bus / "waiting for the native local skater entity bus": the API waits for it.
    table.clear(live_parts)
    for i = 1, #list do live_parts[i] = 0 end
    for _, entity in W.entities do
        if entity.group < #live_parts then live_parts[entity.group + 1] += 1 end
    end
    dirty = RGR.take_checkpoint_groups(W.dirty, live_parts, expected_parts)
    local created_groups = 0
    for i = 0, math.max(#list, #W.gates) - 1 do
        local gate, old = list[i + 1], W.gates[i + 1]
        if gate and old and gate_equal(gate, old) and not dirty[i] then continue end
        -- Move a resident arch in place. Recreating all four meshes five
        -- times a second caused the preview to jump and restart its FX.
        if gate and old and gate.finish == old.finish and gate.guiding == old.guiding and gate.arrow == old.arrow and
            gate.hidden == old.hidden and not dirty[i] then
            local group = {}
            for _, entity in W.entities do
                if entity.group == i then table.insert(group, entity) end
            end
            -- PORT: and every one intact (context, owner, spatial collection): the API's check.
            if #group == expected_parts[i + 1] then
                for _, entity in group do move(entity, mesh_pose(gate, entity.part)) end
                continue
            end
        end
        if gate and created_groups >= 16 then continue end -- Spread a long route across client frames.
        clear_group(i)
        if gate then created_groups += 1 end
        if gate then
            for part = 0, expected_parts[i + 1] - 1 do
                create(gates.asset_of(gate, part), mesh_pose(gate, part), i, part, gate_id_base + i * 4 + part)
            end
        end
    end
    for i = 1, #live_parts do live_parts[i] = 0 end
    for _, entity in W.entities do
        if entity.group < #live_parts then live_parts[entity.group + 1] += 1 end
    end
    W.gates = list
    publish_ready()
    if #list > 0 then waiting("native checkpoint entities created") end
end

function M.world_tick(s, now)
    local view = s.native
    if not view then return end
    local ok, err = pcall(tick, view, now)
    if not ok then
        if type(err) ~= "string" then
            reskate.log("Deathrace object creation failed.", "error")
        elseif W.error ~= err then
            W.error = err
            reskate.log("Deathrace objects: " .. W.error, "error")
        end
    end
end

-- His state reset, as before_level_transition and leaving do it.
local function reset()
    W.entities = {}
    W.gates = {}
    W.dirty = {}
    W.world, W.game, W.ready_world, W.ready_game = "0", 0, "0", 0
    W.route_ready = false
    W.retry = 0
    W.cone = false
    W.bolt = false
    W.cone_points = {}
    W.bolt_retry, W.bolt_moved = 0, 0
    W.cone_try, W.cone_confirmed = 0, false
end

-- Leaving or unloading: every object of this file taken away.
function M.world_clear()
    local ok = pcall(clear)
    if not ok then reskate.log("Deathrace gate cleanup failed.", "error") end
    reset()
    W.waiting = ""
end

-- before_level_transition(base, next). PORT: plugins hear no native state numbers, only
-- level_unloading (a world left: his 14) and level_loaded (a level entered: his 13); the shutdown
-- (24) never reaches a plugin, and the API clears its own objects at a level change regardless.
function M.race_world_before_level_transition(next)
    local release = W.lifetime:before_transition(next, W.game)
    if not release then return end
    -- Retire in the live world before its component data disappears. Saved
    -- courses live in game_modes and remain intact.
    local ok = pcall(clear)
    if not ok then reskate.log("Deathrace pre-transition gate cleanup failed.", "error") end
    reset()
    reskate.log(string.format("Deathrace gate ownership retired before native state %d.", next), "info")
end

reskate.on("level_unloading", function() M.race_world_before_level_transition(14) end)
reskate.on("level_loaded", function() M.race_world_before_level_transition(13) end)
-- PORT: his lifetime opens on the first level entry; the plugin may load inside a level already.
if reskate.level.current() ~= nil then W.lifetime:before_transition(13, 0) end

return nil
