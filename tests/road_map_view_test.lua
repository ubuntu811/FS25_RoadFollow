dofile("tests/stubs.lua")

-- The game-facing side of the road map (roadFollowMap): start / update / draw / switch off, with the engine functions faked. The atlas itself is
-- tested in road_atlas_test.lua; this is for the glue (a mistake in it only shows in the game: the mapper once failed there on a missing coroutine).
g_currentModName = "FS25_RoadFollow"
addConsoleCommand = function() end
g_terrainNode = 1
getTerrainHeightAtWorldPos = function() return 100 end
local lines, texts, clock = 0, 0, 0
local colorsSeen = {}
drawDebugLine = function(...)
    lines = lines + 1
    local r, g, b = select(4, ...), select(5, ...), select(6, ...)
    colorsSeen[string.format("%.2f,%.2f,%.2f", r, g, b)] = (colorsSeen[string.format("%.2f,%.2f,%.2f", r, g, b)] or 0) + 1
end
renderText = function() texts = texts + 1 end
setTextAlignment, setTextColor = function() end, function() end
RenderText = { ALIGN_LEFT = 0 }
getTimeSec = function() clock = clock + 0.0001; return clock end
g_time = 0

local vehicle = { pos = { 0, 30 } }
vehicle.getAISteeringNode = function() return "steer" end
getWorldTranslation = function() return vehicle.pos[1], 100, vehicle.pos[2] end
vehicle.getAIDirectionNode = function() return "dir" end
vehicle.getLastSpeed = function() return 72 end
localDirectionToWorld = function() return 1, 0, 0 end          -- heading east (+x)
local overlayCalls, overlayId = 0, 0
createImageOverlay = function() overlayId = overlayId + 1; return overlayId end
renderOverlay = function() overlayCalls = overlayCalls + 1 end
setOverlayColor, setOverlayRotation, setTextBold = function() end, function() end, function() end
RenderText.ALIGN_CENTER = 1
g_screenAspectRatio = 16 / 9
g_currentModDirectory = "mod/"

local function sample(x, z)
    local cx = (math.floor(x / 2) + 0.5) * 2
    local cz = (math.floor(z / 2) + 0.5) * 2
    if math.abs(cz - 30) <= 3 or (math.abs(cx - 250) <= 3 and cz >= 30) then return 2 end
    return 0
end
g_currentMission = { controlledVehicle = vehicle, wailaTrailTracer = { sampleDrivable = sample, hasDrivableData = function() return true end } }

dofile("scripts/RoadCenterline.lua")
dofile("scripts/RoadSupervisor.lua")
dofile("scripts/RoadMeander.lua")
dofile("scripts/RoadMapper.lua")
dofile("scripts/RoadAtlas.lua")
dofile("scripts/RoadJunction.lua")
dofile("scripts/RoadHud.lua")

local printed = {}
local realPrint = print
print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
dofile("scripts/RoadFollow.lua")
print = realPrint

local text = RoadFollow.consoleMap(nil, nil)
check("roadFollowMap switches the map on and says so", RoadFollow.roadMap ~= nil and text:find("mapping the roads", 1, true) ~= nil)

