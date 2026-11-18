dofile("tests/stubs.lua")
dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadSupervisor.lua")
local S = RoadSupervisor
local function near(a, b, tolerance) return math.abs(a - b) <= tolerance end

-- ===== pose: where the vehicle is against the line =====
local line = {}
for i = 0, 20 do line[#line + 1] = { i * 2, 0 } end            -- along +x
local y, sinPsi, cosPsi = S.pose(line, 10, 2, 1, 0)
check("2 m to the north (left of an eastbound line), heading along it: y +2, no heading error", near(y, 2, 1e-9) and near(sinPsi, 0, 1e-9) and near(cosPsi, 1, 1e-9))
y = S.pose(line, 10, -1.5, 1, 0)
check("1.5 m to the south (right of the line): y -1.5", near(y, -1.5, 1e-9))
local h = { math.cos(math.rad(20)), math.sin(math.rad(20)) }
y, sinPsi, cosPsi = S.pose(line, 10, 0, h[1], h[2])
check("pointing 20 degrees to the left of the line: sin +0.342, cos 0.94", near(sinPsi, math.sin(math.rad(20)), 1e-9) and near(cosPsi, math.cos(math.rad(20)), 1e-9))
y, sinPsi = S.pose(line, 10, 0, h[1], -h[2])
check("pointing 20 degrees to the right: sin negative", sinPsi < 0)
check("a line of one point cannot say", S.pose({ { 0, 0 } }, 0, 0, 1, 0) == nil and S.pose(nil, 0, 0, 1, 0) == nil)
-- a line running north: the left of north is west (-x)
local northLine = {}
for i = 0, 20 do northLine[#northLine + 1] = { 0, i * 2 } end
check("on a northbound line, being west of it is 'left' (+)", S.pose(northLine, -2, 10, 0, 1) > 0)

-- noise on a straight line (a 2 m pixel jitter, 0.5 m either side) must not read as a heading error
local noisyLine = {}
for i = 0, 20 do noisyLine[#noisyLine + 1] = { i * 1.5, (i % 2 == 0) and 0.5 or -0.5 } end
local _, noisySin, noisyCos = S.pose(RoadCenterline.steeringLine(noisyLine), 6, 0, 1, 0)
check("a zigzag of 1 m on a straight line, through the steering-line smoothing, gives only a small heading error (under 5 degrees)", math.abs(noisySin) < math.sin(math.rad(5)) and noisyCos > 0.99)
local sNoise = S.new()
local dNoise = S.update(sNoise, { y = 0.2, sinPsi = noisySin, cosPsi = noisyCos, limit = 2.1, speedMs = 8.3, capturing = false, saturated = false, roadLostMs = 0, hasLine = true }, 16)
check("... so a vehicle driving straight along it is not 'correcting'", dNoise.level == 0)

-- ===== the limit =====
check("a 7 m road leaves 2.1 m each side for the vehicle's centre", near(S.limitFor(7), 7 / 2 - S.VEHICLE_HALF_WIDTH, 1e-9))
check("a very narrow track still gets 1.5 m", S.limitFor(2) == S.MIN_LIMIT)
check("no width known: assumes 6 m", near(S.limitFor(nil), 3 - S.VEHICLE_HALF_WIDTH, 1e-9))

local function base(overrides)
    local m = { y = 0, sinPsi = 0, cosPsi = 1, limit = 2.1, speedMs = 20, capturing = false, saturated = false, roadLostMs = 0, hasLine = true }
    for k, v in pairs(overrides or {}) do m[k] = v end
    return m
end

-- ===== normal driving =====
local s = S.new()
local d = S.update(s, base(), 16)
check("centred and straight: normal", d.level == 0 and d.stop == false and d.speedShare == nil)
d = S.update(s, base({ y = 0.3, sinPsi = 0.01 }), 16)
check("a little off-centre and drifting slowly: still normal", d.level == 0)

-- ===== drifting out =====
d = S.update(s, base({ y = 1.2, sinPsi = 0.2, cosPsi = math.sqrt(1 - 0.04) }), 16)
check("drifting out at 72 km/h (1.2 m off, 11.5 degrees outward): even full steering overshoots the 2.1 m room: correct, speed asked at 70 percent", d.level == 1 and d.stop == false and near(d.speedShare, 0.7, 1e-9))
d = S.update(s, base({ y = 0.2, sinPsi = -0.02 }), 16)
check("recovering: back to normal", d.level == 0)

-- ===== off the road =====
s = S.new()
d = S.update(s, base({ y = 2.1 + 1.1 }), 16)
check("more than 1 m beyond the limit: stop, 'left the road'", d.level == 2 and d.stop and d.reason == "left the road")
d = S.update(s, base({ y = 0 }), 16)
check("the stop is latched: back on the middle does not cancel it", d.stop == true and d.reason == "left the road")
S.reset(s)
check("reset clears it", S.update(s, base(), 16).stop == false)

-- ===== heading =====
s = S.new()
local cos70 = math.cos(math.rad(70))
d = S.update(s, base({ cosPsi = cos70, sinPsi = math.sin(math.rad(70)), speedMs = 15 }), 16)
check("pointing 70 degrees off the road at speed: stop", d.stop and d.reason == "pointing away from the road")
s = S.new()
d = S.update(s, base({ cosPsi = cos70, sinPsi = 0.94, speedMs = 2 }), 16)
check("the same at walking pace is ignored (manoeuvring)", d.stop == false)

-- ===== correcting that does not work =====
s = S.new()
local stopped = false
for i = 1, 150 do
    d = S.update(s, base({ y = 1.5, sinPsi = 0.12, cosPsi = math.sqrt(1 - 0.12 ^ 2) }), 16)
    if d.stop then stopped = true break end
end
check("correcting for 2 s without getting any closer to the middle: stop", stopped and d.reason == "not coming back onto the road")
s = S.new()
stopped = false
local yNow = 1.8
for i = 1, 300 do
    yNow = math.max(0.4, yNow - 0.01)      -- coming back: 10 cm per 16 ms step shrinking steadily
    d = S.update(s, base({ y = yNow, sinPsi = 0.09, cosPsi = math.sqrt(1 - 0.09 ^ 2) }), 16)
    if d.stop then stopped = true break end
end
check("correcting and visibly coming back: no stop", stopped == false)

-- ===== steering at its limit =====
s = S.new()
stopped = false
for i = 1, 80 do
    d = S.update(s, base({ y = 1.6, sinPsi = 0.0, saturated = true }), 16)
    if d.stop then stopped = true break end
end
check("steering saturated for 1 s while 1.6 m off-centre: stop", stopped and d.reason == "steering at its limit")
s = S.new()
stopped = false
for i = 1, 200 do
    d = S.update(s, base({ y = 0.3, saturated = true }), 16)
    if d.stop then stopped = true break end
end
check("saturated but practically centred (3 m/s of authority is fine there): no stop", stopped == false)
-- a saturated moment that passes does not build up for ever
s = S.new()
for i = 1, 30 do S.update(s, base({ y = 1.6, saturated = true }), 16) end
for i = 1, 60 do S.update(s, base({ y = 1.6, saturated = false }), 16) end
check("the saturated time drains when it stops being saturated", s.saturatedMs < 100)

-- ===== road lost =====
s = S.new()
d = S.update(s, base({ hasLine = false, roadLostMs = 1100, speedMs = 12 }), 16)
check("road lost for over 1 s at speed: stop, 'no road ahead'", d.stop and d.reason == "no road ahead")
s = S.new()
d = S.update(s, base({ hasLine = false, roadLostMs = 1100, speedMs = 2 }), 16)
check("... but not at walking pace (a field, a yard)", d.stop == false)
s = S.new()
d = S.update(s, base({ hasLine = false, roadLostMs = 400, speedMs = 12 }), 16)
check("a short dropout is ridden through", d.stop == false and d.level == 0)

-- ===== joining a road =====
s = S.new()
d = S.update(s, base({ y = 18, capturing = true, speedMs = 20 }), 16)
check("while joining, being 18 m from the line is the point, not a problem", d.stop == false)
d = S.update(s, base({ y = 18, capturing = true, speedMs = 20, cosPsi = math.cos(math.rad(85)) }), 16)
check("... but pointing 85 degrees away from the road being joined: stop", d.stop == true)

-- ===== slow speed =====
s = S.new()
d = S.update(s, base({ y = 6, speedMs = 2 }), 16)
check("below 3 m/s the sideways rules are not applied", d.stop == false)
-- ===== the false-stop cases from the log =====
-- the extreme position even with the steering doing its best
local yExt = S.extremeY(0.5, 0.55, math.cos(math.asin(0.55)), 4.2)
check("15 km/h, 33 degrees off the line, 0.5 m out: the overshoot is under a metre (the old model said 4 m)", yExt > 0.5 and yExt < 1.5)
check("pointing back towards the line: no overshoot, the extreme is where it is", near(S.extremeY(0.5, -0.4, math.cos(math.asin(-0.4)), 17), 0.5, 1e-9))
check("outward at 63 km/h, 11 degrees: about 1.6 m of overshoot", near(S.extremeY(-1.42, -0.19, math.cos(math.asin(0.19)), 17.5), -1.42 - 17.5 ^ 2 / S.STEER_ACCEL * (1 - math.cos(math.asin(0.19))), 1e-6))

s = S.new()
d = S.update(s, base({ y = -3.41, sinPsi = -0.2, cosPsi = 0.98, limit = 1.5, speedMs = 10.8, onRoad = true, roadAhead = true }), 16)
check("3.4 m from the ESTIMATED line but the map says there is road under the vehicle: not 'left the road'", d.stop == false)
s = S.new()
s.everOnRoad = true            -- it had been on the road before
d = S.update(s, base({ y = -3.41, sinPsi = -0.2, cosPsi = 0.98, limit = 1.5, speedMs = 10.8, onRoad = false, roadAhead = false }), 16)
check("the same, with no road under it: stopped", d.stop and d.reason == "left the road")
s = S.new()
s.everOnRoad = true            -- it had been on the road before
d = S.update(s, base({ y = 2.0, sinPsi = 0, cosPsi = 1, limit = 1.5, speedMs = 10.8, onRoad = false }), 16)
check("no road under the vehicle and beyond the limit (no margin needed once the map confirms): stop", d.stop)
s = S.new()
d = S.update(s, base({ y = 1.2, sinPsi = 0, cosPsi = 1, limit = 1.5, speedMs = 10.8, onRoad = false }), 16)
check("no road under it but still within the limit of the line: not yet", d.stop == false)

-- pointing away: only when nothing under or ahead is road
s = S.new()
d = S.update(s, base({ cosPsi = math.cos(math.rad(70)), sinPsi = 0.94, speedMs = 15, onRoad = true, roadAhead = true }), 16)
check("70 degrees to the line but road under and ahead (a fork, a wide junction): not a stop", d.stop == false)
s = S.new()
s.everOnRoad = true            -- it had been on the road before
d = S.update(s, base({ cosPsi = math.cos(math.rad(70)), sinPsi = 0.94, speedMs = 15, onRoad = false, roadAhead = false }), 16)
check("70 degrees to the line and no road anywhere near: stop", d.stop and d.reason == "pointing away from the road")

-- correcting for ever while on the road: the line is doubted, the vehicle is not stopped
s = S.new()
local sawStop, sawSuppress = false, false
for i = 1, 400 do
    d = S.update(s, base({ y = 1.8, sinPsi = 0.2, cosPsi = math.sqrt(1 - 0.04), speedMs = 10, onRoad = true, roadAhead = false }), 16)
    if d.stop then sawStop = true break end
    if s.suppressMs ~= nil and s.suppressMs > 0 then sawSuppress = true end
end
check("correcting for 2 s with the vehicle on the road all the time: not a stop; the correction is suppressed for a while", sawStop == false and sawSuppress)
s = S.new()
sawStop = false
for i = 1, 150 do
    d = S.update(s, base({ y = 1.8, sinPsi = 0.12, cosPsi = 0.99, speedMs = 15, onRoad = false }), 16)
    if d.stop then sawStop = true break end
end
check("the same with no road under the vehicle: it is stopped", sawStop)

-- saturated steering only counts when the vehicle is not known to be on the road
s = S.new()
sawStop = false
for i = 1, 100 do
    d = S.update(s, base({ y = 1.6, saturated = true, onRoad = true }), 16)
    if d.stop then sawStop = true break end
end
check("steering saturated but the vehicle is on the road: no stop", sawStop == false)
-- on the road: a lane position is not an emergency, heading for the edge is
s = S.new()
d = S.update(s, base({ y = 2.9, sinPsi = 0.01, cosPsi = 1, limit = 1.5, speedMs = 9, onRoad = true, roadAhead = true }), 16)
check("2.9 m off the line, parallel to it, on the road with road ahead (the lane of a two-lane road): normal", d.level == 0 and d.stop == false)
d = S.update(s, base({ y = 2.9, sinPsi = 0.01, cosPsi = 1, limit = 1.5, speedMs = 9, onRoad = true, roadAhead = nil }), 16)
check("... also when the road ahead is not known", d.level == 0)
d = S.update(s, base({ y = 0.8, sinPsi = 0.3, cosPsi = math.sqrt(1 - 0.09), limit = 2.1, speedMs = 14, onRoad = true, roadAhead = false }), 16)
check("on the road but pointing at the edge with no road ahead (a bend about to be missed): correct", d.level == 1 and d.stop == false)
d = S.update(s, base({ y = 0.8, sinPsi = 0.3, cosPsi = math.sqrt(1 - 0.09), limit = 2.1, speedMs = 14, onRoad = true, roadAhead = true }), 16)
check("the same with road ahead along the heading: fine", d.level == 0)
d = S.update(s, base({ y = 0.8, sinPsi = -0.3, cosPsi = math.sqrt(1 - 0.09), limit = 2.1, speedMs = 14, onRoad = true, roadAhead = false }), 16)
check("pointing back towards the line: no outward drift, no correction", d.level == 0)
-- ===== obstacles the line cannot avoid =====
s = S.new()
d = S.update(s, base({ speedMs = 5, obstacleDistance = 30 }), 16)
check("an obstacle 30 m ahead at 18 km/h (needs about 13 m to stop in): no stop yet", d.stop == false)
d = S.update(s, base({ speedMs = 5, obstacleDistance = 12 }), 16)
check("12 m ahead at 18 km/h: stop now ('obstacle ahead')", d.stop and d.reason == "obstacle ahead")
s = S.new()
d = S.update(s, base({ speedMs = 20, obstacleDistance = 60 }), 16)
check("at 72 km/h even 60 m is too late for comfort (needs 88 m): stop", d.stop and d.reason == "obstacle ahead")
s = S.new()
d = S.update(s, base({ speedMs = 0.2, obstacleDistance = 9, hasLine = true }), 16)
check("standing in front of it: stopped (so cruise control gets switched off)", d.stop and d.reason == "obstacle ahead")
s = S.new()
d = S.update(s, base({ speedMs = 20, obstacleDistance = nil }), 16)
check("no obstacle: no effect", d.stop == false)
s = S.new()
d = S.update(s, base({ speedMs = 5, obstacleDistance = 12, hasLine = false }), 16)
check("the obstacle rule works even when the line itself is unknown", d.stop)
-- ===== road lost after slowing down =====
local lostState = S.new()
local lostSlow = S.update(lostState, { y = 0, sinPsi = 0, cosPsi = 1, limit = 3, speedMs = 2, roadLostMs = 1200, hasLine = false, onRoad = nil, roadAhead = nil }, 16)
check("road lost for 1.2 s, crawling at 7 km/h, never was fast: no stop (slow driving, handed back elsewhere)", lostSlow.stop ~= true)
lostState = S.new()
local lostAuto = S.update(lostState, { y = 0, sinPsi = 0, cosPsi = 1, limit = 3, speedMs = 2, roadLostMs = 1200, hasLine = false, autopilot = true }, 16)
check("the same, but the vehicle was at road speed a moment ago (it slowed for the road's end): stop, no road ahead", lostAuto.stop == true and lostAuto.reason == "no road ahead")

-- ===== engaged beside the road: rejoining it =====
s = S.new()
d = S.update(s, base({ y = 2.5, sinPsi = 0.2, cosPsi = 0.98, limit = 1.5, speedMs = 6.7, onRoad = false, roadAhead = false }), 16)
check("engaged 2.5 m beside the line with no road under the vehicle (never on it yet): not a stop, rejoining slowly", d.stop == false and d.level == 1 and d.rejoining == true)
local rejoinStopped = false
for _ = 1, 700 do
    d = S.update(s, base({ y = 2.5, sinPsi = 0, cosPsi = 1, limit = 1.5, speedMs = 6.7, onRoad = false, roadAhead = false }), 16)
    if d.stop then rejoinStopped = d.reason == "not coming back onto the road" break end
end
check("... but if it has not got onto the road after 10 s: stop, 'not coming back onto the road'", rejoinStopped)
s = S.new()
S.update(s, base({ y = 2.5, sinPsi = 0.2, cosPsi = 0.98, limit = 1.5, speedMs = 6.7, onRoad = false, roadAhead = false }), 16)
d = S.update(s, base({ y = 0.4, sinPsi = 0, cosPsi = 1, limit = 1.5, speedMs = 6.7, onRoad = true, roadAhead = true }), 16)
check("it gets onto the road: normal driving", d.stop == false and d.level == 0 and not d.rejoining)
d = S.update(s, base({ y = 3.5, sinPsi = 0, cosPsi = 1, limit = 1.5, speedMs = 6.7, onRoad = false, roadAhead = false }), 16)
check("... and after that, leaving it is 'left the road' as before", d.stop == true and d.reason == "left the road")
s = S.new()
d = S.update(s, base({ y = 0.5, sinPsi = 0, cosPsi = 1, limit = 1.5, speedMs = 6.7, onRoad = false, roadAhead = false }), 16)
check("on the line of a path over grass (map says no road, but it is within the limit of the line): normal", d.stop == false and d.level == 0)
d = S.update(s, base({ y = 3.5, sinPsi = 0, cosPsi = 1, limit = 1.5, speedMs = 6.7, onRoad = false, roadAhead = false }), 16)
check("... leaving that line is 'left the road'", d.stop == true)

-- ===== stuck: asked to drive on, not moving =====
s = S.new()
d = S.update(s, base({ speedMs = 0, stuckMs = 2900 }), 16)
check("standing still for 2.9 s while asked to drive: not yet", d.stop == false)
d = S.update(s, base({ speedMs = 0, stuckMs = 3100 }), 16)
check("3.1 s: stop, 'stuck, not moving'", d.stop == true and d.reason == "stuck, not moving")

finish("road_supervisor_test")
