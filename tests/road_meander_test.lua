dofile("tests/stubs.lua")
dofile("scripts/RoadMeander.lua")
local M = RoadMeander
local function near(a, b, t) return math.abs(a - b) <= t end

-- runs a signal y(t) for `seconds` at 60 fps and returns the final severity
local function run(state, seconds, yOf, xOf, zOf)
    local severity = 0
    local t = 0
    while t < seconds * 1000 do
        severity = M.update(state, 16, yOf(t / 1000), xOf and xOf(t / 1000) or nil, zOf and zOf(t / 1000) or nil)
        t = t + 16
    end
    return severity
end

local s = M.new()
check("a vehicle exactly on its line: not weaving", run(s, 8, function() return 0 end) == 0)
s = M.new()
check("a steady offset of 0.8 m on one side: not weaving (it never changes side)", run(s, 8, function() return 0.8 end) == 0)
s = M.new()
check("small noise inside the deadband (0.15 m): not weaving", run(s, 8, function(t) return 0.15 * math.sin(t * 8) end) == 0)
s = M.new()
local gentle = run(s, 8, function(t) return 0.9 * math.sin(t * math.pi) end)   -- period 2 s, amplitude 0.9
check("a 0.9 m swing every 2 s: weaving", gentle > 0.5)
s = M.new()
local hard = run(s, 8, function(t) return 1.6 * math.sin(t * 2 * math.pi) end)  -- period 1 s, amplitude 1.6
check("a 1.6 m swing every second: weaving as hard as it gets", hard > 0.9 and hard <= 1)
check("the side changes were counted (about 6 per 6 s window at one change per half second)", s.crossings >= 7)
s = M.new()
local slow = run(s, 8, function(t) return 1.0 * math.sin(t * 0.5) end)           -- period 12.6 s: one drift, not a weave
check("one slow drift across the line in 8 s is not weaving", slow == 0)
s = M.new()
local twice = run(s, 1.2, function(t) return 1.0 * math.sin(t * 2 * math.pi) end)
check("only two side changes in the window: not weaving yet", twice == 0)

-- it stops when the weaving stops
s = M.new()
run(s, 6, function(t) return 1.2 * math.sin(t * 2 * math.pi) end)
check("(weaving)", s.severity > 0.5)
local after = run(s, 8, function() return 0.05 end)
check("8 s of calm later: the weaving is forgotten", after == 0)

-- general direction: weaving ±1 m about a straight track heading east at 5 m/s
s = M.new()
run(s, 6, function(t) return 1.2 * math.sin(t * 2 * math.pi) end, function(t) return t * 5 end, function(t) return 1.2 * math.sin(t * 2 * math.pi) end)
local gx, gz = M.direction(s)
check("the general direction of a weaving drive along east is east (within 10 degrees)", gx ~= nil and gx > 0.98 and math.abs(gz) < 0.17)
s = M.new()
run(s, 1, function() return 0 end, function(t) return t * 0.5 end, function() return 0 end)
check("standing nearly still: no general direction", M.direction(s) == nil)
s = M.new()
check("nothing recorded: nil", M.direction(s) == nil)
-- a drive along north-east
s = M.new()
run(s, 6, function() return 0 end, function(t) return t * 4 end, function(t) return t * 4 end)
gx, gz = M.direction(s)
check("north-east: both components about 0.707", near(gx, 0.7071, 0.02) and near(gz, 0.7071, 0.02))

-- damping
local lookGain, filterGain, blend = M.damping(0)
check("no weaving: nothing changes", lookGain == 1 and filterGain == 1 and blend == 0)
lookGain, filterGain, blend = M.damping(1)
check("full weaving: lookahead 1.6x, filter 3x, half the aim from the recent track", near(lookGain, 1.6, 1e-9) and near(filterGain, 3.0, 1e-9) and near(blend, 0.5, 1e-9))
lookGain, filterGain, blend = M.damping(0.5)
check("in between: in between", lookGain > 1 and lookGain < 1.6 and blend > 0 and blend < 0.5)

-- reset
s = M.new()
run(s, 6, function(t) return 1.2 * math.sin(t * 2 * math.pi) end)
M.reset(s)
check("reset forgets everything", s.severity == 0 and #s.samples == 0 and M.direction(s) == nil)
finish("road_meander_test")
