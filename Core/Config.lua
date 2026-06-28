-- =============================================================================
-- Core/Config.lua
--
-- SavedVariables hydration + defaults merge.  Provides Chronicle.Config as
-- the single gateway to all persisted settings.
--
-- Two SavedVariables (declared in the TOC):
--   ChronicleCompanionWoTLKDB      -- account-wide settings
--   ChronicleCompanionWoTLKCharDB  -- per-character settings
--
-- On ADDON_LOADED we deep-merge defaults into the loaded tables so that
-- new keys from addon upgrades are always present without wiping user prefs.
-- =============================================================================

local Config = {}
Chronicle.Config = Config

-- ---------------------------------------------------------------------------
-- Default values
--
-- Every setting the addon uses MUST have a default here.  Modules read
-- settings via Config:Get() which falls back to these if the key is missing.
-- ---------------------------------------------------------------------------

local ACCOUNT_DEFAULTS = {
    log_level       = "error",        -- error | warn | info | debug
    log_window      = 1,              -- ChatFrame index (1-10)
    auto_combatlog_raid    = true,    -- auto-enable LoggingCombat in raids
    auto_combatlog_dungeon = true,   -- auto-enable LoggingCombat in dungeons
}

local CHAR_DEFAULTS = {
}

-- ---------------------------------------------------------------------------
-- Deep merge: copy missing keys from src into dst (recursive for tables).
-- Existing user values are never overwritten.
-- ---------------------------------------------------------------------------

local function deepMerge(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = {}
                deepMerge(dst[k], v)
            else
                dst[k] = v
            end
        elseif type(v) == "table" and type(dst[k]) == "table" then
            deepMerge(dst[k], v)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Internal state (populated on ADDON_LOADED)
-- ---------------------------------------------------------------------------

local db   = nil   -- ref to ChronicleCompanionWoTLKDB
local cdb  = nil   -- ref to ChronicleCompanionWoTLKCharDB
local ready = false

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Get an account-wide setting.
-- @param key     string   dot-free key name from ACCOUNT_DEFAULTS
-- @param default any      optional fallback if key is somehow still nil
-- @return any
function Config:Get(key, default)
    if db and db[key] ~= nil then return db[key] end
    if ACCOUNT_DEFAULTS[key] ~= nil then return ACCOUNT_DEFAULTS[key] end
    return default
end

--- Set an account-wide setting and persist it.
-- @param key   string
-- @param value any
function Config:Set(key, value)
    if not db then return end
    db[key] = value
end

--- Get a per-character setting.
-- @param key     string
-- @param default any
-- @return any
function Config:GetChar(key, default)
    if cdb and cdb[key] ~= nil then return cdb[key] end
    if CHAR_DEFAULTS[key] ~= nil then return CHAR_DEFAULTS[key] end
    return default
end

--- Set a per-character setting and persist it.
-- @param key   string
-- @param value any
function Config:SetChar(key, value)
    if not cdb then return end
    cdb[key] = value
end

--- Return the full account-wide table (for UI iteration / debug).
function Config:GetAccountDB()
    return db
end

--- Return the full per-character table (for UI iteration / debug).
function Config:GetCharDB()
    return cdb
end

--- Return true once SavedVariables have been loaded and merged.
function Config:IsReady()
    return ready
end

--- Return a copy of account defaults (for reset-to-defaults UI).
function Config:GetAccountDefaults()
    local copy = {}
    for k, v in pairs(ACCOUNT_DEFAULTS) do copy[k] = v end
    return copy
end

--- Return a copy of character defaults.
function Config:GetCharDefaults()
    local copy = {}
    for k, v in pairs(CHAR_DEFAULTS) do copy[k] = v end
    return copy
end

--- Reset a single account setting to its default.
function Config:Reset(key)
    if not db then return end
    if ACCOUNT_DEFAULTS[key] ~= nil then
        if type(ACCOUNT_DEFAULTS[key]) == "table" then
            db[key] = {}
            deepMerge(db[key], ACCOUNT_DEFAULTS[key])
        else
            db[key] = ACCOUNT_DEFAULTS[key]
        end
    else
        db[key] = nil
    end
end

--- Reset all account settings to defaults.
function Config:ResetAll()
    if not db then return end
    for k in pairs(db) do db[k] = nil end
    deepMerge(db, ACCOUNT_DEFAULTS)
end

-- ---------------------------------------------------------------------------
-- Hydration on ADDON_LOADED
-- ---------------------------------------------------------------------------

local function onAddonLoaded(event, name)
    if name ~= Chronicle.ADDON_NAME then return end
    Chronicle.UnregisterEvent("ADDON_LOADED", onAddonLoaded)

    -- Initialize globals if they don't exist yet (fresh install)
    if type(ChronicleCompanionWoTLKDB) ~= "table" then
        ChronicleCompanionWoTLKDB = {}
    end
    if type(ChronicleCompanionWoTLKCharDB) ~= "table" then
        ChronicleCompanionWoTLKCharDB = {}
    end

    db  = ChronicleCompanionWoTLKDB
    cdb = ChronicleCompanionWoTLKCharDB

    -- Merge defaults so new keys from upgrades are always present
    deepMerge(db, ACCOUNT_DEFAULTS)
    deepMerge(cdb, CHAR_DEFAULTS)

    ready = true

    -- Apply persisted logger settings now that Config is ready
    local Log = Chronicle.Logger
    if Log then
        Log:SetLevel(db.log_level)

        local idx = db.log_window
        if idx and idx >= 1 and idx <= 10 then
            local frame = _G["ChatFrame" .. idx]
            if frame then
                Log:SetChatFrame(frame)
            end
        end
    end
end

Chronicle.RegisterEvent("ADDON_LOADED", onAddonLoaded)
