-- =============================================================================
-- Providers/ZoneProvider.lua
--
-- Emits zone/instance context into the combat log.  Dirty on zone change
-- or a periodic timer (default 10 min).  Highest priority provider --
-- zone context is cheap (1 chunk) and critical for the server to group
-- encounters correctly.
--
-- Payload format:
--   Z:<zoneName>,<instanceType>,<difficulty>,<subZone>
--
-- Example:
--   Z:Icecrown Citadel,raid,2,The Frozen Throne
--   Z:Stormwind City,none,1,Trade District
--   Z:Dalaran,none,1,
--
-- Reserved chars avoided: | " \n [ ]
-- =============================================================================

local Log    = Chronicle.Logger
local Relay  = Chronicle.Relay

local P = {
    priority = 1,   -- highest priority (cheap, 1 chunk, critical context)
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local dirty       = false
local lastPayload = nil   -- last emitted payload (dedup: skip if unchanged)
local lastEmitAt  = 0     -- time() of last successful emit
local REEMIT_SEC  = 600   -- re-emit every 10 minutes even if unchanged

-- ---------------------------------------------------------------------------
-- Build payload from current game state
-- ---------------------------------------------------------------------------

local Util = Chronicle.Util

local function buildPayload()
    -- GetInstanceInfo() confirmed on Warmane 3.3.5a
    -- Returns: name, type, difficultyIndex, difficultyName, maxPlayers,
    --          dynamicDifficulty, isDynamic, instanceMapID, lfgID
    local name, instType, diffIdx, diffName, maxPlayers,
          dynDiff, isDynamic, mapID, lfgID
    if type(GetInstanceInfo) == "function" then
        name, instType, diffIdx, diffName, maxPlayers,
            dynDiff, isDynamic, mapID, lfgID = GetInstanceInfo()
    end

    name       = Util.Sanitize(name or GetRealZoneText() or "")
    instType   = instType or "none"
    diffIdx    = diffIdx or 0
    diffName   = Util.Sanitize(diffName or "")
    maxPlayers = maxPlayers or 0
    dynDiff    = dynDiff or 0
    isDynamic  = isDynamic and 1 or 0
    mapID      = mapID or 0
    lfgID      = lfgID or 0

    local subZone = Util.Sanitize(GetSubZoneText() or "")

    -- Format: Z:<name>,<type>,<diffIdx>,<diffName>,<maxPlayers>,<dynDiff>,<isDynamic>,<mapID>,<lfgID>,<subZone>
    -- Example: Z:Icecrown Citadel,raid,2,25 Player,25,1,1,631,0,The Frozen Throne
    return string.format("Z:%s,%s,%d,%s,%d,%d,%d,%d,%d,%s",
        name, instType, diffIdx, diffName, maxPlayers, dynDiff, isDynamic, mapID, lfgID, subZone)
end

-- ---------------------------------------------------------------------------
-- Provider interface
-- ---------------------------------------------------------------------------

function P:Label()
    return "Zone"
end

--- Return the number of pending messages (0 or 1).
-- @treturn number 0 if clean, 1 if dirty or past re-emit timer
function P:Dirty()
    if dirty then return 1 end
    if (time() - lastEmitAt) >= REEMIT_SEC then return 1 end
    return 0
end

function P:Poll()
    local now = time()

    -- Periodic re-emit even if not dirty
    if not dirty and (now - lastEmitAt) >= REEMIT_SEC then
        dirty = true
    end

    if not dirty then return nil end

    local payload = buildPayload()

    -- Dedup: if payload is identical to last emit and we're not on the
    -- periodic timer, skip it.  (Zone didn't actually change.)
    if payload == lastPayload and (now - lastEmitAt) < REEMIT_SEC then
        dirty = false
        return nil
    end

    -- Mark clean + record state
    dirty = false
    lastPayload = payload
    lastEmitAt = now

    -- Short summary for relay UI
    local zoneName = GetRealZoneText() or "?"
    local summary = "ZONE " .. zoneName

    Log:Debug("ZoneProvider: emitting '%s'", payload)
    return payload, summary
end

--- Force the provider dirty (called from events or externally).
function P:MarkDirty()
    dirty = true
    Relay:Kick()
end

--- Return current state for UI/debug.
function P:GetState()
    return {
        dirty       = dirty,
        lastPayload = lastPayload,
        lastEmitAt  = lastEmitAt,
        reemitSec   = REEMIT_SEC,
    }
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

local function onZoneChanged()
    Log:Debug("ZoneProvider: zone changed, marking dirty")
    P:MarkDirty()
end

Chronicle.RegisterEvent("ZONE_CHANGED_NEW_AREA", onZoneChanged)
Chronicle.RegisterEvent("PLAYER_ENTERING_WORLD", onZoneChanged)

-- Also catch subzone changes (less critical, but keeps subZone fresh)
Chronicle.RegisterEvent("ZONE_CHANGED", function()
    -- Only mark dirty if the main zone also changed, or subzone is
    -- meaningful (inside an instance).  Avoid spamming on every
    -- subzone flicker in the open world.
    local _, instanceType = IsInInstance()
    if instanceType and instanceType ~= "none" then
        P:MarkDirty()
    end
end)

-- ---------------------------------------------------------------------------
-- Register with Relay
-- ---------------------------------------------------------------------------

Relay:RegisterProvider(P)
Chronicle.ZoneProvider = P
