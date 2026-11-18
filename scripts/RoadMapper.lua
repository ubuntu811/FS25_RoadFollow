-- Road Mapper: the pieces for finding and following roads on the map picture: the road measured across, the runs on a ring, the walk ahead (and RoadAtlas
-- builds the moving map of the roads round a point from them). Before, this file also held a one-shot map of a fixed point; RoadAtlas replaced it.
--
-- (Pure geometry: no engine calls except through the sampler it is given, so it is tested offline. The sampler answers 0 = no road,
-- 1 = trail / gravel, 2 = road for a world point, like RoadFollow's own.)
--
-- The walk (walkAhead, and RoadAtlas's own steps): the road is measured across (its width, its middle) and the walker steps to the middle, 3 m at a time; its
-- heading is blended slowly, so one noisy pixel cannot jerk it, and the middle of a run of pixels does not care about a ragged edge. It ends where the road ends,
-- widens into open ground, or (RoadAtlas) leaves the circle or runs into a road already walked.
RoadMapper = {}

RoadMapper.AXIS_RADIUS = 6.0                -- the small circle round a hit that tells the road's direction
RoadMapper.AXIS_STEP_DEG = 15
RoadMapper.WALK_STEP = 3.0                  -- metres per step of a walk
RoadMapper.CROSS_HALF = 9.0                 -- metres each side the road is measured across
RoadMapper.CROSS_STEP = 1.5
RoadMapper.MAX_WIDTH = 14.0                 -- wider than this is open ground, not a road
RoadMapper.GAP_STEPS = 2                    -- a break of this many steps (6 m) is bridged
RoadMapper.FAR_BLEND = 0.55                 -- the far look follows bends more eagerly (its steps are longer)
RoadMapper.DIR_BLEND = 0.3                  -- how much of each step's own direction goes into the heading
RoadMapper.MIN_LENGTH = 15.0                -- metres: shorter than this is not a road
RoadMapper.MAX_STEPS = 90                   -- per direction of a walk (270 m)
RoadMapper.CELL = 3.0                       -- the grid that remembers which road has been walked where
RoadMapper.JOIN_MIN_STEPS = 3               -- a walk this far from its seed may end by running into another road

local function normalize(x, z)
    local l = math.sqrt(x * x + z * z)
    if l < 1e-9 then
        return 1, 0
    end
    return x / l, z / l
end

-- Runs of non-zero values in values[1..n]; a run may skip `gap` zeros. { first, last, class (the highest), } wrap = true joins the end to the start.
local function runsOf(values, n, gap, wrap)
    local runs, current = {}, nil
    for i = 1, n do
        if values[i] > 0 then
            if current ~= nil and i - current.last - 1 <= gap then
                current.last = i
                current.class = math.max(current.class, values[i])
            else
                current = { first = i, last = i, class = values[i] }
                runs[#runs + 1] = current
            end
        end
    end
    if wrap and #runs >= 2 then
        local a, b = runs[1], runs[#runs]
        if a.first <= 1 + gap and b.last >= n - gap then
            -- the last run goes on into the first: one run that wraps round
            b.last = a.last + n
            b.class = math.max(a.class, b.class)
            table.remove(runs, 1)
        end
    end
    return runs
end

RoadMapper.runsOf = runsOf          -- (shared with RoadAtlas)
RoadMapper.normalize = normalize

-- the road across a line through (px, pz) with heading (dx, dz): { x, z, width, class } of the run nearest the middle, or nil
function RoadMapper.crossSection(read, px, pz, dx, dz)
    local nx, nz = -dz, dx
    local count = math.floor(2 * RoadMapper.CROSS_HALF / RoadMapper.CROSS_STEP) + 1
    local values = {}
    for i = 1, count do
        local offset = -RoadMapper.CROSS_HALF + (i - 1) * RoadMapper.CROSS_STEP
        values[i] = read(px + nx * offset, pz + nz * offset) or 0
    end
    local best, bestDistance = nil, math.huge
    for _, run in ipairs(runsOf(values, count, 1, false)) do
        local firstOffset = -RoadMapper.CROSS_HALF + (run.first - 1) * RoadMapper.CROSS_STEP
        local lastOffset = -RoadMapper.CROSS_HALF + (run.last - 1) * RoadMapper.CROSS_STEP
        local centre = (firstOffset + lastOffset) / 2
        local width = lastOffset - firstOffset + RoadMapper.CROSS_STEP
        local distance = math.abs(centre)
        if distance < bestDistance then
            bestDistance = distance
            best = { x = px + nx * centre, z = pz + nz * centre, width = width, class = run.class }
        end
    end
    if best ~= nil and bestDistance <= RoadMapper.CROSS_HALF * 0.8 then
        return best
    end
    return nil
end

-- The road straight ahead, followed round its bends: a line from (x, z) heading (dx, dz), `length` metres long at most, one point every `step`
-- metres, and how it ended ("long" = the whole length, "lost" = the road went, "open" = it widened into open ground). Synchronous and cheap (about 13
-- map reads per step): for looking far ahead at speed, where the full scan is too short, not for steering by.
function RoadMapper.walkAhead(sample, x, z, dx, dz, length, step, blend)
    step = step or 4.0
    blend = blend or RoadMapper.FAR_BLEND
    dx, dz = normalize(dx, dz)
    local points = { { x, z } }
    local ending = "long"
    for _ = 1, math.ceil(length / step) do
        local found = nil
        for ahead = 1, RoadMapper.GAP_STEPS + 1 do
            found = RoadMapper.crossSection(sample, x + dx * step * ahead, z + dz * step * ahead, dx, dz)
            if found ~= nil then
                break
            end
        end
        if found == nil then
            ending = "lost"
            break
        end
        if found.width > RoadMapper.MAX_WIDTH then
            ending = "open"
            break
        end
        local moved = math.sqrt((found.x - x) ^ 2 + (found.z - z) ^ 2)
        if moved < 0.5 then
            ending = "lost"
            break
        end
        local ndx, ndz = (found.x - x) / moved, (found.z - z) / moved
        dx, dz = normalize(dx * (1 - blend) + ndx * blend, dz * (1 - blend) + ndz * blend)
        x, z = found.x, found.z
        points[#points + 1] = { x, z }
    end
    return { points = points, ending = ending }
end

-- The points of a line resampled every `spacing` metres along it (the curvature profile reads lines that are about 2 m apart).
function RoadMapper.resample(points, spacing)
    if #points < 2 then
        return points
    end
    local out = { { points[1][1], points[1][2] } }
    local carry = 0
    for i = 2, #points do
        local ax, az, bx, bz = points[i - 1][1], points[i - 1][2], points[i][1], points[i][2]
        local segment = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
        local position = spacing - carry
        while position <= segment do
            local f = position / segment
            out[#out + 1] = { ax + (bx - ax) * f, az + (bz - az) * f }
            position = position + spacing
        end
        carry = segment - (position - spacing)
    end
    return out
end

-- A walk's points as a line to read curvature from: despiked (a pixel's jitter is not a bend), smoothed, and 2 m apart.
function RoadMapper.farLine(points)
    local radius = math.min(2, math.floor((#points - 1) / 2))
    local line = RoadCenterline.smoothPoints(RoadCenterline.despike(points, radius), math.min(2, math.floor((#points - 1) / 2)))
    return RoadMapper.resample(line, 2.0)
end
