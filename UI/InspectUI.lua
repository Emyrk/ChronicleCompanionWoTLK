-- =============================================================================
-- UI/InspectUI.lua
--
-- In-game inspect tool window.  Opened via /clog inspect ui.
-- Provides buttons for each capture function and dumps results into a
-- scrollable output pane -- no chat spam, easy to read during raids.
--
-- Layout:
--   -- Chronicle Inspect Tool ------------ [Clear] [X] -
--   -  Unit: [player         ] [> Target] [> Self]      -
--   -  ----------------------------------               -
--   -  - Gear -Talents - Glyphs - Guild -               -
--   -  ----------------------------------               -
--   -  - Pet  - Honor  - Arena  -Full CI-               -
--   -  ----------------------------------               -
--   -  ------------------------------------------------ -
--   -  - (scrollable output)                          - -
--   -  -                                              - -
--   -  ------------------------------------------------ -
--   -----------------------------------------------------
-- =============================================================================

local Log = Chronicle.Logger
local Capture = Chronicle.Capture

-- ---------------------------------------------------------------------------
-- Frame dimensions
-- ---------------------------------------------------------------------------

local FRAME_WIDTH   = 520
local FRAME_HEIGHT  = 460
local BUTTON_W      = 70
local BUTTON_H      = 24
local BUTTON_PAD    = 4
local OUTPUT_INSET  = 12

-- ---------------------------------------------------------------------------
-- Colour constants
-- ---------------------------------------------------------------------------

local C_TITLE    = { 0.31, 0.76, 1.0 }    -- Chronicle blue
local C_TEXT     = { 0.9,  0.9,  0.9 }     -- default output text
local C_LABEL    = { 1.0,  0.82, 0.0 }     -- gold label headers
local C_SLOT     = { 0.6,  0.8,  1.0 }     -- gear slot names
local C_DIM      = { 0.55, 0.55, 0.55 }    -- secondary / dim text
local C_WARN     = { 1.0,  1.0,  0.0 }     -- yellow warnings
local C_GREEN    = { 0.27, 1.0,  0.27 }    -- success / active marker
local C_ERROR    = { 1.0,  0.3,  0.3 }     -- red errors

-- ---------------------------------------------------------------------------
-- Output helpers -- write formatted lines to the scroll frame
-- ---------------------------------------------------------------------------

local outputFrame  -- forward ref, created in buildFrame()

local function out(text, r, g, b)
    if not outputFrame then return end
    outputFrame:AddMessage(text or "", r or C_TEXT[1], g or C_TEXT[2], b or C_TEXT[3])
end

local function outLabel(text)
    out(text, C_LABEL[1], C_LABEL[2], C_LABEL[3])
end

local function outDim(text)
    out(text, C_DIM[1], C_DIM[2], C_DIM[3])
end

-- ---------------------------------------------------------------------------
-- Slot labels (matches GearScan order)
-- ---------------------------------------------------------------------------

local SLOT_LABELS = {
    "Head", "Neck", "Shoulder", "Shirt", "Chest",
    "Waist", "Legs", "Feet", "Wrist", "Hands",
    "Finger1", "Finger2", "Trinket1", "Trinket2",
    "Back", "MainHand", "OffHand", "Ranged", "Tabard",
}

-- ---------------------------------------------------------------------------
-- Dump functions -- one per button, write into the output pane
-- ---------------------------------------------------------------------------

local function getUnit()
    -- Read from the unit editbox; created in buildFrame()
    if Chronicle._inspectUI_unitBox then
        local text = Chronicle._inspectUI_unitBox:GetText()
        if text and text ~= "" then return text end
    end
    return "player"
end

-- ---------------------------------------------------------------------------
-- Auto-inspect helper
--
-- For non-player units, fires NotifyInspect and waits for
-- INSPECT_TALENT_READY before running the callback.  For "player",
-- runs the callback immediately.
-- ---------------------------------------------------------------------------

local inspectFrame = CreateFrame("Frame")
local pendingCallback = nil
local pendingUnit     = nil   -- unit token of the in-flight inspect

local INSPECT_TIMEOUT = 3.0  -- seconds to wait for INSPECT_TALENT_READY

