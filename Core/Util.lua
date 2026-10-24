-- =============================================================================
-- Core/Util.lua
--
-- Small utility functions shared across modules.
-- =============================================================================

Chronicle.Util = {}
local U = Chronicle.Util

local epochAnchor = time()
local uptimeAnchor = GetTime()
local BASE36_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"
local BASE36_VALUES = {}

for i = 1, #BASE36_CHARS do
    BASE36_VALUES[BASE36_CHARS:sub(i, i)] = i - 1
end

--- Return epoch time in milliseconds as an exact decimal string.
-- Joining seconds and a padded fraction avoids Lua 5.1's 32-bit %d path.
-- @treturn string epoch milliseconds
function U.TimestampMs()
    local elapsed = GetTime() - uptimeAnchor
    local wholeSeconds = math.floor(elapsed)
    local milliseconds = math.floor((elapsed - wholeSeconds) * 1000 + 0.5)
    if milliseconds >= 1000 then
        wholeSeconds = wholeSeconds + 1
        milliseconds = 0
    end
    return tostring(epochAnchor + wholeSeconds) .. string.format("%03d", milliseconds)
end

--- Encode a non-negative number with the lowercase base36 alphabet.
-- @tparam number value non-negative integer-compatible value
-- @tparam[opt] number width left-pad to this many characters
-- @treturn string base36 value
function U.ToBase36(value, width)
    local n = math.floor(tonumber(value) or 0)
    if n < 0 then n = 0 end

    local encoded = "0"
    if n > 0 then
        local parts = {}
        while n > 0 do
            local remainder = n - math.floor(n / 36) * 36
            parts[#parts + 1] = BASE36_CHARS:sub(remainder + 1, remainder + 1)
            n = math.floor(n / 36)
        end
        local reversed = {}
        for i = #parts, 1, -1 do
            reversed[#reversed + 1] = parts[i]
        end
        encoded = table.concat(reversed)
    end

    width = tonumber(width)
    if width and #encoded < width then
        encoded = string.rep("0", width - #encoded) .. encoded
    end
    return encoded
end

--- Decode a lowercase base36 string.
-- @tparam string value base36 value
-- @treturn number|nil decoded value, or nil for invalid input
function U.FromBase36(value)
    if type(value) ~= "string" or value == "" then return nil end
    local result = 0
    for i = 1, #value do
        local digit = BASE36_VALUES[value:sub(i, i)]
        if digit == nil then return nil end
        result = result * 36 + digit
    end
    return result
end

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
