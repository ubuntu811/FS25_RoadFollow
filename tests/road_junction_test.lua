dofile("tests/stubs.lua")
dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadMapper.lua")
dofile("scripts/RoadAtlas.lua")
dofile("scripts/RoadJunction.lua")
local RJ = RoadJunction
local deg = math.rad

-- pieces made by hand: a road along `angle` out of (0, 0), points every 3 m from 10 m to 60 m
local function arm(angle, from, to)
    local points = {}
    for d = from or 10, to or 60, 3 do points[#points + 1] = { d * math.cos(angle), d * math.sin(angle) } end
    return { id = 1, points = points }
end
local function legAngles(legs)
    local out = {}
    for _, l in ipairs(legs) do out[#out + 1] = math.floor(math.deg(l.angle) + 0.5) end
    table.sort(out)
    return out
end

-- 1. the legs of a crossing: four, at 0, 90, 180 and -90 degrees (x east, z south)
local plus = { arm(0), arm(deg(90)), arm(deg(180)), arm(deg(-90)) }
local legs = RJ.legsAt(plus, 0, 0)
check("a crossing: four legs", #legs == 4)
check("... at 0, 90, 180 and -90 degrees", table.concat(legAngles(legs), ",") == "-90,0,90,180")
check("one road running through is two legs (a leg each side)", #RJ.legsAt({ arm(0), arm(deg(180)) }, 0, 0) == 2)
check("points nearer than 8 m or further than 30 m are not read (the junction pulls its own roads out of shape; far away is another place)",
    #RJ.legsAt({ arm(0, 2, 6), arm(deg(90), 40, 80) }, 0, 0) == 0)
check("a single stray point is no leg (needs 2)", #RJ.legsAt({ { id = 1, points = { { 15, 0 } } } }, 0, 0) == 0)
check("two roads leaving in nearly one direction (10 degrees apart) are one leg", #RJ.legsAt({ arm(0), arm(deg(10)) }, 0, 0) == 1)
-- the circle's ends meet: a leg at 175 and one at -175 degrees are one leg
check("a leg just either side of 180 degrees is one leg, not two", #RJ.legsAt({ arm(deg(175)), arm(deg(-175)) }, 0, 0) == 1)

-- 2. the picture for a vehicle coming from the south (z large) heading north: straight on is -z, left is west (-x), right is east (+x)
local carX, carZ = 0, 100
local function describe(pieces) return RJ.describe(RJ.legsAt(pieces, 0, 0), 0, 0, carX, carZ) end
local info = describe(plus)
check("crossing: type '+'", info ~= nil and info.type == "+" and #info.legs == 4)
check("... the first leg is the road you come along (rel = pi)", info.legs[1].approach == true and math.abs(info.legs[1].rel - math.pi) < 1e-6)
local rels = {}
for _, l in ipairs(info.others) do rels[#rels + 1] = math.floor(math.deg(l.rel) + 0.5) end
check("... the others at -90 (left, west), 0 (straight on, north) and 90 (right, east)", table.concat(rels, ",") == "-90,0,90")
check("... left to right in the list", info.others[1].rel < info.others[2].rel and info.others[2].rel < info.others[3].rel)

local tee = describe({ arm(deg(90)), arm(0), arm(deg(180)) })            -- no way straight on (north): east and west only
check("a T: two ways on, one each side, nothing straight on", tee ~= nil and tee.type == "T")
local sideRight = describe({ arm(deg(90)), arm(0), arm(deg(-90)) })       -- east (right) and north (straight on)
check("a side road joining from the right: 't', side right", sideRight ~= nil and sideRight.type == "t" and sideRight.side == "right")
local sideLeft = describe({ arm(deg(90)), arm(deg(180)), arm(deg(-90)) })
check("... from the left: 't', side left", sideLeft ~= nil and sideLeft.type == "t" and sideLeft.side == "left")
local fork = describe({ arm(deg(90)), arm(deg(-90 - 30)), arm(deg(-90 + 30)) })      -- two ways, 30 degrees each side of straight on
check("a fork: two ways leaning forward 30 degrees each side: 'Y'", fork ~= nil and fork.type == "Y")
local wideY = describe({ arm(deg(90)), arm(deg(-90 - 60)), arm(deg(-90 + 60)) })
check("a wide fork (60 degrees each side, still leaning forward): 'Y'", wideY ~= nil and wideY.type == "Y")
check("ways at right angles with nothing between: a T, not a Y", tee.type == "T")
check("five ways: 'star'", describe({ arm(deg(90)), arm(0), arm(deg(180)), arm(deg(-90)), arm(deg(-45)), arm(deg(-135)) }).type == "star")
check("one way on only (a bend): not a junction", describe({ arm(deg(90)), arm(0) }) == nil)
check("the vehicle is not on any of the roads (they all leave sideways from it): no picture", RJ.describe(RJ.legsAt({ arm(0), arm(deg(180)) }, 0, 0), 0, 0, 0, 100) == nil)

-- 3. which leg the signal leads into
local function relOf(leg) return leg and math.floor(math.deg(leg.rel) + 0.5) or nil end
check("crossing, no signal: straight on", relOf(RJ.chosenLeg(info, nil)) == 0)
check("crossing, left: the left leg", relOf(RJ.chosenLeg(info, "left")) == -90)
check("crossing, right: the right leg", relOf(RJ.chosenLeg(info, "right")) == 90)
check("T, no signal: no default, nothing chosen", RJ.chosenLeg(tee, nil) == nil)
check("T, left / right: the leg on that side", relOf(RJ.chosenLeg(tee, "left")) == -90 and relOf(RJ.chosenLeg(tee, "right")) == 90)
check("fork, no signal: no default", RJ.chosenLeg(fork, nil) == nil)
check("fork, left: the left fork, right: the right fork", relOf(RJ.chosenLeg(fork, "left")) == -30 and relOf(RJ.chosenLeg(fork, "right")) == 30)
check("side road from the right, no signal: straight on", relOf(RJ.chosenLeg(sideRight, nil)) == 0)
check("... signalling left where there is no way left: nothing chosen", RJ.chosenLeg(sideRight, "left") == nil)
check("... signalling right: the side road", relOf(RJ.chosenLeg(sideRight, "right")) == 90)
check("hazard / anything else counts as no signal", relOf(RJ.chosenLeg(info, "hazard")) == 0)
check("no junction: nothing", RJ.chosenLeg(nil, "left") == nil)

-- 4. the next junction ahead, from an atlas-like table
local atlas = { pieces = plus, junctions = { { 0, 0 }, { 0, -300 }, { 0, 150 } }, revision = 1 }
-- the vehicle at (0, 100) heading north (0, -1): the junction at (0, 0) is 100 m ahead; (0, -300) is 400 m ahead; (0, 150) is behind
local ahead = RJ.ahead(atlas, 0, 100, 0, -1, 200)
check("the junction 100 m ahead is found, with its distance", ahead ~= nil and math.abs(ahead.distance - 100) < 1e-6 and ahead.type == "+")
check("further than maxDist: not yet", RJ.ahead(atlas, 0, 100, 0, -1, 80) == nil)
check("a junction behind the vehicle is not ahead", RJ.ahead({ pieces = plus, junctions = { { 0, 150 } }, revision = 1 }, 0, 100, 0, -1, 400) == nil)
check("a junction to the side (90 degrees off the heading) is not ahead", RJ.ahead({ pieces = plus, junctions = { { 80, 100 } }, revision = 1 }, 0, 100, 0, -1, 400) == nil)
check("being at the junction (under 6 m): passed", RJ.ahead(atlas, 0, 3, 0, -1, 200) == nil)
check("the same junction ahead when heading the other way round: the other side is its approach", RJ.ahead({ pieces = plus, junctions = { { 0, 0 } }, revision = 1 }, 0, -100, 0, 1, 200) ~= nil)
check("legs are kept for the atlas's revision, worked out again when it changes", atlas.junctions[1].legsRevision == 1)
atlas.pieces = { arm(deg(90)), arm(0), arm(deg(-90)) }
atlas.revision = 2
check("... a new revision: the picture follows (now a side road)", RJ.ahead(atlas, 0, 100, 0, -1, 200).type == "t")

-- 5. the whole chain: a vehicle drives towards junctions in a simulated map and the picture is right well before it gets there
local PIXEL = 2.0
local function world(inside)
    return { sample = function(x, z)
        local cx = (math.floor(x / PIXEL) + 0.5) * PIXEL
        local cz = (math.floor(z / PIXEL) + 0.5) * PIXEL
        return inside(cx, cz) and 2 or 0
    end }
end
local function approach(name, inside, wantType, wantSide)
    local w = world(inside)
    local at = RoadAtlas.new(w.sample)
    RoadAtlas.update(at, 0, 30, 0)
    for _ = 1, 400 do if RoadAtlas.step(at, 120) then break end end
    local d, firstRight, wrongAfter = 0, nil, 0
    while d < 270 do
        d = d + 20 / 60
        RoadAtlas.update(at, d, 30, 20)
        RoadAtlas.step(at, 120)
        local info = RJ.ahead(at, d, 30, 1, 0, 150)
        if info ~= nil then
            local right = info.type == wantType and (wantSide == nil or info.side == wantSide)
            if right and firstRight == nil then firstRight = 300 - d end
            if firstRight ~= nil and not right then wrongAfter = wrongAfter + 1 end
        end
    end
    check(string.format("%s: recognised as '%s%s' %.0f m before it", name, wantType, wantSide and (" " .. wantSide) or "", firstRight or -1), firstRight ~= nil and firstRight >= 60)
    check(name .. ": and it stays right from then on (no flicker)", wrongAfter == 0)
end
approach("a crossing", function(x, z) return math.abs(z - 30) <= 3 or (math.abs(x - 300) <= 3 and z >= -200 and z <= 260) end, "+")
approach("a T (the road ends at a cross road)", function(x, z) return (math.abs(z - 30) <= 3 and x <= 303) or (math.abs(x - 300) <= 3 and z >= -200 and z <= 260) end, "T")
approach("a side road to the right (south)", function(x, z) return (math.abs(z - 30) <= 3 and x <= 700) or (math.abs(x - 300) <= 3 and z >= 30 and z <= 260) end, "t", "right")
approach("a side road to the left (north)", function(x, z) return (math.abs(z - 30) <= 3 and x <= 700) or (math.abs(x - 300) <= 3 and z >= -200 and z <= 30) end, "t", "left")

finish("road_junction_test")
