-- =============================================================================
-- ChronicleCompanionWoTLK -- DispatchProbe
--
-- Smallest possible end-to-end test of the smuggling channel.
--
-- Theory: WoW's combat-log writer emits SPELL_CAST_FAILED rows where the
-- "fail reason" field is the *current value* of the localized SPELL_FAILED_*
-- global the engine picked for that error. If we overwrite that global with
-- arbitrary text right before triggering a guaranteed failure, our text lands
-- verbatim in WoWCombatLog.txt.
--
-- This file does only that, with zero abstraction. Once /chron arm + a real
-- spell failure writes a recognizable line to the log on 3.3.5a, we know the
-- channel is real and we can start building Transport/ on top of it.
--
-- Note: we cannot synthesize a cast failure from Lua on 3.3.5a -- CastSpellByName
-- is protected and may only run from a hardware event. So this probe operates
-- passively: /chron arm <text> overwrites the globals, then YOU produce any
-- spell failure naturally (cast something out of range, on a bad target, on
-- cooldown, etc.). The next SPELL_CAST_FAILED row should carry your text.
-- =============================================================================

Chronicle = Chronicle or {}

local ADDON_NAME = "ChronicleCompanionWoTLK"

-- We don't know in advance which SPELL_FAILED_* global the engine will pick
-- for our trigger, so we hijack a broad set. "Invalid target" on 3.3.5a comes
-- from SPELL_FAILED_BAD_TARGETS / BAD_IMPLICIT_TARGETS; keep those at the top.
local HIJACK_GLOBALS = {
    "SPELL_FAILED_BAD_TARGETS",
    "SPELL_FAILED_BAD_IMPLICIT_TARGETS",
    "SPELL_FAILED_TARGET_FRIENDLY",
    "SPELL_FAILED_TARGET_ENEMY",
    "SPELL_FAILED_INVALID_TARGET",
    "SPELL_FAILED_NO_TARGETS",
    "SPELL_FAILED_TARGETS_DEAD",
    "SPELL_FAILED_OUT_OF_RANGE",
    "SPELL_FAILED_LINE_OF_SIGHT",
    "SPELL_FAILED_UNIT_NOT_INFRONT",
    "SPELL_FAILED_UNKNOWN_SPELL",
    "SPELL_FAILED_SPELL_UNAVAILABLE",
    "SPELL_FAILED_NOT_READY",
    "SPELL_FAILED_NO_SPELL",
    "SPELL_FAILED_ERROR",
    "SPELL_FAILED_TRY_AGAIN",
    "SPELL_FAILED_MOVING",                   -- "Can't do that while moving"
    "SPELL_FAILED_INTERRUPTED",
    "SPELL_FAILED_INTERRUPTED_COMBAT",
    "SPELL_FAILED_SILENCED",
    "SPELL_FAILED_STUNNED",
    "SPELL_FAILED_AFFECTING_COMBAT",
    "SPELL_FAILED_ITEM_NOT_READY",
    "SPELL_FAILED_TOO_CLOSE",
    "SPELL_FAILED_NOT_BEHIND",
    "SPELL_FAILED_NOT_INFRONT",
    "SPELL_FAILED_CASTER_DEAD",
    "SPELL_FAILED_CASTER_AURASTATE",
}

local originals = {}      -- captured once at PLAYER_LOGIN
local captured = false
local activePayload = nil -- non-nil while a probe is armed (globals overwritten)

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff4ec3ff[Chronicle]|r " .. tostring(msg))
end

local function captureOriginals()
    if captured then return end
    for _, name in ipairs(HIJACK_GLOBALS) do
        originals[name] = _G[name]
    end
    captured = true
end

local function applyPayload(text)
    for _, name in ipairs(HIJACK_GLOBALS) do
        _G[name] = text
    end
end

local function restoreOriginals()
    for _, name in ipairs(HIJACK_GLOBALS) do
        _G[name] = originals[name]
    end
end

-- ---------------------------------------------------------------------------
-- UIErrorsFrame suppression
--
-- Without this the user sees our payload flash across the red error overlay
-- (because the engine ALSO routes SPELL_FAILED_* strings to UIErrorsFrame).
-- We hook AddMessage and drop anything that matches our active payload.
-- ---------------------------------------------------------------------------

