AIJobRoadFollow = {
    START_ERROR_LIMIT_REACHED = 1,
    START_ERROR_VEHICLE_DELETED = 2,
    START_ERROR_NO_PERMISSION = 3,
    START_ERROR_VEHICLE_IN_USE = 4
}
local AIJobRoadFollow_mt = Class(AIJobRoadFollow, AIJob)

function AIJobRoadFollow.new(isServer, customMt)
    local self = AIJob.new(isServer, customMt or AIJobRoadFollow_mt)
    self.roadFollowTask = AITaskRoadFollow.new(isServer, self)
    self:addTask(self.roadFollowTask)

    self.vehicleParameter = AIParameterVehicle.new()
    self:addNamedParameter("vehicle", self.vehicleParameter)
    return self
end

-- cruise control is not a paid helper
function AIJobRoadFollow:getPricePerMs()
    return 0
end

function AIJobRoadFollow:start(farmId)
    AIJobRoadFollow:superClass().start(self, farmId)

    if self.isServer then
        local vehicle = self.vehicleParameter:getVehicle()
        vehicle:createAgent(self.helperIndex)
        vehicle:aiJobStarted(self, self.helperIndex, farmId)
    end
end

function AIJobRoadFollow:stop(aiMessage)
    if self.isServer then
        local vehicle = self.vehicleParameter:getVehicle()
        vehicle:deleteAgent()
        vehicle:aiJobFinished()
    end

    AIJobRoadFollow:superClass().stop(self, aiMessage)
end

function AIJobRoadFollow:getIsAvailableForVehicle(vehicle)
    if vehicle ~= nil and vehicle.getCanStartRoadFollow ~= nil then
        return vehicle:getCanStartRoadFollow()
    end
    return false
end

function AIJobRoadFollow:getTitle()
    return "Road Follow"
end

function AIJobRoadFollow:getDescription()
    return "Road Follow"
end

function AIJobRoadFollow:applyCurrentState(vehicle, mission, farmId, isDirectStart)
    AIJobRoadFollow:superClass().applyCurrentState(self, vehicle, mission, farmId, isDirectStart)
    self.vehicleParameter:setVehicle(vehicle)
end

function AIJobRoadFollow:setValues()
    self:resetTasks()
    self.roadFollowTask:setVehicle(self.vehicleParameter:getVehicle())
end

function AIJobRoadFollow:validate(farmId)
    self:setParameterValid(true)

    local isVehicleValid, errorMessage = self.vehicleParameter:validate()
    if not isVehicleValid then
        self.vehicleParameter:setIsValid(false)
    end
    return isVehicleValid, errorMessage
end

function AIJobRoadFollow:getIsStartable(connection)
    if g_currentMission.aiSystem:getAILimitedReached() then
        return false, AIJobRoadFollow.START_ERROR_LIMIT_REACHED
    end

    local vehicle = self.vehicleParameter:getVehicle()
    if vehicle == nil then
        return false, AIJobRoadFollow.START_ERROR_VEHICLE_DELETED
    end

    if not g_currentMission:getHasPlayerPermission("hireAssistant", connection, vehicle:getOwnerFarmId()) then
        return false, AIJobRoadFollow.START_ERROR_NO_PERMISSION
    end

    if vehicle:getIsInUse(connection) then
        return false, AIJobRoadFollow.START_ERROR_VEHICLE_IN_USE
    end

    return true, AIJob.START_SUCCESS
end

function AIJobRoadFollow.getIsStartErrorText(state)
    if state == AIJobRoadFollow.START_ERROR_LIMIT_REACHED then
        return g_i18n:getText("ai_startStateLimitReached")
    elseif state == AIJobRoadFollow.START_ERROR_VEHICLE_DELETED then
        return g_i18n:getText("ai_startStateVehicleDeleted")
    elseif state == AIJobRoadFollow.START_ERROR_NO_PERMISSION then
        return g_i18n:getText("ai_startStateNoPermission")
    elseif state == AIJobRoadFollow.START_ERROR_VEHICLE_IN_USE then
        return g_i18n:getText("ai_startStateVehicleInUse")
    end

    return g_i18n:getText("ai_startStateSuccess")
end
