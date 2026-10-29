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

finish("road_hud_test")
