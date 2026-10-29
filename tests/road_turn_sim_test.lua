-- Closed loop: the real assist driving a simulated vehicle through a T junction made of two stored paths.
local S = dofile("tests/sim_harness.lua")
local store = S.store
local function tJunction()
    store.clear()
    store.add({ points = { { -200, 0 }, { 200, 0 } }, kind = "spline", source = "map", width = 7 })        -- the stem, ends at the crossing
    store.add({ points = { { 200, -300 }, { 200, 300 } }, kind = "spline", source = "map", width = 7 })    -- the crossing road
end
local function heading(v) return math.deg(math.atan2(v.heading[2], v.heading[1])) end

-- a right turn (towards +z) from 45 km/h
for _, startKmh in ipairs({ 30, 45, 60 }) do
    tJunction()
    local v = S.newVehicle(60, 0, startKmh)
    v.spec_drivable.cruiseControl.speed = startKmh
    S.simulate(v, 1)
    RoadFollow.signal(v, "right")
    local stopped, worstSpeedInTurn, maxLateral = nil, 0, 0
    S.simulate(v, 40, function(veh, t)
        local a = S.assistOf(veh)
        if a.sup.stopping then stopped = a.sup.reason return false end
        if veh.pos[1] > 188 and veh.pos[2] < 12 then worstSpeedInTurn = math.max(worstSpeedInTurn, veh.speed) end
        if veh.pos[2] > 40 then return false end
    end)
    check(string.format("a right turn at a T from %d km/h: the assist never calls a stop", startKmh), stopped == nil)
    check(string.format("... %d km/h: it ends up on the crossing road heading south (+z), within 2.5 m of its line", startKmh), v.pos[2] > 30 and math.abs(v.pos[1] - 200) < 2.5 and math.abs(heading(v) - 90) < 12)
    check(string.format("... %d km/h: through the corner it is slow (under 32 km/h)", startKmh), worstSpeedInTurn < 32)
    check(string.format("... %d km/h: the vehicle's own signal went off after the turn", startKmh), v.turnState == Lights.TURNLIGHT_OFF)
end

-- a left turn (towards -z)
tJunction()
local v = S.newVehicle(60, 0, 40)
S.simulate(v, 1)
RoadFollow.signal(v, "left")
local stopped
S.simulate(v, 40, function(veh)
    if S.assistOf(veh).sup.stopping then stopped = S.assistOf(veh).sup.reason return false end
    if veh.pos[2] < -40 then return false end
end)
check("a left turn at the same T: no stop, ends up on the crossing road heading north (-z)", stopped == nil and v.pos[2] < -30 and math.abs(v.pos[1] - 200) < 2.5 and math.abs(heading(v) + 90) < 12)

-- no signal: wait before it
tJunction()
v = S.newVehicle(60, 0, 40)
S.simulate(v, 1)
stopped = nil
S.simulate(v, 40, function(veh)
    if S.assistOf(veh).sup.stopping then stopped = S.assistOf(veh).sup.reason return false end
end)
check("no signal at the T: the vehicle comes to a stop before the junction and waits, still engaged, no stop called", stopped == nil and v.speed < 1 and v.pos[1] < 196 and v.pos[1] > 170 and S.assistOf(v).engaged == true and S.assistOf(v).waiting == true)
check("... and it stops where the stop line is (6 m before the mouth of a 4 m wide stem end, plus the 3 m front overhang assumed): at x = 187, within 1.5 m", math.abs(v.pos[1] - 187) <= 1.5)
RoadFollow.signal(v, "right")
local movingOff, dipped = false, false
S.simulate(v, 25, function(veh)
    if S.assistOf(veh).sup.stopping then stopped = S.assistOf(veh).sup.reason return false end
    if veh.speed > 8 then movingOff = true end
    if movingOff and veh.speed < 6 and veh.pos[2] < 25 then dipped = true end
    if veh.pos[2] > 40 then return false end
end)
check("setting off from the stop line and turning: no stop-and-go (once moving it never drops under 6 km/h before it is round)", movingOff and not dipped)
check("then a signal while it waits: it sets off and takes the turn", stopped == nil and v.pos[2] > 30 and math.abs(v.pos[1] - 200) < 2.5)

-- the road goes straight on through a crossing (the crossing paths and a continuation of the stem): no signal = straight
store.clear()
store.add({ points = { { -200, 0 }, { 400, 0 } }, kind = "spline", source = "map", width = 7 })
store.add({ points = { { 200, -300 }, { 200, 300 } }, kind = "spline", source = "map", width = 7 })
v = S.newVehicle(100, 0, 40)
S.simulate(v, 1)
stopped = nil
S.simulate(v, 12, function(veh)
    if S.assistOf(veh).sup.stopping then stopped = S.assistOf(veh).sup.reason return false end
end)
check("a crossing with the road going straight on: the vehicle drives across without a signal (past the crossing, still on the road)", stopped == nil and v.pos[1] > 220 and math.abs(v.pos[2]) < 1.5)

finish("road_turn_sim_test")
