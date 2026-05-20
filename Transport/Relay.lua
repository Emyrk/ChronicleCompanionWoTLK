-- =============================================================================
-- Transport/Relay.lua
--
-- The hijack engine.  Overwrites SPELL_FAILED_* globals with our payload
-- so the engine writes it into WoWCombatLog.txt on SPELL_CAST_FAILED.
--
-- The relay is message-type-agnostic.  It pulls data from registered
-- providers in priority order.  Each provider implements:
--
--   provider.priority  number      lower = polled first
--   provider:Poll()    string|nil  nil = nothing to send
--   provider:Label()   string      for UI / debug output
--
-- When the relay needs data it walks providers by priority until one
-- returns a payload.  The payload is chunked on the fly and armed
-- into the SPELL_FAILED_* globals.  On confirmed landing (CLEU match)
-- we advance to the next chunk.  When the message is complete we poll
-- again.
--
-- Short messages (< BIN_PACK_THRESHOLD) can bin-pack a second message
-- from the next provider into the same slot.
-- =============================================================================

local Log = Chronicle.Logger
local C   = Chronicle.C

Chronicle.Relay = {}
local R = Chronicle.Relay

-- ---------------------------------------------------------------------------
-- Provider registry
-- ---------------------------------------------------------------------------

local providers = {}   -- sorted { {priority, provider}, ... }

