-- Board Break's geometry, apart from the game: where a board breaks, what is left of it, and where
-- each part of a broken board lies. Everything is measured on the deck, in the deck model's own
-- axes: metres, y up, z along the board with the nose at +z. (Ported from ReSkate's
-- Extension/BoardBreak/board_break_model.h.)
local model = {}

-- ---- rigid motions -------------------------------------------------------------------------------
-- Positions are vectors; quaternions are {x, y, z, w} (Hamilton), as reskate.board has them.
local function v(x, y, z) return vector.create(x, y, z) end
model.vec = v
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function length(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
model.length = length
local function identity() return {0, 0, 0, 1} end
model.identity = identity
-- b first, then a.
local function mul(a, b)
    return {a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2], a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
            a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4], a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3]}
end
local function conj(q) return {-q[1], -q[2], -q[3], q[4]} end
local function unit(q)
    local n = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    if n > 1e-6 then return {q[1] / n, q[2] / n, q[3] / n, q[4] / n} end
    return identity()
end
local function about(axis, radians)
    local s = math.sin(radians / 2)
    return {axis.x * s, axis.y * s, axis.z * s, math.cos(radians / 2)}
end
local function turn(q, p)
    local u = v(q[1], q[2], q[3])
    local c = cross(u, p)
    return p + c * (2 * q[4]) + cross(u, c) * 2
end
model.mul, model.conj, model.unit, model.about, model.turn = mul, conj, unit, about, turn
-- Turned, then shifted.
local function rigid(facing, at) return {facing = facing or identity(), at = at or v(0, 0, 0)} end
model.rigid = rigid

-- ---- breaks --------------------------------------------------------------------------------------
-- A deck breaks across one of three rows: just ahead of the front bolts, in the middle, just behind
-- the back bolts. That cuts it into four stretches; each truck rides on the stretch its bolts are in.
model.nose, model.front, model.back, model.tail, model.front_truck, model.back_truck = 1, 2, 4, 8, 16, 32
model.whole_board = 63
model.stretches = 15
model.places = {"nose", "mid", "tail"}
model.nose_row, model.mid_row, model.tail_row = 0.260, 0.009, -0.260
local function has(set, piece) return bit32.band(set, piece) ~= 0 end
model.has = has

-- What a break leaves: the piece the board keeps, the piece that comes off and flies (0 when the
-- grip tape holds), and how the two hang together: "none", or with the nose hanging ("nose"), the
-- board folded in the middle ("fold"), the tail hanging ("tail").
function model.broken_at(place, joined)
    if joined then
        return {kept = model.whole_board, loose = 0, hinge = if place == "nose" then "nose" elseif place == "mid" then "fold" else "tail"}
    end
    -- A clean break: the board keeps the larger piece, and of two halves the front one.
    if place == "nose" then return {kept = model.whole_board - model.nose, loose = model.nose, hinge = "none"} end
    if place == "mid" then
        return {kept = model.nose + model.front + model.front_truck, loose = model.back + model.tail + model.back_truck, hinge = "none"}
    end
    return {kept = model.whole_board - model.tail, loose = model.tail, hinge = "none"}
end
-- How big a break is, for its sound. An end that hangs on by the grip tape is a small one; an end
-- that comes off, or a board that folds a little, is in between; a board that folds right down or
-- comes apart in the middle is the biggest. `fold_depth` is 0 to 1, how far a fold sags.
function model.break_size(place, joined, fold_depth)
    if place == "mid" then return if not joined or fold_depth >= 0.7 then "heavy" else "medium" end
    return if joined then "light" else "medium"
end
-- How likely a slam of `force` breaks the board: never up to 60% of `heavy`, always from `heavy` up,
-- rising smoothly in between.
function model.break_chance(force, heavy)
    if heavy <= 0 or force >= heavy then return 1 end
    local low = 0.6 * heavy
    if force <= low then return 0 end
    local t = (force - low) / (heavy - low)
    return t * t * (3 - 2 * t)
end

