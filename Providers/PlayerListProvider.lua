-- =============================================================================
-- Providers/PlayerListProvider.lua
--
-- Tracks party/raid members and emits per-player CI segments through the
-- relay.  Each player has independent segment tracking (gear, talents,
-- glyphs, etc.) with per-segment priority, cooldown, and dirty state.
--
-- Poll() snapshots the data at call time and returns ONE segment for ONE
-- player -- the most urgent segment for the most urgent player.
--
-- Priority 3 (after Zone and Header).
-- =============================================================================

local Log     = Chronicle.Logger
local Relay   = Chronicle.Relay
local Capture = Chronicle.Capture
local Format  = Chronicle.CIFormat
local Util    = Chronicle.Util

local P = {
    priority = 3,
}

-- ---------------------------------------------------------------------------
-- Segment definitions: key, priority, cooldown, formatter, self-only flag
-- Lower priority number = emitted first within a player.
-- ---------------------------------------------------------------------------

local SEGMENT_DEFS = {
    { key = "I", priority = 1, cooldown = 1800, selfOnly = false  },  -- Identity, 30 min
    { key = "G", priority = 2, cooldown = 1800,  selfOnly = false }, -- Gear, 30 min
    { key = "T", priority = 3, cooldown = 300,  selfOnly = false  },  -- Talents, 5 min
    { key = "Y", priority = 4, cooldown = 7200,  selfOnly = true  }, -- Glyphs, 2 hours
    { key = "U", priority = 5, cooldown = 3600, selfOnly = false  },  -- Guild, 1 hr
    { key = "E", priority = 6, cooldown = 600,  selfOnly = false  },  -- Pet, 10 min
    { key = "H", priority = 7, cooldown = 7200, selfOnly = true   },  -- Honor, 60 min
    { key = "A", priority = 8, cooldown = 7200, selfOnly = true   },  -- Arena, 60 min
}

-- Lookup for fast access
local SEG_BY_KEY = {}
for _, def in ipairs(SEGMENT_DEFS) do
    SEG_BY_KEY[def.key] = def
end

-- ---------------------------------------------------------------------------
-- Player state
-- ---------------------------------------------------------------------------

local players = {}       -- guid -> player state table
local selfGuid = nil     -- cached UnitGUID("player")

--- Create a fresh player entry.
-- @tparam string guid player GUID
-- @tparam string unit unit token ("player", "raid5", etc.)
-- @tparam boolean isSelf true for the local player
-- @treturn table player state
local function newPlayer(guid, unit, isSelf)
    local entry = {
        guid   = guid,
        unit   = unit,
        isSelf = isSelf,
        segs   = {},
    }
    for _, def in ipairs(SEGMENT_DEFS) do
        -- Peers don't get self-only segments
        if not def.selfOnly or isSelf then
            entry.segs[def.key] = {
                dirty      = true,
                lastEmitAt = 0,
                cooldown   = def.cooldown,
            }
        end
    end
    return entry
end

-- ---------------------------------------------------------------------------
-- Segment dirty helpers
-- ---------------------------------------------------------------------------

--- Check if a segment is due for emit (dirty or past cooldown).
local function segmentIsDue(seg)
    if not seg then return false end
    if seg.dirty then return true end
    if (time() - seg.lastEmitAt) >= seg.cooldown then return true end
    return false
end

--- Mark a specific segment dirty for a player.
-- @tparam string guid player GUID
-- @tparam string key segment key (I, G, T, etc.)
-- @tparam string reason why this segment is being marked dirty
local function markSegDirty(guid, key, reason)
    local pl = players[guid]
    if not pl then return end
    local seg = pl.segs[key]
    if seg and not seg.dirty then
        seg.dirty = true
        local name = (pl.unit and UnitName(pl.unit)) or guid
        Log:Debug("PlayerList: %s.%s dirty (%s)", name, key, reason or "?")
    end
end

