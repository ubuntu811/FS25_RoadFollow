--[[
    RoadMeander.lua

    Detects a vehicle weaving from side to side along the line it follows, and says how to calm it.

    The follower steers at a point on an estimated line. When the estimate jitters, or the response is
    a little too eager, the vehicle crosses the line again and again. A person would notice that and
    stop chasing every correction: drive along the average direction of the last few seconds instead.
    This does the same: it remembers the sideways position (y) over a window, counts how often it
    changed side, and remembers where the vehicle has been, to give the general direction of travel.

    Pure logic. update() takes the sideways position and returns a severity from 0 (steady) to 1
    (weaving hard); direction() returns the average heading of the recent track.
]]

RoadMeander = {}

RoadMeander.WINDOW_MS = 6000          -- how much of the past is looked at
RoadMeander.DEADBAND = 0.25           -- m: a side change only counts when the vehicle was this far out on both sides
RoadMeander.MIN_CROSSINGS = 3         -- side changes in the window before it is called weaving
RoadMeander.FULL_CROSSINGS = 7        -- ... and the number at which it is as bad as it gets
RoadMeander.MIN_AMPLITUDE = 0.35      -- m: the swing has to be at least this wide
RoadMeander.FULL_AMPLITUDE = 1.0      -- m: ... and this wide counts fully
RoadMeander.POSITION_INTERVAL_MS = 400
RoadMeander.MIN_TRACK_LENGTH = 8.0    -- m: a general direction needs at least this much travelled

function RoadMeander.new()
    return { samples = {}, positions = {}, clock = 0, lastPositionAt = -1e9, severity = 0 }
end

function RoadMeander.reset(state)
    state.samples, state.positions, state.clock, state.lastPositionAt, state.severity = {}, {}, 0, -1e9, 0
end

local function trim(list, clock, window)
    while #list > 0 and clock - list[1].t > window do
        table.remove(list, 1)
    end
end

-- dt in ms, y the vehicle's sideways position against its line (+ left), x / z its world position.
-- Returns the severity.
function RoadMeander.update(state, dt, y, x, z)
    state.clock = state.clock + dt
    state.samples[#state.samples + 1] = { t = state.clock, y = y }
    trim(state.samples, state.clock, RoadMeander.WINDOW_MS)

    if x ~= nil and state.clock - state.lastPositionAt >= RoadMeander.POSITION_INTERVAL_MS then
        state.lastPositionAt = state.clock
        state.positions[#state.positions + 1] = { t = state.clock, x = x, z = z }
        trim(state.positions, state.clock, RoadMeander.WINDOW_MS)
    end

    -- side changes with hysteresis: only from "clearly left" to "clearly right" or back
    local side, crossings = 0, 0
    local low, high = math.huge, -math.huge
    for _, sample in ipairs(state.samples) do
        low, high = math.min(low, sample.y), math.max(high, sample.y)
        local now = 0
        if sample.y > RoadMeander.DEADBAND then
            now = 1
        elseif sample.y < -RoadMeander.DEADBAND then
            now = -1
        end
        if now ~= 0 then
            if side ~= 0 and now ~= side then
                crossings = crossings + 1
            end
            side = now
        end
    end
    local amplitude = high - low
    local crossingShare = (crossings - (RoadMeander.MIN_CROSSINGS - 1)) / (RoadMeander.FULL_CROSSINGS - (RoadMeander.MIN_CROSSINGS - 1))
    local amplitudeShare = (amplitude - RoadMeander.MIN_AMPLITUDE) / (RoadMeander.FULL_AMPLITUDE - RoadMeander.MIN_AMPLITUDE)
    local severity = 0
    if crossings >= RoadMeander.MIN_CROSSINGS and amplitude >= RoadMeander.MIN_AMPLITUDE then
        severity = math.max(0, math.min(1, crossingShare)) * math.max(0.25, math.min(1, amplitudeShare))
        severity = math.max(severity, 0.25)
    end
    state.severity = severity
    state.crossings = crossings
    state.amplitude = amplitude
    return severity
end

-- The vehicle's general direction over the recent past: from where it was at the start of the window to
-- where it is now (unit x, z), or nil when it has not gone far enough to say.
function RoadMeander.direction(state)
    local first, last = state.positions[1], state.positions[#state.positions]
    if first == nil or last == nil or first == last then
        return nil
    end
    local dx, dz = last.x - first.x, last.z - first.z
    local length = math.sqrt(dx * dx + dz * dz)
    if length < RoadMeander.MIN_TRACK_LENGTH then
        return nil
    end
    return dx / length, dz / length
end

-- How the weaving is answered: a longer lookahead, a slower target filter, and a share of the aim taken
-- from the straight-ahead direction of the recent track. All scale with the severity.
RoadMeander.LOOKAHEAD_GAIN = 0.6      -- lookahead grows by up to this share
RoadMeander.FILTER_GAIN = 2.0         -- the target filter's time constant grows by up to this share
RoadMeander.MAX_TRACK_BLEND = 0.5     -- at most this share of the aim comes from the recent track direction

function RoadMeander.damping(severity)
    return 1 + RoadMeander.LOOKAHEAD_GAIN * severity, 1 + RoadMeander.FILTER_GAIN * severity, RoadMeander.MAX_TRACK_BLEND * severity
end
