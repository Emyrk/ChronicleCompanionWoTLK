-- =============================================================================
-- UI/RelayUI.lua
--
-- Real-time relay monitor window.  Shows provider states, chunk progress,
-- throughput stats (per-minute buckets), and a live event feed.
--
-- Open via /clog relay ui
-- =============================================================================

local Log   = Chronicle.Logger
local Relay = Chronicle.Relay

-- ---------------------------------------------------------------------------
-- Dimensions & colors
-- ---------------------------------------------------------------------------

local FRAME_W       = 560
local FRAME_H       = 520
local INSET         = 10
local ROW_H         = 16
local SECTION_GAP   = 8

local C_TITLE  = { 0.31, 0.76, 1.0 }
local C_LABEL  = { 0.9,  0.9,  0.9 }
local C_DIM    = { 0.55, 0.55, 0.55 }
local C_GREEN  = { 0.27, 1.0,  0.27 }
local C_YELLOW = { 1.0,  0.82, 0.0  }
local C_RED    = { 1.0,  0.3,  0.3  }
local C_BLUE   = { 0.4,  0.7,  1.0  }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local mainFrame    = nil
local feedFrame    = nil   -- ScrollingMessageFrame for live events
local refreshTimer = 0
local REFRESH_SEC  = 0.5

-- Dynamic text widgets (populated in buildFrame)
local statusText     = nil
local messageText    = nil
local armedText      = nil
local providerRows   = {}  -- array of { label, dirty, lastEmit } FontStrings
local bucketRows     = {}  -- array of { min, landed, missed, errors } FontStrings
local footerText     = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function fmtTime(t)
    if not t or t == 0 then return "never" end
    return date("%H:%M:%S", t)
end

local function fmtAgo(t)
    if not t or t == 0 then return "n/a" end
    local ago = time() - t
    if ago < 1 then return "just now" end
    if ago < 60 then return ago .. "s ago" end
    return math.floor(ago / 60) .. "m ago"
end

local function colorForDirty(count)
    if count == 0 then return C_GREEN end
    if count <= 2 then return C_YELLOW end
    return C_RED
end

local function colorForBucket(landed, missed)
    if landed > missed then return C_GREEN end
    if landed > 0 then return C_YELLOW end
    if missed > 0 then return C_RED end
    return C_DIM
end

-- ---------------------------------------------------------------------------
-- Live feed (event-driven from Relay.onRelayEvent)
-- ---------------------------------------------------------------------------

local EVENT_COLORS = {
    LANDED      = C_GREEN,
    MISSED      = C_DIM,
    ARMED       = C_BLUE,
    POLL        = C_DIM,
    ACTIVATED   = C_GREEN,
    DEACTIVATED = C_YELLOW,
}

local function onRelayEvent(eventType, data)
    if not feedFrame then return end
    local c = EVENT_COLORS[eventType] or C_LABEL
    local ts = date("%H:%M:%S")
    local line = string.format("%s  %s: %s", ts, eventType, data or "")
    feedFrame:AddMessage(line, c[1], c[2], c[3])
end

-- ---------------------------------------------------------------------------
-- Refresh: update all dynamic text from Relay state
-- ---------------------------------------------------------------------------