--- Mark a specific segment dirty for ALL tracked players.
local function markAllSegDirty(key)
    for _, pl in pairs(players) do
        local seg = pl.segs[key]
        if seg then seg.dirty = true end
    end
end

--- Mark all segments dirty for a single player.
-- @tparam string guid player GUID
-- @tparam string reason why all segments are being dirtied
local function markPlayerAllDirty(guid, reason)
    local pl = players[guid]
    if not pl then return end
    for key, seg in pairs(pl.segs) do
        if not seg.dirty then
            seg.dirty = true
        end
    end
    local name = (pl.unit and UnitName(pl.unit)) or guid
    Log:Debug("PlayerList: %s ALL dirty (%s)", name, reason or "?")
end

-- ---------------------------------------------------------------------------
-- Inspect management for peers
--
-- Before we can read a peer's gear/talents we need NotifyInspect().
-- We track which peers have been inspected recently and throttle requests.
-- ---------------------------------------------------------------------------

local lastInspectAt   = 0       -- time() of last NotifyInspect call
local lastInspectGuid = nil     -- GUID of the peer we last called NotifyInspect on
local INSPECT_THROTTLE = 1.5    -- seconds between inspect requests
local inspectedGuids  = {}      -- guid -> time() of last successful inspect
local INSPECT_CACHE_SEC = 120   -- consider inspect data fresh for 2 min
local lastKnownSpec   = {}      -- guid -> last seen GetActiveTalentGroup result

-- ---------------------------------------------------------------------------
-- Segment formatters: capture + format at Poll time
--
-- Each returns a formatted segment string or nil.
-- For peers, we read from the inspect buffer (must be populated).
-- ---------------------------------------------------------------------------

local function formatSegment(pl, key)
    local unit = pl.unit
    local isSelf = pl.isSelf

    if key == "I" then
        -- Identity: lightweight, always available for visible units
        local ci = { player = {
            name   = UnitName(unit) or "",
            class  = select(2, UnitClass(unit)) or "",
            race   = select(2, UnitRace(unit)) or "",
            gender = UnitSex(unit) or 0,
            level  = UnitLevel(unit) or 0,
        }}
        return Format.Identity(ci)

    elseif key == "G" then
        local gear = Capture.ScanGear(unit)
        return Format.Gear(gear)

    elseif key == "T" then
        local isInspect = not isSelf
        local talents = Capture.ScanTalents(unit, isInspect)
        if not talents and isInspect then
            -- Buffer race -- invalidate cache so we re-inspect next Poll
            inspectedGuids[pl.guid] = nil
        end
        return Format.Talents(talents)

    elseif key == "Y" then
        -- Glyphs: self only (no inspect API on 3.3.5a)
        if not isSelf then return nil end
        local glyphs = Capture.ScanGlyphs()
        return Format.Glyphs(glyphs)

    elseif key == "U" then
        local guild = Capture.ScanGuild(unit)
        return Format.Guild(guild)

    elseif key == "E" then
        local pet = Capture.ScanPet(unit)
        return Format.Pet(pet)

    elseif key == "H" then
        if not isSelf then return nil end
        local honor = Capture.ScanHonor()
        return Format.Honor(honor)

    elseif key == "A" then
        if not isSelf then return nil end
        local arena = Capture.ScanArenaTeams()
        return Format.Arena(arena)
    end

    return nil
end

--- Check if a peer's active talent group changed since we last saw it.
-- If it did, mark their talents (and glyphs) dirty.
-- @tparam string guid player GUID
local function checkSpecChange(guid)
    if not guid or not players[guid] or players[guid].isSelf then return end
    if type(GetActiveTalentGroup) ~= "function" then return end

    -- GetActiveTalentGroup(true) reads the inspect buffer's active group
    local ok, currentSpec = pcall(GetActiveTalentGroup, true)
    if not ok or not currentSpec then return end

    local prev = lastKnownSpec[guid]
    lastKnownSpec[guid] = currentSpec

    if prev and prev ~= currentSpec then
        local name = UnitName(players[guid].unit) or guid
        Log:Debug("PlayerList: %s spec changed %d -> %d", name, prev, currentSpec)
        markSegDirty(guid, "T", "spec change detected")
        markSegDirty(guid, "G", "spec change detected")
    end
