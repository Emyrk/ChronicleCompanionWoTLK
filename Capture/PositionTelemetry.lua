-- =============================================================================
-- Capture/PositionTelemetry.lua
--
-- Samples visible party/raid map positions once per second while the player is
-- in combat and WoW combat logging is active. Data stays in SavedVariables for
-- the desktop uploader; it never enters the SPELL_CAST_FAILED relay.
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

local function api(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c, d
end

local function shouldCapture()
    if not Config:Get("position_telemetry_enabled", true) then return false end
    if Store:IsCapped() then return false end
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

local function readPosition(unit)
    if not api("UnitExists", unit) then return nil end
    local connected = api("UnitIsConnected", unit)
    if connected == false then return nil end

    local guid = api("UnitGUID", unit)
    local x, y = api("GetPlayerMapPosition", unit)
    if not guid or not x or not y or (x == 0 and y == 0) then return nil end
    return { guid = guid, x = x, y = y }
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

local function collectPositions()
    local oldContinent = api("GetCurrentMapContinent")
    local oldZone = api("GetCurrentMapZone")
    local oldDungeonLevel = api("GetCurrentMapDungeonLevel")
    local changedMap = false

    local playerX, playerY = api("GetPlayerMapPosition", "player")
    if (not playerX or not playerY or (playerX == 0 and playerY == 0))
        and not mapFrameIsVisible()
        and type(SetMapToCurrentZone) == "function"
    then
        api("SetMapToCurrentZone")
        changedMap = true
    end

    local mapId = tonumber(api("GetCurrentMapAreaID")) or 0
    local units = rosterUnits()
    local positions = {}
    local missing = 0

    for i = 1, math.min(#units, C.POSITION_UNIT_MAX) do
        local position = readPosition(units[i])
        if position then
            positions[#positions + 1] = position
        else
            missing = missing + 1
        end
    end

    if changedMap then
        restoreMap(oldContinent, oldZone, oldDungeonLevel)
    end
    return mapId, positions, missing
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

    local mapId, positions, missing = collectPositions()
    if missing > 0 then
        Store:RecordMissing(missing)
        if not missingWarned then
            local status = Store:GetStatus()
            if status.missing_positions >= C.POSITION_MISSING_WARN_SAMPLES then
                missingWarned = true
                Log:Warn("Some group positions are unavailable; capture will continue with visible units")
            end
        end
    end
    if #positions == 0 then return false end

    return Store:AppendTick(Util.TimestampMs(), mapId, positions)
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

--- Return whether the recurring sampler is active.
-- @treturn boolean
function Telemetry:IsActive()
    return active
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
