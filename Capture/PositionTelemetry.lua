-- =============================================================================
-- Capture/PositionTelemetry.lua
--
-- Samples visible party/raid map positions and percentage vitals once per second
-- while the player is in combat and WoW combat logging is active. Data stays in
-- SavedVariables for the desktop uploader; it never enters the failed-cast relay.
-- =============================================================================

local C = Chronicle.C
local Config = Chronicle.Config
local Log = Chronicle.Logger
local Store = Chronicle.PositionStore
local Util = Chronicle.Util
local Telemetry = {}
Chronicle.PositionTelemetry = Telemetry

local active = false
local generation = 0
local missingWarned = false
local unavailableWarned = false
local lastSample = nil

local function api(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c, d
end

local function shouldCapture()
    if not Config:Get("position_telemetry_enabled", true) then return false end
    if not Store:IsReady() or Store:IsCapped() then return false end
    if not api("LoggingCombat") then return false end
    if not api("UnitAffectingCombat", "player") then return false end
    return true
end

local function rosterUnits()
    local units = {}
    local raidCount = math.min(tonumber(api("GetNumRaidMembers")) or 0, C.POSITION_UNIT_MAX)
    if raidCount > 0 then
        for i = 1, raidCount do
            units[#units + 1] = "raid" .. i
        end
        return units
    end

    units[1] = "player"
    local partyCount = math.min(tonumber(api("GetNumPartyMembers")) or 0, C.PARTY_MEMBER_MAX)
    for i = 1, partyCount do
        units[#units + 1] = "party" .. i
    end
    return units
end

local function toPermille(current, maximum)
    current = tonumber(current)
    maximum = tonumber(maximum)
    if not current or current ~= current or not maximum or maximum ~= maximum
        or maximum <= 0 then
        return nil
    end
    local value = math.floor(current * C.POSITION_VITAL_PERCENT_SCALE / maximum + 0.5)
    if value < 0 then value = 0 end
    if value > C.POSITION_VITAL_PERCENT_SCALE then
        value = C.POSITION_VITAL_PERCENT_SCALE
    end
    return value
end

local function readUnitSample(unit)
    if not api("UnitExists", unit) then return nil end
    local connected = api("UnitIsConnected", unit)
    if connected == false then return nil end

    local guid = api("UnitGUID", unit)
    local x, y = api("GetPlayerMapPosition", unit)
    if not guid or not x or not y or (x == 0 and y == 0) then return nil end

    local health = api("UnitHealth", unit)
    local healthMax = api("UnitHealthMax", unit)
    local resourceType = api("UnitPowerType", unit)
    local resource = api("UnitPower", unit, resourceType)
    local resourceMax = api("UnitPowerMax", unit, resourceType)
    if resource == nil then resource = api("UnitMana", unit) end
    if resourceMax == nil then resourceMax = api("UnitManaMax", unit) end

    return {
        guid = guid,
        x = x,
        y = y,
        health_permille = toPermille(health, healthMax),
        resource_permille = toPermille(resource, resourceMax),
        health_max = tonumber(healthMax),
        resource_max = tonumber(resourceMax),
        resource_type = tonumber(resourceType),
    }
end

local function mapFrameIsVisible()
    if not WorldMapFrame or type(WorldMapFrame.IsShown) ~= "function" then
        return false
    end
    local ok, shown = pcall(WorldMapFrame.IsShown, WorldMapFrame)
    return ok and shown or false
end

local function restoreMap(continent, zone, dungeonLevel)
    if continent and continent > 0 and zone and zone > 0 then
        api("SetMapZoom", continent, zone)
        if dungeonLevel and dungeonLevel > 0 then
            api("SetDungeonMapLevel", dungeonLevel)
        end
    end
end

local function recordSample(mapId, playerX, playerY, available, missing, dungeonLevel)
    lastSample = {
        map_id = mapId,
        dungeon_level = dungeonLevel,
        player_x = playerX,
        player_y = playerY,
        available = available,
        missing = missing,
        map_visible = mapFrameIsVisible(),
    }
end

local function collectPositions()
    local units = rosterUnits()
    local oldContinent = api("GetCurrentMapContinent")
    local oldZone = api("GetCurrentMapZone")
    local oldDungeonLevel = api("GetCurrentMapDungeonLevel")
    local changedMap = false

    local playerX, playerY = api("GetPlayerMapPosition", "player")
    if not playerX or not playerY or (playerX == 0 and playerY == 0) then
        -- Never sample a user-selected map as if it were the player's current
        -- coordinate space. Wait until the world map is hidden instead.
        if mapFrameIsVisible() or type(SetMapToCurrentZone) ~= "function" then
            recordSample(0, playerX, playerY, 0, #units, api("GetCurrentMapDungeonLevel"))
            return 0, {}, #units
        end
        local ok = pcall(SetMapToCurrentZone)
        if not ok then
            recordSample(0, playerX, playerY, 0, #units, api("GetCurrentMapDungeonLevel"))
            return 0, {}, #units
        end
        changedMap = true
    end

    local mapId = tonumber(api("GetCurrentMapAreaID")) or 0
    local dungeonLevel = api("GetCurrentMapDungeonLevel")
    -- Diagnostics must describe the sampled map, before the old map is restored.
    playerX, playerY = api("GetPlayerMapPosition", "player")
    local positions = {}
    local missing = 0

    for i = 1, math.min(#units, C.POSITION_UNIT_MAX) do
        local position = readUnitSample(units[i])
        if position then
            positions[#positions + 1] = position
        else
            missing = missing + 1
        end
    end

    recordSample(mapId, playerX, playerY, #positions, missing, dungeonLevel)
    if changedMap then
        restoreMap(oldContinent, oldZone, oldDungeonLevel)
    end
    return mapId, positions, missing, dungeonLevel
end

local function scheduleNext(token)
    Chronicle.RunAfter(C.POSITION_SAMPLE_INTERVAL_SEC, function()
        if not active or token ~= generation then return end
        if not shouldCapture() then
            Telemetry:Stop()
            return
        end

        Telemetry:CaptureOnce()
        if active and token == generation and not Store:IsCapped() then
            scheduleNext(token)
        else
            Telemetry:Stop()
        end
    end)
end

--- Capture one timestamped group-position tick when all gates are satisfied.
-- @treturn boolean true when a tick was appended
function Telemetry:CaptureOnce()
    if not shouldCapture() then return false end

    local mapId, positions, missing, dungeonLevel = collectPositions()
    if missing > 0 then
        Store:RecordMissing(missing)
        local status = Store:GetStatus()
        if status.missing_positions >= C.POSITION_MISSING_WARN_SAMPLES then
            if #positions == 0 and not unavailableWarned then
                unavailableWarned = true
                Log:Warn("No usable map coordinates returned; no position ticks saved. Some WotLK instances have no supported map. See /clog positions")
            elseif #positions > 0 and not missingWarned then
                missingWarned = true
                Log:Warn("Some group positions are unavailable; capture will continue with visible units")
            end
        end
    end
    if #positions == 0 then return false end

    return Store:AppendTick(Util.TimestampMs(), mapId, positions, dungeonLevel)
end

--- Start the single recurring combat sampler.
function Telemetry:Start()
    if active or not shouldCapture() then return end
    active = true
    generation = generation + 1
    local token = generation
    self:CaptureOnce()
    if active and not Store:IsCapped() then scheduleNext(token) end
end

--- Stop sampling and invalidate pending timer callbacks.
function Telemetry:Stop()
    if not active then return end
    active = false
    generation = generation + 1
end

--- Clear capture data and diagnostics, then resume only when capture is enabled.
-- @treturn boolean true when the position store was reset
function Telemetry:ClearPositions()
    if not Store:Clear() then return false end
    self:Stop()
    missingWarned = false
    unavailableWarned = false
    lastSample = nil
    self:Start()
    Log:Info("Position data cleared. Use /reload or log out to save the cleared state to disk")
    return true
end

--- Return whether the recurring sampler is active.
-- @treturn boolean
function Telemetry:IsActive()
    return active
end

--- Probe raw map-coordinate support for accessible units without storing samples.
-- The engine's handling of non-player tokens is not specified by FrameXML.
-- Keep raw zeroes/errors visible so a live test cannot mistake them for evidence
-- of working enemy positions. Never change the map selection during this probe.
-- @treturn table map context and per-unit raw API results
function Telemetry:ProbeEnemyPositions()
    local result = {
        map_id = api("GetCurrentMapAreaID"),
        dungeon_level = api("GetCurrentMapDungeonLevel"),
        map_visible = mapFrameIsVisible(),
        units = {},
    }
    Log:Info("Position probe: map=%s floor=%s mapVisible=%s (no map changes or saved samples)",
        tostring(result.map_id), tostring(result.dungeon_level), tostring(result.map_visible))
    local units = { "player", "target", "focus", "mouseover", "targettarget" }
    for _, unit in ipairs(units) do
        if api("UnitExists", unit) then
            local sample = {
                unit = unit,
                guid = api("UnitGUID", unit),
                hostile = api("UnitCanAttack", "player", unit),
                is_player = api("UnitIsPlayer", unit),
            }
            if type(GetPlayerMapPosition) == "function" then
                local ok, x, y = pcall(GetPlayerMapPosition, unit)
                sample.ok = ok
                if ok then
                    sample.x, sample.y = x, y
                else
                    sample.error = tostring(x)
                    Log:Warn("Position probe: GetPlayerMapPosition(%s) failed: %s", unit, sample.error)
                end
            else
                sample.ok = false
                sample.error = "GetPlayerMapPosition unavailable"
                Log:Warn("Position probe: %s", sample.error)
            end
            result.units[#result.units + 1] = sample
            Log:Info("  %s guid=%s hostile=%s player=%s ok=%s x=%s y=%s",
                unit, tostring(sample.guid), tostring(sample.hostile), tostring(sample.is_player),
                tostring(sample.ok), tostring(sample.x), tostring(sample.y))
        end
    end
    Log:Info("Raw results only: compare a moving enemy against a stationary player before trusting coordinates")
    return result
end

--- Return diagnostics for the last attempted tick, without changing the map.
-- @treturn table|nil copy of the last sample summary, or nil before sampling
function Telemetry:GetLastSample()
    if not lastSample then return nil end
    local result = {}
    for key, value in pairs(lastSample) do result[key] = value end
    return result
end

Chronicle.RegisterEvent("PLAYER_LOGIN", function()
    Chronicle.RunNextFrame(function()
        Store:Hydrate()
        if api("UnitAffectingCombat", "player") then
            Telemetry:Start()
        end
    end)
end)

Chronicle.RegisterEvent("PLAYER_REGEN_DISABLED", function()
    Telemetry:Start()
end)

Chronicle.RegisterEvent("PLAYER_REGEN_ENABLED", function()
    Telemetry:Stop()
end)

Chronicle.RegisterEvent("PLAYER_LOGOUT", function()
    Telemetry:Stop()
end)