end

--- Check if we can read a peer's inspect buffer (gear/talents).
-- @tparam table pl player entry
-- @treturn boolean true if inspect data is available or not needed
local function hasInspectData(pl)
    if pl.isSelf then return true end
    local lastInsp = inspectedGuids[pl.guid]
    if lastInsp and (time() - lastInsp) < INSPECT_CACHE_SEC then
        return true
    end
    return false
end

--- Check if a peer is in range and inspectable.
-- @tparam table pl player entry
-- @treturn boolean
local function canInspectPeer(pl)
    if pl.isSelf then return true end
    local unit = pl.unit
    if not unit then return false end
    if not UnitExists(unit) then return false end
    if not UnitIsVisible(unit) then return false end
    if not UnitIsConnected(unit) then return false end
    if type(CanInspect) == "function" and not CanInspect(unit) then return false end
    if type(CheckInteractDistance) == "function" and not CheckInteractDistance(unit, 4) then
        return false
    end
    return true
end

--- Try to fire NotifyInspect for a peer if throttle allows.
-- @tparam table pl player entry
-- @treturn boolean true if inspect was fired (data will arrive async)
local function tryInspect(pl)
    if pl.isSelf then return false end
    local now = GetTime()
    if (now - lastInspectAt) < INSPECT_THROTTLE then return false end
    if not canInspectPeer(pl) then return false end

    lastInspectAt = now
    lastInspectGuid = pl.guid
    NotifyInspect(pl.unit)
    Log:Debug("PlayerList: inspecting %s (%s)", UnitName(pl.unit) or "?", pl.unit)
    return true
end

-- ---------------------------------------------------------------------------
-- Provider interface
-- ---------------------------------------------------------------------------

--- @treturn string provider label
function P:Label()
    return "PlayerList"
end

