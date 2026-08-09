-- =============================================================================
-- Providers/HeaderProvider.lua
--
-- Emits a session header into the combat log.  Contains addon version,
-- realm, locale, client build, and a session ID so the server can group
-- log segments from the same play session.
--
-- Priority 3 (after Reset and Zone, before Vehicle and PlayerList).
-- Dirty on relay activation. After the first emit, retries at 1 minute, then
-- settles into a 5-minute refresh cadence.
--
-- Payload format:
--   H:<addonVersion>,<realm>,<locale>,<wowVersion>,<wowBuild>,<sessionId>,<localEpoch>,<utcOffsetMin>
--
-- Example:
--   H:0.1,Icecrown,enUS,3.3.5a,12340,a8f3,1716508800,-420
--
-- localEpoch:    time() at emit, in seconds. Combat-log row timestamps are in
--                local wall-clock time; pairing the row timestamp with this
--                value (and the offset below) lets the server recover UTC.
-- utcOffsetMin:  signed minutes east of UTC. PDT = -420, UTC = 0, CEST = +120.
--                Demuxer disambiguates legacy (6 fields) from new (8 fields)
--                by counting commas; tag stays "H:".
--
-- Session ID is a short random hex string generated once per login.
-- It lets the server detect /reload boundaries within the same log file.
--
-- Reserved chars avoided: | " \n [ ]
-- =============================================================================

local Log   = Chronicle.Logger
local Relay = Chronicle.Relay

local P = {
    priority = 3,
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local dirty          = true       -- dirty on load (first session)
local lastEmitAt     = 0
local emitCount      = 0
local timerGeneration = 0
local sessionId      = nil        -- generated on PLAYER_LOGIN

local Util = Chronicle.Util

-- ---------------------------------------------------------------------------
-- UTC offset helper
-- ---------------------------------------------------------------------------
--
-- WoW's global time() is the game API, not the full Lua os.time function. On
-- 3.3.5a it does not accept a broken-down date table, so the common
-- time(date("!*t")) timezone trick makes HeaderProvider:Poll() fail and leaves
-- the session header permanently dirty. Compare local and UTC calendar fields
-- directly instead. At one instant those dates can differ by at most one day.
local function computeUtcOffsetMinutes(now)
    local okLocal, localParts = pcall(date, "*t", now)
    local okUtc, utcParts = pcall(date, "!*t", now)
    if not okLocal or not okUtc
        or type(localParts) ~= "table" or type(utcParts) ~= "table"
    then
        return 0
    end

    local dayDelta
    if localParts.year == utcParts.year then
        dayDelta = (localParts.yday or 0) - (utcParts.yday or 0)
    elseif localParts.year > utcParts.year then
        dayDelta = 1
    else
        dayDelta = -1
    end

    local hourDelta = (localParts.hour or 0) - (utcParts.hour or 0)
    local minuteDelta = (localParts.min or 0) - (utcParts.min or 0)
    return dayDelta * 1440 + hourDelta * 60 + minuteDelta
end

-- ---------------------------------------------------------------------------
-- Build payload from current game state
-- ---------------------------------------------------------------------------

local function buildPayload()
    local addonVersion = GetAddOnMetadata(Chronicle.ADDON_NAME, "Version") or "?"
    local realm = Util.Sanitize(GetRealmName() or "")
    local locale = GetLocale() or "enUS"

    -- GetBuildInfo() returns: version, buildNumber, buildDate, tocVersion
    local wowVersion, wowBuild = "?", "?"
    if type(GetBuildInfo) == "function" then
        wowVersion, wowBuild = GetBuildInfo()
        wowVersion = Util.Sanitize(tostring(wowVersion or "?"))
        wowBuild   = Util.Sanitize(tostring(wowBuild or "?"))
    end

    local sid = sessionId or "0000"

    local localEpoch   = time()
    local utcOffsetMin = computeUtcOffsetMinutes(localEpoch)

    -- Format: H:<addonVersion>,<realm>,<locale>,<wowVersion>,<wowBuild>,<sessionId>,<localEpoch>,<utcOffsetMin>
    return string.format("H:%s,%s,%s,%s,%s,%s,%d,%d",
        addonVersion, realm, locale, wowVersion, wowBuild, sid,
        localEpoch, utcOffsetMin)
end

-- ---------------------------------------------------------------------------
-- Provider interface
-- ---------------------------------------------------------------------------

--- @treturn string provider label for UI/debug
function P:Label()
    return "Header"
end

local function currentReemitSec()
    if emitCount <= 1 then
        return Chronicle.C.HEADER_INITIAL_REEMIT_SEC
    end
    return Chronicle.C.HEADER_REEMIT_SEC
end

local function scheduleReemit()
    timerGeneration = timerGeneration + 1
    local generation = timerGeneration
    local delay = currentReemitSec()
    Chronicle.RunAfter(delay, function()
        if generation == timerGeneration then
            P:MarkDirty()
        end
    end)
end

--- @treturn number 0 if clean, 1 if dirty or past re-emit timer
function P:Dirty()
    if dirty then return 1 end
    if (time() - lastEmitAt) >= currentReemitSec() then return 1 end
    return 0
end

--- @treturn string|nil payload string, or nil if nothing to send
function P:Poll()
    local now = time()

    -- Periodic re-emit. The quick second copy recovers from a startup carrier
    -- that CLEU observed but the file writer did not persist.
    if not dirty and (now - lastEmitAt) >= currentReemitSec() then
        dirty = true
    end

    if not dirty then return nil end

    local payload = buildPayload()

    dirty = false
    lastEmitAt = now
    emitCount = emitCount + 1

    scheduleReemit()

    local summary = "HDR " .. (sessionId or "?")

    Log:Debug("HeaderProvider: emitting '%s'", payload)
    return payload, summary
end

--- Force the provider dirty.
function P:MarkDirty()
    dirty = true
    Relay:Kick()
end

--- Return current state for UI/debug.
-- @treturn table { dirty, lastEmitAt, reemitSec, emitCount, sessionId }
function P:GetState()
    return {
        dirty       = dirty,
        lastPayload = nil,
        lastEmitAt  = lastEmitAt,
        reemitSec   = currentReemitSec(),
        emitCount   = emitCount,
        timerGeneration = timerGeneration,
        sessionId   = sessionId,
    }
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

Chronicle.RegisterEvent("PLAYER_LOGIN", function()
    sessionId = Util.RandomHex(4)
    Log:Debug("HeaderProvider: session ID = %s", sessionId)
    P:MarkDirty()
end)

-- ---------------------------------------------------------------------------
-- Register with Relay
-- ---------------------------------------------------------------------------

Relay:RegisterProvider(P)
Chronicle.HeaderProvider = P
