dofile("tests/stubs.lua")
Logging = { info = function() end }
dofile("../FS25_whatAmILookingAt/scripts/WailaPathStore.lua")

g_currentModName = "FS25_RoadFollow"
Lights = { TURNLIGHT_OFF = 0, TURNLIGHT_LEFT = 1, TURNLIGHT_RIGHT = 2 }
addConsoleCommand = function() end
Drivable = { CRUISECONTROL_STATE_OFF = 0 }
local driveCalls = {}
AIVehicleUtil = { driveToPoint = function(vehicle, dt, acceleration, allowed, forwards, pX, pZ, maxSpeed)
    driveCalls[#driveCalls + 1] = { pX = pX, pZ = pZ, maxSpeed = maxSpeed, allowed = allowed }
end }
getTerrainHeightAtWorldPos = function() return 100 end
g_terrainNode = 1

local classAt = function() return 2 end            -- what the bitmaps say about the ground (2 road, 1 trail, 0 unknown)
local haveBitmapData = false
local warnings = {}
g_currentMission = {
    showBlinkingWarning = function(_, text) warnings[#warnings + 1] = text end,
    wailaPaths = WailaPathStore,
    wailaTrailTracer = {
        sampleDrivable = function(x, z) return classAt(x, z) end,
        hasDrivableData = function() return haveBitmapData end,
    },
}
dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadSupervisor.lua")
dofile("scripts/RoadMeander.lua")
dofile("scripts/RoadFollow.lua")
dofile("scripts/RoadLead.lua")
dofile("scripts/RoadFieldCourse.lua")

local current
getWorldTranslation = function() return current.pos[1], 100, current.pos[2] end
localDirectionToWorld = function() return current.heading[1], 0, current.heading[2] end
worldToLocal = function(_, wx, _, wz)
    local dx, dz = wx - current.pos[1], wz - current.pos[2]
    local fx, fz = current.heading[1], current.heading[2]
    return dx * -fz + dz * fx, 0, dx * fx + dz * fz
end
local superCalls = 0
local function superFunc() superCalls = superCalls + 1 end
local function newVehicle(x, z)
    local v = { pos = { x, z }, heading = { 1, 0 }, speed = 30, isServer = true, movingDirection = 1 }
    v["spec_FS25_RoadFollow.roadFollow"] = {
        isActive = false, actionEvents = {},
        assist = { engaged = false, goodScans = 0, badMs = 0, scanMs = 0, steerGraceMs = 0, result = nil, warned = false, broken = false, status = nil, modeLabel = nil, groundFactor = 1, sup = RoadSupervisor.new(), saturated = false, meander = RoadMeander.new(), intent = nil, intentMs = 0 },
    }
    v.spec_drivable = { cruiseControl = { state = 1, speed = 40 } }
    v.getAISteeringNode = function() return "s" end
    v.getAIDirectionNode = function() return "d" end
    v.getLastSpeed = function(self) return self.speed end
    v.getSpeedLimit = function() return 80, true end
    v.getCruiseControlMaxSpeed = function(self) return self.spec_drivable.cruiseControl.speed end
    v.getName = function() return "truck" end
    v.cruiseOffCalls = 0
    v.turnState = 0
    v.getTurnLightState = function(self) return self.turnState end
    v.setTurnLightState = function(self, state) self.turnState = state end
    v.setCruiseControlState = function(self, state) self.spec_drivable.cruiseControl.state = state; self.cruiseOffCalls = self.cruiseOffCalls + 1 end
    v.scanRoadAhead = RoadFollow.scanRoadAhead
    v.getRootVehicle = function(self) return self end
    return v
end
local function run(vehicle, ms, input)
    current = vehicle
    input = input or {}
    superCalls, driveCalls = 0, {}
    for _ = 1, ms / 16 do
        RoadFollow.updateVehiclePhysics(vehicle, superFunc, input[1] or 0, input[2] or 0, input[3] or false, 16)
    end
end
local function assistOf(v) return v["spec_FS25_RoadFollow.roadFollow"].assist end

-- the map's road spline along x at z = 0, two-way (as the store imports it)
WailaPathStore.clear()
local spline = WailaPathStore.add({ points = { { -200, 0 }, { 400, 0 } }, kind = "spline", source = "map", width = 7, transient = true })

-- 1. path mode needs no bitmap data at all
haveBitmapData = false
local v = newVehicle(0, 1.5)
run(v, 600)
check("a map spline under the vehicle and NO bitmap data: the assist engages", assistOf(v).engaged == true and #driveCalls > 10)
check("the mode is named: road spline", assistOf(v).modeLabel == "road spline")
check("it steers along the spline: target ahead, a little to the spline's side", driveCalls[#driveCalls].pZ > 6)

-- 2. recorded path is named as such
WailaPathStore.clear()
WailaPathStore.add({ points = { { -200, 0 }, { 400, 0 } }, kind = "recorded", oneWay = true })
v = newVehicle(0, 0)
run(v, 600)
check("a recorded path is named: recorded path", assistOf(v).engaged == true and assistOf(v).modeLabel == "recorded path")
v = newVehicle(0, 0)
v.heading = { -1, 0 }
run(v, 600)
check("...but a one-way recorded path is not followed the wrong way, and the status says so", assistOf(v).engaged == false and assistOf(v).status == "no road data (run the map scan)")

-- 3. no path, bitmap data present: auto-detect, named
WailaPathStore.clear()
haveBitmapData = true
classAt = function(x, z) return math.abs((math.floor(z / 2) + 0.5) * 2) <= 3 and 2 or 0 end
v = newVehicle(0, 0)
run(v, 600)
check("no stored path, bitmap road: auto-detect, named", assistOf(v).engaged == true and assistOf(v).modeLabel == "auto-detect")

-- 4. the paths switch
WailaPathStore.clear()
WailaPathStore.add({ points = { { -200, 0 }, { 400, 0 } }, kind = "spline", source = "map" })
RoadFollow.usePaths = false
v = newVehicle(0, 0)
run(v, 600)
check("paths switched off: auto-detect even where a path exists", assistOf(v).modeLabel == "auto-detect")
RoadFollow.usePaths = true
v = newVehicle(0, 0)
run(v, 600)
check("paths on: the spline wins over the bitmap", assistOf(v).modeLabel == "road spline")

-- 5. the status says why not
WailaPathStore.clear()
haveBitmapData = true
classAt = function() return 0 end
v = newVehicle(0, 0)
run(v, 600)
check("cruise on, nothing to follow: status 'no road here'", assistOf(v).engaged == false and assistOf(v).status == "no road here")
haveBitmapData = false
v = newVehicle(0, 0)
run(v, 600)
check("no data at all: status asks for the map scan", assistOf(v).status == "no road data (run the map scan)")
WailaPathStore.add({ points = { { -200, 0 }, { 400, 0 } }, kind = "spline", source = "map" })
v = newVehicle(0, 0)
run(v, 100, { 0.6, 0 })
check("pedal pressed: status says pedal", assistOf(v).status == "pedal")

-- 6. the ground sets the speed (cruise 40)
haveBitmapData = true
classAt = function() return 2 end
v = newVehicle(0, 0)
run(v, 600)
local onRoad = driveCalls[#driveCalls].maxSpeed
classAt = function() return 1 end
v = newVehicle(0, 0)
run(v, 600)
local onTrail = driveCalls[#driveCalls].maxSpeed
check("on road ground the full cruise speed is asked for", onRoad > 38 and onRoad <= 40.01)
check("on worn trail / gravel 85 percent of it (34 km/h of the 40)", math.abs(onTrail - 34) < 0.5)
RoadFollow.groundFactors.trail = 0.9
v = newVehicle(0, 0)
run(v, 600)
check("the trail share is adjustable", math.abs(driveCalls[#driveCalls].maxSpeed - 36) < 0.5)
RoadFollow.groundFactors.trail = 0.6
classAt = function(x, z) return x < 15 and 2 or 1 end
v = newVehicle(0, 0)
run(v, 600)
check("trail starting 15 m ahead: the speed is already eased (between 24 and 40)", driveCalls[#driveCalls].maxSpeed < 40 and driveCalls[#driveCalls].maxSpeed > 24)
classAt = function() return 0 end
v = newVehicle(0, 0)
run(v, 600)
check("ground the map knows nothing about: no penalty", driveCalls[#driveCalls].maxSpeed > 38)

-- off-road ground: a recorded path over grass (class 0, map data present) is driven at 20 at most
haveBitmapData = true
classAt = function() return 0 end
WailaPathStore.clear()
WailaPathStore.add({ points = { { -200, 0 }, { 400, 0 } }, kind = "recorded", oneWay = true })
v = newVehicle(0, 0)
run(v, 600)
check("a recorded path over grass: 20 km/h at most (cruise is 40)", driveCalls[#driveCalls].maxSpeed <= 20.5 and driveCalls[#driveCalls].maxSpeed >= 19)
RoadFollow.OFFROAD_KMH = 25
v = newVehicle(0, 0)
run(v, 600)
check("the off-road speed is adjustable", math.abs(driveCalls[#driveCalls].maxSpeed - 25) < 0.7)
RoadFollow.OFFROAD_KMH = 20
v = newVehicle(0, 0)
v.spec_drivable.cruiseControl.speed = 15
run(v, 600)
check("a cruise setting below the cap is not raised to it", driveCalls[#driveCalls].maxSpeed <= 15.01)
haveBitmapData = false
v = newVehicle(0, 0)
run(v, 600)
check("no map data: 'grass' cannot be told from 'unknown', so no cap", driveCalls[#driveCalls].maxSpeed > 38)
haveBitmapData = true
WailaPathStore.clear()
WailaPathStore.add({ points = { { -200, 0 }, { 400, 0 } }, kind = "spline", source = "map" })
v = newVehicle(0, 0)
run(v, 600)
check("a map spline is a road even if the road layer says nothing: no cap", driveCalls[#driveCalls].maxSpeed > 38)
classAt = function() return 2 end

-- 7. lane offset
classAt = function() return 2 end
RoadFollow.laneOffset = 0
v = newVehicle(0, 0)
run(v, 600)
local centred = driveCalls[#driveCalls].pX
RoadFollow.laneOffset = 2
v = newVehicle(0, 0)
run(v, 800)
local lane = driveCalls[#driveCalls].pX
check("lane offset 2 m: the aim point moves to the right of the spline (the sign flips against the left-positive local x)", math.abs(lane - centred) > 0.3)
RoadFollow.laneOffset = 0

-- 8. the label function
check("mode labels", RoadFollow.modeLabel({ mode = "path", kind = "spline" }) == "road spline" and RoadFollow.modeLabel({ mode = "auto" }) == "auto-detect"
    and RoadFollow.modeLabel({ mode = "path", kind = "imported" }) == "imported road" and RoadFollow.modeLabel({ mode = "path", kind = "x" }) == "path")
-- ===== joining a road at speed =====
WailaPathStore.clear()
WailaPathStore.add({ points = { { -500, 0 }, { 1500, 0 } }, kind = "spline", source = "map", width = 7 })
haveBitmapData = false
local h25 = { math.cos(math.rad(-12)), math.sin(math.rad(-12)) }
v = newVehicle(0, 20)
v.heading = { h25[1], h25[2] }
v.speed = 80
v.spec_drivable.cruiseControl.speed = 80
run(v, 800)
local joiner = assistOf(v)
check("80 km/h, a road 20 m ahead and to the side at 12 degrees: the assist picks it up and says it is joining", joiner.engaged == true and joiner.modeLabel == "joining road spline")
local joinCall = driveCalls[#driveCalls]
-- a road at a bigger angle is not joined from open ground (RoadFollow.JOIN_MAX_DEG): a path across the way is nothing to snap to
for _, degrees in ipairs({ 25, 45, 90 }) do
    local hx, hz = math.cos(math.rad(-degrees)), math.sin(math.rad(-degrees))
    local across = newVehicle(0, 20)
    across.heading = { hx, hz }
    across.speed = 80
    across.spec_drivable.cruiseControl.speed = 80
    run(across, 800)
    check(string.format("a road at %d degrees to the way the vehicle goes: not joined", degrees), assistOf(across).modeLabel ~= "joining road spline")
end
check("the join is taken far slower than the 80 km/h setting (under 45)", joinCall.maxSpeed > 0 and joinCall.maxSpeed < 45)
local vv = math.max(80 / 3.6, 3)
check("the steering demand respects the authority limit: |pX| <= a_lat * L^2 / (2 v^2)", math.abs(joinCall.pX) <= 1.25 * RoadFollow.STEER_LATERAL_ACCEL * (joinCall.pX ^ 2 + joinCall.pZ ^ 2) / (2 * vv * vv) + 1e-6)
check("while joining the supervisor does not call a stop (the vehicle is 20 m from the line on purpose)", joiner.sup.stopping == false)
-- the join slows the vehicle below the speed a join is first looked for at: it must carry on, not lose the road
v.pos = { 20, 20 + 20 * h25[2] / h25[1] }
v.speed = 22
run(v, 1200)
check("a join under way, the vehicle slowed to 22 km/h by it: the assist is still on, still joining", joiner.engaged == true and joiner.modeLabel == "joining road spline" and #driveCalls > 20)
check("... and did not hand back to plain cruise", joiner.status == nil)
v = newVehicle(0, 20)
v.heading = { h25[1], h25[2] }
v.speed = 20
run(v, 800)
check("at 20 km/h (under the join speed) no join is looked for", assistOf(v).engaged == false)
v = newVehicle(0, 20)
v.heading = { math.cos(math.rad(25)), math.sin(math.rad(25)) }
v.speed = 80
run(v, 800)
check("heading away from the road: no join", assistOf(v).engaged == false)

-- ===== autopilot: off the road is corrected or stopped =====
WailaPathStore.clear()
WailaPathStore.add({ points = { { -500, 0 }, { 1500, 0 } }, kind = "spline", source = "map", width = 7 })
warnings = {}
v = newVehicle(0, 0.5)
v.speed = 60
v.spec_drivable.cruiseControl.speed = 60
run(v, 800)
check("on the road at 60 km/h: engaged, not stopping", assistOf(v).engaged == true and assistOf(v).sup.stopping == false)
v.pos = { 15, 6.2 }                    -- thrown 6 m to the side of the road's line, still pointing along it
run(v, 100)
check("suddenly 6 m off the line: the supervisor stops the vehicle ('left the road')", assistOf(v).sup.stopping == true and assistOf(v).sup.reason == "left the road")
local stopCall = driveCalls[#driveCalls]
check("the vehicle is told to brake to a stop, not to carry on", stopCall.maxSpeed == 0 and stopCall.allowed == false)
v.speed = 0.4
run(v, 100)
check("when it has stopped: cruise control is switched off", v.cruiseOffCalls >= 1 and v.spec_drivable.cruiseControl.state == Drivable.CRUISECONTROL_STATE_OFF)
check("... the player is told why", #warnings >= 1 and warnings[#warnings]:find("left the road", 1, true) ~= nil)
check("... and the assist has handed back", assistOf(v).engaged == false)

-- a vehicle that is only a little off-centre is left alone
v = newVehicle(0, 0.5)
v.speed = 60
v.spec_drivable.cruiseControl.speed = 60
run(v, 800)
v.pos = { 15, 1.6 }
run(v, 300)
check("1.6 m off the line of a 7 m road (limit 2.1): no stop", assistOf(v).sup.stopping == false)
-- the player taking over clears everything
v.pos = { 15, 6.2 }
run(v, 100)
check("(stopping again)", assistOf(v).sup.stopping == true)
run(v, 800, { 0, 0.6 })
check("the player steering during a stop: control back, latch cleared", assistOf(v).engaged == false and assistOf(v).sup.stopping == false)
-- ===== turn signals =====
local function crossingPaths()
    WailaPathStore.clear()
    WailaPathStore.add({ points = { { -300, 0 }, { -6, 0 } }, kind = "spline", source = "map" })
    WailaPathStore.add({ points = { { 6, 0 }, { 1500, 0 } }, kind = "spline", source = "map" })
    WailaPathStore.add({ points = { { 0, 8 }, { 0, 300 } }, kind = "spline", source = "map" })     -- z points south in the game: this one is to the RIGHT of an eastbound vehicle
    WailaPathStore.add({ points = { { 0, -8 }, { 0, -300 } }, kind = "spline", source = "map" })   -- north = to its LEFT
end
haveBitmapData = false
crossingPaths()
v = newVehicle(-25, 0)
v.speed = 40
v.spec_drivable.cruiseControl.speed = 40
run(v, 700)
check("at a crossing with no signal: the line goes straight across", assistOf(v).engaged and assistOf(v).result.turned == false and assistOf(v).result.points[#assistOf(v).result.points][2] > -1.5)
check("signal with nothing engaged is refused", RoadFollow.signal(newVehicle(0, 0), "left") == false)
check("a left click: the signal is set", RoadFollow.signal(v, "left") == true and assistOf(v).intent == "left")
check("... and the vehicle's own turn light goes on (left)", v.turnState == Lights.TURNLIGHT_LEFT)
run(v, 400)
check("with the left signal on, the line turns left (north, -z) at the crossing", assistOf(v).result.turned == true and assistOf(v).result.points[#assistOf(v).result.points][2] < -5)
check("the on-screen mode text will show the signal (state is held)", assistOf(v).intent == "left")
RoadFollow.signal(v, "left")
check("a second left click cancels it (and the light goes off)", assistOf(v).intent == nil and v.turnState == Lights.TURNLIGHT_OFF)
RoadFollow.signal(v, "left")
RoadFollow.signal(v, "right")
check("right after left switches to right", assistOf(v).intent == "right" and v.turnState == Lights.TURNLIGHT_RIGHT)
run(v, 400)
check("with the right signal the line turns right (south, +z)", assistOf(v).result.turned == true and assistOf(v).result.points[#assistOf(v).result.points][2] > 5)

-- the signal is done once the vehicle has turned that way (heading changed 50 degrees to the right)
v.heading = { math.cos(math.rad(60)), math.sin(math.rad(60)) }      -- turned right (towards +z, south)
run(v, 100)
check("the turn is done: the signal clears and the light goes off", assistOf(v).intent == nil and v.turnState == Lights.TURNLIGHT_OFF)

-- a side road that the stored paths do not know (no spline for it): the map pictures still see it
WailaPathStore.clear()
WailaPathStore.add({ points = { { -200, 0 }, { 600, 0 } }, kind = "spline", source = "map", width = 7 })
local mainAndSide = function(x, z)
    if math.abs(z) <= 3 then return 2 end
    if x >= 22 and x <= 29 and z < -3 and z >= -120 then return 2 end
    return 0
end
classAt = mainAndSide
haveBitmapData = true
v = newVehicle(0, 0)
v.speed = 40
v.spec_drivable.cruiseControl.speed = 40
run(v, 700)
check("no signal, a side road the paths do not know: straight on, along the spline", assistOf(v).engaged and assistOf(v).modeLabel == "road spline" and assistOf(v).result.turned ~= true)
RoadFollow.signal(v, "left")
run(v, 400)
check("a left signal: the map picture's opening is used and the line turns left into it (the side road is to the north, -z)", assistOf(v).result.turned == true and assistOf(v).result.points[#assistOf(v).result.points][2] < -5)
check("... labelled as auto-detect (the line is no longer the spline's)", assistOf(v).modeLabel == "auto-detect")
RoadFollow.signal(v, "left")
run(v, 400)
check("the signal cancelled: back to the spline", assistOf(v).modeLabel == "road spline")
classAt = function() return 2 end
haveBitmapData = false
RoadFollow.signal(v, "left")
run(v, 400)
check("a signal with no map pictures: still just the spline, straight on", assistOf(v).modeLabel == "road spline" and assistOf(v).result.turned ~= true)

-- ===== a T junction: the stem road ends side-on in a crossing road =====
WailaPathStore.clear()
WailaPathStore.add({ points = { { 0, 0 }, { 100, 0 } }, kind = "spline", source = "map", width = 7 })
WailaPathStore.add({ points = { { 100, -200 }, { 100, 200 } }, kind = "spline", source = "map", width = 7 })
haveBitmapData = false
classAt = function() return 2 end
v = newVehicle(70, 0)
v.speed = 40
v.spec_drivable.cruiseControl.speed = 50
run(v, 700)
local tAssist = assistOf(v)
check("approaching a T with no signal: engaged, the line ends at the junction", tAssist.engaged == true and tAssist.result.ends == true and tAssist.result.junctionEnd == true)
local tCall = driveCalls[#driveCalls]
check("... braking for it: at 26 m from the mouth the speed asked for is what stops it 7 m before (about 21 km/h)", tCall.maxSpeed > 15 and tCall.maxSpeed < 30)
v.pos = { 87, 0 }
v.speed = 0
run(v, 1200)
check("at the stop line (6 m before the mouth plus the front overhang, 3 m when not known), standing: still engaged (not 'too slow'), waiting, told to stay", tAssist.engaged == true and tAssist.waiting == true and driveCalls[#driveCalls].maxSpeed == 0 and driveCalls[#driveCalls].allowed == false)
check("... and no stop is called, no hazard lights (it is just waiting)", tAssist.sup.stopping == false and tAssist.hazard ~= true)
RoadFollow.signal(v, "left")
run(v, 400)
check("a left signal at the stop line: the line turns left (north, -z), it is no longer waiting", tAssist.result.turned == true and tAssist.waiting == false and tAssist.result.points[#tAssist.result.points][2] < -5)
check("... and it moves off, slowly (never more than what can be braked down to the 15 km/h turn speed by the start of the corner, a few metres ahead: under 27)", driveCalls[#driveCalls].maxSpeed > 0 and driveCalls[#driveCalls].maxSpeed <= 27 and driveCalls[#driveCalls].allowed == true)
RoadFollow.signal(v, "left")
RoadFollow.signal(v, "right")
run(v, 400)
check("a right signal: turns right instead (south, +z)", tAssist.result.turned == true and tAssist.result.points[#tAssist.result.points][2] > 5)

-- ===== cross traffic at the T: give way to what is coming along the road about to be entered =====
CollisionFlag = { TRAFFIC_VEHICLE = 524288, VEHICLE = 65536, DYNAMIC_OBJECT = 4096 }
g_currentMission.nodeToObject = {}
local crossCar = nil                       -- { x, z, hx, hz } centre and half sizes of a box seen from above
raycastAll = function(x, y, z, nx, ny, nz, maxDistance, callbackName, target, mask)
    if crossCar == nil then return end
    local tmin, tmax = 0, maxDistance
    for _, axis in ipairs({ { x, nx, crossCar.x - crossCar.hx, crossCar.x + crossCar.hx }, { z, nz, crossCar.z - crossCar.hz, crossCar.z + crossCar.hz } }) do
        local origin, direction, lo, hi = axis[1], axis[2], axis[3], axis[4]
        if math.abs(direction) < 1e-9 then
            if origin < lo or origin > hi then tmax = -1 end
        else
            local t1, t2 = (lo - origin) / direction, (hi - origin) / direction
            if t1 > t2 then t1, t2 = t2, t1 end
            tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
        end
    end
    if tmax >= tmin and tmax >= 0 then
        target[callbackName](target, 888, x + nx * tmin, y, z + nz * tmin, tmin, 0, 0, 0, 0, 0, true)
    end
end
local function crossDrive(vehicle, steps, stepZ)
    for _ = 1, steps do
        run(vehicle, 100)
        crossCar.z = crossCar.z + stepZ
    end
end
WailaPathStore.clear()
WailaPathStore.add({ points = { { 0, 0 }, { 100, 0 } }, kind = "spline", source = "map", width = 7 })
WailaPathStore.add({ points = { { 100, -200 }, { 100, 200 } }, kind = "spline", source = "map", width = 7 })
v = newVehicle(70, 0)
v.speed = 40
v.spec_drivable.cruiseControl.speed = 50
crossCar = nil
run(v, 700)
v.pos = { 87, 0 }
v.speed = 0
run(v, 1500)
local gAssist = assistOf(v)
RoadFollow.signal(v, "left")
run(v, 600)
check("a left signal at the stop line, the road across empty: no giving way, it moves off", gAssist.giveWay == false and driveCalls[#driveCalls].maxSpeed > 0)
-- a car coming from the north (the left) at 10 m/s along the cross road, 60 m away
crossCar = { x = 100, z = -60, hx = 1.0, hz = 2.4 }
crossDrive(v, 14, 1.0)
check("a car coming along the cross road from the left: giving way, only what stops before the turn is asked for (3 m: under 12 km/h)", gAssist.giveWay == true and driveCalls[#driveCalls].maxSpeed < 12)
v.pos = { 92, 0 }
run(v, 300)
check("... at the start of the turn: told to stand, waiting", gAssist.giveWay == true and driveCalls[#driveCalls].maxSpeed == 0 and driveCalls[#driveCalls].allowed == false and gAssist.waiting == true)
check("... and it is only waiting: engaged, no stop called, no hazard lights", gAssist.engaged == true and gAssist.sup.stopping == false and gAssist.hazard ~= true)
-- it drives past and away to the south
crossCar.z = 30
crossDrive(v, 6, 1.0)
check("the car has gone by (driving away to the south): still waiting a moment after the way is clear", gAssist.giveWay == true or gAssist.crossHoldMs > 0)
crossCar = nil
run(v, 1800)
check("the way clear for more than a second: it goes", gAssist.giveWay == false and driveCalls[#driveCalls].maxSpeed > 0)
-- a right turn: only the traffic from the left matters; a car coming from the right (the south) is not given way to
RoadFollow.signal(v, "left")
RoadFollow.signal(v, "right")
crossCar = { x = 100, z = 60, hx = 1.0, hz = 2.4 }
crossDrive(v, 10, -1.0)
check("a right turn, a car coming from the right (the far lane of the road across): not given way to", gAssist.giveWay == false)
RoadFollow.signal(v, "right")
-- detection off: no waiting
RoadFollow.GIVE_WAY = false
RoadFollow.signal(v, "left")
crossCar = { x = 100, z = -30, hx = 1.0, hz = 2.4 }
crossDrive(v, 8, 0.5)
check("giving way switched off: the car coming is ignored", gAssist.giveWay == false)
RoadFollow.GIVE_WAY = true
RoadFollow.signal(v, "left")
raycastAll = nil
crossCar = nil

-- the debug view's two options: the road read as if a signal were on, without touching the assist's turn state
raycastAll = nil
v = newVehicle(70, 0)
v.speed = 40
v.spec_drivable.cruiseControl.speed = 50
run(v, 700)
v.pos = { 87, 0 }
v.speed = 0
run(v, 1200)
local optAssist = assistOf(v)
current = v
local leftOption = v:scanRoadAhead(false, "left")
local rightOption = v:scanRoadAhead(false, "right")
check("debug options at a T with no signal: a left line (north) and a right line (south) are both found",
    leftOption.valid and leftOption.turned and leftOption.points[#leftOption.points][2] < -5
    and rightOption.valid and rightOption.turned and rightOption.points[#rightOption.points][2] > 5)
check("... and reading them left the assist's own state alone (no signal, no remembered turn)", optAssist.intent == nil and optAssist.turnPathId == nil and optAssist.turnTargetId == nil and optAssist.frozenTurn == nil)
-- with a signal out, the straight way is read too (as if none were out), and a longer look reaches further
RoadFollow.signal(v, "left")
local straightOption = v:scanRoadAhead(false, "straight")
local nearLook = v:scanRoadAhead(false, "left")
local farLook = v:scanRoadAhead(false, "left", 120)
check("a left signal out: the straight way is still read, and it is not a turn", straightOption.valid and straightOption.turned ~= true)
check("... a longer look (120 m) gives a longer line than the normal one", RoadCenterline.length(farLook.points) > RoadCenterline.length(nearLook.points) + 10)
RoadFollow.signal(v, "left")

-- ===== correcting: one speed reduction, not a ratchet =====
WailaPathStore.clear()
WailaPathStore.add({ points = { { -500, 0 }, { 5000, 0 } }, kind = "spline", source = "map", width = 7 })
haveBitmapData = false
v = newVehicle(0, 0)
v.speed = 30
run(v, 600)
v.pos = { 0, 2.6 }                                  -- off the line of a 7 m road by more than it can stand: the supervisor corrects
run(v, 300)
local firstCap = driveCalls[#driveCalls].maxSpeed
check("correcting: the speed asked for is reduced once (about 70% of the speed it had, 21 km/h at most)", assistOf(v).sup.level == 1 and firstCap <= 21.5 and firstCap >= 8)
v.speed = firstCap
run(v, 300)
check("... and while it goes on, the car slowing down does not lower the request again and again (the same cap)", assistOf(v).sup.level == 1 and math.abs(driveCalls[#driveCalls].maxSpeed - firstCap) < 0.6)
v.pos = { 0, 0 }
run(v, 800)
check("when the correcting is over the cap is gone", assistOf(v).sup.level == 0 and assistOf(v).correctCapKmh == nil)

-- the game's own indicator lights count as the intent without any click
crossingPaths()
v = newVehicle(-25, 0)
v.speed = 40
v.spec_drivable.cruiseControl.speed = 40
v.turnState = Lights.TURNLIGHT_LEFT
run(v, 800)
check("the vehicle's own left indicator is read as the intent", RoadFollow.getIntent(v) == "left" and assistOf(v).result.turned == true)

-- a signal that is never used times out; handing back clears it
v = newVehicle(-25, 0)
v.speed = 40
run(v, 400)
RoadFollow.signal(v, "right")
for _ = 1, 40 do assistOf(v).intentMs = assistOf(v).intentMs + 1000; run(v, 16) end
check("a signal unused for 30 s is dropped", assistOf(v).intent == nil)
RoadFollow.signal(v, "left")
v.spec_drivable.cruiseControl.state = 0
run(v, 100)
check("cruise control off: the assist hands back and the signal is cleared", assistOf(v).engaged == false and assistOf(v).intent == nil)

-- ===== meandering =====
WailaPathStore.clear()
WailaPathStore.add({ points = { { -500, 0 }, { 5000, 0 } }, kind = "spline", source = "map", width = 7 })
v = newVehicle(0, 0)
v.speed = 40
v.spec_drivable.cruiseControl.speed = 40
run(v, 800)
local steadyZ = driveCalls[#driveCalls].pZ
-- weave: throw the vehicle from 1.1 m left to 1.1 m right of the line every half second for 8 s
local flip = 1
for step = 1, 16 do
    v.pos = { v.pos[1] + 6, 1.1 * flip }
    flip = -flip
    run(v, 500)
end
check("weaving across the line (1.1 m either side, every half second): the follower notices", assistOf(v).meander.severity > 0.3 and assistOf(v).meandering == true)
local calmZ = driveCalls[#driveCalls].pZ
check("... and answers with a longer lookahead (the aim point is further ahead than when steady)", calmZ > steadyZ * 1.2)
-- calm again
v.pos = { v.pos[1], 0 }
for step = 1, 20 do
    v.pos = { v.pos[1] + 6, 0.05 }
    run(v, 500)
end
check("steady again after a while: it stops calming", assistOf(v).meander.severity == 0 and assistOf(v).meandering == false)
-- a signalled turn is worked out once and then driven: later scans do not find it again from the paths
haveBitmapData = false
crossingPaths()
v = newVehicle(-25, 0)
v.speed = 40
v.spec_drivable.cruiseControl.speed = 40
run(v, 700)
RoadFollow.signal(v, "left")
run(v, 400)
local keptEnd = assistOf(v).result.points[#assistOf(v).result.points]
check("signalled turn: the line turns left at the crossing and is kept", assistOf(v).result.turned == true and keptEnd[2] < -5 and assistOf(v).frozenTurn ~= nil)
WailaPathStore.clear()
WailaPathStore.add({ points = { { -300, 0 }, { 1500, 0 } }, kind = "spline", source = "map" })     -- the side roads vanish from the store: a fresh scan would go straight on
v.pos = { -20, 0 }
run(v, 400)
check("... a fresh scan could not find the turn any more, the kept line is still driven", assistOf(v).result.turned == true and assistOf(v).result.points[#assistOf(v).result.points][2] < -5)
RoadFollow.signal(v, "left")
run(v, 400)
check("... and with the signal off the normal scan is back (straight on)", assistOf(v).result.turned ~= true)


-- ===== "unstable underground" is only said when the ground is what limits the speed =====
do
    local savedClass = classAt
    classAt = function() return 1 end                                  -- worn trail everywhere (85% of the cruise speed)
    local slow = newVehicle(0, 0)
    slow.speed = 30
    slow.spec_drivable.cruiseControl.speed = 40
    slow.getSpeedLimit = function() return 15, true end                -- a machine that may not go faster than 15 (a beet harvester, an implement's own limit)
    run(slow, 800)
    check("the machine's own 15 km/h limit is lower than the trail's: the ground is not blamed", assistOf(slow).askedKmh <= 15.01 and assistOf(slow).groundLimited == false)
    local free = newVehicle(0, 0)
    free.speed = 30
    free.spec_drivable.cruiseControl.speed = 40
    run(free, 800)
    check("no lower limit: the trail's 85% is what limits, and it is said", assistOf(free).groundLimited == true)
    classAt = function() return 2 end
    local road = newVehicle(0, 0)
    road.speed = 30
    road.spec_drivable.cruiseControl.speed = 40
    run(road, 800)
    check("on a road: nothing limits by the ground", assistOf(road).groundLimited == false)
    classAt = savedClass
end

finish("road_assist_path_test")
