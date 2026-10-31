dofile("tests/stubs.lua")
dofile("scripts/RoadHud.lua")
local H = RoadHud
local function near(a, b, t) return math.abs(a - b) <= (t or 1e-6) end

-- scale: the full arc is the set speed, rounded up to ten, at least 30
check("scale for 40 set is 40", H.scaleFor(40) == 40)
check("scale for 43 set is 50", H.scaleFor(43) == 50)
check("scale for 12 set is the 30 minimum", H.scaleFor(12) == 30)
check("scale with no set speed falls back to 50", H.scaleFor(nil) == 50 and H.scaleFor(0) == 50)

-- lit segments
check("standing still lights nothing", H.litCount(0, 40, 20) == 0)
check("creeping lights the first one", H.litCount(1, 40, 20) == 1)
check("half the scale lights half", H.litCount(20, 40, 20) == 10)
check("the set speed lights all", H.litCount(40, 40, 20) == 20)
check("faster than the scale stays at all", H.litCount(55, 40, 20) == 20)
check("no speed value lights nothing", H.litCount(nil, 40, 20) == 0)
check("the set speed is marked on the last segment at full scale", H.setIndex(40, 40, 20) == 20)
check("a set speed of half the scale marks segment 10", H.setIndex(20, 40, 20) == 10)
check("no set speed, no mark", H.setIndex(nil, 40, 20) == nil)

-- blinking
check("blink is on at the start of a period", H.blinkOn(0, 400) == true)
check("blink is off in the second half-period", H.blinkOn(450, 400) == false)
check("blink is on again", H.blinkOn(850, 400) == true)

-- colours by state
check("no assist: idle", H.kindFor(nil) == "idle")
check("assist not engaged: idle", H.kindFor({ engaged = false }) == "idle")
check("engaged, fine: ok", H.kindFor({ engaged = true, sup = { level = 0 } }) == "ok")
check("engaged, correcting: correct", H.kindFor({ engaged = true, sup = { level = 1 } }) == "correct")
check("engaged, stopping: stop", H.kindFor({ engaged = true, sup = { stopping = true, level = 2 } }) == "stop")

