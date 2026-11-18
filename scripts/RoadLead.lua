-- Road Follow: the vehicle ahead. Pure helpers (no engine calls); the raycasts themselves are in RoadFollow.lua.
--
-- The base game's own AI collision handler does not see traffic cars (their collision group is TRAFFIC_VEHICLE, which is
-- not in its mask), so the assist looks along its own line with thin rays: three per stretch of line (the middle and
-- one metre to each side), each stretch about 25 m long, as far ahead as the vehicle needs to stop. The nearest
-- thing that is not the vehicle itself is the "lead". How fast the lead moves is read from how its distance
-- changes; the speed asked for is what lets the vehicle slow to the lead's speed by the time it is `MIN_GAP`
-- behind it (a stopped car: stop `MIN_GAP` short of it).
RoadLead = {}

RoadLead.RAY_HEIGHT = 0.9          -- metres above the ground: a car body, not the road
RoadLead.SEGMENT = 25            -- metres of line per ray
RoadLead.LATERAL = { 0, 1.0, -1.0 }
RoadLead.MIN_GAP = 5.0           -- metres kept between the bumper and the lead
RoadLead.BRAKE = 2.5             -- m/s^2 planned for braking
RoadLead.MIN_RANGE = 60          -- always look at least this far
RoadLead.MAX_RANGE = 170
RoadLead.SPEED_FILTER = 0.3

-- How far to look at this speed (m/s): braking distance plus a margin.
function RoadLead.range(speedMs)
    return math.max(RoadLead.MIN_RANGE, math.min(RoadLead.MAX_RANGE, speedMs * speedMs / (2 * RoadLead.BRAKE) + 40))
end

