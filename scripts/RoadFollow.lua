--[[
    RoadFollow.lua  (vehicle specialization)

    Press the key in a vehicle on a road or track and it steers along that road. The base game's AI
    job system runs it (like FollowMe does): an AI job marks the vehicle as driven by a helper, this
    specialization supplies the point to steer at and the speed, and AIVehicleUtil.driveToPoint does
    the steering and throttle.

    The road comes from the WAILA map scan: g_currentMission.wailaTrailTracer.sampleDrivable(x, z)
    answers 0 / 1 (trail) / 2 (road) from the layer bitmaps. RoadCenterline turns that into the
    centre-line ahead. Speed is the lowest of: the vehicle's cruise control setting, the speed limit,
    what the bend / junction / end of road allows, and what the collision strategy allows.
]]

RoadFollow = {}

local groundUnder          -- defined further down (the map's say on what is under and ahead of the vehicle)

RoadFollow.CHECK_INTERVAL_MS = 50          -- how often the road ahead is re-read
RoadFollow.LOOKAHEAD_MIN = 8               -- m (longer = calmer; a long trailer weaves with a short one)
RoadFollow.LOOKAHEAD_SECONDS = 2.0
RoadFollow.ROW_SCALE_MAX = 1.0             -- rows are this many times further apart at speed (1 = the old fine rows)
RoadFollow.REACH_SECONDS = 3.0             -- the road is read this far ahead (in time) ...  (longer reaches made the pixel march lose gentle curves in the simulation)
RoadFollow.REACH_MIN = 24                  -- ... but at least this many metres
RoadFollow.REACH_MAX = 45                  -- ... and at most this many
RoadFollow.FREEZE_TURN_DEG = 45             -- a signalled turn of at least this many degrees is worked out once and then driven as it was found
RoadFollow.FREEZE_COMPLETE = 0.8           -- ... and only once the line has turned this share of the corner by its end (the whole turn is in it)
RoadFollow.FREEZE_MAX_OFFSET = 3.0         -- ... if the vehicle is on its line (within this many metres) when it is found
RoadFollow.FAR_LOOK = true                 -- at speed on a map-picture road: the road is also followed a long way ahead, for the speed plan only (the full scan is too short at 100+ km/h)
RoadFollow.FAR_LOOK_MIN_KMH = 70
RoadFollow.FAR_LOOK_SECONDS = 6.0          -- how many seconds of driving the far look covers ...
RoadFollow.FAR_LOOK_MAX = 260              -- ... at most this many metres
RoadFollow.FAR_LOOK_STEP = 4.0             -- metres between the points it follows the road by
RoadFollow.FAR_LOOK_MS = 400               -- worked out this often
RoadFollow.FAR_LOOK_WINDOW = 40            -- metres of road one curvature reading of the far look covers (long: the bends that matter at speed are gentle)
RoadFollow.FAR_LOOK_FROM = 25              -- metres: its bends count from here on (the full scan reads the stretch before it)
RoadFollow.PLAN_BRAKE_MIN = 1.5            -- m/s^2 the speed plan counts on for braking: a slow loaded tractor ...
RoadFollow.PLAN_BRAKE_MAX = 3.5            -- ... up to a fast car; from the vehicle's top speed, 0.015 m/s^2 per km/h above 50
RoadFollow.PLAN_BRAKE_PER_KMH = 0.015
RoadFollow.PLAN_LATERAL_PER_KMH = 0.012    -- the sideways acceleration taken in a bend (2.0 for a tractor) and the most it may ever be (3.5) grow like this per km/h of top speed above 50:
RoadFollow.PLAN_LATERAL_MAX = 4.0          -- a car that tops out at 180 km/h has grip a tractor on dirt does not (the measured numbers will replace these guesses)
RoadFollow.PLAN_HARD_MAX = 5.5
RoadFollow.FIELD_MODE = true               -- cruise control on a field (no road at all): steer a course through it, round trees and buildings, in the direction already going
RoadFollow.FIELD_ONLY_ON_FIELDS = true     -- ... only where the ground is farmland (not on meadows, tracks, in forests)
RoadFollow.FIELD_LOOK = 50                 -- metres looked ahead for obstacles (the layers are static, so this costs reads, not speed)
RoadFollow.FIELD_PLAN_MS = 300             -- the course is worked out this often (between, the kept course is trimmed to the vehicle)
RoadFollow.FIELD_SLOPE_MAX = 0.35          -- steeper ground than this (rise over run, about 19 degrees) is an obstacle: a bank, a ditch
RoadFollow.JOIN_MAX_DEG = 15               -- a path is joined from open ground only when it runs within this many degrees of the way the vehicle goes
RoadFollow.TRUSTED_REACH = 45               -- road lost beyond this far ahead is "not seen yet", not "the road ends" (far bends are hard to follow)
RoadFollow.AIM_SPREAD = 4                  -- the aim is averaged over this many metres before and after the aim distance
RoadFollow.TARGET_TIME_CONSTANT_MS = 250   -- the steering target is low-pass filtered over about this long
RoadFollow.LOST_ROAD_STOP_MS = 2500        -- no road ahead for this long: stop
RoadFollow.LOST_ROAD_SPEED_KMH = 5
RoadFollow.DID_NOT_MOVE_STOP_MS = 10000
RoadFollow.MIN_SPEED_KMH = 3

RoadFollow.debugDraw = false
RoadFollow.debugSecondsLeft = 0      -- scan lines shown for this many more seconds (started from the WAILA hub), counted while no menu is open

-- Assisted cruise control (key 3, the base game's own cruise control): while it is on and there is a
-- road ahead, steer along the road; any steering, pedal or handbrake input hands control back.
RoadFollow.assistEnabled = true
RoadFollow.AUTOPILOT = true                -- never drive on silently: stop when the road is lost at speed, brake for the end of a road
RoadFollow.AUTOPILOT_MEMORY_MS = 8000     -- ... but a vehicle that was this recently at that speed still counts as driving on a road (the assist's own end-of-road braking must not make it "slow")
RoadFollow.AUTOPILOT_MIN_KMH = 15          -- below this a lost road is just a field: hand back to plain cruise control
RoadFollow.STEER_LATERAL_ACCEL = 4.5       -- m/s^2: the sideways acceleration the aim point may ask of the steering
RoadFollow.JUNCTION_STOP_MARGIN = 6          -- metres before the junction's mouth that the FRONT of the vehicle waits (a T: no signal = stop here)
RoadFollow.DEFAULT_FRONT_OVERHANG = 3        -- metres from the steering node to the front of the vehicle, when its size is not known
RoadFollow.JUNCTION_TURN_KMH = 15           -- speed through a turn at a junction
RoadFollow.JUNCTION_HOLD_MS = 3000          -- waiting at a junction or turning in one is not "too slow" for this long after it was last seen
RoadFollow.BLACKBOX_MS = 100               -- the last seconds of driving are kept, one entry this often ...
RoadFollow.BLACKBOX_KEEP = 80              -- ... this many (8 s); written to the log when the assist stops the vehicle or the player has to take over
RoadFollow.MAP_BORDER_MARGIN = 4           -- a line is cut this far inside the map border (the world edge is a wall; roads and splines run right off it)
RoadFollow.STUCK_ASK_KMH = 5               -- standing still while this much speed is asked for counts as stuck
RoadFollow.USE_FINE_EDGES = true           -- the real edges of a track from the terrain at 0.5 m, inside what the map picture found (the picture's edges are ragged and a metre or two too wide)
RoadFollow.USE_ROAD_CORE = true            -- in a wide stretch of road (gravel shoulders the map calls road too), the road paint's own stretch (the stone) is the road
RoadFollow.OPEN_HOLD = true                -- wide open ground (a gravel apron, a yard) that the map still calls road: keep going straight on instead of losing the road
RoadFollow.OPEN_HOLD_KMH = 20              -- ... at most this fast
RoadFollow.OPEN_HOLD_MAX_M = 70            -- ... and for at most this far, then it is a lost road like any other
RoadFollow.JOIN_KEEP_MIN_KMH = 4           -- a join under way is kept up to this low a speed
RoadFollow.CAPTURE_MIN_KMH = 30            -- joining a road from the side is looked for at this speed and above
RoadFollow.CAPTURE_SECONDS = 3.0           -- ... as far ahead as this many seconds of travel (8 to 60 m)
RoadFollow.BLEND_MIN = 25                  -- the join eases onto the road over 3 s of travel, 25 to 60 m
RoadFollow.BLEND_MAX = 60
RoadFollow.WHEEL_STEP_KMH = 5              -- the mouse wheel changes the cruise speed by this much per notch while the assist drives (0 = off)
RoadFollow.MOUSE_SIGNALS = true             -- left / right mouse button = turn signal while the assist drives
RoadFollow.INTENT_TIMEOUT_MS = 30000       -- a signal that was never used is dropped after this long
RoadFollow.INTENT_DONE_DEG = 50            -- a turn is done when the heading has changed this much towards the signal
RoadFollow.DETECT_VEHICLES = true          -- rays along the line for traffic and other vehicles ahead (RoadLead.lua); the base game's handler does not see traffic cars
RoadFollow.LEAD_INTERVAL_MS = 100
RoadFollow.DEBUG_OPTION_REACH = 70          -- metres: the debug view reads each way at a junction at least this far out (and 6 s of driving)
RoadFollow.DEBUG_OPTION_MIN_DEG = 35       -- a turn of less than this is not a way at a junction
RoadFollow.DEBUG_OPTION_SCRIBBLE_DEG = 120    -- a line that turns back and forth by this much more than its net turn is a scribble of the map picture
RoadFollow.DEBUG_OPTION_SAME_M = 2.5         -- a way that stays this close to the road's own line is not a way of its own
RoadFollow.DEBUG_OPTION_KEEP_MS = 1000     -- a way that one read misses stays drawn this long
RoadFollow.GIVE_WAY = true                 -- before a junction's turn, look along the cross road for traffic coming and wait for it (RoadLead cross traffic)
RoadFollow.CROSS_ACTIVE_RANGE = 45         -- metres: the cross road is only watched when the junction is this near
RoadFollow.PATH_REACH_SECONDS = 5           -- a stored path is read this many seconds ahead (cheap: no map pixels), so fast bends and traffic are seen in time
RoadFollow.TURN_EXTRA_REACH = 40            -- metres more of a stored path are read while a turn is signalled
RoadFollow.PATH_REACH_MAX = 160
RoadFollow.IGNORE_FOREST_FLOOR = false      -- trail pixels whose paint layer is the learned forest floor are not tracks (console: roadFollowForestFloor); off until checked on the real tracks, a worn path can carry that paint too
RoadFollow.FEEDFORWARD_STEERING = true     -- steer by what the line itself needs a moment ahead (RoadCenterline.steerCurvature) instead of chasing an aim point; console: roadFollowFeedForward
RoadFollow.FF_LOCAL_POINTS = 40            -- how many points of the line are looked at
RoadFollow.WEAVE_SOFTEN = 2.0              -- the correction distance grows by this times the weave severity (0 to 1) while the vehicle weaves
RoadFollow.CURVATURE_STEERING = true       -- steer with AIVehicleUtil.driveAlongCurvature (the wheels go straight to the curvature asked for) instead of driveToPoint (which limits the steering speed and slows the vehicle down to a crawl while the wheel catches up: stop and go in tight turns)
RoadFollow.UNDERSTEER_LEARN = true         -- learn how much a vehicle understeers at speed (yaw rate made / asked) and ask for more curvature to make up for it
RoadFollow.UNDERSTEER_RATE = 0.3           -- how fast the learned value follows (per second, of the relative shortfall)
RoadFollow.UNDERSTEER_MAX_GAIN = 2.0       -- the curvature asked for is never more than this times the line's
RoadFollow.UNDERSTEER_MIN_SPEED = 6.0      -- m/s: below this nothing is learned (slip is small, the heading is noisy)
RoadFollow.UNDERSTEER_MIN_KAPPA = 0.005    -- 1/m: on a straight there is nothing to measure
RoadFollow.CURVATURE_RATE = 0.35           -- most the curvature asked for may change per second (1/m per s): about 0 to a 10 m radius in 0.3 s
RoadFollow.LOOKAHEAD_TIGHT_MIN = 4.5       -- shortest aim distance in a tight bend (metres)
RoadFollow.LOOKAHEAD_CURVE_FACTOR = 0.5    -- in a bend the aim distance is at most this times the bend's radius
RoadFollow.USE_COLLISION_HANDLER = true    -- the game's own collision check (vehicles, objects ahead) slows / holds the assist, as it does for AI workers
RoadFollow.usePaths = true                 -- stored paths (map splines, recorded drives) before auto-detect
RoadFollow.laneOffset = 0                  -- metres to the right of a path's line to drive (0 = on it)
RoadFollow.groundFactors = { road = 1.0, trail = 0.85 }   -- share of the cruise speed per ground class
RoadFollow.GROUND_LOOKAHEAD = 25           -- metres of the line the ground is judged over
RoadFollow.OFFROAD_KMH = 20                -- most this asks for on grass, fields and bare soil (map data present, not a map spline)
RoadFollow.ASSIST_MIN_POINTS = 6           -- at least this many scans of road ahead (about 15 m)
RoadFollow.ASSIST_ENGAGE_SCANS = 3         -- ... on this many scans in a row
RoadFollow.ASSIST_HOLD_MS = 500            -- road lost for this long: hand back to plain cruise control
RoadFollow.ASSIST_STEER_GRACE_MS = 1500    -- after the player steers, leave it to them for this long
RoadFollow.ASSIST_STEER_DEADZONE = 0.08
RoadFollow.TAP_HOLD_MS = 600               -- a steering key held longer than this takes over; released sooner it is a tap = turn signal
RoadFollow.STEER_LEFT_SIGN = -1            -- sign of the steering axis for "left" (confirmed live: the left key is the negative axis) (console: roadFollowTapFlip, if a left tap signals right)
RoadFollow.TAP_INSTANT = true              -- with the assist driving, the signal is set the moment the key goes down (the line shows at once), and undone if the press turns out to be a hold
RoadFollow.TAP_SIGNALS = true              -- a tap on the steering keys sets the turn signal
RoadFollow.ASSIST_PEDAL_DEADZONE = 0.1
RoadFollow.ASSIST_MIN_SPEED_KMH = 5        -- to engage
RoadFollow.ASSIST_STAY_SPEED_KMH = 1       -- once engaged it stays on down to this (a slow bend must not switch it off)
RoadFollow.ASSIST_BEND_FLOOR = 0.75        -- a bend never asks for less than this share of the cruise speed
RoadFollow.LOG_INTERVAL_MS = 500
RoadFollow.ASSIST_MAX_OFFSET_ON_ROAD = 7.0  -- ... but on a wide road or trail (the map says the vehicle is on it) the middle may be this far: steer back to it, it is not a lost road
RoadFollow.ASSIST_MAX_OFFSET = 3.0         -- metres from the road's middle at the vehicle

local specName = "spec_" .. g_currentModName .. ".roadFollow"
local function getSpec(self)
    return self[specName]
end

local function log(formatString, ...)
    print(string.format("[RoadFollow] " .. formatString, ...))
end

function RoadFollow.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(AIJobVehicle, specializations)
       and SpecializationUtil.hasSpecialization(Drivable, specializations)
end

function RoadFollow.initSpecialization(vehicleType)
end

function RoadFollow.registerFunctions(vehicleType)
    for _, funcName in pairs({
        "startRoadFollow",
        "stopRoadFollow",
        "getIsRoadFollowActive",
        "getCanStartRoadFollow",
        "scanRoadAhead",
        "updateRoadFollowDrive",
    }) do
        SpecializationUtil.registerFunction(vehicleType, funcName, RoadFollow[funcName])
    end
end

function RoadFollow.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "updateVehiclePhysics", RoadFollow.updateVehiclePhysics)
end

function RoadFollow.registerEventListeners(vehicleType)
    for _, funcName in pairs({
        "onLoadFinished",
        "onDelete",
        "onUpdate",
        "onDraw",
        "onRegisterActionEvents",
    }) do
        SpecializationUtil.registerEventListener(vehicleType, funcName, RoadFollow)
    end
end

function RoadFollow:onLoadFinished(savegame)
    local spec = getSpec(self)
    spec.isActive = false
    spec.actionEvents = {}
    spec.collision = nil
    spec.scanTimer = 0
    spec.lostMs = 0
    spec.didNotMoveMs = 0
    spec.result = nil
    spec.target = nil
    spec.previewTimer = 0
    spec.previewResult = nil
    spec.assist = { engaged = false, goodScans = 0, badMs = 0, scanMs = 0, steerGraceMs = 0, result = nil, warned = false, broken = false, status = nil, modeLabel = nil, groundFactor = 1, sup = RoadSupervisor.new(), saturated = false, meander = RoadMeander.new(), intent = nil, intentMs = 0 }
end

function RoadFollow:onDelete()
    local spec = getSpec(self)
    if spec.collision ~= nil then
        spec.collision:delete()
        spec.collision = nil
    end
end

-- ===== road data =====

-- The vehicle the player is driving. FS25 has no g_currentMission.controlledVehicle any more (it is nil): the player
-- knows its vehicle.
function RoadFollow.getControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local vehicle = g_localPlayer:getCurrentVehicle()
        if vehicle ~= nil then
            return vehicle
        end
    end
    return g_currentMission ~= nil and g_currentMission.controlledVehicle or nil
end

function RoadFollow.wantRows()
    return RoadFollow.debugDraw or RoadFollow.debugSecondsLeft > 0
end

local function getTracer()
    return g_currentMission ~= nil and g_currentMission.wailaTrailTracer or nil
end

-- Is the paint under this point the learned forest-floor class? One terrain read per 2 m cell, remembered.
local forestFloorCache, forestFloorCount = {}, 0
local function isForestFloor(tracer, x, z)
    local key = math.floor(x / 2) * 100003 + math.floor(z / 2)
    local known = forestFloorCache[key]
    if known == nil then
        if forestFloorCount > 40000 then
            forestFloorCache, forestFloorCount = {}, 0
        end
        known = tracer.getLayerClassAt(x, z) == tracer.LAYER_CLASS_FOREST
        forestFloorCache[key] = known
        forestFloorCount = forestFloorCount + 1
    end
    return known
end

function RoadFollow.clearForestFloorCache()
    forestFloorCache, forestFloorCount = {}, 0
end

-- The road paint under a point (read from the terrain, remembered per 0.5 m cell): used to find the stone core of a wide
-- stretch of "road" that has gravel shoulders. nil when the map has no learned road paint.
-- The learned layer classes (which paint is road) exist only after a map scan has run this session; after loading saved
-- layer pictures there are none. Learn them once, when first needed (a few milliseconds: samples every 64 m).
local learnTried = false
local function ensureLearned(tracer)
    if tracer == nil or tracer.layerClassLearned or learnTried or tracer.learnLayerClasses == nil then
        return
    end
    learnTried = true
    local started = getTimeSec ~= nil and getTimeSec() or nil
    local ok, err = pcall(tracer.learnLayerClasses)
    log("learned the map's road paint for the scan: %s%s", tostring(ok and tracer.layerClassLearned), ok and (started ~= nil and string.format(" (%.0f ms)", (getTimeSec() - started) * 1000) or "") or (" " .. tostring(err)))
end

local corePaintCache, corePaintCount = {}, 0
local function makeCore()
    local tracer = getTracer()
    if RoadFollow.USE_ROAD_CORE then
        ensureLearned(tracer)
    end
    if not RoadFollow.USE_ROAD_CORE or tracer == nil or tracer.sampleRoadPaint == nil or not tracer.layerClassLearned then
        return nil
    end
    return function(x, z)
        local key = math.floor(x * 2) * 200003 + math.floor(z * 2)
        local known = corePaintCache[key]
        if known == nil then
            if corePaintCount > 60000 then
                corePaintCache, corePaintCount = {}, 0
            end
            known = tracer.sampleRoadPaint(x, z) == true
            corePaintCache[key] = known
            corePaintCount = corePaintCount + 1
        end
        return known
    end
end

-- Solid driving ground at an exact point (road paint or worn material), remembered per 0.5 m cell: the real edges of a track.
local finePaintCache, finePaintCount = {}, 0
local function makeFine()
    local tracer = getTracer()
    if RoadFollow.USE_FINE_EDGES then
        ensureLearned(tracer)
    end
    if not RoadFollow.USE_FINE_EDGES or tracer == nil or tracer.sampleSolidGround == nil then
        return nil
    end
    return function(x, z)
        local key = math.floor(x * 2) * 200003 + math.floor(z * 2)
        local known = finePaintCache[key]
        if known == nil then
            if finePaintCount > 80000 then
                finePaintCache, finePaintCount = {}, 0
            end
            known = tracer.sampleSolidGround(x, z) == true
            finePaintCache[key] = known
            finePaintCount = finePaintCount + 1
        end
        return known
    end
end

local function makeSampler()
    local tracer = getTracer()
    if tracer == nil or tracer.sampleDrivable == nil then
        return nil
    end
    local ignoreForestFloor = RoadFollow.IGNORE_FOREST_FLOOR and tracer.getLayerClassAt ~= nil and tracer.LAYER_CLASS_FOREST ~= nil
    return function(x, z)
        local class = tracer.sampleDrivable(x, z)
        if class == 1 and ignoreForestFloor and isForestFloor(tracer, x, z) then
            return 0                           -- worn ground whose paint is the forest floor's: not a track
        end
        return class
    end
end

-- Where the vehicle is, which way it points and how far ahead to read, for one scan.
local function scanSetup(self)
    local x, _, z = getWorldTranslation(self:getAISteeringNode())
    local dx, _, dz = localDirectionToWorld(self:getAIDirectionNode(), 0, 0, 1)
    -- read further ahead the faster it goes: about REACH_SECONDS of road, fine steps near, coarse far
    local speed = (self:getLastSpeed() or 0) / 3.6
    local reach = math.max(RoadFollow.REACH_MIN, math.min(RoadFollow.REACH_MAX, speed * RoadFollow.REACH_SECONDS))
    return x, z, dx, dz, reach, speed
end

-- Short name of where a line came from, for the on-screen text.
function RoadFollow.modeLabel(result)
    if result == nil then
        return "?"
    elseif result.mode == "field" then
        return "field: round obstacles"
    elseif result.mode ~= "path" then
        return "auto-detect"
    elseif result.kind == "spline" then
        return "road spline"
    elseif result.kind == "recorded" then
        return "recorded path"
    elseif result.kind == "imported" then
        return "imported road"
    end
    return "path"
end

-- Keeps the line clear of trees (the tree layer of the map scan): eased sideways round a trunk when the road
-- has room, ended before it when it has not (the vehicle then stops for it). Applies to both kinds of line.
-- A vehicle is about this wide on each side of its line; a building closer than this to a point of the line is in the way
local BUILDING_CLEARANCE = 1.8
-- Buildings right beside the vehicle are not "ahead": it is already there (parked next to a barn)
local BUILDING_IGNORE_NEAR = 4.0

local function applyObstacles(result, speedKmh)
    local tracer = getTracer()
    local hasTrees = tracer ~= nil and tracer.hasTreeData ~= nil and tracer.hasTreeData()
    local hasBuildings = tracer ~= nil and tracer.hasBuildingData ~= nil and tracer.hasBuildingData()
    if result == nil or not result.valid or result.points == nil or #result.points < 2 or not (hasTrees or hasBuildings) then
        return result
    end
    local startX, startZ = result.points[1][1], result.points[1][2]
    local function blocked(x, z)
        if hasTrees and tracer.sampleTree(x, z) then
            return true
        end
        if hasBuildings and (x - startX) ^ 2 + (z - startZ) ^ 2 > BUILDING_IGNORE_NEAR ^ 2 then
            local c = BUILDING_CLEARANCE
            return tracer.sampleBuilding(x, z) or tracer.sampleBuilding(x + c, z) or tracer.sampleBuilding(x - c, z)
                or tracer.sampleBuilding(x, z + c) or tracer.sampleBuilding(x, z - c)
        end
        return false
    end
    local onRoad = nil
    if result.kind ~= "spline" and tracer.hasDrivableData ~= nil and tracer.hasDrivableData() then
        local sample = makeSampler()
        onRoad = function(x, z) return (sample(x, z) or 0) ~= 0 end
    end
    local ramp = math.max(8, math.min(20, speedKmh / 3.6 * 1.2))
    local points, info = RoadCenterline.avoidObstacles(result.points, blocked, onRoad, { ramp = ramp })
    result.points = points
    result.found = #points
    result.nudged = info.nudged
    if info.obstacle ~= nil then
        result.obstacle = info.obstacle
        result.ends = true
        -- what it is and where (for the log and the black box): the first blocked cell beyond the end of the line
        local n = #points
        if n >= 2 then
            local lx, lz = points[n][1] - points[n - 1][1], points[n][2] - points[n - 1][2]
            local length = math.sqrt(lx * lx + lz * lz)
            if length > 1e-6 then
                lx, lz = lx / length, lz / length
                for d = 0, 14, 0.5 do
                    local px, pz = points[n][1] + lx * d, points[n][2] + lz * d
                    local kind = nil
                    if hasTrees and tracer.sampleTree(px, pz) then
                        kind = "tree"
                    elseif hasBuildings and tracer.sampleBuilding(px, pz) then
                        kind = "building"
                    end
                    if kind ~= nil then
                        result.obstacleKind, result.obstacleX, result.obstacleZ = kind, px, pz
                        break
                    end
                end
            end
        end
    end
    return result
end

-- The centre-line ahead of the vehicle right now, or nil, reason when there is nothing to read.
-- First a stored path (the map's road splines, a recorded drive ...) that runs along the vehicle;
-- failing that, the road guessed from the map bitmaps.
-- The geometry (RoadCenterline) works in the world's x / z plane, where z points south: turning counter-clockwise
-- there is turning RIGHT as the driver sees it. A "left" signal therefore asks the geometry for its
-- counter-clockwise opposite, and the other way round. (Found the hard way: the vehicle turned against the blinker.)
local function geometrySide(intent)
    if intent == "left" then
        return "right"
    elseif intent == "right" then
        return "left"
    end
    return nil
end

-- The line ends at the map border: beyond it is not drivable (roads and splines may run right off the map).
local function clipToMap(result)
    local size = g_currentMission ~= nil and g_currentMission.terrainSize or nil
    if size == nil or result == nil or not result.valid or result.points == nil then
        return result
    end
    local limit = size / 2 - RoadFollow.MAP_BORDER_MARGIN
    for i, point in ipairs(result.points) do
        if math.abs(point[1]) > limit or math.abs(point[2]) > limit then
            for k = #result.points, i, -1 do
                result.points[k] = nil
            end
            result.found = #result.points
            result.ends = true
            result.junctionEnd, result.junctionAt = nil, nil
            break
        end
    end
    return result
end

-- How many degrees a line turns from its start to its end (0 for fewer than 4 points).
local function lineTurnDegrees(points)
    local n = #points
    if n < 4 then
        return 0
    end
    local a1 = math.atan2(points[3][2] - points[1][2], points[3][1] - points[1][1])
    local a2 = math.atan2(points[n][2] - points[n - 2][2], points[n][1] - points[n - 2][1])
    local d = a2 - a1
    return math.abs(math.deg(math.atan2(math.sin(d), math.cos(d))))
end

-- A signalled turn is worked out once and then driven: the line (stem, arc, the road turned onto) is kept in world
-- coordinates and only trimmed to where the vehicle is, instead of being found again from the stored paths every scan
-- (a new scan half way round a junction can pick another lane or another branch, and the line jumps).
-- Returns the result for this moment, or nil when the kept line is no longer to be driven (done, left, other signal).
local FROZEN_MIN_REMAINING = 6.0     -- metres of kept line left: the normal scan takes over for the rest
local FROZEN_MAX_DISTANCE = 5.0      -- the vehicle further than this from the kept line: it is not driving it any more
local function frozenTurnResult(frozen, intent, x, z, dx, dz)
    if frozen == nil or frozen.intent ~= intent then
        return nil
    end
    local points = frozen.points
    local bestI, bestD, bestX, bestZ = nil, math.huge, 0, 0
    for k = 1, #points - 1 do
        local ax, az, bx, bz = points[k][1], points[k][2], points[k + 1][1], points[k + 1][2]
        local sx, sz = bx - ax, bz - az
        local lengthSq = sx * sx + sz * sz
        local t = lengthSq > 1e-9 and math.max(0, math.min(1, ((x - ax) * sx + (z - az) * sz) / lengthSq)) or 0
        local cx, cz = ax + sx * t, az + sz * t
        local d = (cx - x) ^ 2 + (cz - z) ^ 2
        if d < bestD then
            bestI, bestD, bestX, bestZ = k, d, cx, cz
        end
    end
    if bestI == nil or bestD > FROZEN_MAX_DISTANCE * FROZEN_MAX_DISTANCE then
        return nil
    end
    local rest = { { bestX, bestZ } }
    for k = bestI + 1, #points do
        rest[#rest + 1] = points[k]
    end
    local remaining = 0
    for k = 2, #rest do
        remaining = remaining + math.sqrt((rest[k][1] - rest[k - 1][1]) ^ 2 + (rest[k][2] - rest[k - 1][2]) ^ 2)
    end
    if remaining < FROZEN_MIN_REMAINING or #rest < 2 then
        return nil
    end
    local result = {}
    for key, value in pairs(frozen.result) do
        result[key] = value
    end
    result.points = rest
    result.found = #rest
    result.offset = (bestX - x) * (-dz) + (bestZ - z) * dx
    result.frozen = true
    return result
end


-- ===== a course through open ground (field mode) =====
local function isOnField(x, z)
    if getDensityAtWorldPos == nil or g_currentMission == nil or g_currentMission.terrainDetailId == nil then
        return false
    end
    local ok, density = pcall(getDensityAtWorldPos, g_currentMission.terrainDetailId, x, 0, z)
    return ok and density ~= nil and density ~= 0
end

-- The "is it in the way" question for the planner: trees, buildings, forest, and ground too steep to drive. nil when the map knows of none
-- of these layers (then there is nothing to avoid them with, and no field mode).
local function fieldBlocker()
    local tracer = getTracer()
    if tracer == nil then
        return nil
    end
    local hasTrees = tracer.hasTreeData ~= nil and tracer.hasTreeData()
    local hasBuildings = tracer.hasBuildingData ~= nil and tracer.hasBuildingData()
    local hasForest = tracer.hasForestData ~= nil and tracer.hasForestData()
    if not (hasTrees or hasBuildings or hasForest) then
        return nil
    end
    local cache = {}
    return function(px, pz)
        local key = math.floor(px / 2) * 100003 + math.floor(pz / 2)
        local known = cache[key]
        if known ~= nil then
            return known
        end
        local blocked = false
        if hasTrees and tracer.sampleTree(px, pz) then
            blocked = true
        elseif hasBuildings and tracer.sampleBuilding(px, pz) then
            blocked = true
        elseif hasForest and tracer.sampleForest(px, pz) then
            blocked = true
        elseif getTerrainHeightAtWorldPos ~= nil then
            local h1 = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            local h2 = getTerrainHeightAtWorldPos(g_terrainNode, px + 2, 0, pz)
            blocked = math.abs(h2 - h1) / 2 > RoadFollow.FIELD_SLOPE_MAX
        end
        cache[key] = blocked
        return blocked
    end
end

-- Half the width of the vehicle with what it pulls and carries (the widest of them), plus a little room.
local function fieldHalfWidth(vehicle)
    local widest = 0
    local children = vehicle.rootVehicle ~= nil and vehicle.rootVehicle.childVehicles or { vehicle }
    for _, child in ipairs(children) do
        if child.size ~= nil and type(child.size.width) == "number" then
            widest = math.max(widest, child.size.width)
        end
    end
    return math.max(2.0, widest / 2 + 0.8)
end

-- The kept course trimmed to where the vehicle is now: the points from its nearest point on; nil when it is too far off the course or too little is left.
local function trimCourse(points, x, z)
    local bestI, bestD, bestX, bestZ = nil, math.huge, 0, 0
    for k = 1, #points - 1 do
        local ax, az, bx, bz = points[k][1], points[k][2], points[k + 1][1], points[k + 1][2]
        local sx, sz = bx - ax, bz - az
        local lengthSq = sx * sx + sz * sz
        local t = lengthSq > 1e-9 and math.max(0, math.min(1, ((x - ax) * sx + (z - az) * sz) / lengthSq)) or 0
        local cx, cz = ax + sx * t, az + sz * t
        local d = (cx - x) ^ 2 + (cz - z) ^ 2
        if d < bestD then
            bestI, bestD, bestX, bestZ = k, d, cx, cz
        end
    end
    if bestI == nil or bestD > 9 then
        return nil
    end
    local rest = { { bestX, bestZ } }
    for k = bestI + 1, #points do
        rest[#rest + 1] = points[k]
    end
    local length = 0
    for k = 2, #rest do
        length = length + math.sqrt((rest[k][1] - rest[k - 1][1]) ^ 2 + (rest[k][2] - rest[k - 1][2]) ^ 2)
    end
    if length < 12 then
        return nil
    end
    return rest
end

-- The course through open ground as a scan result, or nil when this is not a place for it (not on a field, a road under or ahead, no obstacle
-- layers, cruise control off). The direction the vehicle goes when the course starts is kept as far as the obstacles allow.
local function fieldCourse(self, assist, x, z, dx, dz, speedKmh)
    local cruise = self.spec_drivable ~= nil and self.spec_drivable.cruiseControl or nil
    local cruiseOn = cruise ~= nil and Drivable ~= nil and cruise.state ~= Drivable.CRUISECONTROL_STATE_OFF
    if not RoadFollow.FIELD_MODE or assist == nil or not cruiseOn or speedKmh < 3 or RoadFieldCourse == nil then
        return nil
    end
    -- the game's own steering assist has field lanes ready here (a tool is attached, the vehicle is on a field): that is the tool for the job, and
    -- this does not start up in front of it (the player is about to switch it on)
    if self.getAIAutomaticSteeringState ~= nil and AIAutomaticSteering ~= nil and AIAutomaticSteering.STATE ~= nil then
        local ok, state = pcall(self.getAIAutomaticSteeringState, self)
        if ok and state ~= nil and state ~= AIAutomaticSteering.STATE.DISABLED then
            return nil
        end
    end
    local onRoad, roadAhead = groundUnder(x, z, dx, dz, nil)
    if onRoad ~= false or roadAhead ~= false then
        return nil                           -- a road (or no map picture to tell): not open ground
    end
    if RoadFollow.FIELD_ONLY_ON_FIELDS and not isOnField(x, z) then
        return nil
    end
    local blocked = fieldBlocker()
    if blocked == nil then
        return nil
    end
    local field = assist.field
    if field == nil then
        field = { ref = { x = x, z = z, dx = dx, dz = dz }, previous = 0, lastMs = -1e9 }
        assist.field = field
        log("field course started at %.0f %.0f, heading %.0f deg from north", x, z, math.deg(math.atan2(dx, -dz)) % 360)
    end
    local now = g_time or 0
    local points = nil
    if field.plan ~= nil and now - field.lastMs < RoadFollow.FIELD_PLAN_MS then
        points = trimCourse(field.plan.points, x, z)
    end
    local plan = field.plan
    if points == nil then
        local speedMs = speedKmh / 3.6
        plan = RoadFieldCourse.plan(blocked, x, z, dx, dz, field.ref,
            { length = RoadFollow.FIELD_LOOK, halfWidth = fieldHalfWidth(self), previous = field.previous })
        field.plan, field.lastMs, field.previous = plan, now, plan.kappa
        points = plan.points
    end
    local free = plan.free or 0
    local result = { valid = true, points = points, found = #points, mode = "field", kind = "field", ends = false, junction = false,
        openGround = false, roadWidth = 8, offset = 0, field = true }
    if plan.blockedAhead then
        result.ends = true
        result.obstacle = { d = math.max(0, free - 2) }
    end
    return result
end

-- previewIntent: "left" / "right" / "straight" reads the road AS IF that signal were on (or none: for the debug view's options):
-- nothing of the assist's own turn state is read or changed then. previewReach: look at least this far (metres).
function RoadFollow:scanRoadAhead(allowCapture, previewIntent, previewReach)
    local x, z, dx, dz, reach, speedMsNow = scanSetup(self)
    -- rows twice as far apart once moving (up to 3 m near, 6 m far): the line is read over a long stretch, and a row's own
    -- jitter matters less; slowly (tight turns, manoeuvres) the fine steps stay
    local rowScale = 1 + (RoadFollow.ROW_SCALE_MAX - 1) * math.max(0, math.min(1, (speedMsNow - 4) / 4))
    local scanSteps = { step = RoadCenterline.STEP * rowScale, farStep = RoadCenterline.FAR_STEP * rowScale, nearRange = RoadCenterline.NEAR_RANGE * rowScale }
    local speedKmh = self:getLastSpeed() or 0
    if previewReach ~= nil then
        reach = math.max(reach, previewReach)
    end
    local intent
    if previewIntent == "straight" then
        intent = nil
    else
        intent = geometrySide(previewIntent or RoadFollow.getIntent(self))
    end
    -- joining: at speed, a path ahead that the vehicle is heading towards is picked up early and the
    -- line eases onto it; the curvature of that line then slows the vehicle for the join
    local capture = nil
    -- a join that is under way goes on after the join itself has slowed the vehicle below the speed a
    -- join is first looked for at (otherwise the line vanishes half way and the road is lost)
    local assist = getSpec(self).assist
    local joining = assist ~= nil and assist.engaged and assist.result ~= nil and assist.result.capturing == true
    local inField = assist ~= nil and assist.field ~= nil
    if allowCapture and (speedKmh >= RoadFollow.CAPTURE_MIN_KMH or inField or (joining and speedKmh >= RoadFollow.JOIN_KEEP_MIN_KMH)) then
        local ahead = math.max(speedKmh, joining and RoadFollow.CAPTURE_MIN_KMH or 0) / 3.6
        capture = {
            radius = math.max(8, math.min(60, ahead * RoadFollow.CAPTURE_SECONDS)),
            minAlign = math.cos(math.rad(RoadFollow.JOIN_MAX_DEG)),          -- (a path across the way is not for joining)
            blendLength = math.max(RoadFollow.BLEND_MIN, math.min(RoadFollow.BLEND_MAX, ahead * 3.0)),
        }
    end

    local store = g_currentMission ~= nil and g_currentMission.wailaPaths or nil
    if RoadFollow.usePaths and store ~= nil then
        if store.importMapSplines ~= nil then
            store.importMapSplines()     -- once per session
        end
        local pathReach = math.max(reach, math.min(RoadFollow.PATH_REACH_MAX, speedKmh / 3.6 * RoadFollow.PATH_REACH_SECONDS))
        if intent ~= nil then
            pathReach = pathReach + RoadFollow.TURN_EXTRA_REACH            -- a signalled turn is read to the end of the turn and a little beyond
        end
        local ownAssist = (previewIntent == nil) and getSpec(self).assist or nil
        local stickPath = (intent ~= nil and ownAssist ~= nil) and ownAssist.turnPathId or nil
        if ownAssist ~= nil and ownAssist.frozenTurn ~= nil then
            local kept = frozenTurnResult(ownAssist.frozenTurn, intent, x, z, dx, dz)
            if kept ~= nil then
                return applyObstacles(clipToMap(kept), speedKmh), nil
            end
            ownAssist.frozenTurn = nil
        end
        local line = RoadCenterline.pathLine(store, x, z, dx, dz, { reach = pathReach, laneOffset = -RoadFollow.laneOffset, capture = capture, intent = intent, stickPath = stickPath,
            targetPath = (intent ~= nil and ownAssist ~= nil) and ownAssist.turnTargetId or nil })
        if ownAssist ~= nil then
            -- remember the path a signalled turn is made from, until the signal is done
            if intent ~= nil and line.valid and line.pathId ~= nil and ownAssist.turnPathId == nil then
                ownAssist.turnPathId = line.pathId
            elseif intent == nil then
                ownAssist.turnPathId = nil
                ownAssist.turnTargetId = nil
            end
            -- a turn worked out: keep that line (see frozenTurnResult) while it is driven
            -- ... but only a line that holds the WHOLE turn: one cut short by the look-ahead (the turn still beyond its end) would be driven
            -- straight to its end and re-planned at the last moment, with the corner already behind the arc's start
            if intent ~= nil and line.valid and line.turned and (line.sharpestCorner or 0) >= RoadFollow.FREEZE_TURN_DEG
                and math.abs(line.offset or 0) <= RoadFollow.FREEZE_MAX_OFFSET and #line.points >= 4
                and lineTurnDegrees(line.points) >= RoadFollow.FREEZE_COMPLETE * (line.sharpestCorner or 0) then
                local kept = {}
                for key, value in pairs(line) do
                    kept[key] = value
                end
                kept.points = nil
                local copy = {}
                for i, point in ipairs(line.points) do
                    copy[i] = { point[1], point[2] }
                end
                ownAssist.frozenTurn = { intent = intent, points = copy, result = kept }
            elseif intent == nil then
                ownAssist.frozenTurn = nil
            end
            -- ... and the road it turns onto, so that the choice made at the start is kept all the way round
            if intent ~= nil and line.valid and line.targetPathId ~= nil and ownAssist.turnTargetId == nil then
                ownAssist.turnTargetId = line.targetPathId
            end
        end
        if line.valid then
            -- a turn signal is on, but the stored paths know of no side road to turn into (the map's side road
            -- splines often stop short of the main road, or are missing): the map pictures see the opening
            if intent ~= nil and not line.turned then
                local tracer = getTracer()
                if tracer ~= nil and tracer.hasDrivableData ~= nil and tracer.hasDrivableData() then
                    local pixel = RoadCenterline.scan(makeSampler(), x, z, dx, dz, { reach = reach, trustedReach = RoadFollow.TRUSTED_REACH, intent = intent, core = makeCore(), fine = makeFine(), rows = RoadFollow.wantRows(),
        step = scanSteps.step, farStep = scanSteps.farStep, nearRange = scanSteps.nearRange })
                    if pixel.valid and pixel.turned then
                        pixel.mode = "auto"
                        return applyObstacles(clipToMap(pixel), speedKmh), nil
                    end
                end
            end
            return applyObstacles(clipToMap(line), speedKmh), nil
        end
    end

    local tracer = getTracer()
    if tracer == nil or tracer.hasDrivableData == nil or not tracer.hasDrivableData() then
        return nil, "ROADFOLLOW_NEED_SCAN"
    end
    local result = RoadCenterline.scan(makeSampler(), x, z, dx, dz, { reach = reach, trustedReach = RoadFollow.TRUSTED_REACH, intent = intent, core = makeCore(), fine = makeFine(), rows = RoadFollow.wantRows(),
        step = scanSteps.step, farStep = scanSteps.farStep, nearRange = scanSteps.nearRange })
    result.mode = "auto"
    -- no road here: open ground with cruise control on is steered through (RoadFollow.FIELD_MODE), only for the assist's own scans
    if allowCapture == true and previewIntent == nil then
        local looksLikeRoad = result.valid and not result.openGround and #result.points >= RoadFollow.ASSIST_MIN_POINTS
        if not looksLikeRoad then
            local field = fieldCourse(self, assist, x, z, dx, dz, speedKmh)
            if field ~= nil then
                return clipToMap(field), nil
            end
        end
    end
    return applyObstacles(clipToMap(result), speedKmh), nil
end

-- Share of the cruise speed the ground along this line allows (road 1.0, worn trail 0.6 ...); 1 when
-- the map data has no layer to ask.
local function groundFactorOf(result, cruiseKmh)
    local sample = makeSampler()
    if sample == nil or result == nil or result.points == nil then
        return 1
    end
    -- off-road ground is capped only when the map data can tell (class 0 then means "not road, not
    -- trail") and for lines that are not the map's own road splines (those are roads by definition)
    local tracer = getTracer()
    local haveData = tracer ~= nil and tracer.hasDrivableData ~= nil and tracer.hasDrivableData()
    local offroad = nil
    if haveData and result.kind ~= "spline" and type(cruiseKmh) == "number" and cruiseKmh > 0 then
        offroad = math.min(1, RoadFollow.OFFROAD_KMH / cruiseKmh)
    end
    local factors = { road = RoadFollow.groundFactors.road, trail = RoadFollow.groundFactors.trail, offroad = offroad }
    return RoadCenterline.groundFactor(result.points, sample, factors, RoadFollow.GROUND_LOOKAHEAD)
end

-- ===== starting and stopping =====

function RoadFollow:getIsRoadFollowActive()
    return getSpec(self).isActive
end

-- true, or false and the l10n name of the reason
function RoadFollow:getCanStartRoadFollow()
    if self:getIsRoadFollowActive() or self:getIsAIActive() then
        return false, nil
    end
    local result, reason = self:scanRoadAhead()
    if result == nil then
        return false, reason
    end
    -- standing on open ground (a yard, or crossing the road) is not "on the road, pointing along it"
    if not result.valid or result.openGround then
        return false, "ROADFOLLOW_NOT_ON_ROAD"
    end
    return true, nil
end

local function warn(textName)
    if textName == nil then
        return
    end
    local text = g_i18n:getText(textName)
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(text, 3000)
    else
        log("%s", text)
    end
end

function RoadFollow:actionEventToggle(actionName, inputValue, callbackState, isAnalog)
    if self:getIsRoadFollowActive() then
        local message = AIMessageSuccessStoppedByUser ~= nil and AIMessageSuccessStoppedByUser.new() or AIMessageSuccessFinishedJob.new()
        self:stopCurrentAIJob(message)
        return
    end
    if not g_currentMission:getHasPlayerPermission("hireAssistant") then
        return
    end
    local canStart, reason = self:getCanStartRoadFollow()
    if not canStart then
        warn(reason)
        return
    end

    local job = g_currentMission.aiJobTypeManager:createJob(AIJobType.MOD_ROAD_FOLLOW)
    job.vehicleParameter:setVehicle(self)
    job:setValues()
    local success = job:validate(g_localPlayer.farmId)
    if success then
        self:setAIModeSelection(AIModeSelection.MODE.WORKER)
        g_currentMission.aiSystem:startJob(job, g_localPlayer.farmId)
    end
end

function RoadFollow:startRoadFollow()
    local spec = getSpec(self)
    spec.isActive = true
    spec.lostMs = 0
    spec.didNotMoveMs = 0
    spec.scanTimer = RoadFollow.CHECK_INTERVAL_MS
    spec.result = nil
    spec.target = nil
    if self.isServer then
        spec.collision = AIDriveStrategyRoadFollowCollision.new({})
        spec.collision:setAIVehicle(self)
    end
    RoadFollow.updateActionEvents(self)
    log("started on %s", tostring(self:getName()))
end

function RoadFollow:stopRoadFollow()
    local spec = getSpec(self)
    spec.isActive = false
    spec.result = nil
    spec.target = nil

    self:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF, true)
    if self.isServer then
        WheelsUtil.updateWheelsPhysics(self, 0, (self.lastSpeedReal or 0) * (self.movingDirection or 1), 0, true, true)
        if spec.collision ~= nil then
            spec.collision:delete()
            spec.collision = nil
        end
    end
    if self.brake ~= nil then
        self:brake(1)
    end
    local actionController = self.rootVehicle.actionController
    if actionController ~= nil then
        actionController:resetCurrentState()
    end
    RoadFollow.updateActionEvents(self)
    log("stopped")
end

-- ===== the drive loop =====

function RoadFollow:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if self.isServer and self:getIsRoadFollowActive() then
        self:updateRoadFollowDrive(dt)
    end
end

function RoadFollow:updateRoadFollowDrive(dt)
    local spec = getSpec(self)

    -- the road ahead, re-read a few times a second
    spec.scanTimer = spec.scanTimer + dt
    if spec.scanTimer >= RoadFollow.CHECK_INTERVAL_MS or spec.result == nil then
        local elapsed = spec.scanTimer
        spec.scanTimer = 0
        local result = self:scanRoadAhead()
        spec.result = result
        spec.groundFactor = groundFactorOf(result, self:getCruiseControlMaxSpeed())
        if result ~= nil and result.valid and #result.points >= 2 then
            spec.lostMs = 0
        else
            -- real time since the last read, not the nominal interval
            spec.lostMs = spec.lostMs + elapsed
        end
    end

    if spec.lostMs >= RoadFollow.LOST_ROAD_STOP_MS then
        self:stopCurrentAIJob(AIMessageErrorRoadEnded.new())
        return
    end

    local result = spec.result
    local vX, vY, vZ = getWorldTranslation(self:getAISteeringNode())
    local speedKmh = self:getLastSpeed() or 0

    local tX, tZ, maxSpeed
    if result ~= nil and result.valid and #result.points >= 2 then
        local lookahead = math.max(RoadFollow.LOOKAHEAD_MIN, speedKmh / 3.6 * RoadFollow.LOOKAHEAD_SECONDS)
        tX, tZ = RoadCenterline.pickTargetAveraged(RoadCenterline.steeringLine(result.points), vX, vZ, lookahead, RoadFollow.AIM_SPREAD)
        maxSpeed = RoadCenterline.speedAdvice(result, math.huge, RoadCenterline.length(result.points))
    else
        -- lost the road for a moment: roll on straight, slowly, until it is back or the time is up
        local dx, _, dz = localDirectionToWorld(self:getAIDirectionNode(), 0, 0, 1)
        tX, tZ = vX + dx * RoadFollow.LOOKAHEAD_MIN, vZ + dz * RoadFollow.LOOKAHEAD_MIN
        maxSpeed = RoadFollow.LOST_ROAD_SPEED_KMH
    end
    spec.target = { tX, tZ }

    -- the collision strategy only ever lowers the speed
    if spec.collision ~= nil then
        spec.collision:update(dt)
        local _, _, _, collisionSpeed = spec.collision:getDriveData(dt, vX, vY, vZ)
        maxSpeed = math.min(maxSpeed, collisionSpeed or math.huge)
    end

    -- single values, each: getSpeedLimit also returns a flag
    local speedLimit = self:getSpeedLimit(true)
    local cruiseSpeed = self:getCruiseControlMaxSpeed()
    if type(speedLimit) == "number" then
        maxSpeed = math.min(maxSpeed, speedLimit)
    end
    if type(cruiseSpeed) == "number" then
        maxSpeed = math.min(maxSpeed, cruiseSpeed * (spec.groundFactor or 1))
    end
    if maxSpeed > 0 then
        maxSpeed = math.max(maxSpeed, RoadFollow.MIN_SPEED_KMH)
    end

    -- stuck: stop rather than push for ever
    if maxSpeed > 0 and speedKmh < 0.5 then
        spec.didNotMoveMs = spec.didNotMoveMs + dt
        if spec.didNotMoveMs > RoadFollow.DID_NOT_MOVE_STOP_MS then
            self:stopCurrentAIJob(AIMessageErrorBlockedByObject.new())
            return
        end
    else
        spec.didNotMoveMs = 0
    end

    local pX, _, pZ = worldToLocal(self:getAISteeringNode(), tX, vY, tZ)
    AIVehicleUtil.driveToPoint(self, dt, 1, maxSpeed ~= 0, true, pX, pZ, maxSpeed)
end

-- ===== assisted cruise control =====

local function isCruiseOn(self)
    local drivable = self.spec_drivable
    local cruise = drivable ~= nil and drivable.cruiseControl or nil
    return cruise ~= nil and Drivable ~= nil and cruise.state ~= Drivable.CRUISECONTROL_STATE_OFF
end

-- ===== turn signals =====
-- The intent at the next junction: "left", "right" or nil (straight on). Set with the left / right mouse
-- button (a second click on the same side cancels, the other side switches), or by the vehicle's own
-- turn lights (the game's indicator keys). Cleared when the turn is done, after a timeout, or when
-- the assist hands control back.
local function turnLightIntent(vehicle)
    if vehicle.getTurnLightState == nil or Lights == nil then
        return nil
    end
    local ok, state = pcall(vehicle.getTurnLightState, vehicle)
    if not ok or state == nil then
        return nil
    end
    if Lights.TURNLIGHT_LEFT ~= nil and state == Lights.TURNLIGHT_LEFT then
        return "left"
    elseif Lights.TURNLIGHT_RIGHT ~= nil and state == Lights.TURNLIGHT_RIGHT then
        return "right"
    end
    return nil
end

local function setTurnLights(vehicle, intent)
    if vehicle.setTurnLightState == nil or Lights == nil then
        return
    end
    local state = Lights.TURNLIGHT_OFF
    if intent == "left" then
        state = Lights.TURNLIGHT_LEFT
    elseif intent == "right" then
        state = Lights.TURNLIGHT_RIGHT
    elseif intent == "hazard" then
        state = Lights.TURNLIGHT_HAZARD
    end
    if state ~= nil then
        pcall(vehicle.setTurnLightState, vehicle, state, true)
    end
end

function RoadFollow.getIntent(vehicle)
    local spec = getSpec(vehicle)
    if spec == nil or spec.assist == nil then
        return nil
    end
    return spec.assist.intent or turnLightIntent(vehicle)
end

-- A click on the left or right mouse button while the assist drives.
function RoadFollow.signal(vehicle, side)
    local spec = vehicle ~= nil and getSpec(vehicle) or nil
    if spec == nil or spec.assist == nil or not spec.assist.engaged then
        return false
    end
    local assist = spec.assist
    -- the same side again puts the signal out; the other side switches it (left kills right and sets left)
    if (assist.intent or turnLightIntent(vehicle)) == side then
        assist.intent = nil
    else
        assist.intent = side
        local hx, _, hz = localDirectionToWorld(vehicle:getAIDirectionNode(), 0, 0, 1)
        assist.intentHx, assist.intentHz = hx, hz
    end
    assist.intentMs = 0
    assist.intentTurnDeg = nil
    setTurnLights(vehicle, assist.intent)
    log("signal: %s", tostring(assist.intent or "off"))
    return true
end

-- A tap on a steering key while the assist is NOT driving: the vehicle's own turn lights are set, switched or cleared
-- the same way (the same side again puts a light out, the other side switches it), so a light can always be put out again. The
-- assist reads them as the signal as soon as it drives. Only the lights: nothing else is touched.
function RoadFollow.signalLights(vehicle, side)
    local target = side                    -- (the other side switches it)
    if turnLightIntent(vehicle) == side then
        target = nil                       -- the same side again: out
    end
    setTurnLights(vehicle, target)
    log("turn light (assist not driving): %s", tostring(target or "off"))
    return target
end

-- Called every tick while the assist drives: the signal is done once the vehicle has turned that way.
local function updateIntent(self, assist, dt)
    if assist.intent == nil then
        return
    end
    assist.intentMs = assist.intentMs + dt
    local hx, _, hz = localDirectionToWorld(self:getAIDirectionNode(), 0, 0, 1)
    local cross = (assist.intentHx or hx) * hz - (assist.intentHz or hz) * hx
    local dot = (assist.intentHx or hx) * hx + (assist.intentHz or hz) * hz
    local angle = math.deg(math.atan2(cross, dot))          -- + = turned counter-clockwise in x / z = to the RIGHT (z points south)
    local sign = assist.intent == "left" and -1 or 1
    -- done when most of the turn the plan has is made (a 90 degree corner: about 72), or, with stored paths, once the vehicle
    -- is on another path than the one the turn started from
    local doneAngle = math.min(85, math.max(RoadFollow.INTENT_DONE_DEG, 0.8 * (assist.intentTurnDeg or 0)))
    local onNewPath = assist.turnPathId ~= nil and assist.result ~= nil and assist.result.pathId ~= nil
        and assist.result.pathId ~= assist.turnPathId and not assist.result.turned
    if angle * sign >= doneAngle or onNewPath or assist.intentMs >= RoadFollow.INTENT_TIMEOUT_MS then
        log("signal done (%s, turned %.0f degrees)", assist.intent, angle)
        setTurnLights(self, nil)
        assist.intent = nil
    end
end

local function showMessage(text)
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(text, 4000)
    end
    log("%s", text)
end

-- The black box: what the assist saw and asked for in the last seconds, so an incident (an overshoot, a wrong turn,
-- a rescue) can be read from the log afterwards. Written when the assist stops the vehicle or the player takes
-- over, but only with WAILA's debug logging on (one entry per 0.2 s); `roadFollowBlackbox` writes it any time.
local function blackboxRecord(assist, entry)
    local box = assist.blackbox
    if box == nil then
        box = {}
        assist.blackbox = box
    end
    box[#box + 1] = entry
    if #box > RoadFollow.BLACKBOX_KEEP then
        table.remove(box, 1)
    end
end

local function blackboxWrite(assist, why)
    local box = assist.blackbox
    if box == nil or #box == 0 then
        return
    end
    local now = box[#box].t
    print(string.format("[RoadFollow] blackbox (%s): last %.1f s, one line per 0.2 s", tostring(why), (now - box[1].t) / 1000))
    for i = 1, #box, 2 do
        local e = box[i]
        print(string.format("[RoadFollow] bb %+5.1fs pos %.0f %.0f hdg %3.0f spd %4.1f ask %4.1f bend %4.1f pX %+5.1f pZ %4.1f y %+5.2f k %.3f L%d pts %d %s%s%s",
            (e.t - now) / 1000, e.x, e.z, e.hdg, e.speed, e.ask, e.bend, e.pX, e.pZ, e.y, e.k, e.level, e.points, tostring(e.mode),
            e.intent and (" signal " .. e.intent) or "", e.note or ""))
    end
end


local function disengage(assist, reason)
    if assist.engaged then
        log("assist off: %s", reason)
        if WailaConfig ~= nil and WailaConfig.isDebugLog ~= nil and WailaConfig.isDebugLog()
            and (reason == "pedal" or reason == "player steering" or reason == "handbrake" or tostring(reason):find("stopped", 1, true)) then
            blackboxWrite(assist, reason)
        end
    end
    assist.blackbox = nil
    if assist.sup ~= nil then
        RoadSupervisor.reset(assist.sup)
    end
    if assist.meander ~= nil then
        RoadMeander.reset(assist.meander)
    end
    if assist.collision ~= nil then
        pcall(assist.collision.delete, assist.collision)
        assist.collision = nil
    end
    assist.blockedMs = 0
    assist.lead, assist.leadState, assist.following = nil, nil, false
    assist.kappa = 0
    assist.stuckMs, assist.askedKmh = 0, 0
    assist.turnPathId = nil
    assist.turnTargetId = nil
    assist.frozenTurn = nil
    assist.field = nil
    assist.far = nil
    assist.intentTurnDeg = nil
    assist.prevHx, assist.prevHz, assist.yawF, assist.askedYawF, assist.kappaSlow, assist.understeerWarm = nil, nil, nil, nil, nil, 0
    assist.holdTravel = 0
    assist.correctCapKmh = nil
    assist.fastMs = 0
    assist.holdMs = 0
    assist.waiting = false
    assist.intent = nil
    assist.saturated = false
    assist.engaged = false
    assist.goodScans = 0
    assist.badMs = 0
    assist.result = nil
    assist.smoothPoints = nil
    assist.tX, assist.tZ = nil, nil
    assist.modeLabel = nil
end

-- Decides, once per physics call, whether the assist drives this frame. Keeps the road reading up
-- to date (a few times a second) and the engage / hold logic. Returns true when it should steer.
-- The steering keys while the assist drives. A short tap is the turn signal (left key = left, right key =
-- right, the same key again cancels it) and the assist keeps driving; held for longer than TAP_HOLD_MS it
-- is the player taking over. Returns true while the player is steering. A key press ramps the steering
-- axis up and down, so a press is judged by the time the axis stays above half its peak.
local function steerInput(self, assist, axisSide, dt)
    local magnitude = math.abs(axisSide)
    local tap = assist.tap
    if tap == nil then
        tap = { active = false }
        assist.tap = tap
    end
    if not tap.active then
        if magnitude <= RoadFollow.ASSIST_STEER_DEADZONE then
            return false
        end
        tap.active, tap.ms, tap.peak, tap.taken = true, 0, 0, false
        tap.sign = axisSide > 0 and 1 or -1
        tap.wasEngaged = assist.engaged
        tap.signalled, tap.saved = false, nil
        if assist.engaged and RoadFollow.TAP_SIGNALS and RoadFollow.TAP_INSTANT then
            -- the signal at once, not when the key comes up (the key's own axis takes a while to fall): what it was is kept for a hold
            tap.saved = { intent = assist.intent, light = turnLightIntent(self) }
            local pressed = (tap.sign * RoadFollow.STEER_LEFT_SIGN > 0) and "left" or "right"
            log("steering press: signal %s at once (undone if it becomes a hold)", pressed)
            RoadFollow.signal(self, pressed)
            tap.signalled = true
        end
        -- not driving: a tap still works the turn lights when cruise control is on (the assist is wanted), or
        -- when a light is already on (so that it can be put out whatever the cruise control does)
        tap.lightsOnly = not assist.engaged and RoadFollow.TAP_SIGNALS
            and (isCruiseOn(self) or turnLightIntent(self) ~= nil or assist.hazard == true)
    end
    tap.ms = tap.ms + dt
    tap.peak = math.max(tap.peak, magnitude)
    if magnitude < math.max(RoadFollow.ASSIST_STEER_DEADZONE, tap.peak * 0.5) then
        -- released
        tap.active = false
        local side = (tap.sign * RoadFollow.STEER_LEFT_SIGN > 0) and "left" or "right"
        if tap.signalled then
            tap.signalled = false             -- (already set when the key went down)
        elseif not tap.taken and tap.wasEngaged and assist.engaged and RoadFollow.TAP_SIGNALS then
            log("steering tap (axis %+.2f for %d ms, peak %.2f): signal %s  (if that is the wrong side: roadFollowTapFlip)", tap.sign * tap.peak, tap.ms, tap.peak, side)
            RoadFollow.signal(self, side)
        elseif tap.lightsOnly and tap.ms < RoadFollow.TAP_HOLD_MS and not assist.engaged then
            log("steering tap (axis %+.2f for %d ms, peak %.2f): turn light %s", tap.sign * tap.peak, tap.ms, tap.peak, side)
            if assist.hazard then
                assist.hazard = false
            end
            RoadFollow.signalLights(self, side)
        end
        tap.lightsOnly = false
        return false
    end
    if assist.engaged and not tap.wasEngaged then
        tap.lightsOnly = false           -- the assist took over during the press: it is steering, not a tap
    end
    if tap.lightsOnly and not tap.taken and tap.ms < RoadFollow.TAP_HOLD_MS then
        return false                     -- a short press with no assist driving: perhaps a tap for the lights; steering is the player's anyway
    end
    if tap.taken or tap.ms >= RoadFollow.TAP_HOLD_MS or not (tap.wasEngaged and assist.engaged and RoadFollow.TAP_SIGNALS) then
        if tap.signalled and tap.saved ~= nil then
            -- it was a hold, the player steers: the signal set on the press is taken back
            assist.intent = tap.saved.intent
            setTurnLights(self, tap.saved.intent or tap.saved.light)
            tap.signalled, tap.saved = false, nil
            log("steering hold: the signal set on the press is undone")
        end
        tap.taken = true
        return true
    end
    return false      -- still deciding between tap and hold: the assist drives on
end

function RoadFollow.assistTick(self, spec, axisForward, axisSide, doHandbrake, dt)
    local assist = spec.assist
    if steerInput(self, assist, axisSide, dt) then
        assist.steerGraceMs = RoadFollow.ASSIST_STEER_GRACE_MS
    elseif assist.steerGraceMs > 0 then
        assist.steerGraceMs = assist.steerGraceMs - dt
    end

    local speedKmh = self:getLastSpeed() or 0
    local sup = assist.sup
    if (assist.holdMs or 0) > 0 then
        assist.holdMs = assist.holdMs - dt
    end
    if assist.engaged and speedKmh >= RoadFollow.AUTOPILOT_MIN_KMH then
        assist.fastMs = RoadFollow.AUTOPILOT_MEMORY_MS
    elseif (assist.fastMs or 0) > 0 then
        assist.fastMs = assist.fastMs - dt
    end
    if assist.hazard and math.abs(axisForward) > RoadFollow.ASSIST_PEDAL_DEADZONE then
        assist.hazard = false
        setTurnLights(self, nil)
    end
    if assist.speedNoteMs ~= nil and assist.speedNoteMs > 0 then
        assist.speedNoteMs = assist.speedNoteMs - dt
    end
    if assist.engaged then
        updateIntent(self, assist, dt)
    end

    -- a controlled stop that has finished: cruise control off, say why, hand back
    if sup.stopping and speedKmh < RoadSupervisor.STOP_DONE_KMH and isCruiseOn(self)
        and axisSide == 0 and math.abs(axisForward) <= RoadFollow.ASSIST_PEDAL_DEADZONE and not doHandbrake then
        local why = sup.reason or "stopped"
        self:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF, true)
        showMessage("Road assist stopped the vehicle: " .. why)
        assist.status = "stopped: " .. why
        disengage(assist, "stopped: " .. why)
        return false
    end

    local reason = nil
    if not isCruiseOn(self) then
        reason = "cruise control off"
    elseif doHandbrake then
        reason = "handbrake"
    elseif math.abs(axisForward) > RoadFollow.ASSIST_PEDAL_DEADZONE then
        reason = "pedal"
    elseif assist.steerGraceMs > 0 then
        reason = "player steering"
    elseif (self.movingDirection or 1) < 0 then
        reason = "reversing"
    elseif speedKmh < (assist.engaged and RoadFollow.ASSIST_STAY_SPEED_KMH or RoadFollow.ASSIST_MIN_SPEED_KMH)
        and not (assist.engaged and (assist.holdMs or 0) > 0) then
        if assist.engaged and (assist.askedKmh or 0) >= RoadFollow.STUCK_ASK_KMH then
            -- standing still although the assist is asking for speed: not "too slow" (that would hand back to plain
            -- cruise control, which keeps pushing into whatever it is) but stuck: counted, then stopped properly
            assist.stuckMs = (assist.stuckMs or 0) + dt
        else
            reason = "too slow"
        end
    end
    if speedKmh >= RoadFollow.ASSIST_STAY_SPEED_KMH then
        assist.stuckMs = 0
    end
    if reason ~= nil then
        assist.status = reason
        disengage(assist, reason)
        return false
    end

    assist.scanMs = assist.scanMs + dt
    if assist.scanMs >= RoadFollow.CHECK_INTERVAL_MS then
        local elapsed = assist.scanMs
        assist.scanMs = 0
        local result, needText = self:scanRoadAhead(true)
        local good = result ~= nil and result.valid and not result.openGround
            and (#result.points >= RoadFollow.ASSIST_MIN_POINTS or (result.obstacle ~= nil and #result.points >= 2))
            and (result.capturing or math.abs(result.offset or 0) <= RoadFollow.ASSIST_MAX_OFFSET)
        if not good and result ~= nil and result.valid and not result.openGround and not result.capturing and assist.engaged
            and #result.points >= RoadFollow.ASSIST_MIN_POINTS and math.abs(result.offset or 0) <= RoadFollow.ASSIST_MAX_OFFSET_ON_ROAD then
            -- the middle found is a few metres off, but the map says the vehicle is on road or trail right here (a wide gravel
            -- track): the line is good, the vehicle is only well off its middle
            local ox, _, oz = getWorldTranslation(self:getAISteeringNode())
            local ohx, _, ohz = localDirectionToWorld(self:getAIDirectionNode(), 0, 0, 1)
            if groundUnder(ox, oz, ohx, ohz, nil) == true then
                good = true
            end
        end
        if good then
            assist.status = nil
            assist.goodScans = assist.goodScans + 1
            assist.badMs = 0
            assist.holdTravel = 0
            assist.result = result
            if result.mode ~= "field" and assist.field ~= nil then
                assist.field = nil                       -- a road again (joined from the field): the course through the field is over
                log("field course over: back on a road")
            end
            if assist.intent ~= nil and result.turnDeg ~= nil then
                assist.intentTurnDeg = result.turnDeg
            end
            assist.modeLabel = (result.capturing and "joining " or "") .. RoadFollow.modeLabel(result)
            assist.groundFactor = groundFactorOf(result, self:getCruiseControlMaxSpeed())
            -- (the speed plan reads bends from a line smoothed over a long stretch: a metre of pixel jitter in the line is not a bend
            -- to slow down for; a line from a stored path is exact)
            assist.profile = RoadCenterline.curvatureProfile(result.mode == "path" and result.points
                or RoadCenterline.smoothPoints(RoadCenterline.despike(result.points, 3), 5))
            -- the road centre comes from 2 m pixels and jumps about a metre from scan to scan: steer by
            -- a smoothed line
            -- (a line from a stored path is exact, no pixel noise to smooth away, and smoothing would cut its bends)
            assist.smoothPoints = result.mode == "path" and result.points or RoadCenterline.steeringLine(result.points)
            if not assist.engaged and assist.goodScans >= RoadFollow.ASSIST_ENGAGE_SCANS then
                assist.engaged = true
                local ex, _, ez = getWorldTranslation(self:getAISteeringNode())
                log("assist on at %.0f %.0f, %s", ex, ez, tostring(assist.modeLabel))
            end
        else
            -- why not: shown on screen while cruise control is on, so it is clear what it sees
            if result == nil then
                assist.status = needText == "ROADFOLLOW_NEED_SCAN" and "no road data (run the map scan)" or "no road data"
            elseif not result.valid then
                assist.status = result.reason or "no road here"
            elseif result.openGround then
                assist.status = "open ground"
            elseif #result.points < RoadFollow.ASSIST_MIN_POINTS then
                assist.status = "road too short ahead"
            else
                assist.status = "too far off the road's middle"
            end
            assist.goodScans = 0
            -- open ground that the map calls road all round (a wide gravel apron, a yard, a forest-edge clearing): there is no
            -- middle to find, but the road is there. Straight on at a moderate speed, for a limited distance.
            local holding = false
            if RoadFollow.OPEN_HOLD and assist.engaged and result ~= nil and result.valid and result.openGround
                and (assist.holdTravel or 0) < RoadFollow.OPEN_HOLD_MAX_M then
                local hx0, _, hz0 = localDirectionToWorld(self:getAIDirectionNode(), 0, 0, 1)
                local vx0, _, vz0 = getWorldTranslation(self:getAISteeringNode())
                local onRoad = groundUnder(vx0, vz0, hx0, hz0, nil)
                if onRoad == true then
                    holding = true
                    local points = {}
                    for i = 0, 15 do
                        points[#points + 1] = { vx0 + hx0 * 2 * i, vz0 + hz0 * 2 * i }
                    end
                    assist.result = { valid = true, points = points, found = #points, ends = false, junction = false, mode = "hold",
                        openGround = true, holding = true, roadWidth = result.roadWidth or 8, offset = 0 }
                    assist.smoothPoints = points
                    assist.profile = {}
                    assist.modeLabel = "open ground: straight on"
                    assist.groundFactor = 1
                    assist.holdTravel = (assist.holdTravel or 0) + speedKmh / 3.6 * elapsed / 1000
                end
            end
            if holding then
                assist.badMs = 0
            -- standing at a junction's stop line, the map may call the place open ground: that is not a lost road
            elseif assist.engaged and (assist.holdMs or 0) > 0 and speedKmh < 3 then
                assist.badMs = 0
            else
                assist.badMs = assist.badMs + elapsed
            end
            if assist.engaged and assist.badMs >= RoadFollow.ASSIST_HOLD_MS then
                -- autopilot: at speed the supervisor decides (it stops the vehicle after a second);
                -- slowly, or with the autopilot off, a lost road is simply handed back to plain cruise
                if not (RoadFollow.AUTOPILOT and (speedKmh >= RoadFollow.AUTOPILOT_MIN_KMH or (assist.fastMs or 0) > 0)) then
                    disengage(assist, "no road ahead")
                end
            end
        end
    end
    return assist.engaged and assist.result ~= nil
end

-- The game's collision check for AI vehicles (what slows a helper for a vehicle or object in front of it), used
-- here for the assisted drive as well. Everything is protected: when it does not work without a helper job,
-- it is switched off for this vehicle with one log line and the assist carries on without it.
-- Returns the speed it allows (km/h, math.huge = no limit) and whether it holds the vehicle at zero.
local function collisionLimit(self, assist, dt, vX, vY, vZ)
    if not RoadFollow.USE_COLLISION_HANDLER or assist.collisionBroken then
        return math.huge, false
    end
    local ok, speed = pcall(function()
        if assist.collision == nil then
            assist.collision = AIDriveStrategyRoadFollowCollision.new({})
            assist.collision:setAIVehicle(self)
        end
        assist.collision:update(dt)
        local _, _, _, limit = assist.collision:getDriveData(dt, vX, vY, vZ)
        return limit
    end)
    if not ok then
        assist.collisionBroken = true
        assist.collision = nil
        log("collision check unavailable for %s (%s): the assist goes on without it", tostring(self:getName()), tostring(speed))
        return math.huge, false
    end
    if type(speed) ~= "number" then
        return math.huge, false
    end
    return speed, speed <= 0
end

-- ===== the vehicle ahead =====
local function leadMask()
    local mask = 0
    if CollisionFlag ~= nil then
        for _, name in ipairs({ "TRAFFIC_VEHICLE", "VEHICLE", "DYNAMIC_OBJECT" }) do
            if CollisionFlag[name] ~= nil then
                mask = mask + CollisionFlag[name]
            end
        end
    end
    return mask
end

local leadTarget = { best = math.huge }
function leadTarget:rayCallback(actorId, x, y, z, distance)
    if distance < 0.2 then
        return true
    end
    local objects = g_currentMission ~= nil and g_currentMission.nodeToObject or nil
    local object = objects ~= nil and objects[actorId] or nil
    if object ~= nil and object.getRootVehicle ~= nil and object:getRootVehicle() == self.root then
        return true                               -- this vehicle's own parts and implements
    end
    if object ~= nil and RoadLead.isCarriedBy(object, self.root) then
        return true                               -- ... and what it carries
    end
    if distance < self.best then
        self.best = distance
    end
    return true
end

-- Every LEAD_INTERVAL_MS: cast rays along the line ahead (frontOverhang is defined further down, so look it up late)
local function scanLead(self, assist, points, vX, vY, vZ, hx, hz, speedMs, dt, overhang)
    if not RoadFollow.DETECT_VEHICLES or raycastAll == nil or assist.leadBroken then
        return
    end
    assist.leadMs = (assist.leadMs or 0) + dt
    if assist.leadMs < RoadFollow.LEAD_INTERVAL_MS then
        return
    end
    local elapsed = assist.leadMs
    assist.leadMs = 0
    local ok, err = pcall(function()
        local ox, oz = vX + hx * (overhang + 0.3), vZ + hz * (overhang + 0.3)
        local segs = RoadLead.segments(points, ox, oz, hx, hz, RoadLead.range(speedMs))
        leadTarget.root = self:getRootVehicle()
        local mask = leadMask()
        local gap = nil
        for _, seg in ipairs(segs) do
            local dx, dz = (seg.bx - seg.ax) / seg.length, (seg.bz - seg.az) / seg.length
            local best = math.huge
            for _, lateral in ipairs(RoadLead.LATERAL) do
                local sx, sz = seg.ax - dz * lateral, seg.az + dx * lateral
                local y = getTerrainHeightAtWorldPos(g_terrainNode, sx, vY, sz) + RoadLead.RAY_HEIGHT
                leadTarget.best = math.huge
                raycastAll(sx, y, sz, dx, 0, dz, seg.length + 1, "rayCallback", leadTarget, mask)
                best = math.min(best, leadTarget.best)
            end
            if best < math.huge then
                gap = seg.from + best - 0.3
                break
            end
        end
        assist.leadState = assist.leadState or {}
        local vLead = RoadLead.track(assist.leadState, gap, speedMs, elapsed)
        assist.lead = gap ~= nil and { gap = math.max(0, gap), vLead = vLead } or nil
    end)
    if not ok then
        assist.leadBroken = true
        assist.lead = nil
        log("vehicle detection unavailable (%s): the assist goes on without it", tostring(err))
    end
end

-- Every LEAD_INTERVAL_MS while a junction is ahead: rays along the cross road, each way, from the junction's mouth. Keeps
-- assist.cross = { left = state, right = state } (RoadLead.trackCross) and assist.crossHoldMs: above 0 = give way.
local function scanCross(self, assist, points, mouthDistance, intent, vY, dt)
    assist.cross = assist.cross or { left = {}, right = {} }
    if not RoadFollow.GIVE_WAY or not RoadFollow.DETECT_VEHICLES or raycastAll == nil or assist.leadBroken then
        assist.crossHoldMs = 0
        return
    end
    if mouthDistance == nil or points == nil or #points < 2 or mouthDistance > RoadFollow.CROSS_ACTIVE_RANGE then
        RoadLead.trackCross(assist.cross.left, nil, dt)
        RoadLead.trackCross(assist.cross.right, nil, dt)
        assist.crossHoldMs = math.max(0, (assist.crossHoldMs or 0) - dt)
        assist.crossMs = 0
        return
    end
    assist.crossMs = (assist.crossMs or 0) + dt
    assist.crossHoldMs = math.max(0, (assist.crossHoldMs or 0) - dt)
    if assist.crossMs < RoadFollow.LEAD_INTERVAL_MS then
        return
    end
    local elapsed = assist.crossMs
    assist.crossMs = 0
    local ok, err = pcall(function()
        -- the mouth is on the straight run of the line (its start direction), not on the arc of a turn: from there the rays
        -- run along the cross road, across the stem
        local n = #points
        local lx, lz = points[math.min(3, n)][1] - points[1][1], points[math.min(3, n)][2] - points[1][2]
        local length = math.sqrt(lx * lx + lz * lz)
        if length < 1e-6 then
            return
        end
        lx, lz = lx / length, lz / length
        local mx, mz = points[1][1] + lx * mouthDistance, points[1][2] + lz * mouthDistance
        local leftX, leftZ, rightX, rightZ = RoadLead.crossDirections(lx, lz)
        leadTarget.root = self:getRootVehicle()
        local mask = leadMask()
        local threat = false
        for _, side in ipairs(RoadLead.crossSides(intent)) do
            local dirX, dirZ = leftX, leftZ
            if side == "right" then
                dirX, dirZ = rightX, rightZ
            end
            local best = math.huge
            for _, offset in ipairs(RoadLead.CROSS_OFFSETS) do
                local ox, oz = mx + lx * offset, mz + lz * offset
                local y = getTerrainHeightAtWorldPos(g_terrainNode, ox, vY, oz) + RoadLead.RAY_HEIGHT
                leadTarget.best = math.huge
                raycastAll(ox, y, oz, dirX, 0, dirZ, RoadLead.CROSS_RANGE, "rayCallback", leadTarget, mask)
                best = math.min(best, leadTarget.best)
            end
            local state = assist.cross[side]
            RoadLead.trackCross(state, best < math.huge and best or nil, elapsed)
            if RoadLead.crossThreat(state) then
                threat = true
            end
        end
        if threat then
            assist.crossHoldMs = RoadLead.CROSS_CLEAR_MS
        end
    end)
    if not ok then
        assist.leadBroken = true
        assist.crossHoldMs = 0
        log("cross traffic detection unavailable (%s): the assist goes on without it", tostring(err))
    end
end

-- What the map says about the ground right under the vehicle and a little way ahead: onRoad = road or trail
-- within 2.4 m either side of the vehicle's position; roadAhead = road or trail 6 or 10 m ahead along its
-- heading. nil, nil when the map cannot say (no scan data, or the line is a map spline: a spline is a
-- road by definition, whatever the paint layers hold there).
groundUnder = function(vX, vZ, hx, hz, result)
    if result ~= nil and (result.kind == "spline" or result.mode == "field") then
        return nil, nil
    end
    local tracer = getTracer()
    if tracer == nil or tracer.hasDrivableData == nil or not tracer.hasDrivableData() then
        return nil, nil
    end
    local sample = makeSampler()
    if sample == nil then
        return nil, nil
    end
    local function any(x, z)
        return (sample(x, z) or 0) ~= 0
    end
    local nx, nz = -hz, hx
    -- (3.6 m to each side: a track of two wheel ruts with a grass hump between them has no worn ground under its own middle)
    local onRoad = any(vX, vZ) or any(vX + nx * 1.2, vZ + nz * 1.2) or any(vX - nx * 1.2, vZ - nz * 1.2)
        or any(vX + nx * 2.4, vZ + nz * 2.4) or any(vX - nx * 2.4, vZ - nz * 2.4)
        or any(vX + nx * 3.6, vZ + nz * 3.6) or any(vX - nx * 3.6, vZ - nz * 3.6)
    local roadAhead = any(vX + hx * 6, vZ + hz * 6) or any(vX + hx * 10, vZ + hz * 10)
    return onRoad, roadAhead
end

-- One frame of assisted driving: the base game's own drive-to-point, aimed down the road, at the
-- speed the cruise control is set to (lower in a bend).
-- How far the front of the vehicle is ahead of its steering node (the point the line is measured from), so that a stop
-- line is kept by the front bumper and not by the middle of the tractor.
local function frontOverhang(vehicle)
    local ok, value = pcall(function()
        local size = vehicle.size
        local sx, sy, sz = getWorldTranslation(vehicle:getAISteeringNode())
        local _, _, localZ = worldToLocal(vehicle.rootNode, sx, sy, sz)
        return (size.lengthOffset or 0) + (size.length or 0) / 2 - localZ
    end)
    if ok and type(value) == "number" then
        return math.max(0, math.min(8, value))
    end
    return RoadFollow.DEFAULT_FRONT_OVERHANG
end

-- Steer by curvature: the wheels are put straight at the curvature wanted (the base game's own helper), no waiting for the
-- steering to catch up. kappa is + for a left turn (like the aim point's local x). The helper's own sign is the other way
-- round (it is not used with a sign anywhere I can read), so the first real steering input is checked: when the wheel went
-- the wrong way, the sign is flipped for good (one tick of wrong steering at most).
local function steerAlongCurvature(self, assist, dt, kappa, maxSpeed)
    if assist.curvatureSign == nil then
        assist.curvatureSign = -1
    end
    local ok, err = pcall(AIVehicleUtil.driveAlongCurvature, self, dt, assist.curvatureSign * kappa, maxSpeed, 1)
    if not ok then
        assist.curvatureBroken = true
        log("curvature steering unavailable (%s): driving to the aim point instead", tostring(err))
        return false
    end
    if not assist.curvatureChecked and math.abs(kappa) > 0.004 and type(self.rotatedTime) == "number" and math.abs(self.rotatedTime) > 1e-4 then
        if self.rotatedTime * kappa < 0 then
            assist.curvatureSign = -assist.curvatureSign
            log("curvature steering: the wheel went the wrong way, sign flipped")
            pcall(AIVehicleUtil.driveAlongCurvature, self, dt, assist.curvatureSign * kappa, maxSpeed, 1)
        end
        assist.curvatureChecked = true
    end
    return true
end


-- Understeer: at speed the vehicle turns less than the wheels ask for (tyre slip). The yaw rate it really makes is compared
-- with the one asked for (both smoothed over about half a second); the shortfall slowly raises `understeerU`, and the curvature
-- asked for is multiplied by 1 + U * v^2 (the classic understeer gradient: the effect grows with the square of the speed).
-- kappa: the curvature wanted (+ left). Returns the multiplier to ask with.
local function understeerGain(self, assist, dt, vX, vY, vZ, hx, hz, speedMs, kappa)
    if not RoadFollow.UNDERSTEER_LEARN then
        return 1
    end
    local u = assist.understeerU or 0
    local seconds = dt / 1000
    if assist.prevHx ~= nil and seconds > 0 and seconds < 0.2 then
        -- how far it has turned since the last tick, + = to the left, read in the vehicle's own frame: the old heading seen from
        -- the vehicle now points to the RIGHT of where it looks when it has turned left (the vehicle's local x is its left)
        local lateral, _, ahead = worldToLocal(self:getAISteeringNode(), vX + assist.prevHx * 10, vY, vZ + assist.prevHz * 10)
        local yaw = math.atan2(-lateral, ahead) / seconds
        local a = 1 - math.exp(-dt / 500)
        assist.yawF = (assist.yawF or yaw) + (yaw - (assist.yawF or yaw)) * a
        assist.askedYawF = (assist.askedYawF or kappa * speedMs) + (kappa * speedMs - (assist.askedYawF or kappa * speedMs)) * a
        -- only in a steady turn: while the curvature is still changing the vehicle's own lag would read as understeer
        local slow = (assist.kappaSlow or kappa) + (kappa - (assist.kappaSlow or kappa)) * (1 - math.exp(-dt / 1500))
        assist.kappaSlow = slow
        local steady = math.abs(kappa - slow) <= 0.15 * math.abs(slow) + 0.0003
        if steady and speedMs >= RoadFollow.UNDERSTEER_MIN_SPEED and math.abs(assist.askedYawF) >= RoadFollow.UNDERSTEER_MIN_KAPPA * speedMs
            and not assist.saturated and (assist.understeerWarm or 0) > 1500 then
            local ratio = assist.yawF / assist.askedYawF                      -- made / asked (the gain is in what was asked)
            local shortfall = math.max(-0.5, math.min(0.5, 1 - ratio))
            u = u + RoadFollow.UNDERSTEER_RATE * shortfall / (speedMs * speedMs) * seconds
            u = math.max(0, math.min((RoadFollow.UNDERSTEER_MAX_GAIN - 1) / (speedMs * speedMs + 1e-6), u))
            assist.understeerU = u
            assist.understeerRatio = ratio
        end
    end
    assist.understeerWarm = (assist.understeerWarm or 0) + dt
    assist.prevHx, assist.prevHz = hx, hz
    return math.min(RoadFollow.UNDERSTEER_MAX_GAIN, 1 + u * speedMs * speedMs)
end


-- What the speed plan counts on, from the vehicle's top speed (a car that tops out at 180 km/h brakes harder and holds a bend better than a tractor
-- that tops out at 53): braking, the sideways acceleration taken in a bend, the most that may ever be asked, and what the steering is allowed to demand.
function RoadFollow.vehicleLimits(vehicle)
    local cruise = vehicle.spec_drivable ~= nil and vehicle.spec_drivable.cruiseControl or nil
    local top = cruise ~= nil and type(cruise.maxSpeed) == "number" and cruise.maxSpeed or 50
    local extra = math.max(0, top - 50)
    local brake = math.max(RoadFollow.PLAN_BRAKE_MIN, math.min(RoadFollow.PLAN_BRAKE_MAX, RoadFollow.PLAN_BRAKE_MIN + extra * RoadFollow.PLAN_BRAKE_PER_KMH))
    local lateral = math.min(RoadFollow.PLAN_LATERAL_MAX, RoadCenterline.LATERAL_ACCEL + extra * RoadFollow.PLAN_LATERAL_PER_KMH)
    local hard = math.min(RoadFollow.PLAN_HARD_MAX, RoadCenterline.HARD_LATERAL_ACCEL + extra * RoadFollow.PLAN_LATERAL_PER_KMH)
    local steer = math.max(RoadFollow.STEER_LATERAL_ACCEL, hard + 1.0)
    return brake, lateral, hard, steer
end

-- The far look: the road followed a long way ahead (RoadMapper.walkAhead), its bends kept for the speed plan. assist.far = { profile, odo, points }.
local function farLookUpdate(assist, result, x, z, hx, hz, speedKmh, dt)
    if not RoadFollow.FAR_LOOK or RoadMapper == nil or result.mode ~= "auto" or speedKmh < RoadFollow.FAR_LOOK_MIN_KMH then
        assist.far = nil
        return
    end
    assist.farMs = (assist.farMs or 0) + dt
    if assist.far ~= nil and assist.farMs < RoadFollow.FAR_LOOK_MS then
        return
    end
    assist.farMs = 0
    local sample = makeSampler()
    if sample == nil then
        return
    end
    local length = math.max(80, math.min(RoadFollow.FAR_LOOK_MAX, speedKmh / 3.6 * RoadFollow.FAR_LOOK_SECONDS))
    local walk = RoadMapper.walkAhead(sample, x, z, hx, hz, length, RoadFollow.FAR_LOOK_STEP)
    if #walk.points < 6 then
        assist.far = nil
        return
    end
    local line = RoadMapper.farLine(walk.points)
    assist.far = { profile = RoadCenterline.curvatureProfile(line, RoadFollow.FAR_LOOK_WINDOW), odo = assist.odometer or 0, points = line, ending = walk.ending }
end

function RoadFollow.assistDrive(self, spec, dt)
    local assist = spec.assist
    local result = assist.result
    local vX, vY, vZ = getWorldTranslation(self:getAISteeringNode())
    local hx, _, hz = localDirectionToWorld(self:getAIDirectionNode(), 0, 0, 1)
    local speedKmh = self:getLastSpeed() or 0
    local speedMs = speedKmh / 3.6
    local roadLost = assist.badMs >= RoadFollow.ASSIST_HOLD_MS

    -- the supervisor: where is the vehicle against the line, where will it be in a second or two
    local y, sinPsi, cosPsi = nil, nil, nil
    if not roadLost then
        y, sinPsi, cosPsi = RoadSupervisor.pose(assist.smoothPoints or result.points, vX, vZ, hx, hz)
    end
    local onRoad, roadAhead = groundUnder(vX, vZ, hx, hz, result)
    local collisionKmh, held = collisionLimit(self, assist, dt, vX, vY, vZ)
    if held and speedKmh < 1 then
        assist.blockedMs = (assist.blockedMs or 0) + dt
    else
        assist.blockedMs = 0
    end
    -- held up by a vehicle ahead (last scan's lead): after a while, stop for good
    local lastLead = assist.lead
    if lastLead ~= nil and RoadLead.allowedSpeed(lastLead.gap, lastLead.vLead) <= 0.03 and speedKmh < 1 then
        assist.leadBlockedMs = (assist.leadBlockedMs or 0) + dt
    else
        assist.leadBlockedMs = 0
    end
    local decision = RoadSupervisor.update(assist.sup, {
        y = y or 0, sinPsi = sinPsi or 0, cosPsi = cosPsi, limit = RoadSupervisor.limitFor(result.roadWidth),
        speedMs = speedMs, capturing = result.capturing == true, saturated = assist.saturated,
        roadLostMs = RoadFollow.AUTOPILOT and assist.badMs or 0, hasLine = y ~= nil, autopilot = (assist.fastMs or 0) > 0,
        onRoad = onRoad, roadAhead = roadAhead,
        obstacleDistance = result.obstacle ~= nil and math.max(0, result.obstacle.d) or nil,
        blockedMs = math.max(assist.blockedMs or 0, assist.leadBlockedMs or 0), stuckMs = assist.stuckMs or 0,
    }, dt)
    if decision.level ~= assist.lastLevel then
        assist.lastLevel = decision.level
        if decision.level == 2 then
            -- a stop the assist decided on: hazard lights, until the player gives the pedal again
            assist.hazard = true
            assist.intent = nil
            setTurnLights(self, "hazard")
            blackboxWrite(assist, "STOP " .. tostring(decision.reason))      -- always: a stop is the case worth reading afterwards
            log("supervisor: STOP (%s): y %.2f m, speed %.1f km/h, on road %s, road ahead %s, mode %s; last scan problem: %s; line %d points, offset %s%s",
                tostring(decision.reason), y or 0, speedKmh, tostring(onRoad), tostring(roadAhead), tostring(assist.modeLabel),
                tostring(assist.status), #result.points, tostring(result.offset),
                result.obstacle ~= nil and string.format("; obstacle %.0f m ahead: %s%s", result.obstacle.d or 0, tostring(result.obstacleKind or "kind not found"),
                    result.obstacleX ~= nil and string.format(" at %.0f %.0f", result.obstacleX, result.obstacleZ) or "") or "")
        elseif decision.level == 1 then
            log("supervisor: correcting: y %.2f m, heading %.1f deg off, speed %.1f km/h, on road %s", y or 0, math.deg(math.asin(math.max(-1, math.min(1, sinPsi or 0)))), speedKmh, tostring(onRoad))
        end
    end

    -- weaving from side to side along the line: calm it (a longer lookahead, a slower filter, a share of
    -- the aim from the general direction of the last few seconds)
    local severity = 0
    if y ~= nil then
        severity = RoadMeander.update(assist.meander, dt, y, vX, vZ)
    end
    local lookGain, filterGain, trackBlend = RoadMeander.damping(severity)
    if (severity > 0.3) ~= (assist.meandering == true) then
        assist.meandering = severity > 0.3
        log("meander: %s (severity %.2f, %d side changes, %.1f m wide)", assist.meandering and "weaving, calming" or "steady again",
            severity, assist.meander.crossings or 0, assist.meander.amplitude or 0)
    end

    -- the aim point: on the smoothed line, ahead by the lookahead (shorter while correcting)
    local lookahead = math.max(RoadFollow.LOOKAHEAD_MIN, speedMs * RoadFollow.LOOKAHEAD_SECONDS) * lookGain
    if decision.level == 1 then
        lookahead = lookahead * 0.7
    end
    -- in a tight bend the aim point is closer, so the line is followed round it and not cut across it
    local tightest = 0
    for _, entry in ipairs(assist.profile or {}) do
        if entry.d <= lookahead * 2 and entry.kappa > tightest then
            tightest = entry.kappa
        end
    end
    if tightest > 0.04 then
        -- (never under 1.5 s of driving: at speed a short aim distance makes the steering twitchy)
        lookahead = math.max(RoadFollow.LOOKAHEAD_TIGHT_MIN, speedMs * 1.5, math.min(lookahead, RoadFollow.LOOKAHEAD_CURVE_FACTOR / tightest))
    end
    local rawX, rawZ = RoadCenterline.pickTargetAveraged(assist.smoothPoints or result.points, vX, vZ, lookahead, RoadFollow.AIM_SPREAD)
    if trackBlend > 0 then
        local gx, gz = RoadMeander.direction(assist.meander)
        if gx ~= nil then
            rawX = rawX * (1 - trackBlend) + (vX + gx * lookahead) * trackBlend
            rawZ = rawZ * (1 - trackBlend) + (vZ + gz * lookahead) * trackBlend
        end
    end
    if roadLost then
        -- no line to trust: wheels straight while braking
        rawX, rawZ = vX + hx * RoadFollow.LOOKAHEAD_MIN, vZ + hz * RoadFollow.LOOKAHEAD_MIN
    end
    -- low-pass filter over time (dt in ms): a jump in the target becomes a gentle swing of the wheel
    if assist.tX == nil then
        assist.tX, assist.tZ = rawX, rawZ
    else
        local k = 1 - math.exp(-dt / (RoadFollow.TARGET_TIME_CONSTANT_MS * filterGain))
        assist.tX = assist.tX + (rawX - assist.tX) * k
        assist.tZ = assist.tZ + (rawZ - assist.tZ) * k
    end
    local tX, tZ = assist.tX, assist.tZ
    spec.target = { tX, tZ }

    -- speed: the bend (and, as autopilot, the end of the road), the ground, the speed limit
    local cruiseSpeed = self:getCruiseControlMaxSpeed()
    local bendFloor = result.capturing and 0 or RoadFollow.ASSIST_BEND_FLOOR
    -- every bend on the line limits the speed now to what can still be braked down to it in time; and as
    -- autopilot the end of the road is a bend too
    local brake, lateral, hard, steerAccel = RoadFollow.vehicleLimits(self)
    local bendSpeed = RoadCenterline.profileSpeed(assist.profile or {}, cruiseSpeed, bendFloor, brake, lateral, hard)
    -- far ahead (fast, on a map-picture road): the bends beyond the full scan's reach, braked for in time
    assist.odometer = (assist.odometer or 0) + speedMs * dt / 1000
    farLookUpdate(assist, result, vX, vZ, hx, hz, speedKmh, dt)
    if assist.far ~= nil then
        local travelled = assist.odometer - assist.far.odo
        local ahead = {}
        for _, entry in ipairs(assist.far.profile) do
            local d = entry.d - travelled
            if d >= RoadFollow.FAR_LOOK_FROM then
                ahead[#ahead + 1] = { d = d, kappa = entry.kappa }
            end
        end
        bendSpeed = math.min(bendSpeed, RoadCenterline.profileSpeed(ahead, cruiseSpeed, bendFloor, brake, lateral, hard))
    end
    if (RoadFollow.AUTOPILOT and result.ends == true and not result.capturing) or result.obstacle ~= nil then
        bendSpeed = math.min(bendSpeed, RoadCenterline.endSpeed(RoadCenterline.length(result.points)))
    end
    -- a junction where the road ends (a T): without a turn signal, wait before it; a turn that is signalled is
    -- taken slowly, braking for it in time
    -- a T needs a road across the line's end: from the stored paths (a path that ends at another), or from the map
    -- picture only where one run spans the whole scan window; a patch of bare ground beside a track is not a crossing
    local atT = result.ends == true and (result.junctionEnd == true or result.crossingAt ~= nil)
        and not result.capturing and result.obstacle == nil and not result.turned
    assist.waiting = false
    local crossMouth, crossStop = nil, nil          -- where the cross road is along the line, and how far the stop line is
    if atT then
        local mouth = (result.junctionEnd and result.junctionAt or result.crossingAt or RoadCenterline.length(result.points)) - (result.junctionEnd and 4 or 0)
        local stopDistance = mouth - RoadFollow.JUNCTION_STOP_MARGIN - frontOverhang(self)
        crossMouth, crossStop = mouth, stopDistance
        local allowed = math.sqrt(2 * RoadCenterline.BRAKE_DECEL * math.max(0, stopDistance)) * 3.6
        bendSpeed = math.min(bendSpeed, allowed)
        assist.holdMs = RoadFollow.JUNCTION_HOLD_MS
        if allowed < 2 then
            bendSpeed = 0
            assist.waiting = speedKmh < 3
        end
    elseif result.turned or result.corner then
        local toTurn = RoadCenterline.turnStartDistance(result.points, 6) or 0
        crossMouth, crossStop = toTurn, toTurn - frontOverhang(self)
        local vt = RoadFollow.JUNCTION_TURN_KMH / 3.6
        bendSpeed = math.min(bendSpeed, math.sqrt(vt * vt + 2 * RoadCenterline.PROFILE_BRAKE * math.max(0, toTurn - 2)) * 3.6)
        assist.holdMs = RoadFollow.JUNCTION_HOLD_MS
    end
    -- cross traffic: before the turn (or the T) give way to what is coming along the road about to be entered; once the
    -- stop line cannot be reached any more by braking, the vehicle is committed and goes on
    assist.giveWay = false
    scanCross(self, assist, result.points, crossMouth, RoadFollow.getIntent(self), vY, dt)
    if crossMouth ~= nil and (assist.crossHoldMs or 0) > 0 then
        local stopDistance = math.max(0, crossStop or 0)
        local canStop = speedMs * speedMs <= 2 * RoadCenterline.BRAKE_DECEL * stopDistance + 1.0
        if canStop then
            assist.giveWay = true
            local allowed = math.sqrt(2 * RoadCenterline.BRAKE_DECEL * stopDistance) * 3.6
            bendSpeed = math.min(bendSpeed, allowed)
            assist.holdMs = RoadFollow.JUNCTION_HOLD_MS
            if allowed < 2 then
                bendSpeed = 0
                assist.waiting = speedKmh < 3
            end
        else
            assist.crossHoldMs = 0          -- committed (an amber light): keep going
        end
    end
    -- a vehicle ahead: follow at its speed, stop behind it
    scanLead(self, assist, assist.smoothPoints or result.points, vX, vY, vZ, hx, hz, speedMs, dt, frontOverhang(self))
    local lead = assist.lead
    local leadKmh = math.huge
    assist.following = false
    if lead ~= nil then
        leadKmh = RoadLead.allowedSpeed(lead.gap, lead.vLead) * 3.6
        assist.following = leadKmh < cruiseSpeed * (assist.groundFactor or 1)
    end
    local ground = assist.groundFactor or 1
    local maxSpeed = math.min(bendSpeed, cruiseSpeed * ground, leadKmh)
    if result.holding then
        maxSpeed = math.min(maxSpeed, RoadFollow.OPEN_HOLD_KMH)
    end
    -- getSpeedLimit returns the limit and a flag: take only the limit
    local speedLimit = self:getSpeedLimit(true)
    if type(speedLimit) == "number" then
        maxSpeed = math.min(maxSpeed, speedLimit)
    end
    maxSpeed = math.min(maxSpeed, collisionKmh)
    -- is the ground what holds the speed down (and not a bend, a vehicle ahead, the machine's own limit ...)? only then the screen says "unstable underground"
    do
        local groundKmh = cruiseSpeed * ground
        local others = math.min(bendSpeed, leadKmh, collisionKmh, type(speedLimit) == "number" and speedLimit or math.huge,
            result.holding and RoadFollow.OPEN_HOLD_KMH or math.huge)
        assist.groundLimited = groundKmh < cruiseSpeed - 0.5 and groundKmh <= others + 0.5
    end
    local leadStop = leadKmh <= 0.1
    if lead ~= nil and leadKmh < 8 then
        assist.holdMs = RoadFollow.JUNCTION_HOLD_MS               -- queueing behind a vehicle is not "too slow": stay on, move off when it does
    end
    if collisionKmh > 0 and not ((atT or assist.giveWay) and bendSpeed <= 0) and not leadStop then
        maxSpeed = math.max(maxSpeed, RoadFollow.MIN_SPEED_KMH)
    else
        maxSpeed = 0
    end
    if decision.level == 1 and decision.speedShare ~= nil then
        -- one reduction when the correcting starts, held while it lasts (not 30% of the CURRENT speed every frame, which is
        -- full braking all the way down to 8 km/h)
        assist.correctCapKmh = assist.correctCapKmh or math.max(8, speedKmh * decision.speedShare)
        maxSpeed = math.min(maxSpeed, assist.correctCapKmh)
    else
        assist.correctCapKmh = nil
    end
    if decision.stop or roadLost then
        maxSpeed = 0
    end

    -- steering authority: the aim point may not ask for more sideways acceleration than the speed allows
    local pX, _, pZ = worldToLocal(self:getAISteeringNode(), tX, vY, tZ)
    local v = math.max(speedMs, 3)
    local limitX = steerAccel * (pX * pX + pZ * pZ) / (2 * v * v)
    assist.saturated = math.abs(pX) > limitX
    pX = math.max(-limitX, math.min(limitX, pX))

    assist.boxMs = (assist.boxMs or 0) + dt
    if assist.boxMs >= RoadFollow.BLACKBOX_MS then
        assist.boxMs = 0
        blackboxRecord(assist, {
            t = g_time or 0, x = vX, z = vZ, hdg = math.deg(math.atan2(hx, -hz)) % 360, speed = speedKmh, ask = maxSpeed, bend = bendSpeed,
            pX = pX, pZ = pZ, y = y or 0, k = RoadCenterline.curvature(result.points), level = decision.level, points = #result.points,
            mode = assist.modeLabel or "?", intent = assist.intent,
            note = (assist.saturated and " SATURATED" or "") .. (atT and " T" or "") .. (result.turned and " turn" or "") .. (result.ends and " ends" or "") .. (result.obstacleKind ~= nil and string.format(" OBSTACLE %s at %.0f %.0f", result.obstacleKind, result.obstacleX, result.obstacleZ) or "")
                .. (assist.lead ~= nil and string.format(" LEAD %.0f m at %.0f km/h", assist.lead.gap, assist.lead.vLead * 3.6) or ""),
        })
    end
    assist.askedKmh = maxSpeed
    local steered = false
    if RoadFollow.CURVATURE_STEERING and AIVehicleUtil.driveAlongCurvature ~= nil and not assist.curvatureBroken then
        -- the curvature of the circle through the aim point (what driveToPoint would work out), its changes limited in rate
        local wanted = 2 * pX / math.max(pX * pX + pZ * pZ, 1e-6)
        if RoadFollow.FEEDFORWARD_STEERING and not roadLost then
            -- ... or, better: what the line needs a moment ahead, steered once (the line in the vehicle's own frame)
            local line = assist.smoothPoints or result.points
            local localLine = {}
            for i = 1, math.min(#line, RoadFollow.FF_LOCAL_POINTS) do
                local lx, _, lz = worldToLocal(self:getAISteeringNode(), line[i][1], vY, line[i][2])
                localLine[i] = { lx, lz }
            end
            -- weaving is the correction coming too hard for a vehicle that answers late: with the weave detected, the correction
            -- is made softer (a longer correction distance), so each swing is smaller than the last (the gain drops below
            -- what the vehicle's lag can stand)
            local ff, parts = RoadCenterline.steerCurvature(localLine, speedMs, {
                fbMin = 7 * lookGain,
                fbSeconds = RoadCenterline.STEER_FB_SECONDS * (1 + RoadFollow.WEAVE_SOFTEN * severity),
            })
            if ff ~= nil then
                local limitK = steerAccel / math.max(speedMs * speedMs, 9)
                assist.saturated = math.abs(ff) > limitK
                wanted = math.max(-limitK, math.min(limitK, ff))
                assist.ffParts = parts
                assist.ffRaw, assist.ffLimit = ff, limitK
            end
        end
        local step = RoadFollow.CURVATURE_RATE * dt / 1000
        local kappa = (assist.kappa or 0)
        kappa = kappa + math.max(-step, math.min(step, wanted - kappa))
        assist.kappa = kappa
        local gain = understeerGain(self, assist, dt, vX, vY, vZ, hx, hz, speedMs, kappa)
        assist.understeerGain = gain
        steered = steerAlongCurvature(self, assist, dt, kappa * gain, maxSpeed)
    end
    if not steered then
        AIVehicleUtil.driveToPoint(self, dt, 1, maxSpeed > 0, true, pX, pZ, maxSpeed)
    end

    if RoadFollow.debugDraw then
        assist.logMs = (assist.logMs or 0) + dt
        if assist.logMs >= RoadFollow.LOG_INTERVAL_MS then
            assist.logMs = 0
            local parts = assist.ffParts or {}
            log("assist (%s): speed %.1f km/h, asked %.1f (cruise %s, bend %.1f, ground x%.2f, limit %s), target pX %.2f pZ %.1f, y %.2f, line curvature %.4f, %d points, level %d%s | steering: cmd %.4f (line %.4f + correction %.4f) e %.2f m psi %.1f deg, %s, wheel %s, understeer gain %.2f (made/asked %.2f)",
                assist.modeLabel or "?", speedKmh, maxSpeed, tostring(cruiseSpeed), bendSpeed, ground, tostring(speedLimit), pX, pZ,
                y or 0, RoadCenterline.curvature(result.points), #result.points, decision.level, assist.saturated and " SATURATED" or "",
                assist.kappa or 0, parts.kff or 0, parts.kfb or 0, parts.e or 0, math.deg(parts.psi or 0), parts.fitted and "fitted over a long stretch" or "from the line itself",
                tostring(self.rotatedTime and string.format("%.3f", self.rotatedTime) or "?"), assist.understeerGain or 1, assist.understeerRatio or 0)
        end
    end
end

-- The mouse wheel as the speed knob of a real cruise control: up = faster, down = slower, in steps of
-- WHEEL_STEP_KMH snapped to multiples of the step, between 5 km/h and the vehicle's own cruise maximum.
-- Only while the assist is driving (the base game has its own keys for plain cruise control).
function RoadFollow.adjustSpeed(vehicle, direction)
    local step = RoadFollow.WHEEL_STEP_KMH
    if step <= 0 or vehicle == nil then
        return false
    end
    local spec = getSpec(vehicle)
    local drivable = vehicle.spec_drivable
    local cruise = drivable ~= nil and drivable.cruiseControl or nil
    if spec == nil or spec.assist == nil or not spec.assist.engaged or cruise == nil
        or vehicle.getCruiseControlMaxSpeed == nil or vehicle.setCruiseControlMaxSpeed == nil then
        return false
    end
    local current = vehicle:getCruiseControlMaxSpeed()
    if type(current) ~= "number" then
        return false
    end
    local ceiling = type(cruise.maxSpeed) == "number" and cruise.maxSpeed or math.huge
    local wanted = math.floor(current / step + 0.5) * step + direction * step
    wanted = math.max(5, math.min(ceiling, wanted))
    if wanted == current then
        return false
    end
    vehicle:setCruiseControlMaxSpeed(wanted)
    spec.assist.speedNote = wanted
    spec.assist.speedNoteMs = 1500
    return true
end

function RoadFollow.consoleSetWheelStep(self, kmh)
    local value = tonumber(kmh)
    if value ~= nil then
        RoadFollow.WHEEL_STEP_KMH = math.max(0, math.min(20, value))
    end
    return RoadFollow.WHEEL_STEP_KMH > 0
        and string.format("Road Follow: the mouse wheel changes the speed by %.0f km/h per notch while the assist drives", RoadFollow.WHEEL_STEP_KMH)
        or "Road Follow: mouse wheel speed control OFF"
end
addConsoleCommand("roadFollowWheel", "km/h per mouse wheel notch while the road assist drives (0 = off, default 5)", "consoleSetWheelStep", RoadFollow)

-- Overrides the base game's vehicle physics step (axisForward, axisSide, doHandbrake, dt). Anything
-- unexpected goes straight to the original.
function RoadFollow:updateVehiclePhysics(superFunc, ...)
    local axisForward, axisSide, doHandbrake, dt = ...
    local spec = getSpec(self)
    if not RoadFollow.assistEnabled or spec == nil or spec.isActive or not self.isServer or spec.assist.broken then
        return superFunc(self, ...)
    end
    if type(axisForward) ~= "number" or type(axisSide) ~= "number" or type(dt) ~= "number" then
        if not spec.assist.warned then
            spec.assist.warned = true
            log("assist disabled for %s: unexpected updateVehiclePhysics arguments (%s, %s, %s, %s)",
                tostring(self:getName()), type(axisForward), type(axisSide), type(doHandbrake), type(dt))
        end
        return superFunc(self, ...)
    end

    -- the game's own steering assist (field lanes) or an AI helper is driving this vehicle: theirs wins. The steering assist sets the wheel in its own
    -- override of this function, further down the chain, which our drive below would skip entirely.
    -- Also while the player has picked the steering assist (H) and a lane is ready here (the game then has generated its field course: state AVAILABLE,
    -- or ACTIVE once it steers): pressing cruise control then follows THAT lane, never a path this one thinks it has found.
    local steering = self.spec_aiAutomaticSteering
    local gameDrives = (self.getIsAIActive ~= nil and self:getIsAIActive()) or (steering ~= nil and steering.steeringEnabled == true)
    if not gameDrives and steering ~= nil and self.getAIAutomaticSteeringState ~= nil and AIAutomaticSteering ~= nil and AIAutomaticSteering.STATE ~= nil then
        local ok, state = pcall(self.getAIAutomaticSteeringState, self)
        gameDrives = ok and state ~= nil and state ~= AIAutomaticSteering.STATE.DISABLED
    end
    if gameDrives then
        if spec.assist.engaged then
            disengage(spec.assist, "the game's steering assist (a lane is selected) or an AI helper is driving")
        end
        return superFunc(self, ...)
    end

    if RoadFollow.assistTick(self, spec, axisForward, axisSide, doHandbrake == true, dt) then
        -- whatever goes wrong in here, the vehicle must not be left undriven: log it once, switch the
        -- assist off for this vehicle and run the original physics this frame
        local ok, err = pcall(RoadFollow.assistDrive, self, spec, dt)
        if ok then
            return
        end
        spec.assist.broken = true
        spec.assist.engaged = false
        log("assist switched off for %s after an error: %s", tostring(self:getName()), tostring(err))
    end
    return superFunc(self, ...)
end

function RoadFollow.consoleSetLane(self, metres)
    RoadFollow.laneOffset = tonumber(metres) or 0
    return string.format("Road Follow: keep %.1f m to the right of a path's line", RoadFollow.laneOffset)
end
addConsoleCommand("roadFollowLane", "Metres to the right of a stored path's line to drive (0 = on it)", "consoleSetLane", RoadFollow)

function RoadFollow.consoleSetTrailSpeed(self, factor)
    local value = tonumber(factor)
    if value ~= nil then
        RoadFollow.groundFactors.trail = math.max(0.1, math.min(1, value))
    end
    return string.format("Road Follow: worn trail / gravel allows %.0f%% of the cruise speed", RoadFollow.groundFactors.trail * 100)
end
addConsoleCommand("roadFollowTrailSpeed", "Share of the cruise speed on worn trail / gravel, 0.1 to 1", "consoleSetTrailSpeed", RoadFollow)

function RoadFollow.consoleSetOffroadSpeed(self, kmh)
    local value = tonumber(kmh)
    if value ~= nil then
        RoadFollow.OFFROAD_KMH = math.max(3, math.min(80, value))
    end
    return string.format("Road Follow: grass / fields / bare soil are driven at most %.0f km/h", RoadFollow.OFFROAD_KMH)
end
addConsoleCommand("roadFollowOffroadSpeed", "Most km/h asked for on grass, fields and bare soil (default 20)", "consoleSetOffroadSpeed", RoadFollow)

function RoadFollow.consoleToggleAutopilot()
    RoadFollow.AUTOPILOT = not RoadFollow.AUTOPILOT
    return "Road Follow autopilot (stop when the road is lost at speed, brake for the end of a road): " .. (RoadFollow.AUTOPILOT and "ON" or "OFF, a lost road is handed back to plain cruise")
end
addConsoleCommand("roadFollowAutopilot", "Stop when the road is lost at speed and brake for the end of a road (toggle)", "consoleToggleAutopilot", RoadFollow)

function RoadFollow.consoleToggleSignals()
    RoadFollow.MOUSE_SIGNALS = not RoadFollow.MOUSE_SIGNALS
    return "Road Follow: left / right mouse button as turn signals while the assist drives: " .. (RoadFollow.MOUSE_SIGNALS and "ON" or "OFF (the vehicle's own turn lights still count)")
end
addConsoleCommand("roadFollowSignals", "Left / right mouse button = turn signal while the road assist drives (toggle)", "consoleToggleSignals", RoadFollow)

function RoadFollow.consoleTogglePaths()
    RoadFollow.usePaths = not RoadFollow.usePaths
    return "Road Follow: stored paths (map splines, recorded drives) " .. (RoadFollow.usePaths and "ON" or "OFF, auto-detect only")
end
addConsoleCommand("roadFollowPaths", "Use stored paths (map splines, recorded drives) before auto-detect (toggle)", "consoleTogglePaths", RoadFollow)

function RoadFollow.consoleToggleAssist()
    RoadFollow.assistEnabled = not RoadFollow.assistEnabled
    return "Road Follow cruise assist: " .. (RoadFollow.assistEnabled and "ON" or "OFF")
end
addConsoleCommand("roadFollowAssist", "Switch the road assist for the cruise control on or off", "consoleToggleAssist", RoadFollow)

-- ===== debug preview =====
-- Console: roadFollowDebug. Draws the centre-line the follower would use (green = road, yellow =
-- it ends or meets open ground) while sitting in a vehicle, whether or not it is following.

local function drawResult(result, color)
    if result == nil or not result.valid then
        return
    end
    local points = result.points
    for i = 2, #points do
        local ax, az = points[i - 1][1], points[i - 1][2]
        local bx, bz = points[i][1], points[i][2]
        local ay = getTerrainHeightAtWorldPos(g_terrainNode, ax, 0, az) + 0.6
        local by = getTerrainHeightAtWorldPos(g_terrainNode, bx, 0, bz) + 0.6
        drawDebugLine(ax, ay, az, color[1], color[2], color[3], bx, by, bz, color[1], color[2], color[3], false)
    end
end

-- (debug) what each scan row saw: a line across the road from edge to edge, with a tick at the middle it chose.
-- green = road, yellow = trail, cyan = the road paint's own core (stone) found inside a wide stretch, red = very wide (open ground)
local function drawRows(result)
    if result == nil or result.rows == nil then
        return
    end
    for _, row in ipairs(result.rows) do
        local nx, nz = -row.dz, row.dx
        local ax, az = row.x + nx * row.from, row.z + nz * row.from
        local bx, bz = row.x + nx * row.to, row.z + nz * row.to
        local cx, cz = row.x + nx * row.centre, row.z + nz * row.centre
        local r, g, b = 0.1, 1.0, 0.2
        if row.core then
            r, g, b = 0.2, 0.9, 1.0
        elseif (row.to - row.from) > 12 then
            r, g, b = 1.0, 0.2, 0.2
        elseif row.class == 1 then
            r, g, b = 1.0, 0.9, 0.1
        end
        local ay = getTerrainHeightAtWorldPos(g_terrainNode, ax, 0, az) + 0.45
        local by = getTerrainHeightAtWorldPos(g_terrainNode, bx, 0, bz) + 0.45
        drawDebugLine(ax, ay, az, r, g, b, bx, by, bz, r, g, b, false)
        local cy = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz)
        drawDebugLine(cx, cy + 0.2, cz, 1, 1, 1, cx, cy + 1.6, cz, 1, 1, 1, false)
    end
end

function RoadFollow:onDraw(isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = getSpec(self)
    -- the gauge is the speedometer of the vehicle the player drives: there with cruise control off too (then only the speed, no
    -- set mark); never from a vehicle that is only carried or towed along
    local controlled = RoadFollow.getControlledVehicle()
    if isActiveForInputIgnoreSelection and spec.assist ~= nil and RoadFollow.assistEnabled and (controlled == nil or controlled == self) then
        local cruiseOn = isCruiseOn(self)
        local assist = spec.assist
        local kind = RoadHud.kindFor(assist)
        local label
        if kind == "stop" then
            label = "STOPPING: " .. tostring(assist.sup.reason)
        elseif kind == "correct" then
            label = "correcting  (" .. (assist.modeLabel or "?") .. ")"
        elseif kind == "ok" and assist.giveWay then
            label = "giving way: traffic coming"
        elseif kind == "ok" and assist.waiting then
            label = "junction: signal left or right to turn"
        elseif kind == "ok" and assist.following and assist.lead ~= nil then
            label = string.format("following traffic, %.0f m behind", assist.lead.gap)
        elseif kind == "ok" and assist.groundLimited == true and cruiseOn and type(assist.askedKmh) == "number" and assist.askedKmh > 0 then
            -- the ground is what holds the speed down (gravel, a worn trail, open ground): say so (only when it really is the binding limit)
            label = string.format("speed limit %d km/h - unstable underground", math.floor(assist.askedKmh + 0.5))
        elseif kind == "ok" then
            label = assist.modeLabel
            if label ~= nil and assist.speedNoteMs ~= nil and assist.speedNoteMs > 0 and assist.speedNote ~= nil then
                label = label .. string.format("   set %d km/h", assist.speedNote)
            end
        elseif assist.status ~= nil then
            label = "road assist: " .. assist.status
        end
        if not cruiseOn then
            label = nil                          -- plain driving: just the speedometer
        end
        local setKmh = cruiseOn and self.getCruiseControlMaxSpeed ~= nil and self:getCruiseControlMaxSpeed() or nil
        local topKmh = nil                       -- what the full arc stands for when no speed is set: the vehicle's own top speed
        if not cruiseOn and self.spec_drivable ~= nil and self.spec_drivable.cruiseControl ~= nil then
            topKmh = self.spec_drivable.cruiseControl.maxSpeed
        end
        -- a drawing error must not flood the log every frame: say it once and switch the gauge off
        local ok, err = pcall(RoadHud.draw, {
            speedKmh = self.getLastSpeed ~= nil and self:getLastSpeed() or 0,
            setKmh = setKmh,
            scaleKmh = topKmh,
            kind = kind,
            signal = assist.hazard and "hazard" or RoadFollow.getIntent(self),      -- the assist's signal, or the vehicle's own light (set by a tap with the assist off)
            timeMs = g_time,
            label = label,
        })
        if not ok then
            RoadHud.enabled = false
            print(string.format("[RoadFollow] HUD switched off after an error: %s (roadFollowHud switches it back on)", tostring(err)))
        end
    end
    if isActiveForInputIgnoreSelection then
        RoadFollow.drawRoadMap()
    end
    if RoadFollow.wantRows() and isActiveForInputIgnoreSelection then
        RoadFollow.drawDebugView(self, spec)
    end
    if RoadFollow.debugDraw and isActiveForInputIgnoreSelection then
        -- the state is visible on screen, so it is clear whether the lines are switched on
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(1, 0.9, 0.2, 1)
        renderText(0.02, 0.97, 0.014, "Road Follow debug lines ON (console: roadFollowDebug)")
        local a = spec.assist
        if a ~= nil and a.engaged then
            local parts = a.ffParts or {}
            renderText(0.02, 0.95, 0.012, string.format("steering cmd %.3f = line %.3f + correction %.3f   e %.2f m  psi %.1f deg  wheel %s",
                a.kappa or 0, parts.kff or 0, parts.kfb or 0, parts.e or 0, math.deg(parts.psi or 0), tostring(self.rotatedTime and string.format("%.2f", self.rotatedTime) or "?")))
            renderText(0.02, 0.935, 0.012, string.format("%s  asked %.0f km/h  %s%s", a.modeLabel or "?", a.askedKmh or 0, parts.fitted and "(line fitted over a long stretch)" or "(line itself)", a.saturated and "  SATURATED" or ""))
        end
        setTextColor(1, 1, 1, 1)
    end
end

-- The countdown of a timed view (started from the WAILA hub); runs while no menu is open. The lines themselves are drawn
-- from onDraw (RoadFollow.drawDebugView), which is where they are known to show.
function RoadFollow.updateDebugView(dt)
    if RoadFollow.debugSecondsLeft > 0 and not (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        RoadFollow.debugSecondsLeft = math.max(0, RoadFollow.debugSecondsLeft - dt / 1000)
    end
end


-- Is a debug option line a real way of its own: not the road's own line again (a left option along a road that bends left),
-- and not a scribble (a line that changes direction back and forth far more than it turns).
local function distanceToLine(points, x, z)
    local best = math.huge
    for i = 2, #points do
        local ax, az, bx, bz = points[i - 1][1], points[i - 1][2], points[i][1], points[i][2]
        local sx, sz = bx - ax, bz - az
        local lengthSq = sx * sx + sz * sz
        local t = lengthSq > 1e-9 and math.max(0, math.min(1, ((x - ax) * sx + (z - az) * sz) / lengthSq)) or 0
        best = math.min(best, math.sqrt((x - (ax + sx * t)) ^ 2 + (z - (az + sz * t)) ^ 2))
    end
    return best
end

local function optionIsWay(option, mainPoints)
    local points = option.points
    if points == nil or #points < 4 then
        return false
    end
    -- scribble: total change of direction against the net turn
    local total, first, last = 0, nil, nil
    local previous = nil
    for i = 2, #points do
        local heading = math.atan2(points[i][2] - points[i - 1][2], points[i][1] - points[i - 1][1])
        if previous ~= nil then
            local d = heading - previous
            d = math.atan2(math.sin(d), math.cos(d))
            total = total + math.abs(d)
            last = (last or 0) + d
        end
        previous = heading
    end
    if total > math.abs(last or 0) + math.rad(RoadFollow.DEBUG_OPTION_SCRIBBLE_DEG) then
        return false
    end
    -- the road's own line again: most of the way beyond the first stretch lies within a couple of metres of the main line
    if mainPoints ~= nil and #mainPoints >= 2 then
        local near, count = 0, 0
        for i = 6, #points do
            count = count + 1
            if distanceToLine(mainPoints, points[i][1], points[i][2]) <= RoadFollow.DEBUG_OPTION_SAME_M then
                near = near + 1
            end
        end
        if count > 0 and near / count >= 0.6 then
            return false
        end
    end
    return true
end

-- Draws what the scan sees from this vehicle: the rows, the line, the line the assist steers by. Called from onDraw.
function RoadFollow.drawDebugView(self, spec)
    local result
    local assistOn = spec.assist ~= nil and spec.assist.engaged and spec.assist.result ~= nil
    if assistOn then
        result = spec.assist.result                 -- exactly what the assist is steering by
    else
        -- a preview: re-read at the check interval, from where the vehicle is
        spec.previewTimer = (spec.previewTimer or 0) + (g_currentDt or 16)
        if spec.previewResult == nil or spec.previewTimer >= RoadFollow.CHECK_INTERVAL_MS then
            spec.previewTimer = 0
            spec.previewResult = self:scanRoadAhead()
        end
        result = spec.previewResult
    end
    if result ~= nil then
        local color = (result.ends or result.junction) and { 1, 0.9, 0.1 } or { 0.1, 1, 0.2 }
        drawResult(result, color)
        -- the ways at a junction, all drawn: the one chosen (by the signal; none out: straight on) is green, the others red; at a
        -- T with no signal nothing is chosen yet and the two ways to turn are white. Each way is read a little further out than
        -- the assist reads (time to react with the signal), kept for a second when a read misses it (no flashing).
        spec.optionClock = (spec.optionClock or 0) + (g_currentDt or 16)
        spec.optionTimer = (spec.optionTimer or 0) + (g_currentDt or 16)
        spec.optionLines = spec.optionLines or {}
        spec.optionSeen = spec.optionSeen or {}
        local signalled = RoadFollow.getIntent(self)
        if spec.optionTimer >= 200 then
            spec.optionTimer = 0
            local speedMs = (self:getLastSpeed() or 0) / 3.6
            local look = math.max(RoadFollow.DEBUG_OPTION_REACH, math.min(120, speedMs * 6))
            local ways = { "left", "right", "straight" }
            for _, way in ipairs(ways) do
                local option = self:scanRoadAhead(false, way, look)
                local good = option ~= nil and option.valid
                if good and way ~= "straight" then
                    good = option.turned == true and (option.turnDeg or option.sharpestCorner or 0) >= RoadFollow.DEBUG_OPTION_MIN_DEG
                    if good then
                        local view = option
                        if option.mode ~= "path" then
                            view = { points = RoadCenterline.smoothPoints(RoadCenterline.despike(option.points, 3), 5) }
                        end
                        good = optionIsWay(view, result.points)
                    end
                end
                spec.optionHits = spec.optionHits or {}
                if good then
                    -- a way that shows up in one read only is a fluke of the map picture: it needs two reads in a row (unless shown already)
                    spec.optionHits[way] = (spec.optionHits[way] or 0) + 1
                    if spec.optionHits[way] >= 2 or spec.optionLines[way] ~= nil then
                        spec.optionLines[way] = option
                        spec.optionSeen[way] = spec.optionClock
                    end
                else
                    spec.optionHits[way] = 0
                    if spec.optionLines[way] ~= nil and spec.optionClock - (spec.optionSeen[way] or 0) > RoadFollow.DEBUG_OPTION_KEEP_MS then
                        spec.optionLines[way] = nil
                    end
                end
            end
        end
        local straightExists = result.valid and not (result.ends == true and (result.junctionEnd == true or result.crossingAt ~= nil))
        for _, way in ipairs({ "left", "right", "straight" }) do
            local option = spec.optionLines[way]
            if option ~= nil then
                -- (with a signal out but no turn found yet, the assist's own line IS the straight way)
                local chosen = (signalled == way) or (way == "straight" and signalled ~= nil and not result.turned)
                -- the way as the assist would steer it: a line from the map picture is jittery by a metre, smoothed it is not
                if option.mode ~= "path" and not option.smoothedForView then
                    option = { valid = true, mode = option.mode, smoothedForView = true,
                        points = RoadCenterline.smoothPoints(RoadCenterline.despike(option.points, 3), 5) }
                    spec.optionLines[way] = option
                end
                if chosen then
                    -- (the assist's own line, drawn above in green or yellow, is this one)
                elseif signalled == nil and way == "straight" then
                    drawResult(option, { 0.1, 1, 0.2 })                -- no signal: straight on is the way, read as far out as the others
                elseif signalled == nil and not straightExists then
                    drawResult(option, { 0.95, 0.95, 1.0 })          -- a T, nothing chosen yet: the two ways are white
                else
                    drawResult(option, { 1.0, 0.15, 0.1 })
                end
            end
        end
        if spec.assist ~= nil and spec.assist.far ~= nil then
            drawResult({ valid = true, points = spec.assist.far.points }, { 1.0, 0.5, 0.0 })       -- the far look, for the speed plan, in orange
        end
        drawRows(result)
        if assistOn and spec.assist.smoothPoints ~= nil then
            drawResult({ valid = true, points = spec.assist.smoothPoints }, { 0.3, 0.5, 1.0 })      -- the line it steers by, in blue
        end
        spec.debugLogMs = (spec.debugLogMs or 0) + (g_currentDt or 16)
        if spec.debugLogMs >= 2000 then
            spec.debugLogMs = 0
            log("debug lines: %d points, %d scan rows, valid %s, assist %s", #(result.points or {}), #(result.rows or {}), tostring(result.valid),
                assistOn and "engaged (its own scan)" or "not engaged (a preview scan from here)")
        end
    end
    if assistOn and spec.assist.smoothPoints ~= nil then
        -- where the steering reads the bend it follows: the line a moment ahead of the vehicle (orange post)
        local vx, _, vz = getWorldTranslation(self:getAISteeringNode())
        local pts = spec.assist.smoothPoints
        local lead = math.max(RoadCenterline.STEER_LEAD_MIN, (self:getLastSpeed() or 0) / 3.6 * RoadCenterline.STEER_LEAD_SECONDS)
        local walked, bestI, bestD = 0, 1, math.huge
        for i = 1, #pts do
            local d = (pts[i][1] - vx) ^ 2 + (pts[i][2] - vz) ^ 2
            if d < bestD then bestD, bestI = d, i end
        end
        for i = bestI + 1, #pts do
            walked = walked + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2)
            if walked >= lead then
                local x, z = pts[i][1], pts[i][2]
                local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
                drawDebugLine(x, y, z, 1, 0.55, 0.1, x, y + 3, z, 1, 0.55, 0.1, false)
                break
            end
        end
    end
end


-- ===== the road map: the roads round where you stand, as debug lines (roadFollowMap) =====
-- Rings are swept round the point and every road a ring crosses is walked (RoadMapper); the result is drawn: map splines blue, roads the
-- map picture shows white, gravel / worn tracks orange (a trace that lies on a spline is not drawn twice), junctions green, dead ends red,
-- the rings pale pink. The work is spread over frames (MAP_BUDGET map pixels each).
RoadFollow.MAP_BUDGET = 400
RoadFollow.MAP_SECONDS = 120
RoadFollow.MAP_RADIUS = 90
RoadFollow.roadMap = nil

local function viewerPosition()
    local vehicle = RoadFollow.getControlledVehicle()
    if vehicle ~= nil and vehicle.getAISteeringNode ~= nil then
        local x, y, z = getWorldTranslation(vehicle:getAISteeringNode())
        return x, y, z
    end
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        local x, y, z = getWorldTranslation(g_localPlayer.rootNode)
        return x, y, z
    end
    if getCamera ~= nil then
        local x, y, z = getWorldTranslation(getCamera())
        return x, y, z
    end
    return nil
end

function RoadFollow.startRoadMap(radius)
    local sample = makeSampler()
    if sample == nil then
        return false, "no map picture yet (run the map scan first)"
    end
    local x, y, z = viewerPosition()
    if x == nil then
        return false, "could not tell where you are"
    end
    radius = math.max(30, math.min(200, tonumber(radius) or RoadFollow.MAP_RADIUS))
    local radii = {}
    for _, f in ipairs({ 0.17, 0.39, 0.67, 1.0 }) do
        radii[#radii + 1] = math.floor(radius * f + 0.5)
    end
    RoadFollow.roadMap = {
        mapper = RoadMapper.new(sample, x, z, { radius = radius, radii = radii }),
        x = x, z = z, radius = radius, ms = 0, frames = 0, tagged = false,
    }
    return true, string.format("mapping the roads within %d m of %.0f %.0f", radius, x, z)
end

-- Which traces lie on a stored path (so the path is drawn, not the trace): at least 60% of a trace's points within 4 m of one.
local function tagSplines(map)
    local store = g_currentMission ~= nil and g_currentMission.wailaPaths or nil
    map.onSpline = {}
    if store == nil or store.findNear == nil then
        return
    end
    for i, trace in ipairs(map.mapper.traces) do
        local near, total = 0, 0
        for k = 1, #trace.points, 2 do
            total = total + 1
            if #store.findNear(trace.points[k][1], trace.points[k][2], 4.0) > 0 then
                near = near + 1
            end
        end
        map.onSpline[i] = total > 0 and near / total >= 0.6
    end
end

function RoadFollow.updateRoadMap(dt)
    local map = RoadFollow.roadMap
    if map == nil then
        return
    end
    map.ms = map.ms + dt
    if map.ms > RoadFollow.MAP_SECONDS * 1000 then
        RoadFollow.roadMap = nil
        return
    end
    if not map.mapper.done then
        map.frames = map.frames + 1
        RoadMapper.step(map.mapper, RoadFollow.MAP_BUDGET)
        if map.mapper.error ~= nil then
            log("road map failed: %s", map.mapper.error)
        end
    elseif not map.tagged then
        map.tagged = true
        tagSplines(map)
        local m = map.mapper
        log("road map: %d roads, %d junctions, %d dead ends, %d seeds skipped (road already walked), %d rejected (no road continues), %d map reads over %d frames",
            #m.traces, #m.junctions, #m.deadEnds, m.seedsSkipped, m.seedsRejected, m.samples, map.frames)
    end
end

local function mapHeight(point)
    if point[3] == nil then
        point[3] = getTerrainHeightAtWorldPos(g_terrainNode, point[1], 0, point[2]) + 0.5
    end
    return point[3]
end

local function mapLine(points, color)
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        drawDebugLine(a[1], mapHeight(a), a[2], color[1], color[2], color[3], b[1], mapHeight(b), b[2], color[1], color[2], color[3], false)
    end
end

local function mapRing(cx, cz, radius, color, cache)
    if cache.points == nil then
        cache.points = {}
        local n = math.max(24, math.floor(radius * 1.2))
        for i = 0, n do
            local a = 2 * math.pi * i / n
            cache.points[#cache.points + 1] = { cx + radius * math.cos(a), cz + radius * math.sin(a) }
        end
    end
    mapLine(cache.points, color)
end

local function mapPost(x, z, height, color)
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    drawDebugLine(x, y, z, color[1], color[2], color[3], x, y + height, z, color[1], color[2], color[3], false)
end

function RoadFollow.drawRoadMap()
    local map = RoadFollow.roadMap
    if map == nil or (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        return
    end
    if map.drawnAt == g_time then
        return                       -- (called from a vehicle's onDraw and from the mod's draw: once a frame)
    end
    map.drawnAt = g_time
    local m = map.mapper
    map.ringCache = map.ringCache or {}
    for i, radius in ipairs(m.rings) do
        map.ringCache[i] = map.ringCache[i] or {}
        mapRing(map.x, map.z, radius, { 1.0, 0.72, 0.85 }, map.ringCache[i])
    end
    -- stored paths in range
    local store = g_currentMission ~= nil and g_currentMission.wailaPaths or nil
    local splines = 0
    if store ~= nil and store.getAll ~= nil then
        map.pathLines = map.pathLines or (function()
            local out = {}
            for _, path in ipairs(store.getAll()) do
                local line = {}
                for _, p in ipairs(path.points) do
                    if (p[1] - map.x) ^ 2 + (p[2] - map.z) ^ 2 <= (map.radius * 1.1) ^ 2 then
                        line[#line + 1] = { p[1], p[2] }
                    end
                end
                if #line >= 2 then
                    out[#out + 1] = line
                end
            end
            return out
        end)()
        for _, line in ipairs(map.pathLines) do
            mapLine(line, { 0.35, 0.5, 1.0 })
            splines = splines + 1
        end
    end
    local roads, trails, covered = 0, 0, 0
    for i, trace in ipairs(m.traces) do
        if map.onSpline ~= nil and map.onSpline[i] then
            covered = covered + 1
        elseif trace.kind == "road" then
            mapLine(trace.points, { 1.0, 1.0, 1.0 })
            roads = roads + 1
        else
            mapLine(trace.points, { 1.0, 0.65, 0.1 })
            trails = trails + 1
        end
    end
    for _, j in ipairs(m.junctions) do
        mapPost(j[1], j[2], 5, { 0.1, 1.0, 0.2 })
        local ring = {}
        for k = 0, 12 do
            local a = 2 * math.pi * k / 12
            ring[#ring + 1] = { j[1] + 3 * math.cos(a), j[2] + 3 * math.sin(a) }
        end
        mapLine(ring, { 0.1, 1.0, 0.2 })
    end
    for _, d in ipairs(m.deadEnds) do
        mapPost(d[1], d[2], 2.5, { 1.0, 0.15, 0.1 })
    end
    -- the legend
    setTextAlignment(RenderText.ALIGN_LEFT)
    local lines = {
        { { 1, 0.9, 0.2 }, string.format("Road map, %d m round %.0f %.0f  (%s, %d map reads)", map.radius, map.x, map.z, m.done and "done" or "mapping...", m.samples) },
        { { 0.35, 0.5, 1.0 }, string.format("blue: stored paths / map splines (%d)", splines) },
        { { 1, 1, 1 }, string.format("white: road in the map picture (%d)", roads) },
        { { 1.0, 0.65, 0.1 }, string.format("orange: gravel / worn track (%d)", trails) },
        { { 0.1, 1.0, 0.2 }, string.format("green: junctions (%d)    red: dead ends (%d)    (%d lines lie on a spline)", #m.junctions, #m.deadEnds, covered) },
        { { 1.0, 0.72, 0.85 }, "pink: the rings swept   (roadFollowMap off clears it)" },
    }
    for i, entry in ipairs(lines) do
        setTextColor(entry[1][1], entry[1][2], entry[1][3], 1)
        renderText(0.02, 0.92 - (i - 1) * 0.02, 0.014, entry[2])
    end
    setTextColor(1, 1, 1, 1)
end

function RoadFollow.consoleMap(_, argument)
    if argument == "off" or (argument == nil and RoadFollow.roadMap ~= nil) then
        RoadFollow.roadMap = nil
        return "Road Follow road map: off"
    end
    local ok, text = RoadFollow.startRoadMap(argument)
    return "Road Follow road map: " .. text
end
function RoadFollow.consoleField()
    RoadFollow.FIELD_MODE = not RoadFollow.FIELD_MODE
    return "Road Follow field mode (a course through open ground, round obstacles): " .. (RoadFollow.FIELD_MODE and "ON" or "OFF")
end
addConsoleCommand("roadFollowField", "Switch the course through open ground (field mode) on / off", "consoleField", RoadFollow)
addConsoleCommand("roadFollowMap", "Map the roads round where you stand as debug lines (optional radius in metres, 'off' clears)", "consoleMap", RoadFollow)

-- The WAILA hub (Shift+L) gets a "Road Follow" tab: show the scan lines for 10 s, switch them on and off, write the map
-- picture / black box to the log. WAILA publishes itself as g_currentMission.waila; registered once it is there.
local wailaTabRegistered = false
function RoadFollow.registerWailaTab()
    if wailaTabRegistered or g_currentMission == nil or g_currentMission.waila == nil or g_currentMission.waila.registerDebugTab == nil then
        return
    end
    wailaTabRegistered = true
    local entries = {
        { label = "Show the scan lines for 10 s (sit in a vehicle, close this menu)", run = function() RoadFollow.debugSecondsLeft = 10 end },
        { label = "Map the roads round me as debug lines for 2 minutes (roadFollowMap)", run = function() RoadFollow.consoleMap(nil, nil) end },
        { label = "Scan lines on / off until switched (same as the console command roadFollowDebug)", run = function() RoadFollow.consoleToggleDebug() end },
        { label = "Write the map picture around the vehicle to the log (roadFollowDump)", run = function() RoadFollow.consoleDump() end },
        { label = "Write the black box (the last 8 s of the assist) to the log", run = function() RoadFollow.consoleBlackbox() end },
    }
    g_currentMission.waila.registerDebugTab({
        id = "roadfollow",
        label = "Road Follow",
        getItems = function() return entries end,
        describeItem = function(item) return item.label, nil end,
        buttons = { { label = "Run", callback = function(item) item.run() end } },
    })
end

function RoadFollow.consoleToggleDebug()
    RoadFollow.debugDraw = not RoadFollow.debugDraw
    return "Road Follow debug drawing: " .. (RoadFollow.debugDraw and "ON" or "OFF")
end
function RoadFollow.consoleHud(_, scale)
    local value = tonumber(scale)
    if value ~= nil then
        RoadHud.scale = math.max(0.5, math.min(2.5, value))
        RoadHud.enabled = true
    else
        RoadHud.enabled = not RoadHud.enabled
    end
    return "Road Follow HUD: " .. (RoadHud.enabled and string.format("ON, size %.2f", RoadHud.scale) or "OFF")
end
addConsoleCommand("roadFollowHud", "Switch the road assist gauge on or off, or give a size, e.g. roadFollowHud 1.3", "consoleHud", RoadFollow)

function RoadFollow.consoleBlackbox()
    local vehicle = RoadFollow.getControlledVehicle()
    local spec = vehicle ~= nil and getSpec(vehicle) or nil
    if spec == nil or spec.assist == nil or spec.assist.blackbox == nil then
        return "Road Follow black box: nothing recorded (it records while the assist drives)"
    end
    blackboxWrite(spec.assist, "asked for")
    return "Road Follow black box written to the log (search for 'RoadFollow] bb')"
end
addConsoleCommand("roadFollowBlackbox", "Write the last seconds of what the road assist saw and asked for to the log", "consoleBlackbox", RoadFollow)

function RoadFollow.consoleSteer()
    RoadFollow.CURVATURE_STEERING = not RoadFollow.CURVATURE_STEERING
    return "Road Follow steering: " .. (RoadFollow.CURVATURE_STEERING and "by curvature (wheels straight to the curve)" or "driveToPoint (the base game's aim point steering, slower to turn)")
end
addConsoleCommand("roadFollowSteer", "Switch between steering by curvature and the base game's aim point steering (toggle)", "consoleSteer", RoadFollow)

function RoadFollow.consoleForestFloor()
    RoadFollow.IGNORE_FOREST_FLOOR = not RoadFollow.IGNORE_FOREST_FLOOR
    RoadFollow.clearForestFloorCache()
    return "Road Follow: trail pixels painted with the forest floor's layer are " .. (RoadFollow.IGNORE_FOREST_FLOOR and "IGNORED" or "kept (as the trail picture says)")
end
addConsoleCommand("roadFollowForestFloor", "Ignore trail pixels whose paint is the learned forest floor layer (toggle, for testing)", "consoleForestFloor", RoadFollow)

function RoadFollow.consoleFeedForward()
    RoadFollow.FEEDFORWARD_STEERING = not RoadFollow.FEEDFORWARD_STEERING
    return "Road Follow steering by the line's own curvature (feed-forward): " .. (RoadFollow.FEEDFORWARD_STEERING and "ON" or "OFF, aim point steering")
end
addConsoleCommand("roadFollowFeedForward", "Switch the line-curvature (feed-forward) steering on or off (toggle)", "consoleFeedForward", RoadFollow)

-- Live tuning of the steering feel: roadFollowTune <correction seconds> <dead band metres> <look-ahead seconds>
function RoadFollow.consoleTune(_, fb, dead, lead)
    if tonumber(fb) ~= nil then
        RoadCenterline.STEER_FB_SECONDS = math.max(0.4, math.min(4, tonumber(fb)))
    end
    if tonumber(dead) ~= nil then
        RoadCenterline.STEER_DEADBAND = math.max(0, math.min(1.5, tonumber(dead)))
    end
    if tonumber(lead) ~= nil then
        RoadCenterline.STEER_LEAD_SECONDS = math.max(0, math.min(1.2, tonumber(lead)))
    end
    return string.format("Road Follow steering: correction %.1f s (higher = calmer, looser), dead band %.2f m (errors below it are left alone), look-ahead %.2f s (for a sluggish vehicle more)",
        RoadCenterline.STEER_FB_SECONDS, RoadCenterline.STEER_DEADBAND, RoadCenterline.STEER_LEAD_SECONDS)
end
addConsoleCommand("roadFollowTune", "Tune the steering feel: roadFollowTune <correction s> <dead band m> <look-ahead s>", "consoleTune", RoadFollow)

function RoadFollow.consoleTapFlip()
    RoadFollow.STEER_LEFT_SIGN = -RoadFollow.STEER_LEFT_SIGN
    return "Road Follow: a tap on the left steering key now signals " .. (RoadFollow.STEER_LEFT_SIGN == -1 and "(axis -) left, the normal way" or "(axis +) left, the other way round than normal")
end
addConsoleCommand("roadFollowTapFlip", "A tap on the left steering key signals right instead (flip), if the sides are swapped", "consoleTapFlip", RoadFollow)

function RoadFollow.consoleHudFlip()
    RoadHud.ROTATION_SIGN = -RoadHud.ROTATION_SIGN
    return "Road Follow HUD: rotation direction " .. (RoadHud.ROTATION_SIGN == 1 and "normal" or "flipped")
end
-- Console: roadFollowDump. Sit in the vehicle where the assist does something wrong and run it: the log gets
-- a picture of the map data around the vehicle (north is up, 2 m per character) with the line the assist
-- would drive, so the situation can be rebuilt offline.
--   V vehicle   * the line   p stored path   T tree   B building   # road   . trail (in the map)
--   x dirt or gravel ground that is NOT in the trail map (the scan left it out)   f forest
--   o a trail pixel that carries the learned FOREST-FLOOR paint   F forest-floor paint that is not trail   (blank) nothing
function RoadFollow.consoleDump()
    local vehicle = RoadFollow.getControlledVehicle()
    if vehicle == nil or vehicle.getAISteeringNode == nil then
        return "Road Follow dump: sit in a vehicle first"
    end
    local x, z, dx, dz = scanSetup(vehicle)
    local tracer = getTracer()
    local result, why = vehicle:scanRoadAhead(false)
    local range, cell = 36, 2
    local size = 2 * range / cell + 1
    local grid = {}
    local function put(wx, wz, char)
        local col = math.floor((wx - x + range) / cell) + 1
        local row = math.floor((wz - z + range) / cell) + 1
        if col >= 1 and col <= size and row >= 1 and row <= size then
            grid[row][col] = char
        end
    end
    local sample = makeSampler()
    local hasTrees = tracer ~= nil and tracer.hasTreeData ~= nil and tracer.hasTreeData()
    for row = 1, size do
        grid[row] = {}
        for col = 1, size do
            local wx = x - range + (col - 0.5) * cell
            local wz = z - range + (row - 0.5) * cell
            local class = sample ~= nil and sample(wx, wz) or 0
            local char = (class == 2 and "#") or (class == 1 and ".") or " "
            if tracer ~= nil and tracer.getLayerClassAt ~= nil and tracer.LAYER_CLASS_FOREST ~= nil and tracer.layerClassLearned
                and tracer.getLayerClassAt(wx, wz) == tracer.LAYER_CLASS_FOREST then
                -- paint of the learned forest-floor layer: 'o' on a trail pixel, 'F' elsewhere
                char = (class == 1) and "o" or ((class == 0) and "F" or char)
            end
            if class == 0 and char == " " and tracer ~= nil then
                -- bare ground the trail picture does NOT contain: 'x' = dirt or gravel material that the scan left out
                -- (forest floor, a small patch), 'f' = forest
                if tracer.sampleWornMaterial ~= nil and tracer.sampleWornMaterial(wx, wz) then
                    char = "x"
                elseif tracer.hasForestData ~= nil and tracer.hasForestData() and tracer.sampleForest(wx, wz) then
                    char = "f"
                end
            end
            if tracer ~= nil and tracer.hasBuildingData ~= nil and tracer.hasBuildingData() and tracer.sampleBuilding(wx, wz) then
                char = "B"
            end
            if hasTrees and tracer.sampleTree(wx, wz) then
                char = "T"
            end
            grid[row][col] = char
        end
    end
    local store = g_currentMission.wailaPaths
    local nearPaths = {}
    if store ~= nil and store.findNear ~= nil then
        for _, hit in ipairs(store.findNear(x, z, range)) do
            nearPaths[#nearPaths + 1] = string.format("%s(%s, %.0f m away, runs %.0f deg from north%s)", tostring(hit.id), tostring(hit.path.kind), hit.distance,
                math.deg(math.atan2(hit.dx, -hit.dz)) % 360, hit.path.oneWay and ", one way" or "")
            local points = hit.path.points
            for i = 1, #points - 1 do
                local ax, az, bx, bz = points[i][1], points[i][2], points[i + 1][1], points[i + 1][2]
                local n = math.max(1, math.ceil(math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2) / 1.0))
                for k = 0, n do
                    put(ax + (bx - ax) * k / n, az + (bz - az) * k / n, "p")
                end
            end
        end
    end
    if result ~= nil and result.points ~= nil then
        for _, point in ipairs(result.points) do
            put(point[1], point[2], "*")
        end
    end
    put(x, z, "V")
    print(string.format("[RoadFollow] dump: pos %.1f %.1f, heading (%.3f, %.3f) = %.0f deg from north, speed %.1f km/h, intent %s",
        x, z, dx, dz, math.deg(math.atan2(dx, -dz)) % 360, vehicle:getLastSpeed() or 0, tostring(RoadFollow.getIntent(vehicle))))
    print(string.format("[RoadFollow] dump: mode %s, valid %s, points %d, ends %s, junction %s, reason %s, %s",
        tostring(result ~= nil and result.mode), tostring(result ~= nil and result.valid), result ~= nil and #(result.points or {}) or 0,
        tostring(result ~= nil and result.ends), tostring(result ~= nil and result.junction), tostring(result ~= nil and result.reason), tostring(why)))
    -- the paths' own vertices near the vehicle, so the situation can be rebuilt offline: id, one way, then x,z pairs
    if store ~= nil and store.findNear ~= nil then
        local seen = {}
        for _, hit in ipairs(store.findNear(x, z, range)) do
            if not seen[hit.id] then
                seen[hit.id] = true
                local list = {}
                for _, point in ipairs(hit.path.points) do
                    if math.abs(point[1] - x) <= 90 and math.abs(point[2] - z) <= 90 then
                        list[#list + 1] = string.format("%.1f,%.1f", point[1], point[2])
                    end
                end
                print(string.format("[RoadFollow] dump: path %s oneWay %s: %s", tostring(hit.id), tostring(hit.path.oneWay == true), table.concat(list, " ")))
            end
        end
    end
    print("[RoadFollow] dump: stored paths near: " .. (#nearPaths > 0 and table.concat(nearPaths, ", ") or "none"))
    for row = 1, size do
        print("[RoadFollow] dump| " .. table.concat(grid[row]))
    end
    return "Road Follow dump written to the log (search for 'RoadFollow] dump')"
end
addConsoleCommand("roadFollowDump", "Write a picture of the map data and the assist's line around the vehicle to the log", "consoleDump", RoadFollow)

addConsoleCommand("roadFollowHudFlip", "Turn the gauge's segments the other way round if the arc looks scrambled", "consoleHudFlip", RoadFollow)

addConsoleCommand("roadFollowDebug", "Draw the road centre-line the road follower sees (toggle)", "consoleToggleDebug", RoadFollow)

-- ===== input =====

function RoadFollow:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient then
        local spec = getSpec(self)
        self:clearActionEventsTable(spec.actionEvents)
        if self:getIsActiveForInput(true, true) then
            local _, eventId = self:addActionEvent(spec.actionEvents, InputAction.ROADFOLLOW_TOGGLE, self, RoadFollow.actionEventToggle, false, true, false, true, nil, nil, true, true)
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
            -- the number block as the assist's controls (the keys there are different keys from the number row)
            local controls = {
                { InputAction.ROADFOLLOW_SIGNAL_LEFT, "left" },
                { InputAction.ROADFOLLOW_SIGNAL_RIGHT, "right" },
                { InputAction.ROADFOLLOW_SPEED_UP, 1 },
                { InputAction.ROADFOLLOW_SPEED_DOWN, -1 },
            }
            for _, control in ipairs(controls) do
                if control[1] ~= nil then
                    local _, controlId = self:addActionEvent(spec.actionEvents, control[1], self, RoadFollow.actionEventControl, false, true, false, true, control[2], nil, true, true)
                    g_inputBinding:setActionEventTextPriority(controlId, GS_PRIO_LOW)
                    g_inputBinding:setActionEventTextVisibility(controlId, false)
                end
            end
            RoadFollow.updateActionEvents(self)
        end
    end
end

-- Number block keys: callbackState is "left" / "right" (turn signal) or +1 / -1 (set speed)
function RoadFollow:actionEventControl(actionName, inputValue, callbackState, isAnalog)
    local handled
    if type(callbackState) == "number" then
        handled = RoadFollow.adjustSpeed(self, callbackState)
    else
        handled = RoadFollow.signal(self, callbackState)
    end
    log("key %s: %s", tostring(actionName), handled and "used" or "ignored (assist not driving)")
end

function RoadFollow:updateActionEvents()
    if not self.isClient then
        return
    end
    local spec = getSpec(self)
    local event = spec.actionEvents[InputAction.ROADFOLLOW_TOGGLE]
    if event ~= nil then
        g_inputBinding:setActionEventText(event.actionEventId, g_i18n:getText(spec.isActive and "ROADFOLLOW_STOP" or "ROADFOLLOW_START"))
        g_inputBinding:setActionEventTextVisibility(event.actionEventId, true)
    end
end
