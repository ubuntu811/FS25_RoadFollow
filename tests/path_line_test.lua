dofile("tests/stubs.lua")
Logging = { info = function() end }
-- the real path store from the WAILA mod (same machine, sibling folder): the follower is built against it
dofile("../FS25_whatAmILookingAt/scripts/WailaPathStore.lua")
dofile("scripts/RoadCenterline.lua")
local RC, S = RoadCenterline, WailaPathStore
local function near(a, b, tolerance) return math.abs(a - b) <= tolerance end

-- a straight two-way road east, z = 0, x 0..200
S.clear()
local east = S.add({ points = { { 0, 0 }, { 200, 0 } }, kind = "spline", source = "map", width = 7 })

-- 1. vehicle on the path, heading east
local r = RC.pathLine(S, 50, 0, 1, 0, { reach = 30 })
check("heading east on the path: valid, mode path, from the map", r.valid and r.mode == "path" and r.source == "map" and r.kind == "spline")
check("the line is about 30 m long and runs east", near(RC.length(r.points), 30, 0.6) and near(r.points[#r.points][1], 80, 0.6) and near(r.points[#r.points][2], 0, 0.01))
check("points are about 2 m apart", #r.points >= 15 and #r.points <= 17)
check("not at its end, not a junction, not open ground", r.ends == false and r.junction == false and r.openGround == false)
check("offset 0 on the path", near(r.offset, 0, 1e-6))

-- 2. a little to the side: the sign says which side the path is on (+ = path on the left of the vehicle)
r = RC.pathLine(S, 50, 2, 1, 0, { reach = 30 })
check("vehicle 2 m left of the path (z = 2, heading east): the path is to its right, offset -2", near(r.offset, -2, 1e-6))
r = RC.pathLine(S, 50, -2, 1, 0, { reach = 30 })
check("vehicle 2 m right of the path: offset +2", near(r.offset, 2, 1e-6))

-- 3. heading west on a two-way path
r = RC.pathLine(S, 150, 0, -1, 0, { reach = 30 })
check("heading west: the line runs west", r.valid and near(r.points[#r.points][1], 120, 0.6))

-- 4. a one-way path only counts the way it runs
S.clear()
local lane = S.add({ points = { { 0, 0 }, { 200, 0 } }, kind = "recorded", oneWay = true })
check("one-way path, vehicle going its way: followed", RC.pathLine(S, 50, 0, 1, 0, { reach = 30 }).valid)
check("one-way path, vehicle going the other way: not used", RC.pathLine(S, 50, 0, -1, 0, { reach = 30 }).valid == false)

-- 5. across the path is not along it
S.clear()
S.add({ points = { { 0, 0 }, { 200, 0 } } })
check("heading north across an east-west path: no path here", RC.pathLine(S, 50, 0, 0, 1, { reach = 30 }).valid == false)
check("heading 30 degrees off the path: still along it", RC.pathLine(S, 50, 0, math.cos(math.rad(30)), math.sin(math.rad(30)), { reach = 30 }).valid)
check("20 m away: too far", RC.pathLine(S, 50, 20, 1, 0, { reach = 30 }).valid == false)

-- 6. the path ends
r = RC.pathLine(S, 185, 0, 1, 0, { reach = 40 })
check("15 m from the end of the path with 40 m asked: the line stops at the end, ends = true", r.valid and r.ends and near(r.points[#r.points][1], 200, 0.1) and RC.length(r.points) < 16)

-- 7. roads cut at a junction are followed across: second path starts where the first ends
S.clear()
S.add({ points = { { 0, 0 }, { 100, 0 } }, kind = "spline", source = "map" })
local second = S.add({ points = { { 100, 0 }, { 200, 0 } }, kind = "spline", source = "map" })
r = RC.pathLine(S, 80, 0, 1, 0, { reach = 60 })
check("two paths meeting end to end are one road: the line goes on past x = 100", r.valid and not r.ends and near(r.points[#r.points][1], 140, 0.6))
-- the second one stored the other way round
S.clear()
S.add({ points = { { 0, 0 }, { 100, 0 } }, kind = "spline", source = "map" })
S.add({ points = { { 200, 0 }, { 100, 0 } }, kind = "spline", source = "map" })
r = RC.pathLine(S, 80, 0, 1, 0, { reach = 60 })
check("...also when the next piece is stored backwards", r.valid and not r.ends and near(r.points[#r.points][1], 140, 0.6))
-- a gap of 3 m between the pieces is bridged, 10 m is not
S.clear()
S.add({ points = { { 0, 0 }, { 100, 0 } } })
S.add({ points = { { 103, 0 }, { 200, 0 } } })
check("a 3 m gap between two paths is crossed", not RC.pathLine(S, 80, 0, 1, 0, { reach = 60 }).ends)
S.clear()
S.add({ points = { { 0, 0 }, { 100, 0 } } })
S.add({ points = { { 110, 0 }, { 200, 0 } } })
check("a 10 m gap (an intersection) is crossed", not RC.pathLine(S, 80, 0, 1, 0, { reach = 60 }).ends)
S.clear()
S.add({ points = { { 0, 0 }, { 100, 0 } } })
S.add({ points = { { 125, 0 }, { 200, 0 } } })
check("a 25 m gap is the end of the road", RC.pathLine(S, 80, 0, 1, 0, { reach = 60 }).ends == true)

-- a side road leaving at a right angle is not taken
S.clear()
S.add({ points = { { 0, 0 }, { 100, 0 } } })
S.add({ points = { { 100, 0 }, { 100, 100 } } })
r = RC.pathLine(S, 80, 0, 1, 0, { reach = 60 })
check("a road turning off at 90 degrees is not mistaken for the continuation: the line ends", r.ends == true)

-- 8. a curved path is followed
S.clear()
local arc = {}
for i = 0, 40 do local a = i * 2 / 40; arc[#arc + 1] = { 40 * math.sin(a), 40 * (1 - math.cos(a)) } end
S.add({ points = arc })
r = RC.pathLine(S, 0, 0, 1, 0, { reach = 40 })
local worst = 0
for _, p in ipairs(r.points) do worst = math.max(worst, math.abs(math.sqrt(p[1] ^ 2 + (p[2] - 40) ^ 2) - 40)) end
check("the line follows the curve (every point within 0.3 m of the circle)", r.valid and worst < 0.3)
check("the curvature of that line reads about 1/40", near(RC.curvature(r.points), 1 / 40, 0.01))

-- 9. the lane: keep to the right of the path
S.clear()
S.add({ points = { { 0, 0 }, { 200, 0 } } })
r = RC.pathLine(S, 50, 0, 1, 0, { reach = 30, laneOffset = 2 })
check("lane offset 2 m heading east: the line runs 2 m to the right (z = -2)", near(r.points[5][2], -2, 0.01))
r = RC.pathLine(S, 150, 0, -1, 0, { reach = 30, laneOffset = 2 })
check("heading west the right is the other side (z = +2)", near(r.points[5][2], 2, 0.01))

-- 10. the nearest of two parallel paths is used
S.clear()
local near1 = S.add({ points = { { 0, 3 }, { 200, 3 } } })
local far1 = S.add({ points = { { 0, -3 }, { 200, -3 } } })
r = RC.pathLine(S, 50, 2, 1, 0, { reach = 30 })
check("two parallel lanes: the nearer one is followed", r.pathId == near1)
-- ===== joining a road from the side =====
S.clear()
S.add({ points = { { -500, 0 }, { 500, 0 } }, kind = "spline", source = "map", width = 7 })
local cap = { radius = 40, minAlign = 0.4, blendLength = 40 }
-- vehicle 20 m north of the road (z = 20), heading east-southeast, 25 degrees towards it
local h = { math.cos(math.rad(-25)), math.sin(math.rad(-25)) }
r = RC.pathLine(S, 0, 20, h[1], h[2], { reach = 30 })
check("without the join option a road 20 m away is not seen", r.valid == false)
r = RC.pathLine(S, 0, 20, h[1], h[2], { reach = 30, capture = cap })
check("with it, the road ahead is found and the line is marked as a join", r.valid and r.capturing == true and r.mode == "path")
check("the line starts at the vehicle", near(r.points[1][1], 0, 0.01) and near(r.points[1][2], 20, 0.01))
check("it eases onto the road: the far end is on the path (z = 0)", near(r.points[#r.points][2], 0, 0.05))
local monotone = true
for i = 2, #r.points do if r.points[i][2] > r.points[i - 1][2] + 1e-9 then monotone = false end end
check("coming down from the north, the line only ever descends (no wiggle)", monotone)
check("the line is longer than the blend (it reaches the path and goes on along it)", RC.length(r.points) >= 50)
local joinK = RC.curvature(r.points)
check("a 20 m sideways join over 40 m is a real bend (so the speed logic will slow for it), but not a corner", joinK > 0.01 and joinK < 0.1)
local joinKmh = RC.speedAdvice(r, 80, nil)
check("at an 80 km/h setting that join is taken far slower (under 45 km/h)", joinKmh < 45)
local fast = RC.pathLine(S, 0, 20, h[1], h[2], { reach = 30, capture = { radius = 60, blendLength = 60 } })
check("a longer blend is a gentler curve (lower curvature)", RC.curvature(fast.points) < RC.curvature(r.points))

-- not heading towards the road: not a join
local away = { math.cos(math.rad(25)), math.sin(math.rad(25)) }
check("heading away from the road (25 degrees away) and 20 m off: no join", RC.pathLine(S, 0, 20, away[1], away[2], { reach = 30, capture = cap }).valid == false)
-- across the road: too different a direction
check("heading straight at the road (90 degrees to it): no join (not along it)", RC.pathLine(S, 0, 20, 0, -1, { reach = 30, capture = cap }).valid == false)
-- a road behind us is not chased
check("a road behind the vehicle is not chased", RC.pathLine(S, 0, 20, h[1], -h[2], { reach = 30, capture = cap }).valid == false)
-- parallel and close (within near distance): joined although not closing
r = RC.pathLine(S, 0, 7, 1, 0, { reach = 30, capture = cap })
check("alongside the road 7 m away, pointing the same way: a join (a lane change)", r.valid and r.capturing)
-- far parallel (30 m away): needs closing
check("30 m away and exactly parallel: not chased (it is not coming closer)", RC.pathLine(S, 0, 30, 1, 0, { reach = 30, capture = cap }).valid == false)
-- one-way path against the direction: not joined
S.clear()
S.add({ points = { { -500, 0 }, { 500, 0 } }, kind = "recorded", oneWay = true })
check("a one-way path running against us is not joined", RC.pathLine(S, 0, 20, -h[1], h[2], { reach = 30, capture = cap }).valid == false)
-- on the path already: not a join
S.clear()
S.add({ points = { { -500, 0 }, { 500, 0 } } })
r = RC.pathLine(S, 0, 1, 1, 0, { reach = 30, capture = cap })
check("already on the road: plain following, not a join", r.valid and not r.capturing)
-- ===== intersections =====
-- a crossing at x = 0: the main road east-west is cut at the intersection (12 m gap), the side roads
-- start at the edge of the intersection box (8 m north and south of the main road's line)
local function crossing()
    S.clear()
    S.add({ points = { { -300, 0 }, { -6, 0 } }, kind = "spline", source = "map" })     -- main, west half
    S.add({ points = { { 6, 0 }, { 300, 0 } }, kind = "spline", source = "map" })       -- main, east half
    S.add({ points = { { 0, 8 }, { 0, 300 } }, kind = "spline", source = "map" })       -- side road north (left of an eastbound vehicle)
    S.add({ points = { { 0, -8 }, { 0, -300 } }, kind = "spline", source = "map" })     -- side road south (right)
end
crossing()
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100 })
check("crossing, no intent: straight across the intersection", r.valid and not r.ends and near(r.points[#r.points][2], 0, 0.5) and r.points[#r.points][1] > 30)
check("... and it says it crossed a junction", r.junctions >= 1 and r.turned == false)
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100, intent = "left" })
check("left intent: turns north onto the left side road", r.valid and r.points[#r.points][2] > 30 and near(r.points[#r.points][1], 0, 1.0) and r.turned == true)
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100, intent = "right" })
check("right intent: turns south onto the right side road", r.valid and r.points[#r.points][2] < -30 and r.turned == true)
-- the other way: heading north, a "left" is west and there is no road west: the intent finds nothing, goes straight
r = RC.pathLine(S, 0, 100, 0, -1, { reach = 80 })
check("(sanity) heading south along the north side road: straight on to the intersection", r.valid)
r = RC.pathLine(S, 0, 100, 0, -1, { reach = 150, intent = "left" })
check("heading south, left intent = east: turns onto the east half of the main road", r.valid and r.points[#r.points][1] > 20 and near(r.points[#r.points][2], 0, 1.0))
r = RC.pathLine(S, 0, 100, 0, -1, { reach = 150, intent = "right" })
check("heading south, right intent = west", r.valid and r.points[#r.points][1] < -20)
-- a turn intent with no road to turn onto: straight on
S.clear()
S.add({ points = { { -300, 0 }, { 300, 0 } } })
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100, intent = "left" })
check("a left intent with no left turn anywhere: carry on straight, nothing turned", r.valid and not r.turned and near(r.points[#r.points][2], 0, 0.1))

-- a T-junction where the side road starts in the MIDDLE of the main road (one long main spline)
S.clear()
S.add({ points = { { -300, 0 }, { 300, 0 } }, kind = "spline", source = "map" })
S.add({ points = { { 0, 0 }, { 0, 300 } }, kind = "spline", source = "map" })
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100 })
check("T-junction, no intent: straight along the main road", r.valid and near(r.points[#r.points][2], 0, 0.1) and r.points[#r.points][1] > 30)
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100, intent = "left" })
check("T-junction, left intent: leaves the main road at the side road and goes north", r.valid and r.points[#r.points][2] > 20 and near(r.points[#r.points][1], 0, 1.5) and r.turned)
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100, intent = "right" })
check("T-junction, right intent with only a left side road: stays on the main road", r.valid and near(r.points[#r.points][2], 0, 0.1) and not r.turned)

-- a branch that leaves TANGENTIALLY: it starts out lined up with the main road (this is what fooled the first version)
S.clear()
S.add({ points = { { -300, 0 }, { 0, 0 } }, kind = "spline", source = "map" })               -- main, up to the junction
S.add({ points = { { 0, 0 }, { 300, 0 } }, kind = "spline", source = "map" })                -- straight on
-- a side road that leaves tangentially and curves away to the left within the 15 m a branch is judged over
local bend = { { 0, 0 }, { 5, 0.8 }, { 9, 3 }, { 12, 6 }, { 14, 10 }, { 15, 15 }, { 15, 25 }, { 15, 60 }, { 15, 120 } }
S.add({ points = bend, kind = "spline", source = "map" })                                    -- curves away to the left
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100 })
check("a branch that starts tangentially and bends away: with no intent the vehicle goes straight (this is the bug)", r.valid and near(r.points[#r.points][2], 0, 0.5) and r.points[#r.points][1] > 30)
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100, intent = "left" })
check("... and with a left intent it takes the branch", r.valid and r.points[#r.points][2] > 15 and r.turned)
-- starting right at the junction, both paths within reach of the vehicle: straight wins
r = RC.pathLine(S, 1, 0.5, 1, 0, { reach = 60 })
check("standing at the junction with both paths beside you: the straight one is chosen", r.valid and near(r.points[#r.points][2], 0, 0.6))
r = RC.pathLine(S, 1, 0.5, 1, 0, { reach = 60, intent = "left" })
check("... and the left one when the left signal is on", r.valid and r.points[#r.points][2] > 8)

-- one-way lanes: only the way they run
S.clear()
S.add({ points = { { -300, 0 }, { -6, 0 } }, oneWay = true })
S.add({ points = { { 6, 0 }, { 300, 0 } }, oneWay = true })
S.add({ points = { { 0, 300 }, { 0, 8 } }, oneWay = true })      -- runs TOWARDS the junction: not an exit
r = RC.pathLine(S, -60, 0, 1, 0, { reach = 100, intent = "left" })
check("a left intent does not take a one-way road that runs the wrong way (it leads in, not out)", r.valid and not r.turned and r.points[#r.points][1] > 30)
-- ===== a 90 degree corner in a path =====
S.clear()
S.add({ points = { { 0, 0 }, { 100, 0 }, { 100, 100 } }, kind = "spline", source = "map" })
r = RC.pathLine(S, 60, 0, 1, 0, { reach = 60 })
check("a path with a 90 degree vertex: the corner is flagged", r.valid and r.corner == true)
local onArc = true
for _, p in ipairs(r.points) do
    if p[1] > 91 and p[2] > 0.5 and p[2] < 9.5 then
        local d = math.sqrt((p[1] - 90) ^ 2 + (p[2] - 10) ^ 2)
        if math.abs(d - 10) > 0.4 then onArc = false end
    end
end
check("... and rounded with an arc of 10 m radius (not a sharp point)", onArc and RC.curvature(r.points) > 0.03)
local lastPoint = r.points[#r.points]
check("... the line goes on along the second leg", lastPoint[2] > 15 and math.abs(lastPoint[1] - 100) < 0.5)
S.clear()
S.add({ points = { { 0, 0 }, { 100, 0 }, { 120, 8 } }, kind = "spline", source = "map" })
r = RC.pathLine(S, 60, 0, 1, 0, { reach = 70 })
check("a bend of only 22 degrees is no corner", r.corner == false)

-- ===== lane splines: the one that runs our way =====
S.clear()
local rightLane = S.add({ points = { { 0, 1.75 }, { 200, 1.75 } }, kind = "spline", source = "map" })      -- z = +1.75: the right of an eastbound vehicle (z points south)
local leftLane = S.add({ points = { { 200, -1.75 }, { 0, -1.75 } }, kind = "spline", source = "map" })     -- the other lane, drawn the other way
r = RC.pathLine(S, 50, -0.5, 1, 0, { reach = 30 })
check("two lane splines, we are nearer the one drawn against us: the one that runs our way is followed", r.pathId == rightLane)
r = RC.pathLine(S, 50, -1.75, 1, 0, { reach = 30 })
check("even exactly on the wrong-way lane: back to the right one", r.pathId == rightLane and math.abs(r.offset) > 2.5)
r = RC.pathLine(S, 50, 1.75, -1, 0, { reach = 30 })
check("heading west the roles swap: the other spline runs our way", r.pathId == leftLane)
S.clear()
local single = S.add({ points = { { 200, 0 }, { 0, 0 } }, kind = "spline", source = "map" })
r = RC.pathLine(S, 50, 0, 1, 0, { reach = 30 })
check("a single two-way spline drawn against us is still followed (the penalty only ranks candidates)", r.valid and r.pathId == single)

-- a signalled turn keeps the road it picked: with two roads to turn onto, the one remembered from the earlier scan stays
S.clear()
S.add({ points = { { 0, 0 }, { 106, 0 } }, kind = "spline", source = "map", oneWay = true })
local turnNear = S.add({ points = { { 108.5, 3 }, { 108.5, 150 } }, kind = "spline", source = "map", oneWay = true })
local turnFar = S.add({ points = { { 111.5, 6 }, { 111.5, 150 } }, kind = "spline", source = "map", oneWay = true })
r = RC.pathLine(S, 90, 0, 1, 0, { reach = 40, intent = "left" })
check("a left turn onto the nearer of two roads: that one, and it is reported as the turn's target", r.valid and r.turned and r.targetPathId == turnNear)
r = RC.pathLine(S, 90, 0, 1, 0, { reach = 40, intent = "left", targetPath = turnFar })
check("... but the road remembered from the earlier scan stays the target", r.valid and r.turned and r.targetPathId == turnFar)

-- turning onto a road with a lane spline each way (drawn in the traffic direction): right turn -> the near lane, left turn -> the far lane
S.clear()
S.add({ points = { { 0, 0 }, { 106, 0 } }, kind = "spline", source = "map" })
local nearLaneId = S.add({ points = { { 108.5, 150 }, { 108.5, -150 } }, kind = "spline", source = "map" })     -- drawn towards -z
local farLaneId = S.add({ points = { { 111.5, -150 }, { 111.5, 150 } }, kind = "spline", source = "map" })      -- drawn towards +z
r = RC.pathLine(S, 90, 0, 1, 0, { reach = 40, intent = "left" })
check("left turn onto a two-lane road: the far lane (the one that runs that way)", r.turned and r.targetPathId == farLaneId and near(r.points[#r.points][1], 111.5, 0.6))
r = RC.pathLine(S, 90, 0, 1, 0, { reach = 40, intent = "right" })
check("right turn onto a two-lane road: the near lane", r.turned and r.targetPathId == nearLaneId and near(r.points[#r.points][1], 108.5, 0.6))

finish("path_line_test")
