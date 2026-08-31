-- =============================================================================
-- Providers/RaidGroupProvider.lua
--
-- Emits the current raid composition as eight fixed five-player groups. Each
-- field contains a player GUID; unused group positions remain empty so the
-- server can reconstruct subgroup boundaries without relying on raid-unit
-- ordering.
--
-- Payload format:
--   RG:<group1-slot1>,...,<group8-slot5>
--
-- Example (abbreviated):
--   RG:0x001,0x002,,,,0x006,...
-- =============================================================================

local C     = Chronicle.C
local Log   = Chronicle.Logger
local Relay = Chronicle.Relay

local P = {
    priority = C.RAID_GROUP_PROVIDER_PRIORITY,
}

local dirty         = false
local forceDirty    = false
local lastPayload   = nil
local lastGroups    = nil
local lastEmitAt    = 0
local pendingReason = nil
local retryPending  = false
local retryCount    = 0

local fieldCount = C.RAID_GROUP_MAX * C.RAID_GROUP_SLOT_MAX

-- Compact the hexadecimal text without converting through a Lua number. WoW
-- GUIDs are 64-bit values, while Lua 5.1 numbers cannot preserve every integer
-- above 53 bits exactly.
local function compactGuid(guid)
    local hex = guid and string.match(guid, "^0[xX]([0-9A-Fa-f]+)$")
    if not hex then return guid end

    hex = string.gsub(hex, "^0+", "")
    if hex == "" then hex = "0" end
    return hex
end

-- Build a stable group-major layout. GetRaidRosterInfo() is the source of truth
-- for subgroup membership; raidN ordering alone is not a subgroup contract.
-- A nil payload means the roster is still hydrating and must not be emitted.
local function buildPayload()
    local memberCount = GetNumRaidMembers()
    if not memberCount or memberCount <= 0 then
        return nil, false, nil
    end

    local fields = {}
    local groupCounts = {}
    local groupsByGuid = {}

    for fieldIndex = 1, fieldCount do
        fields[fieldIndex] = ""
    end
    for groupIndex = 1, C.RAID_GROUP_MAX do
        groupCounts[groupIndex] = 0
    end

    for raidIndex = 1, memberCount do
        local _, _, subgroup = GetRaidRosterInfo(raidIndex)
        local guid = UnitGUID("raid" .. raidIndex)
        if not subgroup or subgroup < 1 or subgroup > C.RAID_GROUP_MAX or not guid then
            return nil, true
        end

        local slot = groupCounts[subgroup] + 1
        if slot > C.RAID_GROUP_SLOT_MAX then
            return nil, true
        end

        local fieldIndex = ((subgroup - 1) * C.RAID_GROUP_SLOT_MAX) + slot
        fields[fieldIndex] = compactGuid(guid)
        groupCounts[subgroup] = slot
        groupsByGuid[guid] = subgroup
    end

    return "RG:" .. table.concat(fields, ","), true, groupsByGuid
end

local function describeLayoutChange(groupsByGuid)
    if not lastPayload then
        return "initial raid layout"
    end

    local added = 0
    local removed = 0
    local moved = 0
    local previous = lastGroups or {}

    for guid, subgroup in pairs(groupsByGuid) do
        if not previous[guid] then
            added = added + 1
        elseif previous[guid] ~= subgroup then
            moved = moved + 1
        end
    end
    for guid in pairs(previous) do
        if not groupsByGuid[guid] then
            removed = removed + 1
        end
    end

    if added == 0 and removed == 0 and moved == 0 then
        return "raid slot order changed"
    end
    return string.format("roster changed (+%d -%d moved:%d)", added, removed, moved)
end

local function queueStale(reason)
    dirty = true
    if not pendingReason then
        pendingReason = reason
        Log:Debug("RaidGroupProvider: stale (%s); next layout queued", reason)
    end
    Relay:Kick()
end

