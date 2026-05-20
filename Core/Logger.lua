-- =============================================================================
-- Core/Logger.lua
--
-- Chat-window logger with configurable log levels and pretty-print support.
--
-- Log levels (ascending verbosity):
--     error < warn < info < debug
--
-- Set via Chronicle.Logger:SetLevel("debug") or /clog loglvl debug.
-- Output goes to a configurable chat frame (default: DEFAULT_CHAT_FRAME).
-- =============================================================================

local Logger = {}
Chronicle.Logger = Logger

-- ---------------------------------------------------------------------------
-- Level definitions
-- ---------------------------------------------------------------------------

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }
local DEFAULT_LEVEL = "info"

local COLORS = {
    error = "|cffff0000",   -- red
    warn  = "|cffffff00",   -- yellow
    info  = "|cff4ec3ff",   -- Chronicle blue
    debug = "|cff888888",   -- grey
}

-- State
local currentLevel = LEVELS[DEFAULT_LEVEL]
local currentLevelName = DEFAULT_LEVEL
local chatFrame = nil  -- resolved lazily (DEFAULT_CHAT_FRAME may not exist at load time)

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function getChatFrame()
    if chatFrame then return chatFrame end
    return DEFAULT_CHAT_FRAME
end

--- Format a message with optional string.format args.
-- If the first vararg is nil or there are no varargs, msg is used as-is.
local function fmt(msg, ...)
    if select("#", ...) > 0 then
        local ok, result = pcall(string.format, msg, ...)
        if ok then return result end
    end
    return tostring(msg)
end

local function emit(level, msg, ...)
    if LEVELS[level] > currentLevel then return end
    local text = fmt(msg, ...)
    local prefix = COLORS[level] .. "[Chronicle]|r "
    local frame = getChatFrame()
    if frame and frame.AddMessage then
        frame:AddMessage(prefix .. text)
    end
    -- Errors also go through the global error handler so BugSack picks them up
    if level == "error" then
        local handler = geterrorhandler()
        if handler then
            handler("[Chronicle] " .. text)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Log an error.  Always prints.  Also feeds geterrorhandler().
-- @tparam string msg format string (or plain message)
-- @param ... format arguments
function Logger:Error(msg, ...) emit("error", msg, ...) end

--- Log a warning.  Prints at warn level or above.
-- @tparam string msg format string
-- @param ... format arguments
function Logger:Warn(msg, ...)  emit("warn",  msg, ...) end

--- Log an informational message.  Prints at info level or above.
-- @tparam string msg format string
-- @param ... format arguments
function Logger:Info(msg, ...)  emit("info",  msg, ...) end

--- Log a debug message.  Only prints when log level is "debug".
-- @tparam string msg format string
-- @param ... format arguments
function Logger:Debug(msg, ...) emit("debug", msg, ...) end

--- Set the active log level.
-- @tparam string name one of "error", "warn", "info", "debug"
function Logger:SetLevel(name)
    name = (name or ""):lower()
    if not LEVELS[name] then
        self:Warn("Unknown log level '%s'. Use: error, warn, info, debug", tostring(name))
        return
    end
    currentLevel = LEVELS[name]
    currentLevelName = name
    self:Info("Log level set to %s", name)
end

--- Return the current log level name.
-- @treturn string current level ("error", "warn", "info", or "debug")
function Logger:GetLevel()
    return currentLevelName
end

--- Set the chat frame all output goes to.
-- @tparam Frame frame any object with :AddMessage (e.g. ChatFrame2)
function Logger:SetChatFrame(frame)
    if frame and frame.AddMessage then
        chatFrame = frame
        self:Info("Logger output redirected to %s", frame:GetName() or "custom frame")
    else
        self:Warn("Invalid chat frame -- must have :AddMessage()")
    end
end

--- Return the currently active chat frame.
-- @treturn Frame the frame receiving log output
function Logger:GetChatFrame()
    return getChatFrame()
end

-- ---------------------------------------------------------------------------
-- Pretty-print table dumper  (for /chron inspect ci debugging)
--
-- Recursively prints a table to chat, capped at MAX_LINES to avoid flood.
-- ---------------------------------------------------------------------------

local MAX_DUMP_LINES = 50
local dumpCount = 0

local function dumpImpl(t, indent, visited)
    if dumpCount >= MAX_DUMP_LINES then return end
    indent = indent or ""
    visited = visited or {}

    if type(t) ~= "table" then
        emit("info", "%s%s", indent, tostring(t))
        dumpCount = dumpCount + 1
        return
    end

    if visited[t] then
        emit("info", "%s<circular ref>", indent)
        dumpCount = dumpCount + 1
        return
    end
    visited[t] = true

    -- Collect and sort keys for deterministic output
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        -- numbers first (sorted numerically), then strings (alphabetical)
        local ta, tb = type(a), type(b)
        if ta == tb then
            if ta == "number" then return a < b end
            return tostring(a) < tostring(b)
        end
        return ta == "number"
    end)

    for _, k in ipairs(keys) do
        if dumpCount >= MAX_DUMP_LINES then
            emit("info", "%s... (truncated at %d lines)", indent, MAX_DUMP_LINES)
            dumpCount = dumpCount + 1
            return
        end
        local v = t[k]
        local keyStr = type(k) == "number" and ("[" .. k .. "]") or tostring(k)
        if type(v) == "table" then
            emit("info", "%s%s = {", indent, keyStr)
            dumpCount = dumpCount + 1
            dumpImpl(v, indent .. "    ", visited)
            if dumpCount < MAX_DUMP_LINES then
                emit("info", "%s}", indent)
                dumpCount = dumpCount + 1
            end
        else
            local valStr
            if type(v) == "string" then
                valStr = '"' .. v .. '"'
            else
                valStr = tostring(v)
            end
            emit("info", "%s%s = %s", indent, keyStr, valStr)
            dumpCount = dumpCount + 1
        end
    end
end

--- Dump a table to chat in a readable tree format.
-- @param t       any     Value to dump (tables are expanded recursively)
-- @param label   string  Optional header label printed before the dump
function Logger:DumpTable(t, label)
    dumpCount = 0
    if label then
        emit("info", "--- %s ---", label)
        dumpCount = dumpCount + 1
    end
    dumpImpl(t, "  ")
    if label then
        emit("info", "--- end %s ---", label)
    end
end
