dofile("tests/stubs.lua")
dofile("scripts/RoadLead.lua")
local L = RoadLead
local function near(a, b, t) return math.abs(a - b) <= t end

-- how far to look
check("standing still: the minimum range", L.range(0) == L.MIN_RANGE)
check("at 30 m/s (108 km/h): braking distance 180 m is more than the maximum: the maximum", L.range(30) == L.MAX_RANGE)
check("at 15 m/s: 45 + 40 = 85 m", near(L.range(15), 85, 0.01))

-- the stretches along a straight line
local line = {}
for i = 0, 40 do line[#line + 1] = { i * 5, 0 } end        -- 200 m east
local segs = L.segments(line, 3, 0, 1, 0, 100)
check("100 m of range: four stretches of 25 m", #segs == 4)
check("they follow on from each other, the first from the origin", near(segs[1].ax, 3, 1e-9) and near(segs[1].bx, segs[2].ax, 1e-9) and segs[1].from == 0 and near(segs[3].from, 50, 1e-9))
check("and reach the range", near(segs[4].bx, 100, 1.0))

-- a short line: the rest runs straight on in its last direction
local short = { { 0, 0 }, { 10, 0 }, { 20, 5 } }
segs = L.segments(short, 0, 0, 1, 0, 60)
local last = segs[#segs]
check("a line shorter than the range is carried on straight in its last direction", last.bx > 20 and last.bz > 5 and near((last.bz - last.az) / (last.bx - last.ax), 0.5, 0.05))
-- no line at all: straight along the heading
segs = L.segments(nil, 10, 20, 0, 1, 50)
check("no line: straight along the heading (0, 1)", #segs == 2 and near(segs[2].bz, 70, 1e-6) and near(segs[2].bx, 10, 1e-6))
-- a bend: the stretches follow it
local arc = {}
for i = 0, 40 do local a = i * 0.05; arc[#arc + 1] = { 100 * math.sin(a), 100 * (1 - math.cos(a)) } end   -- radius 100 m
segs = L.segments(arc, 0, 0, 1, 0, 100)
check("on a bend the stretches turn with it (the last one points clearly away from east)", segs[#segs].bz - segs[#segs].az > 5)

-- the speed that stops behind a stopped lead
check("a stopped lead 5 m ahead or closer: stand still", L.allowedSpeed(5, 0) == 0 and L.allowedSpeed(3, 0) == 0)
local v = L.allowedSpeed(55, 0)
check("a stopped lead 55 m ahead: 2.5 m/s^2 braking over the 50 m that are left, so 15.8 m/s", near(v, math.sqrt(2 * 2.5 * 50), 0.01))
check("a lead driving at 20 m/s 30 m ahead: more than 20 m/s is allowed (the gap is big enough)", L.allowedSpeed(30, 20) > 20)
check("a lead at 20 m/s but only 4 m ahead: slower than it, to open the gap", near(L.allowedSpeed(4, 20), 19, 1e-9))
check("allowed speed grows with the gap", L.allowedSpeed(40, 10) > L.allowedSpeed(20, 10))

-- reading the lead's speed
local state = {}
check("nothing ahead: speed 0 and no gap", L.track(state, nil, 20, 100) == 0 and state.gap == nil)
check("a lead seen for the first time is assumed to stand still", L.track(state, 60, 20, 100) == 0)
-- the vehicle at 20 m/s, the gap shrinking 1 m per 100 ms = closing 10 m/s: lead drives at 10 m/s
local gap = 60
local estimate
for _ = 1, 30 do
    gap = gap - 1
    estimate = L.track(state, gap, 20, 100)
end
check("closing at 10 m/s while doing 20: the lead's speed is estimated at about 10 m/s", near(estimate, 10, 0.5))
-- a gap that stays the same: same speed as us
state = {}
L.track(state, 40, 20, 100)
for _ = 1, 30 do estimate = L.track(state, 40, 20, 100) end
check("a constant gap: the lead drives as fast as we do", near(estimate, 20, 0.5))
-- a jump (another object takes over): ignored
state = {}
L.track(state, 40, 20, 100)
for _ = 1, 20 do L.track(state, 40, 20, 100) end
local before = state.vLead
L.track(state, 10, 20, 100)
check("a gap that jumps by 30 m in 0.1 s is a different object: the estimate does not follow it", near(state.vLead, before, 1e-9))

-- ===== cross traffic =====
local lx, lz, rx, rz = L.crossDirections(1, 0)
check("heading east: the left is north (z negative), the right south", lx == 0 and lz == -1 and rx == 0 and rz == 1)
lx, lz, rx, rz = L.crossDirections(0, -1)
check("heading north: the left is west", lx == -1 and lz == 0 and rx == 1)
check("a right turn watches the traffic from the left only; a left turn or going over, both", #L.crossSides("right") == 1 and L.crossSides("right")[1] == "left" and #L.crossSides("left") == 2 and #L.crossSides(nil) == 2)
-- a car coming at 10 m/s from 60 m (the gap shrinks 1 m per 100 ms)
local cs = {}
local function feed(gapFrom, step, count)
    local g = gapFrom
    for _ = 1, count do
        L.trackCross(cs, g, 100)
        g = g - step
    end
    return g
end
check("nothing seen: no threat", L.crossThreat(cs) == false)
feed(60, 1, 2)
check("a car only just seen 58 m away: no threat yet (beyond the careful range)", L.crossThreat(cs) == false)
cs = {}
local g = feed(45, 1, 8)
check("coming at 10 m/s from 45 m, now 37 m away: 3.7 s away, a threat", near(cs.approach, 10, 1.5) and L.crossThreat(cs) == true)
cs = {}
feed(120, 0.5, 3)
check("a car far away (about 100 m) is no threat", L.crossThreat(cs) == false)
cs = {}
for _ = 1, 8 do L.trackCross(cs, 20, 100) end
check("a standing car 20 m down the road is no threat", L.crossThreat(cs) == false)
cs = {}
for _ = 1, 8 do L.trackCross(cs, 4, 100) end
check("a standing car right at the mouth (4 m) is in the way", L.crossThreat(cs) == true)
cs = {}
feed(20, -0.5, 8)
check("a car driving away (the gap grows) is no threat", L.crossThreat(cs) == false)
cs = {}
feed(30, 0.3, 8)
check("a slow car coming at 3 m/s from 28 m: 9 s away, no threat yet", L.crossThreat(cs) == false)
cs = {}
feed(13, 0.3, 4)
check("... but once it is within 14 m it is", L.crossThreat(cs) == true)
cs = {}
L.trackCross(cs, 20, 100)
L.trackCross(cs, 19, 100)
check("a car seen only twice (speed not known yet) 19 m away: careful, a threat", L.crossThreat(cs) == true)
L.trackCross(cs, nil, 100)
check("it disappears: no threat", L.crossThreat(cs) == false)

-- ===== cargo is not an obstacle =====
local function fakeVehicle(name) local o = { name = name }; o.getRootVehicle = function(self) return self.root or self end; return o end
local truck = fakeVehicle("truck")
local trailer = fakeVehicle("trailer"); trailer.root = truck
local cargo = fakeVehicle("cargo")
cargo.getDynamicMountObject = function() return trailer end
local stranger = fakeVehicle("stranger")
stranger.getDynamicMountObject = function() return nil end
local loose = fakeVehicle("loose")
check("a vehicle mounted on the trailer of our rig is carried by it", L.isCarriedBy(cargo, truck) == true)
check("... a vehicle that is mounted on nothing is not", L.isCarriedBy(stranger, truck) == false)
check("... an ordinary object without a mount function is not", L.isCarriedBy(loose, truck) == false)
local otherTruck = fakeVehicle("other")
check("... and cargo of another rig is not ours", L.isCarriedBy(cargo, otherTruck) == false)
local cargoImplement = fakeVehicle("cargo implement"); cargoImplement.root = cargo
cargoImplement.getDynamicMountObject = function() return nil end
check("an implement of the carried vehicle is carried too", L.isCarriedBy(cargoImplement, truck) == true)
local stacked = fakeVehicle("stacked")
stacked.getDynamicMountObject = function() return cargo end
check("a vehicle on the carried vehicle is carried as well", L.isCarriedBy(stacked, truck) == true)
-- the filter in front of the base game's handler
g_currentMission = { nodeToObject = { [101] = cargo, [102] = stranger } }
local calls = {}
local handler = { rootVehicle = truck }
function handler.onVehicleCollisionDistanceCallback(h, distance, objectId, subShapeIndex, isLast, trigger)
    calls[#calls + 1] = { objectId = objectId, isLast = isLast }
    return not (objectId == 0 or isLast)
end
check("the filter installs once", L.ignoreCarried(handler) == true and L.ignoreCarried(handler) == false)
local result = handler:onVehicleCollisionDistanceCallback(3, 101, 0, false, {})
check("a hit on the cargo is skipped (the handler never sees it) and the walk goes on", result == true and #calls == 0)
result = handler:onVehicleCollisionDistanceCallback(3, 101, 0, true, {})
check("... the cargo as the last hit: the handler is told the list has ended (object 0)", #calls == 1 and calls[1].objectId == 0 and calls[1].isLast == true)
calls = {}
handler:onVehicleCollisionDistanceCallback(5, 102, 0, false, {})
check("a hit on anything else goes through unchanged", #calls == 1 and calls[1].objectId == 102)
finish("road_lead_test")
