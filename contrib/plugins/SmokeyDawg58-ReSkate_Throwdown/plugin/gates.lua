-- Deathrace's gates and arrows in the world, as SmokeyDawg58's fork spawns them (Extension/Modes/
-- race_world.cpp, race_route.h): each gate is four native entities from this mod's blueprints (the
-- tutorial checkpoint's two arches and its two lightning bolts, blue/yellow, red for the finish,
-- grey for a guide), each arrow two (the chevron's core and its blue glow). Their transforms are his,
-- number for number. Pure but for publish(), which hands them to reskate.entities.
local gates = {}

gates.assets = {
    "World/ReSkate/Deathrace/SM_FX_GP_Checkpoint_A_AT_Gate",
    "World/ReSkate/Deathrace/SM_FX_GP_Checkpoint_A_AL_Gate",
    "World/ReSkate/Deathrace/SM_FX_GP_LightningBolt_A_Gate",
    "World/ReSkate/Deathrace/SM_FX_GP_Checkpoint_A_AT_Finish",
    "World/ReSkate/Deathrace/SM_FX_GP_Checkpoint_A_AL_Finish",
    "World/ReSkate/Deathrace/SM_FX_GP_LightningBolt_A_Finish",
    "World/ReSkate/Deathrace/SM_FX_GP_Checkpoint_A_AT_Guide",
    "World/ReSkate/Deathrace/SM_FX_GP_Checkpoint_A_AL_Guide",
    "World/ReSkate/Deathrace/SM_FX_GP_LightningBolt_A_Guide",
    "World/ReSkate/Deathrace/FloatingArrow_AT",
    "World/ReSkate/Deathrace/FloatingArrow_A",
}

local rad = math.pi / 180

-- race_arrow_transform: the native chevron is an XY quad. Aim supplies yaw and tilt; the D-pad adds
-- roll in that aimed plane.
function gates.arrow_transform(at, heading, roll, half_width, pitch)
    local yaw, r, p = heading * rad, roll * rad, (pitch or 0) * rad
    local co, si, cr, sr, scale = math.cos(yaw), math.sin(yaw), math.cos(r), math.sin(r), 4 * half_width / 6
    local cp, sp = math.cos(p), math.sin(p)
    local right, up, forward = {co, 0, -si}, {si * sp, cp, co * sp}, {si * cp, -sp, co * cp}
    local pose = {}
    for a = 1, 3 do
        pose[a] = (right[a] * cr + up[a] * sr) * scale
        pose[4 + a] = (-right[a] * sr + up[a] * cr) * scale
        pose[8 + a] = forward[a] * scale
        pose[12 + a] = at[a]
    end
    pose[4], pose[8], pose[12], pose[16] = 0, 0, 0, 1
    return pose
end
-- race_arrow_layer_transform: the glow (part 1) a little in front of the core, so depth precision at
-- distance cannot let the core hide its own glow.
function gates.arrow_layer_transform(at, heading, roll, width, pitch, part)
    local pose = gates.arrow_transform(at, heading, roll, width, pitch)
    if part == 1 then
        local length = math.sqrt(pose[9] ^ 2 + pose[10] ^ 2 + pose[11] ^ 2)
        if length > 0.001 then
            for axis = 1, 3 do pose[12 + axis] = pose[12 + axis] + 0.015 * pose[8 + axis] / length end
        end
    end
    return pose
end
-- race_gate_axes: unit axes of a gate at this yaw and tilt.
function gates.axes(yaw, pitch, roll)
    local m = gates.arrow_transform({0, 0, 0}, yaw, roll or 0, 1.5, pitch)
    return {m[1], m[2], m[3]}, {m[5], m[6], m[7]}, {m[9], m[10], m[11]}
end

-- mesh_pose: the exact child transforms of SPF_UI_Checkpoint_Base. One size scales the whole gate,
-- bolts included, about ground level. gate = {at = {x, y, z}, yaw, width (half width), finish,
-- guiding, arrow, roll, pitch}; part 0..3 (0..1 for an arrow).
local sx, sy = {7, 7, -2.12332, 2.13802}, {7, 7, 2.12332, 2.13802}
local right_y, up_x = {0, 0, -0.286054, 0.0179417}, {0, 0, -0.286054, -0.0179417}
local px, py, pz = {0, 0, -1.67701, 1.70283}, {1.70747, 1.70747, 4.31834, 4.34544}, {0.00849477, 0, 0.1, 0.1}
function gates.mesh_pose(gate, part)
    if gate.arrow then return gates.arrow_layer_transform(gate.at, gate.yaw, gate.roll or 0, gate.width, gate.pitch or 0, part) end
    local i = part + 1
    local yaw = gate.yaw * rad
    local co, si, width, scale = math.cos(yaw), math.sin(yaw), gate.width * 2 / 7, gate.width / 6
    local a, bb, c, d = sx[i] * width, right_y[i] * scale, up_x[i] * width, sy[i] * scale
    local depth = (part < 2 and 7 or part == 2 and 2.1425 or 2.1381) * scale
    local at = gate.at
    if (gate.pitch or 0) ~= 0 then
        local right, up, forward = gates.axes(gate.yaw, gate.pitch)
        local m = {}
        for axis = 1, 3 do
            m[axis] = right[axis] * a + up[axis] * bb
            m[4 + axis] = right[axis] * c + up[axis] * d
            m[8 + axis] = forward[axis] * depth
            m[12 + axis] = at[axis] + right[axis] * px[i] * width + up[axis] * py[i] * scale + forward[axis] * pz[i] * scale
        end
        m[4], m[8], m[12], m[16] = 0, 0, 0, 1
        return m
    end
    return {co * a, bb, -si * a, 0, co * c, d, -si * c, 0, si * depth, 0, co * depth, 0,
        at[1] + co * px[i] * width + si * pz[i] * scale, at[2] + py[i] * scale, at[3] - si * px[i] * width + co * pz[i] * scale, 1}
end
-- Which blueprint a gate's part is: arch, inner arch, then the bolt twice; finish and guide sets
-- after the gate's; an arrow's core and glow last.
function gates.asset_of(gate, part)
    if gate.arrow then return gates.assets[10 + part] end
    local first = gate.finish and 4 or gate.guiding and 7 or 1
    return gates.assets[first + math.min(part, 2)]
end
function gates.parts(gate) return gate.hidden and 0 or gate.arrow and 2 or 4 end

-- Every gate of the list in the world, under entity ids from `base` (8 per gate); the gates that are
-- no longer there are taken away. `shown` remembers what was published between calls.
function gates.publish(shown, base, list)
    shown.count = shown.count or 0
    shown.poses = shown.poses or {}
    for g, gate in ipairs(list) do
        for part = 0, 3 do
            local id = base + (g - 1) * 8 + part
            if part < gates.parts(gate) then
                local asset, pose = gates.asset_of(gate, part), gates.mesh_pose(gate, part)
                local key = asset .. table.concat(pose, ",")
                if shown.poses[id] ~= key then
                    shown.poses[id] = key
                    local ok, why = reskate.entities.set(id, asset, {matrix = pose})
                    if not ok then reskate.log("Deathrace: a gate could not be placed: " .. tostring(why)) end
                end
            elseif shown.poses[id] then
                shown.poses[id] = nil
                reskate.entities.remove(id)
            end
        end
    end
    for g = #list + 1, shown.count do
        for part = 0, 3 do
            local id = base + (g - 1) * 8 + part
            if shown.poses[id] then
                shown.poses[id] = nil
                reskate.entities.remove(id)
            end
        end
    end
    shown.count = #list
end
function gates.clear(shown, base)
    gates.publish(shown, base, {})
end

return gates