function R:RegisterProvider(provider)
    if not provider or not provider.Poll or not provider.priority then
        Log:Warn("Relay: invalid provider (needs .priority and :Poll())")
        return
    end
    -- Insert sorted by priority (lower first)
    local entry = { priority = provider.priority, provider = provider }
    local inserted = false
    for i = 1, #providers do
        if provider.priority < providers[i].priority then
            table.insert(providers, i, entry)
            inserted = true
            break
        end
    end
    if not inserted then
        providers[#providers + 1] = entry
    end
    Log:Debug("Relay: registered provider '%s' (priority %d)",
        tostring(provider:Label()), provider.priority)
end

function R:GetProviders()
    return providers
end

-- ---------------------------------------------------------------------------
-- Hijack state
-- ---------------------------------------------------------------------------

local originals     = {}      -- { [globalName] = originalValue }
local captured      = false
local globalsDirty  = false   -- true while globals hold our payload

-- Active message being chunked
local activePayload = nil     -- full payload string (from provider)
local activeLabel   = ""      -- provider label for debug
local activeCounter = 0       -- message counter digit (0-9)
local chunkOffset   = 0       -- bytes of activePayload already landed
local totalChunks   = 0       -- precomputed total chunk count
local landedChunks  = 0       -- how many chunks have landed so far

-- What is currently written into the globals
local armedChunk    = nil

-- Relay on/off
local active        = false
local paused        = false   -- manual pause via /clog relay pause

-- Metrics (in-memory, reset on reload)
local metrics = {
    chunks_landed   = 0,
    chunks_missed   = 0,
    messages_sent   = 0,
    provider_polls  = 0,
}

function R:GetMetrics() return metrics end
function R:IsActive() return active end
function R:IsPaused() return paused end
function R:GetActiveLabel() return activeLabel end
function R:GetActiveProgress()
    if not activePayload then return 0, 0 end
    return landedChunks, totalChunks
end

-- ---------------------------------------------------------------------------
-- Originals capture / restore
-- ---------------------------------------------------------------------------

local function captureOriginals()
    if captured then return end
    for _, name in ipairs(C.HIJACK_GLOBALS) do
        originals[name] = _G[name]
    end
    captured = true
    Log:Debug("Relay: captured %d originals", #C.HIJACK_GLOBALS)
end

local function restoreOriginals()
    if not globalsDirty then return end
    for _, name in ipairs(C.HIJACK_GLOBALS) do
        _G[name] = originals[name]
    end
    globalsDirty = false
    armedChunk = nil
    Log:Debug("Relay: originals restored")
end

local function applyToGlobals(text)
    for _, name in ipairs(C.HIJACK_GLOBALS) do
        _G[name] = text
    end
    globalsDirty = true
    armedChunk = text
end

-- ---------------------------------------------------------------------------
-- Chunking
--
-- Given a payload and a counter digit, produce the chunk at a given
-- byte offset.  Framing:
--   first chunk:  [N<payload_slice>       (243 chars max)
--   middle chunk:   <payload_slice>       (245 chars max)
--   last chunk:     <payload_slice>]      (244 chars max)
--   single chunk: [N<payload_slice>]      (242 chars max)
-- ---------------------------------------------------------------------------

local FIELD_MAX = C.FIELD_MAX_CHARS  -- 245

--- Compute total chunk count for a payload.
local function computeChunkCount(payload)
    local len = #payload
    -- Single-slot: [N + payload + ] <= 245  ->  payload <= 242
    if len <= FIELD_MAX - 3 then return 1 end

    -- First chunk eats 243 of payload (245 - 2 for "[N")
    local remaining = len - (FIELD_MAX - 2)
    -- Continuation chunks have "~" prefix (1 char overhead)
    -- Last chunk: ~ + payload + ] = 243 payload chars
    -- Middle chunk: ~ + payload = 244 payload chars
    if remaining <= FIELD_MAX - 2 then return 2 end  -- first + last
    remaining = remaining - (FIELD_MAX - 2)  -- subtract last chunk capacity
    local middles = math.ceil(remaining / (FIELD_MAX - 1))
    return 1 + middles + 1  -- first + middles + last
end

--- Build chunk at the given offset for a payload + counter.
-- Returns (chunkString, newOffset, isLast).
--
-- Chunk layout:
--   first chunk:  [N<payload>       (prefix = 2 chars)
--   middle chunk: ~<payload>        (prefix = 1 char)
--   last chunk:   ~<payload>]       (prefix = 1 char, suffix = 1 char)
--   single chunk: [N<payload>]      (prefix = 2 chars, suffix = 1 char)
local function buildChunk(payload, counter, offset)
    local len = #payload
    local isFirst = (offset == 0)

    -- Build prefix
    local prefix
    if isFirst then
        prefix = C.MSG_OPEN .. tostring(counter)
    else
        prefix = C.MSG_CONTINUE
    end

    -- How much payload can we fit?
    local capacity = FIELD_MAX - #prefix
    local remaining = len - offset

    -- Will this be the last chunk?
    local suffix = ""
    local isLast = false
    if remaining <= capacity - 1 then
        -- Fits with the closing bracket
        suffix = C.MSG_CLOSE
        isLast = true
        capacity = capacity - 1
    end

    local slice = payload:sub(offset + 1, offset + capacity)
    local newOffset = offset + #slice

    return prefix .. slice .. suffix, newOffset, isLast
end

-- ---------------------------------------------------------------------------
-- Provider polling
-- ---------------------------------------------------------------------------

--- Poll providers in priority order for a payload.
-- Returns (payload, label) or (nil, nil).
local function pollProviders()
    metrics.provider_polls = metrics.provider_polls + 1
    for _, entry in ipairs(providers) do
        local ok, payload = pcall(entry.provider.Poll, entry.provider)
        if ok and payload and payload ~= "" then
            local label = "?"
            local ok2, lbl = pcall(entry.provider.Label, entry.provider)
            if ok2 and lbl then label = lbl end
            return payload, label
        elseif not ok then
            Log:Warn("Relay: provider '%s' Poll() error: %s",
                tostring(entry.provider:Label()), tostring(payload))
        end
    end
    return nil, nil
end

--- Start a new message from a provider's payload.
local function startMessage(payload, label)
    activePayload = payload
    activeLabel   = label
    activeCounter = (activeCounter + 1) % (C.MSG_COUNTER_MAX + 1)
    chunkOffset   = 0
    totalChunks   = computeChunkCount(payload)
    landedChunks  = 0
    Log:Debug("Relay: new message [%d] from '%s' (%d chars, %d chunks)",
        activeCounter, label, #payload, totalChunks)
end

-- ---------------------------------------------------------------------------
-- Arm the next chunk
--
-- Called after a landing or when we first activate.  Builds the next
-- chunk and writes it to all SPELL_FAILED_* globals.
--
-- Bin-packing: if the current message fits entirely in one slot AND
-- leaves room (< BIN_PACK_THRESHOLD), we try to pack a second message
-- from the next provider into the same slot.
-- ---------------------------------------------------------------------------

local function armNext()
    -- Need a message?
    if not activePayload then
        local payload, label = pollProviders()
        if not payload then
            -- Nothing to send -- restore originals
            restoreOriginals()
            return
        end
        startMessage(payload, label)
    end

    local chunk, newOffset, isLast = buildChunk(activePayload, activeCounter, chunkOffset)

    -- Bin-packing: if this is a single-chunk message AND it's short,
    -- try to append another message into the same slot
    if isLast and chunkOffset == 0 and #chunk <= C.BIN_PACK_THRESHOLD then
        local remainingRoom = FIELD_MAX - #chunk
        -- We need at least 4 chars for [N + 1 char payload + ]
        if remainingRoom >= 4 then
            local payload2, label2 = pollProviders()
            if payload2 then
                local framedLen = 2 + #payload2 + 1  -- [N + payload + ]
                if framedLen <= remainingRoom then
                    -- Fits! Pack it in.
                    local counter2 = (activeCounter + 1) % (C.MSG_COUNTER_MAX + 1)
                    local packed = C.MSG_OPEN .. tostring(counter2) .. payload2 .. C.MSG_CLOSE
                    chunk = chunk .. packed
                    -- The second message is fully packed, so advance counter
                    activeCounter = counter2
                    Log:Debug("Relay: bin-packed '%s' (%d chars) into slot",
                        label2, #payload2)
                    -- Note: the first message finishes below (isLast=true),
                    -- and the packed message is also complete.  Both land
                    -- in one SPELL_CAST_FAILED event.
                    metrics.messages_sent = metrics.messages_sent + 1
                else
                    -- Doesn't fit.  The provider returned a payload we can't
                    -- use yet.  That's fine -- we'll get it on the next poll.
                    -- (Provider still considers itself dirty.)
                end
            end
        end
    end

    applyToGlobals(chunk)

    -- If this was the last chunk, prepare for completion on landing
    if isLast then
        -- We'll clear activePayload in onLanding() after confirmation
        chunkOffset = newOffset  -- mark as "all bytes assigned"
    else
        chunkOffset = newOffset
    end
end

-- ---------------------------------------------------------------------------
-- Landing + CLEU handler
-- ---------------------------------------------------------------------------

local function onLanding()
    landedChunks = landedChunks + 1
    metrics.chunks_landed = metrics.chunks_landed + 1

    -- Was that the last chunk of the active message?
    if chunkOffset >= #(activePayload or "") then
        metrics.messages_sent = metrics.messages_sent + 1
        Log:Debug("Relay: message [%d] '%s' complete (%d chunks)",
            activeCounter, activeLabel, totalChunks)
        activePayload = nil
        activeLabel   = ""
    end

    -- Arm the next chunk (or poll for a new message)
    armNext()
end

local function onMiss()
    metrics.chunks_missed = metrics.chunks_missed + 1
    -- Re-arm the same chunk -- it stays in the globals already.
    -- Nothing to do; the globals still hold our payload.
end

local function onSpellCastFailed(failedType)
    if not active or paused then return end

    -- If nothing is armed, try to get something
    if not armedChunk then
        armNext()
        return
    end

    -- Landing check: exact match
    if failedType == armedChunk then
        onLanding()
    else
        onMiss()
    end
end

-- ---------------------------------------------------------------------------
-- UIErrorsFrame suppression
--
-- When armed, the engine also routes SPELL_FAILED_* strings to the
-- red error text overlay.  We hook AddMessage and drop anything that
-- matches our current armed chunk.
-- ---------------------------------------------------------------------------

local uiErrorHooked = false
local originalUIErrorAddMessage = nil

local function installUIErrorHook()
    if uiErrorHooked then return end
    if not UIErrorsFrame then return end

    originalUIErrorAddMessage = UIErrorsFrame.AddMessage
    UIErrorsFrame.AddMessage = function(self, msg, ...)
        -- Drop messages that are our armed payload
        if armedChunk and msg == armedChunk then
            return
        end
        -- Also drop anything that starts with our framing markers:
        --   [N  (message start + digit)
        --   ~   (continuation chunk)
        if msg and #msg >= 2 then
            local first = msg:sub(1, 1)
            if first == C.MSG_CONTINUE then
                return
            end
            local second = msg:sub(2, 2)
            if first == C.MSG_OPEN and second >= "0" and second <= "9" then
                return
            end
        end
        return originalUIErrorAddMessage(self, msg, ...)
    end
    uiErrorHooked = true
end

-- ---------------------------------------------------------------------------
-- Taint error suppression
--
-- Overwriting SPELL_FAILED_* globals causes taint.  We suppress the
-- cosmetic error popups.  The actual taint is harmless for our use case.
-- ---------------------------------------------------------------------------

local taintHooked = false

local function installTaintSuppression()
    if taintHooked then return end

    -- Layer 1: error handler wrapper
    local innerHandler = geterrorhandler()
    seterrorhandler(function(msg)
        if type(msg) == "string"
            and msg:find("ChronicleCompanionWoTLK", 1, true)
            and msg:find("tainted", 1, true)
        then
            return  -- swallow
        end
        if innerHandler then return innerHandler(msg) end
    end)

    -- Layer 2: StaticPopup suppression
    local popupNames = { "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED" }
    for _, name in ipairs(popupNames) do
        local dialog = StaticPopupDialogs and StaticPopupDialogs[name]
        if dialog then
            local origOnShow = dialog.OnShow
            dialog.OnShow = function(self, ...)
                -- If the popup text mentions our addon, hide it
                local text = self.text and self.text:GetText() or ""
                if text:find("ChronicleCompanionWoTLK", 1, true) then
                    self:Hide()
                    return
                end
                if origOnShow then return origOnShow(self, ...) end
            end
        end
    end

    taintHooked = true
end

-- ---------------------------------------------------------------------------
-- Activation / deactivation
-- ---------------------------------------------------------------------------

local function shouldBeActive()
    if paused then return false end
    if not LoggingCombat() then return false end
    local cfg = Chronicle.Config
    if cfg and cfg:Get("hijack_enabled") == false then return false end
    return true
end

function R:Activate()
    if active then return end
    captureOriginals()
    installUIErrorHook()
    installTaintSuppression()
    active = true
    Log:Debug("Relay: activated")
    -- Try to arm something immediately
    armNext()
end

function R:Deactivate()
    if not active then return end
    restoreOriginals()
    active = false
    activePayload = nil
    activeLabel   = ""
    Log:Debug("Relay: deactivated")
end

function R:Pause()
    paused = true
    restoreOriginals()
    Log:Info("Relay paused")
end

function R:Resume()
    paused = false
    Log:Info("Relay resumed")
    if shouldBeActive() then
        R:Activate()
    end
end

function R:Reevaluate()
    if shouldBeActive() and not active then
        R:Activate()
    elseif not shouldBeActive() and active then
        R:Deactivate()
    end
end

-- ---------------------------------------------------------------------------
-- Force-write for testing
--
-- Registers a one-shot provider that returns the given text once.
-- Used by /clog relay write <text>
-- ---------------------------------------------------------------------------

function R:InjectTest(text)
    local testProvider = {
        priority = 0,
        _payload = text,
    }
    function testProvider:Poll()
        local p = self._payload
        self._payload = nil
        return p
    end
    function testProvider:Label()
        return "Test"
    end
    R:RegisterProvider(testProvider)
    -- If relay is active, kick it
    if active and not armedChunk then
        armNext()
    end
    Log:Info("Relay: injected test message (%d chars)", #text)
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

local function onCLEU(event, ...)
    local subevent = select(2, ...)
    if subevent ~= "SPELL_CAST_FAILED" then return end

    local sourceGUID = select(3, ...)
    if sourceGUID ~= UnitGUID("player") then return end

    local failedType = select(C.RELAY_FAILEDTYPE_ARG, ...)
    if failedType then
        onSpellCastFailed(failedType)
    end
end

local function onPlayerLogin()
    captureOriginals()
    -- Start relay if combat logging is already on
    R:Reevaluate()
end

local function onPlayerLogout()
    -- Unconditional safety net -- always restore
    if captured then
        for _, name in ipairs(C.HIJACK_GLOBALS) do
            _G[name] = originals[name]
        end
    end
end

-- Reevaluate on events that might change shouldBeActive()
Chronicle.RegisterEvent("PLAYER_LOGIN", onPlayerLogin)
Chronicle.RegisterEvent("PLAYER_LOGOUT", onPlayerLogout)
Chronicle.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCLEU)

-- These could change LoggingCombat() state
Chronicle.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    R:Reevaluate()
end)
