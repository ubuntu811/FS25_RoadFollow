-- Road Atlas: the roads round a MOVING point, kept up to date by reading only what is new.
--
-- (Pure geometry: the map is only read through the sampler it is given, 0 = no road, 1 = trail / gravel, 2 = road, so it is tested offline. Built on the pieces of
-- RoadMapper: the road measured across, the runs on a ring, the walk.)
--
-- How it works:
--   * Once (first call, or after a jump such as a teleport) a few rings round the point are read: every road a ring crosses is found and WALKED, both ways, and the
--     walked line is stored. That is the only full sweep.
--   * While the point moves, every PROBE_EVERY metres only the LEADING part of the circle (an arc each side of the way it moves) is read. A road that crosses it
--     is a new one unless a stored road already covers the spot; a new one is walked and stored. That is all that is new: a thin sliver, not the circle.
--   * A walk stops at the edge of the circle (WALK_REACH x the radius) and is marked as reaching on; once the point has come within EXTEND_SHARE of the radius
--     of that end, the walk goes on from there.
--   * What is far behind (KEEP_SHARE x the radius) is forgotten: the tails of roads are cut off, roads that are entirely out of range are dropped.
-- Everything is time-sliced: step(budget) does about `budget` map reads and stops. When nothing moves, nothing is read.
RoadAtlas = {}

RoadAtlas.RADIUS = 90                   -- the radius at a standstill (and the least)
RoadAtlas.MAX_RADIUS = 250              -- the most, at speed
RoadAtlas.RADIUS_SECONDS = 6.0          -- at speed the circle reaches this many seconds ahead
RoadAtlas.SHRINK_STEP = 15.0            -- metres the radius gives up per probe when slowing down (it grows at once)
RoadAtlas.PROBE_MAX = 25.0              -- metres between probes at the largest radius (radius / 10, but at least PROBE_EVERY)
RoadAtlas.RING_FRACTIONS = { 0.17, 0.39, 0.67, 1.0 }   -- the rings of the full sweep, as shares of the radius
RoadAtlas.RING_STEP = 1.5               -- metres between reads on a ring (a 2 m map pixel is never skipped)
RoadAtlas.RING_CHUNK = 150              -- map reads of a ring done in one go
RoadAtlas.ARC_HALF_DEG = 100            -- the leading arc read while moving: this many degrees each side of the way
RoadAtlas.PROBE_EVERY = 10.0            -- metres of travel between two reads of the arc
RoadAtlas.JUMP_SHARE = 0.5              -- moved this share of the radius between two probes: not driving, a jump: start over
RoadAtlas.WALK_REACH = 1.15             -- a walk goes this far (x radius) from the centre it started at
RoadAtlas.EXTEND_SHARE = 0.85           -- a road end that reaches on is walked on once it is this near (x radius)
RoadAtlas.KEEP_SHARE = 1.6              -- further than this (x radius) from the point is forgotten
RoadAtlas.MAX_PIECES = 48
RoadAtlas.FRONTIER_GAP = 30.0            -- metres: a ring hit this far beyond a road end that reaches on is that road, not a new one
RoadAtlas.JUNCTION_DEG = 30              -- roads that meet at less than this angle are one road, not a junction
RoadAtlas.FIT_SKIP = 9.0                 -- metres back from a road end where the stretch that a straight line is fitted to begins
RoadAtlas.FIT_SPAN = 35.0                -- ... and where it ends
RoadAtlas.JUNCTION_FAR = 30.0            -- a junction further than this from the end of the road that found it is not believed (the lines run nearly parallel)
RoadAtlas.JUNCTION_NEAR = 14.0           -- metres: the end of a road this near to another one, across it, is a junction
RoadAtlas.MERGE = 8.0                   -- metres: dead ends this close are one
RoadAtlas.JUNCTION_MERGE = 14.0         -- metres: estimates of a junction this close are one junction (the newest estimate counts)
RoadAtlas.QUEUE_COMPACT = 64
RoadAtlas.LONG_WALK_STEPS = 8            -- a walk that has gone this many steps (24 m) on solid road ...
RoadAtlas.LONG_GAP_STEPS = 5             -- ... bridges a gap of this many steps (15 m) in the map picture (a patchy track), not just the usual 6 m
RoadAtlas.LANE_MIN_WIDTH = 6.0           -- metres: a road at least this wide is two lanes, narrower is one
RoadAtlas.LANE_MAX_WIDTH = 9.5           -- ... wider than this is no two-lane road (a track with its verge, a yard): one line
RoadAtlas.LANE_MAX_CV = 0.2              -- ... and a road whose measured width varies more than this (share of the mean) is a track with ragged edges: one line
RoadAtlas.LANE_HALF_MIN = 1.0            -- metres: the lines of the two lanes are width / 4 from the middle, but between these
RoadAtlas.LANE_HALF_MAX = 1.9

