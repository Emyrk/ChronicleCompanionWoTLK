-- =============================================================================
-- Capture/LocalScan.lua
--
-- Full "combatant info" assembler.  Ties GearScan, TalentScan, GlyphScan
-- together with guild / pet / honor / arena team readers and produces the
-- CI struct that will eventually be serialised and smuggled.
--
-- Also owns the slash-command handler for the addon -- both the existing
-- DispatchProbe commands (arm / disarm / log / probe) and the new nested
-- "inspect" sub-commands for testing individual capture functions.
--
-- Slash aliases: /chron, /chronicle, /clog  (all three route here)
-- =============================================================================

local Log = Chronicle.Logger
local Capture = Chronicle.Capture

-- ---------------------------------------------------------------------------
-- Guild
-- ---------------------------------------------------------------------------

--- Read guild info for a unit.
-- @param unit  string  "player", "target", "raid5", etc.
-- @return table or nil  { name, rank_name, rank_index }
function Capture.ScanGuild(unit)
    unit = unit or "player"
    local guildName, rankName, rankIndex = GetGuildInfo(unit)
    if not guildName then return nil end
    return {
        name       = guildName,
        rank_name  = rankName or "",
        rank_index = rankIndex or 0,
    }
end

-- ---------------------------------------------------------------------------
-- Pet
-- ---------------------------------------------------------------------------

--- Derive the pet unit token from a player unit token.
-- "player" -> "pet",  "raid5" -> "raid5pet",  "party2" -> "party2pet"
local function derivePetUnit(unit)
    if unit == "player" then return "pet" end
    return unit .. "pet"
end

--- Read pet info for a unit.
-- @param unit  string  "player", "target", "raid5", etc.
-- @return table or nil  { name, guid, family }
function Capture.ScanPet(unit)
    unit = unit or "player"
    local petUnit = derivePetUnit(unit)
    if not UnitExists(petUnit) then return nil end
    return {
        name   = UnitName(petUnit) or "Unknown",
        guid   = UnitGUID(petUnit) or "",
        family = UnitCreatureFamily(petUnit) or "",
    }
end

-- ---------------------------------------------------------------------------
-- Honor / PvP  (local player only -- can't inspect others' honor)
-- ---------------------------------------------------------------------------

--- Read PvP / honor stats for the local player.
-- @return table  { lifetime_hk, highest_rank, honor_currency, session_hk }
function Capture.ScanHonor()
    local lifetimeHK, highestRank = 0, 0
    if type(GetPVPLifetimeStats) == "function" then
        lifetimeHK, highestRank = GetPVPLifetimeStats()
    end

    local honorCurrency = 0
    if type(GetHonorCurrency) == "function" then
        honorCurrency = GetHonorCurrency()
    end

    local sessionHK = 0
    if type(GetPVPSessionStats) == "function" then
        sessionHK = GetPVPSessionStats()
    end

    return {
        lifetime_hk    = lifetimeHK or 0,
        highest_rank   = highestRank or 0,
        honor_currency = honorCurrency or 0,
        session_hk     = sessionHK or 0,
    }
end

-- ---------------------------------------------------------------------------
-- Arena Teams  (local player only via GetArenaTeam*, or inspected via
--               GetInspectArenaTeamData if available)
-- ---------------------------------------------------------------------------

local ARENA_BRACKETS = { 2, 3, 5 }

--- Read arena team info for the local player.
-- @return table or nil  { ["2v2"]={...}, ["3v3"]={...}, ["5v5"]={...} }
function Capture.ScanArenaTeams()
    -- Try GetArenaTeam* (local player) first, fall back to GetInspectArenaTeamData
    local reader = nil
    if type(GetArenaTeam) == "function" then
        -- GetArenaTeam(teamSize) -> teamName, teamSize, teamRating, teamPlayed,
        --   teamWon, seasonPlayed, seasonWon, playerPlayed, seasonPlayerPlayed,
        --   teamRank, personalRating
        reader = function(bracket)
            local name, _, rating, played, won, _, _, _, _, _, personalRating =
                GetArenaTeam(bracket)
            if not name then return nil end
            return {
                name            = name,
                rating          = rating or 0,
                played          = played or 0,
                won             = won or 0,
                personal_rating = personalRating or 0,
            }
        end
    elseif type(GetInspectArenaTeamData) == "function" then
        reader = function(bracket)
            local name, _, rating, played, won, _, personalRating =
                GetInspectArenaTeamData(bracket)
            if not name then return nil end
            return {
                name            = name,
                rating          = rating or 0,
                played          = played or 0,
                won             = won or 0,
                personal_rating = personalRating or 0,
            }
        end
    end

    if not reader then return nil end

    local teams = {}
    local any = false
    for _, bracket in ipairs(ARENA_BRACKETS) do
        local ok, data = pcall(reader, bracket)
        if ok and data then
            teams[bracket .. "v" .. bracket] = data
            any = true
        end
    end
    return any and teams or nil
