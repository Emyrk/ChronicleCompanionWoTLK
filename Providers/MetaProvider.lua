-- =============================================================================
-- Providers/MetaProvider.lua
--
-- Emits relay throughput stats so the server knows how well the channel
-- is performing.  Reports landed chunk counts from the rolling 10-minute
-- bucket history.
--
-- Priority 5 (lowest -- after all real data).
-- Re-emits every 5 minutes.
--
-- Payload format:
--   M<landed_0>,<landed_1>,<landed_2>,...,<landed_9>
--
-- Each value is the landed count for that minute bucket (0 = current).
--
-- Example:
--   M12,8,15,3,0,0,0,0,0,0
-- =============================================================================

local Log   = Chronicle.Logger
local Relay = Chronicle.Relay

local P = {
    priority = 5,
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local dirty      = true     -- dirty on load
local lastEmitAt = 0
local REEMIT_SEC = 300      -- every 5 minutes

-- ---------------------------------------------------------------------------
-- Provider interface
-- ---------------------------------------------------------------------------

--- @treturn string provider label
function P:Label()
    return "Meta"
end

--- @treturn number 0 or 1
function P:Dirty()
    if dirty then return 1 end
    if (time() - lastEmitAt) >= REEMIT_SEC then return 1 end
    return 0
end

--- @treturn string|nil payload, string|nil summary
function P:Poll()
    local now = time()

    if not dirty and (now - lastEmitAt) < REEMIT_SEC then
        return nil
    end

    local buckets = Relay:GetBuckets()
    if not buckets then return nil end

    local parts = {}
    local total = 0
    for i = 1, #buckets do
        local landed = buckets[i].landed or 0
        parts[i] = tostring(landed)
        total = total + landed
    end

    -- Count total dirty across all providers
    local totalDirty = 0
    local provStates = Relay:GetProviderStates()
    for _, s in ipairs(provStates) do
        totalDirty = totalDirty + (s.dirty or 0)
    end

    dirty = false
    lastEmitAt = now

    -- Format: M<dirty>,<landed_0>,<landed_1>,...,<landed_9>
    local payload = "M" .. totalDirty .. "," .. table.concat(parts, ",")
    local summary = string.format("META d:%d %d landed/10m", totalDirty, total)

    return payload, summary
end

--- @treturn table state for UI/debug
function P:GetState()
    return {
        dirty      = dirty,
        lastEmitAt = lastEmitAt,
        reemitSec  = REEMIT_SEC,
    }
end

-- ---------------------------------------------------------------------------
-- Register with Relay
-- ---------------------------------------------------------------------------

Relay:RegisterProvider(P)
Chronicle.MetaProvider = P
