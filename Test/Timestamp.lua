local T = _G.Test
local cases = {}

local function add(name, run)
    cases[#cases + 1] = { name = name, run = run }
end

local function loadUtil(epoch, uptime)
    _G.Chronicle = {}
    _G.time = function() return epoch end
    local currentUptime = uptime
    _G.GetTime = function() return currentUptime end
    dofile("Core/Util.lua")
    return Chronicle.Util, function(value) currentUptime = value end
end

add("timestamp preserves epoch milliseconds without integer formatting", function()
    local util, setUptime = loadUtil(1786244400, 100.25)
    T.equal(util.TimestampMs(), "1786244400000")
    setUptime(101.484)
    T.equal(util.TimestampMs(), "1786244401234")
end)

add("timestamp carries rounded milliseconds into the next second", function()
    local util, setUptime = loadUtil(1786244400, 10)
    setUptime(10.9996)
    T.equal(util.TimestampMs(), "1786244401000")
end)

add("base36 supports fixed-width telemetry fields", function()
    local util = loadUtil(1786244400, 0)
    T.equal(util.ToBase36(0, 2), "00")
    T.equal(util.ToBase36(35, 2), "0z")
    T.equal(util.ToBase36(631, 3), "0hj")
    T.equal(util.FromBase36("0hj"), 631)
end)

return cases