local originalUIError = UIErrorsFrame.AddMessage
UIErrorsFrame.AddMessage = function(self, msg, ...)
    -- While armed, EVERY spell-failure red-text would render as our payload.
    -- Swallow all messages equal to the active payload.
    if activePayload and msg == activePayload then
        return
    end
    return originalUIError(self, msg, ...)
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- /chron arm <text>  -- overwrite globals and leave them overwritten.
-- /chron disarm      -- restore originals.
-- The next real SPELL_CAST_FAILED you produce (cast while moving, on
-- cooldown, out of range, bad target, etc.) will carry <text> as its
-- fail-reason field in WoWCombatLog.txt.

local function arm(text)
    if not text or text == "" then
        Print("usage: /chron arm <text>")
        return
    end
    captureOriginals()
    activePayload = text
    applyPayload(text)
    Print("armed. Payload: \"" .. text .. "\". Now cause any spell failure.")
end

local function disarm()
    if activePayload == nil then
        Print("not armed.")
        return
    end
    restoreOriginals()
    activePayload = nil
    Print("disarmed; originals restored.")
end

local function probeDump()
    for _, name in ipairs(HIJACK_GLOBALS) do
        Print(name .. " = " .. tostring(_G[name]))
    end
end

-- Export probe functions so LocalScan.lua's slash handler can pass through.
Chronicle._probeArm    = arm
Chronicle._probeDisarm = disarm
Chronicle._probeDump   = probeDump

-- ---------------------------------------------------------------------------
-- Combat-log echo: confirm our payload actually landed
--
-- We listen for SPELL_CAST_FAILED on the player and print the failedType arg.
-- On a real "landed" event this will be the exact text we just dispatched.
-- ---------------------------------------------------------------------------

local function onCombatLogEvent(...)
    -- 3.3.5a CLEU arg order:
    --   timestamp, subevent, sourceGUID, sourceName, sourceFlags,
    --   destGUID, destName, destFlags, ...subevent-specific...
    -- For SPELL_CAST_FAILED the tail is: spellId, spellName, spellSchool, failedType
    local subevent = select(2, ...)
    if subevent ~= "SPELL_CAST_FAILED" then return end

    local sourceGUID = select(3, ...)
    if sourceGUID ~= UnitGUID("player") then return end

    local failedType = select(12, ...)
    if failedType and failedType ~= "" then
        Print("|cff44ff44landed:|r " .. failedType)
    end
end

-- ---------------------------------------------------------------------------
-- Bootstrap
-- ---------------------------------------------------------------------------

local f = CreateFrame("Frame", "ChronicleDispatchProbeFrame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end
        local version = GetAddOnMetadata(ADDON_NAME, "Version") or "?"
        Print("v" .. version .. " loaded. Try: /chron arm hello, then cause a spell fail.")

    elseif event == "PLAYER_LOGIN" then
        captureOriginals()
        -- Ensure combat logging is on so the dispatched line actually hits
        -- WoWCombatLog.txt. (Safe to call when already enabled.)
        if not LoggingCombat() then
            LoggingCombat(true)
            Print("combat logging enabled")
        end

    elseif event == "PLAYER_LOGOUT" then
        if captured then restoreOriginals() end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        onCombatLogEvent(...)
    end
end)

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

SLASH_CHRONICLE1 = "/chron"
SLASH_CHRONICLE2 = "/chronicle"
SLASH_CHRONICLE3 = "/clog"
SlashCmdList["CHRONICLE"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "arm" then
        arm(rest)
    elseif cmd == "disarm" then
        disarm()
    elseif cmd == "log" then
        if LoggingCombat() then
            LoggingCombat(false); Print("combat logging OFF")
        else
            LoggingCombat(true);  Print("combat logging ON")
        end
    elseif cmd == "probe" then
        for _, name in ipairs(HIJACK_GLOBALS) do
            Print(name .. " = " .. tostring(_G[name]))
        end
    else
        Print("commands: /chron arm <text> | /chron disarm | /chron log | /chron probe")
    end
end