local function cancelPending(reason)
    if not pendingCallback then return end
    out("(cancelled: " .. (reason or "superseded") .. ")", C_DIM[1], C_DIM[2], C_DIM[3])
    pendingCallback = nil
    pendingUnit = nil
    inspectFrame:UnregisterEvent("INSPECT_TALENT_READY")
    inspectFrame:SetScript("OnUpdate", nil)
end

local function finishPending()
    inspectFrame:UnregisterEvent("INSPECT_TALENT_READY")
    inspectFrame:SetScript("OnUpdate", nil)
    if pendingCallback then
        local cb = pendingCallback
        pendingCallback = nil
        pendingUnit = nil
        local ok, err = pcall(cb)
        if not ok then
            out("ERROR: " .. tostring(err), C_ERROR[1], C_ERROR[2], C_ERROR[3])
        end
    end
end

inspectFrame:SetScript("OnEvent", function(self, event)
    if event == "INSPECT_TALENT_READY" then
        finishPending()
    end
end)

--- Run a callback, auto-inspecting the unit first if needed.
-- If an inspect is already in-flight, it is cancelled and replaced.
-- @param unit  string   unit token
-- @param fn    function callback to run after inspect data is ready
local function withInspect(unit, fn)
    -- Player data is always available
    if unit == "player" then
        fn()
        return
    end

    -- Check unit exists and is inspectable
    if not UnitExists(unit) then
        out("Unit '" .. unit .. "' does not exist", C_WARN[1], C_WARN[2], C_WARN[3])
        return
    end

    if not UnitIsVisible(unit) then
        out("Unit '" .. unit .. "' is not visible (too far)", C_WARN[1], C_WARN[2], C_WARN[3])
        return
    end

    if not CanInspect(unit) then
        out("Cannot inspect '" .. unit .. "'", C_WARN[1], C_WARN[2], C_WARN[3])
        return
    end

    -- If there's already an in-flight inspect, cancel it
    if pendingCallback then
        cancelPending("new request for " .. (UnitName(unit) or unit))
    end

    out("Inspecting " .. (UnitName(unit) or unit) .. " ...", C_DIM[1], C_DIM[2], C_DIM[3])

    -- Set up the new pending request
    pendingCallback = fn
    pendingUnit = unit
    inspectFrame:RegisterEvent("INSPECT_TALENT_READY")
    NotifyInspect(unit)

    -- Timeout: if INSPECT_TALENT_READY never fires, run anyway with partial data
    local elapsed = 0
    inspectFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= INSPECT_TIMEOUT then
            if pendingCallback then
                out("(inspect timed out -- running with partial data)", C_WARN[1], C_WARN[2], C_WARN[3])
            end
            finishPending()
        end
    end)
end

local function dumpGear()
    local unit = getUnit()
    withInspect(unit, function()
        outLabel("-- Gear: " .. unit .. " --")
        local gear = Capture.ScanGear(unit)
        if not gear or not next(gear) then
            out("  No gear data (empty or unit not available)", C_WARN[1], C_WARN[2], C_WARN[3])
            return
        end
        for i = 1, 19 do
            local g = gear[i]
            if g then
                local gems = table.concat(g.gems, ", ")
                local extra = ""
                if g.vanity_item_id then
                    extra = "  |  vanity: " .. g.vanity_item_id
                end
                local encStr = g.enchant > 0 and tostring(g.enchant) or "none"
                out(string.format("  [%2d] %-10s %s", i, SLOT_LABELS[i] or "?", g.raw or ""),
                    C_SLOT[1], C_SLOT[2], C_SLOT[3])
                outDim(string.format("       id:%-6d  enc:%-5s  gems:[%s]  sfx:%d%s",
                    g.item_id, encStr, gems, g.suffix, extra))
            end
        end
    end)
end

