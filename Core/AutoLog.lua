-- =============================================================================
-- Core/AutoLog.lua
--
-- Automatically enables combat logging and activates the relay when the
-- player enters a raid or dungeon instance.  Deactivates when leaving.
--
-- Two independent config toggles:
--   auto_combatlog  (default true) -- auto-enable LoggingCombat()
--   auto_relay      (default true) -- auto-activate the smuggling relay
-- =============================================================================

local Log    = Chronicle.Logger
local Config = Chronicle.Config
local Relay  = Chronicle.Relay

--- Instance types that trigger auto-activation.
local INSTANCE_TYPES = {
    party = true,   -- 5-man dungeons
    raid  = true,   -- raids
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local wasInInstance = false   -- track transitions, not just current state

-- ---------------------------------------------------------------------------
-- Evaluate current zone and act
-- ---------------------------------------------------------------------------

--- Check the current zone and auto-enable combat logging / relay.
-- Called on zone change events and login.
local function evaluate()
    if not Config:IsReady() then return end

    local inInstance = false
    local instanceType = "none"
    local instanceName = ""

    if type(GetInstanceInfo) == "function" then
        instanceName, instanceType = GetInstanceInfo()
    else
        local _, iType = IsInInstance()
        instanceType = iType or "none"
        instanceName = GetRealZoneText() or ""
    end

    inInstance = INSTANCE_TYPES[instanceType] or false

    -- Entering an instance
    if inInstance and not wasInInstance then
        wasInInstance = true

        -- Auto combat logging (separate toggles for raid vs dungeon)
        local autoLog = false
        if instanceType == "raid" then
            autoLog = Config:Get("auto_combatlog_raid")
        elseif instanceType == "party" then
            autoLog = Config:Get("auto_combatlog_dungeon")
        end
        if autoLog then
            if not LoggingCombat() then
                LoggingCombat(true)
                Log:Info("Auto-enabled combat logging (%s - %s)", instanceName, instanceType)
            else
                Log:Debug("Entered %s (%s) - combat logging already on", instanceName, instanceType)
            end
        end

        -- Auto relay
        if Config:Get("auto_relay") then
            Relay:Activate()
            Log:Debug("Auto-activated relay for %s", instanceName)
        end

    -- Leaving an instance
    elseif not inInstance and wasInInstance then
        wasInInstance = false

        if Config:Get("auto_relay") then
            Relay:Deactivate()
        end

        Log:Info("Left instance (combat logging left on)")
    end
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

Chronicle.RegisterEvent("ZONE_CHANGED_NEW_AREA", evaluate)
Chronicle.RegisterEvent("PLAYER_ENTERING_WORLD", evaluate)

-- Also check on login in case we logged out inside an instance
Chronicle.RegisterEvent("PLAYER_LOGIN", function()
    -- Small delay to let Config hydrate and other modules init
    local f = CreateFrame("Frame")
    local elapsed = 0
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then
            self:SetScript("OnUpdate", nil)
            evaluate()
        end
    end)
end)
