--[[
    RoadSupervisor.lua

    The safety layer of the road assist, in the spirit of a car's lane keeping: it watches where the
    vehicle is against the line it is meant to follow and where it will be in the next second or two,
    and when that looks like leaving the road it does one of two things: correct (slow down, so the
    steering has the authority to bring it back) or stop (a controlled halt, cruise control off, and a
    message saying why). It never lets the vehicle drive on silently. The player is not supervised:
    any steering, pedal or handbrake input hands control back before this runs.

    Pure logic, no engine calls: metrics() turns a line and a vehicle pose into numbers, update()
    turns the numbers into a decision. Positions: y is the vehicle's sideways distance from the line,
    + to the left of the line's direction; sinPsi is the sine of the heading's angle to the line, +
    when the vehicle points to the left of the line.
]]

RoadSupervisor = {}

RoadSupervisor.VEHICLE_HALF_WIDTH = 1.4     -- m: how much of the road's half width the vehicle itself uses
RoadSupervisor.MIN_LIMIT = 1.5              -- m: the smallest sideways room ever allowed
RoadSupervisor.OFF_MARGIN = 1.0             -- m beyond the limit: it is off the road
RoadSupervisor.CORRECT_FRACTION = 1.0       -- the overshoot that steering at its best cannot avoid, beyond this share of the limit: correct
RoadSupervisor.ON_ROAD_MIN_OVERSHOOT = 0.3  -- m: on the road, only an outward drift of at least this much (with no road ahead) is corrected
RoadSupervisor.STEER_ACCEL = 3.5            -- m/s^2 the steering is assumed able to give when working out that overshoot
RoadSupervisor.SUPPRESS_MS = 3000           -- after correcting for a long time while still on the road, the line is doubted for this long
RoadSupervisor.BRAKE_DECEL = 2.5            -- m/s^2: used to look "one stopping time" ahead
RoadSupervisor.MIN_LOOKAHEAD_S = 0.8
RoadSupervisor.MAX_LOOKAHEAD_S = 3.0
RoadSupervisor.CORRECT_SPEED_SHARE = 0.7    -- while correcting, ask for this share of the current speed
RoadSupervisor.CORRECT_TIMEOUT_MS = 2000    -- correcting this long without getting closer: stop
RoadSupervisor.SATURATED_STOP_MS = 1000     -- steering at its limit this long while off-centre: stop
RoadSupervisor.SATURATED_MIN_Y = 0.6        -- ... counted when the offset is beyond this share of the limit
RoadSupervisor.MAX_HEADING_ERROR_DEG = 60   -- pointing this far off the road at speed: stop
RoadSupervisor.LOST_STOP_MS = 1000          -- no road ahead this long, at speed: stop
RoadSupervisor.MIN_SPEED_MS = 3.0           -- below this the geometry rules (heading, prediction) are not applied
RoadSupervisor.STOP_DONE_KMH = 1.0
RoadSupervisor.STUCK_STOP_MS = 3000          -- asked to drive on, not moving for this long: stop properly (a world border, a wall, a ditch)
RoadSupervisor.REJOIN_STOP_MS = 10000       -- engaged beside the road: this long to get onto it, else stop
RoadSupervisor.BLOCKED_STOP_MS = 3000       -- held up by something (another vehicle) for this long: stop and say so
RoadSupervisor.OBSTACLE_BRAKE = 2.5         -- m/s^2 used to judge whether an obstacle ahead can still be stopped for
RoadSupervisor.OBSTACLE_MARGIN = 8.0        -- m kept in hand before an obstacle
RoadSupervisor.DIRECTION_BASELINE = 8.0    -- m: the line's direction is read over this stretch, not over one noisy segment

function RoadSupervisor.new()
    return { level = 0, correctMs = 0, correctStartY = nil, saturatedMs = 0, stopping = false, reason = nil }
end

function RoadSupervisor.reset(state)
    state.level, state.correctMs, state.correctStartY, state.saturatedMs = 0, 0, nil, 0
    state.stopping, state.reason = false, nil
end

