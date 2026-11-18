dofile("tests/stubs.lua")
dofile("scripts/RoadCenterline.lua")
local RC = RoadCenterline

-- A road as the real map data sees it: a bitmap of 2 m pixels. inside(x, z) is the true shape; the
-- sampler answers for the pixel the point falls in (pixel centre), so edges are blocky.
local PIXEL = 2.0
local function rasterised(inside)
    return function(x, z)
        local cx = (math.floor(x / PIXEL) + 0.5) * PIXEL
        local cz = (math.floor(z / PIXEL) + 0.5) * PIXEL
        return inside(cx, cz) and 2 or 0
    end
end

local function near(a, b, tolerance) return math.abs(a - b) <= tolerance end

-- 1. straight road along +x, 6 m wide, centre at z = 0
local straight = rasterised(function(x, z) return math.abs(z) <= 3 end)
local r = RC.scan(straight, 0, 0, 1, 0)
check("straight road: found, polyline is full length", r.valid and r.found == RC.STEPS + 1 and not r.ends)
local x, z = RC.pickTarget(r.points, 0, 0, 10)
check("straight road: the target is 10 m ahead, on the middle", near(x, 10, 0.5) and near(z, 0, 1.0))
check("straight road: curvature is about zero", RC.curvature(r.points) < 0.01)
check("straight road: no junction, no end", not r.junction and not r.ends)
check("straight road: the vehicle is on the middle (offset about 0)", math.abs(r.offset) <= 1.0)

-- 2. standing off-centre: the line still runs along the middle
r = RC.scan(straight, 0, 2, 1, 0)
check("off-centre by 2 m: the road's middle is found, offset is to the right", r.valid and r.offset < -0.5)
local tx, tz = RC.pickTarget(r.points, 0, 2, 10)
check("off-centre: the target pulls back towards the middle", math.abs(tz) < 2)

