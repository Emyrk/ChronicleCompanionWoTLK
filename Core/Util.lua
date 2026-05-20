-- =============================================================================
-- Core/Util.lua
--
-- Small utility functions shared across modules.
-- =============================================================================

Chronicle.Util = {}
local U = Chronicle.Util

local HEX_CHARS = "0123456789abcdef"

--- Generate a random hex string of the given length.
-- @tparam number len number of hex characters (each is 4 bits of entropy)
-- @treturn string random hex string (e.g. "a8f3" for len=4)
function U.RandomHex(len)
    local parts = {}
    for i = 1, len do
        local r = math.random(1, 16)
        parts[i] = HEX_CHARS:sub(r, r)
    end
    return table.concat(parts)
end

local ALNUM_CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local ALNUM_LEN   = #ALNUM_CHARS

--- Generate a random alphanumeric string of the given length.
-- @tparam number len number of characters (each is ~6 bits of entropy)
-- @treturn string random string (e.g. "kQ7xBm" for len=6)
function U.RandomAlnum(len)
    local parts = {}
    for i = 1, len do
        local r = math.random(1, ALNUM_LEN)
        parts[i] = ALNUM_CHARS:sub(r, r)
    end
    return table.concat(parts)
end

--- Sanitize a string for the wire protocol.
-- Strips characters that break combat log field parsing: | " [ ] and newlines.
-- @tparam string s input string
-- @treturn string sanitized string
function U.Sanitize(s)
    return (s or ""):gsub("[|%\"%[%]%\n]", "")
end
