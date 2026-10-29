-- Road Follow HUD: a speed gauge (segmented arc, big number, turn arrows) shown while the road assist is on.
--
-- Two halves. The layout and the little rules (how many segments are lit, which colour, when the arrow
-- blinks) are plain functions with no engine calls, so they are tested offline. The draw function at the
-- bottom is the only part that touches the engine: it uses one white-pixel overlay for everything, rotating
-- it for the arc segments and the arrow heads.
--
-- All sizes are in "screen heights" (0.1 = a tenth of the screen's height); horizontal distances are
-- divided by the aspect ratio when drawing so that circles stay round.
RoadHud = {}

-- g_currentModDirectory only exists while the mod's scripts load, not later when drawing: keep it now
RoadHud.modDirectory = g_currentModDirectory

RoadHud.enabled = true
RoadHud.scale = 1.0
RoadHud.X = 0.5                  -- centre of the gauge on screen (0 to 1)
RoadHud.Y = 0.15
RoadHud.RADIUS = 0.07            -- outer radius of the arc
RoadHud.RING = 0.016             -- thickness of the arc
RoadHud.SEGMENTS = 20
RoadHud.START_DEG = 225          -- the arc starts bottom left and sweeps clockwise over the top ...
RoadHud.SPAN_DEG = 270           -- ... to bottom right
RoadHud.GAP_SHARE = 0.28         -- share of each segment's slot that stays empty
RoadHud.ARROW_SIZE = 0.034
RoadHud.ARROW_THICKNESS = 0.008
RoadHud.ARROW_OFFSET = 0.05      -- from the gauge's rim to the arrow's middle
RoadHud.BLINK_MS = 380
RoadHud.MIN_SCALE_KMH = 30       -- the arc is never scaled for less than this
RoadHud.ROTATION_SIGN = 1        -- flip (console: roadFollowHudFlip) if the engine turns overlays the other way

RoadHud.COLORS = {
    ok = { 0.35, 0.95, 0.35 },
    correct = { 1.0, 0.78, 0.2 },
    stop = { 0.95, 0.25, 0.2 },
    idle = { 0.8, 0.8, 0.8 },
}
RoadHud.UNLIT = { 0.55, 0.6, 0.66, 0.45 }
RoadHud.SET_MARK = { 0.9, 0.95, 1.0, 0.8 }

-- What the full arc stands for: the set cruise speed, rounded up to a whole ten, never below the minimum.
function RoadHud.scaleFor(setKmh)
    if setKmh == nil or setKmh <= 0 then
        return 50
    end
    return math.max(RoadHud.MIN_SCALE_KMH, math.ceil(setKmh / 10 - 1e-9) * 10)
end

-- How many of the `count` segments are lit for this speed (the first lights up as soon as the vehicle moves).
function RoadHud.litCount(speedKmh, scaleKmh, count)
    if speedKmh == nil or speedKmh < 0.5 then
        return 0
    end
    local share = math.min(1, speedKmh / scaleKmh)
    return math.max(1, math.min(count, math.floor(share * count + 0.5)))
end

-- Which segment the set speed falls on, so it can be marked.
function RoadHud.setIndex(setKmh, scaleKmh, count)
    if setKmh == nil or setKmh <= 0 then
        return nil
    end
    return math.max(1, math.min(count, math.ceil(math.min(1, setKmh / scaleKmh) * count - 1e-9)))
end

-- Is a blinking thing lit right now
function RoadHud.blinkOn(timeMs, periodMs)
    return math.floor((timeMs or 0) / (periodMs or RoadHud.BLINK_MS)) % 2 == 0
end

-- The colour family for what the assist is doing: "ok", "correct", "stop", or "idle" (cruise on, assist not driving).
function RoadHud.kindFor(assist)
    if assist == nil or not assist.engaged then
        return "idle"
    end
    if assist.sup ~= nil and assist.sup.stopping then
        return "stop"
    end
    if assist.sup ~= nil and assist.sup.level == 1 then
        return "correct"
    end
    return "ok"
end

-- The arc's segments as rectangles relative to the gauge's centre: x, y (centre), w, h, and the rotation in
-- degrees (counter-clockwise) that turns an upright rectangle so its long side points along the radius.
function RoadHud.arcLayout(count, radius, ring, startDeg, spanDeg, gapShare)
    local out = {}
    local slot = spanDeg / count
    local mid = radius - ring / 2
    for i = 1, count do
        local angle = startDeg - (i - 0.5) * slot
        local rad = math.rad(angle)
        out[i] = {
            x = mid * math.cos(rad),
            y = mid * math.sin(rad),
            w = mid * math.rad(slot) * (1 - gapShare),
            h = ring,
            rot = angle - 90,
        }
    end
    return out
end

-- An arrow as three bars (a shaft and two angled head bars): x, y, w, h (unrotated: long side horizontal),
-- rot in degrees. `side` is "left" or "right"; the arrow points that way.
function RoadHud.arrowBars(side, size, thickness)
    local dir = side == "left" and -1 or 1
    local tipX = dir * size / 2
    local headLength = size * 0.5
    local bars = { { x = 0, y = 0, w = size, h = thickness, rot = 0 } }
    for _, sign in ipairs({ 1, -1 }) do            -- +1: the head bar above the shaft, -1: below
        local half = headLength / 2 * math.sqrt(0.5)
        bars[#bars + 1] = {
            x = tipX - dir * half,                  -- from the tip, back along 45 degrees
            y = sign * half,
            w = headLength,
            h = thickness,
            rot = (dir == -1) and (45 * sign) or (-45 * sign),
        }
    end
    return bars
end

-- ===== drawing (engine) =====

local function getOverlay()
    if RoadHud.overlay == nil and not RoadHud.overlayFailed then
        local ok, overlay = pcall(function()
            return createImageOverlay(RoadHud.modDirectory .. "hud/pixel.dds")   -- the engine's integer id, not an Overlay object
        end)
        if ok and overlay ~= nil then
            RoadHud.overlay = overlay
        else
            RoadHud.overlayFailed = true       -- say so once, then stay quiet
            print(string.format("[RoadFollow] HUD unavailable: could not create the overlay (%s, directory %s)",
                tostring(overlay), tostring(RoadHud.modDirectory)))
        end
    end
    return RoadHud.overlay
end

-- One rotated rectangle, centred at (cx, cy) on screen (0 to 1), sized in screen units
local function bar(overlay, cx, cy, w, h, rotDeg, color)
    local x, y = cx - w / 2, cy - h / 2
    setOverlayColor(overlay, color[1], color[2], color[3], color[4] or 1)
    setOverlayRotation(overlay, math.rad(rotDeg) * RoadHud.ROTATION_SIGN, w / 2, h / 2)
    renderOverlay(overlay, x, y, w, h)
end

-- m: speedKmh, setKmh, kind ("ok" "correct" "stop" "idle"), signal ("left" "right" "hazard" or nil), timeMs, label
function RoadHud.draw(m)
    local overlay = getOverlay()
    if not RoadHud.enabled or overlay == nil or renderOverlay == nil then
        return
    end
    local aspect = g_screenAspectRatio or (16 / 9)
    local s = RoadHud.scale
    local cx, cy = RoadHud.X, RoadHud.Y
    local color = RoadHud.COLORS[m.kind] or RoadHud.COLORS.ok

    local scaleKmh = RoadHud.scaleFor(m.setKmh or m.scaleKmh)
    local lit = RoadHud.litCount(m.speedKmh, scaleKmh, RoadHud.SEGMENTS)
    local mark = RoadHud.setIndex(m.setKmh, scaleKmh, RoadHud.SEGMENTS)
    local arc = RoadHud.arcLayout(RoadHud.SEGMENTS, RoadHud.RADIUS * s, RoadHud.RING * s,
        RoadHud.START_DEG, RoadHud.SPAN_DEG, RoadHud.GAP_SHARE)
    for i, seg in ipairs(arc) do
        local c = color
        if i > lit then
            c = (i == mark) and RoadHud.SET_MARK or RoadHud.UNLIT
        end
        bar(overlay, cx + seg.x / aspect, cy + seg.y, seg.w / aspect, seg.h, seg.rot, c)
    end

    -- turn arrows: the signalled side blinks green, the other stays dim
    local on = RoadHud.blinkOn(m.timeMs)
    for _, side in ipairs({ "left", "right" }) do
        local c = { 0.5, 0.55, 0.6, 0.35 }
        if m.signal == side then
            c = on and { 0.35, 0.95, 0.35, 1 } or { 0.35, 0.95, 0.35, 0.25 }
        elseif m.signal == "hazard" then
            c = on and { 1.0, 0.7, 0.1, 1 } or { 1.0, 0.7, 0.1, 0.25 }
        end
        local dir = side == "left" and -1 or 1
        local ox = dir * (RoadHud.RADIUS + RoadHud.ARROW_OFFSET) * s
        for _, b in ipairs(RoadHud.arrowBars(side, RoadHud.ARROW_SIZE * s, RoadHud.ARROW_THICKNESS * s)) do
            bar(overlay, cx + (ox + b.x) / aspect, cy + b.y, b.w / aspect, b.h, b.rot, c)
        end
    end
    setOverlayRotation(overlay, 0, 0, 0)

    -- the speed
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(1, 1, 1, 1)
    renderText(cx, cy - 0.012 * s, 0.04 * s, string.format("%d", math.floor((m.speedKmh or 0) + 0.5)))
    setTextBold(false)
    setTextColor(0.85, 0.88, 0.92, 1)
    renderText(cx, cy - 0.034 * s, 0.0135 * s, "km/h")

    -- what the assist is doing
    if m.label ~= nil then
        setTextColor(color[1], color[2], color[3], 1)
        renderText(cx, cy - RoadHud.RADIUS * s * 0.72 - 0.026 * s, 0.014 * s, m.label)
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end
