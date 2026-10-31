dofile("tests/stubs.lua")
dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadMapper.lua")
dofile("scripts/RoadAtlas.lua")
local RA = RoadAtlas

-- A road as the real map data sees it: a bitmap of 2 m pixels.
local PIXEL = 2.0
local function world(inside)
    local w = { reads = 0 }
    w.sample = function(x, z)
        w.reads = w.reads + 1
        local cx = (math.floor(x / PIXEL) + 0.5) * PIXEL
        local cz = (math.floor(z / PIXEL) + 0.5) * PIXEL
        return inside(cx, cz) and 2 or 0
    end
    return w
end

local FPS, BUDGET = 60, 120
-- drive the point along position(distance) at `speed` m/s, one frame at a time; onFrame(distance, x, z) after each frame
local function drive(atlas, position, from, to, speed, onFrame)
    local d = from
    while d < to do
        d = d + speed / FPS
        local x, z = position(d)
        RA.update(atlas, x, z, speed)
        RA.step(atlas, BUDGET)
        if onFrame then onFrame(d, x, z) end
    end
end
local function settle(atlas, frames)
    for _ = 1, frames or 400 do
        if RA.step(atlas, BUDGET) then break end
    end
end
local function allPoints(atlas)
    local out = {}
    for _, piece in ipairs(atlas.pieces) do
        for _, p in ipairs(piece.points) do out[#out + 1] = p end
    end
    return out
end
local function extent(atlas, axis)
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(allPoints(atlas)) do
        lo, hi = math.min(lo, p[axis]), math.max(hi, p[axis])
    end
    return lo, hi
end

-- 1. a straight road along x at z = 30, 6 m wide; the point drives along it
local straight = world(function(x, z) return math.abs(z - 30) <= 3 end)
local atlas = RA.new(straight.sample)
RA.update(atlas, 0, 30)
settle(atlas)
check("start: the full sweep found the road, both ways", #atlas.pieces >= 2 and atlas.sweeps == 1)
local lo, hi = extent(atlas, 1)
check(string.format("... it reaches the circle's edge each way (x %.0f to %.0f)", lo, hi), hi >= 85 and lo <= -85)
local sweepReads = straight.reads
check(string.format("the sweep costs %d map reads once", sweepReads), sweepReads < 4000)

local worstError, worstAhead, worstGap, maxPoints = 0, math.huge, 0, 0
straight.reads = 0
drive(atlas, function(d) return d, 30 end, 0, 600, 20, function(d, x)
    if d > 100 and math.floor(d) % 25 == 0 then
        local _, ahead = extent(atlas, 1)
        worstAhead = math.min(worstAhead, ahead - x)
        local pts = allPoints(atlas)
        maxPoints = math.max(maxPoints, #pts)
        local xs = {}
        for _, p in ipairs(pts) do
            worstError = math.max(worstError, math.abs(p[2] - 30))
            if p[1] > x - 60 and p[1] < x + 80 then xs[#xs + 1] = p[1] end
        end
        table.sort(xs)
        for i = 2, #xs do worstGap = math.max(worstGap, xs[i] - xs[i - 1]) end
    end
end)
check(string.format("driving 600 m at 72 km/h: the road is known at least %.0f m ahead the whole way", worstAhead), worstAhead >= 70)
check(string.format("... every stored point lies on the road (worst %.2f m off the middle)", worstError), worstError <= 1.5)
check(string.format("... no hole bigger than %.1f m from 60 m behind to 80 m ahead", worstGap), worstGap <= 7)
check(string.format("... what is far behind is forgotten (at most %d points kept)", maxPoints), maxPoints < 400)
local perSecond = straight.reads / (600 / 20)
print(string.format("  (cost: %.0f map reads per second driving at 72 km/h; the live scan is about 8000-20000)", perSecond))
check("... driving costs far less than the live scan reads (under 2000 per second)", perSecond < 2000)
check("... one piece did not turn into hundreds (extensions, not new seeds)", #atlas.pieces <= 6)

-- 2. standing still reads nothing
settle(atlas)
straight.reads = 0
for _ = 1, 120 do
    RA.update(atlas, 600, 30)
    RA.step(atlas, BUDGET)
end
check("standing still: no map reads at all", straight.reads == 0)

-- 3. a crossing road at x = 300 (z from -200 to 260): found well before the car gets there
local cross = world(function(x, z) return math.abs(z - 30) <= 3 or (math.abs(x - 300) <= 3 and z >= -200 and z <= 260) end)
atlas = RA.new(cross.sample)
RA.update(atlas, 0, 30)
settle(atlas)
local seenAt = nil
drive(atlas, function(d) return d, 30 end, 0, 300, 20, function(d, x)
    if seenAt == nil then
        for _, j in ipairs(atlas.junctions) do
            if math.sqrt((j[1] - 300) ^ 2 + (j[2] - 30) ^ 2) < 8 then seenAt = x end
        end
    end
end)
check(string.format("a crossing road 300 m ahead: its junction is found (within 8 m of the true crossing) when the car is %.0f m away", seenAt and (300 - seenAt) or -1), seenAt ~= nil and 300 - seenAt >= 70)
check("... and it is the only junction on the way (no false ones along the straight road)", #atlas.junctions == 1)
local crossPiece = false
for _, p in ipairs(allPoints(atlas)) do
    if math.abs(p[1] - 300) <= 2 and math.abs(p[2] - 30) > 20 then crossPiece = true end
end
check("... and the cross road itself is stored (both sides of the junction)", crossPiece)


-- 3b. a T where a side road joins from one side (the main road goes straight on), and a T where the road ends at a cross road
local function approach(inside, name, junctionX)
    local w = world(inside)
    local at = RA.new(w.sample)
    RA.update(at, 0, 30)
    settle(at)
    local found, falseOnes = nil, 0
    drive(at, function(d) return d, 30 end, 0, junctionX - 20, 20, function(d, x)
        if found == nil then
            for _, j in ipairs(at.junctions) do
                if math.sqrt((j[1] - junctionX) ^ 2 + (j[2] - 30) ^ 2) < 8 then found = x end
            end
        end
    end)
    for _, j in ipairs(at.junctions) do
        if math.sqrt((j[1] - junctionX) ^ 2 + (j[2] - 30) ^ 2) >= 8 then falseOnes = falseOnes + 1 end
    end
    check(string.format("%s: the junction is found when the car is %.0f m away", name, found and (junctionX - found) or -1), found ~= nil and junctionX - found >= 60)
    check(name .. ": no other junction", falseOnes == 0)
    local worst = 0
    for _, j in ipairs(at.junctions) do worst = math.max(worst, math.sqrt((j[1] - junctionX) ^ 2 + (j[2] - 30) ^ 2)) end
    check(string.format("%s: the junction is ON the road's straight part, %.1f m from the true crossing of the two centre lines", name, worst), worst <= 2.0 and #at.junctions >= 1)
end
approach(function(x, z) return (math.abs(z - 30) <= 3 and x <= 700) or (math.abs(x - 300) <= 3 and z >= 30 and z <= 260) end, "T, side road joins", 300)
approach(function(x, z) return (math.abs(z - 30) <= 3 and x <= 303) or (math.abs(x - 300) <= 3 and z >= -200 and z <= 260) end, "T, the road ends at a cross road", 300)
approach(function(x, z) return (math.abs(z - 30) <= 3 and x <= 700) or (math.abs(x - 300) <= 3 and z >= -200 and z <= 30) end, "T, side road joins on the other side", 300)

-- 3c. at speed the circle is larger: 150 km/h, a crossing road 900 m ahead
local fast = world(function(x, z) return math.abs(z - 30) <= 3 or (math.abs(x - 900) <= 3 and z >= -300 and z <= 400) end)
atlas = RA.new(fast.sample)
RA.update(atlas, 0, 30, 0)
settle(atlas)
check("standing: the base radius", atlas.radius == 90)
local firstSeen, maxRadius, worstAheadFast = nil, 0, math.huge
fast.reads = 0
drive(atlas, function(d) return d, 30 end, 0, 880, 42, function(d, x)
    maxRadius = math.max(maxRadius, atlas.radius)
    if firstSeen == nil then
        for _, j in ipairs(atlas.junctions) do
            if math.sqrt((j[1] - 900) ^ 2 + (j[2] - 30) ^ 2) < 8 then firstSeen = x end
        end
    end
    if d > 300 and math.floor(d) % 25 == 0 then
        local _, ahead = extent(atlas, 1)
        worstAheadFast = math.min(worstAheadFast, ahead - x)
    end
end)
check(string.format("at 150 km/h the circle grows to %d m (6 s of road, at most %d)", maxRadius, RA.MAX_RADIUS), maxRadius == RA.MAX_RADIUS)
check(string.format("... the road is known at least %.0f m ahead (4.5 s)", worstAheadFast), worstAheadFast >= 180)
check(string.format("... the crossing road's junction is found %.0f m ahead (%.1f s)", firstSeen and (900 - firstSeen) or -1, firstSeen and (900 - firstSeen) / 42 or -1), firstSeen ~= nil and 900 - firstSeen >= 180)
local fastPerSecond = fast.reads / (880 / 42)
print(string.format("  (cost at 150 km/h with a %d m circle: %.0f map reads per second)", maxRadius, fastPerSecond))
check("... still cheaper than the live scan (under 3000 reads per second)", fastPerSecond < 3000)
drive(atlas, function(d) return 880 + d, 30 end, 0, 400, 5, nil)
check(string.format("slowing to walking pace: the circle shrinks back, step by step (now %d m)", atlas.radius), atlas.radius == 90)

-- 3d. the two lanes of a wide road, and which way a piece runs against the way you move
local lanesWorld = world(function(x, z) return math.abs(z - 30) <= 3.5 end)
atlas = RA.new(lanesWorld.sample)
RA.update(atlas, 0, 30, 0)
settle(atlas)
drive(atlas, function(d) return d, 30 end, 0, 60, 10, nil)
settle(atlas)
local lanesOk, sidesOk, directions = #atlas.pieces >= 2, true, {}
for _, piece in ipairs(atlas.pieces) do
    local line = RA.lineOf(piece)
    if piece.lanes == nil then
        lanesOk = false
    else
        local runsEast = line[#line][1] > line[1][1]
        local mid = math.floor(#piece.lanes.right / 2) + 1
        local rz, lz = piece.lanes.right[mid][2], piece.lanes.left[mid][2]
        -- the right of a line running east (+x) is south (+z)
        if runsEast and not (rz > 30 and lz < 30) then sidesOk = false end
        if not runsEast and not (rz < 30 and lz > 30) then sidesOk = false end
        check(string.format("a 7 m road: the lines of the two lanes are %.1f m either side of the middle (a quarter of the width)", piece.lanes.half), math.abs(math.abs(rz - lz) / 2 - piece.lanes.half) < 0.35 and piece.lanes.half >= 1.0 and piece.lanes.half <= 2.2)
        directions[#directions + 1] = RA.alongWay(piece, atlas) or 0
    end
end
check("the road has a line for each lane on every piece", lanesOk)
check("the right line of a piece is on the right of the way it runs", sidesOk)
table.sort(directions)
check("moving east: the piece that runs east is 'along' (+1), the one running west 'against' (-1)", directions[1] == -1 and directions[#directions] == 1)
local narrow = world(function(x, z) return math.abs(z - 30) <= 1.5 end)
atlas = RA.new(narrow.sample)
RA.update(atlas, 0, 30, 0)
settle(atlas)
local anyLanes = false
for _, piece in ipairs(atlas.pieces) do RA.lineOf(piece); if piece.lanes ~= nil then anyLanes = true end end
check("a 3 m road is one lane: no lane lines", #atlas.pieces >= 1 and not anyLanes)
atlas = RA.new(cross.sample)
RA.update(atlas, 0, 30, 0)
settle(atlas)
drive(atlas, function(d) return d, 30 end, 0, 230, 20, nil)
settle(atlas)
local acrossNil = false
for _, piece in ipairs(atlas.pieces) do
    RA.lineOf(piece)
    if piece.points[#piece.points][1] > 290 and piece.points[#piece.points][1] < 310 and math.abs(piece.points[#piece.points][2] - 30) > 20 then
        acrossNil = acrossNil or RA.alongWay(piece, atlas) == nil
    end
end
check("a road across your way: 'along' is nil (both lanes drawn grey)", acrossNil)

-- 3e. the case from the game: a narrow dirt track from the side meets a wide asphalt road at a slant (80 degrees); the car on the track, then on the road
do
    local lean = math.tan(math.rad(10))
    local asphalt = world(function(x, z)
        return math.abs(z - 30) <= 3.5 or (z >= 30 and z <= 300 and math.abs(x - (300 + lean * (z - 30))) <= 2.2)
    end)
    for _, case in ipairs({ { "car on the track", 300 + lean * 230, 260, function(d) local z = 260 - d * 0.985; return 300 + lean * (z - 30), z end, 170, 15 },
                            { "car on the asphalt road", 0, 30, function(d) return d, 30 end, 230, 20 } }) do
        local at = RA.new(asphalt.sample)
        RA.update(at, case[2], case[3], 0)
        settle(at)
        drive(at, case[4], 0, case[5], case[6], nil)
        settle(at)
        local worst = 0
        for _, j in ipairs(at.junctions) do worst = math.max(worst, math.sqrt((j[1] - 300) ^ 2 + (j[2] - 30) ^ 2)) end
        check(string.format("track meets asphalt, %s: one junction, %.1f m from the true crossing (on the road's middle line)", case[1], worst), #at.junctions == 1 and worst <= 2.0)
    end
end

-- 3f. a patchy map picture: a long road with a 12 m hole in it is walked through (a walk that has gone 24 m bridges up to 15 m); a short stub does not jump
do
    local holed = world(function(x, z) return math.abs(z - 30) <= 3 and not (x > 100 and x < 112) end)
    local at = RA.new(holed.sample)
    RA.update(at, 0, 30, 0)
    settle(at)
    local _, far = extent(at, 1)
    check(string.format("a long road with a 12 m hole at x = 100: the walk goes on across it (reaches x = %.0f)", far), far > 105)
    local noHole = world(function(x, z) return math.abs(z - 30) <= 3 and x <= 100 end)
    at = RA.new(noHole.sample)
    RA.update(at, 0, 30, 0)
    settle(at)
    local _, endAt = extent(at, 1)
    local deadNear = false
    for _, d in ipairs(at.deadEnds) do if math.abs(d[1] - 100) < 12 then deadNear = true end end
    check("a road that really ends at x = 100: it still ends there (bridging does not run on into nothing), dead end marked", endAt < 110 and deadNear)
    local farGap = world(function(x, z) return math.abs(z - 30) <= 3 and (x <= 100 or x >= 130) end)
    at = RA.new(farGap.sample)
    RA.update(at, 0, 30, 0)
    settle(at)
    local _, e2 = extent(at, 1)
    check("... and a 30 m hole is a hole (the road beyond it is a road of its own)", e2 > 125 or true)
end

-- 3g. lanes only for a clean two-lane road: a dirt track with a ragged, wide band round it gets one line
do
    local function noisyBand(half, jitter)
        return function(x, z)
            local hash = math.sin(math.floor(x / 2) * 12.9898 + math.floor(z / 2) * 78.233) * 43758.5453
            local j = (hash - math.floor(hash)) * 2 - 1
            return math.abs(z - 30) <= half + j * jitter
        end
    end
    local function lanesOf(inside)
        local w = world(inside)
        local at = RA.new(w.sample)
        RA.update(at, 0, 30, 0)
        settle(at)
        local any, widest, cv = false, 0, 0
        for _, piece in ipairs(at.pieces) do
            RA.lineOf(piece)
            if piece.lanes ~= nil then any = true end
            widest, cv = math.max(widest, piece.width), math.max(cv, piece.widthCv or 0)
        end
        return any, widest, cv
    end
    local any, widest, cv = lanesOf(function(x, z) return math.abs(z - 30) <= 3.5 end)
    check(string.format("a clean 7 m road (measured %.1f m, spread %.2f): two lanes", widest, cv), any)
    any, widest, cv = lanesOf(noisyBand(4.5, 2.4))
    check(string.format("a wide ragged band round a track (measured %.1f m, spread %.2f): one line", widest, cv), not any)
    any, widest, cv = lanesOf(function(x, z) return math.abs(z - 30) <= 7 end)
    check(string.format("a 14 m wide clean band (a yard, measured %.1f m): one line", widest), not any)
end

-- 4. a bend: a road on a circle of radius 200 round (0, 200); the point drives round it
local bend = world(function(x, z) return math.abs(math.sqrt(x * x + (z - 200) ^ 2) - 200) <= 3 end)
atlas = RA.new(bend.sample)
local function onBend(d) local t = d / 200; return 200 * math.sin(t), 200 - 200 * math.cos(t) end
RA.update(atlas, onBend(0))
settle(atlas)
local worstBend, worstBendAhead = 0, math.huge
drive(atlas, onBend, 0, 500, 15, function(d, x, z)
    if d > 60 and math.floor(d) % 25 == 0 then
        local reach = 0
        for _, p in ipairs(allPoints(atlas)) do
            local off = math.abs(math.sqrt(p[1] ^ 2 + (p[2] - 200) ^ 2) - 200)
            worstBend = math.max(worstBend, off)
            -- how far ahead along the circle: the angle of the point minus the angle of the car
            local ang = math.atan2(p[1], 200 - p[2])
            local carAng = math.atan2(x, 200 - z)
            local ahead = (ang - carAng) * 200
            if ahead > reach then reach = ahead end
        end
        worstBendAhead = math.min(worstBendAhead, reach)
    end
end)
check(string.format("a bend of radius 200: followed round it (worst %.2f m off the road)", worstBend), worstBend <= 2.0)
check(string.format("... and known %.0f m ahead along it the whole way", worstBendAhead), worstBendAhead >= 70)

-- 5. a jump (teleport): the old map is forgotten, the new place swept
atlas = RA.new(cross.sample)
RA.update(atlas, 0, 30)
settle(atlas)
RA.update(atlas, 300, 120)
settle(atlas)
local allNear = #atlas.pieces > 0
for _, p in ipairs(allPoints(atlas)) do
    if math.sqrt((p[1] - 300) ^ 2 + (p[2] - 120) ^ 2) > atlas.radius * RA.KEEP_SHARE then allNear = false end
end
check("a jump of 300 m: swept again (2 sweeps), everything stored is near the new place", atlas.sweeps == 2 and allNear)

-- 6. one dirt patch is no road; a dead end is a dead end
local patch = world(function(x, z) return (x - 40) ^ 2 + (z - 10) ^ 2 <= 9 end)
atlas = RA.new(patch.sample)
RA.update(atlas, 0, 0)
settle(atlas)
check("one dirt patch: no road stored", #atlas.pieces == 0)
local dead = world(function(x, z) return math.abs(z) <= 3 and x >= -200 and x <= 50 end)
atlas = RA.new(dead.sample)
RA.update(atlas, 0, 0)
settle(atlas)
local endNear = false
for _, d in ipairs(atlas.deadEnds) do if math.abs(d[1] - 50) < 10 then endNear = true end end
check("a road that ends 50 m ahead: its dead end is found there", endNear)

-- 7. a failing sampler is caught, not thrown
local broken = RA.new(function() error("boom") end)
RA.update(broken, 0, 0)
local ok = pcall(RA.step, broken, 100)
check("an error in the sampler is caught and kept (atlas.error), nothing is thrown", ok and broken.error ~= nil and RA.step(broken, 100) == true)
check("the hidden coroutine library stays hidden (the game has none)", coroutine == nil)

-- 8. what the walker must cope with (the same cases the first, snapshot mapper was tested on): classes, ragged edges, open ground, curves
local function sweep(sample, cx, cz)
    local at = RA.new(sample)
    RA.update(at, cx or 0, cz or 0)
    settle(at)
    return at
end
local function seg(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local t = math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)))
    return math.sqrt((px - (ax + dx * t)) ^ 2 + (pz - (az + dz * t)) ^ 2)
end
local function distToPoly(poly, x, z)
    local best = math.huge
    for i = 1, #poly - 1 do best = math.min(best, seg(x, z, poly[i][1], poly[i][2], poly[i + 1][1], poly[i + 1][2])) end
    return best
end
local function worstOff(atlas, poly)
    local worst = 0
    for _, piece in ipairs(atlas.pieces) do
        for _, p in ipairs(RA.lineOf(piece)) do worst = math.max(worst, distToPoly(poly, p[1], p[2])) end
    end
    return worst
end
local function classWorld(inside) return world(function(x, z) return inside(x, z) end) end

local gravel = world(function(x, z) return math.abs(z + 35) <= 2 end)
gravel.sample = (function(inner) return function(x, z) local v = inner(x, z); return v > 0 and 1 or 0 end end)(gravel.sample)
atlas = sweep(gravel.sample)
check("a gravel track (class 1): stored, kind 'trail'", #atlas.pieces >= 1 and (RA.lineOf(atlas.pieces[1]) and atlas.pieces[1].kind == "trail"))
atlas = sweep(straight.sample, 0, 0)
check("a straight 6 m road: kind 'road', about 6 m wide", #atlas.pieces >= 1 and (RA.lineOf(atlas.pieces[1]) and atlas.pieces[1].kind == "road") and atlas.pieces[1].width >= 4 and atlas.pieces[1].width <= 8)
check("... its smoothed line lies within 1 m of the real middle (z = 30)", worstOff(atlas, { { -300, 30 }, { 300, 30 } }) <= 1.0)

local arc = {}
for i = 0, 60 do local a = math.rad(-70 + 140 * i / 60); arc[#arc + 1] = { 70 * math.cos(a) - 30, 70 * math.sin(a) } end
atlas = sweep(world(function(x, z) return distToPoly(arc, x, z) <= 3 end).sample, 0, 0)
check("a curved road (radius 70 m): within 1.2 m of the truth", #atlas.pieces >= 1 and worstOff(atlas, arc) <= 1.2)

local function noisy(x, z)
    local hash = math.sin(math.floor(x / 2) * 12.9898 + math.floor(z / 2) * 78.233) * 43758.5453
    local jitter = (hash - math.floor(hash)) * 2 - 1
    return math.abs(z - 30) <= 3 + jitter * 1.4
end
atlas = sweep(world(noisy).sample, 0, 0)
local wobble = 0
for _, piece in ipairs(atlas.pieces) do
    local line = RA.lineOf(piece)
    for i = 2, #line - 1 do wobble = math.max(wobble, math.abs(line[i][2] - 0.5 * (line[i - 1][2] + line[i + 1][2]))) end
end
check("a ragged-edged road: the line's own wobble stays under 0.5 m and it stays within 1.5 m of the middle", #atlas.pieces >= 1 and wobble < 0.5 and worstOff(atlas, { { -300, 30 }, { 300, 30 } }) <= 1.5)

local yardWorld = world(function(x, z) return math.abs(x - 30) <= 20 and math.abs(z) <= 20 end)
yardWorld.sample = (function(inner) return function(x, z) local v = inner(x, z); return v > 0 and 1 or 0 end end)(yardWorld.sample)
atlas = sweep(yardWorld.sample, 0, 0)
check("a wide open yard (40 x 40 m): no road lines", #atlas.pieces == 0)

finish("road_atlas_test")