end

-- ---------------------------------------------------------------------------
-- Instance snapshot
-- ---------------------------------------------------------------------------

local function captureInstance()
    if type(GetInstanceInfo) ~= "function" then return nil end
    local name, instType, diffIdx, diffName, maxPlayers, playerDiff, isDynamic, mapId =
        GetInstanceInfo()
    if not name or name == "" then return nil end
    return {
        name             = name,
        instance_type    = instType or "",
        difficulty_index = diffIdx or 0,
        difficulty_name  = diffName or "",
        max_players      = maxPlayers or 0,
        player_difficulty = playerDiff or 0,
        is_dynamic       = isDynamic and true or false,
        map_id           = mapId or 0,
    }
end

-- ---------------------------------------------------------------------------
-- Full CI assemblers
-- ---------------------------------------------------------------------------

--- Build a complete Combatant Info struct for the local player.
-- @return table  The CI struct ready for serialization
function Capture.ScanLocal()
    local ci = {
        player = {
            guid   = UnitGUID("player") or "",
            name   = UnitName("player") or "Unknown",
            realm  = GetRealmName() or "",
            class  = select(2, UnitClass("player")) or "",
            race   = select(2, UnitRace("player")) or "",
            gender = UnitSex("player") or 0,
            level  = UnitLevel("player") or 0,
        },
        guild       = Capture.ScanGuild("player"),
        pet         = Capture.ScanPet("player"),
        gear        = Capture.ScanGear("player"),
        talents     = Capture.ScanTalents("player", false),
        glyphs      = Capture.ScanGlyphs(),
        honor       = Capture.ScanHonor(),
        arena_teams = Capture.ScanArenaTeams(),
        instance    = captureInstance(),
        captured_at = time(),
        source      = "local",
    }
    -- Verbose CI dump available via /chron inspect ci
    return ci
end

--- Build a CI struct for an inspected unit.
-- Call only after INSPECT_TALENT_READY has fired for this unit.
-- @param unit  string  "target", "raid5", etc.
-- @return table  The CI struct
function Capture.ScanUnit(unit, isInspect)
    unit = unit or "target"
    isInspect = (isInspect ~= false)  -- default true for non-player units

    local ci = {
        player = {
            guid   = UnitGUID(unit) or "",
            name   = UnitName(unit) or "Unknown",
            realm  = GetRealmName() or "",
            class  = select(2, UnitClass(unit)) or "",
            race   = select(2, UnitRace(unit)) or "",
            gender = UnitSex(unit) or 0,
            level  = UnitLevel(unit) or 0,
        },
        guild       = Capture.ScanGuild(unit),
        pet         = Capture.ScanPet(unit),
        gear        = Capture.ScanGear(unit),
        talents     = Capture.ScanTalents(unit, isInspect),
        -- Glyphs: only readable for "player" (no inspect API on 3.3.5a)
        glyphs      = nil,
        -- Honor: only readable for "player"
        honor       = nil,
        arena_teams = nil,
        instance    = captureInstance(),
        captured_at = time(),
        source      = "inspect",
    }

    -- Arena teams for inspected units (if API exists)
    if type(GetInspectArenaTeamData) == "function" then
        local teams = {}
        local any = false
        for _, bracket in ipairs(ARENA_BRACKETS) do
            local ok, name, _, rating, played, won, _, personalRating =
                pcall(GetInspectArenaTeamData, bracket)
            if ok and name then
                teams[bracket .. "v" .. bracket] = {
                    name            = name,
                    rating          = rating or 0,
                    played          = played or 0,
                    won             = won or 0,
                    personal_rating = personalRating or 0,
                }
                any = true
            end
        end
        if any then ci.arena_teams = teams end
    end

    -- Verbose CI dump available via /chron inspect ci
    return ci