local normalize = RoadMapper.normalize
local runsOf = RoadMapper.runsOf

local function cellKey(x, z)
    return math.floor(x / RoadMapper.CELL) .. "," .. math.floor(z / RoadMapper.CELL)
end

local function mark(a, x, z, id)
    for dx = -1, 1 do
        for dz = -1, 1 do
            local key = cellKey(x + dx * RoadMapper.CELL, z + dz * RoadMapper.CELL)
            if a.visited[key] == nil then
                a.visited[key] = id
            end
        end
    end
end

local function rebuildVisited(a)
    a.visited = {}
    for _, piece in ipairs(a.pieces) do
        for _, p in ipairs(piece.points) do
            mark(a, p[1], p[2], piece.id)
        end
    end
end

local function addNear(list, x, z)
    for _, p in ipairs(list) do
        if (p[1] - x) ^ 2 + (p[2] - z) ^ 2 < RoadAtlas.MERGE ^ 2 then
            return
        end
    end
    list[#list + 1] = { x, z }
end

-- ===== walks =====

local function newWalk(sx, sz, dx, dz, id, cx, cz, a, joinAfter)
    return { x = sx, z = sz, dx = dx, dz = dz, id = id, step = 0, points = {}, ending = nil, joinAfter = joinAfter,
        cx = cx, cz = cz, reach = a.radius * RoadAtlas.WALK_REACH }
end

-- one step (at most GAP_STEPS + 1 cross sections); w.ending is set when the walk is over: "lost" | "open" | "edge" | "joins" | "long"
local function walkStep(a, w)
    if w.step >= RoadMapper.MAX_STEPS then
        w.ending = "long"
        return
    end
    w.step = w.step + 1
    local found = nil
    local gap = (w.step > RoadAtlas.LONG_WALK_STEPS or w.joinAfter == 0) and RoadAtlas.LONG_GAP_STEPS or RoadMapper.GAP_STEPS
    for ahead = 1, gap + 1 do
        found = RoadMapper.crossSection(a.read, w.x + w.dx * RoadMapper.WALK_STEP * ahead, w.z + w.dz * RoadMapper.WALK_STEP * ahead, w.dx, w.dz)
        if found ~= nil then
            break
        end
    end
    if found == nil then
        w.ending = "lost"
        return
    end
    if found.width > RoadMapper.MAX_WIDTH then
        w.ending = "open"
        return
    end
    local moved = math.sqrt((found.x - w.x) ^ 2 + (found.z - w.z) ^ 2)
    if moved < 0.5 then
        w.ending = "lost"
        return
    end
    local ndx, ndz = (found.x - w.x) / moved, (found.z - w.z) / moved
    w.dx, w.dz = normalize(w.dx * (1 - RoadMapper.DIR_BLEND) + ndx * RoadMapper.DIR_BLEND, w.dz * (1 - RoadMapper.DIR_BLEND) + ndz * RoadMapper.DIR_BLEND)
    w.x, w.z = found.x, found.z
    local owner = a.visited[cellKey(w.x, w.z)]
    if owner ~= nil and owner ~= w.id and w.step > w.joinAfter then
        w.ending, w.joinX, w.joinZ = "joins", w.x, w.z
        return
    end
    mark(a, w.x, w.z, w.id)
    w.points[#w.points + 1] = { w.x, w.z, found.class, found.width }
    if (w.x - w.cx) ^ 2 + (w.z - w.cz) ^ 2 > w.reach ^ 2 then
        w.ending = "edge"
    end
end

-- what a finished walk leaves: a dead end where the road was lost
local function noteEnding(a, w)
    if w.ending == "lost" and #w.points > 0 then
        local last = w.points[#w.points]
        addNear(a.deadEnds, last[1], last[2])
    end
end

-- ===== junctions =====
-- A walk stops where the road widens or runs into another road: at a junction. So a junction is where the END of a piece (ending "open" or "joins") is
-- near another road that runs across it (not along it): the junction is where the two centre lines cross. Looked at again whenever a piece is new, because
-- the other road may be found after this one.

-- a junction estimate: the same junction when one is known within JUNCTION_MERGE, and then the newest estimate replaces the old one (it is made from more of
-- the road, the point having come nearer: the first one, from far away, is the roughest)
local function addJunction(a, x, z)
    for _, j in ipairs(a.junctions) do
        if (j[1] - x) ^ 2 + (j[2] - z) ^ 2 < RoadAtlas.JUNCTION_MERGE ^ 2 then
            j[1], j[2] = x, z
            return
        end
    end
    a.junctions[#a.junctions + 1] = { x, z }
end

local function pieceEndDirection(piece)
    local pts = piece.points
    local n = #pts
    local i0 = math.max(1, n - 3)
    return normalize(pts[n][1] - pts[i0][1], pts[n][2] - pts[i0][2])
end

-- A straight line through points (total least squares): its centre (mx, mz) and direction (dx, dz), or nil.
local function fitLine(points)
    local n = #points
    if n < 2 then
        return nil
    end
    local mx, mz = 0, 0
    for _, q in ipairs(points) do
        mx, mz = mx + q[1], mz + q[2]
    end
    mx, mz = mx / n, mz / n
    local sxx, szz, sxz = 0, 0, 0
    for _, q in ipairs(points) do
        local dx, dz = q[1] - mx, q[2] - mz
        sxx, szz, sxz = sxx + dx * dx, szz + dz * dz, sxz + dx * dz
    end
    local angle = 0.5 * math.atan2(2 * sxz, sxx - szz)
    return mx, mz, math.cos(angle), math.sin(angle)
end

-- The stretch of a piece between FIT_SKIP and FIT_SPAN metres back from its end. Near the end the walk's middle is pulled sideways (the run of road pixels there
-- includes the opening of the other road), further back it is the road itself.
local function cleanStretch(piece, skip)
    local pts, out, arc = piece.points, {}, 0
    for i = #pts, 2, -1 do
        arc = arc + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2)
        if arc >= skip and arc <= RoadAtlas.FIT_SPAN then
            out[#out + 1] = pts[i - 1]
        end
    end
    return out
end

-- The way a piece runs at its end, read from the clean stretch (see cleanStretch), not from its last points: those are pulled sideways at a junction, and the
-- two ends of one road on either side of a side road lean opposite ways, which would make them look like roads that cross. Returns the fitted line
-- (centre and direction) or, for a piece too short for it, the end point and the direction of its last points.
local function endLine(p)
    local own = cleanStretch(p, RoadAtlas.FIT_SKIP)
    if #own < 3 then
        own = cleanStretch(p, 3.0)
    end
    local mx, mz, dx, dz = fitLine(own)
    if mx ~= nil and #own >= 3 then
        return mx, mz, dx, dz, true
    end
    local ex, ez = pieceEndDirection(p)
    return p.x, p.z, ex, ez, false
end

-- Where the road a piece ends at meets the road across it: the straight lines through the clean stretch of each (this piece's end, and the points of the other
-- pieces that run across it round the end) cross at the junction, which is then ON the straight part of both roads. Falls back to the foot of the end on the
-- other road when the lines are nearly parallel or cross far away.
local function junctionPlace(a, p, ex, ez, px0, pz0, d0x, d0z, cosLimit)
    local across = {}
    for _, q in ipairs(a.pieces) do
        if q.id ~= p.id then
            local pts = q.points
            for i = 1, #pts do
                local d2 = (pts[i][1] - ex) ^ 2 + (pts[i][2] - ez) ^ 2
                if d2 >= RoadAtlas.FIT_SKIP ^ 2 and d2 <= RoadAtlas.FIT_SPAN ^ 2 then
                    local i0, i1 = math.max(1, i - 2), math.min(#pts, i + 2)
                    if i0 ~= i1 then
                        local qdx, qdz = normalize(pts[i1][1] - pts[i0][1], pts[i1][2] - pts[i0][2])
                        if math.abs(d0x * qdx + d0z * qdz) < cosLimit then
                            across[#across + 1] = pts[i]
                        end
                    end
                end
            end
        end
    end
    local qx, qz, qdx, qdz = fitLine(across)
    if qx == nil or #across < 3 then
        return nil
    end
    local det = d0x * (-qdz) - d0z * (-qdx)
    if math.abs(det) > 0.2 then
        local rx, rz = qx - px0, qz - pz0
        local t = (rx * (-qdz) - rz * (-qdx)) / det
        local jx, jz = px0 + d0x * t, pz0 + d0z * t
        if (jx - ex) ^ 2 + (jz - ez) ^ 2 <= RoadAtlas.JUNCTION_FAR ^ 2 then
            return jx, jz
        end
    end
    local s = (ex - qx) * qdx + (ez - qz) * qdz
    return qx + qdx * s, qz + qdz * s
end

local function checkJunctions(a)
    local cosLimit = math.cos(math.rad(RoadAtlas.JUNCTION_DEG))
    for _, p in ipairs(a.pieces) do
        if (p.ending == "open" or p.ending == "joins") and not p.endChecked and #p.points >= 2 then
            p.endChecked = true
            local ex, ez = p.x, p.z
            local px0, pz0, pdx, pdz = endLine(p)
            local reach2 = RoadAtlas.JUNCTION_NEAR ^ 2
            for _, q in ipairs(a.pieces) do
                if q.id ~= p.id then
                    local best, bestD = nil, reach2
                    for i, point in ipairs(q.points) do
                        local d = (point[1] - ex) ^ 2 + (point[2] - ez) ^ 2
                        if d < bestD then
                            best, bestD = i, d
                        end
                    end
                    if best ~= nil then
                        local i0, i1 = math.max(1, best - 3), math.min(#q.points, best + 3)
                        local qdx, qdz = normalize(q.points[i1][1] - q.points[i0][1], q.points[i1][2] - q.points[i0][2])
                        if i0 ~= i1 and math.abs(pdx * qdx + pdz * qdz) < cosLimit then
                            local jx, jz = junctionPlace(a, p, ex, ez, px0, pz0, pdx, pdz, cosLimit)
                            if jx == nil then
                                jx, jz = q.points[best][1], q.points[best][2]
                            end
                            addJunction(a, jx, jz)
                            break
                        end
                    end
                end
            end
        end
    end
end

-- the ends of the pieces are looked at again (a new road may have turned one of them into a junction)
local function junctionsMayHaveChanged(a)
    for _, p in ipairs(a.pieces) do
        p.endChecked = false
    end
    a.junctionsDirty = true
end

-- a road end that reaches on (its walk stopped at the circle's edge) which a hit just beyond it belongs to
local function frontierFor(a, hx, hz)
    for _, piece in ipairs(a.pieces) do
        if piece.ending == "edge" and not piece.dead then
            local ax, az = hx - piece.x, hz - piece.z
            local along = ax * piece.dx + az * piece.dz
            local lateral = math.abs(-ax * piece.dz + az * piece.dx)
            if along >= -4 and along <= RoadAtlas.FRONTIER_GAP and lateral <= 8 then
                return piece
            end
        end
    end
    return nil
end

-- which way the road at a hit runs: the directions of the runs found on a small circle round it
local function axisAt(a, hx, hz)
    local n = math.floor(360 / RoadMapper.AXIS_STEP_DEG)
    local values = {}
    for i = 1, n do
        local angle = 2 * math.pi * (i - 1) / n
        values[i] = a.read(hx + RoadMapper.AXIS_RADIUS * math.cos(angle), hz + RoadMapper.AXIS_RADIUS * math.sin(angle))
    end
    local directions = {}
    for _, run in ipairs(runsOf(values, n, 0, true)) do
        local middle = (run.first + run.last) / 2
        local angle = 2 * math.pi * (middle - 1) / n
        directions[#directions + 1] = { math.cos(angle), math.sin(angle), angle = angle }
    end
    return directions
end

local function polylineLength(points)
    local length = 0
    for i = 2, #points do
        length = length + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
    end
    return length
end

-- the walks of one seed become pieces (one per direction, each starting at the seed); a seed whose roads are all together shorter than MIN_LENGTH is a patch
local function finishSeed(a, hx, hz, id, walks)
    local parts, total = {}, 0
    for _, w in ipairs(walks) do
        if #w.points > 0 then
            local points = { { hx, hz, 2, 0 } }
            for _, p in ipairs(w.points) do
                points[#points + 1] = p
            end
            total = total + polylineLength(points)
            parts[#parts + 1] = { w = w, points = points }
        end
    end
    if total < RoadMapper.MIN_LENGTH or #a.pieces + #parts > RoadAtlas.MAX_PIECES then
        rebuildVisited(a)            -- (the cells this seed marked must not keep other seeds away)
        return
    end
    for _, part in ipairs(parts) do
        local w = part.w
        a.pieces[#a.pieces + 1] = { id = id, points = part.points, ending = w.ending, x = w.x, z = w.z, dx = w.dx, dz = w.dz,
            extending = false, dirty = true, line = nil, kind = "road", width = 0, endChecked = false }
    end
    a.revision = a.revision + 1
    junctionsMayHaveChanged(a)
end

-- ===== jobs =====
-- The work is a queue of jobs; each run() does one small unit (a chunk of a ring, a seed's first look, one step of a walk) and sets job.done when
-- it is finished; a job may leave job.children, which go to the front of the queue. (No coroutine: the game's Lua has none.)

local extendJob

local function seedJob(a, hx, hz, cx, cz)
    local job = { done = false }
    local state, chosen, walks, k, w, id = "start", nil, nil, 0, nil, 0
    job.run = function()
        if state == "start" then
            if #a.pieces >= RoadAtlas.MAX_PIECES then
                job.done = true
            elseif a.visited[cellKey(hx, hz)] ~= nil then
                a.seedsSkipped = a.seedsSkipped + 1          -- a road already known
                job.done = true
            elseif frontierFor(a, hx, hz) ~= nil then
                -- just beyond the end of a road that is known: that road going on. Walk it on now, from its end (the extend job is run next)
                local piece = frontierFor(a, hx, hz)
                a.seedsSkipped = a.seedsSkipped + 1
                if not piece.extending then
                    piece.extending = true
                    job.children = { extendJob(a, piece) }
                end
                job.done = true
            else
                local directions = axisAt(a, hx, hz)
                if #directions == 0 then
                    a.seedsRejected = a.seedsRejected + 1    -- nothing continues from here: a patch, not a road
                    job.done = true
                else
                    a.nextId = a.nextId + 1
                    id = a.nextId
                    mark(a, hx, hz, id)
                    if #directions >= 3 then
                        addJunction(a, hx, hz)               -- more than two ways out: a junction at the seed
                    end
                    if #directions == 1 then
                        chosen = { directions[1] }
                        addNear(a.deadEnds, hx, hz)
                    else
                        chosen = directions
                    end
                    walks, k = {}, 1
                    w = newWalk(hx, hz, chosen[1][1], chosen[1][2], id, cx, cz, a, RoadMapper.JOIN_MIN_STEPS)
                    state = "walk"
                end
            end
            return
        end
        walkStep(a, w)
        if w.ending == nil then
            return
        end
        noteEnding(a, w)
        walks[k] = w
        k = k + 1
        if chosen[k] ~= nil then
            w = newWalk(hx, hz, chosen[k][1], chosen[k][2], id, cx, cz, a, RoadMapper.JOIN_MIN_STEPS)
        else
            finishSeed(a, hx, hz, id, walks)
            job.done = true
        end
    end
    return job
end

-- a ring (arc = nil) or an arc { dx, dz } (the way the point moves, +- ARC_HALF_DEG) read RING_CHUNK pixels at a time; when it is all read, every
-- run of road on it becomes a seed
local function ringJob(a, cx, cz, radius, arc)
    local job = { done = false }
    local n, start, span
    if arc == nil then
        n = math.max(12, math.ceil(2 * math.pi * radius / RoadAtlas.RING_STEP))
        start, span = 0, 2 * math.pi
    else
        local half = math.rad(RoadAtlas.ARC_HALF_DEG)
        span = 2 * half
        n = math.max(8, math.ceil(span * radius / RoadAtlas.RING_STEP)) + 1
        start = math.atan2(arc.dz, arc.dx) - half
    end
    local function angleOf(j)
        if arc == nil then
            return start + span * (j - 1) / n
        end
        return start + span * (j - 1) / (n - 1)
    end
    local values, i = {}, 1
    job.run = function()
        local last = math.min(n, i + RoadAtlas.RING_CHUNK - 1)
        for j = i, last do
            local angle = angleOf(j)
            values[j] = a.read(cx + radius * math.cos(angle), cz + radius * math.sin(angle))
        end
        i = last + 1
        if i <= n then
            return
        end
        job.children = {}
        for _, run in ipairs(runsOf(values, n, 1, arc == nil)) do
            local angle = angleOf((run.first + run.last) / 2)
            job.children[#job.children + 1] = seedJob(a, cx + radius * math.cos(angle), cz + radius * math.sin(angle), cx, cz)
        end
        job.done = true
    end
    return job
end

-- the walk of a road end that reached the edge, taken up again from where it stopped
extendJob = function(a, piece)
    local job = { done = false }
    local w = nil
    job.run = function()
        if w == nil then
            if piece.dead or piece.ending ~= "edge" then
                piece.extending = false
                job.done = true
                return
            end
            w = newWalk(piece.x, piece.z, piece.dx, piece.dz, piece.id, a.cx, a.cz, a, 0)
        end
        walkStep(a, w)
        if w.ending == nil then
            return
        end
        noteEnding(a, w)
        if not piece.dead then
            for _, p in ipairs(w.points) do
                piece.points[#piece.points + 1] = p
            end
            piece.x, piece.z, piece.dx, piece.dz = w.x, w.z, w.dx, w.dz
            piece.ending = w.ending
            piece.dirty = true
            piece.endChecked = false
            a.revision = a.revision + 1
            junctionsMayHaveChanged(a)
        end
        piece.extending = false
        a.extensions = a.extensions + 1
        job.done = true
    end
    return job
end

-- ===== the atlas =====

function RoadAtlas.new(sample, options)
    options = options or {}
    local a = {
        sample = sample, radius = options.radius or RoadAtlas.RADIUS, baseRadius = options.radius or RoadAtlas.RADIUS,
        pieces = {}, junctions = {}, deadEnds = {}, visited = {},
        queue = {}, head = 1, nextId = 0,
        samples = 0, used = 0, budget = 0, error = nil,
        seedsSkipped = 0, seedsRejected = 0, sweeps = 0, probes = 0, extensions = 0,
        started = false, cx = 0, cz = 0, revision = 0,
    }
    a.read = function(x, z)
        a.samples = a.samples + 1
        a.used = a.used + 1
        return a.sample(x, z) or 0
    end
    return a
end

-- Forget everything and sweep the rings round (x, z).
function RoadAtlas.reset(a, x, z)
    a.pieces, a.junctions, a.deadEnds, a.visited = {}, {}, {}, {}
    a.revision = a.revision + 1
    a.queue, a.head = {}, 1
    a.cx, a.cz = x, z
    a.started = true
    a.sweeps = a.sweeps + 1
    for _, f in ipairs(RoadAtlas.RING_FRACTIONS) do
        a.queue[#a.queue + 1] = ringJob(a, x, z, math.max(8, math.floor(a.radius * f + 0.5)), nil)
    end
end

local function far2(x, z, cx, cz)
    return (x - cx) ^ 2 + (z - cz) ^ 2
end

-- Forget what is far behind: the tails of roads, roads that are out of range altogether, junctions and dead ends.
local function prune(a)
    local keep2 = (a.radius * RoadAtlas.KEEP_SHARE) ^ 2
    local changed = false
    local kept = {}
    for _, piece in ipairs(a.pieces) do
        local pts = piece.points
        local first, last = 1, #pts
        while first < last and far2(pts[first][1], pts[first][2], a.cx, a.cz) > keep2 do
            first = first + 1
        end
        while last > first and far2(pts[last][1], pts[last][2], a.cx, a.cz) > keep2 do
            last = last - 1
        end
        if last - first < 1 or far2(pts[first][1], pts[first][2], a.cx, a.cz) > keep2 then
            piece.dead = true
            changed = true
        else
            if first > 1 or last < #pts then
                local out = {}
                for i = first, last do
                    out[#out + 1] = pts[i]
                end
                piece.points = out
                piece.dirty = true
                changed = true
                if last < #pts then
                    piece.ending = "trim"             -- the end that was walked is gone
                end
            end
            kept[#kept + 1] = piece
        end
    end
    a.pieces = kept
    if changed then
        a.revision = a.revision + 1
    end
    for _, list in ipairs({ a.junctions, a.deadEnds }) do
        for i = #list, 1, -1 do
            if far2(list[i][1], list[i][2], a.cx, a.cz) > keep2 then
                table.remove(list, i)
            end
        end
    end
    if changed then
        rebuildVisited(a)
    end
end

local function scheduleExtensions(a)
    local near2 = (a.radius * RoadAtlas.EXTEND_SHARE) ^ 2
    for _, piece in ipairs(a.pieces) do
        if piece.ending == "edge" and not piece.extending and far2(piece.x, piece.z, a.cx, a.cz) <= near2 then
            piece.extending = true
            a.queue[#a.queue + 1] = extendJob(a, piece)
        end
    end
end

-- the radius for a speed: the base radius at a standstill, at speed as far as the point gets in RADIUS_SECONDS (but at most MAX_RADIUS)
local function targetRadius(a, speedMs)
    return math.max(a.baseRadius, math.min(RoadAtlas.MAX_RADIUS, math.floor((speedMs or 0) * RoadAtlas.RADIUS_SECONDS + 0.5)))
end

local function probeEvery(a)
    return math.max(RoadAtlas.PROBE_EVERY, math.min(RoadAtlas.PROBE_MAX, a.radius / 10))
end

-- Call every frame with where the point is and how fast it goes (m/s, nil = not known). Cheap: it only decides what work to queue (once per probeEvery
-- metres of travel).
function RoadAtlas.update(a, x, z, speedMs)
    if not a.started then
        a.radius = targetRadius(a, speedMs)
        RoadAtlas.reset(a, x, z)
        return
    end
    local moved = math.sqrt((x - a.cx) ^ 2 + (z - a.cz) ^ 2)
    if moved < probeEvery(a) then
        return
    end
    if moved > a.radius * RoadAtlas.JUMP_SHARE then
        a.radius = targetRadius(a, speedMs)
        RoadAtlas.reset(a, x, z)
        return
    end
    -- the circle grows at once and shrinks slowly (so a short slowing down does not throw the far roads away)
    local target = targetRadius(a, speedMs)
    if target >= a.radius then
        a.radius = target
    else
        a.radius = math.max(target, a.radius - RoadAtlas.SHRINK_STEP)
    end
    local dx, dz = (x - a.cx) / moved, (z - a.cz) / moved
    a.dirX, a.dirZ = dx, dz
    a.cx, a.cz = x, z
    a.probes = a.probes + 1
    a.queue[#a.queue + 1] = ringJob(a, x, z, a.radius, { dx = dx, dz = dz })
    prune(a)
    scheduleExtensions(a)
end

-- Does about `budget` map reads of the queued work (a job is never cut in the middle, so a little more at most); true when nothing is left to do.
function RoadAtlas.step(a, budget)
    if a.error ~= nil then
        return true
    end
    a.budget = math.max(1, budget or 120)
    a.used = 0
    while a.used < a.budget do
        local job = a.queue[a.head]
        if job == nil then
            break
        end
        local ok, err = pcall(job.run)
        if not ok then
            a.error = tostring(err)
            return true
        end
        if job.done then
            a.head = a.head + 1
            if job.children ~= nil then
                for i = #job.children, 1, -1 do
                    table.insert(a.queue, a.head, job.children[i])
                end
            end
        end
    end
    if a.junctionsDirty then
        a.junctionsDirty = false
        checkJunctions(a)
    end
    if a.head > RoadAtlas.QUEUE_COMPACT then
        local out = {}
        for i = a.head, #a.queue do
            out[#out + 1] = a.queue[i]
        end
        a.queue, a.head = out, 1
    end
    return a.queue[a.head] == nil
end

function RoadAtlas.idle(a)
    return a.queue[a.head] == nil
end

-- +1 when the (drawn) line of a piece runs the way the point moves, -1 when against it, nil when across it or when the point has not moved yet. Cached per probe.
function RoadAtlas.alongWay(piece, a)
    if a.dirX == nil or piece.line == nil then
        return nil
    end
    if piece.alongAt == a.probes and piece.alongLine == piece.line then
        return piece.along
    end
    local line = piece.line
    local best, bestD = 1, math.huge
    for i, p in ipairs(line) do
        local d = (p[1] - a.cx) ^ 2 + (p[2] - a.cz) ^ 2
        if d < bestD then
            best, bestD = i, d
        end
    end
    local i0, i1 = math.max(1, best - 2), math.min(#line, best + 2)
    local along = nil
    if i0 ~= i1 then
        local dx, dz = normalize(line[i1][1] - line[i0][1], line[i1][2] - line[i0][2])
        local dot = dx * a.dirX + dz * a.dirZ
        if dot > 0.7 then
            along = 1
        elseif dot < -0.7 then
            along = -1
        end
    end
    piece.alongAt, piece.alongLine, piece.along = a.probes, piece.line, along
    return along
end

-- A line moved sideways by `offset` metres (positive = to the right of the way the line runs; the right of heading (dx, dz) is (-dz, dx) in the world).
local function offsetLine(line, offset)
    local out = {}
    local n = #line
    for i = 1, n do
        local a, b = line[math.max(1, i - 1)], line[math.min(n, i + 1)]
        local dx, dz = normalize(b[1] - a[1], b[2] - a[2])
        out[i] = { line[i][1] - dz * offset, line[i][2] + dx * offset }
    end
    return out
end

-- The smoothed centre line of a piece (despiked, a pixel's jitter is not a bend), made again only when the piece has changed. Also sets piece.kind
-- ("road" when most of it is the map's road, else "trail"), piece.width and piece.lanes (the line of each of the two lanes of a wide road, or nil).
function RoadAtlas.lineOf(piece)
    if piece.line == nil or piece.dirty then
        local points, road, widths = {}, 0, {}
        for i, p in ipairs(piece.points) do
            points[i] = { p[1], p[2] }
            if i > 1 then
                if p[3] == 2 then
                    road = road + 1
                end
                widths[#widths + 1] = p[4]
            end
        end
        local line = RoadCenterline.despike(points, math.min(2, math.floor((#points - 1) / 2)))
        line = RoadCenterline.smoothPoints(line, math.min(3, math.floor((#line - 1) / 2)))
        table.sort(widths)
        piece.line = line
        piece.kind = (#widths > 0 and road / #widths >= 0.6) and "road" or "trail"
        piece.width = widths[math.ceil(#widths / 2)] or 0
        -- a road wide enough for two lanes: the line of each lane (right / left of the way the piece runs), in the middle of the lane
        piece.lanes = nil
        local mean, sumSquares = 0, 0
        for _, width in ipairs(widths) do
            mean = mean + width
        end
        mean = #widths > 0 and mean / #widths or 0
        for _, width in ipairs(widths) do
            sumSquares = sumSquares + (width - mean) ^ 2
        end
        piece.widthCv = (#widths > 1 and mean > 0) and math.sqrt(sumSquares / #widths) / mean or 0
        if piece.kind == "road" and piece.width >= RoadAtlas.LANE_MIN_WIDTH and piece.width <= RoadAtlas.LANE_MAX_WIDTH and piece.widthCv <= RoadAtlas.LANE_MAX_CV and #line >= 2 then
            local half = math.max(RoadAtlas.LANE_HALF_MIN, math.min(RoadAtlas.LANE_HALF_MAX, piece.width / 4))
            piece.lanes = { right = offsetLine(line, half), left = offsetLine(line, -half), half = half }
        end
        piece.dirty = false
    end
    return piece.line
end