-- Sideways position and heading against the line, from the vehicle's own position and heading now.
-- points: the line ahead, first point near the vehicle. Returns y, sinPsi, cosPsi, or nil for a line
-- too short to say.
function RoadSupervisor.pose(points, x, z, hx, hz)
    if points == nil or #points < 2 then
        return nil
    end
    -- the closest point on the line (among its first stretch)
    local bestDistance, bestIndex, bestCx, bestCz = math.huge, nil, 0, 0
    local upTo = math.min(#points - 1, 12)
    for i = 1, upTo do
        local a, b = points[i], points[i + 1]
        local sx, sz = b[1] - a[1], b[2] - a[2]
        local lengthSq = sx * sx + sz * sz
        if lengthSq > 1e-9 then
            local t = math.max(0, math.min(1, ((x - a[1]) * sx + (z - a[2]) * sz) / lengthSq))
            local cx, cz = a[1] + sx * t, a[2] + sz * t
            local distance = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2)
            if distance < bestDistance then
                bestDistance, bestIndex, bestCx, bestCz = distance, i, cx, cz
            end
        end
    end
    if bestIndex == nil then
        return nil
    end
    -- the line's direction there: from the closest point to the point DIRECTION_BASELINE metres further
    -- along (or the end of the line), so pixel noise on single segments does not read as a heading error
    local targetX, targetZ = points[#points][1], points[#points][2]
    local travelled, lastX, lastZ = 0, bestCx, bestCz
    for i = bestIndex + 1, #points do
        local dx, dz = points[i][1] - lastX, points[i][2] - lastZ
        travelled = travelled + math.sqrt(dx * dx + dz * dz)
        lastX, lastZ = points[i][1], points[i][2]
        if travelled >= RoadSupervisor.DIRECTION_BASELINE then
            targetX, targetZ = lastX, lastZ
            break
        end
    end
    local lx, lz = targetX - bestCx, targetZ - bestCz
    local length = math.sqrt(lx * lx + lz * lz)
    if length < 1e-6 then
        local a, b = points[bestIndex], points[bestIndex + 1]
        lx, lz = b[1] - a[1], b[2] - a[2]
        length = math.sqrt(lx * lx + lz * lz)
    end
    lx, lz = lx / length, lz / length
    -- + when the vehicle is to the left of the line's direction
    local y = (x - bestCx) * (-lz) + (z - bestCz) * lx
    local sinPsi = hx * (-lz) + hz * lx
    local cosPsi = hx * lx + hz * lz
    return y, sinPsi, cosPsi
end

-- Sideways room for the vehicle on this road, metres either side of the line.
function RoadSupervisor.limitFor(roadWidth)
    return math.max(RoadSupervisor.MIN_LIMIT, (roadWidth or 6) / 2 - RoadSupervisor.VEHICLE_HALF_WIDTH)
end

-- How far the vehicle will still drift outward even with the steering doing its best: turning the heading
-- error psi away at lateral acceleration a takes a distance, and sideways that is (v^2 / a) * (1 - cos psi).
-- A vehicle pointing back towards the line, or along it, has no such overshoot. Returns the sideways
-- position of the furthest point it will reach (+ left of the line).
function RoadSupervisor.extremeY(y, sinPsi, cosPsi, speedMs)
    local direction = (y ~= 0) and (y > 0 and 1 or -1) or ((sinPsi > 0) and 1 or -1)
    local outward = (y * sinPsi > 0) or (math.abs(y) < 0.2 and sinPsi ~= 0)
    if not outward then
        return y
    end
    local overshoot = (speedMs * speedMs / RoadSupervisor.STEER_ACCEL) * (1 - (cosPsi or 1))
    return y + direction * overshoot
end

-- m = { y, sinPsi, cosPsi, limit, speedMs, capturing, saturated, roadLostMs, hasLine, obstacleDistance (metres to something
--       the line cannot avoid, or nil), blockedMs (how long the collision check has held the speed at zero), stuckMs (how long it has stood still while asked to drive on), autopilot (true: the vehicle was at road speed a moment ago, so a lost road is a stop even if it has slowed since),
--       onRoad (true / false / nil: is there road or trail under the vehicle, from the map; nil = unknown),
--       roadAhead (true / false / nil: road or trail a little way ahead along the heading) }
-- returns { level = 0 normal | 1 correcting | 2 stopping, stop = bool, reason = text or nil,
--           speedShare = share of the current speed to ask for (level 1) or nil }
--
-- The line the follower steers by is an ESTIMATE (it jumps at a fork, a widening, a bad scan), so
-- "the vehicle left the road" is never judged against the line alone: when the map says the vehicle is
-- still on road or trail, it has not left it, whatever the line says.
function RoadSupervisor.update(state, m, dt)
    if state.stopping then
        return { level = 2, stop = true, reason = state.reason }
    end

    local speed = m.speedMs or 0
    local function stop(reason)
        state.stopping = true
        state.reason = reason
        state.level = 2
        return { level = 2, stop = true, reason = reason }
    end

    -- the road is gone ahead, at speed: a controlled stop rather than driving on into whatever is there
    if (m.roadLostMs or 0) >= RoadSupervisor.LOST_STOP_MS and (speed >= RoadSupervisor.MIN_SPEED_MS or m.autopilot == true) then
        return stop("no road ahead")
    end

    -- pushing against something that does not give (the map border, a wall): it is not going anywhere, stop pushing
    if (m.stuckMs or 0) >= RoadSupervisor.STUCK_STOP_MS then
        return stop("stuck, not moving")
    end

    -- held up by something in the way (the game's collision check keeps the speed at zero): after a while,
    -- stop properly rather than sit there with cruise control on
    if (m.blockedMs or 0) >= RoadSupervisor.BLOCKED_STOP_MS then
        return stop("blocked by something")
    end

    -- something in the way that the line cannot go round (a tree on a narrow track): stop for it, in good time
    if m.obstacleDistance ~= nil then
        local needed = speed * speed / (2 * RoadSupervisor.OBSTACLE_BRAKE) + RoadSupervisor.OBSTACLE_MARGIN
        if m.obstacleDistance <= needed or speed < 0.5 then
            return stop("obstacle ahead")
        end
    end

    if not m.hasLine then
        state.level = 0
        return { level = 0, stop = false }
    end

    if state.suppressMs ~= nil and state.suppressMs > 0 then
        state.suppressMs = state.suppressMs - dt
    end

    local absY = math.abs(m.y)
    local onRoad = m.onRoad
    local level = 0
    -- engaged beside the road (the vehicle came off it, or crossed a junction and is next to the track beyond):
    -- until it has been on the road once it is rejoining it, not leaving it. Like a join: slowly, towards the line.
    if onRoad == true or absY <= m.limit then
        state.everOnRoad = true            -- on the road, or on its line (a recorded path over grass is its own road)
    end
    local rejoining = not state.everOnRoad and onRoad == false and m.capturing ~= true
    if rejoining then
        state.rejoinMs = (state.rejoinMs or 0) + dt
        if state.rejoinMs >= RoadSupervisor.REJOIN_STOP_MS then
            return stop("not coming back onto the road")
        end
    end
    local capturing = m.capturing or rejoining
    local checksGeometry = not capturing and speed >= RoadSupervisor.MIN_SPEED_MS
    if checksGeometry then
        -- 1. actually off the road: no road under the vehicle (when the map can say) and well off the line
        local offRoad
        if onRoad ~= nil then
            offRoad = (onRoad == false) and absY > m.limit
        else
            offRoad = absY > m.limit + RoadSupervisor.OFF_MARGIN
        end
        if offRoad then
            return stop("left the road")
        end
        -- 2. pointing well away from the road with no road under or ahead of it
        if m.cosPsi ~= nil and m.cosPsi < math.cos(math.rad(RoadSupervisor.MAX_HEADING_ERROR_DEG)) then
            local noRoadBelow = (onRoad == false) or (onRoad == nil)
            local noRoadAhead = (m.roadAhead == false) or (m.roadAhead == nil)
            if noRoadBelow and noRoadAhead then
                return stop("pointing away from the road")
            end
        end
        -- 3. will leave it, even with the steering doing its best: correct (while there is still time)
        if not (state.suppressMs ~= nil and state.suppressMs > 0) then
            local yExt = RoadSupervisor.extremeY(m.y, m.sinPsi or 0, m.cosPsi or 1, speed)
            if onRoad == true then
                -- on the road, being off the middle of it is just a lane position. What is worth correcting is
                -- heading for the edge: no road left ahead along the heading, and still drifting outward.
                local outwardOvershoot = math.abs(yExt) - absY
                if m.roadAhead == false and outwardOvershoot > RoadSupervisor.ON_ROAD_MIN_OVERSHOOT then
                    level = 1
                end
            elseif math.abs(yExt) > m.limit * RoadSupervisor.CORRECT_FRACTION then
                level = 1
            end
        end
    elseif capturing and speed >= RoadSupervisor.MIN_SPEED_MS and m.cosPsi ~= nil
        and m.cosPsi < math.cos(math.rad(RoadSupervisor.MAX_HEADING_ERROR_DEG + 20))
        and m.onRoad ~= true and m.roadAhead ~= true then
        -- a join that has the vehicle pointing well away from the road it is meant to join
        return stop("pointing away from the road")
    end

    if level == 1 then
        if state.correctStartY == nil then
            state.correctStartY = absY
            state.correctMs = 0
        end
        state.correctMs = state.correctMs + dt
        if state.correctMs >= RoadSupervisor.CORRECT_TIMEOUT_MS then
            if absY >= state.correctStartY - 0.1 then
                if onRoad == true then
                    -- correcting for a long time with the vehicle still on the road: the line is what is wrong,
                    -- not the vehicle. Stop second-guessing it for a while.
                    state.suppressMs = RoadSupervisor.SUPPRESS_MS
                    state.correctMs, state.correctStartY = 0, nil
                    level = 0
                else
                    return stop("not coming back onto the road")
                end
            else
                state.correctStartY = absY
                state.correctMs = 0
            end
        end
    else
        state.correctMs = 0
        state.correctStartY = nil
    end

    -- the steering is at the limit of what the speed allows and the vehicle is still off-centre (and not
    -- known to be on the road)
    if m.saturated and absY > m.limit * RoadSupervisor.SATURATED_MIN_Y and not capturing and onRoad ~= true then
        state.saturatedMs = state.saturatedMs + dt
        if state.saturatedMs >= RoadSupervisor.SATURATED_STOP_MS then
            return stop("steering at its limit")
        end
    else
        state.saturatedMs = math.max(0, state.saturatedMs - dt * 2)
    end

    if rejoining and not m.capturing then
        level = 1                      -- slowly, towards the line
    end
    state.level = level
    return { level = level, stop = false, speedShare = level == 1 and RoadSupervisor.CORRECT_SPEED_SHARE or nil, rejoining = rejoining or nil }
end
