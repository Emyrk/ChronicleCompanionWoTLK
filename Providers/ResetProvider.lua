-- =============================================================================
-- Providers/ResetProvider.lua
--
-- Listens for INSTANCE_RESET_SUCCESS and emits a single message recording
-- the time the player reset their instances.  Only the most recent reset
-- is retained -- if a second reset fires before the relay drains the first,
-- the older timestamp is overwritten.  This is intentional: back-to-back
-- resets collapse into one "latest" marker for the server demuxer.
--
-- Payload format:
--   R:<unixTimestamp>
--
-- Example:
--   R:1716240123
--
-- Reserved chars avoided: | , " \n [ ]
-- (`:` is reserved in the base64 alphabet but is fine in payload bodies;
--  every other provider uses it as the type/value separator too.)
--
-- Priority 1 -- resets are rare, 1 chunk, and mark instance boundaries the
-- server demuxer needs early.  All other providers shift down by 1.
-- =============================================================================

local Log   = Chronicle.Logger
local Relay = Chronicle.Relay

local P = {
    priority = 1,
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local pendingTs = nil   -- single integer timestamp slot; latest reset wins

-- ---------------------------------------------------------------------------
-- Provider interface
-- ---------------------------------------------------------------------------

--- @treturn string provider label
function P:Label()
    return "Reset"
end

--- @treturn number 1 if a reset is pending, 0 otherwise
function P:Dirty()
    return pendingTs and 1 or 0
end

--- @treturn string|nil payload, string|nil summary
function P:Poll()
    if not pendingTs then return nil end

    local ts = pendingTs
    pendingTs = nil

    local payload = "R:" .. ts
    return payload, "RESET"
end

--- Return current state for UI/debug.
-- @treturn table { pendingTs = pendingTs }
function P:GetState()
    return {
        pendingTs = pendingTs,
    }
end

-- ---------------------------------------------------------------------------
-- Event wiring
--
-- IMPORTANT: on 3.3.5a there is NO `INSTANCE_RESET_SUCCESS` event.
-- `INSTANCE_RESET_SUCCESS` is a GlobalStrings entry ("%s has been reset.")
-- that the server sends as a CHAT_MSG_SYSTEM line.  We have to pattern-match
-- the chat message instead of listening for a named event.
-- ---------------------------------------------------------------------------

-- Build a Lua pattern from the localized format string.
-- INSTANCE_RESET_SUCCESS = "%s has been reset." -> "^(.+) has been reset%.$"
local RESET_PATTERN
do
    local fmt = _G.INSTANCE_RESET_SUCCESS or "%s has been reset."
    -- Escape Lua-pattern magic chars, then replace the %s placeholder with a
    -- capture.  Order matters: escape first, then swap the (now-escaped) %%s.
    local escaped = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    RESET_PATTERN = "^" .. escaped:gsub("%%%%s", "(.+)") .. "$"
end

Chronicle.RegisterEvent("CHAT_MSG_SYSTEM", function(event, msg)
    if not msg then return end
    local instanceName = msg:match(RESET_PATTERN)
    if not instanceName then return end

    Log:Debug("ResetProvider: reset observed for '%s'", instanceName)
    pendingTs = time()  -- overwrites any prior un-drained reset
    Log:Debug("ResetProvider: queued reset at %d", pendingTs)
    Relay:Kick()
end)

-- ---------------------------------------------------------------------------
-- Register with Relay
-- ---------------------------------------------------------------------------

Relay:RegisterProvider(P)
Chronicle.ResetProvider = P