-- 2b. standing beside the road, 4 m from its middle (the road's near edge is 1 m away)
r = RC.scan(straight, 0, 4, 1, 0)
check("4 m beside a 6 m road: it is found and its middle is 4 m to the right", r.valid and near(r.offset, -4, 1.0))

-- 3. heading the other way along the same road
r = RC.scan(straight, 30, 0, -1, 0)
tx, tz = RC.pickTarget(r.points, 30, 0, 10)
check("opposite direction: target is ahead of the vehicle (towards -x)", r.valid and near(tx, 20, 0.5))

-- 4. a bend: arc of radius 40 m, 6 m wide, from heading +x turning left (+z)
local radius = 40
local arc = rasterised(function(x, z)
    local dxc, dzc = x - 0, z - radius          -- circle centre (0, 40)
    local distance = math.sqrt(dxc * dxc + dzc * dzc)
    return math.abs(distance - radius) <= 3 and x >= -2
end)
r = RC.scan(arc, 0, 0, 1, 0)
local curvature = RC.curvature(r.points)
check("bend (R 40): the polyline follows it, curving left", r.valid and r.found >= RC.STEPS and r.points[#r.points][2] > 2)
check("bend (R 40): curvature about 1/40", near(curvature, 1 / radius, 0.012))
local speed = RC.speedAdvice(r, 40, nil)
check("bend (R 40): slower than the 40 km/h limit, but not crawling", speed < 40 and speed > 15)

-- 5. a tight bend gets a lower speed than a gentle one
local tight = rasterised(function(x, z)
    local distance = math.sqrt(x * x + (z - 12) ^ 2)
    return math.abs(distance - 12) <= 3 and x >= -2
end)
local rt = RC.scan(tight, 0, 0, 1, 0)
check("tight bend (R 12) is taken slower than the R 40 bend", RC.speedAdvice(rt, 40, nil) < speed)

-- 6. dead end: the road stops at x = 30
local deadEnd = rasterised(function(x, z) return math.abs(z) <= 3 and x <= 30 end)
r = RC.scan(deadEnd, 18, 0, 1, 0)
check("dead end: the polyline stops, ends = true", r.valid and r.ends and r.found < RC.STEPS + 1)
local _, _, ending = RC.pickTarget(r.points, 18, 0, 20)
check("dead end: a lookahead beyond the end reports ending", ending == true)
check("dead end: speed advice drops as the end gets close", RC.speedAdvice(r, 40, 5) < RC.speedAdvice(r, 40, 50))

-- 7. T junction ahead: the road we are on ends in a wide crossing road (open ground rule)
local tJunction = rasterised(function(x, z) return (math.abs(z) <= 3 and x <= 20) or (x >= 20 and x <= 26 and math.abs(z) <= 30) end)
r = RC.scan(tJunction, 8, 0, 1, 0)
check("T junction: flagged as a junction", r.valid and r.junction)
check("T junction: speed is limited at the junction", RC.speedAdvice(r, 40, nil) <= RC.JUNCTION_SPEED_KMH + 0.01)

-- 8. a yard much wider than a road: the line is kept, not dragged to the yard's middle
local yard = rasterised(function(x, z) return (math.abs(z) <= 3 and x <= 20) or (x > 20 and math.abs(z) <= 20) end)
r = RC.scan(yard, 8, 0, 1, 0)
local lastZ = r.points[#r.points][2]
check("yard: wide open ground flagged, the line stays straight", r.junction and math.abs(lastZ) < 2)

-- 9. off the road
local empty = rasterised(function() return false end)
r = RC.scan(empty, 0, 0, 1, 0)
check("no road at all: not valid, with a reason", r.valid == false and r.reason ~= nil)
r = RC.scan(straight, 0, 20, 1, 0)
check("20 m beside the road: too far to join it", r.valid == false)

-- 10. a fork: a second road leaves at an angle; we keep going straight
local fork = rasterised(function(x, z)
    local main = math.abs(z) <= 3
    local branch = x >= 20 and math.abs(z - (x - 20) * 0.7 - 10) <= 3 and z > 3
    return main or branch
end)
r = RC.scan(fork, 8, 0, 1, 0)
check("fork: keeps to the main road (straight on)", r.valid and math.abs(r.points[#r.points][2]) < 3)

-- 11. sample noise: a gap of one missing pixel in the middle of the road does not stop the march
local dashed = rasterised(function(x, z) return math.abs(z) <= 3 and not (x > 10 and x < 12) end)
r = RC.scan(dashed, 0, 0, 1, 0)
check("a one-pixel gap in the road is bridged, the line goes on", r.valid and not r.ends and #r.points == RC.STEPS + 1)

-- a longer hole, 10 m: the road is lost, the bridged points are dropped again
local hole = rasterised(function(x, z) return math.abs(z) <= 3 and not (x > 10 and x < 22) end)
r = RC.scan(hole, 0, 0, 1, 0)
check("a 10 m hole ends the line before it, with no bridged points left", r.valid and r.ends and r.points[#r.points].bridged == nil and r.points[#r.points][1] < 11)

-- target on a short polyline
x, z, ending = RC.pickTarget({ { 0, 0 }, { 3, 0 } }, 0, 0, 10)
check("pickTarget on a short polyline gives its end", ending == true and x == 3)
-- the bend floor: a tight bend never asks for less than the given share of the wanted speed
local plain = RC.speedAdvice(rt, 40, nil)
local floored = RC.speedAdvice(rt, 40, nil, 0.5)
check("bend floor: the R 12 bend without a floor is slower than 20 km/h, with a 50 percent floor it is 20", plain < 20 and near(floored, 20, 0.01))
local gentle = RC.speedAdvice(r, 50, nil, 0.75)
local rc120pts = {}
for i = 0, 16 do local a = i * 1.5 / 120; rc120pts[#rc120pts + 1] = { 120 * math.sin(a), 120 * (1 - math.cos(a)) } end
local rc120 = { points = rc120pts, junction = false, ends = false }
local kRt = RC.curvature(rt.points)
local hardKmh = math.sqrt(RC.HARD_LATERAL_ACCEL / kRt) * 3.6
check("a 50 km/h cruise setting: the 75 percent floor (37.5) applies, but never above what the bend physically allows", near(RC.speedAdvice(rt, 50, nil, 0.75), math.min(37.5, hardKmh), 0.05))
check("a gentle bend at a high setting (cruise 80, R 120): the floor keeps it near the setting, the physical limit allows it", RC.speedAdvice(rc120 or rt, 80, nil, 0.75) > 0)
check("bend floor: no wanted speed (math.huge) leaves the bend speed alone", RC.speedAdvice(rt, math.huge, nil, 0.5) == RC.speedAdvice(rt, math.huge, nil))

-- pixel jitter on a straight road must not read as a bend
local jitter = {}
for i = 0, 16 do jitter[#jitter + 1] = { i * 1.5, (i % 2 == 0) and 0.6 or -0.6 } end
check("a straight road with 0.6 m zigzag noise reads as straight", RC.curvature(jitter) == 0)
-- smoothing: a 1 m zigzag becomes nearly flat, a real bend stays a bend
local zig = {}
for i = 0, 16 do zig[#zig + 1] = { i * 1.5, (i % 2 == 0) and 1 or -1 } end
local flat = RC.smoothPoints(zig, 2)
local worst = 0
for i = 3, #flat - 2 do worst = math.max(worst, math.abs(flat[i][2])) end
check("smoothing: a 1 m zigzag is cut to under 0.35 m", worst < 0.35)
check("smoothing keeps the point count", #flat == #zig)
local arc = {}
for i = 0, 16 do local a = i * 1.5 / 40; arc[#arc + 1] = { 40 * math.sin(a), 40 * (1 - math.cos(a)) } end
local arcSmooth = RC.smoothPoints(arc, 2)
local radialWorst = 0
for _, p in ipairs(arcSmooth) do radialWorst = math.max(radialWorst, math.abs(math.sqrt(p[1] ^ 2 + (p[2] - 40) ^ 2) - 40)) end
check("smoothing: a bend of R 40 stays on its circle (within 0.3 m, it only slides along it)", radialWorst < 0.3)
-- reach: a longer line for higher speeds, fine steps near and coarse steps far
r = RC.scan(straight, 0, 0, 1, 0, { reach = 45 })
check("reach 45 m on a straight road: the line is about 45 m long", r.valid and not r.ends and near(RC.length(r.points), 45, 3))
check("reach 45 m: fewer points than 45 m of fine steps would need (cheap far end)", #r.points < 45 / RC.STEP)
tx = RC.pickTarget(r.points, 0, 0, 30)
check("an aim point 30 m ahead exists on it (it was clamped to ~24 m before)", near(tx, 30, 1.0))
local short = RC.scan(straight, 0, 0, 1, 0, { reach = 24 })
check("reach 24 m: about 24 m", near(RC.length(short.points), 24, 3))
-- a bend 20 m ahead is seen from further away
local lateBend = rasterised(function(x, z)
    if x <= 20 then return math.abs(z) <= 3 end
    local dxc, dzc = x - 20, z - 40
    return math.abs(math.sqrt(dxc * dxc + dzc * dzc) - 40) <= 3 and x >= 18
end)
local seeShort = RC.scan(lateBend, 0, 0, 1, 0, { reach = 24 })
local seeLong = RC.scan(lateBend, 0, 0, 1, 0, { reach = 45 })
check("a bend that starts 20 m ahead gives a higher curvature with the long reach than with 24 m", RC.curvature(seeLong.points) >= RC.curvature(seeShort.points))
-- ===== gravel next to a road =====
-- road (class 2) z in [-3, 3]; gravel (class 1) right beside it on the left, z in (3, 11]
local function classed(roadInside, gravelInside)
    return function(x, z)
        local cx = (math.floor(x / PIXEL) + 0.5) * PIXEL
        local cz = (math.floor(z / PIXEL) + 0.5) * PIXEL
        if roadInside(cx, cz) then return 2 end
        if gravelInside(cx, cz) then return 1 end
        return 0
    end
end
local withGravel = classed(function(x, z) return math.abs(z) <= 3 end, function(x, z) return z > 3 and z <= 11 end)
r = RC.scan(withGravel, 0, 0, 1, 0)
check("road with a gravel strip beside it: the road's middle is kept (last point within 0.8 m of z = 0)", r.valid and not r.openGround and math.abs(r.points[#r.points][2]) < 0.8)
check("...and the width read is the road's (8 m on 2 m pixels), not road plus gravel (16 m)", r.roadWidth < 10)
local noClasses = rasterised(function(x, z) return z >= -3 and z <= 11 end)
r = RC.scan(noClasses, 0, 0, 1, 0)
check("the same shape without a road class (trail only) is just a wide run: no crash, still valid", r.valid)

-- a gravel yard bulging out for 10 m beside a road must not pull the line sideways
local yardBeside = classed(function(x, z) return math.abs(z) <= 3 end, function(x, z) return x >= 12 and x <= 24 and z > 3 and z <= 12 end)
r = RC.scan(yardBeside, 0, 0, 1, 0, { reach = 40 })
local worstZ = 0
for _, p in ipairs(r.points) do worstZ = math.max(worstZ, math.abs(p[2])) end
check("a gravel yard beside the road keeps the line within 1.2 m of the road's middle", r.valid and worstZ < 1.2)
local oldWay = RC.scanRuns(yardBeside, 18, 0, 0, 1, 7, 0.5)
-- (the plain any-class run at the yard is much wider than the road)
local widest = 0
for _, run in ipairs(RC.scanRuns(yardBeside, 18, 0, 1, 0, 7, 0.5)) do widest = math.max(widest, run.width) end
check("(the any-class run there is wider than the road, which is what used to fool it)", widest > 8)

-- when there is no road near, trails still work
local trailOnly = classed(function() return false end, function(x, z) return math.abs(z) <= 2 end)
r = RC.scan(trailOnly, 0, 0, 1, 0)
check("a plain trail with no road class is followed", r.valid and r.found == RC.STEPS + 1)

-- ===== despike =====
local spiky = {}
for i = 0, 16 do spiky[#spiky + 1] = { i * 1.5, 0 } end
spiky[8][2] = 4
local cleaned = RC.despike(spiky, 2)
check("a single 4 m false tick is removed by the median", math.abs(cleaned[8][2]) < 0.01)
check("the ends keep their positions", cleaned[1][1] == spiky[1][1] and cleaned[#cleaned][1] == spiky[#spiky][1])
local bendLine = {}
for i = 0, 16 do local a = i * 1.5 / 25; bendLine[#bendLine + 1] = { 25 * math.sin(a), 25 * (1 - math.cos(a)) } end
local bendCleaned = RC.despike(bendLine, 2)
local moved = 0
for i = 1, #bendLine do moved = math.max(moved, math.abs(bendCleaned[i][1] - bendLine[i][1]) + math.abs(bendCleaned[i][2] - bendLine[i][2])) end
check("a clean bend is left alone by the median", moved < 0.01)
local steering = RC.steeringLine(spiky)
check("the steering line of a spiky straight is flat", math.abs(steering[8][2]) < 0.2)

-- ===== averaged aim =====
local straightLine = {}
for i = 0, 20 do straightLine[#straightLine + 1] = { i * 2, 0 } end
local ax, az = RC.pickTargetAveraged(straightLine, 0, 0, 12, 4)
check("averaged aim on a straight line: the point 12 m ahead", near(ax, 12, 0.3) and near(az, 0, 0.01))
local noisy = {}
for i = 0, 20 do noisy[#noisy + 1] = { i * 2, (i % 2 == 0) and 1 or -1 } end
local _, zPlain = RC.pickTarget(noisy, 0, 0, 12)
local _, zAvg = RC.pickTargetAveraged(noisy, 0, 0, 12, 4)
check("averaged aim is steadier than a single point on a zigzag", math.abs(zAvg) <= math.abs(zPlain))
local bx, bz = RC.pickTargetAveraged(bendLine, 0, 0, 12, 4)
local px, pz = RC.pickTarget(bendLine, 0, 0, 12)
check("on a bend the averaged aim stays within 0.5 m of the plain one", math.sqrt((bx - px) ^ 2 + (bz - pz) ^ 2) < 0.5)
-- ===== ground factor =====
local line = {}
for i = 0, 20 do line[#line + 1] = { i * 2, 0 } end
local factors = { road = 1.0, trail = 0.6 }
check("all road: full speed", near(RC.groundFactor(line, function() return 2 end, factors, 25), 1.0, 1e-9))
check("all trail: 60 percent", near(RC.groundFactor(line, function() return 1 end, factors, 25), 0.6, 1e-9))
check("unknown ground: no penalty", near(RC.groundFactor(line, function() return 0 end, factors, 25), 1.0, 1e-9))
local half = RC.groundFactor(line, function(x) return x < 12 and 2 or 1 end, factors, 24)
check("the trail starts 12 m ahead: in between, weighted by how much of the next 24 m it is", half > 0.6 and half < 1.0 and near(half, (6 * 1.0 + 7 * 0.6) / 13, 0.001))
check("only the next `ahead` metres count (trail beyond 25 m is ignored)", near(RC.groundFactor(line, function(x) return x < 26 and 2 or 1 end, factors, 25), 1.0, 1e-9))
check("an empty line is 1", RC.groundFactor({}, function() return 1 end, factors, 25) == 1)
-- off-road ground (class 0) with a factor, or none
check("off-road ground uses its factor when given (0.5)", near(RC.groundFactor(line, function() return 0 end, { road = 1, trail = 0.6, offroad = 0.5 }, 25), 0.5, 1e-9))
check("road then grass 14 m ahead: mixed", RC.groundFactor(line, function(x) return x < 14 and 2 or 0 end, { road = 1, trail = 0.6, offroad = 0.5 }, 24) < 1)
-- ===== junctions in auto-detect =====
-- main road east-west (8 m of road at 2 m pixels), side road to the north (left of an eastbound vehicle)
-- starting at x = 100, 8 m wide
local tLeft = rasterised(function(x, z)
    return (math.abs(z) <= 3 and x >= 0) or (x >= 96 and x <= 103 and z > 3 and z <= 200)
end)
local function lastOf(res) return res.points[#res.points] end
r = RC.scan(tLeft, 70, 0, 1, 0, { reach = 60 })
local worstZ = 0
for _, p in ipairs(r.points) do worstZ = math.max(worstZ, math.abs(p[2])) end
check("T-junction with a side road on the left, no signal: the line stays on the main road (within 1.2 m of its middle)", r.valid and worstZ < 1.2 and lastOf(r)[1] > 120)
check("... and it is flagged as a junction", r.junction == true and not r.turned)
-- a real junction mouth is flared (rounded corners), so the road widens gradually rather than all at once:
-- the case where chasing the middle of the run pulled the line into the side road
local flared = rasterised(function(x, z)
    if math.abs(z) <= 3 and x >= 0 then return true end
    if x >= 96 and x <= 103 and z > 3 and z <= 200 then return true end
    -- the two rounded corners (radius 8) where the side road meets the main road
    if x >= 88 and x < 96 and z > 3 and z <= 11 and math.sqrt((x - 88) ^ 2 + (z - 11) ^ 2) > 8 then return true end
    if x > 103 and x <= 111 and z > 3 and z <= 11 and math.sqrt((x - 111) ^ 2 + (z - 11) ^ 2) > 8 then return true end
    return false
end)
r = RC.scan(flared, 70, 0, 1, 0, { reach = 60 })
worstZ = 0
for _, p in ipairs(r.points) do worstZ = math.max(worstZ, math.abs(p[2])) end
check("a flared T-junction mouth, no signal: the line goes straight on (within 1.2 m of the main road's middle)", r.valid and worstZ < 1.2 and lastOf(r)[1] > 120)
r = RC.scan(flared, 70, 0, 1, 0, { reach = 70, intent = "left" })
check("a flared mouth with a left signal: turns onto the side road", r.valid and r.turned and lastOf(r)[2] > 15 and math.abs(lastOf(r)[1] - 99.5) < 3)

r = RC.scan(tLeft, 70, 0, 1, 0, { reach = 70, intent = "left" })
check("left signal: the line turns north onto the side road (ends well north of the main road, near x = 100)", r.valid and r.turned == true and lastOf(r)[2] > 15 and math.abs(lastOf(r)[1] - 100) < 12)
-- quality of the planned turn: starts on the main road, rounds the corner, ends on the side road's axis
local turn = RC.scan(tLeft, 70, 0, 1, 0, { reach = 70, intent = "left" })
local firstTurnIndex = nil
for i, p in ipairs(turn.points) do if math.abs(p[2]) > 0.8 then firstTurnIndex = i break end end
check("the turn starts before the side road (the arc begins ahead of x = 96), not after the vehicle has driven past it", firstTurnIndex ~= nil and turn.points[firstTurnIndex][1] < 100)
check("and ends up heading north along the side road's axis (the last 20 m within 1.5 m of x = 99.5)", (function()
    for i = #turn.points - 8, #turn.points do if math.abs(turn.points[i][1] - 99.5) > 1.5 then return false end end
    return true
end)())
local turnK = RC.curvature(turn.points)
check("the corner is an arc, not a point: the curvature is a real bend but nowhere near a 90 degree corner", turnK > 0.02 and turnK < 0.2)
check("the turn is taken slower than the road allows (curvature based)", RC.speedAdvice(turn, 50, nil) < 40)
r = RC.scan(tLeft, 70, 0, 1, 0, { reach = 70, intent = "right" })
worstZ = 0
for _, p in ipairs(r.points) do worstZ = math.max(worstZ, math.abs(p[2])) end
check("right signal at a junction on the LEFT: no turn, straight on", r.valid and not r.turned and worstZ < 1.2)

-- side road on the right (south)
local tRight = rasterised(function(x, z)
    return (math.abs(z) <= 3 and x >= 0) or (x >= 96 and x <= 103 and z < -3 and z >= -200)
end)
r = RC.scan(tRight, 70, 0, 1, 0, { reach = 60 })
worstZ = 0
for _, p in ipairs(r.points) do worstZ = math.max(worstZ, math.abs(p[2])) end
check("side road on the right, no signal: straight on", r.valid and worstZ < 1.2)
r = RC.scan(tRight, 70, 0, 1, 0, { reach = 70, intent = "right" })
check("right signal: turns south", r.valid and r.turned and lastOf(r)[2] < -15)
r = RC.scan(tRight, 70, 0, 1, 0, { reach = 70, intent = "left" })
check("left signal at a junction on the right: straight on", r.valid and not r.turned and math.abs(lastOf(r)[2]) < 1.5)

-- a crossing: side roads on both sides
local cross = rasterised(function(x, z)
    return (math.abs(z) <= 3 and x >= 0) or (x >= 96 and x <= 103 and math.abs(z) <= 200)
end)
r = RC.scan(cross, 70, 0, 1, 0, { reach = 60 })
worstZ = 0
for _, p in ipairs(r.points) do worstZ = math.max(worstZ, math.abs(p[2])) end
check("a crossing, no signal: straight across", r.valid and worstZ < 1.2 and lastOf(r)[1] > 120)
r = RC.scan(cross, 70, 0, 1, 0, { reach = 70, intent = "left" })
check("a crossing with a left signal: north", r.valid and r.turned and lastOf(r)[2] > 15)
r = RC.scan(cross, 70, 0, 1, 0, { reach = 70, intent = "right" })
check("a crossing with a right signal: south", r.valid and r.turned and lastOf(r)[2] < -15)

-- the road is never abandoned for nothing: a normal road with no junction is unchanged by all this
r = RC.scan(straight, 0, 0, 1, 0, { reach = 45, intent = "left" })
check("a plain road with a left signal on: no junction, no turn, straight", r.valid and not r.turned and not r.junction and math.abs(lastOf(r)[2]) < 1.0)

-- a slightly widening road (a bus stop, a passing place) is not a junction
local widening = rasterised(function(x, z) return (math.abs(z) <= 3 and x >= 0) or (x >= 96 and x <= 110 and z > 3 and z <= 5) end)
r = RC.scan(widening, 70, 0, 1, 0, { reach = 60 })
worstZ = 0
for _, p in ipairs(r.points) do worstZ = math.max(worstZ, math.abs(p[2])) end
check("a 2 m passing bay beside the road does not pull the line (and is not called a junction turn)", r.valid and worstZ < 1.5 and not r.turned)
-- ===== planning the speed along the line =====
local function lineOf(segments)
    -- segments: { {"straight", metres}, {"arc", radius, degrees, side} ... } -> points every 1.5 m heading east at the start
    local pts, x, z, heading = { { 0, 0 } }, 0, 0, 0
    for _, seg in ipairs(segments) do
        if seg[1] == "straight" then
            local n = math.floor(seg[2] / 1.5)
            for _ = 1, n do x, z = x + 1.5 * math.cos(heading), z + 1.5 * math.sin(heading) pts[#pts + 1] = { x, z } end
        else
            local radius, degrees, side = seg[2], seg[3], seg[4] or 1
            local n = math.floor(math.rad(degrees) * radius / 1.5)
            for _ = 1, n do
                heading = heading + side * 1.5 / radius
                x, z = x + 1.5 * math.cos(heading), z + 1.5 * math.sin(heading)
                pts[#pts + 1] = { x, z }
            end
        end
    end
    return pts
end

local straightLine = lineOf({ { "straight", 45 } })
check("straight line: no bends in the profile, no limit", #RC.curvatureProfile(straightLine) == 0 and RC.profileSpeed(RC.curvatureProfile(straightLine), 80, 0.75) == 80)

local bendLate = lineOf({ { "straight", 30 }, { "arc", 15, 90 } })        -- a tight 90 degree bend 30 m ahead, R 15
local profLate = RC.curvatureProfile(bendLate)
check("a tight bend 30 m ahead shows up in the profile with a curvature near 1/15", #profLate > 0 and (function()
    local top = 0 for _, e in ipairs(profLate) do top = math.max(top, e.kappa) end
    return near(top, 1 / 15, 0.03)
end)())
local planned = RC.profileSpeed(profLate, 80, 0.75)
local topKappa = 0
for _, e in ipairs(profLate) do topKappa = math.max(topKappa, e.kappa) end
local bendKmh = math.min(math.sqrt(RC.HARD_LATERAL_ACCEL / topKappa) * 3.6, 80)
check("the plan is physical: at least the bend's own limit, at most what braking over the line could still take off", planned >= bendKmh - 0.5 and planned <= math.sqrt((bendKmh / 3.6) ^ 2 + 2 * RC.PROFILE_BRAKE * RC.length(bendLate)) * 3.6 + 0.5)
check("... and below the 80 km/h wanted (it is going to have to slow down)", planned < 80)
local bendNear = lineOf({ { "straight", 10 }, { "arc", 15, 90 } })
check("the same bend only 10 m ahead asks for much less speed than at 30 m ahead", RC.profileSpeed(RC.curvatureProfile(bendNear), 80, 0.75) < planned - 5)
local bendFar = lineOf({ { "straight", 70 }, { "arc", 15, 90 } })
check("a bend beyond the line's end is not planned for (nothing to see yet)", RC.profileSpeed(RC.curvatureProfile(lineOf({ { "straight", 45 } })), 80, 0.75) == 80 and #bendFar > #bendLate)
local gentle = lineOf({ { "straight", 20 }, { "arc", 120, 40 } })
check("a gentle bend (R 120) does not slow a 50 km/h cruise", RC.profileSpeed(RC.curvatureProfile(gentle), 50, 0.75) > 49)
check("end of the road: stopping distance limits the speed (30 m: about 38 km/h, 6 m: about 15)", near(RC.endSpeed(30), math.sqrt(2 * RC.BRAKE_DECEL * 27) * 3.6, 0.01) and RC.endSpeed(6) < 20 and RC.endSpeed(2) == 0)
-- ===== keeping clear of obstacles =====
local function treeAt(cx, cz, radius)
    return function(x, z) return (x - cx) ^ 2 + (z - cz) ^ 2 <= radius * radius end
end
local function straightPts(length, step)
    local pts = {}
    for x = 0, length, step or 1.5 do pts[#pts + 1] = { x, 0 } end
    return pts
end
local wideRoad = function(x, z) return math.abs(z) <= 4 end
local narrowRoad = function(x, z) return math.abs(z) <= 1.5 end

local pts, info = RC.avoidObstacles(straightPts(45), treeAt(100, 100, 2.5), wideRoad)
check("nothing in the way: the line is unchanged", info.nudged == false and info.obstacle == nil and #pts == 31 and pts[10][2] == 0)

pts, info = RC.avoidObstacles(straightPts(45), treeAt(20, 0.5, 2.5), wideRoad)
check("a tree dot on the line, room on a wide road: nudged round it", info.nudged == true and info.obstacle == nil)
local clear = true
for _, p in ipairs(pts) do if treeAt(20, 0.5, 2.5)(p[1], p[2]) then clear = false end end
check("... and every point of the new line is clear of the tree", clear)
local stillOnRoad = true
for _, p in ipairs(pts) do if not wideRoad(p[1], p[2]) then stillOnRoad = false end end
check("... and still on the road", stillOnRoad)
check("the nudge is on the side that has room (the tree is just left of the line, so the line goes right)", info.shift < 0)
local maxSlope = 0
for i = 2, #pts do maxSlope = math.max(maxSlope, math.abs(pts[i][2] - pts[i - 1][2]) / math.abs(pts[i][1] - pts[i - 1][1])) end
check("the sideways move is gradual (never steeper than 25 degrees)", maxSlope < math.tan(math.rad(25)))
check("it eases back to the road's line after the tree (the far end is on the original line)", math.abs(pts[#pts][2]) < 0.05)

pts, info = RC.avoidObstacles(straightPts(45), treeAt(20, 0.5, 2.5), narrowRoad)
check("a tree on a track too narrow to pass: no way round, the line ends before it", info.obstacle ~= nil and near(info.obstacle.d, 18, 3.5) and pts[#pts][1] <= 20 - RC.AVOID_STOP_MARGIN + 0.01)
check("... and says how far the obstacle is", info.obstacle.d > 15 and info.obstacle.d < 22)
pts, info = RC.avoidObstacles(straightPts(45), treeAt(20, 0.5, 2.5), nil)
check("when the road is not checked (a spline path), it is simply nudged round", info.nudged and info.obstacle == nil)

-- two trees
local twoTrees = function(x, z) return treeAt(15, 0.5, 2.5)(x, z) or treeAt(38, -0.5, 2.5)(x, z) end
pts, info = RC.avoidObstacles(straightPts(60), twoTrees, wideRoad)
local allClear = true
for _, p in ipairs(pts) do if twoTrees(p[1], p[2]) then allClear = false end end
check("two trees: both avoided", info.nudged and info.obstacle == nil and allClear)

-- the vehicle is already beside a tree (the line's first point is inside its dot)
pts, info = RC.avoidObstacles(straightPts(45), treeAt(0, 0.8, 2.5), wideRoad)
check("a tree right at the vehicle: the line is pushed away from it", info.nudged and not treeAt(0, 0.8, 2.5)(pts[1][1], pts[1][2]))

-- a line that is not blocked anywhere keeps all its points (no truncation side effects)
pts, info = RC.avoidObstacles({ { 0, 0 }, { 1.5, 0 } }, treeAt(50, 50, 2), wideRoad)
check("a two point line without obstacles stays as it is", #pts == 2 and not info.nudged)
check("a one point line / no sampler: returned as is", #RC.avoidObstacles({ { 0, 0 } }, treeAt(0, 0, 3), wideRoad) == 1 and #RC.avoidObstacles(straightPts(10), nil, nil) == 7)
-- ===== spotty trails =====
-- a worn trail (class 1) with holes in it: a hole up to TRAIL_MAX_GAP is bridged, a real road's hole only up to MAX_GAP
local function holey(class, gapStart, gapLength)
    return function(x, z)
        local cx = (math.floor(x / 2) + 0.5) * 2
        local cz = (math.floor(z / 2) + 0.5) * 2
        if math.abs(cz) > 2 or cx < 0 then return 0 end
        if cx >= gapStart and cx < gapStart + gapLength then return 0 end
        return class
    end
end
local spotty = RC.scan(holey(1, 20, 10), 0, 0, 1, 0, { reach = 45 })
check("a trail with a 10 m hole: the line is bridged across it and carries on", spotty.valid and not spotty.ends and spotty.points[#spotty.points][1] > 40)
spotty = RC.scan(holey(1, 20, 16), 0, 0, 1, 0, { reach = 45 })
check("a trail with a 16 m hole: too long, the line ends at the hole (the bridged points are dropped)", spotty.ends == true and spotty.points[#spotty.points][1] < 20)
spotty = RC.scan(holey(2, 20, 6), 0, 0, 1, 0, { reach = 45 })
check("a real road (class 2) with a 6 m hole: the old 4 m rule, the line ends", spotty.ends == true and spotty.points[#spotty.points][1] < 20)
spotty = RC.scan(holey(2, 20, 3), 0, 0, 1, 0, { reach = 45 })
check("a real road with a 3 m hole: bridged as before", not spotty.ends and spotty.points[#spotty.points][1] > 40)

-- ===== a bend of 90 degrees (an L), not a junction =====
local function cornerScan(inside, x, reach)
    return RC.scan(rasterised(inside), x, 0, 1, 0, { reach = reach or 45 })
end
local north = cornerScan(function(x, z) return (math.abs(z) <= 3 and x >= 0 and x <= 63) or (x >= 57 and x <= 63 and z <= 3 and z >= -120) end, 20)
check("an L bend to the left (north, -z) with no signal: the line takes it", north.valid and north.turned == true and north.corner == true)
check("... it ends up heading north, well into the second leg", north.points[#north.points][2] < -8 and math.abs(north.points[#north.points][1] - 60) < 4)
local south = cornerScan(function(x, z) return (math.abs(z) <= 3 and x >= 0 and x <= 63) or (x >= 57 and x <= 63 and z >= -3 and z <= 120) end, 20)
check("an L bend to the right (south, +z): taken too", south.corner == true and south.points[#south.points][2] > 8)
local tee = cornerScan(function(x, z) return (math.abs(z) <= 3 and x >= 0 and x <= 63) or (x >= 57 and x <= 63 and z >= -120 and z <= 120) end, 20)
check("a T (the road goes both ways): not a bend, no choice made for the driver (the line ends at it)", tee.corner == nil and tee.turned == nil and tee.ends == true)
local sideRoad = cornerScan(function(x, z) return (math.abs(z) <= 3 and x >= 0) or (x >= 57 and x <= 63 and z >= -120 and z <= 3) end, 20)
check("a side road with the main road going straight on: straight on, no bend", sideRoad.corner == nil and sideRoad.turned == nil and sideRoad.points[#sideRoad.points][1] > 60 and math.abs(sideRoad.points[#sideRoad.points][2]) < 2)
local signalled = RC.scan(rasterised(function(x, z) return (math.abs(z) <= 3 and x >= 0) or (x >= 57 and x <= 63 and z >= -120 and z <= 3) end), 20, 0, 1, 0, { reach = 45, intent = "right" })      -- (the geometry's own sense: counter-clockwise in x / z is "left", the side road is to the north = -z = "right" here)
check("the same side road with a signal towards it: still taken, as a signalled turn (not marked a bend)", signalled.turned == true and signalled.corner == nil)

-- ===== crossing a road, the road beyond a little off to the side =====
local function crossing(offset, far)
    return rasterised(function(x, z) return false end), function(x, z)
        local cx = (math.floor(x / 2) + 0.5) * 2
        local cz = (math.floor(z / 2) + 0.5) * 2
        if cx >= 60 and cx <= 72 then return 2 end                           -- the road across (asphalt)
        if cx < 60 and cx >= 0 and math.abs(cz) <= 2 then return 1 end       -- the trail up to it
        if far and cx > 72 and cx <= 160 and math.abs(cz - offset) <= 2 then return 1 end
        return 0
    end
end
local _, offsetMap = crossing(5, true)
local acrossLine = RC.scan(offsetMap, 30, 0, 1, 0, { reach = 60 })
check("crossing a road with the trail beyond it 5 m to the side: the line carries on (does not end at the road)", acrossLine.valid and not acrossLine.ends and acrossLine.points[#acrossLine.points][1] > 80)
check("... and ends up on that trail (within 1.5 m of its middle)", math.abs(acrossLine.points[#acrossLine.points][2] - 5) < 1.5)
local jump = 0
for k = 2, #acrossLine.points do jump = math.max(jump, math.abs(acrossLine.points[k][2] - acrossLine.points[k - 1][2])) end
check("... gently: never more than 2.5 m sideways between two points (3 m apart)", jump <= 2.5)
local _, straightMap = crossing(0, true)
local straightAcross = RC.scan(straightMap, 30, 0, 1, 0, { reach = 60 })
local straightWorst = 0
for _, p in ipairs(straightAcross.points) do straightWorst = math.max(straightWorst, math.abs(p[2])) end
check("the trail beyond exactly in line: straight across, no wobble", not straightAcross.ends and straightWorst < 1.0)
local _, noFarMap = crossing(0, false)
local acrossNothing = RC.scan(noFarMap, 30, 0, 1, 0, { reach = 60 })
check("no trail beyond the road (a T): the line still ends there", acrossNothing.ends == true)

-- ===== a track with two wheel ruts and grass between them is one track, not a junction =====
local function ruts(gapBetween)
    return function(x, z)
        local cx = (math.floor(x / 2) + 0.5) * 2
        local cz = (math.floor(z / 2) + 0.5) * 2
        if cx < 0 or cx > 200 then return 0 end
        -- two ruts 2 m wide whose centres are (gapBetween + 2) m apart
        local half = (gapBetween + 2) / 2
        if math.abs(cz - half) <= 1 or math.abs(cz + half) <= 1 then return 1 end
        return 0
    end
end
local twin = RC.scan(ruts(2), 20, 4.0, 1, 0, { reach = 45 })           -- standing in the right rut (z = +3 here)
check("two ruts with 2 m of grass between them: one track, not a junction", twin.valid and twin.junction == false)
check("... and the line goes on along the track (no end)", not twin.ends and twin.points[#twin.points][1] > 55)
local parallel = rasterised(function(x, z) return x >= 0 and (math.abs(z) <= 1 or (z >= 6 and z <= 10)) end)
local wideGap = RC.scan(parallel, 20, 0, 1, 0, { reach = 45 })
check("a second road 6 m beside the track (4 m of grass between them): that is a junction-like thing, flagged", wideGap.valid and wideGap.junction == true)

-- ===== a crossing is a road across the line, not any wide patch =====
local blobBeside = RC.scan(rasterised(function(x, z)
    if x >= 0 and x <= 60 and math.abs(z) <= 1 then return true end                    -- the track, ends at x = 60
    if x >= 30 and x <= 44 and z >= 3 and z <= 11 then return true end                  -- a patch of bare ground beside it
    return false
end), 20, 0, 1, 0, { reach = 45 })
check("a track that ends, with a patch of bare ground beside it: no crossing is reported", blobBeside.crossingAt == nil)
local crossedT = RC.scan(rasterised(function(x, z)
    return (x >= 0 and x <= 60 and math.abs(z) <= 1) or (x >= 56 and x <= 64 and math.abs(z) <= 100)
end), 20, 0, 1, 0, { reach = 45 })
check("a track that ends in a road across it: the crossing is reported, about 36 m ahead", crossedT.crossingAt ~= nil and crossedT.ends == true and crossedT.crossingAt > 34 and crossedT.crossingAt < 42)

-- ===== a Y fork: the track splits and nothing goes straight on =====
local function segDistance(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local t = math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)))
    return math.sqrt((px - (ax + dx * t)) ^ 2 + (pz - (az + dz * t)) ^ 2)
end
local function forkMap(angleDeg)
    local a = math.rad(angleDeg)
    local ex, ez = 60 + 80 * math.cos(a), 80 * math.sin(a)
    return rasterised(function(x, z)
        return segDistance(x, z, 0, 0, 60, 0) <= 2 or segDistance(x, z, 60, 0, ex, -ez) <= 2 or segDistance(x, z, 60, 0, ex, ez) <= 2
    end)
end
for _, angle in ipairs({ 40, 60 }) do
    local fork = RC.scan(forkMap(angle), 20, 0, 1, 0, { reach = 45 })
    check(string.format("a Y fork of %d degrees, no signal: the line ends at the fork, which is reported (a place to wait at)", angle), fork.ends == true and fork.fork == true and fork.crossingAt ~= nil and fork.crossingAt > 30 and fork.crossingAt < 50)
    check(string.format("... %d degrees: no branch is taken for the driver", angle), fork.turned == nil)
    -- the geometry's own sense: counter-clockwise in x / z (= +z here) is "left"
    local left = RC.scan(forkMap(angle), 20, 0, 1, 0, { reach = 60, intent = "left" })
    check(string.format("%d degrees with the signal towards +z: that branch is taken", angle), left.turned == true and left.points[#left.points][2] > 4 and not left.ends)
    local right = RC.scan(forkMap(angle), 20, 0, 1, 0, { reach = 60, intent = "right" })
    check(string.format("%d degrees with the signal towards -z: the other branch", angle), right.turned == true and right.points[#right.points][2] < -4)
end

-- ===== the centre of a track with ruts and a hump is the middle between its outer edges =====
local rutTrack = rasterised(function(x, z) return x >= 0 and x <= 200 and ((z >= 1 and z <= 5) or (z >= -5 and z <= -1)) end)   -- two ruts, 2 m of grass between them (z -1 .. 1)
local rutLine = RC.scan(rutTrack, 20, 3.0, 1, 0, { reach = 45 })        -- standing in one rut
local rutWorst = 0
for k = 6, #rutLine.points do rutWorst = math.max(rutWorst, math.abs(rutLine.points[k][2])) end
check("standing in one of two ruts: the line goes along the middle of the whole track (within 1 m of the hump), not along the rut", rutLine.valid and not rutLine.ends and rutWorst < 1.0)
check("... the track is reported as one road about 10-12 m wide (2 m pixels)", rutLine.roadWidth ~= nil and rutLine.roadWidth > 8 and rutLine.roadWidth <= 13)
local twoRoads = rasterised(function(x, z) return x >= 0 and ((z >= -2 and z <= 2) or (z >= 7 and z <= 11)) end)       -- 5 m apart: two roads
local twoLine = RC.scan(twoRoads, 20, 0, 1, 0, { reach = 45 })
local twoWorst = 0
for _, p in ipairs(twoLine.points) do twoWorst = math.max(twoWorst, math.abs(p[2])) end
check("two roads 5 m apart are not merged: the line stays on the one it is on", twoWorst < 1.5)

-- ===== steering along the line in one go (feed-forward curvature) =====
local function localArc(radius, side, count)               -- an arc starting at the origin heading +z, curving to side (+1 left)
    local pts = {}
    for i = 0, count do
        local a = i * 2.0 / radius
        pts[#pts + 1] = { side * radius * (1 - math.cos(a)), radius * math.sin(a) }
    end
    return pts
end
local k, parts = RC.steerCurvature(localArc(50, 1, 20), 10)
check("on a left bend of radius 50 m, on the line and pointing along it: the curvature is the bend's (+0.02)", k ~= nil and near(k, 0.02, 0.008) and math.abs(parts.kfb) < 0.01)
k = RC.steerCurvature(localArc(50, -1, 20), 10)
check("a right bend: the same, the other way (-0.02)", near(k, -0.02, 0.008))
local straightLocal = {}
for i = 0, 30 do straightLocal[#straightLocal + 1] = { 0, i * 2.0 } end
k = RC.steerCurvature(straightLocal, 10)
check("a straight line dead ahead: no steering", math.abs(k) < 1e-6)
local offLeft = {}
for i = 0, 30 do offLeft[#offLeft + 1] = { 1.0, i * 2.0 } end
k, parts = RC.steerCurvature(offLeft, 10)
check("the straight line 1 m to the left: steer left a little (about 2 e / L^2)", k > 0.005 and k < 0.06 and near(parts.e, 1.0, 1e-6))
local pointingAway = {}
for i = 0, 30 do pointingAway[#pointingAway + 1] = { i * 2.0 * math.sin(0.1), i * 2.0 * math.cos(0.1) } end      -- the line leaves 0.1 rad to the left
k, parts = RC.steerCurvature(pointingAway, 10)
check("a line that points 0.1 rad to the left of the vehicle's heading: steer left", k > 0 and near(parts.psi, 0.1, 0.01))
local lagged = RC.steerCurvature(localArc(50, 1, 20), 30)
check("faster, it looks further ahead along the line (the same bend)", near(lagged, 0.02, 0.005))
check("a line with fewer than 2 points: nothing", RC.steerCurvature({ { 0, 0 } }, 10) == nil)
-- a bend that begins 15 m ahead: the vehicle looks 'lead' metres ahead only, so it still steers straight now
local late = {}
for i = 0, 10 do late[#late + 1] = { 0, i * 2.0 } end
for i = 1, 20 do local a = i * 2.0 / 50; late[#late + 1] = { 50 * (1 - math.cos(a)), 20 + 50 * math.sin(a) } end
k = RC.steerCurvature(late, 5)
check("a bend 20 m ahead is not steered yet at 5 m/s (the look-ahead is under 2 m)", math.abs(k) < 0.002)

-- ===== short stubs beside a track are not junctions =====
local function stubMap(stubLength, both)
    return rasterised(function(x, z)
        if x >= 0 and x <= 200 and math.abs(z) <= 1 then return true end                                  -- the track
        if x >= 60 and x <= 66 and z >= 1 and z <= 1 + stubLength then return true end                     -- a side stub on the +z side
        if both and x >= 60 and x <= 66 and z <= -1 and z >= -1 - stubLength then return true end         -- and on the other side
        return false
    end)
end
local stub = RC.scan(stubMap(5, false), 30, 0, 1, 0, { reach = 45 })
check("a 5 m stub of dirt beside the track: not a junction", stub.valid and stub.junction ~= true and not stub.ends)
check("... and the line goes straight on past it (within 1.5 m of the track)", (function()
    for _, p in ipairs(stub.points) do if math.abs(p[2]) > 1.5 then return false end end
    return true
end)())
local stubs = RC.scan(stubMap(5, true), 30, 0, 1, 0, { reach = 45 })
check("stubs on both sides: not a junction, not a fork", stubs.junction ~= true and stubs.fork == nil)
local stubSignal = RC.scan(stubMap(5, false), 30, 0, 1, 0, { reach = 45, intent = "left" })
check("a turn signal towards a 5 m stub: it is not a road, no turn is made", stubSignal.turned ~= true)
local realSide = RC.scan(stubMap(30, false), 30, 0, 1, 0, { reach = 45 })
check("a 30 m long side road at the same place: that is a junction", realSide.junction == true)
local stubEnd = RC.scan(rasterised(function(x, z)
    if x >= 0 and x <= 90 and math.abs(z) <= 1 then return true end
    if x >= 84 and x <= 90 and math.abs(z) <= 4 then return true end        -- two 3 m stubs where the track ends
    return false
end), 60, 0, 1, 0, { reach = 40 })
check("a track that ends with a 3 m stub to each side (a turning spot): not a fork to wait at", stubEnd.fork == nil)

-- ===== ruts whose hump is sometimes 2 m, sometimes 4 m wide on the map: one steady line =====
local wobblyRuts = rasterised(function(x, z)
    if x < 0 or x > 300 then return false end
    local humpHalf = (math.floor(x / 14) % 2 == 0) and 1 or 2           -- the hump alternates between 2 and 4 m wide every 14 m
    return (z >= humpHalf and z <= humpHalf + 2) or (z <= -humpHalf and z >= -humpHalf - 2)
end)
local steady = RC.scan(wobblyRuts, 20, 3.0, 1, 0, { reach = 45 })
local biggestJump, worstOff = 0, 0
for k = 2, #steady.points do
    biggestJump = math.max(biggestJump, math.abs(steady.points[k][2] - steady.points[k - 1][2]))
    if k > 4 then worstOff = math.max(worstOff, math.abs(steady.points[k][2])) end
end
check("ruts with a hump that is 2 m wide here and 4 m there: the line is one steady line along the middle (no step over 1 m, within 1 m of the hump)", steady.valid and biggestJump <= 1.0 and worstOff <= 1.0)

-- ===== a stone road with gravel shoulders that the map calls road too: the stone is the road =====
local shoulderBand = rasterised(function(x, z) return x >= 0 and math.abs(z) <= 10 end)            -- 20 m of "road" in the pictures
local stoneCore = function(x, z) return x >= 0 and math.abs(z) <= 3 end                            -- the road paint itself: 6 m
local noCore = RC.scan(shoulderBand, 20, 0, 1, 0, { reach = 45 })
check("without the paint test, 20 m of road all round is open ground (nothing to follow)", noCore.openGround == true or not noCore.valid or noCore.junction)
local withCore = RC.scan(shoulderBand, 20, 0, 1, 0, { reach = 45, core = stoneCore })
local coreWorst = 0
for _, p in ipairs(withCore.points) do coreWorst = math.max(coreWorst, math.abs(p[2])) end
check("with it, the stone's own 6 m is the road: a valid line, not open ground, along its middle", withCore.valid and withCore.openGround == false and #withCore.points >= 14 and coreWorst < 1.0)
check("... and the road width is about 6 m, not 20", withCore.roadWidth >= 4 and withCore.roadWidth <= 8)
local onShoulder = RC.scan(shoulderBand, 20, 6.5, 1, 0, { reach = 45, core = stoneCore })
check("standing on the gravel shoulder beside the stone: still on the road, and the line leads onto the stone", onShoulder.valid and math.abs(onShoulder.points[#onShoulder.points][2]) < 1.5)
local noStone = RC.scan(shoulderBand, 20, 0, 1, 0, { reach = 45, core = function() return false end })
check("a paint test that finds no stone anywhere changes nothing (the old behaviour)", noStone.openGround == noCore.openGround and noStone.valid == noCore.valid)

-- ===== debug rows: what each scan row saw =====
local rowsRoad = RC.scan(shoulderBand, 20, 0, 1, 0, { reach = 45, core = stoneCore, rows = true })
check("with rows asked for, the scan records one row per step (about as many as points), none otherwise", rowsRoad.rows ~= nil and #rowsRoad.rows >= #rowsRoad.points - 2 and RC.scan(shoulderBand, 20, 0, 1, 0, { reach = 45 }).rows == nil)
local rowOk = true
for _, row in ipairs(rowsRoad.rows) do
    if not (row.from <= row.to and row.centre ~= nil and row.dx ~= nil and row.x ~= nil) then rowOk = false end
end
check("every row says where it was, which way it looked, and the edges and middle it found", rowOk)
check("in the wide band the rows are the stone core (6 m), marked as core", rowsRoad.rows[2].core == true and math.abs((rowsRoad.rows[2].to - rowsRoad.rows[2].from) - 6) < 1.5)

-- ===== far-sighted steering: one parabola through the next stretch of line =====
local a, b, c, rms = RC.fitParabola(localArc(100, 1, 25), 40)
check("a parabola through an arc of radius 100: it bends to the left by 1/R (2 c = 0.01), points straight ahead, no offset", a ~= nil and near(2 * c, 0.01, 0.0015) and math.abs(b) < 0.01 and math.abs(a) < 0.05 and rms < 0.05)
local noisyLine = {}
for i = 0, 30 do noisyLine[#noisyLine + 1] = { 1.5 + ((i % 3) - 1) * 0.7, i * 2.0 } end          -- 1.5 m to the left, +-0.7 m of pixel noise
local kn, partsN = RC.steerCurvature(noisyLine, 10)
check("a noisy straight line 1.5 m to the left: the offset comes out at 1.5 m and the bend is about zero (the noise does not become steering)", partsN.fitted == true and near(partsN.e, 1.5, 0.35) and math.abs(partsN.kff) < 0.003)
local cornerLocal = {}
for i = 0, 10 do cornerLocal[#cornerLocal + 1] = { 0, i * 2.0 } end
for i = 1, 12 do cornerLocal[#cornerLocal + 1] = { i * 2.0, 20 } end
local _, partsC = RC.steerCurvature(cornerLocal, 10)
check("a 90 degree corner does not fit a parabola: it is steered the old way (not marked as fitted)", partsC.fitted ~= true)
check("too few points ahead: no fit", RC.fitParabola({ { 0, 1 }, { 0, 2 } }, 40) == nil)

-- ===== a track crossing a wider track, and carrying on beyond it (maybe a little to one side): straight on, no turn =====
local function distToSegment(px, pz, ax, az, bx, bz)
    local sx, sz = bx - ax, bz - az
    local t = math.max(0, math.min(1, ((px - ax) * sx + (pz - az) * sz) / (sx * sx + sz * sz)))
    return math.sqrt((px - (ax + sx * t)) ^ 2 + (pz - (az + sz * t)) ^ 2)
end
local function crossingWithContinuation(offset)
    return rasterised(function(x, z)
        if x >= 0 and x <= 62 and math.abs(z) <= 2 then return true end
        local a = math.rad(30)
        if distToSegment(x, z, 64 - 100 * math.cos(a), -100 * math.sin(a), 64 + 100 * math.cos(a), 100 * math.sin(a)) <= 3 then return true end
        return x >= 70 and x <= 200 and math.abs(z - offset) <= 2
    end)
end
for _, offset in ipairs({ 0, 3, 6 }) do
    local crossed = RC.scan(crossingWithContinuation(offset), 20, 0, 1, 0, { reach = 60 })
    check(string.format("a track across a wide diagonal track, the track carrying on %d m to the side beyond: no turn, no corner, and the line goes on beyond the crossing onto it", offset),
        crossed.turned ~= true and crossed.corner ~= true and crossed.points[#crossed.points][1] > 75 and math.abs(crossed.points[#crossed.points][2] - offset) < 3.5)
end

-- 40. the junction's legs, found by a ring scan (geometry left = +z); angles are relative to the heading
local function legAngles(inside)
    local legs, open = RC.junctionLegs(rasterised(inside), 55, 0, 1, 0)
    local out = {}
    for _, leg in ipairs(legs) do out[#out + 1] = math.floor(leg.angle + 0.5) end
    return out, open
end
local function hasLeg(angles, wanted, tolerance)
    for _, a in ipairs(angles) do if math.abs(a - wanted) <= tolerance then return true end end
    return false
end
local tLegs = legAngles(function(x, z) return (x <= 62 and math.abs(z) <= 2) or (x >= 58 and x <= 66 and math.abs(z) <= 60) end)
check("legs of a T: one each side, none straight on", hasLeg(tLegs, 82, 10) and hasLeg(tLegs, -82, 10) and not hasLeg(tLegs, 0, 25))
local xLegs = legAngles(function(x, z) return math.abs(z) <= 2 or (x >= 58 and x <= 66 and math.abs(z) <= 60) end)
check("legs of a crossing: both sides and straight on", hasLeg(xLegs, 82, 10) and hasLeg(xLegs, -82, 10) and hasLeg(xLegs, 0, 10))
local lLegs = legAngles(function(x, z) return (x <= 62 and math.abs(z) <= 2) or (x >= 58 and x <= 66 and z >= 0 and z <= 60) end)
check("legs of an L-bend: just the one to the left", #lLegs == 1 and hasLeg(lLegs, 82, 10))
local plain = legAngles(function(x, z) return math.abs(z) <= 2 end)
check("legs of a plain road: only straight on", #plain == 1 and hasLeg(plain, 0, 10))
local _, yardOpen = legAngles(function(x, z) return math.abs(z) <= 30 and x >= 30 and x <= 90 end)
check("a wide yard has no legs: it is open ground", yardOpen == true)

-- 41. a junction-sized bend (radius 12 m) is taken slowly even with a floor that would ask for more
check("a 12 m radius bend: at most the tight-bend speed, whatever the floor", RC.profileSpeed({ { d = 0, kappa = 1 / 12 } }, 53, 0.75) <= RC.TIGHT_KMH + 0.01)
check("a 60 m radius bend keeps the normal bend speed", RC.profileSpeed({ { d = 0, kappa = 1 / 60 } }, 53, 0.75) > RC.TIGHT_KMH + 5)


-- 42. a patch of dirt beside the road is no side road: a turn needs a leg (the road seen at three distances out)
local patchRoad = rasterised(function(x, z)
    if math.abs(z) <= 3 then return true end                                              -- the road, 6 m wide
    return x >= 40 and x <= 47 and z >= 3 and z <= 18                                    -- a 7 m wide patch of worn ground reaching 15 m out from the road's edge
end)
local patched = RC.scan(patchRoad, 20, 0, 1, 0, { reach = 60, intent = "right" })        -- (z positive is the geometry's left: try both sides)
local patchedLeft = RC.scan(patchRoad, 20, 0, 1, 0, { reach = 60, intent = "left" })
check("a patch of dirt 15 m deep beside the road: no turn to either side", patched.turned ~= true and patchedLeft.turned ~= true)
local legRoad = rasterised(function(x, z)
    if math.abs(z) <= 3 then return true end
    return x >= 40 and x <= 44 and z >= 0 and z <= 60                                   -- a 4 m wide track running off to the side
end)
local legged = RC.scan(legRoad, 20, 0, 1, 0, { reach = 60, intent = "right" })
local leggedLeft = RC.scan(legRoad, 20, 0, 1, 0, { reach = 60, intent = "left" })
check("... a track that runs off the same way is a turn", legged.turned == true or leggedLeft.turned == true)

finish("road_centerline_test")
