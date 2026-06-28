-- =============================================================================
-- UI/SettingsUI.lua
--
-- Main addon settings window.  Opened via /clog (no args).
--
-- Layout (two columns):
--
--  +-- ChronicleLog Options ---------------------- [X] +
--  |  Advanced combat logging settings                  |
--  |                                                    |
--  |  Logging: OFF  [Toggle]      Auto Combat Logger    |
--  |  Relay: ACTIVE               [x] Auto in Raids     |
--  |  Instance: No                [x] Auto in Dungeons   |
--  |                              [x] Auto Relay         |
--  |  Version Info                                      |
--  |  Addon: 0.1                Debug                   |
--  |  Build: 12340              Log Level               |
--  |                            [error][warn][info][debug]|
--  |                            Log Window              |
--  |                            [1][2][3]...[10]        |
--  |                                                    |
--  |                  [Reset Settings]                  |
--  +----------------------------------------------------+
-- =============================================================================

local Log    = Chronicle.Logger
local Config = Chronicle.Config

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

local FRAME_W = 460
local FRAME_H = 340
local INSET   = 14
local ROW_H   = 22
local BTN_H   = 22
local COL2_X  = 230  -- left edge of right column

-- ---------------------------------------------------------------------------
-- Colors
-- ---------------------------------------------------------------------------

local C_TITLE    = { 0.31, 0.76, 1.0 }
local C_SUBTITLE = { 0.7,  0.7,  0.7 }
local C_LABEL    = { 0.9,  0.9,  0.9 }
local C_ACTIVE   = { 0.27, 1.0,  0.27 }
local C_INACTIVE = { 1.0,  0.3,  0.3 }
local C_YELLOW   = { 1.0,  0.82, 0.0 }
local C_DIM      = { 0.55, 0.55, 0.55 }
local C_SECTION  = { 1.0,  0.82, 0.0 }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local mainFrame = nil
local levelButtons  = {}
local windowButtons = {}

-- Dynamic text widgets (refreshed on show + periodic)
local loggingText   = nil
local relayText     = nil
local instanceText  = nil
local versionText   = nil
local buildText     = nil
local checkboxes    = {}  -- key -> CheckButton

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

local function makeLabel(parent, size, r, g, b)
    local font = (size == "large") and "GameFontNormalLarge"
              or (size == "normal") and "GameFontNormal"
              or "GameFontHighlightSmall"
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    if r then fs:SetTextColor(r, g, b) end
    return fs
end

local function makeCheckbox(parent, label, configKey, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetWidth(24)
    cb:SetHeight(24)
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    text:SetText(label)
    text:SetTextColor(C_LABEL[1], C_LABEL[2], C_LABEL[3])
    cb._label = text
    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        Config:Set(configKey, checked)
        if onClick then onClick(checked) end
    end)
    checkboxes[configKey] = cb
    return cb
end

-- (dropdowns handle their own selection highlighting)

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

local function refresh()
    if not Config:IsReady() then return end

    -- Logging status
    local logging = LoggingCombat()
    if logging then
        loggingText:SetText("Logging: |cff44ff44ON|r")
    else
        loggingText:SetText("Logging: |cffff4444OFF|r")
    end

    -- Relay status
    local Relay = Chronicle.Relay
    if Relay then
        if Relay:IsActive() then
            relayText:SetText("Relay: |cff44ff44ACTIVE|r")
        else
            relayText:SetText("Relay: |cffff4444INACTIVE|r")
        end
    else
        relayText:SetText("Relay: N/A")
    end

    -- Instance
    local instName = ""
    local instType = "none"
    if type(GetInstanceInfo) == "function" then
        instName, instType = GetInstanceInfo()
    else
        local _, iType = IsInInstance()
        instType = iType or "none"
        instName = GetRealZoneText() or ""
    end
    instType = instType or "none"

    local TYPE_LABELS = {
        none  = "No",
        party = "Dungeon",
        raid  = "Raid",
        pvp   = "PvP",
        arena = "Arena",
    }
    local typeLabel = TYPE_LABELS[instType] or instType

    if instType ~= "none" then
        instanceText:SetText("Instance: |cff44ff44" .. typeLabel .. "|r")
    else
        instanceText:SetText("Instance: |cffff4444" .. typeLabel .. "|r")
    end

    -- Checkboxes
    for key, cb in pairs(checkboxes) do
        cb:SetChecked(Config:Get(key) and true or false)
    end

    -- Dropdowns
    if levelButtons._dropdown then
        UIDropDownMenu_SetSelectedValue(levelButtons._dropdown, Config:Get("log_level"))
    end
    if windowButtons._dropdown then
        UIDropDownMenu_SetSelectedValue(windowButtons._dropdown, Config:Get("log_window"))
    end