-- The stretches to cast rays along: { ax, az, bx, bz, from, length } with `from` = metres from the origin to the stretch's
-- start. `points` is the line ahead ({x, z} ...) and may be nil / too short: the rest of the range then runs straight
-- on in the line's last direction (or along (hx, hz) when there is no line).
function RoadLead.segments(points, originX, originZ, hx, hz, range)
    local cumulative, total = { 0 }, 0
    local ux, uz = hx, hz
    local hasLine = points ~= nil and #points >= 2
    if hasLine then
        for i = 2, #points do
            total = total + math.sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2)
            cumulative[i] = total
        end
        local p, q = points[#points - 1], points[#points]
        local l = math.sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2)
        if l > 1e-9 then
            ux, uz = (q[1] - p[1]) / l, (q[2] - p[2]) / l
        end
    end
    local function positionAt(distance)
        if not hasLine then
            return originX + ux * distance, originZ + uz * distance
        end
        if distance >= total then
            local tail = points[#points]
            return tail[1] + ux * (distance - total), tail[2] + uz * (distance - total)
        end
        for i = 2, #points do
            if cumulative[i] >= distance then
                local f = (distance - cumulative[i - 1]) / math.max(cumulative[i] - cumulative[i - 1], 1e-9)
                return points[i - 1][1] + (points[i][1] - points[i - 1][1]) * f, points[i - 1][2] + (points[i][2] - points[i - 1][2]) * f
            end
        end
        return originX, originZ
    end
    local samples = { { originX, originZ, 0 } }
    local distance = 0
    while distance < range - 1e-6 do
        distance = math.min(range, distance + RoadLead.SEGMENT)
        local x, z = positionAt(distance)
        samples[#samples + 1] = { x, z, distance }
    end
    local segs = {}
    for i = 1, #samples - 1 do
        local a, b = samples[i], samples[i + 1]
        local length = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
        if length > 1 then
            segs[#segs + 1] = { ax = a[1], az = a[2], bx = b[1], bz = b[2], from = a[3], length = length }
        end
    end
    return segs
end

-- The speed (m/s) that lets the vehicle slow to the lead's speed `vLead` by the time it is MIN_GAP behind it.
function RoadLead.allowedSpeed(gap, vLead)
    vLead = math.max(0, vLead or 0)
    if gap <= RoadLead.MIN_GAP then
        return math.max(0, vLead - 1.0)           -- too close: slower than the lead, to open the gap again
    end
    return math.sqrt(vLead * vLead + 2 * RoadLead.BRAKE * (gap - RoadLead.MIN_GAP))
end

-- state = {} kept between calls; gap = metres to the lead now (nil: none). Returns the lead's speed (m/s) estimate.
-- A lead seen for the first time is assumed to stand still, which is the careful guess.
function RoadLead.track(state, gap, ownSpeedMs, dtMs)
    if gap == nil then
        state.gap, state.vLead = nil, 0
        return 0
    end
    local seconds = math.max(dtMs, 1) / 1000
    if state.gap ~= nil then
        local closing = (state.gap - gap) / seconds
        if math.abs(closing) <= 40 then
            local estimate = math.max(0, math.min(60, ownSpeedMs - closing))
            state.vLead = state.vLead + (estimate - state.vLead) * RoadLead.SPEED_FILTER
        end
    else
        state.vLead = 0
    end
    state.gap = gap
    return state.vLead
end

-- ===== cross traffic at a junction =====
-- Before a turn (or a T) the vehicle looks along the road it is about to enter, to both sides of the junction's mouth, for
-- a vehicle that is coming: a moving one that is near or would arrive soon is given way to; a standing one is only in the way
-- when it is right at the mouth. Rays from the mouth, along the cross road, side by side along the line (across its lanes).
RoadLead.CROSS_RANGE = 50              -- metres looked along the cross road each way
RoadLead.CROSS_OFFSETS = { -1.5, 0, 1.5, 3.0, 4.5, 6.0, 7.5, 9.0, 10.5 }       -- along the line from the mouth point: a strip as wide as the cross road's lanes, rays 1.5 m apart (a car is 2 m wide)
RoadLead.CROSS_BLOCK = 5.0             -- a vehicle this close to the mouth is in the way, moving or not
RoadLead.CROSS_NEAR = 14.0             -- a vehicle coming this close is given way to however slow
RoadLead.CROSS_GAP_SECONDS = 7.0       -- ... and one that would be at the mouth within this long
RoadLead.CROSS_APPROACH_MIN = 1.0      -- m/s: slower than this towards the mouth is "not coming"
RoadLead.CROSS_UNKNOWN_RANGE = 30.0    -- a vehicle seen only just now (speed not yet known) inside this is given way to
RoadLead.CROSS_CLEAR_MS = 1200         -- once giving way, the way must be clear this long before going on
RoadLead.CROSS_FILTER = 0.4

-- The cross road's two directions at a mouth where the line runs (lx, lz): { leftX, leftZ, rightX, rightZ } (the vehicle's own
-- left and right: in the world's x / z plane (x east, z south) the left of heading east (1, 0) is north (0, -1), so left is
-- (z, -x) of the heading and right is (-z, x)).
function RoadLead.crossDirections(lx, lz)
    return lz, -lx, -lz, lx
end

-- state = {} per side, kept between calls; gap = metres from the mouth to the nearest vehicle on that side (nil: none).
-- Keeps the speed the vehicle comes towards the mouth with (m/s, + = coming) and how many looks it is based on.
function RoadLead.trackCross(state, gap, dtMs)
    if gap == nil then
        state.gap, state.approach, state.looks = nil, 0, 0
        return
    end
    local seconds = math.max(dtMs, 1) / 1000
    if state.gap ~= nil then
        local closing = (state.gap - gap) / seconds
        if math.abs(closing) <= 40 then
            state.approach = (state.approach or 0) + (closing - (state.approach or 0)) * RoadLead.CROSS_FILTER
            state.looks = (state.looks or 0) + 1
        end
    else
        state.approach, state.looks = 0, 0
    end
    state.gap = gap
end

-- Is this side's vehicle one to give way to
function RoadLead.crossThreat(state)
    if state == nil or state.gap == nil then
        return false
    end
    if state.gap <= RoadLead.CROSS_BLOCK then
        return true
    end
    if (state.looks or 0) < 3 then
        return state.gap <= RoadLead.CROSS_UNKNOWN_RANGE         -- not known yet how it moves: careful
    end
    local approach = state.approach or 0
    if approach >= RoadLead.CROSS_APPROACH_MIN then
        return state.gap <= RoadLead.CROSS_NEAR or state.gap / approach <= RoadLead.CROSS_GAP_SECONDS
    end
    return false
end

-- Which sides matter for a turn: a right turn (right-hand traffic) joins the road with the traffic from the left only;
-- going straight over, or a left turn, has both sides to watch.
function RoadLead.crossSides(intent)
    if intent == "right" then
        return { "left" }
    end
    return { "left", "right" }
end

-- ===== what the vehicle carries is not in its way =====
-- A vehicle loaded onto a flatbed or a trailer (dynamically mounted: a damaged contract vehicle on a transporter, a tractor on a
-- low loader) is a vehicle of its own as far as the base game's collision handler goes (its root vehicle is itself), so the handler
-- reports it as an obstacle the moment it sits in a trigger box: the assist then asks for 0 km/h on a clear road and the cargo's
-- own (tuned down) speed seems to rule. Anything mounted on the vehicle's own rig, or on something that is, is its own.
RoadLead.MOUNT_DEPTH = 6

function RoadLead.isCarriedBy(object, rootVehicle)
    if object == nil or rootVehicle == nil then
        return false
    end
    local current = object
    for _ = 1, RoadLead.MOUNT_DEPTH do
        if current.getDynamicMountObject == nil then
            return false
        end
        local ok, mount = pcall(current.getDynamicMountObject, current)
        if not ok then
            return false
        end
        if mount == nil then
            -- not mounted itself: perhaps an implement of a mounted vehicle, then the root of that is what is mounted
            local root = current.getRootVehicle ~= nil and current:getRootVehicle() or nil
            if root ~= nil and root ~= current then
                current = root
            else
                return false
            end
        else
            if mount == rootVehicle or (mount.getRootVehicle ~= nil and mount:getRootVehicle() == rootVehicle) then
                return true
            end
            current = mount
        end
    end
    return false
end

-- Puts a filter in front of the base game's collision handler (an AICollisionTriggerHandler instance): hits on what the vehicle
-- carries are skipped; the end of the hit list is still passed on so the handler finishes its count.
function RoadLead.ignoreCarried(handler)
    local original = handler.onVehicleCollisionDistanceCallback
    if original == nil or handler.carriedFilterInstalled then
        return false
    end
    handler.carriedFilterInstalled = true
    handler.onVehicleCollisionDistanceCallback = function(h, distance, objectId, subShapeIndex, isLast, trigger)
        local objects = g_currentMission ~= nil and g_currentMission.nodeToObject or nil
        local object = (objectId ~= nil and objectId ~= 0 and objects ~= nil) and objects[objectId] or nil
        if object ~= nil and RoadLead.isCarriedBy(object, h.rootVehicle) then
            if isLast then
                return original(h, distance, 0, subShapeIndex, true, trigger)
            end
            return true
        end
        return original(h, distance, objectId, subShapeIndex, isLast, trigger)
    end
    return true
end
