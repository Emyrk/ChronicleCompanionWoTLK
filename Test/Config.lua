local T = _G.Test
local cases = {}

local function add(name, run)
    cases[#cases + 1] = { name = name, run = run }
end

add("reset all preserves position upload data", function()
    local handlers = {}
    _G.Chronicle = {
        ADDON_NAME = "ChronicleCompanionWoTLK",
        RegisterEvent = function(event, fn) handlers[event] = fn end,
        UnregisterEvent = function() end,
        Logger = nil,
    }
    _G.ChronicleCompanionWoTLKDB = {
        log_level = "debug",
        position_payload = { schema_version = 1, tick_count = 10 },
    }
    _G.ChronicleCompanionWoTLKCharDB = {}

    dofile("Core/Config.lua")
    handlers.ADDON_LOADED("ADDON_LOADED", "ChronicleCompanionWoTLK")
    Chronicle.Config:ResetAll()

    T.equal(ChronicleCompanionWoTLKDB.log_level, "error")
    T.equal(ChronicleCompanionWoTLKDB.position_payload.tick_count, 10)
end)

return cases
