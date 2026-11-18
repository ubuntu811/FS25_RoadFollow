-- Closed loop: a left turn at a T of two-lane roads (a lane spline each way, drawn in the traffic direction), signalled 55 m before it.
-- The line must hold the whole turn from the moment of the signal (not end at the junction and be re-planned there), the vehicle must
-- stay near the lanes it should use and arrive on the far (north-bound) lane.
local S = dofile("tests/sim_harness.lua")
local store = S.store
if OLD_BEHAVIOUR then
    RoadFollow.FREEZE_COMPLETE = 0
    RoadFollow.TURN_EXTRA_REACH = 0
end

local function distToPoly(poly, x, z)
    local best = math.huge
    for i = 1, #poly - 1 do
        local ax, az, bx, bz = poly[i][1], poly[i][2], poly[i + 1][1], poly[i + 1][2]
        local dx, dz = bx - ax, bz - az
        local t = math.max(0, math.min(1, ((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz)))
        best = math.min(best, math.sqrt((x - (ax + dx * t)) ^ 2 + (z - (az + dz * t)) ^ 2))
    end
    return best
end

store.clear()
local eastLane = { { -300, 1.75 }, { 104, 1.75 } }
local northLane = { { 111.75, 300 }, { 111.75, -300 } }
store.add({ points = eastLane, kind = "spline", source = "map", width = 3.5 })
store.add({ points = { { 104, -1.75 }, { -300, -1.75 } }, kind = "spline", source = "map", width = 3.5 })
store.add({ points = northLane, kind = "spline", source = "map", width = 3.5 })
store.add({ points = { { 108.25, -300 }, { 108.25, 300 } }, kind = "spline", source = "map", width = 3.5 })

local v = S.newVehicle(-20, 1.75, 40)
v.spec_drivable.cruiseControl.speed = 40
local assist = S.assistOf(v)
local signalled = false
local endsAtJunction, worstFromLanes, stopped = 0, 0, nil
local previous = nil
local worstJump = 0
S.simulate(v, 22, function(veh)
    if not signalled and veh.pos[1] > 55 then
        RoadFollow.signal(veh, "left")
        signalled = true
    end
    if assist.sup.stopping then stopped = assist.sup.reason return false end
    local r = assist.result
    if signalled and r ~= nil and r.points ~= nil and #r.points > 4 and veh.pos[1] < 100 then
        if r.points[#r.points][2] > -5 then endsAtJunction = endsAtJunction + 1 end
        -- the point 12 m along the line, compared with the previous scan's line: a re-plan jumps
        local ahead = r.points[math.min(#r.points, 7)]
        if previous ~= nil then
            worstJump = math.max(worstJump, distToPoly(previous, ahead[1], ahead[2]))
        end
        previous = r.points
    end
    if veh.pos[1] > 90 then
        worstFromLanes = math.max(worstFromLanes, math.min(distToPoly(eastLane, veh.pos[1], veh.pos[2]), distToPoly(northLane, veh.pos[1], veh.pos[2])))
    end
    if veh.pos[2] < -40 then return false end
end)

check("the signal was given and nothing stopped the vehicle", signalled and stopped == nil)
check(string.format("from the signal on, the line holds the whole turn (it ended at the junction in %d scans: only the one or two before the signal is read)", endsAtJunction), endsAtJunction <= 3)
check(string.format("the line does not jump between scans on the approach (worst %.2f m at 12 m ahead)", worstJump), worstJump < 1.5)
check(string.format("the vehicle stays near the lane it leaves and the lane it joins (a 10 m radius turn cuts the corner by 4.1 m at most; worst %.2f m)", worstFromLanes), worstFromLanes < 4.6)
check(string.format("it ends on the north-bound lane, heading north (x %.1f, z %.1f, heading %.0f)", v.pos[1], v.pos[2], math.deg(math.atan2(v.heading[2], v.heading[1]))),
    v.pos[2] < -15 and math.abs(v.pos[1] - 111.75) < 1.5 and math.abs(math.deg(math.atan2(v.heading[2], v.heading[1])) + 90) < 12)
finish("road_t_turn_sim_test")