local function dumpTalents()
    local unit = getUnit()
    withInspect(unit, function()
        local isInspect = (unit ~= "player")
        outLabel("-- Talents: " .. unit .. " --")
        local talents = Capture.ScanTalents(unit, isInspect)
        if not talents then
            out("  No talent data (buffer race or unavailable)", C_WARN[1], C_WARN[2], C_WARN[3])
            return
        end
        out(string.format("  Active group: %d  |  Total groups: %d",
            talents.active_group, talents.num_groups))
        for g = 1, talents.num_groups do
            local group = talents.groups[g]
            if group then
                local marker = (g == talents.active_group) and " (active)" or ""
                out(string.format("  Group %d%s:", g, marker), C_GREEN[1], C_GREEN[2], C_GREEN[3])
                for t = 1, #group.tabs do
                    local tab = group.tabs[t]
                    out(string.format("    %s: %d pts", tab.name, tab.points))
                end
                outDim("    rank_string: " .. group.rank_string)
            else
                outDim(string.format("  Group %d: <unavailable>", g))
            end
        end
    end)
end

local function dumpGlyphs()
    outLabel("-- Glyphs (local player) --")
    local glyphs = Capture.ScanGlyphs()
    if not glyphs then
        out("  No glyph data", C_WARN[1], C_WARN[2], C_WARN[3])
        return
    end
    out(string.format("  Active group: %d  |  Inactive spec readable: %s",
        glyphs.active_group, tostring(glyphs.inactive_spec_available)))
    for g, group in pairs(glyphs.groups) do
        local marker = (g == glyphs.active_group) and " (active)" or ""
        out(string.format("  Group %d%s:", g, marker), C_GREEN[1], C_GREEN[2], C_GREEN[3])
        out("    Major:")
        for i, e in ipairs(group.major) do
            local status = e.enabled and "filled" or "empty"
            if e.spell_id > 0 then
                local name = GetSpellInfo(e.spell_id)
                out(string.format("      [%d] %s (spell %d)", i, name or "?", e.spell_id))
            else
                outDim(string.format("      [%d] (%s)", i, status))
            end
        end
        out("    Minor:")
        for i, e in ipairs(group.minor) do
            if e.spell_id > 0 then
                local name = GetSpellInfo(e.spell_id)
                out(string.format("      [%d] %s (spell %d)", i, name or "?", e.spell_id))
            else
                outDim(string.format("      [%d] (empty)", i))
            end
        end
    end
end

local function dumpGuild()
    local unit = getUnit()
    outLabel("-- Guild: " .. unit .. " --")
    local guild = Capture.ScanGuild(unit)
    if guild then
        out(string.format("  <%s>  rank: %s  (index %d)", guild.name, guild.rank_name, guild.rank_index))
    else
        outDim("  Unguilded")
    end
end

local function dumpPet()
    local unit = getUnit()
    outLabel("-- Pet: " .. unit .. " --")
    local pet = Capture.ScanPet(unit)
    if pet then
        out(string.format("  Name: %s", pet.name))
        out(string.format("  GUID: %s", pet.guid))
        out(string.format("  Family: %s", pet.family))
    else
        outDim("  No pet active")
    end
end

local function dumpHonor()
    outLabel("-- Honor (local player) --")
    local honor = Capture.ScanHonor()
    out(string.format("  Lifetime HK: %d  |  Highest rank: %d", honor.lifetime_hk, honor.highest_rank))
    out(string.format("  Honor currency: %d  |  Session HK: %d", honor.honor_currency, honor.session_hk))
end

local function dumpArena()
    outLabel("-- Arena Teams (local player) --")
    local teams = Capture.ScanArenaTeams()
    if not teams then
        outDim("  No arena teams (no API or no teams)")
        return
    end
    for bracket, t in pairs(teams) do
        out(string.format("  %s: %s", bracket, t.name), C_GREEN[1], C_GREEN[2], C_GREEN[3])
        outDim(string.format("    rating: %d  |  personal: %d  |  W: %d  L: %d",
            t.rating, t.personal_rating, t.won, t.played - t.won))
    end
end

