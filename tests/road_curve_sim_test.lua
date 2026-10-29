-- Closed loop: how closely the assist follows bends, from stored paths (exact lines) and from map pictures (2 m pixels).
local S = dofile("tests/sim_harness.lua")
local store = S.store

local function trueDistance(poly, x, z)
    local best = math.huge
    for i = 1, #poly - 1 do
        local ax, az, bx, bz = poly[i][1], poly[i][2], poly[i + 1][1], poly[i + 1][2]
        local sx, sz = bx - ax, bz - az
        local t = math.max(0, math.min(1, ((x - ax) * sx + (z - az) * sz) / (sx * sx + sz * sz)))
        best = math.min(best, math.sqrt((x - (ax + sx * t)) ^ 2 + (z - (az + sz * t)) ^ 2))
    end
    return best
end
local function arcPoly(radius)
    local pts = { { -100, 0 }, { 150, 0 } }
    for i = 1, 60 do
        local a = math.rad(90) * i / 60
        pts[#pts + 1] = { 150 + radius * math.sin(a), radius * (1 - math.cos(a)) }
    end
    pts[#pts + 1] = { 150 + radius + 0.01, radius + 400 }
    return pts
end

-- paths: a 90 degree bend at various radii and speeds
for _, cfg in ipairs({ { 100, 60, 0.8 }, { 40, 40, 0.8 }, { 25, 30, 1.0 } }) do
    local radius, kmh, allowed = cfg[1], cfg[2], cfg[3]
    store.clear()
    local poly = arcPoly(radius)
    store.add({ points = poly, kind = "spline", source = "map", width = 7 })
    local v = S.newVehicle(0, 0, kmh)
    v.spec_drivable.cruiseControl.speed = kmh
    local worst, stopped, minSpeed = 0, nil, math.huge
    S.simulate(v, 60, function(veh)
        if S.assistOf(veh).sup.stopping then stopped = S.assistOf(veh).sup.reason return false end
        if veh.pos[1] > 120 and veh.pos[2] < radius + 100 then
            worst = math.max(worst, trueDistance(poly, veh.pos[1], veh.pos[2]))
            minSpeed = math.min(minSpeed, veh.speed)
        end
        if veh.pos[2] > radius + 100 then return false end
    end)
    check(string.format("a 90 degree bend, radius %d m, at %d km/h from a stored path: no stop, never more than %.1f m from the path (worst %.2f)", radius, kmh, allowed, worst), stopped == nil and worst <= allowed)
    check(string.format("... radius %d m: no stop-and-go, it does not crawl through the bend (slowest %.0f km/h)", radius, minSpeed), minSpeed > kmh * 0.4)
end

-- a straight road, the vehicle 2 m off its line at 80 km/h: it comes back without swinging
store.clear()
local straight = { { -100, 0 }, { 2000, 0 } }
store.add({ points = straight, kind = "spline", source = "map", width = 7 })
local v = S.newVehicle(0, 2.0, 80)
v.spec_drivable.cruiseControl.speed = 80
local overshoot, settledAt = 0, nil
S.simulate(v, 20, function(veh, t)
    if S.assistOf(veh).sup.stopping then return false end
    local y = veh.pos[2]
    if t > 1 and y < 0 then overshoot = math.max(overshoot, -y) end
    if settledAt == nil and math.abs(y) < 0.1 then settledAt = t end
end)
check("2 m off the line at 80 km/h: it is back on it within 8 s", settledAt ~= nil and settledAt < 8)
check("... and does not swing past it by more than 0.6 m (overshoot " .. string.format("%.2f", overshoot) .. ")", overshoot < 0.6)
check("... and stays on it afterwards (end within 0.15 m)", math.abs(v.pos[2]) < 0.15)

-- map pictures: the same bend as a road of 2 m pixels (a trail of 6 m): the line is noisy, the steering must stay calm
for _, cfg in ipairs({ { 80, 50, 2.2 }, { 40, 40, 2.5 } }) do
    local radius, kmh, allowed = cfg[1], cfg[2], cfg[3]
    store.clear()
    S.setBitmap(true)
    local function roadAt(x, z)
        local cx, cz = (math.floor(x / 2) + 0.5) * 2, (math.floor(z / 2) + 0.5) * 2
        if cx < -100 then return 0 end
        if cx <= 150 then return math.abs(cz) <= 3 and 2 or 0 end
        local dx, dz = cx - 150, cz - radius
        local d = math.sqrt(dx * dx + dz * dz)
        if cz < radius and math.abs(d - radius) <= 3 then return 2 end
        if cz >= radius and cx >= 150 + radius - 3 and cx <= 150 + radius + 3 then return 2 end
        return 0
    end
    S.setSampler(roadAt)
    local vehicle = S.newVehicle(0, 0, kmh)
    vehicle.spec_drivable.cruiseControl.speed = kmh
    local poly = arcPoly(radius)
    local worst, stopped, headingSwing = 0, nil, 0
    local lastHeading
    S.simulate(vehicle, 60, function(veh)
        local a = S.assistOf(veh)
        if a.sup.stopping then stopped = a.sup.reason return false end
        if veh.pos[1] > 120 and veh.pos[2] < radius + 60 then
            worst = math.max(worst, trueDistance(poly, veh.pos[1], veh.pos[2]))
            local h = math.atan2(veh.heading[2], veh.heading[1])
            if lastHeading ~= nil then headingSwing = math.max(headingSwing, math.abs(h - lastHeading)) end
            lastHeading = h
        end
        if veh.pos[2] > radius + 60 then return false end
    end)
    check(string.format("a 90 degree bend, radius %d m, at %d km/h from map pictures (2 m pixels): no stop, within %.1f m of the true road middle (worst %.2f)", radius, kmh, allowed, worst), stopped == nil and worst <= allowed)
    check(string.format("... radius %d m: the heading changes smoothly (no tick turns more than 0.6 degrees)", radius), headingSwing < math.rad(0.6))
    S.setBitmap(false)
    S.setSampler(function() return 0 end)
end

-- ===== real vehicles are slower than the ideal one: delay and lag in the steering =====
for _, dyn in ipairs({ { name = "responsive car", delay = 0.1, lag = 0.2 }, { name = "typical", delay = 0.15, lag = 0.25 }, { name = "sluggish tractor with trailers", delay = 0.25, lag = 0.4 } }) do
    for _, kmh in ipairs({ 30, 50, 80 }) do
        store.clear()
        store.add({ points = { { -100, 0 }, { 6000, 0 } }, kind = "spline", source = "map", width = 7 })
        local vehicle = S.newVehicle(0, 2.0, kmh)
        vehicle.spec_drivable.cruiseControl.speed = kmh
        local peak, stopped = 0, nil
        S.simulate(vehicle, 40, function(veh, t)
            if S.assistOf(veh).sup.stopping then stopped = S.assistOf(veh).sup.reason return false end
            if t > 12 then peak = math.max(peak, math.abs(veh.pos[2])) end
        end, dyn)
        check(string.format("%s at %d km/h, started 2 m off a straight line: it settles, no sustained weaving (after 12 s never more than 0.3 m off; %.2f)", dyn.name, kmh, peak), stopped == nil and peak < 0.3)
    end
end
for _, dyn in ipairs({ { name = "typical", delay = 0.15, lag = 0.25, allow = 0.8 }, { name = "sluggish tractor with trailers", delay = 0.25, lag = 0.4, allow = 1.6 } }) do
    store.clear()
    local poly = arcPoly(40)
    store.add({ points = poly, kind = "spline", source = "map", width = 7 })
    local vehicle = S.newVehicle(0, 0, 40)
    vehicle.spec_drivable.cruiseControl.speed = 40
    local worst, stopped = 0, nil
    S.simulate(vehicle, 60, function(veh)
        if S.assistOf(veh).sup.stopping then stopped = S.assistOf(veh).sup.reason return false end
        if veh.pos[1] > 120 and veh.pos[2] < 140 then worst = math.max(worst, trueDistance(poly, veh.pos[1], veh.pos[2])) end
        if veh.pos[2] > 140 then return false end
    end, dyn)
    check(string.format("a radius 40 m bend at 40 km/h, %s: no stop, within %.1f m of the path (worst %.2f)", dyn.name, dyn.allow, worst), stopped == nil and worst <= dyn.allow)
end

-- a correction that is too stiff for the vehicle weaves; once the weave is seen, it is softened until the swings die out
do
    local savedFb = RoadCenterline.STEER_FB_SECONDS
    RoadCenterline.STEER_FB_SECONDS = 0.8                   -- deliberately too stiff for a sluggish vehicle
    store.clear()
    store.add({ points = { { -100, 0 }, { 8000, 0 } }, kind = "spline", source = "map", width = 7 })
    local vehicle = S.newVehicle(0, 2.0, 50)
    vehicle.spec_drivable.cruiseControl.speed = 50
    local firstSwing, lateSwing, stopped = 0, 0, nil
    S.simulate(vehicle, 60, function(veh, t)
        if S.assistOf(veh).sup.stopping then stopped = S.assistOf(veh).sup.reason return false end
        if t > 3 and t < 15 then firstSwing = math.max(firstSwing, math.abs(veh.pos[2])) end
        if t > 40 then lateSwing = math.max(lateSwing, math.abs(veh.pos[2])) end
    end, { delay = 0.25, lag = 0.4 })
    RoadCenterline.STEER_FB_SECONDS = savedFb
    check(string.format("a too stiff correction on a sluggish vehicle first weaves (%.2f m) ...", firstSwing), stopped == nil and firstSwing > 0.5)
    check(string.format("... and once the weave is detected it is softened and the swings die out (after 40 s under 0.2 m; %.2f)", lateSwing), lateSwing < 0.2)
end


-- understeer at speed: the vehicle makes only 1 / (1 + 0.0006 v^2) of the curvature the wheels ask for (at 60 km/h: 0.85). The
-- learned gain makes up for it
do
    local radius, kmh = 150, 60
    local worstOf = {}
    for _, learn in ipairs({ false, true }) do
        RoadFollow.UNDERSTEER_LEARN = learn
        store.clear()
        local poly = arcPoly(radius)
        store.add({ points = poly, kind = "spline", source = "map", width = 7 })
        local v = S.newVehicle(0, 0, kmh)
        v.spec_drivable.cruiseControl.speed = kmh
        local worst = 0
        S.simulate(v, 60, function(veh)
            if S.assistOf(veh).sup.stopping then return false end
            if veh.pos[1] > 120 and veh.pos[2] < radius + 100 then
                worst = math.max(worst, trueDistance(poly, veh.pos[1], veh.pos[2]))
            end
            if veh.pos[2] > radius + 100 then return false end
        end, { understeer = 0.0006 })
        worstOf[learn] = worst
        if learn then worstOf.gain = S.assistOf(v).understeerGain end
    end
    RoadFollow.UNDERSTEER_LEARN = true
    check(string.format("an understeering vehicle in a 150 m bend at 60 km/h: learning cuts the worst error (%.2f without, %.2f with, a third at least)", worstOf[false], worstOf[true]),
        worstOf[true] < worstOf[false] * 0.7 and worstOf[true] < 0.5)
    -- a vehicle that does not understeer is left alone
    store.clear()
    local poly = arcPoly(radius)
    store.add({ points = poly, kind = "spline", source = "map", width = 7 })
    local v = S.newVehicle(0, 0, kmh)
    v.spec_drivable.cruiseControl.speed = kmh
    local maxGain = 1
    S.simulate(v, 60, function(veh)
        maxGain = math.max(maxGain, S.assistOf(veh).understeerGain or 1)
        if veh.pos[2] > radius + 100 then return false end
    end, { understeer = 0 })
    check(string.format("... a vehicle that does not understeer is left alone (largest gain %.2f)", maxGain), maxGain < 1.06)
end
finish("road_curve_sim_test")
