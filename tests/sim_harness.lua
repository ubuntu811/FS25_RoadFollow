-- A closed-loop simulation: a simple vehicle (bicycle model) driven by the real assist code over a stored-path road,
-- so that what the pieces do TOGETHER (line, aim point, curvature steering, speed, supervisor) can be seen, not only
-- one scan at a time.
dofile("tests/stubs.lua")
Logging = { info = function() end }
dofile("../FS25_whatAmILookingAt/scripts/WailaPathStore.lua")
g_currentModName = "FS25_RoadFollow"
Lights = { TURNLIGHT_OFF = 0, TURNLIGHT_LEFT = 1, TURNLIGHT_RIGHT = 2, TURNLIGHT_HAZARD = 3 }
addConsoleCommand = function() end
Drivable = { CRUISECONTROL_STATE_OFF = 0 }
getTerrainHeightAtWorldPos = function() return 100 end
g_terrainNode = 1
local haveBitmapData = false
local samplerFn = function() return 0 end
g_currentMission = {
    showBlinkingWarning = function() end,
    wailaPaths = WailaPathStore,
    wailaTrailTracer = { sampleDrivable = function(x, z) return samplerFn(x, z) end, hasDrivableData = function() return haveBitmapData end },
}
local last = { curvature = 0, maxSpeed = 0, allowed = true }
AIVehicleUtil = {
    driveToPoint = function(v, dt, acc, allowed, forwards, pX, pZ, maxSpeed)
        -- the base game's circle through the aim point (+ x = the (x, z) counter-clockwise side in this harness)
        local k = 2 * pX / math.max(pX * pX + pZ * pZ, 1e-6)
        last = { curvature = k, maxSpeed = maxSpeed, allowed = allowed }
    end,
    driveAlongCurvature = function(v, dt, curvature, maxSpeed, acc)
        v.rotatedTime = -curvature * 10              -- the helper's own sign: + argument = the other way round
        last = { curvature = -curvature, maxSpeed = maxSpeed, allowed = maxSpeed > 0 }
    end,
}
dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadSupervisor.lua")
dofile("scripts/RoadMeander.lua")
dofile("scripts/RoadHud.lua")
dofile("scripts/RoadFollow.lua")
dofile("scripts/RoadLead.lua")

local current
getWorldTranslation = function() return current.pos[1], 100, current.pos[2] end
localDirectionToWorld = function() return current.heading[1], 0, current.heading[2] end
worldToLocal = function(_, wx, _, wz)
    local dx, dz = wx - current.pos[1], wz - current.pos[2]
    local fx, fz = current.heading[1], current.heading[2]
    return dx * -fz + dz * fx, 0, dx * fx + dz * fz
end
local function superFunc() end
local function newVehicle(x, z, kmh)
    local v = { pos = { x, z }, heading = { 1, 0 }, speed = kmh, isServer = true, movingDirection = 1, rotatedTime = 0 }
    v["spec_FS25_RoadFollow.roadFollow"] = {
        isActive = false, actionEvents = {},
        assist = { engaged = false, goodScans = 0, badMs = 0, scanMs = 0, steerGraceMs = 0, result = nil, warned = false, broken = false, status = nil, modeLabel = nil, groundFactor = 1, sup = RoadSupervisor.new(), saturated = false, meander = RoadMeander.new(), intent = nil, intentMs = 0 },
    }
    v.spec_drivable = { cruiseControl = { state = 1, speed = 50 } }
    v.getAISteeringNode = function() return "s" end
    v.getAIDirectionNode = function() return "d" end
    v.getLastSpeed = function(self) return self.speed end
    v.getSpeedLimit = function() return 120, true end
    v.getCruiseControlMaxSpeed = function(self) return self.spec_drivable.cruiseControl.speed end
    v.getName = function() return "sim" end
    v.turnState = 0
    v.getTurnLightState = function(self) return self.turnState end
    v.setTurnLightState = function(self, state) self.turnState = state end
    v.setCruiseControlState = function(self, state) self.spec_drivable.cruiseControl.state = state end
    v.scanRoadAhead = RoadFollow.scanRoadAhead
    return v
end
local function assistOf(v) return v["spec_FS25_RoadFollow.roadFollow"].assist end

-- One tick of the vehicle: the assist asks (curvature, speed), the vehicle follows with a steering delay and limited
-- acceleration, and moves.
local function simulate(v, seconds, onStep, dynamics)
    current = v
    local dt = 16
    local steps = seconds * 1000 / dt
    -- dynamics (optional): { delay = seconds the command takes to reach the wheels, lag = time constant of the vehicle's own
    -- yaw response }: real vehicles are not instant
    dynamics = dynamics or {}
    local delayTicks = math.floor((dynamics.delay or 0) * 1000 / dt + 0.5)
    local queue = {}
    local steerLagged = 0
    local steer = 0                                -- the curvature the wheels really make (steering lag)
    for i = 1, steps do
        RoadFollow.updateVehiclePhysics(v, superFunc, 0, 0, false, dt)
        -- steering: moves towards what was asked at most 0.5 1/m per second, never beyond a 5.5 m turning radius
        local want = math.max(-1 / 5.5, math.min(1 / 5.5, last.curvature))
        queue[#queue + 1] = want
        if #queue > delayTicks + 1 then table.remove(queue, 1) end
        want = queue[1]
        local rate = 0.5 * dt / 1000
        steer = steer + math.max(-rate, math.min(rate, want - steer))
        if (dynamics.lag or 0) > 0 then
            steerLagged = steerLagged + (steer - steerLagged) * (1 - math.exp(-dt / 1000 / dynamics.lag))
        else
            steerLagged = steer
        end
        -- speed: accelerates at 2.5 m/s^2, brakes at 5 m/s^2 towards the speed asked
        local target = (last.allowed and last.maxSpeed or 0) / 3.6
        local speedMs = v.speed / 3.6
        if target > speedMs then speedMs = math.min(target, speedMs + 2.5 * dt / 1000) else speedMs = math.max(target, speedMs - 5 * dt / 1000) end
        v.speed = speedMs * 3.6
        -- understeer (optional, dynamics.understeer = u): the vehicle makes 1 / (1 + u v^2) of the curvature the wheels ask for
        local made = steerLagged / (1 + (dynamics.understeer or 0) * speedMs * speedMs)
        local theta = math.atan2(v.heading[2], v.heading[1]) + made * speedMs * dt / 1000      -- + = towards +z
        v.heading = { math.cos(theta), math.sin(theta) }
        v.pos[1] = v.pos[1] + v.heading[1] * speedMs * dt / 1000
        v.pos[2] = v.pos[2] + v.heading[2] * speedMs * dt / 1000
        if onStep ~= nil and onStep(v, i * dt / 1000) == false then break end
    end
end

return { newVehicle = newVehicle, simulate = simulate, assistOf = assistOf, store = WailaPathStore,
    setBitmap = function(on) haveBitmapData = on end, setSampler = function(fn) samplerFn = fn end }
