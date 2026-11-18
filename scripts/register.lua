--
--  Road Follow: registration. The AI job pieces, the job type, and the specialization that is
--  injected into every drivable vehicle type (the same approach FollowMe uses).
--
local modDir = g_currentModDirectory
local modName = g_currentModName

source(modDir .. "scripts/RoadCenterline.lua")
source(modDir .. "scripts/RoadSupervisor.lua")
source(modDir .. "scripts/RoadMeander.lua")
source(modDir .. "scripts/RoadHud.lua")
source(modDir .. "scripts/RoadLead.lua")
source(modDir .. "scripts/RoadMapper.lua")
source(modDir .. "scripts/RoadAtlas.lua")
source(modDir .. "scripts/RoadJunction.lua")
source(modDir .. "scripts/RoadFieldCourse.lua")
source(modDir .. "scripts/AIMessageErrorRoadEnded.lua")
source(modDir .. "scripts/AITaskRoadFollow.lua")
source(modDir .. "scripts/AIJobRoadFollow.lua")
source(modDir .. "scripts/AIDriveStrategyRoadFollowCollision.lua")

local function injectSpecialization()
    local specTypeName = modName .. ".roadFollow"
    local added = {}
    for typeName, typeObject in pairs(g_vehicleTypeManager:getTypes()) do
        if typeObject.specializationsByName[specTypeName] == nil
            and SpecializationUtil.hasSpecialization(Drivable, typeObject.specializations)
            and SpecializationUtil.hasSpecialization(Motorized, typeObject.specializations)
            and SpecializationUtil.hasSpecialization(Enterable, typeObject.specializations)
            and SpecializationUtil.hasSpecialization(AIJobVehicle, typeObject.specializations)
            and not SpecializationUtil.hasSpecialization(Locomotive, typeObject.specializations)
            and not SpecializationUtil.hasSpecialization(PushHandTool, typeObject.specializations)
        then
            g_vehicleTypeManager:addSpecialization(typeName, specTypeName)
            table.insert(added, typeName)
        end
    end
    if #added > 0 then
        print(string.format("[RoadFollow] specialization added to %d vehicle type(s)", #added))
    end
end

TypeManager.validateTypes = Utils.appendedFunction(TypeManager.validateTypes, function(self)
    if self.typeName == "vehicle" then
        injectSpecialization()
    end
end)

AIJobTypeManager.loadMapData = Utils.appendedFunction(AIJobTypeManager.loadMapData, function(self)
    self:registerJobType("MOD_ROAD_FOLLOW", "(mod) Road Follow", AIJobRoadFollow)
end)

-- The mouse wheel as the speed knob while the road assist drives (see RoadFollow.adjustSpeed). The
-- listener only looks at wheel events outside menus, for the vehicle the player is driving.
RoadFollowInput = {}
function RoadFollowInput:mouseEvent(posX, posY, isDown, isUp, button)
    if not isDown or g_currentMission == nil or Input == nil then
        return
    end
    if g_gui ~= nil and g_gui:getIsGuiVisible() then
        return
    end
    local direction = 0
    if button == Input.MOUSE_BUTTON_WHEEL_UP then
        direction = 1
    elseif button == Input.MOUSE_BUTTON_WHEEL_DOWN then
        direction = -1
    end
    if direction ~= 0 and RoadFollow ~= nil then
        RoadFollow.adjustSpeed(RoadFollow.getControlledVehicle(), direction)
    end
    -- turn signals: left mouse button = left, right mouse button = right (only while the assist drives)
    if RoadFollow ~= nil and RoadFollow.MOUSE_SIGNALS then
        if button == Input.MOUSE_BUTTON_LEFT then
            RoadFollow.signal(RoadFollow.getControlledVehicle(), "left")
        elseif button == Input.MOUSE_BUTTON_RIGHT then
            RoadFollow.signal(RoadFollow.getControlledVehicle(), "right")
        end
    end
end
addModEventListener(RoadFollowInput)

-- The scan lines (see RoadFollow.updateDebugView) are drawn from the mod's own per-frame update, and the hub tab is
-- registered as soon as WAILA is there.
RoadFollowDebugView = {}
function RoadFollowDebugView:update(dt)
    if RoadFollow ~= nil then
        RoadFollow.registerWailaTab()
        RoadFollow.hookLandscaping()
        RoadFollow.updateDebugView(dt)
        RoadFollow.updateRoadMap(dt)
    end
end
function RoadFollowDebugView:draw()
    if RoadFollow ~= nil then
        RoadFollow.drawRoadMap()
    end
    if RoadFollow ~= nil and RoadFollow.debugSecondsLeft > 0 and not (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(1, 0.9, 0.2, 1)
        renderText(0.02, 0.95, 0.014, string.format("Road Follow scan lines: %.0f s left (sit in a vehicle)", RoadFollow.debugSecondsLeft))
        setTextColor(1, 1, 1, 1)
    end
end
addModEventListener(RoadFollowDebugView)

-- Landscaping edits (paint, sculpt, smooth ...) tell the road follower where the terrain changed (the map picture is a snapshot): see RoadFollow.hookLandscaping.
if RoadFollow ~= nil then
    RoadFollow.hookLandscaping()
end
