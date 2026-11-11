local T = _G.Test
local cases = {}

local function add(name, run)
    cases[#cases + 1] = { name = name, run = run }
end

local RU_TAB_NAMES = {
    "\208\158\209\128\209\131\208\182\208\184\208\181",
    "\208\157\208\181\208\184\209\129\209\130\208\190\208\178\209\129\209\130\208\178\208\190",
    "\208\151\208\176\209\137\208\184\209\130\208\176",
}

local EN_TAB_NAMES = { "Arms", "Fury", "Protection" }
local WARRIOR_BACKGROUNDS = { "WarriorArms", "WarriorFury", "WarriorProtection" }

local function loadTalentScan(options)
    options = options or {}
    local names = options.names or EN_TAB_NAMES
    local backgrounds = options.backgrounds or WARRIOR_BACKGROUNDS
    local activeGroup = options.activeGroup or 2
    local numGroups = options.numGroups or 2
    local groupRanks = options.groupRanks or {
        [1] = {
            [1] = { 5, 0 },
            [2] = { 0, 3 },
            [3] = { 1, 1 },
        },
        [2] = {
            [1] = { 0, 5 },
            [2] = { 2, 0 },
            [3] = { 0, 1 },
        },
    }

    _G.Chronicle = {
        Capture = {},
        Logger = { Debug = function() end },
    }
    _G.UnitClass = function()
        return options.className or "Warrior", options.classToken or "WARRIOR"
    end
    _G.GetNumTalentTabs = function() return 3 end
    _G.GetTalentTabInfo = function(tab, isInspect, isPet, group)
        local ranks = groupRanks[group or activeGroup][tab]
        local points = 0
        for _, rank in ipairs(ranks) do points = points + rank end
        return names[tab], "Icon" .. tab, points, backgrounds[tab], 0
    end
    _G.GetNumTalents = function() return 2 end
    _G.GetTalentInfo = function(tab, index, isInspect, isPet, group)
        local rank = groupRanks[group or activeGroup][tab][index]
        return "Talent" .. tab .. index, "TalentIcon", index, 1, rank, 5
    end
    _G.GetActiveTalentGroup = function() return activeGroup end
    _G.GetNumTalentGroups = function() return numGroups end

    dofile("Capture/TalentScan.lua")
    return Chronicle.Capture
end

add("inspected Russian talent names are accepted and dual specs are preserved", function()
    local capture = loadTalentScan({ names = RU_TAB_NAMES })
    local talents = capture.ScanTalents("raid1", true)

    T.truthy(talents)
    T.equal(talents.active_group, 2)
    T.equal(talents.num_groups, 2)
    T.equal(talents.groups[1].tabs[1].name, RU_TAB_NAMES[1])
    T.equal(talents.groups[1].rank_string, "50}03}11")
    T.equal(talents.groups[2].rank_string, "05}20}01")
end)

add("inspected English talent names remain accepted", function()
    local capture = loadTalentScan({ names = EN_TAB_NAMES })
    local talents = capture.ScanTalents("raid1", true)

    T.truthy(talents)
    T.equal(talents.groups[1].tabs[3].name, "Protection")
end)

add("all WotLK class tokens accept their stock talent background prefix", function()
    local fixtures = {
        { "WARRIOR", "WarriorArms" },
        { "PALADIN", "PaladinHoly" },
        { "HUNTER", "HunterBeastMastery" },
        { "ROGUE", "RogueAssassination" },
        { "PRIEST", "PriestDiscipline" },
        { "DEATHKNIGHT", "DeathKnightBlood" },
        { "SHAMAN", "ShamanElementalCombat" },
        { "MAGE", "MageArcane" },
        { "WARLOCK", "WarlockCurses" },
        { "DRUID", "DruidBalance" },
    }

    for _, fixture in ipairs(fixtures) do
        local capture = loadTalentScan({
            classToken = fixture[1],
            backgrounds = { fixture[2], fixture[2], fixture[2] },
        })
        T.truthy(capture.ScanTalents("raid1", true), fixture[1] .. " background rejected")
    end
end)

add("self scans do not validate inspect-buffer backgrounds", function()
    local capture = loadTalentScan({
        backgrounds = { "MageFire", "", "CustomTree" },
    })

    T.truthy(capture.ScanTalents("player", false))
end)

add("inspected talents reject a known cross-class background", function()
    local capture = loadTalentScan({
        backgrounds = { "WarriorArms", "MageFire", "WarriorProtection" },
    })

    T.falsy(capture.ScanTalents("raid1", true))
end)

add("inspected talents reject an incomplete background", function()
    local capture = loadTalentScan({
        backgrounds = { "WarriorArms", "", "WarriorProtection" },
    })

    T.falsy(capture.ScanTalents("raid1", true))
end)

add("inspected talents accept an unknown non-empty custom background", function()
    local capture = loadTalentScan({
        backgrounds = { "WarriorArms", "CustomFuryTree", "WarriorProtection" },
    })

    T.truthy(capture.ScanTalents("raid1", true))
end)

return cases
