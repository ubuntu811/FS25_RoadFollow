dofile("tests/stubs.lua")
dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadMapper.lua")
local M = RoadMapper

local PIXEL = 2.0
local calls = 0
local function rasterised(inside)
    return function(x, z)
        calls = calls + 1
        local cx = (math.floor(x / PIXEL) + 0.5) * PIXEL
        local cz = (math.floor(z / PIXEL) + 0.5) * PIXEL
        return inside(cx, cz) or 0
    end
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
local function runAll(map, cx, cz, options, budget)
    local m = M.new(map, cx, cz, options)
    local steps = 0
    while not M.step(m, budget or 400) do
        steps = steps + 1
        if steps > 100000 then break end
    end
    return m, steps
end
local function worstError(trace, truthPoly)
    local worst = 0
    for _, p in ipairs(trace.points) do worst = math.max(worst, distToPoly(truthPoly, p[1], p[2])) end
    return worst
end

-- 1. a straight road past the point, 6 m wide (class 2): found, one line, close to the truth
calls = 0
local straight = rasterised(function(x, z) return math.abs(z - 30) <= 3 and 2 or 0 end)
local m, steps = runAll(straight, 0, 0)
check("a straight road 30 m off: mapped as one road", m.error == nil and #m.traces >= 1)
local t = m.traces[1]
check("... a 'road' kind, about 6 m wide", t ~= nil and t.kind == "road" and t.width >= 4 and t.width <= 8)
check("... its line lies within 1 m of the real middle (z = 30)", t ~= nil and worstError(t, { { -200, 30 }, { 200, 30 } }) <= 1.0)
check("... and it is long (over 100 m)", t ~= nil and t.length > 100)
check("the work was time-sliced over several steps", steps >= 3)

-- 2. a crossing of two roads: both found, a junction noted
local cross = rasterised(function(x, z) return (math.abs(z - 20) <= 3 or math.abs(x - 25) <= 3) and 2 or 0 end)
m = runAll(cross, 0, 0)
check("a crossing of two roads: both roads mapped", #m.traces >= 2)
local nearJunction = false
for _, j in ipairs(m.junctions) do if math.sqrt((j[1] - 25) ^ 2 + (j[2] - 20) ^ 2) < 12 then nearJunction = true end end
check("... and the junction is noted", nearJunction)

-- 3. a single patch of dirt (6 x 6 m) is no road
local patch = rasterised(function(x, z) return (math.abs(x - 40) <= 3 and math.abs(z) <= 3) and 1 or 0 end)
m = runAll(patch, 0, 0)
check("one dirt patch: no road at all", #m.traces == 0)

-- 4. a gravel track (class 1) is a trail
local trail = rasterised(function(x, z) return math.abs(z + 35) <= 2 and 1 or 0 end)
m = runAll(trail, 0, 0)
check("a gravel track: mapped, kind 'trail'", #m.traces >= 1 and m.traces[1].kind == "trail")

-- 5. a curved road: smooth, accurate
local arc = {}
for i = 0, 60 do local a = math.rad(-70 + 140 * i / 60); arc[#arc + 1] = { 70 * math.cos(a) - 30, 70 * math.sin(a) } end
local curved = rasterised(function(x, z) return distToPoly(arc, x, z) <= 3 and 2 or 0 end)
m = runAll(curved, 0, 0)
t = m.traces[1]
check("a curved road (radius 70 m): mapped within 1.2 m of the truth", t ~= nil and worstError(t, arc) <= 1.2)

-- 6. ragged edges: the road's edge is noisy by a pixel either side; the line stays steady
local function noisy(x, z)
    local hash = math.sin(math.floor(x / 2) * 12.9898 + math.floor(z / 2) * 78.233) * 43758.5453
    local jitter = (hash - math.floor(hash)) * 2 - 1          -- -1 .. 1
    return (math.abs(z - 30) <= 3 + jitter * 1.4) and 2 or 0
end
m = runAll(rasterised(noisy), 0, 0)
t = m.traces[1]
local wobble = 0
if t ~= nil then
    for i = 2, #t.points - 1 do
        local dev = math.abs(t.points[i][2] - 0.5 * (t.points[i - 1][2] + t.points[i + 1][2]))
        wobble = math.max(wobble, dev)
    end
end
check("a ragged-edged road: the line's own wobble stays under 0.5 m (smoothed)", t ~= nil and wobble < 0.5 and worstError(t, { { -200, 30 }, { 200, 30 } }) <= 1.5)

-- 7. open ground (a 40 x 40 m yard) is not walked as a road
local yard = rasterised(function(x, z) return (math.abs(x - 30) <= 20 and math.abs(z) <= 20) and 1 or 0 end)
m = runAll(yard, 0, 0)
check("a wide open yard: no road lines", #m.traces == 0)

-- 8. cost: reads for the straight road case (the current row scan needs about 620 per scan)
calls = 0
m = runAll(straight, 0, 0)
check(string.format("a whole map around the point costs %d map reads once (the current scan costs about 620 per scan, 20 scans a second)", m.samples), m.samples < 9000)
check("the sampler count matches the counted reads", m.samples == calls)


-- 9. the far look: the road followed straight ahead, round its bends, cheaply
do
    local before = calls
    local walk = M.walkAhead(straight, 0, 30, 1, 0, 200, 4)
    check("a straight road: the walk follows it the whole 200 m", walk.ending == "long" and #walk.points >= 50 and walk.points[#walk.points][1] > 190)
    check("... close to its middle (z = 30)", math.abs(walk.points[#walk.points][2] - 30) < 0.8)
    check(string.format("... for about %d map reads (13 per step)", calls - before), calls - before < 900)
    -- a bend of radius 120 m starting 100 m ahead
    local bendPoly = { { -50, 0 }, { 100, 0 } }
    for i = 1, 40 do local a = math.rad(70) * i / 40; bendPoly[#bendPoly + 1] = { 100 + 120 * math.sin(a), 120 * (1 - math.cos(a)) } end
    bendPoly[#bendPoly + 1] = { bendPoly[#bendPoly][1] + 200 * math.cos(math.rad(70)), bendPoly[#bendPoly][2] + 200 * math.sin(math.rad(70)) }
    local bend = rasterised(function(x, z) return distToPoly(bendPoly, x, z) <= 3 and 2 or 0 end)
    walk = M.walkAhead(bend, 0, 0, 1, 0, 250, 4)
    local worst = 0
    for _, p in ipairs(walk.points) do worst = math.max(worst, distToPoly(bendPoly, p[1], p[2])) end
    check(string.format("a bend (radius 120) 100 m ahead: the walk follows it round (within 1.5 m of the real road; worst %.2f)", worst), walk.ending == "long" and worst <= 1.5)
    local profile = RoadCenterline.curvatureProfile(M.farLine(walk.points), 40)
    local peak, at = 0, 0
    for _, e in ipairs(profile) do if e.kappa > peak then peak, at = e.kappa, e.d end end
    check(string.format("... and its curvature profile finds the bend: about 1/120 (%.4f) at 100-200 m (at %.0f m)", peak, at), peak > 0.005 and peak < 0.013 and at > 90 and at < 220)
    -- a road that stops: the walk says so
    local stub = rasterised(function(x, z) return (x < 80 and math.abs(z) <= 3) and 2 or 0 end)
    walk = M.walkAhead(stub, 0, 0, 1, 0, 200, 4)
    check("a road that ends 80 m ahead: the walk ends 'lost' near there", walk.ending == "lost" and walk.points[#walk.points][1] > 60 and walk.points[#walk.points][1] < 90)
end

finish("road_mapper_test")