local function refresh()
    if not mainFrame or not mainFrame:IsShown() then return end

    local m = Relay:GetMetrics()

    -- Status line
    local state = "INACTIVE"
    if Relay:IsActive() then state = "|cff44ff44ACTIVE|r" end
    if Relay:IsPaused() then state = "|cffffff00PAUSED|r" end
    local logging = LoggingCombat() and "|cff44ff44ON|r" or "|cffff4444OFF|r"
    local numGlobals = Chronicle.C and #Chronicle.C.HIJACK_GLOBALS or 0
    statusText:SetText(string.format("Status: %s    CombatLog: %s    Globals: %d    Last land: %s",
        state, logging, numGlobals, fmtAgo(m.last_land_at)))

    -- Active message
    local label = Relay:GetActiveLabel()
    local landed, total = Relay:GetActiveProgress()
    if label and label ~= "" then
        messageText:SetText(string.format("Message: \"%s\"  chunk %d/%d", label, landed, total))
    else
        messageText:SetText("Message: idle")
    end

    -- Armed chunk preview
    local armed = Relay:GetArmedChunk()
    if armed then
        local preview = armed
        if #preview > 80 then preview = preview:sub(1, 80) .. "..." end
        armedText:SetText("Armed: " .. preview)
    else
        armedText:SetText("Armed: (none)")
    end

    -- Provider rows
    local states = Relay:GetProviderStates()
    for i = 1, 8 do  -- max 8 providers displayed
        local row = providerRows[i]
        if not row then break end
        local s = states[i]
        if s then
            row.label:SetText(string.format("#%d %s", s.priority, s.label))
            row.label:Show()

            local dc = colorForDirty(s.dirty)
            row.dirty:SetText(string.format("dirty:%d", s.dirty))
            row.dirty:SetTextColor(dc[1], dc[2], dc[3])
            row.dirty:Show()

            row.lastEmit:SetText("emit: " .. fmtTime(s.lastEmitAt))
            row.lastEmit:Show()

            -- Details button: show if provider has CreateDebugFrame
            if s.provider and s.provider.CreateDebugFrame then
                if not row.detailBtn._debugFrame then
                    row.detailBtn._debugFrame = s.provider:CreateDebugFrame(mainFrame)
                    row.detailBtn._debugFrame:Hide()
                end
                row.detailBtn:Show()
            else
                row.detailBtn:Hide()
            end
        else
            row.label:Hide()
            row.dirty:Hide()
            row.lastEmit:Hide()
            row.detailBtn:Hide()
        end
    end

    -- Throughput buckets
    local bkts = Relay:GetBuckets()
    for i = 1, 10 do
        local row = bucketRows[i]
        if not row then break end
        local b = bkts[i]
        if b then
            row.min:SetText(b.minute_ago == 0 and "now" or ("-" .. b.minute_ago))
            local bc = colorForBucket(b.landed, b.missed)
            row.landed:SetText(tostring(b.landed))
            row.landed:SetTextColor(bc[1], bc[2], bc[3])
            row.missed:SetText(tostring(b.missed))
            row.missed:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
            row.errors:SetText(tostring(b.errors))
            row.errors:SetTextColor(b.errors > 0 and C_RED[1] or C_DIM[1],
                                     b.errors > 0 and C_RED[2] or C_DIM[2],
                                     b.errors > 0 and C_RED[3] or C_DIM[3])
        end
    end

    -- Footer totals
    footerText:SetText(string.format(
        "Totals:  Landed %d  |  Missed %d  |  Sent %d  |  Polls %d",
        m.chunks_landed, m.chunks_missed, m.messages_sent, m.provider_polls))
end

-- ---------------------------------------------------------------------------
-- Frame builder
-- ---------------------------------------------------------------------------

local function makeLabel(parent, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY",
        size == "small" and "GameFontHighlightSmall" or "GameFontNormal")
    fs:SetTextColor(r or C_LABEL[1], g or C_LABEL[2], b or C_LABEL[3])
    return fs
end

