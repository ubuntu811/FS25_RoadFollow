-- Road Follow: a way through open ground (a field) with things in it.
--
-- No road to follow here: the course is the direction the vehicle was already going (a reference line), kept as closely as the
-- obstacles allow. Several arcs of different curvature are tried from where the vehicle is; for each, a corridor as wide as the
-- vehicle is checked along the arc, every 2 m. Of the arcs that are free for the whole look-ahead the one that ends closest to the
-- reference direction and line wins (with a little preference for the arc chosen last time, so the choice does not flicker); when
-- none is free for the whole length, the one that stays free longest. Re-planned a few times a second, a tree or a building is
-- passed on the shorter side and the reference line is rejoined behind it.
--
-- Pure: obstacles come from a `blocked(x, z)` callback (trees, buildings, steep ground ... whatever the caller knows).
RoadFieldCourse = {}

RoadFieldCourse.KAPPAS = { 0, 0.008, -0.008, 0.016, -0.016, 0.028, -0.028, 0.045, -0.045 }       -- 1/m, + = turning towards +z in x / z
RoadFieldCourse.STEP = 2.0
RoadFieldCourse.LATERAL_STEP = 1.6          -- metres between the checks across the corridor
RoadFieldCourse.MIN_FREE = 6.0              -- metres: less than this is no way through
RoadFieldCourse.HEADING_WEIGHT = 12.0       -- cost per radian between the heading at the end of the arc and the wanted one
RoadFieldCourse.CONVERGE = 15.0             -- metres: off the reference line by this much, the wanted heading at the end of the arc is 45 degrees back towards it
RoadFieldCourse.CONVERGE_MAX = 0.6          -- radians: the most the wanted heading is turned towards the line
RoadFieldCourse.CURVE_WEIGHT = 20.0         -- cost per 1/m of curvature (straight is preferred)
RoadFieldCourse.KEEP_WEIGHT = 60.0          -- cost per 1/m of change from the last arc (hysteresis)
RoadFieldCourse.SOFT_CLEARANCE = 1.2        -- metres of room kept beyond the vehicle's own corridor when there is a way that has it (an arc that only just
                                            -- squeezes past leaves no room for the turn that follows)
RoadFieldCourse.MAX_OFFSET = 50.0           -- metres: further than this from the reference line is no longer 'the same way'
RoadFieldCourse.MAX_HEADING = 1.3           -- radians (75 degrees): an arc that ends turned away this far from the reference direction is no way on
RoadFieldCourse.EVAL_LENGTH = 22.0          -- metres along the arc at which its heading and offset are judged (the whole length is only checked for obstacles:
                                            -- a long arc judged at its far end overshoots the reference line and never settles on it)
RoadFieldCourse.FULL_SHARE = 0.95           -- an arc free for this share of the look-ahead counts as free

local function wrap(angle)
    return math.atan2(math.sin(angle), math.cos(angle))
end

-- The point `s` metres along the arc from (x, z) with heading `theta` and curvature `kappa`.
local function arcPoint(x, z, theta, kappa, s)
    if math.abs(kappa) < 1e-6 then
        return x + math.cos(theta) * s, z + math.sin(theta) * s, theta
    end
    local t = theta + kappa * s
    return x + (math.sin(t) - math.sin(theta)) / kappa, z - (math.cos(t) - math.cos(theta)) / kappa, t
end
RoadFieldCourse.arcPoint = arcPoint

-- How far the arc is free: metres from the vehicle to the first blocked check of the corridor (the whole length when none).
local function freeLength(blocked, x, z, theta, kappa, length, halfWidth, step)
    local free = 0
    local s = step
    while s <= length + 1e-6 do
        local px, pz, t = arcPoint(x, z, theta, kappa, s)
        local nx, nz = -math.sin(t), math.cos(t)
        -- across the whole corridor (every LATERAL_STEP m): something between the middle and the edges is in the way too
        local count = math.max(1, math.ceil(halfWidth / RoadFieldCourse.LATERAL_STEP))
        for k = -count, count do
            local offset = halfWidth * k / count
            if blocked(px + nx * offset, pz + nz * offset) then
                return free
            end
        end
        free = s
        s = s + step
    end
    return length