-- ---- where the parts of a broken board lie -------------------------------------------------------
model.axle_height, model.front_axle, model.back_axle = 0.028, 0.2226, -0.2225
-- How far each half of a board tips: a touch short of where its first splinter meets the ground.
model.front_tip, model.back_tip = 0.340, 0.315
-- Half a board on one truck tips about its axle until the broken end lies on the ground. `towards`
-- is +1 when the broken end is on the nose side of that axle.
function model.tipped_on_axle(axle_z, towards, angle)
    local turned = about(v(1, 0, 0), towards * angle)
    local axle = v(0, model.axle_height, axle_z)
    return rigid(turned, axle - turn(turned, axle))
end
-- A piece that hangs on by the grip tape: turned about the break line just under the deck's top,
-- and drawn a hair away from the board, so the tape opens into a ragged crack.
model.crack, model.grip_height = 0.0025, 0.0935
function model.hung_on_grip(break_z, towards, angle)
    local turned = about(v(1, 0, 0), towards * angle)
    local hinge = v(0, model.grip_height - 0.004, break_z)
    return rigid(turned, hinge - turn(turned, hinge) + v(0, 0, towards * model.crack * 0.5))
end
-- A board folded in the middle: each half turns about its own axle, the front by `depth` of the
-- way to the ground and the back as far as brings its grip to the same height, and the two move
-- along the board until the grip of both all but meets again at the break. The front half, then the back.
function model.folded(depth)
    local grip_y = 0.095
    local rise, ahead, behind = grip_y - model.axle_height, model.front_axle - model.mid_row, model.mid_row - model.back_axle
    local a = model.front_tip * math.clamp(depth, 0, 1)
    local height = rise * math.cos(a) - ahead * math.sin(a)
    local b = math.acos(math.clamp(height / math.sqrt(rise * rise + behind * behind), -1, 1)) - math.atan2(behind, rise)
    local front_half = model.tipped_on_axle(model.front_axle, -1, a)
    local back_half = model.tipped_on_axle(model.back_axle, 1, b)
    local front_end = model.front_axle - (rise * math.sin(a) + ahead * math.cos(a))
    local back_end = model.back_axle + (rise * math.sin(b) + behind * math.cos(b))
    local shift = (back_end - front_end + model.crack) * 0.5 -- and a crack's width more: the tape gapes
    front_half.at += v(0, 0, shift)
    back_half.at -= v(0, 0, shift)
    return front_half, back_half
end
-- The deck sits on the board's rig a quarter turn about the upright axis (the rig's mount carries
-- it), and the stretches hang on the rig's root: a motion worked out on the deck, carried over.
function model.on_root(mount, motion)
    return rigid(unit(mul(mul(mount, motion.facing), conj(mount))), turn(mount, motion.at))
end

-- Where something goes that is not to be seen: far below the board.
model.away = v(0, -2000, 0)
-- A broken board as it lies, in the rig root's axes: its four stretches (nose, front, back, tail,
-- in that order everywhere), each {shown, motion}, and its trucks.
-- `kept` is the piece the board keeps, hanging together as `hinge` says. `angle` is how far an end
-- droops (radians) or how deep a fold sags (0 to 1); `up` is how far the board is the right way up
-- (1 on its wheels, -1 on its grip); `mount` is the rig's mount turn.
function model.lay_out(kept, hinge, angle, up, mount)
    local ahead, rear, hung = rigid(), rigid(), rigid()
    if hinge == "fold" then
        -- The break sags towards the ground under the board. On its grip the fold would push nose
        -- and tail into the ground instead, so there it stays shallow.
        local level = math.clamp((up + 0.2) / 0.8, 0, 1)
        ahead, rear = model.folded(angle * (0.3 + 0.7 * level))
    elseif hinge == "nose" then
        hung = model.hung_on_grip(model.nose_row, 1, angle)
    elseif hinge == "tail" then
        hung = model.hung_on_grip(model.tail_row, -1, angle)
    elseif has(kept, model.front_truck) ~= has(kept, model.back_truck) then
        -- Half a deck on one truck: while the board is the right way up it tips onto its broken end.
        local level = math.clamp((up - 0.3) / 0.5, 0, 1)
        local amount = level * level * (3 - 2 * level)
        ahead = if has(kept, model.front_truck) then model.tipped_on_axle(model.front_axle, -1, model.front_tip * amount)
            else model.tipped_on_axle(model.back_axle, 1, model.back_tip * amount)
    end
    ahead = model.on_root(mount, ahead)
    hung = model.on_root(mount, hung)
    rear = if hinge == "fold" then model.on_root(mount, rear) else ahead
    return {
        stretch = {
            {shown = has(kept, model.nose), motion = if hinge == "nose" then hung else ahead},
            {shown = has(kept, model.front), motion = ahead},
            {shown = has(kept, model.back), motion = rear},
            {shown = has(kept, model.tail), motion = if hinge == "fold" then rear elseif hinge == "tail" then hung else ahead},
        },
        front_truck = has(kept, model.front_truck),
        back_truck = has(kept, model.back_truck),
        front_motion = ahead,
        back_motion = rear,
    }
