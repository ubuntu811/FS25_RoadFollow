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
local straight = rasterised(function(x, z) return math.abs(z - 30) <= 3 and 2 or 0 end)

-- the far look: the road followed straight ahead, round its bends, cheaply
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