-- the arc: 20 segments, 270 degrees, opening at the bottom
local arc = H.arcLayout(20, 0.07, 0.016, 225, 270, 0.28)
check("20 segments", #arc == 20)
check("the first segment is bottom left", arc[1].x < 0 and arc[1].y < 0)
check("the last segment is bottom right", arc[20].x > 0 and arc[20].y < 0)
check("the arc is mirror-symmetric (first and last)", near(arc[1].x, -arc[20].x) and near(arc[1].y, arc[20].y))
check("the middle segments are at the top", arc[10].y > 0.05 and arc[11].y > 0.05)
check("the bottom is open (no segment near straight down)", (function()
    for _, s in ipairs(arc) do if s.y < -0.049 and math.abs(s.x) < 0.02 then return false end end
    return true
end)())
check("every segment sits on the ring's middle radius", (function()
    for _, s in ipairs(arc) do if not near(math.sqrt(s.x * s.x + s.y * s.y), 0.062, 1e-9) then return false end end
    return true
end)())
check("the two segments around the top are tilted equally and oppositely", near(arc[10].rot, 6.75, 1e-9) and near(arc[11].rot, -6.75, 1e-9))
check("segment 1 points along its own radius (rot = angle - 90)", near(arc[1].rot, 225 - 6.75 - 90, 1e-9))
check("segments are told apart by gaps (width below slot arc length)", arc[1].w < 0.062 * math.rad(13.5))

-- the arrows: a shaft and two head bars, mirror images of each other
local left, right = H.arrowBars("left", 0.034, 0.008), H.arrowBars("right", 0.034, 0.008)
check("an arrow is 3 bars", #left == 3 and #right == 3)
check("the left arrow's head is on the left (its head bars sit left of centre)", left[2].x < 0 and left[3].x < 0)
check("the right arrow's head is on the right", right[2].x > 0 and right[3].x > 0)
check("head bars are one above, one below the shaft", left[2].y > 0 and left[3].y < 0)
check("head bars lean opposite ways", left[2].rot == -left[3].rot and left[2].rot ~= 0)
check("the right arrow leans the other way from the left (mirrored)", right[2].rot == -left[2].rot)
check("each head bar's far end reaches back of the tip: a bar's end at the tip",
    (function()
        local b = left[2]            -- tip is at x = -0.017, y = 0; the bar's tip end is half a bar from its centre
        local r = math.rad(b.rot)
        local tipEndX = b.x - math.cos(r) * b.w / 2
        local tipEndY = b.y - math.sin(r) * b.w / 2
        return near(tipEndX, -0.017, 1e-9) and near(tipEndY, 0, 1e-9)
    end)())

-- ===== the junction picture =====
dofile("scripts/RoadJunction.lua")
do
    local function leg(rel, approach) return { rel = rel, approach = approach } end
    local approachLeg, ahead, left, right = leg(math.pi, true), leg(0), leg(-math.pi / 2), leg(math.pi / 2)
    local plus = { x = 0, z = 0, distance = 100, type = "+", legs = { approachLeg, left, ahead, right }, others = { left, ahead, right }, approach = approachLeg }
    local tee = { x = 0, z = 0, distance = 100, type = "T", legs = { approachLeg, left, right }, others = { left, right }, approach = approachLeg }
    local H = RoadHud
    local C = H.JUNCTION_COLORS
    local function barOf(bars, which) for _, b in ipairs(bars) do if b.leg == which then return b end end end
    local function same(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4] end

    check("no junction: no bars", #H.junctionBars(nil, nil, 0) == 0)
    local bars = H.junctionBars(plus, nil, 0)
    check("a crossing: a bar for every leg and a mark for you", #bars == 5 and bars[#bars].you == true)
    local b = barOf(bars, approachLeg)
    check("the road you come along is at the bottom", math.abs(b.x) < 1e-6 and b.y < 0 and same(b.color, C.approach))
    b = barOf(bars, ahead)
    check("straight on is up", math.abs(b.x) < 1e-6 and b.y > 0)
    check("left is to the left and right to the right", barOf(bars, left).x < 0 and barOf(bars, right).x > 0)
    check("a leg bar is as long as the leg length, thin, and turned to point along the leg (left: 180, straight on: 90, right: 0 degrees)",
        math.abs(barOf(bars, ahead).w - H.JUNCTION_LEG) < 1e-9 and barOf(bars, left).h == H.JUNCTION_THICK and math.abs(math.abs(barOf(bars, left).rot) - 180) < 1e-6
        and math.abs(barOf(bars, ahead).rot - 90) < 1e-6 and math.abs(barOf(bars, right).rot) < 1e-6)

    -- nothing signalled: the ways on blink, straight on at a crossing is green (its default)
    local on = H.junctionBars(plus, nil, 0)                         -- blink phase on
    local off = H.junctionBars(plus, nil, H.BLINK_MS)               -- blink phase off
    check("no signal at a crossing: straight on is green and steady, the side legs blink", same(barOf(on, ahead).color, C.chosen) and same(barOf(off, ahead).color, C.chosen)
        and same(barOf(on, left).color, C.leg) and same(barOf(off, left).color, C.dim) and same(barOf(on, right).color, C.leg) and same(barOf(off, right).color, C.dim))
    check("... the leg that is chosen is drawn thicker", barOf(on, ahead).h > H.JUNCTION_THICK)
    -- a T: no default, everything blinks
    on, off = H.junctionBars(tee, nil, 0), H.junctionBars(tee, nil, H.BLINK_MS)
    check("a T with no signal: both legs blink, nothing is green", same(barOf(on, left).color, C.leg) and same(barOf(off, left).color, C.dim) and same(barOf(on, right).color, C.leg) and same(barOf(off, right).color, C.dim))
    -- signalled: the leg is green and steady, the others dim and still, the blinking has stopped
    for _, t in ipairs({ 0, H.BLINK_MS }) do
        local s = H.junctionBars(tee, "left", t)
        check("a T, left signalled (blink phase " .. t .. "): the left leg green and steady, the right one dim and still", same(barOf(s, left).color, C.chosen) and same(barOf(s, right).color, C.dim))
    end
    local s = H.junctionBars(plus, "right", 0)
    check("a crossing, right signalled: the right leg is green, straight on is not (it was only the default)", same(barOf(s, right).color, C.chosen) and same(barOf(s, ahead).color, C.dim))
    s = H.junctionBars({ x = 0, z = 0, distance = 50, type = "t", legs = { approachLeg, ahead, right }, others = { ahead, right }, approach = approachLeg }, "left", 0)
    check("signalling a side where there is no way: nothing is green", barOf(s, ahead).color == C.dim and barOf(s, right).color == C.dim)
    check("a hazard is no decision: the picture goes on blinking", same(barOf(H.junctionBars(tee, "hazard", 0), left).color, C.leg) and same(barOf(H.junctionBars(tee, "hazard", H.BLINK_MS), left).color, C.dim))
    -- the angles are tidied to multiples of 15 degrees
    local odd = { x = 0, z = 0, distance = 50, type = "Y", legs = { approachLeg, leg(math.rad(-37)), leg(math.rad(32)) }, others = {}, approach = approachLeg }
    odd.others = { odd.legs[2], odd.legs[3] }
    local ob = H.junctionBars(odd, nil, 0)
    check("legs at 37 degrees left and 32 right are drawn at 30 / 30 (tidied to 15 degree steps)", math.abs(ob[2].x / ob[2].y + math.tan(math.rad(30))) < 1e-6 and math.abs(ob[3].x / ob[3].y - math.tan(math.rad(30))) < 1e-6)
    check("the distance is shown to the nearest ten metres", H.junctionDistanceText(104) == "100 m" and H.junctionDistanceText(96) == "100 m" and H.junctionDistanceText(7) == "10 m")
end

finish("road_hud_test")
