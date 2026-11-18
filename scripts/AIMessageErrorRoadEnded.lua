AIMessageErrorRoadEnded = {}
local AIMessageErrorRoadEnded_mt = Class(AIMessageErrorRoadEnded, AIMessage)

function AIMessageErrorRoadEnded.new(customMt)
    return AIMessage.new(customMt or AIMessageErrorRoadEnded_mt)
end

function AIMessageErrorRoadEnded:getMessage()
    return g_i18n:getText("ROADFOLLOW_AIERROR_ROAD_ENDED")
end
