-- =============================================================================
-- Capture/TalentScan.lua
--
-- Reads talent data for the local player or an inspected unit.
-- WotLK dual-spec aware: reads both talent groups when the 5th-arg
-- extension to GetTalentInfo is available, otherwise falls back to the
-- active group only.
--
-- Also provides a rank_string per group in Chronicle's upstream format:
--   "ranks_tab1}ranks_tab2}ranks_tab3"
-- where each tab's portion is the concatenation of every talent's current
-- rank digit in talent-index order (including 0 for unspent).
--
-- Buffer-race defense: for inspected units, validates that the returned
-- talent tab names match the expected class.  Returns nil + warning on
-- mismatch (another addon clobbered the global inspect buffer).
-- =============================================================================

local Log = Chronicle.Logger
local Capture = Chronicle.Capture

-- ---------------------------------------------------------------------------
-- Class -> expected talent tab names (English, matches 3.3.5 data)
-- Used for inspect-buffer-race detection.
-- ---------------------------------------------------------------------------

local CLASS_TAB_NAMES = {
    WARRIOR     = { "Arms", "Fury", "Protection" },
    PALADIN     = { "Holy", "Protection", "Retribution" },
    HUNTER      = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE       = { "Assassination", "Combat", "Subtlety" },
    PRIEST      = { "Discipline", "Holy", "Shadow" },
    DEATHKNIGHT = { "Blood", "Frost", "Unholy" },
    SHAMAN      = { "Elemental", "Enhancement", "Restoration" },
    MAGE        = { "Arcane", "Fire", "Frost" },
    WARLOCK     = { "Affliction", "Demonology", "Destruction" },
    DRUID       = { "Balance", "Feral Combat", "Restoration" },
}

-- Feature-test dual-spec C-APIs (added in 3.1.0, pure C-side, not in FrameXML)
local hasActiveTalentGroup = type(GetActiveTalentGroup) == "function"
local hasNumTalentGroups   = type(GetNumTalentGroups)   == "function"

-- ---------------------------------------------------------------------------
-- Internal: read a single talent group
-- ---------------------------------------------------------------------------

