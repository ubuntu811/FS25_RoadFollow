AITaskRoadFollow = {}
local AITaskRoadFollow_mt = Class(AITaskRoadFollow, AITask)

function AITaskRoadFollow.new(isServer, job, customMt)
    local self = AITask.new(isServer, job, customMt or AITaskRoadFollow_mt)
    self.vehicle = nil
    return self
end

function AITaskRoadFollow:reset()
    self.vehicle = nil
    AITaskRoadFollow:superClass().reset(self)
end

function AITaskRoadFollow:update(dt)
end

function AITaskRoadFollow:setVehicle(vehicle)
    self.vehicle = vehicle
end

function AITaskRoadFollow:start()
    if self.isServer then
        self.vehicle:startRoadFollow()
    end
    AITaskRoadFollow:superClass().start(self)
end

function AITaskRoadFollow:stop()
    AITaskRoadFollow:superClass().stop(self)
    if self.isServer then
        self.vehicle:stopRoadFollow()
    end
end