print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
local seenJunction, mostPieces = false, 0
local pictureType, pictureAt, pictureDistance = nil, nil, nil
local ok, err = pcall(function()
    for frame = 1, 1200 do
        g_time = g_time + 17
        vehicle.pos[1] = vehicle.pos[1] + 20 / 60
        RoadFollow.updateRoadMap(1000 / 60)
        RoadFollow.drawRoadMap()
        local a = RoadFollow.roadMap.atlas
        if #a.junctions >= 1 then seenJunction = true end
        local info = RoadFollow.junctionInfo(vehicle)
        if info ~= nil and pictureType == nil then pictureType, pictureAt, pictureDistance = info.type, vehicle.pos[1], info.distance end
        mostPieces = math.max(mostPieces, #a.pieces)
    end
end)
print = realPrint
check("20 s of driving: update and draw run without an error" .. (ok and "" or (" (" .. tostring(err) .. ")")), ok)
local atlas = RoadFollow.roadMap.atlas
check("the atlas did not fail", atlas.error == nil)
check("it found the road and, on the way, the junction (the cross road at x = 250)", seenJunction and mostPieces >= 2)
check("debug lines and the legend were drawn", lines > 100 and texts >= 4)
local logged = false
for _, line in ipairs(printed) do if line:find("road map:", 1, true) and line:find("map reads/s", 1, true) then logged = true end end
check("the cost is logged (reads per second and ms of work)", logged)
check("... and kept for the legend", (RoadFollow.roadMap.readsPerSecond or 0) > 0)
check(string.format("the junction picture: the side road at x = 250 is a 't' on the right, first reported %.0f m before it", pictureAt and (250 - pictureAt) or -1),
    pictureType == "t" and pictureAt ~= nil and 250 - pictureAt >= 60)
do
    local info = { x = 250, z = 30, distance = 120, type = "t", side = "right", legs = {}, others = {} }
    local approachLeg = { rel = math.pi, approach = true }
    local straightLeg = { rel = 0 }
    local rightLeg = { rel = math.pi / 2 }
    info.legs, info.others = { approachLeg, straightLeg, rightLeg }, { straightLeg, rightLeg }
    overlayCalls = 0
    local drawn = pcall(RoadHud.drawJunction, { junction = info, signal = "right", timeMs = 0 })
    check("the junction picture is drawn (a panel, three legs and a mark for you) with the engine's overlay calls", drawn and overlayCalls == 1 + 3 + 1)
    check("nothing to draw without a junction", pcall(RoadHud.drawJunction, { junction = nil }) and overlayCalls == 5)
end
check("RoadFollow.junctionInfo gives the picture to the vehicle the player drives only", RoadFollow.junctionInfo({}) == nil)

-- drawn once per frame even when called twice (from the vehicle's onDraw and the mod's draw)
lines = 0
g_time = g_time + 17
RoadFollow.drawRoadMap()
local once = lines
RoadFollow.drawRoadMap()
check("called twice in one frame, drawn once", lines == once and once > 0)

-- a menu open: no work, no drawing
local before = atlas.samples
g_gui = { getIsGuiVisible = function() return true end }
vehicle.pos[1] = vehicle.pos[1] + 50
RoadFollow.updateRoadMap(16)
g_time = g_time + 17
lines = 0
RoadFollow.drawRoadMap()
check("a menu open: nothing read, nothing drawn", atlas.samples == before and lines == 0)
g_gui = nil

text = RoadFollow.consoleMap(nil, nil)
check("the same command again switches the lines off (the atlas goes on for the junction picture)", RoadFollow.roadMap ~= nil and RoadFollow.roadMap.show == false and text:find("off", 1, true) ~= nil)
lines = 0
g_time = g_time + 17
RoadFollow.drawRoadMap()
check("... nothing is drawn then", lines == 0)
text = RoadFollow.consoleJunctions()
check("roadFollowJunctions switches the picture off, and with the lines off too the atlas stops", RoadFollow.JUNCTION_HUD == false and RoadFollow.roadMap == nil and text:find("OFF", 1, true) ~= nil)
check("update and draw with it all off do nothing and do not fail", pcall(RoadFollow.updateRoadMap, 16) and pcall(RoadFollow.drawRoadMap) and RoadFollow.roadMap == nil)
RoadFollow.consoleJunctions()
check("... and on again", RoadFollow.JUNCTION_HUD == true)
RoadFollow.updateRoadMap(16)
check("while the player is in a vehicle the atlas starts by itself (for the picture) without the lines", RoadFollow.roadMap ~= nil and RoadFollow.roadMap.show == false)
text = RoadFollow.consoleMap(nil, "60")
check("a radius can be given", RoadFollow.roadMap ~= nil and RoadFollow.roadMap.show == true and RoadFollow.roadMap.atlas.radius == 60)

-- the map's own sampler: forest-floor paint out in the open is a track (a sandy or cobbled path painted with the forest floor's layer), forest floor under forest is not
do
    local FOREST = 2
    local classes, underForest, trees, buildings, foliage = {}, {}, {}, {}, {}
    local tracer = { LAYER_CLASS_FOREST = FOREST,
        sampleDrivable = function(x, z) return classes[math.floor(x) .. "," .. math.floor(z)] or 0 end,
        getLayerClassAt = function(x, z) return FOREST end,
        sampleForest = function(x, z) return underForest[math.floor(x)] == true end,
        sampleTree = function(x, z) return trees[math.floor(x)] == true end,
        sampleBuilding = function(x, z) return buildings[math.floor(x)] == true end,
        hasFoliageAt = function(x, z) return foliage[math.floor(x)] == true end,
    }
    local saved = g_currentMission.wailaTrailTracer
    g_currentMission.wailaTrailTracer = tracer
    classes["5,5"] = 2
    underForest[100], trees[200], buildings[300], foliage[400] = true, true, true, true
    local sample = RoadFollow.makeAtlasSampler()
    check("a road pixel stays a road", sample(5, 5) == 2)
    check("forest-floor paint out in the open is a track (class 1)", sample(50, 50) == 1)
    check("forest-floor paint under forest is not", sample(100, 50) == 0)
    check("... nor where a tree stands, nor under a building", sample(200, 50) == 0 and sample(300, 50) == 0)
    check("... nor where foliage grows on it (a forest floor is stone / dirt / FOLIAGE; a track has none)", sample(400, 50) == 0)
    local calls = 0
    local counting = tracer.getLayerClassAt
    tracer.getLayerClassAt = function(x, z) calls = calls + 1; return counting(x, z) end
    sample(60, 60); sample(60, 60); sample(60.5, 60.5)
    check("the layer is asked once per 2 m cell (cached)", calls == 1)
    RoadFollow.FOREST_FLOOR_TRACKS = false
    check("switched off (RoadFollow.FOREST_FLOOR_TRACKS = false): the plain sampler", RoadFollow.makeAtlasSampler()(70, 70) == 0)
    RoadFollow.FOREST_FLOOR_TRACKS = true
    tracer.hasFoliageAt = nil
    check("a WAILA without the foliage sampler: still works (the forest picture and the trees decide)", RoadFollow.makeAtlasSampler()(90, 90) == 1)
    tracer.sampleForest = nil
    check("a WAILA without the forest sampler: the plain sampler, no error", RoadFollow.makeAtlasSampler()(80, 80) == 0)
    g_currentMission.wailaTrailTracer = saved
