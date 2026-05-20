-- =============================================================================
-- Init.lua
--
-- LAST file in the TOC.  Registers slash commands, prints the boot message,
-- and acts as the safety net.  This file has ZERO hard dependencies on any
-- other Chronicle module -- if Namespace.lua itself errored (Chronicle == nil),
-- Init.lua still creates the global, registers the slashes, and tells the
-- user something went wrong.
-- =============================================================================

local ADDON_NAME = "ChronicleCompanionWoTLK"

-- Ensure the global exists even if Namespace.lua failed
Chronicle = Chronicle or {}

-- ---------------------------------------------------------------------------
-- Slash commands -- always registered, regardless of module health
-- ---------------------------------------------------------------------------

local function fallbackHandler(msg)
    local frame = DEFAULT_CHAT_FRAME
    if not frame then return end
    frame:AddMessage("|cffff0000[Chronicle]|r Addon failed to load fully. Check for Lua errors (/console scriptErrors 1).")
end

SLASH_CHRONICLE1 = "/chron"
SLASH_CHRONICLE2 = "/chronicle"
SLASH_CHRONICLE3 = "/clog"
SlashCmdList["CHRONICLE"] = Chronicle._slashHandler or fallbackHandler

-- ---------------------------------------------------------------------------
-- Boot message on PLAYER_LOGIN (chat frames are guaranteed ready)
--
-- Use our own event frame here -- Chronicle.RegisterEvent may not exist
-- if Namespace.lua failed to load.
-- ---------------------------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")

local bootVersion = nil

initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        bootVersion = GetAddOnMetadata(ADDON_NAME, "Version") or "?"

    elseif event == "PLAYER_LOGIN" then
        self:UnregisterAllEvents()

        local version = bootVersion or GetAddOnMetadata(ADDON_NAME, "Version") or "?"
        local Log = Chronicle.Logger

        if Log then
            Log:Info("v%s loaded  --  /chron help", version)
        else
            local frame = DEFAULT_CHAT_FRAME
            if frame then
                frame:AddMessage("|cff4ec3ff[Chronicle]|r v" .. version ..
                    " loaded (Logger unavailable -- check for Lua errors)")
            end
        end
    end
end)
