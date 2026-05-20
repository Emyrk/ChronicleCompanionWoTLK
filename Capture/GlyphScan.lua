-- =============================================================================
-- Capture/GlyphScan.lua
--
-- Reads glyph data for the local player.  WotLK has 6 glyph sockets
-- (3 major + 3 minor).  Attempts to read both spec groups via the
-- 2nd-arg extension to GetGlyphSocketInfo; falls back to active-spec-only
-- if the extension is unavailable.
--
-- Note: GetGlyphSocketInfo only works for the local player ("player").
-- There is no API to read another player's glyphs via the inspect buffer
-- on 3.3.5a.
-- =============================================================================

local Log = Chronicle.Logger
local Capture = Chronicle.Capture

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- NUM_GLYPH_SLOTS is a Blizzard global (= 6 on 3.3.5a)
local GLYPH_SLOTS = NUM_GLYPH_SLOTS or 6

-- Glyph types returned by GetGlyphSocketInfo:
--   1 = Major, 2 = Minor  (Blizzard constants GLYPHTYPE_MAJOR / GLYPHTYPE_MINOR)
local GLYPH_TYPE_MAJOR = 1
local GLYPH_TYPE_MINOR = 2

-- Feature-test: dual-spec group arg support
local hasActiveTalentGroup = type(GetActiveTalentGroup) == "function"
local hasNumTalentGroups   = type(GetNumTalentGroups)   == "function"

-- ---------------------------------------------------------------------------
-- Internal: read glyphs for one talent group
-- ---------------------------------------------------------------------------

--- Read all 6 glyph sockets for a given talent group.
-- @param group  number|nil  talent group index (1 or 2), or nil to omit arg
-- @return table { major = { [1..3] = entry }, minor = { [1..3] = entry } }
local function readGroup(group)
    local major = {}
    local minor = {}
    local majorIdx = 0
    local minorIdx = 0

    for i = 1, GLYPH_SLOTS do
        local enabled, glyphType, glyphSpellID, icon
        if group then
            enabled, glyphType, glyphSpellID, icon = GetGlyphSocketInfo(i, group)
        else
            enabled, glyphType, glyphSpellID, icon = GetGlyphSocketInfo(i)
        end

        local entry = {
            spell_id = glyphSpellID or 0,
            enabled  = enabled and true or false,
        }

        if glyphType == GLYPH_TYPE_MAJOR then
            majorIdx = majorIdx + 1
            major[majorIdx] = entry
        elseif glyphType == GLYPH_TYPE_MINOR then
            minorIdx = minorIdx + 1
            minor[minorIdx] = entry
        else
            -- Unknown or nil glyphType -- bucket by socket index parity as fallback.
            -- Standard layout: sockets 1-3 = major, 4-6 = minor.
            if i <= 3 then
                majorIdx = majorIdx + 1
                major[majorIdx] = entry
            else
                minorIdx = minorIdx + 1
                minor[minorIdx] = entry
            end
        end
    end

    return { major = major, minor = minor }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Scan glyph data for the local player.
