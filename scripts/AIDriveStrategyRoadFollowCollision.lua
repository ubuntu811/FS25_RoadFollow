-- Slows or stops for what is in the way, using the base game's collision trigger handler (the same
-- pieces its own AI strategies use; shaped after FollowMe's collision strategy).
AIDriveStrategyRoadFollowCollision = {}
local AIDriveStrategyRoadFollowCollision_mt = Class(AIDriveStrategyRoadFollowCollision, AIDriveStrategy)

function AIDriveStrategyRoadFollowCollision.new(reconstructionData, customMt)
    local self = AIDriveStrategy.new(reconstructionData, customMt or AIDriveStrategyRoadFollowCollision_mt)

    self.collisionHandler = AICollisionTriggerHandler.new()
    self.isBlocked = false
    self.hasStaticCollision = false
    self.collisionDistance = math.huge
    self.lastMovingDirection = 1
    self.lastMaxSpeed = math.huge
    return self
end

function AIDriveStrategyRoadFollowCollision:delete()
    AIDriveStrategyRoadFollowCollision:superClass().delete(self)
end

function AIDriveStrategyRoadFollowCollision:setAIVehicle(vehicle)
    AIDriveStrategyRoadFollowCollision:superClass().setAIVehicle(self, vehicle)

    self.collisionHandler:init(vehicle, self)
    -- a vehicle loaded onto this one (a damaged contract vehicle on a transporter) is cargo, not an obstacle
    if RoadLead ~= nil and RoadLead.ignoreCarried ~= nil then
        RoadLead.ignoreCarried(self.collisionHandler)
    end
    self.collisionHandler:setStaticCollisionCallback(function(hasStaticCollision)
        self.hasStaticCollision = hasStaticCollision
    end)
    self.collisionHandler:setIsBlockedCallback(function(isBlocked)
        self.isBlocked = isBlocked
    end)
    self.collisionHandler:setCollisionDistanceCallback(function(distance)
        -- the base game finds "collisions" on bridges and other things that are not really in the
        -- way; when it knows of a moving thing's hit point, that distance is the better one
        if self.collisionHandler.dynamicHitPointDistance ~= nil then
            self.collisionDistance = self.collisionHandler.dynamicHitPointDistance
        else
            self.collisionDistance = distance
        end
    end)
end

function AIDriveStrategyRoadFollowCollision:update(dt)
    self.collisionHandler:update(dt, self.lastMovingDirection)
end

-- Only a speed limit: no target of its own (returns nil, nil for the target)
function AIDriveStrategyRoadFollowCollision:getDriveData(dt, vX, vY, vZ)
    local maxSpeed = math.huge
    if self.isBlocked then
        maxSpeed = 0
    elseif self.collisionDistance ~= math.huge then
        -- static "collisions" are often bridges: do not crawl for those
        local lowestSpeed = self.hasStaticCollision and 10 or 1
        maxSpeed = math.max(self.collisionDistance * 2, lowestSpeed)
    end
    self.lastMaxSpeed = maxSpeed
    return nil, nil, true, maxSpeed, math.huge
end