end

-- x, z, hx, hz: where the vehicle is and which way it points. ref = { x, z, dx, dz }: the reference line (a point on it and its
-- direction). opts = { length (look-ahead, m), halfWidth (corridor, m), previous (the last curvature chosen) }.
-- Returns { points = { {x, z} ... } (every STEP m), kappa, free (m), clear (true when free for the whole look-ahead) }.
function RoadFieldCourse.plan(blocked, x, z, hx, hz, ref, opts)
    local length = opts.length or 30
    local halfWidth = opts.halfWidth or 2.5
    local step = opts.step or RoadFieldCourse.STEP
    local theta0 = math.atan2(hz, hx)
    local refTheta = math.atan2(ref.dz, ref.dx)
    local refNx, refNz = -ref.dz, ref.dx
    local previous = opts.previous or 0

    -- one pass with a given corridor half width: { kappa, free, clear } of the best arc, or nil when no arc is a way on
    local function pass(width)
        local best, bestCost, bestFree = nil, math.huge, -1
        local fallback, fallbackFree, fallbackCost = nil, -1, math.huge
        for _, kappa in ipairs(RoadFieldCourse.KAPPAS) do
            local free = freeLength(blocked, x, z, theta0, kappa, length, width, step)
            local ex, ez, et = arcPoint(x, z, theta0, kappa, math.max(math.min(free, RoadFieldCourse.EVAL_LENGTH), step))
            -- the heading wanted at the end of the arc: the reference direction, turned back towards the reference line by how far off it
            -- the arc ends (so the line is rejoined smoothly after a detour, not just kept parallel to)
            local offset = (ex - ref.x) * refNx + (ez - ref.z) * refNz
            local pull = math.max(-RoadFieldCourse.CONVERGE_MAX, math.min(RoadFieldCourse.CONVERGE_MAX, math.atan(offset / RoadFieldCourse.CONVERGE)))
            local headingError = math.abs(wrap(et - (refTheta - pull)))
            local awayFromRef = math.abs(wrap(et - refTheta))
            if math.abs(offset) <= RoadFieldCourse.MAX_OFFSET and awayFromRef <= RoadFieldCourse.MAX_HEADING then
                local cost = RoadFieldCourse.HEADING_WEIGHT * headingError
                    + RoadFieldCourse.CURVE_WEIGHT * math.abs(kappa) + RoadFieldCourse.KEEP_WEIGHT * math.abs(kappa - previous)
                if free >= length * RoadFieldCourse.FULL_SHARE then
                    if cost < bestCost then
                        best, bestCost, bestFree = kappa, cost, free
                    end
                elseif free > fallbackFree + 1e-6 or (math.abs(free - fallbackFree) <= 1e-6 and cost < fallbackCost) then
                    fallback, fallbackFree, fallbackCost = kappa, free, cost
                end
            end
        end
        if best ~= nil then
            return best, bestFree, true
        end
        return fallback, math.max(fallbackFree, 0), false
    end

    -- with room to spare when there is a way that has it; the bare corridor otherwise
    local kappa, free, clear = pass(halfWidth + RoadFieldCourse.SOFT_CLEARANCE)
    if kappa == nil or not clear then
        local k2, f2, c2 = pass(halfWidth)
        if k2 ~= nil and (c2 or kappa == nil or f2 > free) then
            kappa, free, clear = k2, f2, c2
        end
    end
    if kappa == nil then
        return { points = { { x, z } }, kappa = 0, free = 0, clear = false, blockedAhead = true }
    end
    local points = { { x, z } }
    local reach = math.max(free, step)
    local s = step
    while s <= reach + 1e-6 do
        local px, pz = arcPoint(x, z, theta0, kappa, s)
        points[#points + 1] = { px, pz }
        s = s + step
    end
    return { points = points, kappa = kappa, free = free, clear = clear, blockedAhead = free < RoadFieldCourse.MIN_FREE }
end
