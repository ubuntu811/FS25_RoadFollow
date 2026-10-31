dofile("tests/stubs.lua")

g_currentModName = "FS25_RoadFollow"
addConsoleCommand = function() end
Drivable = { CRUISECONTROL_STATE_OFF = 0 }
Lights = { TURNLIGHT_OFF = 0, TURNLIGHT_LEFT = 1, TURNLIGHT_RIGHT = 2, TURNLIGHT_HAZARD = 3 }
local driveCalls = {}
AIVehicleUtil = { driveToPoint = function(vehicle, dt, acceleration, allowed, forwards, pX, pZ, maxSpeed)
    driveCalls[#driveCalls + 1] = { pX = pX, pZ = pZ, maxSpeed = maxSpeed, forwards = forwards, allowed = allowed }
end }
getTerrainHeightAtWorldPos = function() return 100 end
g_terrainNode = 1

local roadSample = function(x, z) return math.abs((math.floor(z / 2) + 0.5) * 2) <= 3 and 2 or 0 end
local currentSample = roadSample
local treeFn = function() return false end
local treeData = false
local buildingFn = function() return false end
local buildingData = false
g_currentMission = { wailaTrailTracer = { sampleDrivable = function(x, z) return currentSample(x, z) end, hasDrivableData = function() return true end,
    sampleTree = function(x, z) return treeFn(x, z) end, hasTreeData = function() return treeData end,
    sampleBuilding = function(x, z) return buildingFn(x, z) end, hasBuildingData = function() return buildingData end } }

dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadSupervisor.lua")
dofile("scripts/RoadMeander.lua")
dofile("scripts/RoadFollow.lua")
dofile("scripts/RoadLead.lua")
dofile("scripts/RoadFieldCourse.lua")
dofile("scripts/RoadMapper.lua")

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

local function assistOf(v) return v["spec_FS25_RoadFollow.roadFollow"].assist end

local function newVehicle(x, z)
    local v = { pos = { x, z }, heading = { 1, 0 }, speed = 30, isServer = true, movingDirection = 1 }
    v["spec_FS25_RoadFollow.roadFollow"] = {
        isActive = false, actionEvents = {},
        assist = { engaged = false, goodScans = 0, badMs = 0, scanMs = 0, steerGraceMs = 0, result = nil, warned = false, broken = false, sup = RoadSupervisor.new(), saturated = false, meander = RoadMeander.new(), intent = nil, intentMs = 0 },
    }
    v.spec_drivable = { cruiseControl = { state = 1, speed = 40 } }
    v.getAISteeringNode = function() return "s" end
    v.getAIDirectionNode = function() return "d" end
    v.getLastSpeed = function(self) return self.speed end
    v.getSpeedLimit = function() return 60, true end
    v.getCruiseControlMaxSpeed = function(self) return self.spec_drivable.cruiseControl.speed end
    v.getName = function() return "tractor" end
    v.getRootVehicle = function(self) return self end
    v.setTurnLightState = function(self, state) self.turnState = state end
    v.setCruiseControlState = function(self, state) self.spec_drivable.cruiseControl.state = state end
    for _, name in ipairs({ "scanRoadAhead" }) do v[name] = RoadFollow[name] end
    return v
end

-- runs the physics override for `ms`; input = { forward, side, handbrake }
local function run(vehicle, ms, input)
    current = vehicle
    input = input or {}
    superCalls, driveCalls = 0, {}
    for _ = 1, ms / 16 do
        RoadFollow.updateVehiclePhysics(vehicle, superFunc, input[1] or 0, input[2] or 0, input[3] or false, 16)
    end
end

local v = newVehicle(0, 0)
v.spec_drivable.cruiseControl.state = 0
run(v, 400)
check("cruise control off: always the base game's own physics", superCalls > 20 and #driveCalls == 0)

v = newVehicle(0, 0)
run(v, 800)
check("cruise on, on a road, no input: the assist drives after a few scans", #driveCalls > 20)
check("...and the base physics only ran during engagement (first scans)", superCalls <= 12 and superCalls > 0)
check("assist engaged, shown in its state", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == true)
local last = driveCalls[#driveCalls]
check("it steers forwards, allowed, with the target ahead on the road", last.forwards == true and last.allowed == true and last.pZ > 5 and math.abs(last.pX) < 1)
check("speed is the cruise setting on a straight road", last.maxSpeed <= 40.01 and last.maxSpeed > 30)

-- the player steers (a held key, longer than the tap time): control goes to the player, and stays with them for the grace time
run(v, 800, { 0, 0.6 })
run(v, 100, { 0, 0.6 })
check("steering input: base physics, no assist", superCalls > 0 and #driveCalls == 0 and v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == false)
run(v, 800)
check("after letting go: still the player's for the grace period (0.8 s)", #driveCalls == 0 and superCalls > 0)
run(v, 2200)
check("after the grace period the assist is back", #driveCalls > 0)

-- a tap on a steering key is the turn signal, and the assist keeps driving
local tapAssist = v["spec_FS25_RoadFollow.roadFollow"].assist
check("(taps as the turn signal are off by default: the signal keys are the signal)", RoadFollow.TAP_SIGNALS == false)
RoadFollow.TAP_SIGNALS = true      -- the tap feature stays, behind the switch: tested here
run(v, 400)
check("(driving again before the tap tests)", tapAssist.engaged == true)
run(v, 80, { 0, 0.6 })
check("a tap, still pressed after 80 ms: the assist keeps driving, no hand-over", tapAssist.engaged == true and #driveCalls > 0 and superCalls == 0)
run(v, 48, { 0, 0 })
check("released: the signal is set on the side of the key (axis +, the right key, right)", tapAssist.engaged == true and tapAssist.intent == "right")
run(v, 200, { 0, 0 })
check("... and the assist drives on, the player never had control", tapAssist.engaged == true and #driveCalls > 0 and tapAssist.steerGraceMs <= 0)
run(v, 80, { 0, 0.6 })
run(v, 48, { 0, 0 })
check("the same key again cancels the signal", tapAssist.intent == nil)
run(v, 80, { 0, -0.6 })
run(v, 48, { 0, 0 })
check("the other key (axis -, the left key) signals left", tapAssist.intent == "left")
run(v, 80, { 0, 0.6 })
run(v, 48, { 0, 0 })
check("the opposite key while a signal is on switches it (right now, after left)", tapAssist.intent == "right")
-- taps switched off: any steering input is the old hand-over
RoadFollow.TAP_SIGNALS = false
run(v, 80, { 0, 0.6 })
check("taps switched off: any steering at all hands over at once", tapAssist.engaged == false and tapAssist.intent == nil)
RoadFollow.TAP_SIGNALS = true
run(v, 2800)
check("(assist back after the grace period)", tapAssist.engaged == true)
run(v, 900, { 0, 0.6 })
check("a long press is a take-over: base physics, no signal set", superCalls > 0 and tapAssist.engaged == false and tapAssist.intent == nil)
run(v, 100, { 0, 0 })
check("... and releasing a long press does not signal", tapAssist.intent == nil)
run(v, 2800)
RoadFollow.STEER_LEFT_SIGN = 1
run(v, 80, { 0, 0.6 })
run(v, 48, { 0, 0 })
check("with the sides flipped (roadFollowTapFlip), axis + signals left", tapAssist.intent == "left")
RoadFollow.STEER_LEFT_SIGN = -1
tapAssist.intent = nil
run(v, 400)

-- pedal or handbrake
run(v, 100, { 0.5, 0 })
check("accelerator pressed: base physics", #driveCalls == 0)
run(v, 800)
run(v, 100, { 0, 0, true })
check("handbrake: base physics", #driveCalls == 0)

-- too slow (starting off)
v = newVehicle(0, 0)
v.speed = 2
run(v, 600)
check("below 5 km/h: no assist", #driveCalls == 0)

-- reversing
v = newVehicle(0, 0)
v.movingDirection = -1
run(v, 600)
check("reversing: no assist", #driveCalls == 0)

-- off the road
v = newVehicle(0, 30)
run(v, 600)
check("not on a road: plain cruise control", #driveCalls == 0 and superCalls > 30)

-- the road ends: with the autopilot (the default) the vehicle is brought to a controlled stop, with it
-- off the lost road is handed back to plain cruise control
currentSample = function(x, z) return x <= 40 and roadSample(x, z) or 0 end
v = newVehicle(0, 0)
run(v, 400)
check("road ahead: engaged", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == true)
v.pos = { 36, 0 }
run(v, 2500)
local endAssist = v["spec_FS25_RoadFollow.roadFollow"].assist
check("the road ends ahead at 30 km/h: the supervisor stops the vehicle (autopilot), it does not hand back", endAssist.engaged == true and endAssist.sup.stopping == true and endAssist.sup.reason == "no road ahead")
check("... and the vehicle is told to stop: speed 0, not allowed to drive", driveCalls[#driveCalls].maxSpeed == 0 and driveCalls[#driveCalls].allowed == false)
RoadFollow.AUTOPILOT = false
v = newVehicle(0, 0)
run(v, 400)
v.pos = { 36, 0 }
run(v, 1200)
check("autopilot off: the lost road is handed back to plain cruise control", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == false and superCalls > 0)
RoadFollow.AUTOPILOT = true
v = newVehicle(0, 0)
v.speed = 10
run(v, 400)
v.pos = { 36, 0 }
run(v, 1200)
check("below 15 km/h a lost road is a field, not an emergency: handed back", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == false and not v["spec_FS25_RoadFollow.roadFollow"].assist.sup.stopping)
currentSample = roadSample

-- a tight bend is taken slower than a straight
local bend = function(x, z)
    local cx = (math.floor(x / 2) + 0.5) * 2
    local cz = (math.floor(z / 2) + 0.5) * 2
    local d = math.sqrt(cx * cx + (cz - 12) ^ 2)
    return math.abs(d - 12) <= 3 and cx >= -2 and 2 or 0
end
currentSample = bend
v = newVehicle(0, 0)
run(v, 800)
last = driveCalls[#driveCalls]
check("a tight bend: the assist asks for less than the 40 km/h cruise setting", last ~= nil and last.maxSpeed < 40)
currentSample = roadSample

-- guards
v = newVehicle(0, 0)
v["spec_FS25_RoadFollow.roadFollow"].isActive = true
run(v, 400)
check("the road-follow job is active: the assist stays out of it", #driveCalls == 0)
RoadFollow.assistEnabled = false
v = newVehicle(0, 0)
run(v, 400)
check("switched off (console): never", #driveCalls == 0 and superCalls > 0)
RoadFollow.assistEnabled = true
v = newVehicle(0, 0)
current = v
superCalls = 0
RoadFollow.updateVehiclePhysics(v, superFunc, nil, nil, false, 16)
RoadFollow.updateVehiclePhysics(v, superFunc, nil, nil, false, 16)
check("unexpected arguments: base physics, no error", superCalls == 2 and v["spec_FS25_RoadFollow.roadFollow"].assist.warned == true)
v = newVehicle(0, 0)
v.isServer = false
run(v, 400)
check("not the server: base physics", #driveCalls == 0)
-- once engaged, a slow stretch does not switch the assist off (it used to flap on and off)
v = newVehicle(0, 0)
run(v, 600)
check("engaged at speed", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == true)
v.speed = 3
run(v, 600)
check("slowed to 3 km/h: still engaged, still steering", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == true and #driveCalls > 10)
v.speed = 0.5
run(v, 200)
check("standing still although the assist asks for speed: not handed back to plain cruise (which would keep pushing), still engaged for now", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == true)
run(v, 3200)
check("... and after 3 s of not moving: stopped properly (cruise off, hazard lights), 'stuck'", v.spec_drivable.cruiseControl.state == 0 and v["spec_FS25_RoadFollow.roadFollow"].assist.hazard == true and v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == false)
-- moving again clears the count
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
v.speed = 0.5
run(v, 2000)
v.speed = 8
run(v, 400)
v.speed = 0.5
run(v, 2000)
check("a standstill of 2 s, driving, another 2 s: the count restarted, no stop", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == true and v["spec_FS25_RoadFollow.roadFollow"].assist.hazard ~= true)
v = newVehicle(0, 0)
v.speed = 3
run(v, 600)
check("but from a standstill-ish 3 km/h it does not engage", #driveCalls == 0)

-- the steering target is filtered: a sudden sideways jump of the road does not jump the target
v = newVehicle(0, 0)
run(v, 800)
local settled = driveCalls[#driveCalls].pX
-- the road moves 3 m to the side: first frames after the change must change pX gradually
currentSample = function(x, z) return math.abs((math.floor((z - 3) / 2) + 0.5) * 2) <= 3 and 2 or 0 end
run(v, 48)
local early = driveCalls[#driveCalls].pX
run(v, 1500)
local late = driveCalls[#driveCalls].pX
check("a 3 m sideways jump of the road: the target eases over instead of snapping", math.abs(early - settled) < math.abs(late - settled))
currentSample = roadSample

-- an error inside the assisted drive must not leave the vehicle undriven
v = newVehicle(0, 0)
local realDrive = AIVehicleUtil.driveToPoint
AIVehicleUtil.driveToPoint = function() error("boom") end
run(v, 800)
check("an error in the assisted drive: base physics takes over, the assist is switched off for this vehicle",
    v["spec_FS25_RoadFollow.roadFollow"].assist.broken == true and superCalls > 0)
superCalls = 0
AIVehicleUtil.driveToPoint = realDrive
run(v, 400)
check("...and stays off afterwards (no repeated errors)", #driveCalls == 0 and superCalls > 0)
-- ===== mouse wheel as the speed knob =====
v = newVehicle(0, 0)
v.setCruiseControlMaxSpeed = function(self, speed) self.spec_drivable.cruiseControl.speed = speed end
v.spec_drivable.cruiseControl.maxSpeed = 60
check("not engaged: the wheel does nothing", RoadFollow.adjustSpeed(v, 1) == false and v.spec_drivable.cruiseControl.speed == 40)
run(v, 600)
check("(engaged)", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == true)
check("wheel up: 5 km/h faster", RoadFollow.adjustSpeed(v, 1) == true and v.spec_drivable.cruiseControl.speed == 45)
RoadFollow.adjustSpeed(v, 1)
check("another notch: 50", v.spec_drivable.cruiseControl.speed == 50)
RoadFollow.adjustSpeed(v, -1)
check("wheel down: 45 again", v.spec_drivable.cruiseControl.speed == 45)
for _ = 1, 10 do RoadFollow.adjustSpeed(v, 1) end
check("never above the vehicle's own cruise maximum (60)", v.spec_drivable.cruiseControl.speed == 60 and RoadFollow.adjustSpeed(v, 1) == false)
for _ = 1, 20 do RoadFollow.adjustSpeed(v, -1) end
check("never below 5 km/h", v.spec_drivable.cruiseControl.speed == 5)
v.spec_drivable.cruiseControl.speed = 42
RoadFollow.adjustSpeed(v, 1)
check("a speed set to 42 by the base keys snaps to the 5 km/h grid (45)", v.spec_drivable.cruiseControl.speed == 45)
check("the new speed is noted for the on-screen text", v["spec_FS25_RoadFollow.roadFollow"].assist.speedNote == 45 and v["spec_FS25_RoadFollow.roadFollow"].assist.speedNoteMs > 0)
RoadFollow.WHEEL_STEP_KMH = 0
check("step 0 switches it off", RoadFollow.adjustSpeed(v, 1) == false)
RoadFollow.WHEEL_STEP_KMH = 5
check("no vehicle: no error", RoadFollow.adjustSpeed(nil, 1) == false)
local mid = v.spec_drivable.cruiseControl.speed
run(v, 800)
check("the changed speed is what the assist then asks for (maxSpeed follows the cruise setting)", driveCalls[#driveCalls].maxSpeed <= mid + 0.01 and driveCalls[#driveCalls].maxSpeed > mid - 12)
-- ===== trees =====
treeData = true
treeFn = function(x, z) return (x - 20) ^ 2 + (z - 0.4) ^ 2 <= 6.25 end
currentSample = roadSample                               -- an 8 m road (pixels of 2 m)
v = newVehicle(0, 0)
run(v, 800)
local treeAssist = v["spec_FS25_RoadFollow.roadFollow"].assist
check("a tree dot on the line 20 m ahead, a wide road: the assist drives round it (nudged), no stop", treeAssist.engaged == true and treeAssist.result.nudged == true and treeAssist.sup.stopping == false)
local clearOfTree = true
for _, p in ipairs(treeAssist.result.points) do if treeFn(p[1], p[2]) then clearOfTree = false end end
check("the line the assist steers by is clear of the tree", clearOfTree)

currentSample = function(x, z) return math.abs((math.floor(z / 2) + 0.5) * 2) <= 1 and 2 or 0 end   -- a 2-4 m track
v = newVehicle(0, 0)
run(v, 1500)
treeAssist = v["spec_FS25_RoadFollow.roadFollow"].assist
check("the same tree on a track too narrow to pass: the vehicle is stopped for it", treeAssist.sup.stopping == true and treeAssist.sup.reason == "obstacle ahead")
check("... told to brake to a stop, not to drive on", driveCalls[#driveCalls].maxSpeed == 0 and driveCalls[#driveCalls].allowed == false)
v.speed = 0.3
run(v, 100)
check("... and once stopped, cruise control is switched off", v.spec_drivable.cruiseControl.state == 0 or v["spec_FS25_RoadFollow.roadFollow"].assist.engaged == false)
check("... with the hazard lights on (from the moment it decided to stop)", v.turnState == Lights.TURNLIGHT_HAZARD and v["spec_FS25_RoadFollow.roadFollow"].assist.hazard == true)
run(v, 100)
check("... they stay on while it stands there", v.turnState == Lights.TURNLIGHT_HAZARD)
run(v, 50, { 0.5, 0 })
check("... and go off when the player gives the pedal", v.turnState == Lights.TURNLIGHT_OFF and v["spec_FS25_RoadFollow.roadFollow"].assist.hazard == false)
treeData = false
currentSample = roadSample
v = newVehicle(0, 0)
run(v, 800)
check("no tree data (the layer was never scanned): nothing changes", v["spec_FS25_RoadFollow.roadFollow"].assist.engaged and v["spec_FS25_RoadFollow.roadFollow"].assist.result.nudged == nil)
-- ===== a road that fades out: the assist's own braking must not turn into "slow driving" =====
currentSample = roadSample
v = newVehicle(0, 0)
run(v, 800)
check("(engaged at road speed before the road fades)", assistOf(v).engaged == true)
currentSample = function() return 0 end
v.speed = 10
run(v, 3000)
check("the road is gone and the vehicle has slowed to 10 km/h (its own end-of-road braking): stopped, not handed back to plain cruise", assistOf(v).sup.stopping == true and assistOf(v).sup.reason == "no road ahead")
currentSample = roadSample
v = newVehicle(0, 0)
v.speed = 10
run(v, 800)
check("(engaged slowly, at 10 km/h, never fast)", assistOf(v).engaged == true)
currentSample = function() return 0 end
run(v, 3000)
check("a road lost while crawling along is still just handed back (not a stop)", assistOf(v).engaged == false and assistOf(v).sup.stopping == false)
currentSample = roadSample

-- ===== buildings =====
buildingData = true
currentSample = roadSample                               -- an 8 m road
buildingFn = function(x, z) return x >= 14 and x <= 34 and z >= 1.5 end   -- a barn wall 1.5 m beside the line
v = newVehicle(0, 0)
run(v, 800)
local barn = v["spec_FS25_RoadFollow.roadFollow"]
check("a barn wall 1.5 m beside the line, the road wide enough: the line is moved away from it, no stop", barn.assist.engaged == true and barn.assist.result.nudged == true and barn.assist.sup.stopping == false)
local clear = true
for _, p in ipairs(barn.assist.result.points) do
    if buildingFn(p[1], p[2]) or buildingFn(p[1] + 1.8, p[2]) or buildingFn(p[1], p[2] + 1.8) then clear = false end
end
check("... and every point of it keeps the vehicle's width away from the wall", clear)

buildingFn = function(x, z) return x >= 20 end                     -- a building straight across the road
v = newVehicle(0, 0)
run(v, 1500)
barn = v["spec_FS25_RoadFollow.roadFollow"]
check("a building across the road: the vehicle is stopped for it", barn.assist.sup.stopping == true and barn.assist.sup.reason == "obstacle ahead")

buildingFn = function(x, z) return x >= -20 and x <= 6 and z >= 1.5 end   -- the vehicle is parked right beside a barn
v = newVehicle(0, 0)
run(v, 800)
barn = v["spec_FS25_RoadFollow.roadFollow"]
check("parked right beside a barn (it is behind and beside, not ahead): the assist still engages and is not stopped", barn.assist.engaged == true and barn.assist.sup.stopping == false)
buildingData = false
buildingFn = function() return false end

-- ===== a vehicle ahead (rays along the line) =====
local sceneCars = {}                                  -- { x = centre, z = centre, half = 2.4 (lengthwise), id }
local rayCalls = 0
CollisionFlag = { TRAFFIC_VEHICLE = 524288, VEHICLE = 65536, DYNAMIC_OBJECT = 4096 }
g_currentMission.nodeToObject = {}
raycastAll = function(x, y, z, nx, ny, nz, maxDistance, callbackName, target, mask)
    rayCalls = rayCalls + 1
    for _, car in ipairs(sceneCars) do
        -- a box of 4.8 x 2 m seen from above: slab test along (nx, nz)
        local tmin, tmax = 0, maxDistance
        for _, axis in ipairs({ { x, nx, car.x - car.half, car.x + car.half }, { z, nz, car.z - 1.0, car.z + 1.0 } }) do
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
            target[callbackName](target, car.id or 777, x + nx * tmin, y, z + nz * tmin, tmin, 0, 0, 0, 0, 0, true)
        end
    end
end
currentSample = roadSample
v = newVehicle(0, 0)
v.speed = 30
sceneCars = {}
run(v, 800)
check("no vehicle ahead: the speed asked for is the cruise setting's (30 km/h road speed here, 40 set)", driveCalls[#driveCalls].maxSpeed > 25 and assistOf(v).lead == nil)
check("... and the rays were cast (a few per 100 ms)", rayCalls > 10)
-- the vehicle drives on towards a stopped car (the harness itself does not move vehicles)
local function approach(vehicle, ms)
    current = vehicle
    superCalls, driveCalls = 0, {}
    for _ = 1, ms / 16 do
        RoadFollow.updateVehiclePhysics(vehicle, superFunc, 0, 0, false, 16)
        vehicle.pos[1] = vehicle.pos[1] + vehicle.speed / 3.6 * 0.016
    end
end
sceneCars = { { x = 32, z = 0, half = 2.4 } }
v = newVehicle(0, 0)
v.speed = 30
approach(v, 1400)
local lead = assistOf(v).lead
check("driving at 30 km/h towards a stopped car: seen, and its speed is read as about 0 (we close at our own speed)", lead ~= nil and lead.vLead < 2)
check("... the gap is the distance from our bumper to its rear", lead ~= nil and math.abs(lead.gap - ((32 - 2.4) - (v.pos[1] + 3))) < 2.5)
check("... and the speed asked for is what stops 5 m behind it: below the 30 km/h of the road", driveCalls[#driveCalls].maxSpeed < 28 and driveCalls[#driveCalls].maxSpeed >= 3 and assistOf(v).following == true)
-- the same gap, but the car ahead drives exactly as fast as we do: it is followed, not feared
sceneCars = { { x = 20, z = 0, half = 2.4 } }
v = newVehicle(0, 0)
v.speed = 30
run(v, 1500)           -- the harness vehicle stands still, so a constant gap means the same speed
lead = assistOf(v).lead
check("a lead that keeps the same distance while we drive 30: it drives about 30 too", lead ~= nil and lead.vLead * 3.6 > 24)
-- a car right in front, we are (nearly) standing
sceneCars = {}
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
sceneCars = { { x = 8, z = 0, half = 2.4 } }
v.speed = 8
run(v, 400)            -- slowing down behind it: the car is seen
v.speed = 0.4
run(v, 600)
check("a stopped car 8 m ahead (bumper gap 2 m), us nearly standing: told to stop, not to creep", driveCalls[#driveCalls].maxSpeed == 0 and driveCalls[#driveCalls].allowed == false)
run(v, 3600)
check("held up for 3 s by the car ahead: a controlled stop ('blocked by something'), cruise control switched off, hazard lights on", v.spec_drivable.cruiseControl.state == 0 and assistOf(v).hazard == true and assistOf(v).engaged == false)
-- a car beside the line (the next lane) is not ahead
v = newVehicle(0, 0)
v.speed = 30
sceneCars = { { x = 20, z = 4, half = 2.4 } }
run(v, 800)
check("a car 4 m to the side (the other lane): not a lead", assistOf(v).lead == nil and driveCalls[#driveCalls].maxSpeed > 25)
-- own parts are not a lead
v = newVehicle(0, 0)
v.speed = 30
sceneCars = { { x = 10, z = 0, half = 2.4, id = 55 } }
g_currentMission.nodeToObject[55] = v
run(v, 800)
check("a hit on the vehicle's own parts (or an implement of it) is ignored", assistOf(v).lead == nil)
g_currentMission.nodeToObject[55] = nil
-- the detection can be switched off, and a failing raycast switches itself off
sceneCars = { { x = 12, z = 0, half = 2.4 } }
RoadFollow.DETECT_VEHICLES = false
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
check("detection switched off: no lead", assistOf(v).lead == nil)
RoadFollow.DETECT_VEHICLES = true
local realRaycast = raycastAll
raycastAll = function() error("boom") end
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
check("a raycast that throws: the assist goes on without detection (flagged once)", assistOf(v).engaged == true and assistOf(v).leadBroken == true)
raycastAll = realRaycast
sceneCars = {}
raycastAll = nil

-- ===== steering by curvature =====
local curveCalls = {}
local curveConvention = -1                 -- the base game's helper: rotatedTime = -(curvature argument) (+ argument = a right turn)
AIVehicleUtil.driveAlongCurvature = function(vehicle, dt, curvature, maxSpeed, acceleration)
    curveCalls[#curveCalls + 1] = { curvature = curvature, maxSpeed = maxSpeed, dt = dt }
    vehicle.rotatedTime = curveConvention * curvature * 10
end
currentSample = roadSample
RoadFollow.CURVATURE_STEERING = true
v = newVehicle(0, 2.2)                     -- 2.2 m off the middle of the road: it has to steer back
v.speed = 30
v.rotatedTime = 0
curveCalls = {}
run(v, 400)
local curveAssist = assistOf(v)
check("steering by curvature: the base game's curvature helper is used (and driveToPoint is not)", #curveCalls > 10 and #driveCalls == 0)
check("the wheel is put the way the aim point lies (rotatedTime has the sign of the curvature wanted)", math.abs(curveAssist.kappa) > 0.002 and v.rotatedTime * curveAssist.kappa > 0)
local fastestStep = 0
for k = 2, #curveCalls do fastestStep = math.max(fastestStep, math.abs(curveCalls[k].curvature - curveCalls[k - 1].curvature)) end
check("the curvature asked for changes no faster than the rate limit (0.35 1/m per s)", fastestStep <= RoadFollow.CURVATURE_RATE * 16 / 1000 + 1e-9)
check("the speed limit is handed over too", curveCalls[#curveCalls].maxSpeed ~= nil and curveCalls[#curveCalls].maxSpeed > 0)
-- the helper turns the other way round than assumed: the first input flips the sign, once
curveConvention = 1
v = newVehicle(0, 2.2)
v.speed = 30
v.rotatedTime = 0
run(v, 400)
check("a helper with the opposite sign: found out on the first input and flipped for good", assistOf(v).curvatureSign == 1 and assistOf(v).curvatureChecked == true and v.rotatedTime * assistOf(v).kappa > 0)
curveConvention = -1
-- a helper that throws: back to driveToPoint
local goodHelper = AIVehicleUtil.driveAlongCurvature
AIVehicleUtil.driveAlongCurvature = function() error("boom") end
v = newVehicle(0, 2.2)
v.speed = 30
run(v, 400)
check("a curvature helper that throws: flagged once, the assist drives on with driveToPoint", assistOf(v).curvatureBroken == true and #driveCalls > 10)
AIVehicleUtil.driveAlongCurvature = goodHelper
RoadFollow.CURVATURE_STEERING = false
v = newVehicle(0, 2.2)
v.speed = 30
curveCalls = {}
run(v, 400)
check("steering by curvature switched off: driveToPoint as before", #curveCalls == 0 and #driveCalls > 10)
RoadFollow.CURVATURE_STEERING = true
AIVehicleUtil.driveAlongCurvature = nil
v = newVehicle(0, 2.2)
v.speed = 30
run(v, 400)
check("a game version without the helper: driveToPoint", #driveCalls > 10)

-- ===== the map border =====
g_currentMission.terrainSize = 100                 -- a tiny map: the border is at x = +-50 (46 with the margin)
currentSample = roadSample
v = newVehicle(30, 0)
v.speed = 30
run(v, 800)
local borderAssist = assistOf(v)
local lastBorderPoint = borderAssist.result.points[#borderAssist.result.points]
check("a road running off the map: the line is cut at the border (4 m inside), and marked as ending", borderAssist.result.ends == true and lastBorderPoint[1] <= 46 and lastBorderPoint[1] > 40)
check("... so the speed asked for brings the vehicle to a stop before the border", driveCalls[#driveCalls].maxSpeed < 30)
g_currentMission.terrainSize = nil
v = newVehicle(30, 0)
v.speed = 30
run(v, 800)
check("(no map size known: nothing is cut)", assistOf(v).result.ends ~= true)

-- ===== forest-floor paint is not a track (optional) =====
local tracerStub = g_currentMission.wailaTrailTracer
tracerStub.LAYER_CLASS_FOREST = 2
tracerStub.layerClassLearned = true
local paintOfCell = function() return nil end
tracerStub.getLayerClassAt = function(x, z) return paintOfCell(x, z) end
currentSample = function(x, z) return math.abs((math.floor(z / 2) + 0.5) * 2) <= 3 and 1 or 0 end        -- a 8 m trail (class 1)
paintOfCell = function() return 2 end                                                                      -- all of it painted as forest floor
RoadFollow.IGNORE_FOREST_FLOOR = false
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
check("flag off: a trail painted as forest floor is followed as the picture says", assistOf(v).engaged == true)
RoadFollow.IGNORE_FOREST_FLOOR = true
RoadFollow.clearForestFloorCache()
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
check("flag on: trail pixels with the forest-floor paint are not a track (nothing to follow)", assistOf(v).engaged == false)
paintOfCell = function(x, z) return nil end
RoadFollow.clearForestFloorCache()
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
check("flag on, the trail painted with something else: followed", assistOf(v).engaged == true)
-- only the pixels on one side carry the forest paint: the rest is still a track, and the line keeps to it
paintOfCell = function(x, z) return z > 1.5 and 2 or nil end
RoadFollow.clearForestFloorCache()
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
check("flag on, a forest-floor strip along one edge: the track is what is left, and it is still followed", assistOf(v).engaged == true)
RoadFollow.IGNORE_FOREST_FLOOR = false
tracerStub.getLayerClassAt, tracerStub.LAYER_CLASS_FOREST, tracerStub.layerClassLearned = nil, nil, nil
currentSample = roadSample

-- ===== open ground that the map calls road: straight on, for a while =====
currentSample = function(x, z) return (x < 40) and (math.abs((math.floor(z / 2) + 0.5) * 2) <= 3 and 2 or 0) or 2 end     -- a road, then a wide gravel area (class 2 all round)
v = newVehicle(0, 0)
v.speed = 30
run(v, 800)
check("(engaged on the road before the open ground)", assistOf(v).engaged == true)
v.pos = { 50, 0 }
run(v, 3000)
check("in open ground that the map calls road: still engaged, holding straight on (not 'no road ahead')", assistOf(v).engaged == true and assistOf(v).result.holding == true and assistOf(v).sup.stopping == false)
check("... slowly (at most 20 km/h asked) and the aim is straight ahead", driveCalls[#driveCalls].maxSpeed <= 20.01 and math.abs(driveCalls[#driveCalls].pX) < 0.5)
run(v, 12000)
check("after 70 m of it (the limit) the road is considered lost: a stop (or hand-back), not endless driving on", assistOf(v).sup.stopping == true or assistOf(v).engaged == false)
currentSample = roadSample

-- ===== the black box =====
WailaConfig = { isDebugLog = function() return true end }
currentSample = roadSample
v = newVehicle(0, 0)
run(v, 1500)
check("the black box records while the assist drives (about one entry per 100 ms)", #assistOf(v).blackbox >= 10)
local boxLines = {}
local savedPrint = print
print = function(text) boxLines[#boxLines + 1] = tostring(text) end
run(v, 50, { 0.5, 0 })
print = savedPrint
local boxText = table.concat(boxLines, "\n")
check("the player taking over (pedal) writes it to the log, with debug logging on", boxText:find("blackbox (pedal)", 1, true) ~= nil and boxText:find("] bb ", 1, true) ~= nil)
check("... and it is emptied afterwards", assistOf(v).blackbox == nil)
WailaConfig = { isDebugLog = function() return false end }
v = newVehicle(0, 0)
run(v, 1500)
boxLines = {}
print = function(text) boxLines[#boxLines + 1] = tostring(text) end
run(v, 50, { 0.5, 0 })
print = savedPrint
check("with debug logging off nothing but the one 'assist off' line is written", table.concat(boxLines, "\n"):find("blackbox", 1, true) == nil)
WailaConfig = nil

-- roadFollowDump: a picture of the map and the line, for rebuilding a situation offline
currentSample = roadSample
v = newVehicle(0, 0)
current = v
g_localPlayer = { getCurrentVehicle = function() return v end }
local printed = {}
local realPrint = print
print = function(text) printed[#printed + 1] = tostring(text) end
local answer = RoadFollow.consoleDump()
print = realPrint
g_localPlayer = nil
local rows, vRow, vCol = {}, nil, nil
for _, line in ipairs(printed) do
    local picture = line:match("dump| (.*)$")
    if picture ~= nil then
        rows[#rows + 1] = picture
        local col = picture:find("V", 1, true)
        if col ~= nil then vRow, vCol = #rows, col end
    end
end
check("dump: reports success and a 37 x 37 picture", type(answer) == "string" and #rows == 37 and #rows[1] == 37)
check("dump: the vehicle is in the middle", vRow == 19 and vCol == 19)
check("dump: the road (z within 3 m, 2 m pixels) is drawn as # on and next to the vehicle's row", rows[19]:find("#", 1, true) ~= nil and rows[1]:find("#", 1, true) == nil)
check("dump: the line the assist would drive is drawn east of the vehicle", rows[vRow]:sub(vCol + 1):find("*", 1, true) ~= nil)
check("dump: the header gives position, heading, and mode", (function()
    local text = table.concat(printed, "\n")
    return text:find("pos 0.0 0.0", 1, true) ~= nil and text:find("mode auto", 1, true) ~= nil
end)())


-- taps while the assist is NOT driving still work the turn lights
do
    local lv = newVehicle(0, 0)
    local la = assistOf(lv)
    lv.speed = 0
    currentSample = function() return 0 end            -- no road: the assist cannot engage
    run(lv, 400)
    lv.turnState = Lights.TURNLIGHT_OFF
    lv.getTurnLightState = function(self) return self.turnState end
    run(lv, 80, { 0, -0.6 })
    run(lv, 48, { 0, 0 })
    check("assist not driving, cruise on: a tap on the left key sets the left light", la.engaged == false and lv.turnState == Lights.TURNLIGHT_LEFT)
    run(lv, 80, { 0, 0.6 })
    run(lv, 48, { 0, 0 })
    check("... a tap on the other key switches to the right light", lv.turnState == Lights.TURNLIGHT_RIGHT)
    run(lv, 80, { 0, 0.6 })
    run(lv, 48, { 0, 0 })
    check("... the same key again puts it out", lv.turnState == Lights.TURNLIGHT_OFF)
    lv.spec_drivable.cruiseControl.state = 0
    run(lv, 80, { 0, 0.6 })
    run(lv, 48, { 0, 0 })
    check("cruise control off and no light on: steering keys are only steering, no light", lv.turnState == Lights.TURNLIGHT_OFF)
    lv.turnState = Lights.TURNLIGHT_RIGHT
    run(lv, 80, { 0, 0.6 })
    run(lv, 48, { 0, 0 })
    check("a light that is on goes out with a tap on its side even with cruise control off", lv.turnState == Lights.TURNLIGHT_OFF)
    lv.spec_drivable.cruiseControl.state = 1
    run(lv, 900, { 0, 0.6 })
    run(lv, 100, { 0, 0 })
    check("a long press is steering, not a light tap", lv.turnState == Lights.TURNLIGHT_OFF)
    currentSample = roadSample
end


-- ===== a wide gravel track: the middle may be a few metres off, the vehicle is still on the road =====
do
    currentSample = function(x, z) return math.abs((math.floor(z / 2) + 0.5) * 2) <= 4 and 2 or 0 end        -- 8 m wide
    local wv = newVehicle(0, 0.5)
    wv.speed = 40
    run(wv, 800)
    local wa = assistOf(wv)
    check("an 8 m wide track, near its middle: engaged", wa.engaged == true)
    wv.pos = { 40, 3.3 }
    run(wv, 1500)
    check("... the vehicle 3.3 m off the middle but plainly on the road: still engaged, not a lost road", wa.engaged == true and wa.status == nil and wa.sup.stopping == false)
    check("... and it steers back towards the middle (the aim point is on the side of the middle)", driveCalls[#driveCalls] ~= nil)
    currentSample = roadSample
end


-- ===== field mode: open ground, cruise control on: a course round the trees, the direction already going =====
do
    local savedSample, savedTreeFn, savedTreeData = currentSample, treeFn, treeData
    currentSample = function() return 0 end                          -- no road, no trail anywhere
    g_currentMission.terrainDetailId = 1
    getDensityAtWorldPos = function() return 1 end                   -- farmland
    local fv = newVehicle(0, 0)
    fv.speed = 15
    fv.spec_drivable.cruiseControl.speed = 20
    treeData = true
    treeFn = function() return false end
    run(fv, 1200)
    local fa = assistOf(fv)
    check("cruise control on, a field with no road: the assist takes it (field course), straight on", fa.engaged == true and fa.result ~= nil and fa.result.mode == "field")
    check("... the label says so", fa.modeLabel == "field: round obstacles")
    check("... the line runs along the way the vehicle goes (x ahead, z about 0)", #fa.result.points > 10 and math.abs(fa.result.points[#fa.result.points][2]) < 0.5 and fa.result.points[#fa.result.points][1] > 30)
    -- a tree 30 m ahead on the line (1.5 m trunk)
    fv = newVehicle(0, 0)
    fv.speed = 15
    fv.spec_drivable.cruiseControl.speed = 20
    treeFn = function(x, z) return (x - 30) ^ 2 + z ^ 2 <= 2.5 * 2.5 end
    run(fv, 1200)
    fa = assistOf(fv)
    local nearest = math.huge
    for _, p in ipairs(fa.result.points) do nearest = math.min(nearest, math.sqrt((p[1] - 30) ^ 2 + p[2] ^ 2)) end
    check("a tree 30 m ahead: the course goes round it (never within 3.5 m of its middle)", fa.engaged == true and fa.result.mode == "field" and nearest >= 3.5)
    check("... and it is not stopped for it (room to go round)", fa.sup.stopping == false)
    -- the same field with the mode switched off: plain cruise control, the assist stays out
    RoadFollow.FIELD_MODE = false
    fv = newVehicle(0, 0)
    fv.speed = 15
    fv.spec_drivable.cruiseControl.speed = 20
    run(fv, 1200)
    check("field mode switched off: no field course", assistOf(fv).engaged == false)
    RoadFollow.FIELD_MODE = true
    -- not on a field (a meadow): no field course
    getDensityAtWorldPos = function() return 0 end
    fv = newVehicle(0, 0)
    fv.speed = 15
    fv.spec_drivable.cruiseControl.speed = 20
    run(fv, 1200)
    check("not farmland: no field course", assistOf(fv).engaged == false)
    -- cruise control off: nothing
    getDensityAtWorldPos = function() return 1 end
    fv = newVehicle(0, 0)
    fv.speed = 15
    fv.spec_drivable.cruiseControl.state = 0
    run(fv, 1200)
    check("cruise control off: nothing is steered", assistOf(fv).engaged == false)
    -- the game's steering assist has lanes ready here (state AVAILABLE): no field course in front of it
    AIAutomaticSteering = { STATE = { DISABLED = 0, AVAILABLE = 1, ACTIVE = 2 } }
    fv = newVehicle(0, 0)
    fv.speed = 15
    fv.spec_drivable.cruiseControl.speed = 20
    fv.getAIAutomaticSteeringState = function() return AIAutomaticSteering.STATE.AVAILABLE end
    run(fv, 1200)
    check("the game's steering assist available on this field: no field course", assistOf(fv).engaged == false)
    fv.getAIAutomaticSteeringState = function() return AIAutomaticSteering.STATE.DISABLED end
    run(fv, 1200)
    check("... and with it disabled (nothing attached, no lanes) the field course is back", assistOf(fv).engaged == true and assistOf(fv).result.mode == "field")
    AIAutomaticSteering = nil
    -- a road under the vehicle: the road scan is what counts, not the field
    currentSample = savedSample
    fv = newVehicle(0, 0)
    fv.speed = 30
    run(fv, 1200)
    check("on a road the road is followed (not a field course)", assistOf(fv).result ~= nil and assistOf(fv).result.mode ~= "field")
    currentSample, treeFn, treeData = savedSample, savedTreeFn, savedTreeData
    getDensityAtWorldPos = nil
end


-- ===== a fast car and a bend far ahead: the plan slows in time =====
do
    local savedSample = currentSample
    -- a road along +x for 150 m, then a bend of radius 120 m (towards +z)
    local poly = { { -300, 0 }, { 150, 0 } }
    for i = 1, 40 do local a = math.rad(70) * i / 40; poly[#poly + 1] = { 150 + 120 * math.sin(a), 120 * (1 - math.cos(a)) } end
    poly[#poly + 1] = { poly[#poly][1] + 300 * math.cos(math.rad(70)), poly[#poly][2] + 300 * math.sin(math.rad(70)) }
    local function nearRoad(x, z)
        local best = math.huge
        for i = 1, #poly - 1 do
            local ax, az, bx, bz = poly[i][1], poly[i][2], poly[i + 1][1], poly[i + 1][2]
            local dx, dz = bx - ax, bz - az
            local t = math.max(0, math.min(1, ((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz)))
            best = math.min(best, math.sqrt((x - (ax + dx * t)) ^ 2 + (z - (az + dz * t)) ^ 2))
        end
        return best
    end
    currentSample = function(x, z) return nearRoad((math.floor(x / 2) + 0.5) * 2, (math.floor(z / 2) + 0.5) * 2) <= 3 and 2 or 0 end
    local function drive(topKmh, farLook)
        RoadFollow.FAR_LOOK = farLook
        local car = newVehicle(0, 0)
        car.speed = 130
        car.getSpeedLimit = function() return 250, true end
        car.spec_drivable.cruiseControl.speed = topKmh
        car.spec_drivable.cruiseControl.maxSpeed = topKmh
        run(car, 1500)
        RoadFollow.FAR_LOOK = true
        return car, driveCalls[#driveCalls] and driveCalls[#driveCalls].maxSpeed or 0
    end
    local car, askedFar = drive(180, true)
    local _, askedNear = drive(180, false)
    check(string.format("130 km/h, cruise 180, a bend 150 m ahead: with the far look the speed asked is already below the cruise (%.0f), without it nothing (%.0f)", askedFar, askedNear), askedFar < 160 and askedNear >= 170)
    check("... the far look is kept for the plan (and drawn)", assistOf(car).far ~= nil and #assistOf(car).far.points > 20)
    check("... the car is not stopped for it", assistOf(car).sup.stopping == false)
    -- what a vehicle can do, from its top speed
    local tractor = { spec_drivable = { cruiseControl = { maxSpeed = 53 } } }
    local sports = { spec_drivable = { cruiseControl = { maxSpeed = 180 } } }
    local tb, tl, th, ts = RoadFollow.vehicleLimits(tractor)
    local sb, sl, sh, ss = RoadFollow.vehicleLimits(sports)
    check("the tractor keeps the old numbers (1.5 braking, 2.0 bend, 3.5 hard)", math.abs(tb - 1.5) < 0.1 and math.abs(tl - 2.0) < 0.1 and math.abs(th - 3.5) < 0.1)
    check("the 180 km/h car brakes harder and holds a bend better, and its steering may ask for more", sb > tb + 1 and sl > tl + 1 and sh > th + 1 and ss > ts + 1)
    check("... within the caps", sb <= 3.5 + 1e-9 and sl <= 4.0 + 1e-9 and sh <= 5.5 + 1e-9)
    currentSample = savedSample
end


-- ===== the game's own steering assist (and an AI helper) win over this one =====
do
    local sv = newVehicle(0, 0)
    sv.speed = 30
    run(sv, 700)
    check("(a vehicle on a road: the assist engages)", assistOf(sv).engaged == true and #driveCalls > 0)
    sv.spec_aiAutomaticSteering = { steeringEnabled = true }
    run(sv, 300)
    check("the game's steering assist switches on: this assist lets go at once and the base physics run (it steers)", assistOf(sv).engaged == false and superCalls > 0 and #driveCalls == 0)
    run(sv, 700)
    check("... and stays out for as long as it is on", assistOf(sv).engaged == false and #driveCalls == 0)
    sv.spec_aiAutomaticSteering.steeringEnabled = false
    run(sv, 1200)
    check("the steering assist off again: this one takes over again", assistOf(sv).engaged == true and #driveCalls > 0)
    -- a lane selected with H (state AVAILABLE: the game's course is ready, it does not steer yet): this assist stays out of it as well, on any ground
    AIAutomaticSteering = { STATE = { DISABLED = 0, AVAILABLE = 1, ACTIVE = 2 } }
    local lane = newVehicle(0, 0)
    lane.speed = 30
    lane.spec_aiAutomaticSteering = { steeringEnabled = false }
    lane.getAIAutomaticSteeringState = function() return AIAutomaticSteering.STATE.AVAILABLE end
    run(lane, 1200)
    check("a steering assist lane selected (available, not steering yet): this assist does not engage, the base physics run", assistOf(lane).engaged == false and #driveCalls == 0 and superCalls > 0)
    lane.getAIAutomaticSteeringState = function() return AIAutomaticSteering.STATE.DISABLED end
    run(lane, 1200)
    check("the lane deselected (disabled): this assist works again", assistOf(lane).engaged == true and #driveCalls > 0)
    AIAutomaticSteering = nil
    local helper = newVehicle(0, 0)
    helper.speed = 30
    helper.getIsAIActive = function() return true end
    run(helper, 700)
    check("an AI helper driving: this assist does not engage", assistOf(helper).engaged == false and #driveCalls == 0 and superCalls > 0)
end

finish("road_assist_test")
