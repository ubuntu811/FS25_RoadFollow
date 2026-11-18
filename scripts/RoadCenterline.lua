--[[
    RoadCenterline.lua

    Pure geometry for following a road: no engine calls, the road comes in as a function
    sample(x, z) -> 0 (not road), 1 (worn trail) or 2 (road).

    From the vehicle's position and heading it marches forward in short steps. At every step it
    scans a line across the direction of travel, finds the stretches of road ("runs") on that
    line, picks the one that continues the road, and moves to its middle. The middles form a short
    polyline: the centre-line ahead. From it come the point to steer at, how sharp the bend is, and
    whether the road ends or opens up (a junction or a yard).

    The map data is a bitmap of two-metre pixels, so a single scan is blocky; the direction is
    smoothed along the march and the curvature is read over the whole polyline, not step by step.
]]

RoadCenterline = {}

RoadCenterline.STEP = 1.5              -- metres between two scans
RoadCenterline.STEPS = 16              -- scans ahead (polyline of about 24 m)
RoadCenterline.HALF_WIDTH = 7.0        -- how far to each side a scan looks
RoadCenterline.START_HALF_WIDTH = 10.0 -- the first scan, at the vehicle, looks wider (it may stand beside the road)
RoadCenterline.SAMPLE_SPACING = 0.5    -- metres between samples on a scan
RoadCenterline.MAX_ROAD_WIDTH = 12.0   -- a wider run is open ground (yard, junction), not a road
RoadCenterline.MAX_SHIFT = 1.5         -- the middle may move at most this far sideways per step
RoadCenterline.DIRECTION_SMOOTHING = 0.3
RoadCenterline.FAR_STEP = 3.0          -- beyond the near range the march steps this far (coarser, cheaper)
RoadCenterline.NEAR_RANGE = 15.0       -- metres read at STEP; only used when a reach is asked for
RoadCenterline.WIDEN_MARGIN = 3.0         -- a run wider than the road by more than this is a junction (2 m pixels: noise is about 2)
RoadCenterline.OPEN_JUMP = 1.5            -- an edge that moved outward by this much is where the road opened up
RoadCenterline.TURN_SHIFT_PER_STEP = 0.22 -- following an opening (turn signal): sideways move per metre of step (about 12 degrees)
RoadCenterline.DEFAULT_ROAD_WIDTH = 8.0   -- assumed when the vehicle starts inside a junction
RoadCenterline.CORNER_CLUSTER = 8.0      -- an opening this far after the last one starts a new candidate bend
RoadCenterline.CORNER_REACH = 16.0        -- the road must stop going straight on within this of the opening for it to be a bend
RoadCenterline.MERGE_MAX_WIDTH = 9.0      -- ... but only while the merged track stays this wide (two ruts and their hump are about 7-8 m; branches of a fork that keep diverging soon are wider)
RoadCenterline.MERGE_GAP = 4.5            -- stretches of road on a scan line with less than this between them are one track (wheel ruts with a grass hump, a worn patch in a gravel road): the centre is then the middle between the outer edges
RoadCenterline.JUNCTION_RUN_GAP = 5.0     -- another stretch of road on the scan line only counts as a junction when it is this far (metres) from the one we follow (ruts are 2 to 3.5 m apart): wheel ruts with grass between them are one track
RoadCenterline.REACQUIRE_RANGE = 14.0    -- after open ground (a crossing road) the road beyond may be this far off to the side ...
RoadCenterline.REACQUIRE_SHIFT = 0.45    -- ... and is steered for gently: sideways metres per metre
RoadCenterline.MAX_GAP = 4.0           -- a hole in the road this long (metres) is bridged in a straight line
RoadCenterline.TRAIL_MAX_GAP = 12.0    -- ... on a worn trail (never any real road pixel so far) the holes are longer: trails are spotty
RoadCenterline.HARD_LATERAL_ACCEL = 3.5   -- m/s^2: what no bend speed may exceed, whatever the floor says
RoadCenterline.TIGHT_KAPPA = 0.04        -- 1/m: a bend this sharp (radius 25 m or less) is a junction-sized turn ...
RoadCenterline.TIGHT_KMH = 15            -- ... taken this slowly whatever the floor says (a tractor with a trailer cannot steer round it faster)
RoadCenterline.LATERAL_ACCEL = 2.0     -- m/s^2 allowed in a bend (a tractor on a track takes more than a car would)
RoadCenterline.BRAKE_DECEL = 1.0       -- m/s^2 used to stop at a road's end
RoadCenterline.JUNCTION_SPEED_KMH = 12

local function normalize(x, z)
    local length = math.sqrt(x * x + z * z)
    if length < 1e-9 then
        return 0, 1
    end
    return x / length, z / length
end

-- The map class (0 none, 1 worn trail, 2 road) of every sample on the line through (cx, cz) across
-- direction (dx, dz); index i = -count .. count, i * spacing metres from the middle, left is +.
function RoadCenterline.scanClasses(sample, cx, cz, dx, dz, halfWidth, spacing)
    local nx, nz = -dz, dx
    local count = math.floor(halfWidth / spacing)
    local classes = {}
    for i = -count, count do
        local t = i * spacing
        classes[i] = sample(cx + nx * t, cz + nz * t) or 0
    end
    return classes, count
end