local function buildFrame()
    if mainFrame then return mainFrame end

    local f = CreateFrame("Frame", "ChronicleRelayUIFrame", UIParent)
    f:SetWidth(FRAME_W)
    f:SetHeight(FRAME_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 4, -10)
    title:SetText("Chronicle Relay Monitor")
    title:SetTextColor(C_TITLE[1], C_TITLE[2], C_TITLE[3])

    -- Close
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    -- Pause/Resume button
    local pauseBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    pauseBtn:SetWidth(80)
    pauseBtn:SetHeight(22)
    pauseBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    pauseBtn:SetText("Pause")
    pauseBtn:SetScript("OnClick", function()
        if Relay:IsPaused() then
            Relay:Resume()
            pauseBtn:SetText("Pause")
        else
            Relay:Pause()
            pauseBtn:SetText("Resume")
        end
    end)

    table.insert(UISpecialFrames, "ChronicleRelayUIFrame")

    -- ---- Section 1: Status ----
    local y = -36

    statusText = makeLabel(f, "normal")
    statusText:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 4, y)

    y = y - ROW_H - 2
    messageText = makeLabel(f, "small")
    messageText:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 4, y)

    y = y - ROW_H
    armedText = makeLabel(f, "small", C_DIM[1], C_DIM[2], C_DIM[3])
    armedText:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 4, y)

    -- ---- Section 2: Providers ----
    y = y - ROW_H - SECTION_GAP
    local provHdr = makeLabel(f, "normal", C_YELLOW[1], C_YELLOW[2], C_YELLOW[3])
    provHdr:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 4, y)
    provHdr:SetText("-- Providers --")

    for i = 1, 8 do
        y = y - ROW_H
        local row = {}
        row.label = makeLabel(f, "small")
        row.label:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 8, y)
        row.label:SetWidth(120)
        row.label:SetJustifyH("LEFT")

        row.dirty = makeLabel(f, "small")
        row.dirty:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
        row.dirty:SetWidth(60)

        row.lastEmit = makeLabel(f, "small", C_DIM[1], C_DIM[2], C_DIM[3])
        row.lastEmit:SetPoint("LEFT", row.dirty, "RIGHT", 8, 0)
        row.lastEmit:SetWidth(90)

        -- [Details] button (shown only if provider has CreateDebugFrame)
        local detailBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        detailBtn:SetWidth(50)
        detailBtn:SetHeight(ROW_H)
        detailBtn:SetPoint("LEFT", row.lastEmit, "RIGHT", 4, 0)
        detailBtn:SetText("Details")
        detailBtn:GetFontString():SetFont(detailBtn:GetFontString():GetFont(), 9)
        detailBtn:Hide()
        detailBtn._debugFrame = nil
        detailBtn:SetScript("OnClick", function(self)
            if self._debugFrame then
                if self._debugFrame:IsShown() then
                    self._debugFrame:Hide()
                else
                    self._debugFrame:ClearAllPoints()
                    self._debugFrame:SetPoint("TOPLEFT", f, "TOPRIGHT", 4, 0)
                    self._debugFrame:Show()
                end
            end
        end)
        row.detailBtn = detailBtn

        row.label:Hide()
        row.dirty:Hide()
        row.lastEmit:Hide()
        providerRows[i] = row
    end

    -- ---- Section 3: Throughput ----
    y = y - SECTION_GAP
    local thruHdr = makeLabel(f, "normal", C_YELLOW[1], C_YELLOW[2], C_YELLOW[3])
    thruHdr:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 4, y)
    thruHdr:SetText("-- Throughput (per minute) --")

    -- Column headers
    y = y - ROW_H
    local colMin = makeLabel(f, "small", C_DIM[1], C_DIM[2], C_DIM[3])
    colMin:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 8, y)
    colMin:SetText("Min")
    colMin:SetWidth(36)
    local colLand = makeLabel(f, "small", C_DIM[1], C_DIM[2], C_DIM[3])
    colLand:SetPoint("LEFT", colMin, "RIGHT", 4, 0)
    colLand:SetText("Land")
    colLand:SetWidth(40)
    local colMiss = makeLabel(f, "small", C_DIM[1], C_DIM[2], C_DIM[3])
    colMiss:SetPoint("LEFT", colLand, "RIGHT", 4, 0)
    colMiss:SetText("Miss")
    colMiss:SetWidth(40)
    local colErr = makeLabel(f, "small", C_DIM[1], C_DIM[2], C_DIM[3])
    colErr:SetPoint("LEFT", colMiss, "RIGHT", 4, 0)
    colErr:SetText("Err")
    colErr:SetWidth(36)

    for i = 1, 10 do
        y = y - ROW_H
        local row = {}
        row.min = makeLabel(f, "small", C_DIM[1], C_DIM[2], C_DIM[3])
        row.min:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + 8, y)
        row.min:SetWidth(36)
        row.min:SetJustifyH("RIGHT")

        row.landed = makeLabel(f, "small")
        row.landed:SetPoint("LEFT", row.min, "RIGHT", 4, 0)
        row.landed:SetWidth(40)
        row.landed:SetJustifyH("RIGHT")

        row.missed = makeLabel(f, "small")
        row.missed:SetPoint("LEFT", row.landed, "RIGHT", 4, 0)
        row.missed:SetWidth(40)
        row.missed:SetJustifyH("RIGHT")

        row.errors = makeLabel(f, "small")
        row.errors:SetPoint("LEFT", row.missed, "RIGHT", 4, 0)
        row.errors:SetWidth(36)
        row.errors:SetJustifyH("RIGHT")

        bucketRows[i] = row
    end

    -- ---- Section 4: Live Feed ----
    -- Positioned to the right of the throughput table, aligned with its header
    local feedX = 210

    local feedHdr = makeLabel(f, "normal", C_YELLOW[1], C_YELLOW[2], C_YELLOW[3])
    feedHdr:SetPoint("TOPLEFT", thruHdr, "TOPLEFT", feedX - INSET - 4, 0)
    feedHdr:SetText("-- Live Feed --")

    local feedBg = CreateFrame("Frame", nil, f)
    feedBg:SetPoint("TOPLEFT", feedHdr, "BOTTOMLEFT", -4, -4)
    feedBg:SetPoint("RIGHT", f, "RIGHT", -INSET, 0)
    feedBg:SetHeight(ROW_H * 11 + 8)
    feedBg:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    feedBg:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
    feedBg:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    local smf = CreateFrame("ScrollingMessageFrame", "ChronicleRelayFeed", feedBg)
    smf:SetPoint("TOPLEFT", feedBg, "TOPLEFT", 4, -4)
    smf:SetPoint("BOTTOMRIGHT", feedBg, "BOTTOMRIGHT", -4, 4)
    smf:SetFontObject(GameFontHighlightSmall)
    smf:SetJustifyH("LEFT")
    smf:SetMaxLines(100)
    smf:SetFading(false)
    smf:SetInsertMode("BOTTOM")
    smf:EnableMouseWheel(true)
    smf:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    feedFrame = smf

    -- ---- Footer ----
    footerText = makeLabel(f, "small", C_DIM[1], C_DIM[2], C_DIM[3])
    footerText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", INSET + 4, INSET + 2)
    footerText:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -INSET, INSET + 2)

    -- ---- OnUpdate refresh ----
    f:SetScript("OnUpdate", function(self, dt)
        refreshTimer = refreshTimer + dt
        if refreshTimer >= REFRESH_SEC then
            refreshTimer = 0
            refresh()
        end
    end)

    -- ---- Wire event hook on show/hide ----
    -- Also wire immediately on build in case Show() doesn't re-fire OnShow
    Relay.onRelayEvent = onRelayEvent

    f:SetScript("OnShow", function()
        Relay.onRelayEvent = onRelayEvent
        refreshTimer = 0
        refresh()
    end)
    f:SetScript("OnHide", function()
        Relay.onRelayEvent = nil
    end)

    mainFrame = f
    return f
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Toggle the relay monitor window.
function Chronicle.ToggleRelayUI()
    local firstBuild = (mainFrame == nil)
    local f = buildFrame()
    if firstBuild then
        f:Show()
    elseif f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

--- Show the relay monitor window.
function Chronicle.ShowRelayUI()
    buildFrame():Show()
end

--- Hide the relay monitor window.
function Chronicle.HideRelayUI()
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    end
end
