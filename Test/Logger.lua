local T = _G.Test
local cases = {}

local function add(name, run)
    cases[#cases + 1] = { name = name, run = run }
end

add("alerts remain visible when normal warnings are filtered", function()
    local messages = {}
    _G.Chronicle = {}
    _G.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, message) messages[#messages + 1] = message end,
    }
    _G.geterrorhandler = function() return function() end end

    dofile("Core/Logger.lua")
    Chronicle.Logger:SetLevel("error")
    Chronicle.Logger:Warn("hidden")
    T.equal(#messages, 0)
    Chronicle.Logger:Alert("visible")
    T.equal(#messages, 1)
    T.contains(messages[1], "visible")
end)

return cases