end
-- What goes into the stretches' bones. The first three hang on the rig's root; the tail's hangs on
-- the front stretch's, so its place is given from there. A stretch that does not show goes away.
function model.bones_of(stretch)
    local motion = {}
    for i = 1, 4 do motion[i] = if stretch[i].shown then stretch[i].motion else rigid(identity(), model.away) end
    local from, to = motion[2], motion[4]
    local back = conj(from.facing)
    return {motion[1], motion[2], motion[3], rigid(unit(mul(back, to.facing)), turn(back, to.at - from.at))}
end
-- A truck hangs on the deck's bone, which is moved `deck_away` to hide the real deck, and that bone
-- sits on the mount. To move the truck with a piece: the piece's motion seen from the deck, the
-- deck's move taken back. `steer` is the truck's own turn, which it keeps; `place` where it sits on the deck.
model.back_truck_place, model.front_truck_place = v(0.0005, -0.0183, -0.2345), v(0.0005, -0.0183, 0.2347)
-- The real deck goes this far down: reskate.board.set takes a bone at most 1000 m from its parent,
-- and the trucks, which hang on the deck, come back up by as much.
model.deck_away = v(0, -950, 0)
function model.truck_bone(motion, mount, mount_at, steer, place)
    local facing = unit(mul(mul(conj(mount), motion.facing), mount))
    local at = turn(conj(mount), turn(motion.facing, mount_at) + motion.at - mount_at)
    return rigid(unit(mul(facing, steer)), turn(facing, place) + at - model.deck_away)
end
-- The trucks' baseplates. A deck pack's truck model has each baseplate on its truck's effector, a
-- bone under the truck's: this is where that effector goes so that the baseplate sits on the deck
-- however the truck steers. `truck` is the truck's bone as the animation left it.
model.back_truck_rest = {facing = {-0.3641458, -0.3641458, -0.6061335, 0.6061335}, at = v(0.0005361, -0.0183003, -0.2344986), effector = v(0.0395021, 0, 0)}
model.front_truck_rest = {facing = {-0.6061674, 0.6061674, 0.3640894, 0.3640894}, at = v(0.0005361, -0.0182917, 0.2346680), effector = v(0.0395677, 0, 0)}
function model.baseplate_bone(truck, rest)
    local back = conj(truck.facing)
    return rigid(unit(mul(back, rest.facing)), turn(back, rest.at + turn(rest.facing, rest.effector) - truck.at))
end

-- ---- the piece that comes off --------------------------------------------------------------------
-- Its kick (m/s) and spin (axis times rad/s) in the deck's own axes, and how far above the ground
-- the rig's origin lies once the piece rests: a bare piece lies on its underside. `roll(low, high)`
-- draws a number. (The plugin cannot carry a loose truck: board.toss writes bones relative to the
-- board's place, and a truck hangs on the deck, so a piece that comes off goes without its truck.)
function model.flight(loose, roll)
    local loose_end = not has(loose, model.front_truck + model.back_truck) -- a nose or tail, no truck on it
    local along = if has(loose, model.nose) then 1 else -1 -- the way it leaves, along the board
    local push = if loose_end then 1 else 0.55
    return {
        kick = v(roll(-0.9, 0.9) * push, (1.4 + roll(0, 1.2)) * push, along * (1.2 + roll(0, 1.6)) * push),
        spin = v(along * (5 + roll(0, 6)) * push, roll(-3, 3) * push, roll(-2, 2) * push),
        rest = -0.083 + 0.012, -- on its underside, a little above: real ground is rough
    }
end
return model
