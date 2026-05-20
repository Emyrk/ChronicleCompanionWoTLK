-- =============================================================================
-- UI/SettingsUI.lua
--
-- Main addon settings window.  Opened via /clog (no args).
--
-- Layout:
--   +-- Chronicle Settings --------------------- [X] +
--   |                                                 |
--   |  Log Level       [error] [warn] [info] [debug]  |
--   |                                                 |
--   |  Log Window      [ 1 ] [ 2 ] [ 3 ] ... [ 10 ]  |
--   |                                                 |
--   |                          [Reset to Defaults]    |
--   +-------------------------------------------------+
-- =============================================================================

local Log = Chronicle.Logger
local Config = Chronicle.Config

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

local FRAME_WIDTH  = 360
local FRAME_HEIGHT = 220
local INSET        = 14
local ROW_HEIGHT   = 30
local BTN_H        = 22

-- ---------------------------------------------------------------------------
-- Colors
-- ---------------------------------------------------------------------------

local C_TITLE    = { 0.31, 0.76, 1.0 }
local C_LABEL    = { 0.9, 0.9, 0.9 }
local C_ACTIVE   = { 0.27, 1.0, 0.27 }     -- green highlight for selected
local C_INACTIVE = { 0.4, 0.4, 0.4 }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local mainFrame = nil
local levelButtons = {}
local windowButtons = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function makeButton(parent, text, width, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetWidth(width)
    btn:SetHeight(BTN_H)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
end

--- Highlight the active button in a group, dim the rest.
local function highlightGroup(buttons, activeValue)
    for value, btn in pairs(buttons) do
        if value == activeValue then
            btn:GetFontString():SetTextColor(C_ACTIVE[1], C_ACTIVE[2], C_ACTIVE[3])
        else
            btn:GetFontString():SetTextColor(C_LABEL[1], C_LABEL[2], C_LABEL[3])
        end
    end
end

-- ---------------------------------------------------------------------------
-- Refresh: sync button highlights to current Config values
-- ---------------------------------------------------------------------------

local function refresh()
    if not Config:IsReady() then return end
    highlightGroup(levelButtons, Config:Get("log_level"))
    highlightGroup(windowButtons, Config:Get("log_window"))
end

-- ---------------------------------------------------------------------------
-- Frame builder
-- ---------------------------------------------------------------------------

local function buildFrame()
    if mainFrame then return mainFrame end

    local f = CreateFrame("Frame", "ChronicleSettingsFrame", UIParent)
    f:SetWidth(FRAME_WIDTH)
    f:SetHeight(FRAME_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 24,
        insets   = { left = 5, right = 5, top = 5, bottom = 5 },
    })

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, -12)
    title:SetText("Chronicle Settings")
    title:SetTextColor(C_TITLE[1], C_TITLE[2], C_TITLE[3])

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    -- ESC to close
    table.insert(UISpecialFrames, "ChronicleSettingsFrame")

    -- ---- Row 1: Log Level ----
    local rowY = -48

    local lvlLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lvlLabel:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, rowY)
    lvlLabel:SetText("Log Level")
    lvlLabel:SetTextColor(C_LABEL[1], C_LABEL[2], C_LABEL[3])

    local levels = { "error", "warn", "info", "debug" }
    local prevBtn = nil
    for _, lvl in ipairs(levels) do
        local btn = makeButton(f, lvl, 58, function()
            Config:Set("log_level", lvl)
            Log:SetLevel(lvl)
            highlightGroup(levelButtons, lvl)
        end)
        if not prevBtn then
            btn:SetPoint("LEFT", lvlLabel, "RIGHT", 12, 0)
        else
            btn:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
        end
        levelButtons[lvl] = btn
        prevBtn = btn
    end

    -- ---- Row 2: Log Window ----
    rowY = rowY - ROW_HEIGHT - 14

    local winLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    winLabel:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, rowY)
    winLabel:SetText("Log Window")
    winLabel:SetTextColor(C_LABEL[1], C_LABEL[2], C_LABEL[3])

    prevBtn = nil
    for i = 1, 10 do
        local idx = i
        local btn = makeButton(f, tostring(i), 26, function()
            local frame = _G["ChatFrame" .. idx]
            if frame then
                Config:Set("log_window", idx)
                Log:SetChatFrame(frame)
                highlightGroup(windowButtons, idx)
            else
                Log:Warn("ChatFrame%d does not exist", idx)
            end
        end)
        if not prevBtn then
            btn:SetPoint("LEFT", winLabel, "RIGHT", 12, 0)
        else
            btn:SetPoint("LEFT", prevBtn, "RIGHT", 2, 0)
        end
        windowButtons[idx] = btn
        prevBtn = btn
    end

    -- ---- Reset to Defaults button ----
    local resetBtn = makeButton(f, "Reset to Defaults", 130, function()
        Config:ResetAll()
        -- Re-apply
        Log:SetLevel(Config:Get("log_level"))
        local idx = Config:Get("log_window")
        local frame = _G["ChatFrame" .. (idx or 1)]
        if frame then Log:SetChatFrame(frame) end
        refresh()
        Log:Info("Settings reset to defaults")
    end)
    resetBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -INSET, INSET)

    -- Show handler: refresh highlights when frame opens
    f:SetScript("OnShow", function() refresh() end)

    mainFrame = f
    return f
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function Chronicle.ToggleSettingsUI()
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

function Chronicle.ShowSettingsUI()
    buildFrame():Show()
end

function Chronicle.HideSettingsUI()
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    end
end