local function dumpFullCI()
    local unit = getUnit()
    withInspect(unit, function()
        outLabel("-- Full CI: " .. unit .. " --")
        local ci
        if unit == "player" then
            ci = Capture.ScanLocal()
        else
            ci = Capture.ScanUnit(unit, true)
        end
        if not ci then
            out("  Failed to build CI", C_ERROR[1], C_ERROR[2], C_ERROR[3])
            return
        end

        -- Player identity
        out(string.format("  %s  %s %s %s  lv%d",
            ci.player.name, ci.player.race, ci.player.class,
            (ci.player.gender == 2 and "M" or ci.player.gender == 3 and "F" or "?"),
            ci.player.level), C_GREEN[1], C_GREEN[2], C_GREEN[3])
        outDim("  GUID: " .. ci.player.guid)
        outDim("  Realm: " .. ci.player.realm)

        -- Summary counts
        local gearCount = 0
        if ci.gear then
            for _ in pairs(ci.gear) do gearCount = gearCount + 1 end
        end
        local talentStr = "none"
        if ci.talents and ci.talents.groups[ci.talents.active_group] then
            talentStr = ci.talents.groups[ci.talents.active_group].rank_string
        end
        out(string.format("  Gear slots filled: %d/19", gearCount))
        out(string.format("  Talents: %s", talentStr))

        if ci.guild then
            out(string.format("  Guild: <%s> %s", ci.guild.name, ci.guild.rank_name))
        end
        if ci.pet then
            out(string.format("  Pet: %s (%s)", ci.pet.name, ci.pet.family))
        end
        if ci.instance then
            out(string.format("  Instance: %s (%s %s)",
                ci.instance.name, ci.instance.difficulty_name, ci.instance.instance_type))
        end
        out(string.format("  Source: %s  |  Captured at: %s", ci.source, date("%H:%M:%S", ci.captured_at)))
    end)
end

-- ---------------------------------------------------------------------------
-- Button definitions: { label, callback }
-- ---------------------------------------------------------------------------

local BUTTONS_ROW1 = {
    { "Gear",    dumpGear },
    { "Talents", dumpTalents },
    { "Glyphs",  dumpGlyphs },
    { "Guild",   dumpGuild },
}

local BUTTONS_ROW2 = {
    { "Pet",     dumpPet },
    { "Honor",   dumpHonor },
    { "Arena",   dumpArena },
    { "Full CI", dumpFullCI },
}

-- ---------------------------------------------------------------------------
-- Frame builder
-- ---------------------------------------------------------------------------

local mainFrame = nil  -- singleton

local function createButton(parent, label, onClick, width)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetWidth(width or BUTTON_W)
    btn:SetHeight(BUTTON_H)
    btn:SetText(label)
    btn:SetScript("OnClick", function()
        local ok, err = pcall(onClick)
        if not ok then
            out("ERROR: " .. tostring(err), C_ERROR[1], C_ERROR[2], C_ERROR[3])
        end
    end)
    return btn
end

