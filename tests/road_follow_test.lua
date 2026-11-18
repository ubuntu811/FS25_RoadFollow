dofile("tests/stubs.lua")

-- engine stubs for the specialization's drive loop
g_currentModName = "FS25_RoadFollow"
addConsoleCommand = function() end
AIVehicleUtil = { driveToPoint = function(vehicle, dt, acceleration, allowed, forwards, pX, pZ, maxSpeed)
    vehicle.lastDrive = { acceleration = acceleration, allowed = allowed, forwards = forwards, pX = pX, pZ = pZ, maxSpeed = maxSpeed }
end }
AIMessageErrorRoadEnded = { new = function() return { kind = "roadEnded" } end }
AIMessageErrorBlockedByObject = { new = function() return { kind = "blocked" } end }
getTerrainHeightAtWorldPos = function() return 100 end
g_terrainNode = 1

-- a road along x, 6 m wide, as 2 m pixels
local function sample(x, z)
    local cz = (math.floor(z / 2) + 0.5) * 2
    return math.abs(cz) <= 3 and 2 or 0
end
g_currentMission = { wailaTrailTracer = { sampleDrivable = sample, hasDrivableData = function() return true end } }

dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadSupervisor.lua")
dofile("scripts/RoadMeander.lua")
dofile("scripts/RoadFollow.lua")

-- a vehicle: position (x, z), heading (hx, hz); node transforms with GIANTS' convention (+z forward, +x left)
local function newVehicle(x, z, hx, hz)
    local v = { pos = { x, z }, heading = { hx, hz }, speed = 10, cruiseMax = 30, limit = 50, stops = {} }
    v["spec_FS25_RoadFollow.roadFollow"] = { isActive = true, scanTimer = 0, lostMs = 0, didNotMoveMs = 0, actionEvents = {} }
    v.getAISteeringNode = function() return "steer" end
    v.getAIDirectionNode = function() return "dir" end
    v.getLastSpeed = function(self) return self.speed end
    v.getSpeedLimit = function(self) return self.limit, true end
    v.getCruiseControlMaxSpeed = function(self) return self.cruiseMax end
    v.stopCurrentAIJob = function(self, message) self.stops[#self.stops + 1] = message end
    v.isServer = true
    -- what SpecializationUtil.registerFunction does in the engine
    for _, name in ipairs({ "startRoadFollow", "stopRoadFollow", "getIsRoadFollowActive", "getCanStartRoadFollow", "scanRoadAhead", "updateRoadFollowDrive" }) do
        v[name] = RoadFollow[name]
    end
    v.getIsAIActive = function() return false end
    return v
end
local current
getWorldTranslation = function() return current.pos[1], 100, current.pos[2] end
localDirectionToWorld = function() return current.heading[1], 0, current.heading[2] end
worldToLocal = function(_, wx, _, wz)
    local dx, dz = wx - current.pos[1], wz - current.pos[2]
    local fx, fz = current.heading[1], current.heading[2]
    local lx, lz = -fz, fx            -- left of the heading, in the world's x/z
    return dx * lx + dz * lz, 0, dx * fx + dz * fz
end
local function drive(vehicle, ms)
    current = vehicle
    for _ = 1, ms / 16 do
        RoadFollow.updateRoadFollowDrive(vehicle, 16)
    end
end

-- on the middle of the road, heading along it
local v = newVehicle(0, 0, 1, 0)
drive(v, 200)
check("on the middle: steering is called, forwards, allowed", v.lastDrive ~= nil and v.lastDrive.forwards == true and v.lastDrive.allowed == true)
check("on the middle: the target is ahead and not to a side", v.lastDrive.pZ > 5 and math.abs(v.lastDrive.pX) < 1.0)
check("the speed is capped by the cruise setting (30 km/h) at most", v.lastDrive.maxSpeed <= 30 and v.lastDrive.maxSpeed > 3)

-- 3 m off to the left: the target pulls back towards the road middle (to the right side of the vehicle)
v = newVehicle(0, 2.5, 1, 0)
drive(v, 200)
check("beside the middle: the target is on the road's middle side", v.lastDrive.pX ~= 0 and (v.lastDrive.pX < 0) == true)
local px = v.lastDrive.pX
v = newVehicle(0, -2.5, 1, 0)
drive(v, 200)
check("on the other side: the opposite sign", v.lastDrive.pX > 0 and math.abs(v.lastDrive.pX + px) < 1.5)

-- the cruise setting limits the speed
v = newVehicle(0, 0, 1, 0)
v.cruiseMax = 12
drive(v, 200)
check("cruise setting 12 km/h: the vehicle is told 12 km/h at most", v.lastDrive.maxSpeed <= 12.01)
v.limit = 8
drive(v, 100)
check("a lower speed limit wins", v.lastDrive.maxSpeed <= 8.01)

-- the road ends: speed drops, then the AI job is stopped when nothing is left
local function endingSample(x, z) return x <= 20 and sample(x, z) or 0 end
g_currentMission.wailaTrailTracer.sampleDrivable = endingSample
v = newVehicle(10, 0, 1, 0)
drive(v, 100)
local before = v.lastDrive.maxSpeed
v.pos = { 17, 0 }
v.heading = { 1, 0 }
drive(v, 100)
check("the road ends ahead: the speed advice drops as the end gets close", v.lastDrive.maxSpeed < before)

-- driven off the road: it rolls on slowly, then stops with "road ended"
g_currentMission.wailaTrailTracer.sampleDrivable = sample
v = newVehicle(0, 40, 1, 0)
drive(v, 1500)
check("off the road for 1.5 s: still rolling, slowly, nothing stopped yet", #v.stops == 0 and v.lastDrive ~= nil and v.lastDrive.maxSpeed <= RoadFollow.LOST_ROAD_SPEED_KMH + 0.01)
drive(v, 1500)
check("off the road for 3 s: the job is stopped with the road-ended message", #v.stops >= 1 and v.stops[1].kind == "roadEnded")

-- standing still while it should be moving: blocked after the timeout
v = newVehicle(0, 0, 1, 0)
v.speed = 0
drive(v, RoadFollow.DID_NOT_MOVE_STOP_MS + 500)
check("not moving for the timeout: stopped as blocked", #v.stops >= 1 and v.stops[1].kind == "blocked")

-- start conditions
v = newVehicle(0, 0, 1, 0)
v["spec_FS25_RoadFollow.roadFollow"].isActive = false
current = v
local ok, reason = RoadFollow.getCanStartRoadFollow(v)
check("on a road, pointing along it: can start", ok == true)
v.heading = { 0, 1 }  -- across the road
ok, reason = RoadFollow.getCanStartRoadFollow(v)
check("pointing across the road: cannot start, 'not on a road'", ok == false and reason == "ROADFOLLOW_NOT_ON_ROAD")
v.pos, v.heading = { 0, 40 }, { 1, 0 }
ok, reason = RoadFollow.getCanStartRoadFollow(v)
check("far from any road: cannot start", ok == false and reason == "ROADFOLLOW_NOT_ON_ROAD")
g_currentMission.wailaTrailTracer.hasDrivableData = function() return false end
ok, reason = RoadFollow.getCanStartRoadFollow(v)
check("no map data yet: cannot start, 'scan first'", ok == false and reason == "ROADFOLLOW_NEED_SCAN")
finish("road_follow_test")