end

-- the game's own lane splines (WAILA's path store, kind "spline"): drawn directly where the road has them, our lines only where it has none
do
    local imports, finds = 0, 0
    local function lane(z, step)
        local points = {}
        if step > 0 then
            for px = -500, 1500, 4 do points[#points + 1] = { px, z } end
        else
            for px = 1500, -500, -4 do points[#points + 1] = { px, z } end
        end
        return { kind = "spline", source = "map", oneWay = false, transient = true, points = points }
    end
    local east, west = lane(28.2, 1), lane(31.8, -1)          -- two lanes of the road at z = 30, one each way (x east, z south)
    g_currentMission.wailaPaths = {
        importMapSplines = function() imports = imports + 1 end,
        findNear = function() finds = finds + 1; return { { path = east, dx = 1, dz = 0, distance = 1.8 }, { path = west, dx = -1, dz = 0, distance = 1.8 } } end,
    }
    vehicle.pos = { 0, 30 }
    local map = RoadFollow.roadMap
    map.atlas = RoadAtlas.new(sample, { radius = 90 })
    for frame = 1, 600 do
        g_time = g_time + 17
        vehicle.pos[1] = vehicle.pos[1] + 20 / 60
        RoadFollow.updateRoadMap(1000 / 60)
        RoadFollow.drawRoadMap()
    end
    check("the lane splines of the store are found and the map splines imported", imports >= 1 and finds >= 1 and map.splines ~= nil and #map.splines == 2)
    check("... copied as runs of points inside the drawing range, ours to keep heights on (the store's own points are untouched)", #map.splines[1].runs >= 1 and east.points[1][3] == nil and #map.splines[1].runs[1] > 10)
    local mine, oncoming = colorsSeen["1.00,1.00,1.00"] or 0, colorsSeen["0.55,0.75,1.00"] or 0
    check(string.format("driving east: the lane that runs east is white (%d lines), the one running west light blue (%d lines)", mine, oncoming), mine > 0 and oncoming > 0)
    local coveredCount, crossDrawn = 0, false
    for _, piece in ipairs(map.atlas.pieces) do
        local line = RoadAtlas.lineOf(piece)
        local nearCross = math.abs(line[1][1] - 250) < 6 and math.abs(line[#line][1] - 250) < 6
        if piece.onSpline == true then coveredCount = coveredCount + 1 end
        if nearCross and piece.onSpline == false then crossDrawn = true end
    end
    check("the pieces of the road that lie on the splines are left out of our drawing", coveredCount >= 1)
    check("... the cross road, which has no spline, is still drawn with our own line", crossDrawn)
    local before = finds
    for frame = 1, 5 do g_time = g_time + 17; RoadFollow.updateRoadMap(16); RoadFollow.drawRoadMap() end
    check("the store is not asked every frame (at most every 400 ms)", finds - before <= 1)
    g_currentMission.wailaPaths = nil
    map.splineAt, map.splineKey = nil, nil
    g_time = g_time + 1000
    check("no store: no splines, no error", pcall(RoadFollow.drawRoadMap) and #map.splines == 0)
end

-- terrain the player has edited: the map picture is a snapshot, so edited places are read from the terrain paint live
do
    local ROAD, FOREST = 1, 2
    local snapshotRoad = function(x, z) return math.abs(z - 30) <= 3 and x <= 0 end            -- the scanned map: a road to x = 0 only
    local liveClassAt = {}                                                                        -- what the paint says now, by 8 m cell
    local function cellOf(x, z) return math.floor(x / 8) .. "," .. math.floor(z / 8) end
    local tracer = { LAYER_CLASS_ROAD = ROAD, LAYER_CLASS_FOREST = FOREST,
        sampleDrivable = function(x, z) return snapshotRoad(x, z) and 2 or 0 end,
        getLayerClassAt = function(x, z) return liveClassAt[cellOf(x, z)] end,
        hasFoliageAt = function() return false end }
    local saved = g_currentMission.wailaTrailTracer
    g_currentMission.wailaTrailTracer = tracer
    RoadFollow.mapStale = false
    local sample = RoadFollow.makeAtlasSampler()
    check("before any edit: the snapshot decides (no road at x = 50, a road at x = -50)", sample(50, 30) == 0 and sample(-50, 30) == 2)
    -- the player paints road paint at x = 50 and paints over the road at x = -50 in the construction screen
    liveClassAt[cellOf(50, 30)], liveClassAt[cellOf(50, 24)], liveClassAt[cellOf(50, 36)] = ROAD, ROAD, ROAD
    local before = RoadFollow.editedCellCount()
    RoadFollow.noteTerrainEdit(50, 30, 4)
    RoadFollow.noteTerrainEdit(-50, 30, 4)
    check("an edit marks the cells under the brush (8 m cells), and the map is stale", RoadFollow.editedCellCount() > before and RoadFollow.mapStale == true)
    check("a road painted in an edited place is a road at once (read live, the snapshot has none)", sample(50, 30) == 2)
    check("a road painted over: gone at once (the snapshot still says road)", sample(-50, 30) == 0)
    check("somewhere not edited, the snapshot still decides", sample(-100, 30) == 2 and sample(300, 30) == 0)
    liveClassAt[cellOf(60, 30)] = FOREST
    RoadFollow.noteTerrainEdit(60, 30, 2)
    check("edited: forest-floor paint with no foliage is a track, with foliage it is not",
        sample(60, 30) == 1 and (function() tracer.hasFoliageAt = function() return true end; local v = sample(60.5, 30.5); tracer.hasFoliageAt = function() return false end; return v == 0 end)())
    local plain = RoadFollow.makeAtlasSampler()
    check("the same through the driving sampler's own path (an edited cell is live for the road assist too)", RoadFollow.editedCellCount() > 0 and plain(50, 30) == 2)

    -- the map starts again after an edit
    local map = RoadFollow.roadMap
    local oldAtlas = map.atlas
    local px, pz = oldAtlas.cx, oldAtlas.cz                       -- where the map is: an edit here matters
    RoadFollow.pendingEdit = nil
    RoadFollow.noteTerrainEdit(px, pz, 4)
    RoadFollow.updateRoadMap(16)
    check("an edit just made: the map waits for it to be over (the quiet period), it does not start again every time", map.atlas == oldAtlas and RoadFollow.mapStale == true)
    g_time = g_time + RoadFollow.EDIT_QUIET_MS + 50
    RoadFollow.updateRoadMap(16)
    check("when no edit has come for a while, the road map is made again (a new atlas)", map.atlas ~= oldAtlas and RoadFollow.mapStale == false)
    local second = map.atlas
    RoadFollow.noteTerrainEdit(px, pz, 4)
    g_time = g_time + RoadFollow.EDIT_QUIET_MS + 50
    RoadFollow.updateRoadMap(16)
    check("a second edit soon after the restart: not again yet (at most one restart every EDIT_RESTART_MIN_MS)", map.atlas == second and RoadFollow.mapStale == true)
    g_time = g_time + RoadFollow.EDIT_RESTART_MIN_MS
    RoadFollow.updateRoadMap(16)
    check("... and then it is", map.atlas ~= second and RoadFollow.mapStale == false)
    -- a terraforming machine: an edit every 100 ms for 10 s. Marking goes on, the map does not restart (it never gets quiet)
    local third, restarts = map.atlas, 0
    g_time = g_time + RoadFollow.EDIT_RESTART_MIN_MS
    for i = 1, 100 do
        g_time = g_time + 100
        RoadFollow.noteTerrainEdit(px + i, pz, 4)
        local before = map.atlas
        RoadFollow.updateRoadMap(100)
        if map.atlas ~= before then restarts = restarts + 1 end
    end
    check("a terraforming machine editing ten times a second for 10 s: no restart while it goes on", restarts == 0 and map.atlas == third)
    g_time = g_time + RoadFollow.EDIT_QUIET_MS + 50
    RoadFollow.updateRoadMap(16)
    check("... one restart when it stops", map.atlas ~= third and RoadFollow.mapStale == false)
    -- edits far from the map (further than the atlas keeps) restart nothing
    local fourth = map.atlas
    g_time = g_time + RoadFollow.EDIT_RESTART_MIN_MS + RoadFollow.EDIT_QUIET_MS + 50
    RoadFollow.noteTerrainEdit(px + 5000, pz + 5000, 4)
    local cells = RoadFollow.editedCellCount()
    g_time = g_time + RoadFollow.EDIT_QUIET_MS + 50
    RoadFollow.updateRoadMap(16)
    check("an edit 7 km away: the cells are marked (read live when the map gets there) but the map is not restarted", map.atlas == fourth and RoadFollow.mapStale == false and cells > 0)
    -- while a menu is open (the construction screen) nothing is done at all
    RoadFollow.noteTerrainEdit(px, pz, 4)
    g_time = g_time + RoadFollow.EDIT_RESTART_MIN_MS + RoadFollow.EDIT_QUIET_MS + 50
    g_gui = { getIsGuiVisible = function() return true end }
    local keptAtlas = map.atlas
    RoadFollow.updateRoadMap(16)
    check("while the construction screen (a menu) is open nothing is redone", map.atlas == keptAtlas and RoadFollow.mapStale == true)
    g_gui = nil
    RoadFollow.updateRoadMap(16)
    check("... when it has closed (and it is quiet), the map starts again", map.atlas ~= keptAtlas and RoadFollow.mapStale == false)

    -- the hook on the game's landscaping event
    Utils = { appendedFunction = function(old, new) return function(...) local r = old(...); new(...); return r end end }
    local created = 0
    LandscapingSculptEvent = { new = function(...) created = created + 1; return { made = true } end }
    RoadFollow.landscapingHooked = false
    RoadFollow.hookLandscaping()
    RoadFollow.hookLandscaping()
    local count = RoadFollow.editedCellCount()
    local event = LandscapingSculptEvent.new(false, 1, 400, 0, 300, nil, nil, nil, nil, nil, nil, 4)
    check("LandscapingSculptEvent.new still makes the event (the hook is only appended, and only once)", event ~= nil and event.made == true and created == 1)
    check("... and tells the road follower where (a real edit)", RoadFollow.editedCellCount() > count and RoadFollow.mapStale == true)
    count = RoadFollow.editedCellCount()
    LandscapingSculptEvent.new(true, 1, 900, 0, 900, nil, nil, nil, nil, nil, nil, 4)
    check("a validation only (a preview, nothing painted) marks nothing", RoadFollow.editedCellCount() == count)
    RoadFollow.mapStale = false
    g_currentMission.wailaTrailTracer = saved
end

-- the funnel: TerrainDeformation (every deformation), its queue's completion
do
    RoadFollow.landscapingHooked = false
    local applied, completed = 0, 0
    TerrainDeformation = {
        new = function() return setmetatable({}, { __index = TerrainDeformation }) end,
        addSoftCircleBrush = function(self, x, z, radius) end,
        addSoftSquareBrush = function(self, x, z, size) end,
        addArea = function(self, x, y, z, s1x, s1y, s1z, s2x, s2y, s2z) end,
        addPolygonalArea = function(self, vertexPositions) end,
        clearAreas = function(self) end,
        apply = function(self, previewOnly) applied = applied + 1 end,
    }
    TerrainDeformationQueue = { onJobComplete = function(self) completed = completed + 1 end }
    LandscapingSculptEvent = nil
    RoadFollow.hookLandscaping()
    local function fresh() RoadFollow.mapStale = false; return TerrainDeformation.new() end
    local count = RoadFollow.editedCellCount()
    local td = fresh()
    td:addSoftCircleBrush(2000, 2000, 6)
    check("adding a brush marks nothing yet (it may be a preview, or never applied)", RoadFollow.editedCellCount() == count and RoadFollow.mapStale == false)
    td:apply(true)
    check("a preview (previewOnly) marks nothing", RoadFollow.editedCellCount() == count and applied == 1)
    td:apply(false)
    check("applying for real marks the cells the brush covered (and the original apply still runs)", RoadFollow.editedCellCount() > count and RoadFollow.mapStale == true and applied == 2)
    count = RoadFollow.editedCellCount()
    td = fresh()
    td:addSoftSquareBrush(3000, 3000, 16)
    td:addArea(3100, 0, 3100, 20, 0, 0, 0, 0, 20)
    td:addPolygonalArea({ { 3200, 3200 }, { 3240, 3200 }, { 3240, 3230 } })
    td:addPolygonalArea({ 3300, 3300, 3310, 3300, 3310, 3310 })
    td:apply(false)
    local b = td.rfBounds
    check("a square brush, a plane area and polygons (as vertex pairs or flat numbers) all widen the same rectangle", b ~= nil and b[1] == 2992 and b[2] == 2992 and b[3] == 3310 and b[4] == 3310)
    check("... and every cell of it is marked", RoadFollow.editedCellCount() > count + 100)
    td = fresh()
    td:addSoftCircleBrush(5000, 5000, 4)
    td:clearAreas()
    check("clearAreas forgets the areas", td.rfBounds == nil)
    td:apply(false)
    check("... an apply with no areas marks nothing and does not fail", RoadFollow.mapStale == false)
    RoadFollow.pendingEdit, RoadFollow.mapStale = nil, false
    TerrainDeformationQueue.onJobComplete({})
    check("a completed job that was not an edit we know of (a preview, another place) changes nothing, and the original still runs", RoadFollow.mapStale == false and completed == 1)
    RoadFollow.noteTerrainEdit(5000, 5000, 4)
    RoadFollow.mapStale, RoadFollow.editAt = false, 0
    TerrainDeformationQueue.onJobComplete({})
    check("a job that completes while an edit is pending: the quiet period starts from now (the paint has landed)", RoadFollow.mapStale == true and RoadFollow.editAt == g_time and completed == 2)
    RoadFollow.mapStale, RoadFollow.pendingEdit = false, nil
    local broken = TerrainDeformation.new()
    check("odd arguments do not break the game's calls", pcall(broken.addSoftCircleBrush, broken, nil, nil, nil) and pcall(broken.addArea, broken, nil) and pcall(broken.addPolygonalArea, broken, "x") and pcall(broken.addPolygonalArea, broken, nil))
end

finish("road_map_view_test")