local function buildFrame()
    if mainFrame then return mainFrame end

    -- ---- Main frame ----
    local f = CreateFrame("Frame", "ChronicleInspectToolFrame", UIParent)
    f:SetWidth(FRAME_WIDTH)
    f:SetHeight(FRAME_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")

    -- Backdrop
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 24,
        insets   = { left = 5, right = 5, top = 5, bottom = 5 },
    })

    -- Dragging
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- ---- Title bar ----
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    title:SetText("Chronicle Inspect Tool")
    title:SetTextColor(C_TITLE[1], C_TITLE[2], C_TITLE[3])

    -- ---- Close button ----
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    -- ---- Clear button ----
    local clearBtn = createButton(f, "Clear", function()
        if outputFrame then outputFrame:Clear() end
    end, 50)
    clearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)

    -- ---- Unit editbox ----
    local unitLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    unitLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -38)
    unitLabel:SetText("Unit:")

    local unitBox = CreateFrame("EditBox", "ChronicleInspectUnitBox", f, "InputBoxTemplate")
    unitBox:SetWidth(130)
    unitBox:SetHeight(20)
    unitBox:SetPoint("LEFT", unitLabel, "RIGHT", 8, 0)
    unitBox:SetAutoFocus(false)
    unitBox:SetText("target")
    unitBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    unitBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    Chronicle._inspectUI_unitBox = unitBox

    -- Quick-set buttons: Target and Self
    local targetBtn = createButton(f, "> Target", function()
        unitBox:SetText("target")
    end, 65)
    targetBtn:SetPoint("LEFT", unitBox, "RIGHT", 6, 0)

    local selfBtn = createButton(f, "> Self", function()
        unitBox:SetText("player")
    end, 55)
    selfBtn:SetPoint("LEFT", targetBtn, "RIGHT", BUTTON_PAD, 0)

    local focusBtn = createButton(f, "> Focus", function()
        unitBox:SetText("focus")
    end, 58)
    focusBtn:SetPoint("LEFT", selfBtn, "RIGHT", BUTTON_PAD, 0)

    -- ---- Scan buttons -- row 1 ----
    local btnRowY = -64
    local prevBtn = nil
    for i, def in ipairs(BUTTONS_ROW1) do
        local btn = createButton(f, def[1], def[2], BUTTON_W)
        if i == 1 then
            btn:SetPoint("TOPLEFT", f, "TOPLEFT", OUTPUT_INSET, btnRowY)
        else
            btn:SetPoint("LEFT", prevBtn, "RIGHT", BUTTON_PAD, 0)
        end
        prevBtn = btn
    end

    -- ---- Scan buttons -- row 2 ----
    btnRowY = btnRowY - (BUTTON_H + BUTTON_PAD)
    prevBtn = nil
    for i, def in ipairs(BUTTONS_ROW2) do
        local btn = createButton(f, def[1], def[2], BUTTON_W)
        if i == 1 then
            btn:SetPoint("TOPLEFT", f, "TOPLEFT", OUTPUT_INSET, btnRowY)
        else
            btn:SetPoint("LEFT", prevBtn, "RIGHT", BUTTON_PAD, 0)
        end
        prevBtn = btn
    end

    -- ---- Scrolling output pane ----
    local outputTop = btnRowY - BUTTON_H - 10

    -- Scroll frame container
    local scrollBg = CreateFrame("Frame", nil, f)
    scrollBg:SetPoint("TOPLEFT", f, "TOPLEFT", OUTPUT_INSET, outputTop)
    scrollBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -OUTPUT_INSET, OUTPUT_INSET)
    scrollBg:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    scrollBg:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
    scrollBg:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    -- ScrollingMessageFrame -- behaves like a chat window
    local smf = CreateFrame("ScrollingMessageFrame", "ChronicleInspectOutput", scrollBg)
    smf:SetPoint("TOPLEFT", scrollBg, "TOPLEFT", 6, -6)
    smf:SetPoint("BOTTOMRIGHT", scrollBg, "BOTTOMRIGHT", -22, 6)
    smf:SetFontObject(GameFontHighlightSmall)
    smf:SetJustifyH("LEFT")
    smf:SetMaxLines(500)
    smf:SetFading(false)
    smf:SetInsertMode("BOTTOM")
    smf:EnableMouseWheel(true)
    smf:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)
    smf:SetHyperlinksEnabled(true)
    smf:SetScript("OnHyperlinkClick", function(self, link, text, button)
        -- Allow clicking item links in the output
        SetItemRef(link, text, button)
    end)
    smf:SetScript("OnHyperlinkEnter", function(self, link)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    smf:SetScript("OnHyperlinkLeave", function()
        GameTooltip:Hide()
    end)

    outputFrame = smf

    -- ScrollingMessageFrame handles its own scrolling via mouse wheel.
    -- No manual scrollbar needed (UIPanelScrollBarTemplate expects a
    -- ScrollFrame parent, which we don't have).

    -- ESC to close
    table.insert(UISpecialFrames, "ChronicleInspectToolFrame")

    mainFrame = f
    return f
end

-- ---------------------------------------------------------------------------
-- Public API: toggle the inspect tool
-- ---------------------------------------------------------------------------

function Chronicle.ToggleInspectUI()
    local firstBuild = (mainFrame == nil)
    local f = buildFrame()
    if firstBuild then
        -- First open: always show (frame starts hidden after creation)
        f:Show()
    elseif f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

function Chronicle.ShowInspectUI()
    local f = buildFrame()
    f:Show()
end

function Chronicle.HideInspectUI()
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    end
end