end

-- ---------------------------------------------------------------------------
-- Slash command handler
--
-- Replaces the DispatchProbe's handler. Supports the old arm/disarm/log/probe
-- commands plus new nested "inspect" sub-commands.
--
-- Routing:
--   /chron inspect <sub> [unit]   ->  capture testing commands
--   /clog loglvl <level>          ->  set log level
--   /chron arm <text>             ->  DispatchProbe arm (if probe loaded)
--   /chron disarm                 ->  DispatchProbe disarm
--   /chron log                    ->  toggle combat logging
--   /chron probe                  ->  DispatchProbe global dump
--   /chron help                   ->  print help
-- ---------------------------------------------------------------------------

--- Parse a slash message into tokens.
-- "/chron inspect gear target" -> {"inspect", "gear", "target"}
local function tokenize(msg)
    local tokens = {}
    for token in (msg or ""):gmatch("%S+") do
        tokens[#tokens + 1] = token:lower()
    end
    return tokens
end

--- Resolve a unit token from user input (case-insensitive, accepts names).
-- "player" / "target" / "focus" / "raid5" / "party2" / etc.
-- If the input is a player name, try to find them in raid/party.
local function resolveUnit(input)
    if not input or input == "" then return "player" end

    -- Direct unit tokens that WoW recognises
    local direct = {
        player = true, target = true, focus = true, pet = true,
        mouseover = true, targettarget = true,
    }
    if direct[input] then return input end
    -- raidN / partyN patterns
    if input:match("^raid%d+$") or input:match("^party%d+$") then
        return input
    end

    -- Try to find by name in raid/party
    local numRaid = GetNumRaidMembers() or 0
    for i = 1, numRaid do
        local name = UnitName("raid" .. i)
        if name and name:lower() == input then
            return "raid" .. i
        end
    end
    local numParty = GetNumPartyMembers() or 0
    for i = 1, numParty do
        local name = UnitName("party" .. i)
        if name and name:lower() == input then
            return "party" .. i
        end
    end

    -- Fall back to the raw input -- WoW might accept it
    return input
end

--- Handle "/chron inspect ..." sub-commands.
local function handleInspect(tokens)
    -- tokens[1] = "inspect", tokens[2] = sub-command, tokens[3] = optional unit
    local sub = tokens[2]
    local unitInput = tokens[3]

    if not sub then
        Log:Info("Usage: /chron inspect <ui|gear|talents|glyphs|guild|pet|honor|arena|ci|probe> [unit]")
        return
    end

    if sub == "ui" then
        Chronicle.ToggleInspectUI()
        return
    end

    if sub == "gear" then
        local unit = resolveUnit(unitInput)
        local gear = Capture.ScanGear(unit)
        Log:Info("Gear for %s:", unit)
        Capture.PrintGear(gear)

    elseif sub == "talents" then
        local unit = resolveUnit(unitInput)
        local isInspect = (unit ~= "player")
        local talents = Capture.ScanTalents(unit, isInspect)
        Log:Info("Talents for %s (inspect=%s):", unit, tostring(isInspect))
        Capture.PrintTalents(talents)

    elseif sub == "glyphs" then
        local glyphs = Capture.ScanGlyphs()
        Log:Info("Glyphs (local player only):")
        Capture.PrintGlyphs(glyphs)

    elseif sub == "guild" then
        local unit = resolveUnit(unitInput)
        local guild = Capture.ScanGuild(unit)
        if guild then
            Log:Info("Guild for %s: <%s> rank: %s (index %d)",
                unit, guild.name, guild.rank_name, guild.rank_index)
        else
            Log:Info("Guild for %s: unguilded", unit)
        end

    elseif sub == "pet" then
        local unit = resolveUnit(unitInput)
        local pet = Capture.ScanPet(unit)
        if pet then
            Log:Info("Pet for %s: %s  GUID: %s  Family: %s",
                unit, pet.name, pet.guid, pet.family)
        else
            Log:Info("Pet for %s: none", unit)
        end

    elseif sub == "honor" then
        local honor = Capture.ScanHonor()
        Log:Info("Honor (local player):")
        Log:Info("  Lifetime HK: %d  |  Highest rank: %d", honor.lifetime_hk, honor.highest_rank)
        Log:Info("  Honor currency: %d  |  Session HK: %d", honor.honor_currency, honor.session_hk)

    elseif sub == "arena" then
        local teams = Capture.ScanArenaTeams()
        if teams then
            Log:Info("Arena teams (local player):")
            for bracket, t in pairs(teams) do
                Log:Info("  %s: %s  rating:%d  personal:%d  W/L: %d/%d",
                    bracket, t.name, t.rating, t.personal_rating, t.won, t.played - t.won)
            end
        else
            Log:Info("Arena teams: none (no API or no teams)")
        end

    elseif sub == "ci" then
        local unit = resolveUnit(unitInput)
        local ci
        if unit == "player" then
            ci = Capture.ScanLocal()
        else
            ci = Capture.ScanUnit(unit, true)
        end
        Log:DumpTable(ci, "Combatant Info (" .. unit .. ")")

    elseif sub == "probe" then
        local what = tokens[3]  -- "talents" or "glyphs"
        if what == "talents" then
            Capture.ProbeTalents()
        elseif what == "glyphs" then
            Capture.ProbeGlyphs()
        else
            Log:Info("Usage: /chron inspect probe <talents|glyphs>")
        end

    else
        Log:Info("Unknown inspect sub-command: '%s'", sub)
        Log:Info("Usage: /chron inspect <ui|gear|talents|glyphs|guild|pet|honor|arena|ci|probe> [unit]")
    end
end

-- ---------------------------------------------------------------------------
-- Main slash handler
-- ---------------------------------------------------------------------------

local function slashHandler(msg)
    local tokens = tokenize(msg)
    local cmd = tokens[1]

    if cmd == "help" then
        Log:Info("ChronicleCompanionWoTLK commands:")
        Log:Info("  /clog             -- open settings")
        Log:Info("  /chron inspect    -- inspect tools (ui, gear, talents, ...)")
        Log:Info("  /clog relay       -- relay status and controls")
        Log:Info("  /clog log         -- logger settings")
        Log:Info("Type a command alone for its sub-help.")
        return
    end

    if not cmd or cmd == "" then
        Chronicle.ToggleSettingsUI()
        return
    end

    -- ---- Nested inspect commands ----
    if cmd == "inspect" then
        handleInspect(tokens)
        return
    end

    -- ---- /clog log [set-lvl|set-window] ----
    if cmd == "log" then
        local sub = tokens[2]

        -- No sub-command: dump current state + sub-help
        if not sub then
            local frame = Log:GetChatFrame()
            local frameName = (frame and frame:GetName()) or "DEFAULT_CHAT_FRAME"
            Log:Info("Log level: %s  |  Output window: %s", Log:GetLevel(), frameName)
            Log:Info("  /clog log set-lvl <error|warn|info|debug>")
            Log:Info("  /clog log set-window <1-10|name>")
            return
        end

        if sub == "set-lvl" then
            local level = tokens[3]
            if level then
                Log:SetLevel(level)
                -- Persist to SavedVariables
                if Chronicle.Config then
                    Chronicle.Config:Set("log_level", level:lower())
                end
            else
                Log:Info("Current log level: %s", Log:GetLevel())
                Log:Info("Usage: /clog log set-lvl <error|warn|info|debug>")
            end
            return
        end

        if sub == "set-window" then
            local target = tokens[3]
            if not target then
                Log:Info("Usage: /clog log set-window <1-10|name>")
                Log:Info("  e.g. /clog log set-window 2       -- ChatFrame2")
                Log:Info("  e.g. /clog log set-window combat  -- first window whose name contains 'combat'")
                return
            end

            -- Try numeric index first (ChatFrame1 .. ChatFrame10)
            local idx = tonumber(target)
            if idx and idx >= 1 and idx <= 10 then
                local frame = _G["ChatFrame" .. idx]
                if frame then
                    Log:SetChatFrame(frame)
                    if Chronicle.Config then
                        Chronicle.Config:Set("log_window", idx)
                    end
                else
                    Log:Warn("ChatFrame%d does not exist", idx)
                end
                return
            end

            -- Try matching by tab name (case-insensitive substring)
            local needle = target:lower()
            for i = 1, 10 do
                local frame = _G["ChatFrame" .. i]
                if frame then
                    local name = (frame.name or frame:GetName() or ""):lower()
                    if name:find(needle, 1, true) then
                        Log:SetChatFrame(frame)
                        if Chronicle.Config then
                            Chronicle.Config:Set("log_window", i)
                        end
                        return
                    end
                end
            end
            Log:Warn("No chat window matching '%s' found (tried ChatFrame1-10)", target)
            return
        end

        -- Unknown log sub-command
        Log:Info("Usage: /clog log [set-lvl <level> | set-window <window>]")
        return
    end

    -- ---- DispatchProbe pass-through (arm / disarm / probe) ----
    -- These reference the DispatchProbe's functions via the Chronicle table
    -- or directly through the globals it set up.
    if cmd == "arm" then
        -- Reconstruct the rest of the message (everything after "arm ")
        local rest = (msg or ""):match("^%S+%s+(.+)$") or ""
        if Chronicle._probeArm then
            Chronicle._probeArm(rest)
        else
            Log:Warn("Dispatch probe not loaded -- arm unavailable")
        end
        return
    end

    if cmd == "disarm" then
        if Chronicle._probeDisarm then
            Chronicle._probeDisarm()
        else
            Log:Warn("Dispatch probe not loaded -- disarm unavailable")
        end
        return
    end

    if cmd == "probe" then
        if Chronicle._probeDump then
            Chronicle._probeDump()
        else
            Log:Warn("Dispatch probe not loaded -- probe unavailable")
        end
        return
    end

    -- ---- /clog relay [status|activate|deactivate|write|clear|pause|resume|ui] ----
    if cmd == "relay" then
        local sub = tokens[2]
        local Relay = Chronicle.Relay

        if not sub then
            -- Status summary
            if not Relay then
                Log:Warn("Relay module not loaded")
                return
            end
            local m = Relay:GetMetrics()
            local state = Relay:IsActive() and "ACTIVE" or "inactive"
            if Relay:IsPaused() then state = "PAUSED" end
            local landed, total = Relay:GetActiveProgress()
            local label = Relay:GetActiveLabel()
            Log:Info("Relay: %s", state)
            if label and label ~= "" then
                Log:Info("  Message: '%s'  chunk %d/%d", label, landed, total)
            else
                Log:Info("  Message: idle")
            end
            Log:Info("  Landed: %d  |  Missed: %d  |  Sent: %d  |  Polls: %d",
                m.chunks_landed, m.chunks_missed, m.messages_sent, m.provider_polls)
            Log:Info("  /clog relay <activate|deactivate|write|clear|pause|resume|ui>")
            return
        end

        if sub == "activate" then
            Relay:Activate()
            Log:Info("Relay force-activated")
            return
        end

        if sub == "deactivate" then
            Relay:Deactivate()
            Log:Info("Relay force-deactivated")
            return
        end

        if sub == "pause" then
            Relay:Pause()
            return
        end

        if sub == "resume" then
            Relay:Resume()
            return
        end

        if sub == "clear" then
            Relay:Deactivate()
            Relay:Activate()
            Log:Info("Relay: queue cleared (deactivated + reactivated)")
            return
        end

        if sub == "write" then
            -- Reconstruct everything after "relay write "
            local rest = (msg or ""):match("^%S+%s+%S+%s+(.+)$") or ""
            if rest == "" then
                Log:Info("Usage: /clog relay write <text>")
                return
            end
            Relay:InjectTest(rest)
            return
        end

        if sub == "ui" then
            if Chronicle.ToggleRelayUI then
                Chronicle.ToggleRelayUI()
            else
                Log:Warn("Relay UI not loaded")
            end
            return
        end

        Log:Info("Usage: /clog relay [status|activate|deactivate|write|clear|pause|resume|ui]")
        return
    end

    Log:Warn("Unknown command: '%s'. Try /chron help", cmd)
end

-- Expose handler so Init.lua can wire the slash commands after all files load.
Chronicle._slashHandler = slashHandler