--- Read talent data for one spec group.
-- @param isInspect  boolean  true when reading an inspected unit's buffer
-- @param group      number   talent group index (1 or 2), or nil to omit the arg
-- @return table { tabs = { [1..3] = { name, icon, points, talents } }, rank_string }
local function readGroup(isInspect, group)
    local numTabs = GetNumTalentTabs(isInspect) or 3
    local tabs = {}
    local rankParts = {}

    for tab = 1, numTabs do
        -- GetTalentTabInfo: (tab, isInspect, isPet, [group])
        local tabName, tabIcon, tabPoints
        if group then
            tabName, tabIcon, tabPoints = GetTalentTabInfo(tab, isInspect, false, group)
        else
            tabName, tabIcon, tabPoints = GetTalentTabInfo(tab, isInspect, false)
        end

        local numTalents = GetNumTalents(tab, isInspect) or 0
        local talents = {}
        local rankDigits = {}

        for idx = 1, numTalents do
            -- GetTalentInfo: (tab, idx, isInspect, isPet, [group])
            local name, icon, tier, column, rank, maxRank
            if group then
                name, icon, tier, column, rank, maxRank = GetTalentInfo(tab, idx, isInspect, false, group)
            else
                name, icon, tier, column, rank, maxRank = GetTalentInfo(tab, idx, isInspect, false)
            end

            rank = rank or 0
            maxRank = maxRank or 0
            rankDigits[#rankDigits + 1] = tostring(rank)

            -- Sparse: only store talents with at least 1 point
            if rank > 0 then
                talents[idx] = {
                    name = name,
                    rank = rank,
                    max  = maxRank,
                }
            end
        end

        tabs[tab] = {
            name    = tabName or ("Tab" .. tab),
            icon    = tabIcon or "",
            points  = tabPoints or 0,
            talents = talents,
        }
        rankParts[tab] = table.concat(rankDigits, "")
    end

    return {
        tabs        = tabs,
        rank_string = table.concat(rankParts, "}"),
    }
end

-- ---------------------------------------------------------------------------
-- Buffer-race validation
-- ---------------------------------------------------------------------------

local function validateTabNames(tabs, unit)
    local _, classToken = UnitClass(unit)
    if not classToken then return true end  -- can't validate without class

    local expected = CLASS_TAB_NAMES[classToken]
    if not expected then return true end  -- unknown class, skip validation

    for i = 1, 3 do
        if tabs[i] and expected[i] and tabs[i].name ~= expected[i] then
            Log:Debug("TalentScan: buffer race for %s -- expected '%s', got '%s' (will retry)",
                tostring(unit), expected[i], tostring(tabs[i].name))
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Scan talents for a unit.
-- @param unit       string   "player", "target", "raid5", etc.
-- @param isInspect  boolean  true if reading another player's inspect buffer
-- @return table or nil  (nil on buffer-race or data unavailable)
function Capture.ScanTalents(unit, isInspect)
    unit = unit or "player"
    isInspect = isInspect or false

    -- Determine how many spec groups exist and which is active
    local activeGroup = 1
    local numGroups = 1

    if hasActiveTalentGroup then
        local ok, val = pcall(GetActiveTalentGroup, isInspect)
        if ok and val then activeGroup = val end
    end
    if hasNumTalentGroups then
        local ok, val = pcall(GetNumTalentGroups, isInspect)
        if ok and val then numGroups = val end
    end

    local result = {
        active_group = activeGroup,
        num_groups   = numGroups,
        groups       = {},
    }

    -- Try reading each group using the 5th-arg extension.
    -- If the extension doesn't work, fall back to no-group reads.
    local useFifthArg = true

    for g = 1, numGroups do
        local groupData
        if useFifthArg then
            local ok, data = pcall(readGroup, isInspect, g)
            if ok and data then
                groupData = data
            else
                -- 5th arg failed -- fall back to reading without group arg
                -- (this only gives us the active spec's data)
                useFifthArg = false
                Log:Debug("TalentScan: 5th-arg extension unavailable, falling back to active-group-only")
                groupData = readGroup(isInspect, nil)
            end
        else
            -- Without the 5th arg we can only read the active group,
            -- so skip inactive groups entirely.
            if g == activeGroup then
                groupData = readGroup(isInspect, nil)
            end
        end

        if groupData then
            -- Buffer-race check for inspected units
            if isInspect and not validateTabNames(groupData.tabs, unit) then
                return nil
            end
            result.groups[g] = groupData
        end
    end

    local totalPoints = 0
    local activeData = result.groups[activeGroup]
    if activeData then
        for _, tab in pairs(activeData.tabs) do
            totalPoints = totalPoints + (tab.points or 0)
        end
    end
    -- Verbose stats available via /chron inspect talents

    return result
end

--- Pretty-print talent scan results to chat.
-- @param talents  table  Output from ScanTalents()
function Capture.PrintTalents(talents)
    if not talents then
        Log:Info("TalentScan: no talent data")
        return
    end
    Log:Info("Active group: %d  |  Total groups: %d", talents.active_group, talents.num_groups)
    for g = 1, talents.num_groups do
        local group = talents.groups[g]
        if group then
            local marker = (g == talents.active_group) and " (active)" or ""
            Log:Info("  Group %d%s:", g, marker)
            for t = 1, #group.tabs do
                local tab = group.tabs[t]
                Log:Info("    %s: %d pts", tab.name, tab.points)
            end
            Log:Info("    rank_string: %s", group.rank_string)
        else
            Log:Info("  Group %d: <unavailable>", g)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Probe: raw API return-value dump for verifying the 5th-arg extension
-- ---------------------------------------------------------------------------

--- Print raw GetTalentInfo output for group 1 vs group 2 (talent 1 of tab 1).
-- Used to verify whether the talentGroup arg works on Warmane 3.3.5a.
function Capture.ProbeTalents()
    Log:Info("--- Talent 5th-arg probe ---")
    Log:Info("GetActiveTalentGroup available: %s", tostring(hasActiveTalentGroup))
    Log:Info("GetNumTalentGroups available: %s", tostring(hasNumTalentGroups))

    if hasActiveTalentGroup then
        Log:Info("Active group: %s", tostring(GetActiveTalentGroup(false)))
    end
    if hasNumTalentGroups then
        Log:Info("Num groups: %s", tostring(GetNumTalentGroups(false)))
    end

    -- Read tab 1, talent 1 with group=1 and group=2
    local function dump5thArg(group)
        local ok, name, icon, tier, col, rank, maxRank = pcall(
            GetTalentInfo, 1, 1, false, false, group
        )
        if ok then
            Log:Info("  GetTalentInfo(1,1,false,false,%d) -> name=%s rank=%s max=%s",
                group, tostring(name), tostring(rank), tostring(maxRank))
        else
            Log:Info("  GetTalentInfo(1,1,false,false,%d) -> ERROR: %s", group, tostring(name))
        end
    end

    Log:Info("With 5th arg (talentGroup):")
    dump5thArg(1)
    dump5thArg(2)

    Log:Info("Without 5th arg (baseline):")
    local name, _, _, _, rank, maxRank = GetTalentInfo(1, 1, false, false)
    Log:Info("  GetTalentInfo(1,1,false,false) -> name=%s rank=%s max=%s",
        tostring(name), tostring(rank), tostring(maxRank))
    Log:Info("--- end probe ---")
end
