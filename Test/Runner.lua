local suites = {
    "Test/Timestamp.lua",
    "Test/Logger.lua",
    "Test/Config.lua",
    "Test/PositionStore.lua",
    "Test/PositionTelemetry.lua",
    "Test/SettingsUI.lua",
}

local total = 0
local failed = 0

local function fail(message)
    error(message or "assertion failed", 2)
end

_G.Test = {
    equal = function(actual, expected, message)
        if actual ~= expected then
            fail((message or "values differ")
                .. ": expected " .. tostring(expected)
                .. ", got " .. tostring(actual))
        end
    end,
    truthy = function(value, message)
        if not value then fail(message or "expected truthy value") end
    end,
    falsy = function(value, message)
        if value then fail(message or "expected falsy value") end
    end,
    contains = function(haystack, needle, message)
        if not tostring(haystack):find(needle, 1, true) then
            fail((message or "substring missing") .. ": " .. tostring(needle))
        end
    end,
}

for _, path in ipairs(suites) do
    local cases = assert(dofile(path))
    for _, case in ipairs(cases) do
        total = total + 1
        local ok, err = pcall(case.run)
        if ok then
            io.write("PASS ", case.name, "\n")
        else
            failed = failed + 1
            io.write("FAIL ", case.name, ": ", tostring(err), "\n")
        end
    end
end

io.write(string.format("\n%d tests, %d failures\n", total, failed))
if failed > 0 then os.exit(1) end