-- The stretches on such a line whose class is at least minClass:
-- { { from, to, centre, width }, ... } in metres from the line's middle.
function RoadCenterline.runsFromClasses(classes, count, spacing, minClass)
    local runs, current = {}, nil
    for i = -count, count do
        local t = i * spacing
        if classes[i] >= minClass then
            if current == nil then
                current = { from = t, to = t }
            else
                current.to = t
            end
        elseif current ~= nil then
            runs[#runs + 1] = current
            current = nil
        end
    end
    if current ~= nil then
        runs[#runs + 1] = current
    end
    -- stretches with only a short gap between them are one track
    local merged = {}
    for _, run in ipairs(runs) do
        local last = merged[#merged]
        if last ~= nil and (run.from - last.to - spacing) <= RoadCenterline.MERGE_GAP
            and (run.to - last.from + spacing) <= RoadCenterline.MERGE_MAX_WIDTH then
            last.to = run.to
        else
            merged[#merged + 1] = run
        end
    end
    runs = merged
    for _, run in ipairs(runs) do
        run.centre = (run.from + run.to) * 0.5
        run.width = run.to - run.from + spacing
    end
    return runs
end

-- Every stretch of road or trail on the line (any class).
function RoadCenterline.scanRuns(sample, cx, cz, dx, dz, halfWidth, spacing)
    local classes, count = RoadCenterline.scanClasses(sample, cx, cz, dx, dz, halfWidth, spacing)
    return RoadCenterline.runsFromClasses(classes, count, spacing, 1)
end

-- A run that reaches the edge of the scan window goes on beyond it: open ground (a yard, a
-- field track widening out), whose middle means nothing. Its width is reported as at least the
-- window. Returns the sideways shift to aim for (0 on open ground) and whether it is open ground.
local function aimOf(run, halfWidth, spacing, maxWidth, maxShift)
    -- (a core run is bounded by ground that is not the road paint; it may lie right at the edge of the window and is no yard)
    local reachesEdge = not run.core and (run.from <= -halfWidth + spacing or run.to >= halfWidth - spacing)
    if reachesEdge or run.width > maxWidth then
        return 0, true
    end
    return math.max(-maxShift, math.min(maxShift, run.centre)), false
end

-- The run that continues the road: the one holding the straight-ahead line, else the nearest one.
local function chooseRun(runs)
    local best, bestDistance = nil, math.huge
    for _, run in ipairs(runs) do
        local distance = 0
        if 0 < run.from then
            distance = run.from
        elseif 0 > run.to then
            distance = -run.to
        end
        if distance < bestDistance or (distance == bestDistance and best ~= nil and math.abs(run.centre) < math.abs(best.centre)) then
            best, bestDistance = run, distance
        end
    end
    return best
end

-- The runs to steer by on one line: where there is real road (class 2) within reach of the straight
-- line, only the road, so a gravel yard or verge next to it does not widen it or pull its middle
-- sideways; otherwise any road or trail.
RoadCenterline.PREFER_ROAD_WITHIN = 3.0
local function runsOnLine(sample, cx, cz, dx, dz, halfWidth, spacing)
    local classes, count = RoadCenterline.scanClasses(sample, cx, cz, dx, dz, halfWidth, spacing)
    local roadRuns = RoadCenterline.runsFromClasses(classes, count, spacing, 2)
    local roadRun = chooseRun(roadRuns)
    if roadRun ~= nil then
        local distance = 0
        if 0 < roadRun.from then
            distance = roadRun.from
        elseif 0 > roadRun.to then
            distance = -roadRun.to
        end
        if distance <= RoadCenterline.PREFER_ROAD_WITHIN then
            for _, run in ipairs(roadRuns) do
                run.class = 2
            end
            return roadRuns
        end
    end
    local anyRuns = RoadCenterline.runsFromClasses(classes, count, spacing, 1)
    for _, run in ipairs(anyRuns) do
        run.class = 1
    end
    return anyRuns
end

-- A turn at a junction, planned as a whole: the side road's axis is found by looking out sideways from
-- the line, the corner is rounded with an arc, and the line goes on along the side road. `side` is +1
-- for left, -1 for right; (px, pz) is where the line is when the opening is met, heading (dx, dz),
-- `points` the line so far (first point at the vehicle). Returns the new list of points, or nil when no
-- side road is found (then the vehicle just goes straight on).
RoadCenterline.TURN_RADIUS = 10.0
RoadCenterline.TURN_DIRECTION_BASE = 6.0   -- a second look this much further out finds the side road's direction
RoadCenterline.TURN_MIN_ANGLE = 25         -- degrees: a side road leaving at less than this is not a turn
RoadCenterline.TURN_MIN_LEG = 12.0         -- metres: a side road is seen this far along (two looks TURN_DIRECTION_BASE apart beyond the first); a single dirt patch is no road
RoadCenterline.TURN_SEARCH_OUT = 8.0      -- metres out from the road's edge at which the side road's axis is measured
local function planTurn(sample, points, px, pz, dx, dz, side, expectedWidth, remaining, options)
    local halfWidth = (options.halfWidth or RoadCenterline.HALF_WIDTH) * 2.2
    local spacing = options.spacing or RoadCenterline.SAMPLE_SPACING
    local maxWidth = options.maxRoadWidth or RoadCenterline.MAX_ROAD_WIDTH
    local nx, nz = -dz * side, dx * side                      -- the way the turn goes
    local out = expectedWidth * 0.5 + RoadCenterline.TURN_SEARCH_OUT

    -- where the side road crosses a line parallel to the main road, `distance` out to the side: its run, as
    -- a position along the main road (+ ahead of P)
    local function sideRoadAt(distance, nearAlong, shift, wide)
        shift = shift or 0                           -- the scan line is centred this far ahead (a side road that slants away drifts along)
        local window = wide and halfWidth * 2 or halfWidth      -- ... and wider the further out it is looked for
        local cx, cz = px + nx * distance + dx * shift, pz + nz * distance + dz * shift
        -- across the side road: this scan runs along the main road, positive towards -side * heading
        local classes, count = RoadCenterline.scanClasses(sample, cx, cz, nx, nz, window, spacing)
        local runs = RoadCenterline.runsFromClasses(classes, count, spacing, 2)
        if #runs == 0 then
            runs = RoadCenterline.runsFromClasses(classes, count, spacing, 1)
        end
        local best, bestWidth = nil, nil
        for _, r in ipairs(runs) do
            local reachesEdge = r.from <= -window + spacing or r.to >= window - spacing
            if r.width <= maxWidth * 1.6 and not reachesEdge then
                local along = -side * r.centre + shift
                if best == nil or math.abs(along - nearAlong) < math.abs(best - nearAlong) then
                    best = along
                    bestWidth = r.width
                end
            end
        end
        return best, bestWidth
    end

    local along1, legWidth = sideRoadAt(out, 0)
    if along1 == nil then
        return nil
    end
    -- the side road's direction: a second look further out. It leaves at an angle phi to the main road
    -- (90 degrees: square on, less: it slants forward). Without a second sighting it is taken as square on.
    local gap = RoadCenterline.TURN_DIRECTION_BASE
    local along2 = sideRoadAt(out + gap, along1, along1, true)
    -- a road leaves the road: it is there at three distances out, not a single patch of dirt beside the road (a leg of
    -- at least TURN_MIN_LEG metres from the first sighting)
    local along3 = along2 ~= nil and sideRoadAt(out + 2 * gap, along2 + (along2 - along1), along2 + (along2 - along1), true) or nil
    if along2 == nil or along3 == nil then
        return nil
    end
    local phi = math.pi / 2
    if along2 ~= nil then
        local measured = math.atan2(gap, along2 - along1)
        if measured >= math.rad(RoadCenterline.TURN_MIN_ANGLE) and measured <= math.rad(110) then
            phi = measured
        end
    end
    -- the side road's axis meets the main line at the corner
    local along = along1 - out / math.tan(phi)
    local cornerX, cornerZ = px + dx * along, pz + dz * along

    -- the line so far, and how far the corner is along it
    local total = RoadCenterline.length(points)
    local toCorner = total + along
    -- the arc fits between the line and the side road: tangent length t = r * tan(phi / 2) on each side
    local half = math.tan(phi / 2)
    local radius = RoadCenterline.TURN_RADIUS
    local t = radius * half
    if t > toCorner then
        t = toCorner
        radius = t / half
    end
    if radius < 3 then
        return nil
    end
    -- cut the line at the arc's start (t before the corner)
    local cutAt = toCorner - t
    local kept = { points[1] }
    local walked = 0
    local ax, az = points[1][1], points[1][2]
    for i = 2, #points do
        local bx, bz = points[i][1], points[i][2]
        local seg = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
        if walked + seg >= cutAt then
            local f = seg > 1e-9 and (cutAt - walked) / seg or 0
            kept[#kept + 1] = { ax + (bx - ax) * f, az + (bz - az) * f }
            walked = cutAt
            break
        end
        kept[#kept + 1] = { bx, bz }
        walked = walked + seg
        ax, az = bx, bz
    end
    -- if the corner is beyond the end of the line, extend straight to the arc's start
    if walked < cutAt - 1e-6 then
        local last = kept[#kept]
        local extra = cutAt - walked
        kept[#kept + 1] = { last[1] + dx * extra, last[2] + dz * extra }
    end
    local startX, startZ = kept[#kept][1], kept[#kept][2]
    -- the arc: from the tangent point, phi round to the side road's axis
    local step = options.step or RoadCenterline.STEP
    local angleStep = step / radius
    local theta = angleStep
    while theta < phi - 1e-6 do
        kept[#kept + 1] = {
            startX + dx * radius * math.sin(theta) + nx * radius * (1 - math.cos(theta)),
            startZ + dz * radius * math.sin(theta) + nz * radius * (1 - math.cos(theta)),
        }
        theta = theta + angleStep
    end
    local endX = startX + dx * radius * math.sin(phi) + nx * radius * (1 - math.cos(phi))
    local endZ = startZ + dz * radius * math.sin(phi) + nz * radius * (1 - math.cos(phi))
    kept[#kept + 1] = { endX, endZ }
    -- the side road's direction at the end of the arc
    local sdx, sdz = dx * math.cos(phi) + nx * math.sin(phi), dz * math.cos(phi) + nz * math.sin(phi)

    -- on along the side road
    local used = RoadCenterline.length(kept)
    local left = remaining - used
    if left > step then
        local sub = RoadCenterline.scan(sample, endX, endZ, sdx, sdz, {
            reach = left, step = options.step, halfWidth = options.halfWidth, spacing = options.spacing,
            maxRoadWidth = options.maxRoadWidth, maxShift = options.maxShift, smoothing = options.smoothing, noCorner = true, core = options.core, fine = options.fine,
        })
        if sub.valid then
            for i = 2, #sub.points do
                kept[#kept + 1] = sub.points[i]
            end
            return kept, sub.ends, math.deg(phi), legWidth
        end
    end
    return kept, false, math.deg(phi), legWidth
end

-- result = {
--   valid       false when there is no road at the vehicle (result.reason says why)
--   points      { {x, z}, ... } centre-line ahead, the first point is the road's middle at the vehicle
--   found       how many scans found road
--   ends        true when the road stops before the polyline is full
--   junction    true when a scan met open ground or a fork
--   offset      sideways distance of the vehicle from the road's middle, metres (+ = road is to the left)
--   roadWidth   width of the road at the vehicle
-- }
-- The legs of a junction, found by a ring scan: from the junction's middle (a point `ahead` metres in front of (px, pz)), road
-- samples on two circles (radius r and r + 4) every 5 degrees; a stretch of the circle that is road on both is a leg. Each leg
-- comes back as its angle against the heading (0 = straight on, + = to the geometry's left, up to +-180 = back the way we came)
-- and its width. The way we came from is left out. This is what "where are the roads from here" looks like, as one picture.
RoadCenterline.LEG_RADIUS = 12.0
RoadCenterline.LEG_AHEAD = 5.0
RoadCenterline.LEG_STEP_DEG = 5
RoadCenterline.LEG_STRAIGHT_DEG = 30
local function junctionLegs(sample, px, pz, dx, dz, options)
    options = options or {}
    local cx, cz = px + dx * (options.legAhead or RoadCenterline.LEG_AHEAD), pz + dz * (options.legAhead or RoadCenterline.LEG_AHEAD)
    local r1 = options.legRadius or RoadCenterline.LEG_RADIUS
    local r2 = r1 + 4
    local heading = math.atan2(dz, dx)
    local step = RoadCenterline.LEG_STEP_DEG
    local count = math.floor(360 / step)
    local on = {}
    for i = 0, count - 1 do
        local angle = heading + math.rad(i * step)
        local ca, sa = math.cos(angle), math.sin(angle)
        on[i] = (sample(cx + ca * r1, cz + sa * r1) or 0) > 0 and (sample(cx + ca * r2, cz + sa * r2) or 0) > 0
    end
    -- runs of consecutive samples (wrapping round), a gap of one sample is bridged
    local legs = {}
    local visited = {}
    for i = 0, count - 1 do
        if on[i] and not on[(i - 1) % count] and not visited[i] then
            local j = i
            local last = i
            local gap = 0
            local total = 0
            while total < count do
                local nextI = (j + 1) % count
                if on[nextI] then
                    gap = 0
                    last = nextI
                elseif gap < 1 then
                    gap = gap + 1
                else
                    break
                end
                j = nextI
                total = total + 1
            end
            local span = ((last - i) % count) + 1
            local centre = (i + (span - 1) / 2) % count
            -- angle against the heading: indices count counter-clockwise (in x / z) from the heading, which is "left" here
            local theta = centre * step
            if theta > 180 then theta = theta - 360 end
            visited[i] = true
            legs[#legs + 1] = { angle = theta, width = span * step, arc = span * step }
        end
    end
    -- all on: open ground all round, not legs
    local allOn = true
    for i = 0, count - 1 do if not on[i] then allOn = false end end
    if allOn then return {}, true end
    local out = {}
    for _, leg in ipairs(legs) do
        if math.abs(leg.angle) < 150 then
            out[#out + 1] = leg
        end
    end
    return out, false
end
RoadCenterline.junctionLegs = junctionLegs

local function legSummary(legs)
    local info = { straight = false, left = 0, right = 0, count = #legs }
    for _, leg in ipairs(legs) do
        if math.abs(leg.angle) <= RoadCenterline.LEG_STRAIGHT_DEG then
            info.straight = true
        elseif leg.angle > 0 then
            info.left = info.left + 1
        else
            info.right = info.right + 1
        end
    end
    return info
end

-- Does road carry on sideways from the point (px, pz), well beyond the scan window? A stub of dirt a few metres long
-- beside a track (a turning spot, a worn patch, a gate) does not: only a real side road does. `side` is +1 for the
-- geometry's left. Looks at 3 distances out, over a stretch of 18 m along the line (a branch leaves at an angle).
RoadCenterline.STUB_OUT = { 9.0, 11.5, 14.0 }
RoadCenterline.STUB_ALONG = { -6, -3, 0, 3, 6, 9, 12 }
local function sideExtends(sample, px, pz, dx, dz, side, options)
    local out = options.stubOut or RoadCenterline.STUB_OUT
    local nx, nz = -dz * side, dx * side
    for _, distance in ipairs(out) do
        for _, along in ipairs(options.stubAlong or RoadCenterline.STUB_ALONG) do
            if (sample(px + nx * distance + dx * along, pz + nz * distance + dz * along) or 0) > 0 then
                return true
            end
        end
    end
    return false
end

-- A wide stretch of "road" on a scan line (a road with gravel shoulders that the map pictures also call road, a clearing): the
-- core of it, where the road paint itself is (stone), found with `core(x, z)` (true on the road paint, read from the terrain
-- at that exact point). The core nearest the line is the road; the shoulders beside it are not its middle.
RoadCenterline.CORE_MIN_WIDTH = 2.0
local function coreRun(core, cx, cz, dx, dz, halfWidth, spacing)
    local classes, count = RoadCenterline.scanClasses(function(x, z) return core(x, z) and 2 or 0 end, cx, cz, dx, dz, halfWidth, spacing)
    local runs = RoadCenterline.runsFromClasses(classes, count, spacing, 1)
    local pick = chooseRun(runs)
    if pick ~= nil and pick.width >= RoadCenterline.CORE_MIN_WIDTH then
        pick.class = 2
        pick.core = true
        return pick
    end
    return nil
end

-- The real edges of the run the picture found: the pictures are made of 2 m cells that were closed, filled and curve-fitted, so
-- their edges are ragged and often a metre or two outside the real track, and the middle of such a run jumps about from row
-- to row. `fine(x, z)` is true on solid driving ground at that exact point (read from the terrain); inside the picture's run
-- (a little padded) the stretch of it nearest the line is the track, found to about 0.25 m. Stretches with a short gap (wheel
-- ruts and their hump) are joined as before.
RoadCenterline.FINE_SPACING = 0.5
RoadCenterline.FINE_PAD = 1.5
RoadCenterline.FINE_MIN_WIDTH = 1.5
local function fineRun(fine, sample, cx, cz, dx, dz, run)
    local nx, nz = -dz, dx
    local step = RoadCenterline.FINE_SPACING
    local lo, hi = run.from - RoadCenterline.FINE_PAD, run.to + RoadCenterline.FINE_PAD
    local found, current = {}, nil
    local t = lo
    while t <= hi + 1e-9 do
        local px, pz = cx + nx * t, cz + nz * t
        if fine(px, pz) and (sample(px, pz) or 0) > 0 then
            if current == nil then current = { from = t, to = t } else current.to = t end
        elseif current ~= nil then
            found[#found + 1] = current
            current = nil
        end
        t = t + step
    end
    if current ~= nil then found[#found + 1] = current end
    if #found == 0 then
        return nil
    end
    local merged = {}
    for _, r in ipairs(found) do
        local last = merged[#merged]
        if last ~= nil and (r.from - last.to - step) <= RoadCenterline.MERGE_GAP and (r.to - last.from + step) <= RoadCenterline.MERGE_MAX_WIDTH then
            last.to = r.to
        else
            merged[#merged + 1] = r
        end
    end
    local best, bestD = nil, math.huge
    for _, r in ipairs(merged) do
        r.centre = (r.from + r.to) * 0.5
        r.width = r.to - r.from + step
        local d = 0
        if 0 < r.from then d = r.from elseif 0 > r.to then d = -r.to end
        if d < bestD or (d == bestD and best ~= nil and math.abs(r.centre) < math.abs(best.centre)) then
            best, bestD = r, d
        end
    end
    if best == nil or best.width < RoadCenterline.FINE_MIN_WIDTH or bestD > math.max(3.0, run.width * 0.5) then
        return nil
    end
    best.class = run.class
    best.fine = true
    return best
end

-- Is there road further on, straight ahead of the point (px, pz) heading (dx, dz), after a stretch with none (the road crossed
-- another road and carries on beyond it, maybe a little to one side)? Looks 4 to 24 m ahead, 9 m to each side. Returns the
-- distance and the sideways offset of the nearest stretch of road, or nil.
RoadCenterline.AHEAD_DISTANCES = { 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24 }
local function roadAhead(sample, px, pz, dx, dz)
    local nx, nz = -dz, dx
    for _, distance in ipairs(RoadCenterline.AHEAD_DISTANCES) do
        local cx, cz = px + dx * distance, pz + dz * distance
        local best, run = nil, 0
        for t = -9, 9 do
            if (sample(cx + nx * t, cz + nz * t) or 0) > 0 then
                run = run + 1
                if run >= 2 and (best == nil or math.abs(t - 0.5) < math.abs(best)) then
                    best = t - 0.5
                end
            else
                run = 0
            end
        end
        if best ~= nil then
            return distance, best
        end
    end
    return nil
end

function RoadCenterline.scan(sample, x, z, dx, dz, options)
    options = options or {}
    local step = options.step or RoadCenterline.STEP
    local steps = options.steps or RoadCenterline.STEPS
    local intent = options.intent
    -- reach (metres) asks for a line that long: fine steps near the vehicle, coarser ones beyond
    local reach = options.reach
    local nearRange = options.nearRange or RoadCenterline.NEAR_RANGE
    local farStep = options.farStep or RoadCenterline.FAR_STEP
    local halfWidth = options.halfWidth or RoadCenterline.HALF_WIDTH
    local spacing = options.spacing or RoadCenterline.SAMPLE_SPACING
    local maxWidth = options.maxRoadWidth or RoadCenterline.MAX_ROAD_WIDTH
    local maxShift = options.maxShift or RoadCenterline.MAX_SHIFT
    local smoothing = options.smoothing or RoadCenterline.DIRECTION_SMOOTHING

    dx, dz = normalize(dx, dz)
    local result = { valid = false, points = {}, found = 0, ends = false, junction = false }

    local startHalfWidth = options.startHalfWidth or RoadCenterline.START_HALF_WIDTH
    local runs = runsOnLine(sample, x, z, dx, dz, startHalfWidth, spacing)
    local run = chooseRun(runs)
    if run ~= nil and options.fine ~= nil then
        run = fineRun(options.fine, sample, x, z, dx, dz, run) or run
    end
    if run ~= nil and options.core ~= nil and not run.fine
        and (run.width > maxWidth * 0.7 or run.from <= -startHalfWidth + spacing or run.to >= startHalfWidth - spacing) then
        run = coreRun(options.core, x, z, dx, dz, startHalfWidth + 4, spacing) or run
    end
    if run == nil then
        result.reason = "no road here"
        return result
    end
    -- a vehicle standing off the road still has to be near it
    local nearLimit = run.core and 6.0 or 3.0                      -- (beside the stone core, on the shoulder, is still on the road)
    if 0 < run.from and run.from > nearLimit or 0 > run.to and -run.to > nearLimit then
        result.reason = "too far from the road"
        return result
    end
    result.valid = true
    local startShift, startOpen = aimOf(run, startHalfWidth, spacing, maxWidth, math.huge)
    result.offset = startShift
    result.roadWidth = run.width
    result.openGround = startOpen

    local nx, nz = -dz, dx
    local px, pz = x + nx * startShift, z + nz * startShift
    result.points[1] = { px, pz }
    result.found = 1
    if options.rows then
        -- (debug) every scan row: where it was, which way it looked, what it found
        result.rows = { { x = x, z = z, dx = dx, dz = dz, from = run.from, to = run.to, class = run.class, core = run.core, centre = run.centre } }
    end

    -- what the road looks like across the line: its width and where its edges are (relative to the
    -- line). A run that is suddenly wider is a junction: one edge carries on, the other jumps out.
    local expectedWidth = RoadCenterline.DEFAULT_ROAD_WIDTH
    local expFrom, expTo = nil, nil
    if not startOpen and run.width <= maxWidth then
        expectedWidth = run.width
        expFrom, expTo = run.from - startShift, run.to - startShift
    end

    local maxGap = options.maxGap or RoadCenterline.MAX_GAP
    local trailGap = options.trailMaxGap or RoadCenterline.TRAIL_MAX_GAP
    local sawRoad = run.class == 2
    local missedLength = 0
    local travelled = 0
    local iterations = 0
    local limit = reach or (steps * step)
    local limitReach = limit
    local turnPlanned = false
    local reacquireUntil = nil      -- the road was lost at a crossing but found again ahead: searching wide for it until this far
    local gapAllow = nil            -- ... and the gap to it that may be bridged
    local lastWidened = nil         -- how far along the line the road last widened (a possible junction)
    local junctionInfo = nil        -- the legs of the junction met there (ring scan), summarised
    local function legsHere(atX, atZ, atDx, atDz)
        if junctionInfo == nil or travelled - junctionInfo.at > RoadCenterline.CORNER_CLUSTER then
            local legs, open = junctionLegs(sample, atX, atZ, atDx, atDz, options)
            junctionInfo = legSummary(legs)
            junctionInfo.open = open
            junctionInfo.at = travelled
        end
        return junctionInfo
    end
    local forkAt = nil              -- where the road first opened to both sides
    local lastOpen = nil            -- how far along the line open ground (a junction, a crossing road) was last met
    local cornerPlan = nil          -- a turn into the one side that opened, kept in case the road turns out not to go straight on
    while travelled < limit - 1e-6 and iterations < 200 do
        iterations = iterations + 1
        local stepNow = step
        if reach ~= nil and travelled >= nearRange then
            stepNow = farStep
        end
        -- predicted next middle, then look across the road there
        local qx, qz = px + dx * stepNow, pz + dz * stepNow
        local ahead = runsOnLine(sample, qx, qz, dx, dz, halfWidth, spacing)
        local next = chooseRun(ahead)
        if next ~= nil and options.fine ~= nil then
            local fineOne = fineRun(options.fine, sample, qx, qz, dx, dz, next)
            if fineOne ~= nil then
                next = fineOne
                ahead = { fineOne }
            end
        end
        if next ~= nil and options.core ~= nil and not next.fine
            and (next.width > maxWidth * 0.7 or next.from <= -halfWidth + spacing or next.to >= halfWidth - spacing) then
            -- wide: the road paint's own stretch is the road (see coreRun)
            local coreOne = coreRun(options.core, qx, qz, dx, dz, halfWidth, spacing)
            if coreOne ~= nil then
                next = coreOne
                ahead = { coreOne }
            end
        end
        if options.rows and next ~= nil then
            result.rows[#result.rows + 1] = { x = qx, z = qz, dx = dx, dz = dz, from = next.from, to = next.to, class = next.class, core = next.core, centre = next.centre }
        end
        -- just past open ground (a road crossed) the road carries on, but maybe not exactly in line: look wider for it
        local reacquiring = (lastOpen ~= nil and travelled - lastOpen <= RoadCenterline.REACQUIRE_RANGE)
            or (reacquireUntil ~= nil and travelled <= reacquireUntil)
        local tolerance = reacquiring and (halfWidth - 1.0) or maxShift
        local found = next ~= nil and not ((0 < next.from and next.from > tolerance) or (0 > next.to and -next.to > tolerance))
        if found then
            missedLength = 0
            if next.class == 2 then
                sawRoad = true
            end
            if #ahead > 1 then
                for _, other in ipairs(ahead) do
                    if other ~= next then
                        local gapBetween = other.from > next.to and (other.from - next.to) or (next.from - other.to)
                        if gapBetween >= RoadCenterline.JUNCTION_RUN_GAP then
                            result.junction = true
                        end
                    end
                end
            end
            -- (junctionAt: how far along the line the first junction or open ground was met, set below)
            local shift, open
            -- a run that reaches the edge of the scan window is cut off by it: it is wider than it looks
            local touchesEdge = next.from <= -halfWidth + spacing or next.to >= halfWidth - spacing
            -- with a turn signal on, the road opening towards that side by even a little is the junction to take
            local signalOpened = expFrom ~= nil and ((intent == "left" and (next.to - expTo) > RoadCenterline.OPEN_JUMP)
                or (intent == "right" and (expFrom - next.from) > RoadCenterline.OPEN_JUMP))
            -- the road beyond a crossing, found again: steer for it, it is not a new junction
            if next.from <= -halfWidth + spacing and next.to >= halfWidth - spacing then
                lastOpen = travelled               -- a road across the line: whatever is beyond it may be a little off to the side
                if result.crossingAt == nil then
                    result.crossingAt = travelled + stepNow      -- where a road crosses the line (the run spans the whole scan window)
                end
            end
            local reacquireNow = reacquiring and next.width <= maxWidth and lastOpen ~= travelled
            local widened = expFrom ~= nil and not reacquireNow and (next.width > expectedWidth + RoadCenterline.WIDEN_MARGIN or touchesEdge or signalOpened)
            if widened then
                lastWidened = travelled
                -- a junction: do not chase the middle of the widened run (that drifts into the side
                -- road). The edge that carried on is the reference: keep the same distance from it
                -- and go straight; with a turn signal on that side, follow the opening instead.
                local leftOpened = (next.to - expTo) > RoadCenterline.OPEN_JUMP
                local rightOpened = (expFrom - next.from) > RoadCenterline.OPEN_JUMP
                -- an opening only counts as a junction when road really goes on sideways: a stub is not one (the line still holds
                -- its edge and goes straight on past it, as for a junction)
                local leftReal = leftOpened and sideExtends(sample, px, pz, dx, dz, 1, options)
                local rightReal = rightOpened and sideExtends(sample, px, pz, dx, dz, -1, options)
                if leftReal or rightReal or (intent ~= nil and (leftOpened or rightOpened)) then
                    result.junction = true
                end
                if leftReal and rightReal and forkAt == nil then
                    forkAt = travelled + stepNow          -- the road opens to both sides here: a fork, if nothing goes straight on after it
                end
                local limit = maxShift * stepNow / step
                -- a turn signal on the side that opened: plan the whole turn
                local turnSide = nil
                if intent == "left" and leftOpened then
                    turnSide = 1
                elseif intent == "right" and rightOpened then
                    turnSide = -1
                end
                local planned, plannedEnds, plannedDeg = nil, nil, nil
                if turnSide ~= nil then
                    planned, plannedEnds, plannedDeg = planTurn(sample, result.points, px, pz, dx, dz, turnSide, expectedWidth, limitReach, options)
                elseif intent == nil and not options.noCorner and leftOpened ~= rightOpened
                    and (cornerPlan == nil or travelled - cornerPlan.travelled > RoadCenterline.CORNER_CLUSTER)
                    and not sideExtends(sample, px, pz, dx, dz, leftOpened and -1 or 1, options)       -- (the road going the other way too is a T, not a bend)
                    and (function()
                        local info = legsHere(px, pz, dx, dz)
                        -- a bend has ONE way on (a leg to a side and nothing straight on); a junction has more
                        return not info.straight and info.left + info.right == 1
                    end)() then
                    -- no signal, a road opening on one side only: if nothing goes straight on after it, this is a
                    -- bend (an L, not a junction) and the road itself turns there
                    local cp, cends, cdeg, cleg = planTurn(sample, result.points, px, pz, dx, dz, leftOpened and 1 or -1, expectedWidth, limitReach, options)
                    -- a leg much wider than the road we are on is another road crossing it, not the same road bending
                    if cp ~= nil and (cleg or 0) <= expectedWidth * 1.6 + 1.0 then
                        cornerPlan = { points = cp, ends = cends == true, travelled = travelled, deg = cdeg }
                    end
                end
                if planned ~= nil then
                    result.points = planned
                    result.found = #planned
                    result.turned = true
                    result.turnDeg = plannedDeg
                    result.ends = plannedEnds == true
                    turnPlanned = true
                    break
                end
                if leftOpened and rightOpened then
                    shift = 0
                elseif leftOpened then
                    shift = math.max(-limit, math.min(limit, next.from - expFrom))
                elseif rightOpened then
                    shift = math.max(-limit, math.min(limit, next.to - expTo))
                else
                    shift = 0
                end
                -- the expected edges stay those of the road, seen from the new position
                expFrom, expTo = expFrom - shift, expTo - shift
            else
                -- open ground: keep the line, do not chase the middle of a yard
                local shiftLimit = maxShift * stepNow / step
                if reacquireNow then
                    -- steering for the road beyond a crossing: gently
                    shiftLimit = RoadCenterline.REACQUIRE_SHIFT * stepNow
                    shift, open = math.max(-shiftLimit, math.min(shiftLimit, next.centre)), false
                else
                    shift, open = aimOf(next, halfWidth, spacing, maxWidth, shiftLimit)
                end
                if open then
                    result.junction = true
                elseif expFrom ~= nil or next.width <= maxWidth then
                    expectedWidth = expFrom ~= nil and (expectedWidth * 0.9 + next.width * 0.1) or next.width
                    expFrom, expTo = next.from - shift, next.to - shift
                end
            end
            local anx, anz = -dz, dx
            local cx, cz = qx + anx * shift, qz + anz * shift

            local ndx, ndz = normalize(cx - px, cz - pz)
            dx, dz = normalize(dx * smoothing + ndx * (1 - smoothing), dz * smoothing + ndz * (1 - smoothing))
            px, pz = cx, cz
            result.points[#result.points + 1] = { px, pz }
            result.found = result.found + 1
            if result.junction and result.junctionAt == nil then
                result.junctionAt = travelled + stepNow
            end
        else
            -- the road does not go straight on, and a road opened on one side just before: a bend, taken as one
            if cornerPlan ~= nil and missedLength == 0 and travelled - cornerPlan.travelled <= RoadCenterline.CORNER_REACH then
                result.points = cornerPlan.points
                result.found = #cornerPlan.points
                result.turned = true
                result.corner = true
                result.turnDeg = cornerPlan.deg
                result.ends = cornerPlan.ends
                turnPlanned = true
                break
            end
            -- before this is a bend or a fork: is there road straight on, beyond a crossing? Then it carries on.
            if missedLength == 0 and not options.noCorner and (lastWidened ~= nil or forkAt ~= nil or cornerPlan ~= nil)
                and (lastWidened or forkAt or cornerPlan.travelled) and travelled - (lastWidened or forkAt or cornerPlan.travelled) <= RoadCenterline.CORNER_REACH then
                local distanceAhead = roadAhead(sample, px, pz, dx, dz)
                if distanceAhead ~= nil then
                    gapAllow = distanceAhead + 3
                    reacquireUntil = travelled + distanceAhead + 14
                    cornerPlan, forkAt = nil, nil
                end
            end
            -- nothing goes straight on after a place where the road opened to both sides: a fork (a Y). Like a T it is
            -- a place to wait at, not to drive on into the grass. (Roads on both sides of the line at the miss are a
            -- fork too, even when the branches left so fast that no widening was seen.)
            if missedLength == 0 and result.crossingAt == nil and cornerPlan == nil then
                local hasLeft, hasRight = false, false
                for _, r in ipairs(ahead) do
                    if r.from > 0.5 then hasLeft = true elseif r.to < -0.5 then hasRight = true end
                end
                local info = legsHere(px, pz, dx, dz)
                if (not info.straight and info.left >= 1 and info.right >= 1)
                    or (forkAt ~= nil and travelled - forkAt <= RoadCenterline.CORNER_REACH and not info.straight) then
                    result.crossingAt = forkAt or (travelled + stepNow)
                    result.fork = true
                end
            end
            -- with a turn signal on, and nothing straight on: take the branch that way
            if intent ~= nil and not options.noCorner and missedLength == 0 and not turnPlanned and (result.fork or #ahead > 0) then
                local planned, plannedEnds, plannedDeg = planTurn(sample, result.points, px, pz, dx, dz, intent == "left" and 1 or -1, expectedWidth, limitReach, options)
                if planned ~= nil then
                    result.points = planned
                    result.found = #planned
                    result.turned = true
                    result.turnDeg = plannedDeg
                    result.ends = plannedEnds == true
                    result.crossingAt, result.fork = nil, nil
                    turnPlanned = true
                    break
                end
            end
            -- a short hole in the map data (a chunk edge, a bridge) is crossed in a straight line;
            -- if the road does not come back the bridged points are dropped again below
            missedLength = missedLength + stepNow
            if missedLength > math.max(gapAllow or 0, (sawRoad and maxGap or math.max(maxGap, trailGap))) + 1e-6 then
                -- (the line is read further than it is trusted: losing the road far out is just the end of what can be read,
                -- not a road that ends there, and must not make the vehicle brake for an end)
                if travelled <= (options.trustedReach or math.huge) then
                    result.ends = true
                end
                break
            end
            px, pz = qx, qz
            result.points[#result.points + 1] = { px, pz, bridged = true }
        end
        travelled = travelled + stepNow
    end
    -- trailing bridged points led nowhere: the road ended before them
    while not turnPlanned and #result.points > 1 and result.points[#result.points].bridged do
        result.points[#result.points] = nil
        if travelled <= (options.trustedReach or math.huge) then
            result.ends = true
        end
    end
    return result
end

-- ===== following a stored path =====
-- `store` is WAILA's path store (findNear(x, z, radius) -> hits { path, id, distance, x, z, dx, dz,
-- index }). Where a path runs near the vehicle in the vehicle's direction, the centre-line ahead is
-- that path itself, no guessing from pixels: this is the same kind of result RoadCenterline.scan gives
-- (points, ends, offset ...), with mode = "path".
RoadCenterline.STICK_RADIUS = 9.0             -- while turning, the path the turn started on is kept within this distance ...
RoadCenterline.STICK_MIN_ALIGN = 0.3          -- ... as long as the vehicle's heading is within about 72 degrees of it
RoadCenterline.ON_PATH_DISTANCE = 3.0         -- a path this close that runs our way is the one we are on
RoadCenterline.BACKWARD_PENALTY = 5.0         -- metres of extra distance for driving a path against its own direction (lane splines: the one running our way wins)
RoadCenterline.PATH_SEARCH_RADIUS = 6.0
RoadCenterline.PATH_MIN_ALIGN = 0.6          -- cos of the largest angle between vehicle and path (about 53 degrees)
RoadCenterline.PATH_SPACING = 2.0            -- metres between the points of the line
RoadCenterline.TURN_JOIN_RADIUS = 8.0         -- ... but a turn may take a road that passes this near the end of the one we are on (the far lane of the road we meet)
RoadCenterline.TURN_BACKWARD_PENALTY = 12.0   -- metres of extra distance for turning onto a lane against its drawn direction: keep to the traffic side (right turn: near lane, left turn: far lane)
RoadCenterline.PATH_JOIN_RADIUS = 4.0        -- paths whose ends meet within this are one road
RoadCenterline.PATH_JOIN_ALIGN = 0.8
RoadCenterline.PATH_MAX_JOINS = 8

-- Walks from a point on `path` (segment `index`) forward or backward along its points, collecting
-- vertices in travel order until `distance` metres are covered. Returns the vertices and the
-- distance really covered.
local function collectVertices(path, index, startX, startZ, forward, distance)
    local vertices = { { startX, startZ } }
    local covered = 0
    local lastX, lastZ = startX, startZ
    local i = forward and index + 1 or index
    local step = forward and 1 or -1
    while i >= 1 and i <= #path.points and covered < distance do
        local p = path.points[i]
        local dx, dz = p[1] - lastX, p[2] - lastZ
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 1e-6 then
            local remaining = distance - covered
            if d > remaining then
                -- the last segment is cut where the asked-for distance ends
                local f = remaining / d
                vertices[#vertices + 1] = { lastX + dx * f, lastZ + dz * f }
                covered = distance
                break
            end
            vertices[#vertices + 1] = { p[1], p[2] }
            covered = covered + d
            lastX, lastZ = p[1], p[2]
        end
        i = i + step
    end
    return vertices, covered
end

-- ===== junctions =====
-- A branch is judged by where it ENDS UP heading (over JUNCTION_BASELINE metres), not by how its first
-- metres line up: a side road leaves the main road tangentially, so at its very start it points the
-- same way as the road it leaves. By default the vehicle goes straight on; a turn intent ("left" /
-- "right", the turn signal) picks the branch that turns that way instead.
RoadCenterline.JUNCTION_BASELINE = 15.0   -- metres a branch is judged over
RoadCenterline.JUNCTION_GAP = 14.0        -- paths that end this close across an intersection are one road
RoadCenterline.STRAIGHT_MAX_DEG = 30      -- "straight on" allows this much
RoadCenterline.TURN_MIN_DEG = 12          -- a turn is at least this much ...
RoadCenterline.TURN_MAX_DEG = 115         -- ... and at most this much
RoadCenterline.TURN_PREFERRED_DEG = 60
RoadCenterline.DEGREE_COST = 0.3          -- metres of distance that one degree of divergence is worth
RoadCenterline.BRANCH_RADIUS = 3.5        -- a side road starting this close to the line leaves it there
RoadCenterline.BRANCH_SPACING = 4.0       -- ... looked for every this many metres along the line (turn intents only)
RoadCenterline.ENDPOINT_TOLERANCE = 3.0   -- "at the start / end of a path" means within this

local pathLengthCache = setmetatable({}, { __mode = "k" })
local function pathLength(path)
    local cached = pathLengthCache[path]
    if cached ~= nil and cached.count == #path.points then
        return cached.length
    end
    local total = 0
    for i = 2, #path.points do
        total = total + math.sqrt((path.points[i][1] - path.points[i - 1][1]) ^ 2 + (path.points[i][2] - path.points[i - 1][2]) ^ 2)
    end
    pathLengthCache[path] = { count = #path.points, length = total }
    return total
end

-- + when (vx, vz) points to the left of (rx, rz), in degrees
local function signedAngleDeg(rx, rz, vx, vz)
    return math.deg(math.atan2(rx * vz - rz * vx, rx * vx + rz * vz))
end

-- Unit direction a path takes over the next `baseline` metres from a point on it, or nil.
local function directionOver(path, index, px, pz, forward, baseline)
    local vertices = collectVertices(path, index, px, pz, forward, baseline)
    if #vertices < 2 then
        return nil
    end
    local last = vertices[#vertices]
    local ux, uz = last[1] - px, last[2] - pz
    local length = math.sqrt(ux * ux + uz * uz)
    if length < 1e-6 then
        return nil
    end
    return ux / length, uz / length
end

-- Chooses among candidates { theta (degrees, + left, against the current direction), cost (metres) }.
-- Straight (no intent): the straightest, within `straightLimit` degrees. A turn intent: the nearest
-- branch that turns that way; when there is none, straight on (the intent stays for the next junction).
-- Returns the candidate and whether it is a turn, or nil.
local function chooseCandidate(candidates, intent, straightLimit, preferId)
    local best, bestScore = nil, math.huge
    if intent == "left" or intent == "right" then
        local sign = intent == "left" and 1 or -1
        -- the road an earlier scan of this same turn picked stays the one (else the pick flips between the lanes as the vehicle moves)
        if preferId ~= nil then
            for _, c in ipairs(candidates) do
                if c.hit.id == preferId and c.theta * sign >= RoadCenterline.TURN_MIN_DEG and c.theta * sign <= RoadCenterline.TURN_MAX_DEG then
                    return c, true
                end
            end
        end
        for _, c in ipairs(candidates) do
            local turn = c.theta * sign
            if turn >= RoadCenterline.TURN_MIN_DEG and turn <= RoadCenterline.TURN_MAX_DEG then
                local score = c.cost + RoadCenterline.DEGREE_COST * math.abs(turn - RoadCenterline.TURN_PREFERRED_DEG)
                if score < bestScore then
                    best, bestScore = c, score
                end
            end
        end
        if best ~= nil then
            return best, true
        end
    end
    for _, c in ipairs(candidates) do
        if math.abs(c.theta) <= straightLimit then
            local score = c.cost + RoadCenterline.DEGREE_COST * math.abs(c.theta)
            if score < bestScore then
                best, bestScore = c, score
            end
        end
    end
    return best, false
end

-- The path the vehicle is on or next to, among those running its way. Judged by direction over the
-- next stretch, so that of two paths side by side the straight one wins over a branch that bends away.
local function pickInitial(store, x, z, dx, dz, radius, minAlign, intent, accept, stick)
    local candidates = {}
    -- turning at a junction: the path the turn started on stays THE path while the vehicle is still near it (it is cutting
    -- the corner or is half way round it), however far its heading has already turned away from it
    if stick ~= nil and stick.id ~= nil then
        for _, hit in ipairs(store.findNear(x, z, stick.radius or RoadCenterline.STICK_RADIUS)) do
            if hit.id == stick.id then
                local dot = hit.dx * dx + hit.dz * dz
                if math.abs(dot) >= RoadCenterline.STICK_MIN_ALIGN and (dot >= 0 or not hit.path.oneWay) then
                    return { hit = hit, forward = dot >= 0, turned = false, stuck = true }
                end
            end
        end
    end
    for _, hit in ipairs(store.findNear(x, z, radius)) do
        if accept == nil or accept(hit) then
            local dot = hit.dx * dx + hit.dz * dz
            local forward = dot >= 0
            if math.abs(dot) >= minAlign and (forward or not hit.path.oneWay) then
                local ux, uz = directionOver(hit.path, hit.index, hit.x, hit.z, forward, RoadCenterline.JUNCTION_BASELINE)
                local theta = 0
                if ux ~= nil then
                    theta = signedAngleDeg(dx, dz, ux, uz)
                end
                candidates[#candidates + 1] = { hit = hit, forward = forward, theta = theta, cost = hit.distance + (forward and 0 or RoadCenterline.BACKWARD_PENALTY) }
            end
        end
    end
    if #candidates == 0 then
        return nil
    end
    -- one road to take: a curve of up to 60 degrees is still that road. Several (a junction): without a turn
    -- signal only one that really runs straight on counts, else the straightest of them; never one that is
    -- merely the nearest
    local ids = {}
    local distinct = 0
    for _, c in ipairs(candidates) do
        if not ids[c.hit.id] then
            ids[c.hit.id] = true
            distinct = distinct + 1
        end
    end
    -- a turn signal does not move the vehicle off the road it is on: while a path that runs its way is right under it
    -- (and nearer than the one the signal would pick), that is the path; the turn is taken further on, at the junction.
    -- Standing right at the junction, with both paths beside it, the signal decides.
    local limitDeg = distinct > 1 and RoadCenterline.STRAIGHT_MAX_DEG or 60
    local chosen, turned = chooseCandidate(candidates, intent, limitDeg)
    if turned and chosen ~= nil then
        for _, c in ipairs(candidates) do
            if c.cost <= RoadCenterline.ON_PATH_DISTANCE and math.abs(c.theta) <= RoadCenterline.STRAIGHT_MAX_DEG
                and c.cost + 1.0 < chosen.cost then
                chosen, turned = c, false
                break
            end
        end
    end
    if chosen == nil then
        chosen = candidates[1]
        for _, c in ipairs(candidates) do
            if math.abs(c.theta) < math.abs(chosen.theta) then chosen = c end
        end
    end
    return { hit = chosen.hit, forward = chosen.forward, turned = turned }
end

-- Paths that carry on from the point (px, pz) heading (ex, ez): they start or end within the gap, ahead,
-- and do not run into the one we are on. `sideways` limits how far to the side a straight-on path may be.
local function continuations(store, px, pz, ex, ez, usedIds, gap, midPathRadius)
    local found = {}
    for _, hit in ipairs(store.findNear(px, pz, gap)) do
        if not usedIds[hit.id] then
            local length = pathLength(hit.path)
            local atStart = hit.along <= RoadCenterline.ENDPOINT_TOLERANCE
            local atEnd = hit.along >= length - RoadCenterline.ENDPOINT_TOLERANCE
            -- the ways the candidate can be driven on from here: from its start, from its end (backwards), or,
            -- a road that passes right through the point (we meet it side-on), both ways: left and right
            local ways = {}
            if atStart and not atEnd then
                ways[1] = true
            elseif atEnd and not atStart then
                ways[1] = false
            elseif hit.distance <= midPathRadius then
                ways = { true, false }
            end
            for _, forward in ipairs(ways) do
                if forward or not hit.path.oneWay then
                    local ahead = (hit.x - px) * ex + (hit.z - pz) * ez
                    if ahead >= -1.5 then
                        local ux, uz = directionOver(hit.path, hit.index, hit.x, hit.z, forward, RoadCenterline.JUNCTION_BASELINE)
                        if ux ~= nil then
                            found[#found + 1] = {
                                hit = hit, forward = forward, theta = signedAngleDeg(ex, ez, ux, uz), cost = hit.distance + (forward and 0 or RoadCenterline.TURN_BACKWARD_PENALTY),
                                sideways = math.abs((hit.x - px) * (-ez) + (hit.z - pz) * ex),
                            }
                        end
                    end
                end
            end
        end
    end
    return found
end

function RoadCenterline.pathLine(store, x, z, dx, dz, options)
    options = options or {}
    local reach = options.reach or 24
    local spacing = options.spacing or RoadCenterline.PATH_SPACING
    local intent = options.intent
    dx, dz = normalize(dx, dz)

    local found = pickInitial(store, x, z, dx, dz, options.radius or RoadCenterline.PATH_SEARCH_RADIUS,
        options.minAlign or RoadCenterline.PATH_MIN_ALIGN, intent, nil, options.stickPath ~= nil and { id = options.stickPath } or nil)
    -- joining: no path right here, but one ahead that the vehicle is heading towards (or is close to)
    -- and that runs roughly the vehicle's way. The line then leaves the vehicle and eases onto the path.
    local capture = options.capture
    local capturing = false
    if found == nil and capture ~= nil then
        found = pickInitial(store, x, z, dx, dz, capture.radius, capture.minAlign or 0.4, intent, function(hit)
            local fx, fz = hit.x - x, hit.z - z
            local ahead = fx * dx + fz * dz
            if ahead < -2 then
                return false
            end
            if hit.distance > (capture.nearDistance or 8) then
                local closing = hit.distance > 1e-6 and ahead / hit.distance or 1
                if closing < (capture.minClosing or 0.08) then
                    return false
                end
            end
            return true
        end)
        capturing = found ~= nil
        if capturing then
            reach = math.max(reach, (capture.blendLength or 40) + 12)
        end
    end
    if found == nil then
        return { valid = false, points = {}, found = 0, ends = false, junction = false, reason = "no path here" }
    end

    local first = found.hit
    local vertices = { { first.x, first.z } }
    local covered = 0
    local current, forward, index, sx, sz = first.path, found.forward, first.index, first.x, first.z
    local usedIds = { [current.id] = true }
    local result = { valid = true, points = {}, found = 0, ends = false, junction = false, mode = "path",
        pathId = first.id, source = first.path.source, kind = first.path.kind, roadWidth = first.path.width, openGround = false,
        turned = found.turned == true, junctions = 0 }

    for join = 0, RoadCenterline.PATH_MAX_JOINS do
        local walked, length = collectVertices(current, index, sx, sz, forward, reach - covered)

        -- a turn intent: a side road that starts on this path ahead leaves it there
        local branch = nil
        if (intent == "left" or intent == "right") and #walked >= 2 then
            local along = 0
            local nextSample = RoadCenterline.BRANCH_SPACING
            for k = 2, #walked do
                local ax, az = walked[k - 1][1], walked[k - 1][2]
                local bx, bz = walked[k][1], walked[k][2]
                local segment = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
                local ex2, ez2 = normalize(bx - ax, bz - az)
                while branch == nil and nextSample <= along + segment do
                    local f = (nextSample - along) / segment
                    local qx, qz = ax + (bx - ax) * f, az + (bz - az) * f
                    local list = continuations(store, qx, qz, ex2, ez2, usedIds, RoadCenterline.BRANCH_RADIUS, 0)
                    local pick, turned = chooseCandidate(list, intent, -1, options.targetPath)
                    if pick ~= nil and turned and (pick.forward or pick.hit.id == options.targetPath) and (options.targetPath == nil or pick.hit.id == options.targetPath) then
                        branch = { cand = pick, atX = qx, atZ = qz, vertexCount = k - 1, distance = nextSample }
                    end
                    nextSample = nextSample + RoadCenterline.BRANCH_SPACING
                end
                if branch ~= nil then
                    break
                end
                along = along + segment
            end
        end
        if branch ~= nil then
            -- cut the walk at the branch point and carry on along the side road
            for k = 2, branch.vertexCount do
                vertices[#vertices + 1] = walked[k]
            end
            vertices[#vertices + 1] = { branch.atX, branch.atZ }
            covered = covered + branch.distance
            if covered >= reach then
                break
            end
            local cand = branch.cand
            current, forward, index = cand.hit.path, cand.forward, cand.hit.index
            sx, sz = cand.hit.x, cand.hit.z
            usedIds[current.id] = true
            result.turned = true
            result.targetPathId = result.targetPathId or current.id
            result.junctions = result.junctions + 1
            vertices[#vertices + 1] = { sx, sz }
        else
            for k = 2, #walked do
                vertices[#vertices + 1] = walked[k]
            end
            covered = covered + length
            if covered >= reach then
                break
            end
            -- the path ended: carry on with the path that continues from here (straight on, or the turn)
            local endX, endZ = walked[#walked][1], walked[#walked][2]
            local ex, ez
            if #walked >= 2 then
                ex, ez = endX - walked[#walked - 1][1], endZ - walked[#walked - 1][2]
            else
                ex, ez = dx, dz
            end
            ex, ez = normalize(ex, ez)
            local list = continuations(store, endX, endZ, ex, ez, usedIds, RoadCenterline.JUNCTION_GAP,
                (intent == "left" or intent == "right") and RoadCenterline.TURN_JOIN_RADIUS or RoadCenterline.PATH_JOIN_RADIUS)
            -- straight on must really be roughly in line; a turn may start further to the side
            local usable = {}
            for _, c in ipairs(list) do
                if c.sideways <= 6 or (c.sideways <= RoadCenterline.JUNCTION_GAP and math.abs(c.theta) > RoadCenterline.STRAIGHT_MAX_DEG) then
                    usable[#usable + 1] = c
                end
            end
            local pick, turned = chooseCandidate(usable, intent, RoadCenterline.STRAIGHT_MAX_DEG, options.targetPath)
            if pick == nil or join == RoadCenterline.PATH_MAX_JOINS then
                result.ends = true
                -- the path ends at a road it meets side-on (a T): nothing runs straight on, but there is a way
                -- to turn. junctionAt: how far (metres along the line) the crossing is.
                if pick == nil then
                    for _, other in ipairs(store.findNear(endX, endZ, RoadCenterline.JUNCTION_GAP)) do
                        if not usedIds[other.id] then
                            result.junctionEnd = true
                            result.junctionAt = covered
                            break
                        end
                    end
                end
                break
            end
            if turned then
                result.turned = true
                result.targetPathId = result.targetPathId or pick.hit.path.id
            end
            result.junctions = result.junctions + 1
            current, forward, index = pick.hit.path, pick.forward, pick.hit.index
            sx, sz = pick.hit.x, pick.hit.z
            usedIds[current.id] = true
            -- across an intersection the line crosses the gap in a straight stretch
            vertices[#vertices + 1] = { sx, sz }
        end
    end

-- Sharp corners of a vertex list (a stem road ending side-on in a crossing road) replaced by an arc of
-- (up to) `radius` metres, so the line can be driven. The arc is limited by half the length of the
-- two segments at the corner. Returns a new list.
RoadCenterline.CORNER_MIN_DEG = 35
RoadCenterline.CORNER_RADIUS = 10.0
local function roundCorners(vertices, radius, minDeg)
    -- the same point twice (where one path hands over to the next) is no corner
    local clean = { vertices[1] }
    for i = 2, #vertices do
        local last = clean[#clean]
        if (vertices[i][1] - last[1]) ^ 2 + (vertices[i][2] - last[2]) ^ 2 > 1e-6 then
            clean[#clean + 1] = vertices[i]
        end
    end
    vertices = clean
    if #vertices < 3 then
        return vertices, 0
    end
    -- which vertices are corners, and how far each one is from the neighbouring corners (or the ends of the list):
    -- vertices in between that lie on a straight line do not shorten the stretch a corner has to round into
    local count = #vertices
    local lengthTo = { 0 }                      -- distance along the list
    local turnAt = {}
    for i = 2, count do
        lengthTo[i] = lengthTo[i - 1] + math.sqrt((vertices[i][1] - vertices[i - 1][1]) ^ 2 + (vertices[i][2] - vertices[i - 1][2]) ^ 2)
    end
    local corners = {}
    for k = 2, count - 1 do
        local a, c, b = vertices[k - 1], vertices[k], vertices[k + 1]
        local ux, uz, vx, vz = c[1] - a[1], c[2] - a[2], b[1] - c[1], b[2] - c[2]
        local lu, lv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
        if lu > 1e-6 and lv > 1e-6 then
            local turn = math.atan2((ux / lu) * (vz / lv) - (uz / lu) * (vx / lv), (ux / lu) * (vx / lv) + (uz / lu) * (vz / lv))
            turnAt[k] = turn
            if math.deg(math.abs(turn)) >= minDeg and math.deg(math.abs(turn)) <= 150 then
                corners[#corners + 1] = k
            end
        end
    end
    local isCorner = {}
    for _, k in ipairs(corners) do isCorner[k] = true end
    local out = { vertices[1] }
    local sharpest = 0
    for k = 2, count - 1 do
        if not isCorner[k] then
            out[#out + 1] = vertices[k]
        else
            local c = vertices[k]
            local turn = turnAt[k]
            local phi = math.abs(turn)
            sharpest = math.max(sharpest, math.deg(phi))
            -- room before and after: to the previous / next corner (half of it, shared) or the end of the list (all of it)
            local before, after = lengthTo[k], lengthTo[count] - lengthTo[k]
            for j = k - 1, 2, -1 do
                if isCorner[j] then before = (lengthTo[k] - lengthTo[j]) * 0.5 break end
            end
            for j = k + 1, count - 1 do
                if isCorner[j] then after = (lengthTo[j] - lengthTo[k]) * 0.5 break end
            end
            local a, b = vertices[k - 1], vertices[k + 1]
            local ux, uz = c[1] - a[1], c[2] - a[2]
            local vx, vz = b[1] - c[1], b[2] - c[2]
            local lu, lv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
            ux, uz, vx, vz = ux / lu, uz / lu, vx / lv, vz / lv
            local t = math.min(radius * math.tan(phi / 2), before, after)
            local r = t / math.tan(phi / 2)
            -- the arc starts t before the corner along the incoming direction: the incoming stretch may be built of several
            -- collinear vertices, so the arc start can lie before the previous vertex: cut those away
            local sx, sz = c[1] - ux * t, c[2] - uz * t
            while #out > 1 do
                -- drop earlier vertices that are beyond the arc's start along the incoming direction
                local last = out[#out]
                if (c[1] - last[1]) * ux + (c[2] - last[2]) * uz < t - 1e-6 and last ~= vertices[1] then
                    out[#out] = nil
                else
                    break
                end
            end
            local side = turn > 0 and 1 or -1
            local cx, cz = sx + (-uz) * side * r, sz + ux * side * r
            local a0 = math.atan2(sz - cz, sx - cx)
            local steps = math.max(2, math.ceil(math.deg(phi) / 15))
            for i = 0, steps do
                local ang = a0 + side * phi * i / steps
                out[#out + 1] = { cx + r * math.cos(ang), cz + r * math.sin(ang) }
            end
        end
    end
    out[#out + 1] = vertices[#vertices]
    return out, sharpest
end

    -- A corner is rounded with an arc whose size depends on the stretches either side of it. The list starts at the vehicle,
    -- so without more road BEHIND it the stretch before the first corner would shrink as the vehicle drives up to it, and the
    -- arc would tighten to nothing: the road behind (on the first path) is added for the rounding and cut off again.
    local backVertices = collectVertices(first.path, first.index, first.x, first.z, not found.forward, RoadCenterline.CORNER_RADIUS * 2.5)
    local prefix = {}
    for k = #backVertices, 2, -1 do
        prefix[#prefix + 1] = backVertices[k]
    end
    local startVertex = vertices[1]
    local withBack = {}
    for _, v in ipairs(prefix) do withBack[#withBack + 1] = v end
    for _, v in ipairs(vertices) do withBack[#withBack + 1] = v end
    local rounded
    rounded, result.sharpestCorner = roundCorners(withBack, RoadCenterline.CORNER_RADIUS, RoadCenterline.CORNER_MIN_DEG)
    result.corner = (result.sharpestCorner or 0) >= 60
    if result.turned then
        result.turnDeg = result.sharpestCorner
    end
    -- cut at the vehicle's own place on the rounded line: its nearest point
    local bestI, bestD, bestX, bestZ = 1, math.huge, rounded[1][1], rounded[1][2]
    for k = 1, #rounded - 1 do
        local ax, az, bx, bz = rounded[k][1], rounded[k][2], rounded[k + 1][1], rounded[k + 1][2]
        local sx, sz = bx - ax, bz - az
        local lengthSq = sx * sx + sz * sz
        local t = lengthSq > 1e-9 and math.max(0, math.min(1, ((startVertex[1] - ax) * sx + (startVertex[2] - az) * sz) / lengthSq)) or 0
        local cx, cz = ax + sx * t, az + sz * t
        local d = (cx - startVertex[1]) ^ 2 + (cz - startVertex[2]) ^ 2
        if d < bestD then
            bestI, bestD, bestX, bestZ = k, d, cx, cz
        end
    end
    vertices = { { bestX, bestZ } }
    for k = bestI + 1, #rounded do
        vertices[#vertices + 1] = rounded[k]
    end
    -- resample the vertices every `spacing` metres
    local points = { { vertices[1][1], vertices[1][2] } }
    local carry = 0
    for i = 2, #vertices do
        local ax, az = vertices[i - 1][1], vertices[i - 1][2]
        local bx, bz = vertices[i][1], vertices[i][2]
        local segment = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
        local position = spacing - carry
        while position <= segment do
            local f = position / segment
            points[#points + 1] = { ax + (bx - ax) * f, az + (bz - az) * f }
            position = position + spacing
        end
        carry = segment - (position - spacing)
    end
    local last = vertices[#vertices]
    local tail = points[#points]
    if (last[1] - tail[1]) ^ 2 + (last[2] - tail[2]) ^ 2 > 0.25 then
        points[#points + 1] = { last[1], last[2] }
    end

    -- the lane: keep this far to the right of the path's line, in the direction of travel
    local laneOffset = options.laneOffset or 0
    if laneOffset ~= 0 and #points >= 2 then
        local shifted = {}
        for i = 1, #points do
            local a = points[math.max(1, i - 1)]
            local b = points[math.min(#points, i + 1)]
            local tx, tz = normalize(b[1] - a[1], b[2] - a[2])
            shifted[i] = { points[i][1] + tz * laneOffset, points[i][2] - tx * laneOffset }
        end
        points = shifted
    end
    -- joining: start at the vehicle and ease onto the path over `blendLength` metres (smoothstep), so the
    -- line is one steerable curve, and its curvature tells how slowly the join has to be taken
    if capturing then
        local blendLength = capture.blendLength or 40
        local vx, vz = x - points[1][1], z - points[1][2]
        local along = 0
        for i = 1, #points do
            if i > 1 then
                along = along + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
            end
            local t = math.min(1, along / blendLength)
            local weight = 1 - t * t * (3 - 2 * t)
            points[i] = { points[i][1] + vx * weight, points[i][2] + vz * weight }
        end
        result.capturing = true
        result.blendLength = blendLength
    end
    result.points = points
    result.found = #points
    -- sideways position of the vehicle against the path: + when the path is on the vehicle's left
    -- measured to where the vehicle is on the line it will follow (on a rounded corner that is the arc, not the path's own
    -- vertex); the line is already shifted by the lane offset
    if result.points ~= nil and #result.points >= 1 and not capturing then
        result.offset = (result.points[1][1] - x) * (-dz) + (result.points[1][2] - z) * dx
    else
        result.offset = (first.x - x) * (-dz) + (first.z - z) * dx - laneOffset
    end
    return result
end

-- ===== steering along the line in one go =====
-- The curvature to steer with, from the line in the vehicle's own frame (x to the left, z forward; the first point near
-- the vehicle): what the line itself needs a moment from now (feed-forward: on a bend the wheels go straight to the bend's
-- curvature and stay there) plus a small correction for being off the line or pointing away from it. On the line and
-- along it the correction is zero, so a bend is steered once, not chased with an aim point that sees it late.
-- Returns kappa (+ = to the left, 1/m) and a table of the parts.
RoadCenterline.STEER_LEAD_SECONDS = 0.3     -- the wheels act a moment after they are turned: look this far ahead along the line
RoadCenterline.STEER_LEAD_MIN = 1.5
RoadCenterline.STEER_BASE = 3.0              -- metres either side of the look-ahead point over which the bend is measured
RoadCenterline.STEER_FB_MIN = 7.0            -- correction distance: how far ahead an error is taken out
RoadCenterline.STEER_FB_SECONDS = 1.4
RoadCenterline.STEER_FB_MAX = 0.12
RoadCenterline.STEER_DEADBAND = 0.2           -- a lateral error under this (metres) is not corrected: a person does not either, and a stiff correction of every centimetre makes a heavy vehicle weave
RoadCenterline.STEER_HEADING_BASELINE = 2.0

local function polylineAt(points, cumulative, s)
    local n = #points
    if s <= 0 then
        return points[1][1], points[1][2]
    end
    if s >= cumulative[n] then
        return nil
    end
    for i = 2, n do
        if cumulative[i] >= s then
            local f = (s - cumulative[i - 1]) / math.max(cumulative[i] - cumulative[i - 1], 1e-9)
            return points[i - 1][1] + (points[i][1] - points[i - 1][1]) * f, points[i - 1][2] + (points[i][2] - points[i - 1][2]) * f
        end
    end
    return nil
end

-- Least-squares parabola x = a + b z + c z^2 through the line's points ahead (in the vehicle's frame, 0 <= z <= zMax):
-- where the line is across the vehicle (a), the way it points (b) and how it bends (2 c), worked out once from a long stretch
-- instead of from the nearest few points, so pixel noise of a metre does not turn into steering. Returns a, b, c and the rms
-- residual, or nil when there are too few points.
function RoadCenterline.fitParabola(points, zMax)
    local sz0, sz1, sz2, sz3, sz4, sx0, sx1, sx2, count = 0, 0, 0, 0, 0, 0, 0, 0, 0
    for i = 1, #points do
        local x, z = points[i][1], points[i][2]
        if z >= -1.0 and z <= zMax then
            count = count + 1
            local z2 = z * z
            sz0 = sz0 + 1
            sz1 = sz1 + z
            sz2 = sz2 + z2
            sz3 = sz3 + z2 * z
            sz4 = sz4 + z2 * z2
            sx0 = sx0 + x
            sx1 = sx1 + x * z
            sx2 = sx2 + x * z2
        end
    end
    if count < 6 then
        return nil
    end
    -- normal equations of x = a + b z + c z^2
    local m = { { sz0, sz1, sz2, sx0 }, { sz1, sz2, sz3, sx1 }, { sz2, sz3, sz4, sx2 } }
    for col = 1, 3 do
        local pivot = col
        for r = col + 1, 3 do
            if math.abs(m[r][col]) > math.abs(m[pivot][col]) then pivot = r end
        end
        if math.abs(m[pivot][col]) < 1e-9 then
            return nil
        end
        m[col], m[pivot] = m[pivot], m[col]
        for r = col + 1, 3 do
            local f = m[r][col] / m[col][col]
            for k = col, 4 do m[r][k] = m[r][k] - f * m[col][k] end
        end
    end
    local c = m[3][4] / m[3][3]
    local b = (m[2][4] - m[2][3] * c) / m[2][2]
    local a = (m[1][4] - m[1][2] * b - m[1][3] * c) / m[1][1]
    local sum, sumLine = 0, 0
    -- (and the plain straight-line fit through the same points, to tell a real bend from noise)
    local det = sz0 * sz2 - sz1 * sz1
    local bl = det ~= 0 and (sz0 * sx1 - sz1 * sx0) / det or 0
    local al = (sx0 - bl * sz1) / sz0
    for i = 1, #points do
        local x, z = points[i][1], points[i][2]
        if z >= -1.0 and z <= zMax then
            local d = x - (a + b * z + c * z * z)
            sum = sum + d * d
            local dl = x - (al + bl * z)
            sumLine = sumLine + dl * dl
        end
    end
    local rms, rmsLine = math.sqrt(sum / count), math.sqrt(sumLine / count)
    -- a bend only counts when the curved fit is clearly better than the straight one: otherwise the "curvature" is the noise
    if rms > 0.8 * rmsLine or rmsLine < 0.25 then
        return al, bl, 0, rmsLine
    end
    return a, b, c, rms
end

RoadCenterline.FIT_SECONDS = 2.5          -- the stretch the line is fitted over: this many seconds of driving ahead ...
RoadCenterline.FIT_MIN = 20               -- ... at least this many metres (4 to 5 car lengths) ...
RoadCenterline.FIT_MAX = 50               -- ... at most this many
RoadCenterline.FIT_MAX_SAG = 1.2          -- ... and only when its bend over that stretch is small (metres of sag): bends are steered from the line itself
RoadCenterline.FIT_MAX_RMS = 0.8          -- a line that does not fit a parabola this well (a corner) is steered the other way

function RoadCenterline.steerCurvature(points, speedMs, options)
    options = options or {}
    local n = #points
    if n < 2 then
        return nil
    end
    -- far-sighted: one smooth curve through the next stretch of line gives where the line is, where it points and how it bends
    if options.fit ~= false then
        local zMax = math.max(RoadCenterline.FIT_MIN, math.min(RoadCenterline.FIT_MAX, speedMs * RoadCenterline.FIT_SECONDS))
        local a, b, c, rms = RoadCenterline.fitParabola(points, zMax)
        -- (a line whose bend is concentrated in part of the window would have its bend averaged away by one parabola:
        -- only gentle lines, with under 1.2 m of sag over the window, are fitted)
        if a ~= nil and rms <= (options.fitMaxRms or RoadCenterline.FIT_MAX_RMS) and math.abs(c) * zMax * zMax <= (options.fitMaxSag or RoadCenterline.FIT_MAX_SAG) then
            local L = math.max(options.fbMin or RoadCenterline.STEER_FB_MIN, speedMs * (options.fbSeconds or RoadCenterline.STEER_FB_SECONDS))
            local dead = options.deadband or RoadCenterline.STEER_DEADBAND
            local eEff = a - math.max(-dead, math.min(dead, a))
            local psi = math.atan(b)
            local kff = 2 * c
            local kfb = 2 * eEff / (L * L) + 2 * psi / L
            local fbMax = options.fbMax or RoadCenterline.STEER_FB_MAX
            kfb = math.max(-fbMax, math.min(fbMax, kfb))
            return kff + kfb, { e = a, psi = psi, kff = kff, kfb = kfb, fitted = true, rms = rms, zMax = zMax }
        end
    end
    local cumulative = { 0 }
    for i = 2, n do
        cumulative[i] = cumulative[i - 1] + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
    end
    -- the line's closest point to the vehicle (the origin)
    local bestD, bestS, bestX, bestZ = math.huge, 0, points[1][1], points[1][2]
    for i = 1, n - 1 do
        local ax, az, bx, bz = points[i][1], points[i][2], points[i + 1][1], points[i + 1][2]
        local sx, sz = bx - ax, bz - az
        local lengthSq = sx * sx + sz * sz
        if lengthSq > 1e-9 then
            local t = math.max(0, math.min(1, (-ax * sx - az * sz) / lengthSq))
            local cx, cz = ax + sx * t, az + sz * t
            local d = cx * cx + cz * cz
            if d < bestD then
                bestD, bestS, bestX, bestZ = d, cumulative[i] + t * math.sqrt(lengthSq), cx, cz
            end
        end
    end
    local e = bestX                                -- + : the line is to the left of the vehicle
    -- the line's direction there: its tangent, from a point a little behind to one a little ahead (a longer baseline
    -- would measure the chord of a bend, which is not the direction the line points in)
    local half = (options.headingBaseline or RoadCenterline.STEER_HEADING_BASELINE) * 0.5
    local fx, fz = polylineAt(points, cumulative, bestS + half)
    if fx == nil then
        fx, fz = points[n][1], points[n][2]
    end
    local rx, rz = polylineAt(points, cumulative, math.max(0, bestS - half))
    local dx, dz = fx - rx, fz - rz
    local psi = 0
    if dx * dx + dz * dz > 1e-6 then
        psi = math.atan2(dx, dz)                   -- + : the line points to the left of where the vehicle points
    end
    -- the bend the line has a moment from now
    local lead = math.max(options.leadMin or RoadCenterline.STEER_LEAD_MIN, speedMs * (options.leadSeconds or RoadCenterline.STEER_LEAD_SECONDS))
    local base = options.base or RoadCenterline.STEER_BASE
    local kff = 0
    local ax, az = polylineAt(points, cumulative, bestS + lead - base)
    local bx, bz = polylineAt(points, cumulative, bestS + lead)
    local cx, cz = polylineAt(points, cumulative, bestS + lead + base)
    if ax ~= nil and bx ~= nil and cx ~= nil then
        local v1x, v1z, v2x, v2z = bx - ax, bz - az, cx - bx, cz - bz
        local l1, l2 = math.sqrt(v1x * v1x + v1z * v1z), math.sqrt(v2x * v2x + v2z * v2z)
        local l3 = math.sqrt((v1x + v2x) ^ 2 + (v1z + v2z) ^ 2)
        if l1 > 1e-6 and l2 > 1e-6 and l3 > 1e-6 then
            kff = 2 * (v1z * v2x - v1x * v2z) / (l1 * l2 * l3)     -- + : a bend to the left
        end
    end
    local L = math.max(options.fbMin or RoadCenterline.STEER_FB_MIN, speedMs * (options.fbSeconds or RoadCenterline.STEER_FB_SECONDS))
    local dead = options.deadband or RoadCenterline.STEER_DEADBAND
    local eEff = e - math.max(-dead, math.min(dead, e))
    local kfb = 2 * eEff / (L * L) + 2 * psi / L
    local fbMax = options.fbMax or RoadCenterline.STEER_FB_MAX
    kfb = math.max(-fbMax, math.min(fbMax, kfb))
    return kff + kfb, { e = e, psi = psi, kff = kff, kfb = kfb, s = bestS }
end

-- ===== keeping clear of obstacles =====
-- `blocked(x, z)` says whether a point of the line would hit something (a tree dot); `onRoad(x, z)` whether a
-- point is still on the road or trail (nil = not checked). A line that runs into an obstacle is eased
-- sideways around it (over `ramp` metres each side) by the smallest shift that is clear and still on the road; when no
-- shift works the line ends before the obstacle (STOP_MARGIN metres short) and says so, so the vehicle
-- is brought to a stop instead of driven into it.
-- Returns the new points and info { nudged = bool, shift = metres, obstacle = { d, x, z } or nil }.
RoadCenterline.AVOID_SHIFTS = { 1.0, -1.0, 1.8, -1.8, 2.6, -2.6, 3.4, -3.4 }
RoadCenterline.AVOID_RAMP = 10.0
RoadCenterline.AVOID_STOP_MARGIN = 4.0
RoadCenterline.AVOID_MAX_RANGES = 3

local function smoothstep(t)
    t = math.max(0, math.min(1, t))
    return t * t * (3 - 2 * t)
end

function RoadCenterline.avoidObstacles(points, blocked, onRoad, options)
    options = options or {}
    local n = #points
    local info = { nudged = false }
    if n < 2 or blocked == nil then
        return points, info
    end
    local ramp = options.ramp or RoadCenterline.AVOID_RAMP

    local dist, nx, nz = { 0 }, {}, {}
    for i = 2, n do
        dist[i] = dist[i - 1] + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
    end
    for i = 1, n do
        local a, b = points[math.max(1, i - 1)], points[math.min(n, i + 1)]
        local ux, uz = normalize(b[1] - a[1], b[2] - a[2])
        nx[i], nz[i] = -uz, ux                         -- left of the direction of travel
    end

    local working = {}
    for i = 1, n do
        working[i] = { points[i][1], points[i][2] }
    end

    local i, ranges = 1, 0
    while i <= n and ranges < RoadCenterline.AVOID_MAX_RANGES do
        if blocked(working[i][1], working[i][2]) then
            local lo, hi = i, i
            while hi + 1 <= n and blocked(working[hi + 1][1], working[hi + 1][2]) do
                hi = hi + 1
            end
            ranges = ranges + 1
            local fixed = false
            for _, shift in ipairs(RoadCenterline.AVOID_SHIFTS) do
                local candidate, ok = {}, true
                for k = 1, n do
                    local d = dist[k]
                    local w = 0
                    if d >= dist[lo] - ramp and d <= dist[hi] + ramp then
                        if d < dist[lo] then
                            w = smoothstep((d - (dist[lo] - ramp)) / ramp)
                        elseif d > dist[hi] then
                            w = smoothstep(1 - (d - dist[hi]) / ramp)
                        else
                            w = 1
                        end
                    end
                    if w > 0 then
                        local qx, qz = working[k][1] + nx[k] * shift * w, working[k][2] + nz[k] * shift * w
                        if blocked(qx, qz) or (onRoad ~= nil and not onRoad(qx, qz)) then
                            ok = false
                            break
                        end
                        candidate[k] = { qx, qz }
                    end
                end
                if ok then
                    for k, point in pairs(candidate) do
                        working[k] = point
                    end
                    info.nudged = true
                    info.shift = shift
                    fixed = true
                    break
                end
            end
            if not fixed then
                -- no way round: the line ends before the obstacle
                local stopAt = dist[lo] - RoadCenterline.AVOID_STOP_MARGIN
                local kept = { working[1] }
                for k = 2, n do
                    if dist[k] <= stopAt then
                        kept[#kept + 1] = working[k]
                    else
                        break
                    end
                end
                info.obstacle = { d = dist[lo], x = working[lo][1], z = working[lo][2] }
                return kept, info
            end
            i = hi + 1
        else
            i = i + 1
        end
    end
    return working, info
end

-- Share of the wanted speed the ground allows over the next `ahead` metres of the line: the mean of
-- factors.road (class 2), factors.trail (class 1) and factors.offroad (class 0: grass, field, bare
-- soil; nil = no penalty, which is also right when the map has no data to tell).
function RoadCenterline.groundFactor(points, sample, factors, ahead)
    local total, count, along = 0, 0, 0
    for i = 1, #points do
        if i > 1 then
            along = along + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
        end
        if along > ahead then
            break
        end
        local class = sample(points[i][1], points[i][2]) or 0
        local factor = 1
        if class == 2 then
            factor = factors.road
        elseif class == 1 then
            factor = factors.trail
        elseif factors.offroad ~= nil then
            factor = factors.offroad
        end
        total = total + factor
        count = count + 1
    end
    return count > 0 and total / count or 1
end

-- Length of the polyline
function RoadCenterline.length(points)
    local total = 0
    for i = 2, #points do
        total = total + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
    end
    return total
end

-- The point to steer at: the first point on the polyline at least `lookahead` metres from the
-- vehicle, interpolated. When the polyline is shorter, its last point and ending = true.
function RoadCenterline.pickTarget(points, vx, vz, lookahead)
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        local da = math.sqrt((a[1] - vx) ^ 2 + (a[2] - vz) ^ 2)
        local db = math.sqrt((b[1] - vx) ^ 2 + (b[2] - vz) ^ 2)
        if db >= lookahead then
            if da >= lookahead or db == da then
                return a[1], a[2], false
            end
            local f = (lookahead - da) / (db - da)
            return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, false
        end
    end
    local last = points[#points]
    return last[1], last[2], true
end

-- The line to steer by: false ticks removed, then smoothed.
-- The line smoothed by local regression: every point is replaced by what a quadratic fitted (by least squares) to the points
-- within `halfWindow` metres of it along the line says about that spot (Savitzky-Golay). A bend is a quadratic, so it
-- survives; the metre or so of jitter in the middle of each row of a pixel scan is not, and drops out. This is the
-- "draw one smooth line through the measuring points" step.





RoadCenterline.STEERING_LINE_MODE = "both"           -- the despiked line, averaged over a few points, then smoothed by local regression
RoadCenterline.REGRESS_HALF_WINDOW = 5.0
function RoadCenterline.regressLine(points, halfWindow)
    local n = #points
    if n < 6 then
        return points
    end
    halfWindow = halfWindow or RoadCenterline.REGRESS_HALF_WINDOW
    local s = { 0 }
    for i = 2, n do
        s[i] = s[i - 1] + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
    end
    local out = {}
    local total = s[n]
    for i = 1, n do
        -- (the window shrinks symmetrically towards the ends, like the median filter: a one-sided window would extrapolate
        -- the fit and drag the end of the line; the very ends are kept as measured)
        local hw = math.min(halfWindow, s[i], total - s[i])
        local useRaw = hw < 3
        -- gather the window (tricube weights, nearest points count most)
        local sw, ss1, ss2, ss3, ss4, sx0, sx1, sx2, sz0, sz1, sz2, count = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        for j = 1, useRaw and 0 or n do
            local d = s[j] - s[i]
            if math.abs(d) <= hw then
                local u = math.abs(d) / hw
                local w = (1 - u * u * u) ^ 3
                count = count + 1
                local d2 = d * d
                sw = sw + w
                ss1 = ss1 + w * d
                ss2 = ss2 + w * d2
                ss3 = ss3 + w * d2 * d
                ss4 = ss4 + w * d2 * d2
                sx0 = sx0 + w * points[j][1]
                sx1 = sx1 + w * points[j][1] * d
                sx2 = sx2 + w * points[j][1] * d2
                sz0 = sz0 + w * points[j][2]
                sz1 = sz1 + w * points[j][2] * d
                sz2 = sz2 + w * points[j][2] * d2
            end
        end
        if useRaw or count < 5 then
            out[i] = { points[i][1], points[i][2] }
        else
            -- the value at d = 0 of the weighted quadratic fit: solve the 3 x 3 normal equations for the constant term
            local function constant(t0, t1, t2)
                local m = { { sw, ss1, ss2, t0 }, { ss1, ss2, ss3, t1 }, { ss2, ss3, ss4, t2 } }
                for col = 1, 3 do
                    local pivot = col
                    for r = col + 1, 3 do
                        if math.abs(m[r][col]) > math.abs(m[pivot][col]) then pivot = r end
                    end
                    if math.abs(m[pivot][col]) < 1e-9 then
                        return nil
                    end
                    m[col], m[pivot] = m[pivot], m[col]
                    for r = col + 1, 3 do
                        local f = m[r][col] / m[col][col]
                        for k = col, 4 do m[r][k] = m[r][k] - f * m[col][k] end
                    end
                end
                local c2 = m[3][4] / m[3][3]
                local c1 = (m[2][4] - m[2][3] * c2) / m[2][2]
                return (m[1][4] - m[1][2] * c1 - m[1][3] * c2) / m[1][1]
            end
            local x0, z0 = constant(sx0, sx1, sx2), constant(sz0, sz1, sz2)
            out[i] = { x0 or points[i][1], z0 or points[i][2] }
        end
    end
    return out
end

function RoadCenterline.steeringLine(points)
    if #points < 3 then
        return points
    end
    local mode = RoadCenterline.STEERING_LINE_MODE or "old"
    local d = RoadCenterline.despike(points, 2)
    if mode == "old" then
        return RoadCenterline.smoothPoints(d, 2)
    elseif mode == "regress" then
        return RoadCenterline.regressLine(d, RoadCenterline.REGRESS_HALF_WINDOW)
    else
        return RoadCenterline.regressLine(RoadCenterline.smoothPoints(d, 2), RoadCenterline.REGRESS_HALF_WINDOW)
    end
end

-- The aim point averaged over points `spread` metres before, at and after `lookahead`: evens out the
-- last bit of jitter, and a bend cancels to first order because the three points straddle it.
function RoadCenterline.pickTargetAveraged(points, vx, vz, lookahead, spread)
    local x0, z0, ending = RoadCenterline.pickTarget(points, vx, vz, lookahead)
    spread = spread or 4
    local x1, z1 = RoadCenterline.pickTarget(points, vx, vz, math.max(1, lookahead - spread))
    local x2, z2 = RoadCenterline.pickTarget(points, vx, vz, lookahead + spread)
    return (x0 * 2 + x1 + x2) / 4, (z0 * 2 + z1 + z2) / 4, ending
end

-- Sharpness of the bend over the polyline, 1/metres. The sag of the line against its chord gives
-- the radius of the circle through its ends and its furthest point, R = (h^2 + s^2) / (2 s), which
-- leans on the extremes and so ignores the pixel jitter of single steps. A sag under 0.25 m is a
-- straight road.
RoadCenterline.MIN_SAG = 0.4
-- moving average over `radius` points each side (one-sided at the ends)
-- Median of each coordinate over `radius` points each side: removes one-off false ticks (a gravel
-- patch pulling a single scan sideways) without smearing real bends the way an average does.
function RoadCenterline.despike(points, radius)
    local n = #points
    local out = {}
    local function median(values)
        table.sort(values)
        return values[math.ceil(#values / 2)]
    end
    for i = 1, n do
        -- the window shrinks symmetrically near the ends (a one-sided window would shift points)
        local r = math.min(radius, i - 1, n - i)
        local xs, zs = {}, {}
        for j = i - r, i + r do
            xs[#xs + 1], zs[#zs + 1] = points[j][1], points[j][2]
        end
        out[i] = { median(xs), median(zs) }
    end
    return out
end

function RoadCenterline.smoothPoints(points, radius)
    local n = #points
    local out = {}
    for i = 1, n do
        local sx, sz, count = 0, 0, 0
        for j = math.max(1, i - radius), math.min(n, i + radius) do
            sx, sz, count = sx + points[j][1], sz + points[j][2], count + 1
        end
        out[i] = { sx / count, sz / count }
    end
    return out
end

local curvatureOf

-- the worse of the whole line and its near half: a bend close by must not average out over a long line
function RoadCenterline.curvatureRaw(points)
    return curvatureOf(points)
end

function RoadCenterline.curvature(rawPoints)
    local whole = curvatureOf(rawPoints)
    local n = #rawPoints
    if n < 8 then
        return whole
    end
    local half = {}
    for i = 1, math.ceil(n / 2) do half[i] = rawPoints[i] end
    return math.max(whole, curvatureOf(half))
end

curvatureOf = function(rawPoints)
    local n = #rawPoints
    if n < 4 then
        return 0
    end
    local points = RoadCenterline.smoothPoints(rawPoints, 2)
    local a, b = points[1], points[n]
    local cx, cz = b[1] - a[1], b[2] - a[2]
    local chord = math.sqrt(cx * cx + cz * cz)
    if chord < 3 then
        return 0
    end
    local ux, uz = cx / chord, cz / chord
    local sag = 0
    for i = 2, n - 1 do
        local px, pz = points[i][1] - a[1], points[i][2] - a[2]
        sag = math.max(sag, math.abs(px * -uz + pz * ux))
    end
    if sag < RoadCenterline.MIN_SAG then
        return 0
    end
    local h = chord * 0.5
    return (2 * sag) / (h * h + sag * sag)
end

-- ===== planning the speed along the line =====
-- A driver slows BEFORE a bend, not in it. The bend's sharpness is measured over short windows all along
-- the line (not once over the whole of it, which averages a tight bend 30 m ahead into almost nothing),
-- and every bend limits the speed NOW to whatever can still be braked down to it in the distance left.
RoadCenterline.PROFILE_WINDOW = 14.0      -- m: how much line one curvature reading covers (long enough to see a gentle bend over the noise)
RoadCenterline.PROFILE_BRAKE = 1.5        -- m/s^2: the braking the plan counts on (a loaded truck with a trailer, on dirt)

-- [{ d = metres from the vehicle to the middle of the window, kappa = 1/m }, ...]; empty on a straight line
-- window: metres of line one curvature reading covers (default PROFILE_WINDOW; a gentle bend needs a longer one to show above the noise: the sag of
-- a 14 m chord on a 120 m radius is 0.2 m)
function RoadCenterline.curvatureProfile(points, window)
    window = window or RoadCenterline.PROFILE_WINDOW
    local profile = {}
    local n = #points
    if n < 4 then
        return profile
    end
    local smooth = RoadCenterline.smoothPoints(points, 2)
    local distance = { 0 }
    for i = 2, n do
        distance[i] = distance[i - 1] + math.sqrt((smooth[i][1] - smooth[i - 1][1]) ^ 2 + (smooth[i][2] - smooth[i - 1][2]) ^ 2)
    end
    for i = 1, n - 3 do
        local j = i + 3
        while j < n and distance[j] - distance[i] < window do
            j = j + 1
        end
        if distance[j] - distance[i] >= window * 0.6 then
            local slice = {}
            for k = i, j do
                slice[#slice + 1] = smooth[k]
            end
            local kappa = RoadCenterline.curvatureRaw(slice)
            if kappa > 1e-4 then
                profile[#profile + 1] = { d = (distance[i] + distance[j]) * 0.5, kappa = kappa }
            end
        end
    end
    return profile
end

-- The most the vehicle may do right now (km/h) given the bends ahead: for each one, the speed it can be
-- taken at (comfortable, but never above the physical limit; optionally not below a share of the wanted
-- speed) plus what braking can take off in the distance before it.
-- brake, lateral, hard: what the vehicle can do (m/s^2): braking the plan counts on, the sideways acceleration taken in a bend, and the most it may ever be.
function RoadCenterline.profileSpeed(profile, maxSpeedKmh, bendFloor, brake, lateral, hard)
    local allowed = maxSpeedKmh
    for _, entry in ipairs(profile) do
        local bend = math.sqrt((lateral or RoadCenterline.LATERAL_ACCEL) / entry.kappa) * 3.6
        if bendFloor ~= nil and maxSpeedKmh ~= math.huge then
            bend = math.max(bend, maxSpeedKmh * bendFloor)
        end
        bend = math.min(bend, math.sqrt((hard or RoadCenterline.HARD_LATERAL_ACCEL) / entry.kappa) * 3.6)
        if entry.kappa >= RoadCenterline.TIGHT_KAPPA then
            bend = math.min(bend, RoadCenterline.TIGHT_KMH)
        end
        local bendMs = bend / 3.6
        local now = math.sqrt(bendMs * bendMs + 2 * (brake or RoadCenterline.PROFILE_BRAKE) * entry.d) * 3.6
        allowed = math.min(allowed, now)
    end
    return allowed
end

-- The speed from which the vehicle can still stop `distance` metres ahead (3 m kept in hand), km/h.
-- Metres along the line to where it first turns away from its starting direction by `degrees`
-- (nil when it never does within the line).
function RoadCenterline.turnStartDistance(points, degrees)
    local n = #points
    if n < 3 then
        return nil
    end
    local dx, dz = normalize(points[math.min(3, n)][1] - points[1][1], points[math.min(3, n)][2] - points[1][2])
    local distance = 0
    for i = 2, n do
        distance = distance + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
        local sx, sz = normalize(points[i][1] - points[i - 1][1], points[i][2] - points[i - 1][2])
        local angle = math.deg(math.acos(math.max(-1, math.min(1, dx * sx + dz * sz))))
        if angle >= degrees then
            return distance
        end
    end
    return nil
end

function RoadCenterline.endSpeed(distance)
    return math.sqrt(2 * RoadCenterline.BRAKE_DECEL * math.max(0, distance - 3)) * 3.6
end

-- Speed this stretch allows, km/h: slower in a bend, at a junction and towards the end of the road.
function RoadCenterline.speedAdvice(result, maxSpeedKmh, distanceToEnd, bendFloor)
    local speed = maxSpeedKmh
    local curvature = RoadCenterline.curvature(result.points)
    if curvature > 1e-4 then
        local bendSpeed = math.sqrt(RoadCenterline.LATERAL_ACCEL / curvature) * 3.6
        -- optionally never slower than a share of the wanted speed (assisted cruise: pixel noise must not crawl) ...
        if bendFloor ~= nil and maxSpeedKmh ~= math.huge then
            bendSpeed = math.max(bendSpeed, maxSpeedKmh * bendFloor)
        end
        -- ... but never above what the bend physically allows
        bendSpeed = math.min(bendSpeed, math.sqrt(RoadCenterline.HARD_LATERAL_ACCEL / curvature) * 3.6)
        speed = math.min(speed, bendSpeed)
    end
    if result.junction then
        speed = math.min(speed, RoadCenterline.JUNCTION_SPEED_KMH)
    end
    if result.ends and distanceToEnd ~= nil then
        speed = math.min(speed, RoadCenterline.endSpeed(distanceToEnd))
    end
    return math.max(speed, 0)
end
