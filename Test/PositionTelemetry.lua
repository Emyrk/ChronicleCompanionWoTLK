local T = _G.Test
local cases = {}

local function add(name, run)
    cases[#cases + 1] = { name = name, run = run }
end

local function loadTelemetry(options)
    options = options or {}
    local appended = {}
    local missing = 0
    local scheduled = {}
    local mapSetCalls = 0
    local handlers = {}
    local warnings = {}
    local positions = options.positions or {
        player = { 0.25, 0.75 },
        party1 = { 0.50, 0.60 },
    }

    _G.Chronicle = {
        C = {
            POSITION_SAMPLE_INTERVAL_SEC = 1,
            POSITION_UNIT_MAX = 50,
            POSITION_MISSING_WARN_SAMPLES = 10,
            PARTY_MEMBER_MAX = 4,
            RAID_MEMBER_MAX = 40,
        },
        Config = {
            Get = function(_, key)
                if key == "position_telemetry_enabled" then
                    return options.enabled ~= false
                end
            end,
        },
        Logger = { Warn = function(_, message) warnings[#warnings + 1] = message end, Info = function() end },
        Util = { TimestampMs = function() return "1786244400123" end },
        PositionStore = {
            Clear = function() return options.clearResult ~= false end,
            IsReady = function() return options.bridgeReady ~= false end,
            AppendTick = function(_, timestamp, mapId, samples)
                appended[#appended + 1] = {
                    timestamp = timestamp,
                    mapId = mapId,
                    samples = samples,
                }
                return options.appendResult ~= false
            end,
            RecordMissing = function(_, count) missing = missing + count end,
            GetStatus = function() return { missing_positions = missing } end,
            IsCapped = function() return options.capped == true end,
        },
        RegisterEvent = function(event, fn) handlers[event] = fn end,
        RunNextFrame = function(fn) fn() end,
        RunAfter = function(_, fn) scheduled[#scheduled + 1] = fn end,
    }

    _G.LoggingCombat = function() return options.logging ~= false end
    _G.UnitAffectingCombat = function() return options.combat ~= false end
    _G.GetNumRaidMembers = function() return options.raidCount or 0 end
    _G.GetNumPartyMembers = function() return options.partyCount or 1 end
    _G.UnitExists = function(unit) return positions[unit] ~= nil end
    _G.UnitIsConnected = function() return true end
    _G.UnitGUID = function(unit)
        if not positions[unit] then return nil end
        if unit == "player" then return "0x0000000000000001" end
        local index = tonumber(unit:match("(%d+)$")) or 2
        return string.format("0x%016x", index + 1)
    end
    _G.GetCurrentMapAreaID = function() return 631 end
    _G.GetPlayerMapPosition = function(unit)
        local value = positions[unit]
        if not value then return 0, 0 end
        return value[1], value[2]
    end
    _G.WorldMapFrame = { IsShown = function() return options.worldMapVisible == true end }
    _G.SetMapToCurrentZone = function() mapSetCalls = mapSetCalls + 1 end
    _G.GetCurrentMapContinent = function() return 1 end
    _G.GetCurrentMapZone = function() return 2 end
    _G.GetCurrentMapDungeonLevel = function() return 1 end
    _G.SetMapZoom = function() end
    _G.SetDungeonMapLevel = function() end

    dofile("Capture/PositionTelemetry.lua")
    return Chronicle.PositionTelemetry, appended, function() return missing end,
        scheduled, handlers, warnings, function() return mapSetCalls end
end

add("capture is gated by combat logging", function()
    local telemetry, appended = loadTelemetry({ logging = false })
    T.falsy(telemetry:CaptureOnce())
    T.equal(#appended, 0)
end)

add("capture is gated by player combat", function()
    local telemetry, appended = loadTelemetry({ combat = false })
    T.falsy(telemetry:CaptureOnce())
    T.equal(#appended, 0)
end)

add("capture stores one epoch for all visible group positions", function()
    local telemetry, appended = loadTelemetry()
    T.truthy(telemetry:CaptureOnce())
    T.equal(#appended, 1)
    T.equal(appended[1].timestamp, "1786244400123")
    T.equal(appended[1].mapId, 631)
    T.equal(#appended[1].samples, 2)
    T.equal(appended[1].samples[1].guid, "0x0000000000000001")
    T.equal(appended[1].samples[2].guid, "0x0000000000000002")
end)

add("missing map coordinates are counted and omitted", function()
    local telemetry, appended, getMissing = loadTelemetry({
        positions = {
            player = { 0.25, 0.75 },
            party1 = { 0, 0 },
        },
    })
    T.truthy(telemetry:CaptureOnce())
    T.equal(#appended[1].samples, 1)
    T.equal(getMissing(), 1)
end)

add("visible world map prevents sampling an unrelated coordinate space", function()
    local telemetry, appended, getMissing, _, _, _, getMapSetCalls = loadTelemetry({
        worldMapVisible = true,
        positions = {
            player = { 0, 0 },
            party1 = { 0.50, 0.60 },
        },
    })
    T.falsy(telemetry:CaptureOnce())
    T.equal(#appended, 0)
    T.equal(getMissing(), 2)
    T.equal(getMapSetCalls(), 0)
end)

add("map fallback retries after setting the current zone", function()
    local telemetry, appended = loadTelemetry()
    local calls = 0
    _G.GetPlayerMapPosition = function(unit)
        calls = calls + 1
        if calls <= 1 then return 0, 0 end
        if unit == "player" then return 0.25, 0.75 end
        return 0.50, 0.60
    end
    T.truthy(telemetry:CaptureOnce())
    T.equal(#appended[1].samples, 2)
    T.truthy(calls >= 3)
end)

add("raid sampling supports fifty visible units", function()
    local positions = {}
    for i = 1, 50 do positions["raid" .. i] = { i / 100, i / 100 } end
    local telemetry, appended = loadTelemetry({ raidCount = 50, partyCount = 0, positions = positions })
    T.truthy(telemetry:CaptureOnce())
    T.equal(#appended[1].samples, 50)
end)

add("turning combat logging off stops the timer chain", function()
    local options = {}
    local telemetry, appended, _, scheduled = loadTelemetry(options)
    telemetry:Start()
    T.equal(#appended, 1)
    options.logging = false
    scheduled[1]()
    T.equal(#appended, 1)
    T.falsy(telemetry:IsActive())
end)

add("start creates one timer chain and stop invalidates it", function()
    local telemetry, appended, _, scheduled = loadTelemetry()
    telemetry:Start()
    telemetry:Start()
    T.equal(#appended, 1)
    T.equal(#scheduled, 1)
    telemetry:Stop()
    scheduled[1]()
    T.equal(#appended, 1)
end)

add("unsupported map retries without saving fabricated zero coordinates", function()
    local positions = { player = { 0, 0 }, party1 = { 0, 0 } }
    local telemetry, appended, getMissing, scheduled, _, warnings = loadTelemetry({ positions = positions })
    T.equal(telemetry:GetLastSample(), nil)
    telemetry:Start()
    for i = 1, 6 do scheduled[i]() end
    T.truthy(telemetry:IsActive())
    T.equal(#appended, 0)
    T.equal(getMissing(), 14)
    T.equal(#warnings, 1)
    T.contains(warnings[1], "No usable map coordinates")
    local sample = telemetry:GetLastSample()
    T.equal(sample.available, 0)
    T.equal(sample.missing, 2)
    T.equal(sample.player_x, 0)
    T.equal(sample.player_y, 0)
    T.equal(sample.map_id, 631)
    T.equal(sample.dungeon_level, 1)
    sample.available = 99
    T.equal(telemetry:GetLastSample().available, 0)

    positions.player = { 0.25, 0.75 }
    positions.party1 = { 0.50, 0.60 }
    scheduled[7]()
    T.equal(#appended, 1)
    T.equal(telemetry:GetLastSample().available, 2)
end)

add("partial availability has a different warning from no coordinates", function()
    local telemetry, appended, _, _, _, warnings = loadTelemetry({
        positions = { player = { 0.25, 0.75 }, party1 = { 0, 0 } },
    })
    for i = 1, 11 do telemetry:CaptureOnce() end
    T.equal(#appended, 11)
    T.equal(#warnings, 1)
    T.contains(warnings[1], "Some group positions")
end)

add("visible world map is not changed and is reported in diagnostics", function()
    local telemetry, appended = loadTelemetry({
        positions = { player = { 0, 0 }, party1 = { 0, 0 } },
    })
    _G.WorldMapFrame.IsShown = function() return true end
    _G.SetMapToCurrentZone = function() error("must not change a visible map") end
    T.falsy(telemetry:CaptureOnce())
    T.equal(#appended, 0)
    T.truthy(telemetry:GetLastSample().map_visible)
end)

add("unavailable bridge prevents sampling and timer creation", function()
    local telemetry, appended, getMissing, scheduled = loadTelemetry({ bridgeReady = false })
    _G.GetPlayerMapPosition = function() error("must not sample without persistent storage") end
    telemetry:Start()
    T.falsy(telemetry:CaptureOnce())
    T.falsy(telemetry:IsActive())
    T.equal(#appended, 0)
    T.equal(#scheduled, 0)
    T.equal(getMissing(), 0)
end)

add("clear invalidates the old timer chain and resumes enabled capture", function()
    local telemetry, appended, _, scheduled = loadTelemetry()
    telemetry:Start()
    T.equal(#appended, 1)
    local oldTimer = scheduled[1]
    T.truthy(telemetry:ClearPositions())
    T.equal(#appended, 2)
    oldTimer()
    T.equal(#appended, 2)
    scheduled[2]()
    T.equal(#appended, 3)
end)

add("clear honors disabled capture and removes last-sample diagnostics", function()
    local options = {}
    local telemetry = loadTelemetry(options)
    telemetry:Start()
    options.enabled = false
    T.truthy(telemetry:ClearPositions())
    T.falsy(telemetry:IsActive())
    T.equal(telemetry:GetLastSample(), nil)
end)

add("failed clear leaves the running sampler alone", function()
    local telemetry = loadTelemetry({ clearResult = false })
    telemetry:Start()
    T.falsy(telemetry:ClearPositions())
    T.truthy(telemetry:IsActive())
end)

return cases