-- @return table  { active_group, groups = { [1..2] = { major, minor } }, inactive_spec_available }
function Capture.ScanGlyphs()
    local activeGroup = 1
    local numGroups = 1

    if hasActiveTalentGroup then
        local ok, val = pcall(GetActiveTalentGroup, false)
        if ok and val then activeGroup = val end
    end
    if hasNumTalentGroups then
        local ok, val = pcall(GetNumTalentGroups, false)
        if ok and val then numGroups = val end
    end

    local result = {
        active_group = activeGroup,
        groups = {},
        inactive_spec_available = false,
    }

    -- Always read the active group without the 2nd arg (guaranteed to work)
    result.groups[activeGroup] = readGroup(nil)

    -- Try reading inactive group(s) with the 2nd-arg extension
    if numGroups > 1 then
        for g = 1, numGroups do
            if g ~= activeGroup then
                local ok, data = pcall(readGroup, g)
                if ok and data then
                    -- Verify the data is actually different from the active group
                    -- (if the 2nd arg is silently ignored, data will be identical)
                    result.groups[g] = data
                    result.inactive_spec_available = true
                else
                    Log:Debug("GlyphScan: 2nd-arg extension failed for group %d: %s",
                        g, tostring(data))
                end
            end
        end

        -- Also re-read the active group WITH the group arg, to confirm
        -- the extension works consistently
        if result.inactive_spec_available then
            local ok, data = pcall(readGroup, activeGroup)
            if ok and data then
                result.groups[activeGroup] = data
            end
        end
    end

    local activeData = result.groups[activeGroup]
    local numActive = 0
    if activeData then
        for _, e in ipairs(activeData.major) do
            if e.spell_id > 0 then numActive = numActive + 1 end
        end
        for _, e in ipairs(activeData.minor) do
            if e.spell_id > 0 then numActive = numActive + 1 end
        end
    end
    -- Verbose scan stats available via /chron inspect glyphs

    return result
end

--- Pretty-print glyph scan results to chat.
-- @param glyphs  table  Output from ScanGlyphs()
function Capture.PrintGlyphs(glyphs)
    if not glyphs then
        Log:Info("GlyphScan: no glyph data")
        return
    end
    Log:Info("Active group: %d  |  Inactive spec readable: %s",
        glyphs.active_group, tostring(glyphs.inactive_spec_available))
    for g, group in pairs(glyphs.groups) do
        local marker = (g == glyphs.active_group) and " (active)" or ""
        Log:Info("  Group %d%s:", g, marker)
        Log:Info("    Major:")
        for i, e in ipairs(group.major) do
            local status = e.enabled and "filled" or "empty"
            Log:Info("      [%d] spell_id=%d (%s)", i, e.spell_id, status)
        end
        Log:Info("    Minor:")
        for i, e in ipairs(group.minor) do
            local status = e.enabled and "filled" or "empty"
            Log:Info("      [%d] spell_id=%d (%s)", i, e.spell_id, status)
        end
    end
end

--- Print raw GetGlyphSocketInfo output for group 1 vs group 2 (socket 1).
-- Used to verify whether the 2nd-arg extension works on Warmane 3.3.5a.
function Capture.ProbeGlyphs()
    Log:Info("--- Glyph 2nd-arg probe ---")
    Log:Info("NUM_GLYPH_SLOTS = %s", tostring(NUM_GLYPH_SLOTS))

    -- Without 2nd arg (baseline)
    Log:Info("Without 2nd arg (baseline):")
    for i = 1, GLYPH_SLOTS do
        local enabled, glyphType, spellID, icon = GetGlyphSocketInfo(i)
        Log:Info("  socket %d: enabled=%s type=%s spellID=%s",
            i, tostring(enabled), tostring(glyphType), tostring(spellID))
    end

    -- With 2nd arg = 1
    Log:Info("With 2nd arg = 1:")
    for i = 1, GLYPH_SLOTS do
        local ok, enabled, glyphType, spellID, icon = pcall(GetGlyphSocketInfo, i, 1)
        if ok then
            Log:Info("  socket %d: enabled=%s type=%s spellID=%s",
                i, tostring(enabled), tostring(glyphType), tostring(spellID))
        else
            Log:Info("  socket %d: ERROR: %s", i, tostring(enabled))
        end
    end

    -- With 2nd arg = 2
    Log:Info("With 2nd arg = 2:")
    for i = 1, GLYPH_SLOTS do
        local ok, enabled, glyphType, spellID, icon = pcall(GetGlyphSocketInfo, i, 2)
        if ok then
            Log:Info("  socket %d: enabled=%s type=%s spellID=%s",
                i, tostring(enabled), tostring(glyphType), tostring(spellID))
        else
            Log:Info("  socket %d: ERROR: %s", i, tostring(enabled))
        end
    end
    Log:Info("--- end probe ---")
end