--- Return count of dirty segments across reachable players only.
-- Out-of-range peers are excluded since we can't serve them anyway.
-- @treturn number dirty segment count
function P:Dirty()
    local count = 0
    for _, pl in pairs(players) do
        -- Skip unreachable peers
        if pl.isSelf or canInspectPeer(pl) then
            for _, seg in pairs(pl.segs) do
                if segmentIsDue(seg) then
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- Poll for the next segment to emit.
-- Walks players (self first, then peers sorted by oldest emit),
-- then walks segments by priority within each player.
-- Snapshots the data at call time.
-- @treturn string|nil formatted wire message, or nil if nothing to send
function P:Poll()
    if not selfGuid then return nil end

    -- Build ordered player list: self first, then peers
    local ordered = {}
    local selfEntry = players[selfGuid]
    if selfEntry then
        ordered[1] = selfEntry
    end
    -- Collect peers sorted by priority:
    --   1. Just-inspected peers (fresh data waiting to be emitted)
    --   2. Then by oldest segment emit (most stale first)
    local peers = {}
    local now = time()
    for guid, pl in pairs(players) do
        if guid ~= selfGuid then
            peers[#peers + 1] = pl
        end
    end
    table.sort(peers, function(a, b)
        -- Just-inspected peers go first (fresh data within last 5 seconds)
        local aFresh = inspectedGuids[a.guid] and (now - inspectedGuids[a.guid]) < 5
        local bFresh = inspectedGuids[b.guid] and (now - inspectedGuids[b.guid]) < 5
        if aFresh ~= bFresh then return aFresh end

        -- Otherwise sort by oldest segment emit (most stale first)
        local aOldest, bOldest = now, now
        for _, seg in pairs(a.segs) do
            if seg.lastEmitAt < aOldest then aOldest = seg.lastEmitAt end
        end
        for _, seg in pairs(b.segs) do
            if seg.lastEmitAt < bOldest then bOldest = seg.lastEmitAt end
        end
        return aOldest < bOldest
    end)
    for _, pl in ipairs(peers) do
        ordered[#ordered + 1] = pl
    end

    -- Walk players, then segments by priority
    for _, pl in ipairs(ordered) do
        -- For peers, check if they're in range
        if not pl.isSelf and not canInspectPeer(pl) then
            -- Skip this peer entirely -- too far away
        else
            for _, def in ipairs(SEGMENT_DEFS) do
                local seg = pl.segs[def.key]
                if seg and segmentIsDue(seg) then
                    -- Log why this segment is due
                    if not seg.dirty and seg.lastEmitAt > 0 then
                        local name = UnitName(pl.unit) or pl.guid
                        Log:Debug("PlayerList: %s.%s due (cooldown expired, age=%ds, cd=%ds)",
                            name, def.key, time() - seg.lastEmitAt, seg.cooldown)
                    end
                    -- For peers: segments needing inspect data (G, T)
                    -- require fresh inspect buffer
                    local needsInspect = (not pl.isSelf) and (def.key == "G" or def.key == "T")
                    if needsInspect and not hasInspectData(pl) then
                        -- Try to fire inspect, skip this segment for now
                        tryInspect(pl)
                    else
                        -- Snapshot + format
                        local segment = formatSegment(pl, def.key)
                        if not segment then
                            -- Nothing to emit (e.g. no pet, no arena teams).
                            -- Mark clean so we don't keep retrying every Poll.
                            seg.dirty = false
                            seg.lastEmitAt = time()
                        else
                            seg.dirty = false
                            seg.lastEmitAt = time()
                            local msg = Format.Wrap(pl.guid, segment)
                            local name = UnitName(pl.unit) or pl.guid
                            local summary = string.format("CI %s:%s", name, def.key)
                            return msg, summary
                        end
                    end
                end
            end
        end
    end

    return nil
end

--- Return current state for UI/debug.
-- @treturn table { players = { guid -> { unit, isSelf, segs } }, selfGuid }
function P:GetState()
    return {
        players  = players,
        selfGuid = selfGuid,
    }
end

-- ---------------------------------------------------------------------------
-- Debug frame: compact table with colored segment indicators
--
-- Layout per player row:
--   Name       Unit    [I][G][T][Y][U][E][H][A]   Last emit
--
-- Segment colors: green=clean, yellow=dirty, red=stale (past 2x cooldown)
-- Hover a segment letter to see details (cooldown remaining, last emit)
-- ---------------------------------------------------------------------------

local SEG_KEYS_ORDERED = { "I", "G", "T", "Y", "U", "E", "H", "A" }

local C_GREEN  = { 0.27, 1.0,  0.27 }
local C_YELLOW = { 1.0,  0.82, 0.0  }
local C_RED    = { 1.0,  0.3,  0.3  }
local C_DIM    = { 0.35, 0.35, 0.35 }
local C_LABEL  = { 0.9,  0.9,  0.9  }
local C_TITLE  = { 0.31, 0.76, 1.0  }

local debugFrame = nil
local debugRows  = {}     -- array of row widget tables
local MAX_DEBUG_ROWS = 26 -- 25-man + self
local REFRESH_SEC = 0.5

local function segColor(seg)
    if not seg then return C_DIM end
    if seg.dirty then return C_YELLOW end
    local age = time() - seg.lastEmitAt
    if seg.lastEmitAt == 0 then return C_YELLOW end  -- never emitted
    if age >= seg.cooldown * 2 then return C_RED end  -- very stale
    if age >= seg.cooldown then return C_YELLOW end   -- due for re-emit
    return C_GREEN
end

local function fmtTime(t)
    if not t or t == 0 then return "never" end
    return date("%H:%M:%S", t)
end

local function buildDebugRow(parent, yOffset)
    local row = {}

    row.name = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, yOffset)
    row.name:SetWidth(90)
    row.name:SetJustifyH("LEFT")

    row.unit = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.unit:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
    row.unit:SetWidth(50)
    row.unit:SetJustifyH("LEFT")
    row.unit:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    -- Segment indicators: one FontString per segment key
    row.segs = {}
    local prevAnchor = row.unit
    for _, key in ipairs(SEG_KEYS_ORDERED) do
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", prevAnchor, "RIGHT", 3, 0)
        fs:SetWidth(14)
        fs:SetJustifyH("CENTER")
        fs:SetText(key)
        row.segs[key] = fs
        prevAnchor = fs
    end

    row.lastEmit = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.lastEmit:SetPoint("LEFT", prevAnchor, "RIGHT", 8, 0)
    row.lastEmit:SetWidth(70)
    row.lastEmit:SetJustifyH("LEFT")
    row.lastEmit:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    return row
end

local function refreshDebug()
    if not debugFrame or not debugFrame:IsShown() then return end

    -- Build ordered list: self first, then peers alphabetically
    local ordered = {}
    for _, pl in pairs(players) do
        ordered[#ordered + 1] = pl
    end
    table.sort(ordered, function(a, b)
        if a.isSelf ~= b.isSelf then return a.isSelf end
        local nameA = UnitName(a.unit) or ""
        local nameB = UnitName(b.unit) or ""
        return nameA < nameB
    end)

    for i = 1, MAX_DEBUG_ROWS do
        local row = debugRows[i]
        if not row then break end
        local pl = ordered[i]
        if pl then
            local name = UnitName(pl.unit) or "?"
            if pl.isSelf then name = name .. " *" end
            row.name:SetText(name)
            row.name:SetTextColor(C_LABEL[1], C_LABEL[2], C_LABEL[3])
            row.name:Show()

            row.unit:SetText(pl.unit or "")
            row.unit:Show()

            -- Segment indicators
            local oldestEmit = time()
            for _, key in ipairs(SEG_KEYS_ORDERED) do
                local seg = pl.segs[key]
                local fs = row.segs[key]
                if seg then
                    local c = segColor(seg)
                    fs:SetTextColor(c[1], c[2], c[3])
                    fs:Show()
                    if seg.lastEmitAt > 0 and seg.lastEmitAt < oldestEmit then
                        oldestEmit = seg.lastEmitAt
                    end
                else
                    -- Self-only segment on a peer: dim dash
                    fs:SetText("-")
                    fs:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
                    fs:Show()
                end
            end

            row.lastEmit:SetText(fmtTime(oldestEmit ~= time() and oldestEmit or 0))
            row.lastEmit:Show()
        else
            row.name:Hide()
            row.unit:Hide()
            for _, key in ipairs(SEG_KEYS_ORDERED) do
                row.segs[key]:Hide()
            end
            row.lastEmit:Hide()
        end
    end
end

--- Create the debug frame for embedding in the Relay UI.
-- @tparam Frame parent  the parent frame to attach to
-- @treturn Frame the debug frame
function P:CreateDebugFrame(parent)
    if debugFrame then return debugFrame end

    local f = CreateFrame("Frame", "ChroniclePlayerListDebug", parent or UIParent)
    f:SetWidth(480)
    f:SetHeight(20 + MAX_DEBUG_ROWS * 14 + 10)
    f:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    f:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
    title:SetText("PlayerList Debug")
    title:SetTextColor(C_TITLE[1], C_TITLE[2], C_TITLE[3])

    -- Player count
    local countText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    countText:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    -- Column headers
    local hdrY = -22
    local hdrName = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hdrName:SetPoint("TOPLEFT", f, "TOPLEFT", 8, hdrY)
    hdrName:SetWidth(90)
    hdrName:SetJustifyH("LEFT")
    hdrName:SetText("Name")
    hdrName:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    local hdrUnit = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hdrUnit:SetPoint("LEFT", hdrName, "RIGHT", 4, 0)
    hdrUnit:SetWidth(50)
    hdrUnit:SetText("Unit")
    hdrUnit:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    -- Segment header letters
    local prevAnchor = hdrUnit
    for _, key in ipairs(SEG_KEYS_ORDERED) do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", prevAnchor, "RIGHT", 3, 0)
        fs:SetWidth(14)
        fs:SetJustifyH("CENTER")
        fs:SetText(key)
        fs:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
        prevAnchor = fs
    end

    local hdrEmit = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hdrEmit:SetPoint("LEFT", prevAnchor, "RIGHT", 8, 0)
    hdrEmit:SetText("Emit")
    hdrEmit:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    -- Player rows
    local rowY = hdrY - 14
    for i = 1, MAX_DEBUG_ROWS do
        debugRows[i] = buildDebugRow(f, rowY)
        rowY = rowY - 14
    end

    -- Refresh timer
    local timer = 0
    f:SetScript("OnUpdate", function(self, dt)
        timer = timer + dt
        if timer >= REFRESH_SEC then
            timer = 0
            -- Update player count
            local n = 0
            for _ in pairs(players) do n = n + 1 end
            countText:SetText(n .. " players")
            refreshDebug()
        end
    end)

    debugFrame = f
    return f
end

-- ---------------------------------------------------------------------------
-- Roster management
-- ---------------------------------------------------------------------------

--- Refresh the tracked player list from the current party/raid roster.
-- @treturn table list of newly-added GUIDs (already fully dirty via newPlayer)
-- @treturn table list of removed GUIDs (no longer tracked)
local function refreshRoster()
    selfGuid = UnitGUID("player")
    if not selfGuid then return {}, {} end

    local seen = {}
    local added, removed = {}, {}

    -- Always track self
    if not players[selfGuid] then
        players[selfGuid] = newPlayer(selfGuid, "player", true)
        added[#added + 1] = selfGuid
        Log:Debug("PlayerList: tracking self %s", selfGuid)
    else
        players[selfGuid].unit = "player"
    end
    seen[selfGuid] = true

    -- Raid members
    local numRaid = GetNumRaidMembers() or 0
    for i = 1, numRaid do
        local unit = "raid" .. i
        local guid = UnitGUID(unit)
        if guid and guid ~= selfGuid then
            seen[guid] = true
            if not players[guid] then
                players[guid] = newPlayer(guid, unit, false)
                added[#added + 1] = guid
                Log:Debug("PlayerList: tracking %s (%s)", UnitName(unit) or "?", unit)
            else
                players[guid].unit = unit
            end
        end
    end

    -- Party members (only if not in raid)
    if numRaid == 0 then
        local numParty = GetNumPartyMembers() or 0
        for i = 1, numParty do
            local unit = "party" .. i
            local guid = UnitGUID(unit)
            if guid and guid ~= selfGuid then
                seen[guid] = true
                if not players[guid] then
                    players[guid] = newPlayer(guid, unit, false)
                    added[#added + 1] = guid
                    Log:Debug("PlayerList: tracking %s (%s)", UnitName(unit) or "?", unit)
                else
                    players[guid].unit = unit
                end
            end
        end
    end

    -- Remove players no longer in roster
    for guid in pairs(players) do
        if not seen[guid] then
            Log:Debug("PlayerList: removing %s (left group)", guid)
            players[guid] = nil
            removed[#removed + 1] = guid
        end
    end

    return added, removed
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

-- Self gear changed
Chronicle.RegisterEvent("UNIT_INVENTORY_CHANGED", function(event, unit)
    if unit == "player" and selfGuid then
        markSegDirty(selfGuid, "G", "UNIT_INVENTORY_CHANGED")
        Relay:Kick()
        return
    end
    -- Peer gear changed: invalidate their inspect cache so we re-inspect
    local guid = UnitGUID(unit)
    if guid and players[guid] and not players[guid].isSelf then
        inspectedGuids[guid] = nil  -- wipe cache, forces re-inspect on next Poll
        checkSpecChange(guid)       -- also check if they swapped specs
        markSegDirty(guid, "G", "UNIT_INVENTORY_CHANGED (peer)")
        Relay:Kick()
    end
end)

-- Self talents changed
Chronicle.RegisterEvent("PLAYER_TALENT_UPDATE", function()
    if selfGuid then
        markSegDirty(selfGuid, "T", "PLAYER_TALENT_UPDATE")
        Relay:Kick()
    end
end)

-- Self spec swapped
local function onSpecChange()
    if selfGuid then
        markSegDirty(selfGuid, "T", "ACTIVE_TALENT_GROUP_CHANGED")
        markSegDirty(selfGuid, "Y", "ACTIVE_TALENT_GROUP_CHANGED")
        markSegDirty(selfGuid, "G", "ACTIVE_TALENT_GROUP_CHANGED")
        Relay:Kick()
    end
end
Chronicle.RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", onSpecChange)

-- Glyph changed
Chronicle.RegisterEvent("GLYPH_UPDATED", function()
    if selfGuid then
        markSegDirty(selfGuid, "Y", "GLYPH_UPDATED")
        Relay:Kick()
    end
end)

-- Pet changed
Chronicle.RegisterEvent("UNIT_PET", function(event, unit)
    if unit == "player" and selfGuid then
        markSegDirty(selfGuid, "E", "UNIT_PET")
        Relay:Kick()
    end
end)

-- Guild changed
Chronicle.RegisterEvent("PLAYER_GUILD_UPDATE", function()
    if selfGuid then
        markSegDirty(selfGuid, "U", "PLAYER_GUILD_UPDATE")
        Relay:Kick()
    end
end)

-- Inspect data arrived for a peer
-- WoW 3.3.5a doesn't tell us WHICH player the inspect is for.
-- We only mark the peer we most recently called NotifyInspect on.
-- Track that via lastInspectGuid (declared near other inspect state above).

-- When inspect data arrives, just mark the cache fresh and kick.
-- The provider's next Poll() will find this player has data and emit it.
-- No need to explicitly dirty segments -- having fresh inspect data
-- means Poll() can now serve this player's G/T/I segments.
Chronicle.RegisterEvent("INSPECT_TALENT_READY", function()
    if lastInspectGuid and players[lastInspectGuid] then
        inspectedGuids[lastInspectGuid] = time()
        checkSpecChange(lastInspectGuid)
        local name = UnitName(players[lastInspectGuid].unit) or lastInspectGuid
        Log:Debug("PlayerList: inspect data ready for %s", name)
    end
    lastInspectGuid = nil
    Relay:Kick()
end)

-- Roster changed: refresh the tracked list and only react to real composition
-- changes. RAID_ROSTER_UPDATE / PARTY_MEMBERS_CHANGED fire for assist/loot/
-- ready-check toggles too, so blanket-dirtying every player here would re-emit
-- the entire raid's CI on every flag flip. Newly-added players are already
-- fully dirty via newPlayer(); existing players keep their segment state and
-- rely on per-segment cooldowns for periodic refresh.
local function onRosterChanged()
    local added, removed = refreshRoster()
    if (added and #added > 0) or (removed and #removed > 0) then
        Log:Debug("PlayerList: roster delta +%d -%d", #added, #removed)
        Relay:Kick()
    end
end
-- 3.3.5a roster events (GROUP_ROSTER_UPDATE does not exist on this client)
Chronicle.RegisterEvent("RAID_ROSTER_UPDATE", onRosterChanged)
Chronicle.RegisterEvent("PARTY_MEMBERS_CHANGED", onRosterChanged)

-- Login: initialize
Chronicle.RegisterEvent("PLAYER_LOGIN", function()
    selfGuid = UnitGUID("player")
    refreshRoster()
end)

-- Entering world (zone transitions, reloads)
Chronicle.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    selfGuid = UnitGUID("player")
    refreshRoster()
end)

-- ---------------------------------------------------------------------------
-- Register with Relay
-- ---------------------------------------------------------------------------

Relay:RegisterProvider(P)
Chronicle.PlayerListProvider = P
