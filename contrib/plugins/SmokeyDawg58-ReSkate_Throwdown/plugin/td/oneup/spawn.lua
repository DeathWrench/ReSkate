-- SmokeyDawg58's one_up_spawn.h. Facing is his std::array<float,9> (rows right, up, forward) as a
-- 1-based list: his facing[i] is facing[i + 1] here. Transforms are 16-number lists the same way.
local SP = {}

local function f32(x) return (string.unpack("<f", string.pack("<f", x))) end
local function finite(x) return x == x and x ~= math.huge and x ~= -math.huge end

SP.default_facing = {1, 0, 0, 0, 1, 0, 0, 0, 1}
function SP.copy(facing) return table.clone(facing) end

function SP.valid_facing(facing)
    if #facing ~= 9 then return false end
    for _, n in ipairs(facing) do
        if not finite(n) or math.abs(n) > 1.01 then return false end
    end
    for row = 0, 2 do
        local length = 0
        for i = 0, 2 do length += facing[row * 3 + i + 1] * facing[row * 3 + i + 1] end
        if math.abs(length - 1) > .03 then return false end
        for other = 0, row - 1 do
            local dot = 0
            for i = 0, 2 do dot += facing[row * 3 + i + 1] * facing[other * 3 + i + 1] end
            if math.abs(dot) > .03 then return false end
        end
    end
    local f = facing
    local determinant = f[1] * (f[5] * f[9] - f[6] * f[8]) -
        f[2] * (f[4] * f[9] - f[6] * f[7]) + f[3] * (f[4] * f[8] - f[5] * f[7])
    return determinant > .97
end
function SP.spawn_transform(position, facing)
    local f = facing
    return {f[1], f[2], f[3], 0, f[4], f[5], f[6], 0,
        f[7], f[8], f[9], 0, position.x, position.y, position.z, 1}
end
function SP.transform_facing(t)
    return {t[1], t[2], t[3], t[5], t[6], t[7], t[9], t[10], t[11]}
end
-- CreateThrowdownQueueParams.SpawnPoint is XYZ plus a yaw in radians.
-- TeleportLocation is only a Vec3; treating it as a transform discards the
-- facing chosen in the native placement editor and leaves an identity spawn.
function SP.native_spawn_transform(spawn)
    local co, si = f32(math.cos(spawn[4])), f32(math.sin(spawn[4]))
    return SP.spawn_transform(vector.create(spawn[1], spawn[2], spawn[3]), {co, 0, -si, 0, 1, 0, si, 0, co})
end

-- ---- for the port --------------------------------------------------------------------------------
-- The yaw (radians) a facing turns about world up: its forward row is (sin yaw, 0, cos yaw), as
-- native_spawn_transform builds it. The bridge passes facings as this, in degrees, and
-- reskate.skater.teleport takes it as its heading (0 faces +Z, pi/2 faces +X).
function SP.yaw(facing) return math.atan2(facing[7], facing[9]) end
-- The facing a yaw in degrees stands for (the bridge's create_at_spawn and offers do the same).
function SP.from_yaw_degrees(degrees)
    local yaw = f32(degrees * 3.14159265 / 180)
    return SP.transform_facing(SP.native_spawn_transform({0, 0, 0, yaw}))
end

return SP
