-- Road Junction: what the next junction ahead looks like (T, Y, +, a side road) and which way the signal leads.
--
-- (Pure geometry on the roads RoadAtlas has stored: no engine calls, tested offline.)
--
-- A junction is a point. Its LEGS are the ways roads leave it: the directions of the stored road points 8 to 30 m round it, grouped (a road that runs through
-- is two legs). The leg the vehicle comes along is the APPROACH; every other leg gets its angle `rel` against the way straight on (0 = straight on, negative =
-- left, positive = right, in radians, as the world's x / z read: the left of a heading east (1, 0) is north, -z). The type:
--   "T"  two ways on, one each side (nothing straight on)       "Y"  a fork: two ways on, both leaning forward (or both on one side)
--   "t"  a side road joins: straight on, and one way to a side  "+"  a crossing: straight on, left and right      "star" more legs than that
RoadJunction = {}

RoadJunction.NEAR = 8.0                  -- metres: legs are read from the road points between NEAR and FAR from the junction
RoadJunction.FAR = 30.0                  -- (nearer, the roads are still pulled out of shape by the junction itself)
RoadJunction.CLUSTER_DEG = 25            -- points whose directions differ by less than this are one leg
RoadJunction.MIN_SUPPORT = 2             -- a leg needs at least this many road points
RoadJunction.APPROACH_DEG = 50           -- the approach is the leg within this of the way back to the vehicle
RoadJunction.AHEAD_DEG = 40              -- a junction is ahead when within this of the heading
RoadJunction.MIN_DISTANCE = 6.0          -- metres: nearer than this it is being passed
RoadJunction.STRAIGHT_DEG = 20           -- a leg within this of straight on is "straight on"
RoadJunction.FORK_DEG = 75               -- two ways on that both lean forward by no more than this are a fork (Y), else a T
RoadJunction.TURN_MIN_DEG = 15           -- a leg is on the signalled side when it leans at least this much to it

local function wrap(angle)
    return math.atan2(math.sin(angle), math.cos(angle))
end

-- The legs round (jx, jz) from the stored pieces: { { angle (world, atan2(dz, dx)), support } ... }
function RoadJunction.legsAt(pieces, jx, jz)
    local near2, far2 = RoadJunction.NEAR ^ 2, RoadJunction.FAR ^ 2
    local angles = {}
    for _, piece in ipairs(pieces) do
        for _, p in ipairs(piece.points) do
            local dx, dz = p[1] - jx, p[2] - jz
            local d2 = dx * dx + dz * dz
            if d2 >= near2 and d2 <= far2 then
                angles[#angles + 1] = math.atan2(dz, dx)
            end
        end
    end
    table.sort(angles)
    local gap = math.rad(RoadJunction.CLUSTER_DEG)
    local clusters = {}
    for _, angle in ipairs(angles) do
        local last = clusters[#clusters]
        if last ~= nil and angle - last.last <= gap then
            last.x, last.z, last.n, last.last = last.x + math.cos(angle), last.z + math.sin(angle), last.n + 1, angle
        else
            clusters[#clusters + 1] = { first = angle, last = angle, x = math.cos(angle), z = math.sin(angle), n = 1 }
        end
    end
    -- the circle's ends meet: the last group goes on into the first
    if #clusters >= 2 and clusters[1].first + 2 * math.pi - clusters[#clusters].last <= gap then
        local first, last = clusters[1], clusters[#clusters]
        last.x, last.z, last.n = last.x + first.x, last.z + first.z, last.n + first.n
        table.remove(clusters, 1)
    end
    local legs = {}
    for _, c in ipairs(clusters) do
        if c.n >= RoadJunction.MIN_SUPPORT then
            legs[#legs + 1] = { angle = math.atan2(c.z, c.x), support = c.n }
        end
    end
    return legs
end

-- The type of a junction from the angles (against straight on) of the ways on, or nil when there is only one way on (a bend, not a junction).
-- Second result: for "t", the side the road joins from.
function RoadJunction.classify(others)
    local n = #others
    if n < 2 then
        return nil
    end
    local straight = math.rad(RoadJunction.STRAIGHT_DEG)
    local ahead, left, right, leanMax = 0, 0, 0, 0
    local sideOfT = nil
    for _, leg in ipairs(others) do
        local r = math.abs(leg.rel)
        leanMax = math.max(leanMax, r)
        if r <= straight then
            ahead = ahead + 1
        elseif leg.rel < 0 then
            left = left + 1
            sideOfT = "left"
        else
            right = right + 1
            sideOfT = "right"
        end
    end
    if n == 2 then
        if ahead == 1 then
            return "t", sideOfT
        end
        local forkLimit = math.rad(RoadJunction.FORK_DEG)
        if leanMax <= forkLimit then
            return "Y"                      -- both ways lean forward (and neither is straight on): a fork
        end
        if left == 1 and right == 1 then
            return "T"
        end
        return "Y"
    end
    if n == 3 and ahead == 1 and left == 1 and right == 1 then
        return "+"
    end
    return "star"
end

-- The picture of a junction at (jx, jz) for a vehicle at (carX, carZ): { x, z, legs, approach, others, type, side } or nil when the vehicle is not on one of
-- its roads. legs = the approach (rel = pi) and the other legs, left to right.
function RoadJunction.describe(legs, jx, jz, carX, carZ)
    local back = math.atan2(carZ - jz, carX - jx)
    local approach, bestDiff = nil, math.rad(RoadJunction.APPROACH_DEG)
    for _, leg in ipairs(legs) do
        local diff = math.abs(wrap(leg.angle - back))
        if diff <= bestDiff then
            approach, bestDiff = leg, diff
        end
    end
    if approach == nil then
        return nil
    end
    local forward = approach.angle + math.pi
    local others, all = {}, {}
    for _, leg in ipairs(legs) do
        local copy = { angle = leg.angle, support = leg.support }
        if leg == approach then
            copy.rel, copy.approach = math.pi, true
        else
            copy.rel = wrap(leg.angle - forward)
            others[#others + 1] = copy
        end
        all[#all + 1] = copy
    end
    table.sort(others, function(a, b) return a.rel < b.rel end)
    local legsOut = {}
    for _, leg in ipairs(all) do
        if leg.approach then
            legsOut[#legsOut + 1] = leg
        end
    end
    for _, leg in ipairs(others) do
        legsOut[#legsOut + 1] = leg
    end
    local kind, side = RoadJunction.classify(others)
    if kind == nil then
        return nil
    end
    return { x = jx, z = jz, legs = legsOut, approach = legsOut[1], others = others, type = kind, side = side }
end

-- The leg the signal leads into: with "left" / "right" the one on that side nearest to a right-angle turn; with no signal the way straight on, when the
-- junction has one that is plain (a + or a side road; at a T or a fork there is no default). nil when there is none.
function RoadJunction.chosenLeg(info, intent)
    if info == nil then
        return nil
    end
    local best, bestScore = nil, nil
    if intent == "left" or intent == "right" then
        local sign = intent == "left" and -1 or 1
        for _, leg in ipairs(info.others) do
            local lean = leg.rel * sign
            if lean > math.rad(RoadJunction.TURN_MIN_DEG) then
                local score = math.abs(lean - math.pi / 2)
                if best == nil or score < bestScore then
                    best, bestScore = leg, score
                end
            end
        end
        return best
    end
    if info.type == "T" or info.type == "Y" then
        return nil
    end
    for _, leg in ipairs(info.others) do
        local r = math.abs(leg.rel)
        if r <= math.rad(RoadJunction.STRAIGHT_DEG) and (best == nil or r < bestScore) then
            best, bestScore = leg, r
        end
    end
    return best
end

-- The next junction ahead of a vehicle at (x, z) heading (hx, hz), within maxDist metres, from the atlas (RoadAtlas: its stored pieces and junction points):
-- the picture (see describe) with .distance, or nil. Legs are worked out again only when the atlas's roads have changed.
function RoadJunction.ahead(atlas, x, z, hx, hz, maxDist)
    local candidates = {}
    local cosAhead = math.cos(math.rad(RoadJunction.AHEAD_DEG))
    for _, j in ipairs(atlas.junctions) do
        local dx, dz = j[1] - x, j[2] - z
        local d = math.sqrt(dx * dx + dz * dz)
        if d >= RoadJunction.MIN_DISTANCE and d <= maxDist and (dx * hx + dz * hz) >= cosAhead * d then
            candidates[#candidates + 1] = { j = j, d = d }
        end
    end
    table.sort(candidates, function(a, b) return a.d < b.d end)
    for _, c in ipairs(candidates) do
        local j = c.j
        if j.legsRevision ~= atlas.revision then
            j.legs, j.legsRevision = RoadJunction.legsAt(atlas.pieces, j[1], j[2]), atlas.revision
        end
        local info = RoadJunction.describe(j.legs, j[1], j[2], x, z)
        if info ~= nil then
            info.distance = c.d
            return info
        end
    end
    return nil
end
