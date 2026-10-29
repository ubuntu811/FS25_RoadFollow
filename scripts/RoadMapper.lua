-- Road Mapper: the roads around a point, found by sweeping rings and walking every road a ring crosses.
--
-- (Pure geometry: no engine calls except through the sampler it is given, so it is tested offline. The sampler answers 0 = no road,
-- 1 = trail / gravel, 2 = road for a world point, like RoadFollow's own.)
--
-- How the noise goes away, in the order it happens:
--   1. A ring (radius 15, 35, 60, 90 m ...) is read every 1.5 m, so a 2 m map pixel is never skipped. A run of road pixels on the ring is a
--      HIT: a place a road crosses the ring. That is all the ring is for: finding roads, cheaply (about 2 pi r / 1.5 reads each).
--   2. A hit is only a seed. A small circle round it says which way the road runs (it crosses that circle on two sides) or that it
--      runs nowhere (one lonely dirt patch crosses it on no side at all): such a seed is thrown away. A single pixel of dirt is not a road.
--   3. The road is WALKED from the seed, both ways, 3 m at a time. At each step the road is measured across (its width, its middle) and the
--      walker steps to the middle; its heading is blended slowly, so one noisy pixel cannot jerk it. The middle of a run of pixels does not
--      care about a ragged edge.
--   4. The walk ends where the road ends, widens into open ground, leaves the radius, or runs into a road already walked (a junction:
--      noted, and not walked twice).
--   5. The walked line is despiked (median) and smoothed, and thin pieces (under MIN_LENGTH) are dropped.
-- Everything is time-sliced: step(budget) reads at most `budget` map pixels and stops; call it again next frame.
RoadMapper = {}

RoadMapper.RADII = { 15, 35, 60, 90 }       -- metres: the rings
RoadMapper.RING_STEP = 1.5                  -- metres between reads on a ring
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
RoadMapper.MAX_TRACES = 16
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

function RoadMapper.new(sample, cx, cz, options)
    options = options or {}
    local m = {
        cx = cx, cz = cz,
        radius = options.radius or RoadMapper.RADII[#RoadMapper.RADII],
        radii = options.radii or RoadMapper.RADII,
        traces = {}, junctions = {}, deadEnds = {}, rings = {},
        samples = 0, used = 0, budget = 0, done = false, error = nil, visited = {}, seedsSkipped = 0, seedsRejected = 0,
    }
    local radii = {}
    for _, r in ipairs(m.radii) do
        if r <= m.radius + 1e-6 then
            radii[#radii + 1] = r
        end
    end
    m.radii = radii
    m.rings = radii

    local function read(x, z)
        m.samples = m.samples + 1
        m.used = m.used + 1
        if m.used >= m.budget then
            m.used = 0
            coroutine.yield()
        end
        return sample(x, z) or 0
    end

    local function cellKey(x, z)
        return math.floor(x / RoadMapper.CELL) .. "," .. math.floor(z / RoadMapper.CELL)
    end
    local function mark(x, z, id)
        for dx = -1, 1 do
            for dz = -1, 1 do
                local key = cellKey(x + dx * RoadMapper.CELL, z + dz * RoadMapper.CELL)
                if m.visited[key] == nil then
                    m.visited[key] = id
                end
            end
        end
    end

    local function crossSection(px, pz, dx, dz)
        return RoadMapper.crossSection(read, px, pz, dx, dz)
    end

    -- walk from (sx, sz) heading (dx, dz): { points = {{x, z, class, width}}, ending = "lost" | "open" | "edge" | "joins" | "long", joinX, joinZ }
    local function walk(sx, sz, dx, dz, id)
        local points = {}
        local x, z = sx, sz
        local ending = "long"
        local joinX, joinZ
        for step = 1, RoadMapper.MAX_STEPS do
            local found = nil
            for ahead = 1, RoadMapper.GAP_STEPS + 1 do
                found = crossSection(x + dx * RoadMapper.WALK_STEP * ahead, z + dz * RoadMapper.WALK_STEP * ahead, dx, dz)
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
            dx, dz = normalize(dx * (1 - RoadMapper.DIR_BLEND) + ndx * RoadMapper.DIR_BLEND, dz * (1 - RoadMapper.DIR_BLEND) + ndz * RoadMapper.DIR_BLEND)
            x, z = found.x, found.z
            local owner = m.visited[cellKey(x, z)]
            if owner ~= nil and owner ~= id and step > RoadMapper.JOIN_MIN_STEPS then
                ending = "joins"
                joinX, joinZ = x, z
                break
            end
            mark(x, z, id)
            points[#points + 1] = { x, z, found.class, found.width }
            if (x - m.cx) ^ 2 + (z - m.cz) ^ 2 > (m.radius * 1.15) ^ 2 then
                ending = "edge"
                break
            end
        end
        return { points = points, ending = ending, joinX = joinX, joinZ = joinZ }
    end

    -- which way the road at a hit runs: the directions of the runs found on a small circle round it
    local function axisAt(hx, hz)
        local n = math.floor(360 / RoadMapper.AXIS_STEP_DEG)
        local values = {}
        for i = 1, n do
            local angle = 2 * math.pi * (i - 1) / n
            values[i] = read(hx + RoadMapper.AXIS_RADIUS * math.cos(angle), hz + RoadMapper.AXIS_RADIUS * math.sin(angle))
        end
        local runs = runsOf(values, n, 0, true)
        local directions = {}
        for _, run in ipairs(runs) do
            local middle = (run.first + run.last) / 2
            local angle = 2 * math.pi * (middle - 1) / n
            directions[#directions + 1] = { math.cos(angle), math.sin(angle), angle = angle }
        end
        return directions
    end

    local function nearJunction(x, z)
        for _, j in ipairs(m.junctions) do
            if (j[1] - x) ^ 2 + (j[2] - z) ^ 2 < 8 * 8 then
                return true
            end
        end
        return false
    end
    local function addJunction(x, z)
        if not nearJunction(x, z) then
            m.junctions[#m.junctions + 1] = { x, z }
        end
    end

    local function finish(trace)
        local pts = trace.points
        if #pts < 3 then
            return nil
        end
        local line = {}
        for i, p in ipairs(pts) do
            line[i] = { p[1], p[2] }
        end
        local radiusDespike = math.min(2, math.floor((#line - 1) / 2))
        line = RoadCenterline.despike(line, radiusDespike)
        line = RoadCenterline.smoothPoints(line, math.min(3, math.floor((#line - 1) / 2)))
        local length = 0
        for i = 2, #line do
            length = length + math.sqrt((line[i][1] - line[i - 1][1]) ^ 2 + (line[i][2] - line[i - 1][2]) ^ 2)
        end
        local road, widths = 0, {}
        for _, p in ipairs(pts) do
            if p[3] == 2 then
                road = road + 1
            end
            widths[#widths + 1] = p[4]
        end
        table.sort(widths)
        return { points = line, length = length, kind = (road / #pts >= 0.6) and "road" or "trail", width = widths[math.ceil(#widths / 2)] or 0,
            ending = trace.ending }
    end

    local function body()
        local id = 0
        for _, radius in ipairs(m.radii) do
            local n = math.max(12, math.ceil(2 * math.pi * radius / RoadMapper.RING_STEP))
            local values = {}
            for i = 1, n do
                local angle = 2 * math.pi * (i - 1) / n
                values[i] = read(m.cx + radius * math.cos(angle), m.cz + radius * math.sin(angle))
            end
            for _, run in ipairs(runsOf(values, n, 1, true)) do
                local middle = (run.first + run.last) / 2
                local angle = 2 * math.pi * (middle - 1) / n
                local hx, hz = m.cx + radius * math.cos(angle), m.cz + radius * math.sin(angle)
                if #m.traces >= RoadMapper.MAX_TRACES then
                    break
                end
                if m.visited[cellKey(hx, hz)] ~= nil then
                    m.seedsSkipped = m.seedsSkipped + 1          -- a road already walked
                else
                    local directions = axisAt(hx, hz)
                    if #directions == 0 then
                        m.seedsRejected = m.seedsRejected + 1    -- nothing continues from here: a patch, not a road
                    else
                        id = id + 1
                        mark(hx, hz, id)
                        local pieces = {}
                        -- two or more ways out: the road runs through (the two most opposite); more than two is a junction at the seed
                        if #directions >= 3 then
                            addJunction(hx, hz)
                        end
                        local chosen = {}
                        if #directions == 1 then
                            chosen = { directions[1] }
                            m.deadEnds[#m.deadEnds + 1] = { hx, hz }
                        else
                            for _, d in ipairs(directions) do
                                chosen[#chosen + 1] = d
                            end
                        end
                        local pointsAll = {}
                        local ends = {}
                        for k, d in ipairs(chosen) do
                            local piece = walk(hx, hz, d[1], d[2], id)
                            pieces[k] = piece
                            if piece.ending == "joins" then
                                addJunction(piece.joinX, piece.joinZ)
                            elseif piece.ending == "lost" and #piece.points > 0 then
                                local last = piece.points[#piece.points]
                                m.deadEnds[#m.deadEnds + 1] = { last[1], last[2] }
                            end
                        end
                        -- one line per seed: the first two pieces joined through the seed (more than two: the rest are separate lines)
                        local function reversed(list)
                            local out = {}
                            for i = #list, 1, -1 do out[#out + 1] = list[i] end
                            return out
                        end
                        if #pieces >= 2 then
                            local line = reversed(pieces[1].points)
                            line[#line + 1] = { hx, hz, 2, 0 }
                            for _, p in ipairs(pieces[2].points) do line[#line + 1] = p end
                            local trace = finish({ points = line, ending = pieces[2].ending })
                            if trace ~= nil and trace.length >= RoadMapper.MIN_LENGTH then
                                m.traces[#m.traces + 1] = trace
                            end
                            for k = 3, #pieces do
                                local extra = finish({ points = pieces[k].points, ending = pieces[k].ending })
                                if extra ~= nil and extra.length >= RoadMapper.MIN_LENGTH and #m.traces < RoadMapper.MAX_TRACES then
                                    m.traces[#m.traces + 1] = extra
                                end
                            end
                        elseif #pieces == 1 then
                            local trace = finish({ points = pieces[1].points, ending = pieces[1].ending })
                            if trace ~= nil and trace.length >= RoadMapper.MIN_LENGTH then
                                m.traces[#m.traces + 1] = trace
                            end
                        end
                    end
                end
            end
        end
    end

    m.co = coroutine.create(body)          -- (an error inside comes back from coroutine.resume in step)
    return m
end

-- Reads at most `budget` map pixels; true when the whole map is done.
function RoadMapper.step(m, budget)
    if m.done then
        return true
    end
    m.budget = math.max(1, budget or 400)
    m.used = 0
    local ok, err = coroutine.resume(m.co)
    if not ok then
        m.error = tostring(err)
        m.done = true
    elseif coroutine.status(m.co) == "dead" then
        m.done = true
    end
    return m.done
end
