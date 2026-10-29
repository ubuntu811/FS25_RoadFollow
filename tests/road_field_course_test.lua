dofile("tests/stubs.lua")
dofile("scripts/RoadFieldCourse.lua")
local F = RoadFieldCourse

-- obstacles: trees { x, z, r } and rectangles { x1, z1, x2, z2 }
local function world(trees, rects)
    return function(x, z)
        for _, t in ipairs(trees or {}) do
            if (x - t[1]) ^ 2 + (z - t[2]) ^ 2 <= t[3] * t[3] then return true end
        end
        for _, r in ipairs(rects or {}) do
            if x >= r[1] and x <= r[3] and z >= r[2] and z <= r[4] then return true end
        end
        return false
    end
end

-- a vehicle that follows the first stretch of each plan exactly, re-planned every 0.2 s
local function drive(blocked, seconds, options)
    options = options or {}
    local speed = options.speed or 5.0
    local x, z, theta = 0, 0, 0
    local ref = { x = 0, z = 0, dx = 1, dz = 0 }
    local previous = 0
    local worstClearance, crossings, lastSign = math.huge, 0, 0
    local trail = {}
    local stoppedAt = nil
    for i = 1, seconds * 5 do
        local plan = F.plan(blocked, x, z, math.cos(theta), math.sin(theta), ref, { length = options.length or 50, halfWidth = options.halfWidth or 2.2, previous = previous })
        if plan.blockedAhead then
            stoppedAt = { x, z, plan.free }
            break
        end
        previous = plan.kappa
        local sign = plan.kappa > 0.012 and 1 or (plan.kappa < -0.012 and -1 or 0)
        if sign ~= 0 and lastSign ~= 0 and sign ~= lastSign then crossings = crossings + 1 end
        if sign ~= 0 then lastSign = sign end
        x, z, theta = F.arcPoint(x, z, theta, plan.kappa, speed * 0.2)
        trail[#trail + 1] = { x, z }
        if blocked(x, z) then worstClearance = 0 end
    end
    return { x = x, z = z, theta = theta, trail = trail, crossings = crossings, stoppedAt = stoppedAt, hit = worstClearance == 0 }
end
local function maxAbsZ(trail, fromX, toX)
    local m = 0
    for _, p in ipairs(trail) do if p[1] >= fromX and p[1] <= toX then m = math.max(m, math.abs(p[2])) end end
    return m
end

-- 1. an empty field: straight on along the reference line
local r = drive(world(), 20)
check("an empty field: straight on, never off the line", maxAbsZ(r.trail, 0, 1000) < 0.01 and r.x > 95)

-- 2. one tree on the line
r = drive(world({ { 40, 0, 1.5 } }), 30)
check("a tree on the line: no collision", not r.hit and r.stoppedAt == nil)
check("... passed with room (the middle of the vehicle at least 3.7 m from the trunk)", maxAbsZ(r.trail, 30, 50) >= 3.7)
check("... the line is rejoined behind it (within 1.5 m of it 60 m on)", math.abs(r.trail[#r.trail][2]) < 1.5 and r.x > 100)
check("... the heading comes back (within 5 degrees)", math.abs(r.theta) < math.rad(5))
check("... without hunting from side to side (at most 2 changes of direction)", r.crossings <= 2)

-- 3. a row of trees across 24 m
local row = {}
for z = -12, 12, 3 do row[#row + 1] = { 50, z, 1.2 } end
r = drive(world(row), 40)
check("a row of trees 24 m wide across the way: round it, no collision", not r.hit and r.stoppedAt == nil and r.x > 100)

-- 4. a building 15 x 40 m
r = drive(world(nil, { { 45, -20, 60, 20 } }), 45)
check("a 15 x 40 m building ahead: round it, no collision", not r.hit and r.stoppedAt == nil)
check("... and back on course afterwards (heading within 8 degrees, off the line by under 3 m)", r.x > 100 and math.abs(r.theta) < math.rad(8) and math.abs(r.trail[#r.trail][2]) < 3)

-- 5. a wall across the whole field: stops in front of it, does not drive into it
r = drive(world(nil, { { 60, -300, 70, 300 } }), 40)
check("an endless wall: the plan says 'no way through' before it is reached", r.stoppedAt ~= nil and r.stoppedAt[1] < 58 and not r.hit)

-- 6. a gap between two buildings
local twoBuildings = function(gap) return world(nil, { { 45, -60, 60, -gap / 2 }, { 45, gap / 2, 60, 60 } }) end
r = drive(twoBuildings(9), 40)
check("a 9 m gap between two buildings (vehicle 4.4 m wide with its clearance): driven through", not r.hit and r.stoppedAt == nil and r.x > 80)
r = drive(twoBuildings(3.5), 40)
local through = false
for _, p in ipairs(r.trail) do if p[1] > 46 and p[1] < 59 and math.abs(p[2]) < 3 then through = true end end
check("a 3.5 m gap (too narrow): not driven through (round the buildings, or stopped in front)", not through and not r.hit)

-- 7. the plan's own contract
local plan = F.plan(world(), 0, 0, 1, 0, { x = 0, z = 0, dx = 1, dz = 0 }, { length = 20 })
check("the plan is a polyline every 2 m starting at the vehicle", plan.points[1][1] == 0 and #plan.points == 11 and plan.clear == true and plan.free == 20)
plan = F.plan(world({ { 25, 0, 1 } }, nil), 0, 0, 1, 0, { x = 0, z = 0, dx = 1, dz = 0 }, { length = 40, halfWidth = 2.2 })
check("a tree 25 m ahead with room beside it: the plan turns away (curvature not 0) and is free for the whole look-ahead", plan.kappa ~= 0 and plan.clear == true)
plan = F.plan(world({ { 6, 0, 1 } }, nil), 0, 0, 1, 0, { x = 0, z = 0, dx = 1, dz = 0 }, { length = 40, halfWidth = 2.2 })
check("a tree 6 m ahead (too late to turn away at these radii): the plan says there is no way on", plan.blockedAhead == true)

finish("road_field_course_test")