end

-- ---------------------------------------------------------------------------
-- Frame builder
-- ---------------------------------------------------------------------------

local function buildFrame()
    if mainFrame then return mainFrame end

    local f = CreateFrame("Frame", "ChronicleSettingsFrame", UIParent)
    f:SetWidth(FRAME_W)
    f:SetHeight(FRAME_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
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

    -- Title + subtitle
    local title = makeLabel(f, "large", C_TITLE[1], C_TITLE[2], C_TITLE[3])
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("ChronicleLog Options")

    local subtitle = makeLabel(f, "small", C_SUBTITLE[1], C_SUBTITLE[2], C_SUBTITLE[3])
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subtitle:SetText("Advanced combat logging settings")

    -- Close
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    table.insert(UISpecialFrames, "ChronicleSettingsFrame")

    -- =====================================================================
    -- LEFT COLUMN
    -- =====================================================================
    local y = -50

    -- Logging status + Toggle
    loggingText = makeLabel(f, "normal", C_LABEL[1], C_LABEL[2], C_LABEL[3])
    loggingText:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, y)

    local toggleBtn = makeButton(f, "Toggle", 60, function()
        if LoggingCombat() then
            LoggingCombat(false)
        else
            LoggingCombat(true)
        end
        if Chronicle.Relay then
            Chronicle.Relay:Reevaluate()
        end
        refresh()
    end)
    toggleBtn:SetPoint("LEFT", loggingText, "RIGHT", 8, 0)

    -- Relay status
    y = y - ROW_H - 4
    relayText = makeLabel(f, "normal", C_LABEL[1], C_LABEL[2], C_LABEL[3])
    relayText:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, y)

    -- Instance status
    y = y - ROW_H - 4
    instanceText = makeLabel(f, "normal", C_LABEL[1], C_LABEL[2], C_LABEL[3])
    instanceText:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, y)

    -- ---- Version Info section ----
    y = y - ROW_H - 12
    local verHdr = makeLabel(f, "normal", C_SECTION[1], C_SECTION[2], C_SECTION[3])
    verHdr:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, y)
    verHdr:SetText("Version Info")

    y = y - ROW_H
    local addonVer = GetAddOnMetadata(Chronicle.ADDON_NAME, "Version") or "?"
    versionText = makeLabel(f, "small", C_ACTIVE[1], C_ACTIVE[2], C_ACTIVE[3])
    versionText:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, y)
    versionText:SetText("Addon: " .. addonVer)

    y = y - ROW_H - 2
    local wowVer, wowBuild = "?", "?"
    if type(GetBuildInfo) == "function" then
        wowVer, wowBuild = GetBuildInfo()
    end
    buildText = makeLabel(f, "small", C_ACTIVE[1], C_ACTIVE[2], C_ACTIVE[3])
    buildText:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, y)
    buildText:SetText("Build: " .. tostring(wowBuild or "?"))

    -- =====================================================================
    -- RIGHT COLUMN
    -- =====================================================================
    local ry = -50

    -- ---- Auto Combat Logger section ----
    local autoHdr = makeLabel(f, "normal", C_SECTION[1], C_SECTION[2], C_SECTION[3])
    autoHdr:SetPoint("TOPLEFT", f, "TOPLEFT", COL2_X, ry)
    autoHdr:SetText("Automatic Combat Logger")

    ry = ry - ROW_H - 2
    local cbRaid = makeCheckbox(f, "Auto-enable in Raids", "auto_combatlog_raid")
    cbRaid:SetPoint("TOPLEFT", f, "TOPLEFT", COL2_X, ry)

    ry = ry - ROW_H - 2
    local cbDungeon = makeCheckbox(f, "Auto-enable in Dungeons", "auto_combatlog_dungeon")
    cbDungeon:SetPoint("TOPLEFT", f, "TOPLEFT", COL2_X, ry)

    -- ---- Debug section ----
    ry = ry - ROW_H - 12
    local dbgHdr = makeLabel(f, "normal", C_SECTION[1], C_SECTION[2], C_SECTION[3])
    dbgHdr:SetPoint("TOPLEFT", f, "TOPLEFT", COL2_X, ry)
    dbgHdr:SetText("Debug")

    -- Log Level dropdown
    ry = ry - ROW_H - 2
    local lvlLabel = makeLabel(f, "small", C_LABEL[1], C_LABEL[2], C_LABEL[3])
    lvlLabel:SetPoint("TOPLEFT", f, "TOPLEFT", COL2_X, ry)
    lvlLabel:SetText("Log Level:")

    local lvlDropdown = CreateFrame("Frame", "ChronicleLogLevelDropdown", f, "UIDropDownMenuTemplate")
    lvlDropdown:SetPoint("LEFT", lvlLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(lvlDropdown, 90)

    local levels = { "error", "warn", "info", "debug" }
    local function lvlDropdown_Init()
        for _, lvl in ipairs(levels) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = lvl
            info.value = lvl
            info.func = function(self)
                Config:Set("log_level", self.value)
                Log:SetLevel(self.value)
                UIDropDownMenu_SetSelectedValue(lvlDropdown, self.value)
            end
            info.checked = nil  -- handled by SetSelectedValue
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(lvlDropdown, lvlDropdown_Init)
    UIDropDownMenu_SetSelectedValue(lvlDropdown, Config:Get("log_level"))
    -- Store ref for refresh
    levelButtons._dropdown = lvlDropdown

    -- Log Window dropdown (shows chat frame names)
    ry = ry - ROW_H - 8
    local winLabel = makeLabel(f, "small", C_LABEL[1], C_LABEL[2], C_LABEL[3])
    winLabel:SetPoint("TOPLEFT", f, "TOPLEFT", COL2_X, ry)
    winLabel:SetText("Output:")

    local winDropdown = CreateFrame("Frame", "ChronicleLogWindowDropdown", f, "UIDropDownMenuTemplate")
    winDropdown:SetPoint("LEFT", winLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(winDropdown, 120)

    local function winDropdown_Init()
        for i = 1, 10 do
            local chatFrame = _G["ChatFrame" .. i]
            if chatFrame then
                -- GetChatWindowInfo returns: name, fontSize, r, g, b, a, shown, ...
                local name = GetChatWindowInfo(i) or ""
                if name == "" then name = "ChatFrame" .. i end
                local info = UIDropDownMenu_CreateInfo()
                info.text = i .. ": " .. name
                info.value = i
                info.func = function(self)
                    local frame = _G["ChatFrame" .. self.value]
                    if frame then
                        Config:Set("log_window", self.value)
                        Log:SetChatFrame(frame)
                        UIDropDownMenu_SetSelectedValue(winDropdown, self.value)
                    end
                end
                info.checked = nil
                UIDropDownMenu_AddButton(info)
            end
        end
    end
    UIDropDownMenu_Initialize(winDropdown, winDropdown_Init)
    UIDropDownMenu_SetSelectedValue(winDropdown, Config:Get("log_window"))
    windowButtons._dropdown = winDropdown

    -- =====================================================================
    -- Footer: Tool buttons + Reset
    -- =====================================================================
    local inspectBtn = makeButton(f, "Inspect Tool", 100, function()
        if Chronicle.ToggleInspectUI then
            Chronicle.ToggleInspectUI()
        end
    end)
    inspectBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", INSET, INSET)

    local relayBtn = makeButton(f, "Relay Monitor", 100, function()
        if Chronicle.ToggleRelayUI then
            Chronicle.ToggleRelayUI()
        end
    end)
    relayBtn:SetPoint("LEFT", inspectBtn, "RIGHT", 6, 0)

    local resetBtn = makeButton(f, "Reset Settings", 100, function()
        Config:ResetAll()
        Log:SetLevel(Config:Get("log_level"))
        local idx = Config:Get("log_window")
        local frame = _G["ChatFrame" .. (idx or 1)]
        if frame then Log:SetChatFrame(frame) end
        refresh()
        Log:Info("Settings reset to defaults")
    end)
    resetBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -INSET, INSET)

    -- Refresh on show + periodic (for logging/relay/instance status)
    f:SetScript("OnShow", function()
        refresh()
    end)
    local timer = 0
    f:SetScript("OnUpdate", function(self, dt)
        timer = timer + dt
        if timer >= 1 then
            timer = 0
            refresh()
        end
    end)

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