local function clearState()
    dirty = false
    forceDirty = false
    lastPayload = nil
    lastGroups = nil
    pendingReason = nil
    retryCount = 0
end

local refreshStaleState

local function scheduleRetry()
    if retryPending or retryCount >= C.RAID_GROUP_RETRY_MAX_ATTEMPTS then return end

    retryPending = true
    retryCount = retryCount + 1
    Chronicle.RunAfter(C.RAID_GROUP_RETRY_SEC, function()
        retryPending = false
        refreshStaleState()
    end)
end

-- Compare the live layout to the last emitted layout after roster-related
-- events. These events also fire for changes that do not alter composition, so
-- the comparison prevents needless multi-chunk re-emits.
refreshStaleState = function()
    local payload, inRaid, groupsByGuid = buildPayload()
    if not inRaid then
        clearState()
        return
    end
    if not payload then
        dirty = true
        scheduleRetry()
        return
    end

    retryCount = 0

    if payload ~= lastPayload then
        queueStale(describeLayoutChange(groupsByGuid))
    elseif not forceDirty then
        dirty = false
        pendingReason = nil
    end
end

local function scheduleRosterCheck()
    -- Roster events can fire while raid unit IDs are still being rebuilt.
    -- Comparing on the next frame avoids most transient layouts; bounded
    -- delayed retries cover clients that need more than one frame.
    retryCount = 0
    Chronicle.RunNextFrame(refreshStaleState)
end

local function onZoneChanged()
    retryCount = 0
    if GetNumRaidMembers() <= 0 then
        clearState()
        return
    end

    forceDirty = true
    queueStale("zone changed")
    scheduleRetry()
end

-- ---------------------------------------------------------------------------
-- Provider interface
-- ---------------------------------------------------------------------------

--- @treturn string provider label for UI/debug
function P:Label()
    return "RaidGroup"
end

--- @treturn number 0 if clean, 1 if a layout is pending
function P:Dirty()
    return dirty and 1 or 0
end

--- @treturn string|nil payload, string|nil summary
function P:Poll()
    if not dirty then return nil end

    local payload, inRaid, groupsByGuid = buildPayload()
    if not inRaid then
        clearState()
        return nil
    end
    if not payload then
        scheduleRetry()
        return nil
    end

    retryCount = 0

    if payload == lastPayload and not forceDirty then
        dirty = false
        pendingReason = nil
        return nil
    end

    dirty = false
    forceDirty = false
    pendingReason = nil
    lastPayload = payload
    lastGroups = groupsByGuid
    lastEmitAt = time()

    local memberCount = GetNumRaidMembers() or 0
    local summary = "RAID GROUPS " .. tostring(memberCount)
    Log:Debug("RaidGroupProvider: emitting raid layout for %d members", memberCount)
    return payload, summary
end

--- Force a layout re-emit even if composition is unchanged.
--- @treturn nil
function P:MarkDirty()
    if GetNumRaidMembers() <= 0 then return end
    forceDirty = true
    queueStale("forced externally")
end

--- @treturn table state for UI/debug
function P:GetState()
    return {
        dirty = dirty,
        forceDirty = forceDirty,
        pendingReason = pendingReason,
        lastPayload = lastPayload,
        lastEmitAt = lastEmitAt,
    }
end

-- 3.3.5a roster events. They also cover joins, leaves, and subgroup moves.
Chronicle.RegisterEvent("RAID_ROSTER_UPDATE", scheduleRosterCheck)
Chronicle.RegisterEvent("PARTY_MEMBERS_CHANGED", scheduleRosterCheck)

-- Zone transitions require a fresh layout even when the raid is unchanged.
Chronicle.RegisterEvent("ZONE_CHANGED_NEW_AREA", onZoneChanged)
Chronicle.RegisterEvent("PLAYER_ENTERING_WORLD", onZoneChanged)

Relay:RegisterProvider(P)
Chronicle.RaidGroupProvider = P
