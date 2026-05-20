-- =============================================================================
-- UI/MinimapButton.lua
--
-- Minimap icon that shows recording state (On.tga / Off.tga).
-- Left-click: open settings.  Right-click: toggle combat logging.
-- Icon swaps based on LoggingCombat() + Relay active state.
--
-- No library dependencies -- pure frame API.
-- =============================================================================

local Log    = Chronicle.Logger
local Config = Chronicle.Config

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local ICON_ON  = "Interface\\AddOns\\ChronicleCompanionWoTLK\\textures\\On"
local ICON_OFF = "Interface\\AddOns\\ChronicleCompanionWoTLK\\textures\\Off"
local BUTTON_SIZE = 33
local DEFAULT_ANGLE = 225  -- degrees around the minimap (configurable)

-- ---------------------------------------------------------------------------
-- Button frame
-- ---------------------------------------------------------------------------

local button = CreateFrame("Button", "ChronicleMinimapButton", Minimap)
button:SetWidth(BUTTON_SIZE)
button:SetHeight(BUTTON_SIZE)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
button:EnableMouse(true)
button:SetMovable(true)
button:RegisterForClicks("anyUp")
button:RegisterForDrag("LeftButton")

-- Icon texture
local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetWidth(20)
icon:SetHeight(20)
icon:SetTexture(ICON_OFF)

-- Border overlay (standard minimap tracking button border)
-- The MiniMap-TrackingBorder texture is 54x54 but the circle is offset
-- to the top-left.  We offset the border so the circle centers on our icon.
local border = button:CreateTexture(nil, "OVERLAY")
border:SetWidth(54)
border:SetHeight(54)
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

-- Center both on the button with the border's known offset
-- The tracking border circle center is at roughly (11, -12) from its TOPLEFT
icon:SetPoint("CENTER", button, "CENTER", 0, 0)
border:SetPoint("CENTER", button, "CENTER", 11, -12)

-- ---------------------------------------------------------------------------
-- Positioning: place around the minimap rim by angle
-- ---------------------------------------------------------------------------

local function updatePosition(angle)
    local rad = math.rad(angle)
    local x = math.cos(rad) * 80
    local y = math.sin(rad) * 80
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- ---------------------------------------------------------------------------
-- Dragging around the minimap
-- ---------------------------------------------------------------------------

local isDragging = false

local function onUpdate()
    if not isDragging then return end
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    updatePosition(angle)
    -- Save angle
    if Config:IsReady() then
        Config:SetChar("minimap_angle", angle)
    end
end

button:SetScript("OnDragStart", function(self)
    isDragging = true
    self:SetScript("OnUpdate", onUpdate)
end)

button:SetScript("OnDragStop", function(self)
    isDragging = false
    self:SetScript("OnUpdate", nil)
end)

-- ---------------------------------------------------------------------------
-- Click handlers
-- ---------------------------------------------------------------------------

button:SetScript("OnClick", function(self, btn)
    if btn == "RightButton" then
        -- Toggle combat logging
        if LoggingCombat() then
            LoggingCombat(false)
            Log:Info("Combat logging OFF")
        else
            LoggingCombat(true)
            Log:Info("Combat logging ON")
        end
        -- Relay activates/deactivates based on LoggingCombat state
        if Chronicle.Relay then
            Chronicle.Relay:Reevaluate()
        end
    else
        -- Open settings
        Chronicle.ToggleSettingsUI()
    end
end)

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Chronicle Companion", 0.31, 0.76, 1.0)

    local logging = LoggingCombat()
    if logging then
        GameTooltip:AddLine("Combat Log: |cff44ff44ON|r", 1, 1, 1)
    else
        GameTooltip:AddLine("Combat Log: |cffff4444OFF|r", 1, 1, 1)
    end

    local Relay = Chronicle.Relay
    if Relay and Relay:IsActive() then
        GameTooltip:AddLine("Relay: |cff44ff44ACTIVE|r", 1, 1, 1)
    else
        GameTooltip:AddLine("Relay: |cffff4444INACTIVE|r", 1, 1, 1)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffffffLeft-click:|r Settings", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("|cffffffffRight-click:|r Toggle logging", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)

button:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- ---------------------------------------------------------------------------
-- Icon refresh: swap On/Off texture based on state
-- ---------------------------------------------------------------------------

local REFRESH_SEC = 1
local refreshTimer = 0

local refreshFrame = CreateFrame("Frame")
refreshFrame:SetScript("OnUpdate", function(self, dt)
    refreshTimer = refreshTimer + dt
    if refreshTimer < REFRESH_SEC then return end
    refreshTimer = 0

    local logging = LoggingCombat()
    local Relay = Chronicle.Relay
    local relayActive = Relay and Relay:IsActive()

    if logging or relayActive then
        icon:SetTexture(ICON_ON)
    else
        icon:SetTexture(ICON_OFF)
    end
end)

-- ---------------------------------------------------------------------------
-- Init: restore position from saved angle
-- ---------------------------------------------------------------------------

Chronicle.RegisterEvent("PLAYER_LOGIN", function()
    local angle = DEFAULT_ANGLE
    if Config:IsReady() then
        angle = Config:GetChar("minimap_angle") or DEFAULT_ANGLE
    end
    updatePosition(angle)
end)
