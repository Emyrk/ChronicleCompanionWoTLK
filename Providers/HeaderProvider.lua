-- =============================================================================
-- Providers/HeaderProvider.lua
--
-- Emits a session header into the combat log.  Contains addon version,
-- realm, locale, client build, and a session ID so the server can group
-- log segments from the same play session.
--
-- Priority 2 (after Zone, before PlayerList).
-- Dirty at session start and every 30 minutes.
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

local dirty       = true       -- dirty on load (first session)
local lastEmitAt  = 0
local REEMIT_SEC  = 1800       -- re-emit every 30 minutes
local sessionId   = nil        -- generated on PLAYER_LOGIN

local Util = Chronicle.Util

-- ---------------------------------------------------------------------------
-- UTC offset helper
-- ---------------------------------------------------------------------------
--
-- Lua 5.1 has no direct "local TZ offset" API.  Standard trick: take the
-- current epoch, format it as a UTC broken-down table with date("!*t"), then
-- feed that table back through time() -- which interprets it as *local* time.
-- The delta is (local - UTC) in seconds.  difftime() handles platforms where
-- time_t isn't a plain number; fall back to subtraction if it's missing.
local function computeUtcOffsetMinutes()
    local now = time()
    local utc = date("!*t", now)
    utc.isdst = false
    local utcAsLocal = time(utc)
    local diff
    if type(difftime) == "function" then
        diff = difftime(now, utcAsLocal)
    else
        diff = now - utcAsLocal
    end
    return math.floor(diff / 60 + 0.5)
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
    local utcOffsetMin = computeUtcOffsetMinutes()

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

--- @treturn number 0 if clean, 1 if dirty or past re-emit timer
function P:Dirty()
    if dirty then return 1 end
    if (time() - lastEmitAt) >= REEMIT_SEC then return 1 end
    return 0
end

--- @treturn string|nil payload string, or nil if nothing to send
function P:Poll()
    local now = time()

    -- Periodic re-emit
    if not dirty and (now - lastEmitAt) >= REEMIT_SEC then
        dirty = true
    end

    if not dirty then return nil end

    local payload = buildPayload()

    dirty = false
    lastEmitAt = now

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
-- @treturn table { dirty, lastEmitAt, reemitSec, sessionId }
function P:GetState()
    return {
        dirty       = dirty,
        lastPayload = nil,
        lastEmitAt  = lastEmitAt,
        reemitSec   = REEMIT_SEC,
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
