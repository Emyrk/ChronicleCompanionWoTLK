-- =============================================================================
-- Core/PositionStore.lua
--
-- Bounded account-wide SavedVariables storage for timestamped group positions.
-- The desktop uploader sends this payload beside WoWCombatLog.txt, then removes
-- ChronicleCompanionWoTLKDB.position_payload while the game is closed.
-- =============================================================================

local C = Chronicle.C
local Config = Chronicle.Config
local Log = Chronicle.Logger
local Util = Chronicle.Util
local Store = {}
Chronicle.PositionStore = Store

local blockedReason = nil
local payload = nil
local guidToIndex = {}

local function newPayload()
    return {
        schema_version = C.POSITION_SCHEMA_VERSION,
        encoding = "b36-v1",
        guids = {},
        chunks = {},
        current_chunk_ticks = 0,
        tick_count = 0,
        position_count = 0,
        encoded_bytes = 0,
        missing_positions = 0,
        skipped_positions = 0,
        skipped_ticks = 0,
        capped = false,
        warned_soft = false,
        warned_critical = false,
        warned_cap = false,
    }
end

local function blockCapture(reason)
    payload = nil
    guidToIndex = {}
    if blockedReason ~= reason then
        Log:Alert("Position capture disabled to preserve unreadable SavedVariables: %s", reason)
    end
    blockedReason = reason
    return false
end

local function ensureNumber(key)
    if type(payload[key]) ~= "number" then payload[key] = 0 end
end

local function ensureBoolean(key)
    if type(payload[key]) ~= "boolean" then payload[key] = false end
end

local function rebuildIndex()
    guidToIndex = {}
    for i = 1, #payload.guids do
        local guid = payload.guids[i]
        if type(guid) == "string" and guid ~= "" then
            guidToIndex[guid] = i - 1
        end
    end
end

local function recalculateBytes()
    local total = 0
    for i = 1, #payload.guids do
        total = total + #tostring(payload.guids[i]) + 1
    end
    for i = 1, #payload.chunks do
        total = total + #tostring(payload.chunks[i])
    end
    payload.encoded_bytes = total
end

local function warnAtThresholds()
    local bytes = payload.encoded_bytes
    if bytes >= C.POSITION_STORE_WARN_BYTES and not payload.warned_soft then
        payload.warned_soft = true
        Log:Alert("Position data reached its SavedVariables warning threshold (%d KiB)",
            math.floor(bytes / 1024))
    end
    if bytes >= C.POSITION_STORE_CRITICAL_BYTES and not payload.warned_critical then
        payload.warned_critical = true
        Log:Alert("Position data is near its SavedVariables cap (%d KiB)",
            math.floor(bytes / 1024))
    end
end

local function warnAtCap()
    if payload.warned_cap then return end
    payload.warned_cap = true
    Log:Alert("Position data reached its hard cap; capture stopped until the desktop uploader resets it")
end

local function roundCoordinate(value)
    local n = tonumber(value)
    if not n then return nil end
    local scaled = math.floor(n * C.POSITION_COORD_SCALE + 0.5)
    if scaled < 0 then scaled = 0 end
    if scaled > C.POSITION_COORD_SCALE then scaled = C.POSITION_COORD_SCALE end
    return scaled
end

local function fixedBase36(value, width)
    local encoded = Util.ToBase36(value, width)
    if #encoded > width then return nil end
    return encoded
end

--- Hydrate the position payload from the account-wide SavedVariables table.
-- The desktop application resets capture by deleting position_payload while
-- WoW is closed; the next hydrate recreates an empty payload.
function Store:Hydrate()
    local db = Config and Config:GetAccountDB()
    if type(db) ~= "table" then return false end

    if db.position_payload == nil then
        blockedReason = nil
        db.position_payload = newPayload()
    elseif type(db.position_payload) ~= "table" then
        return blockCapture("position_payload is not a table")
    elseif db.position_payload.schema_version ~= C.POSITION_SCHEMA_VERSION then
        return blockCapture("unsupported schema version")
    elseif db.position_payload.encoding ~= "b36-v1" then
        return blockCapture("unsupported encoding")
    elseif type(db.position_payload.guids) ~= "table" then
        return blockCapture("GUID dictionary is not a table")
    elseif type(db.position_payload.chunks) ~= "table" then
        return blockCapture("chunk list is not a table")
    end

    payload = db.position_payload
    if #payload.guids > C.POSITION_GUID_MAX then
        return blockCapture("GUID dictionary exceeds its supported size")
    end
    local seenGuids = {}
    for i = 1, #payload.guids do
        local guid = payload.guids[i]
        if type(guid) ~= "string" or guid == "" then
            return blockCapture("GUID dictionary contains an invalid entry")
        end
        if seenGuids[guid] then
            return blockCapture("GUID dictionary contains a duplicate entry")
        end
        seenGuids[guid] = true
    end
    for i = 1, #payload.chunks do
        if type(payload.chunks[i]) ~= "string" then
            return blockCapture("chunk list contains an invalid entry")
        end
    end

    blockedReason = nil
    ensureNumber("current_chunk_ticks")
    ensureNumber("tick_count")
    ensureNumber("position_count")
    ensureNumber("encoded_bytes")
    ensureNumber("missing_positions")
    ensureNumber("skipped_positions")
    ensureNumber("skipped_ticks")
    ensureBoolean("capped")
    ensureBoolean("warned_soft")
    ensureBoolean("warned_critical")
    ensureBoolean("warned_cap")

    rebuildIndex()
    recalculateBytes()
    if payload.encoded_bytes >= C.POSITION_STORE_MAX_BYTES then
        payload.capped = true
    end
    warnAtThresholds()
    if payload.capped then warnAtCap() end
    return true
end

--- Append one timestamped set of GUID positions.
-- Encoding: <epoch36>:<map36>:<guidIndex36><x36><y36>...;
-- @tparam string timestampMs epoch milliseconds
-- @tparam number mapId current map area ID, or zero when unavailable
-- @tparam table positions array of { guid=string, x=number, y=number }
-- @treturn boolean true when the tick was appended
function Store:AppendTick(timestampMs, mapId, positions)
    if not payload and not self:Hydrate() then return false end
    if payload.capped then
        payload.skipped_ticks = payload.skipped_ticks + 1
        warnAtCap()
        return false
    end
    if type(positions) ~= "table" or #positions == 0 then return false end

    local timestamp = tonumber(timestampMs)
    if not timestamp then return false end

    local encodedMap = fixedBase36(math.max(tonumber(mapId) or 0, 0), C.POSITION_MAP_WIDTH)
    if not encodedMap then encodedMap = string.rep("0", C.POSITION_MAP_WIDTH) end

    local records = {}
    local stagedGuids = {}
    local stagedIndices = {}
    local seen = {}

    for i = 1, math.min(#positions, C.POSITION_UNIT_MAX) do
        local position = positions[i]
        local guid = position and position.guid
        if type(guid) == "string" and guid ~= "" and not seen[guid] then
            seen[guid] = true
            local x = roundCoordinate(position.x)
            local y = roundCoordinate(position.y)
            if x and y then
                local index = guidToIndex[guid]
                if index == nil then
                    index = stagedIndices[guid]
                end
                if index == nil then
                    index = #payload.guids + #stagedGuids
                    if index < C.POSITION_GUID_MAX then
                        stagedGuids[#stagedGuids + 1] = guid
                        stagedIndices[guid] = index
                    else
                        index = nil
                        payload.skipped_positions = payload.skipped_positions + 1
                    end
                end

                if index ~= nil then
                    local indexText = fixedBase36(index, C.POSITION_GUID_INDEX_WIDTH)
                    local xText = fixedBase36(x, C.POSITION_COORD_WIDTH)
                    local yText = fixedBase36(y, C.POSITION_COORD_WIDTH)
                    if indexText and xText and yText then
                        records[#records + 1] = indexText .. xText .. yText
                    else
                        payload.skipped_positions = payload.skipped_positions + 1
                    end
                end
            end
        end
    end

    if #records == 0 then return false end

    local tick = Util.ToBase36(timestamp) .. ":" .. encodedMap .. ":"
        .. table.concat(records) .. ";"
    local addedBytes = #tick
    for i = 1, #stagedGuids do
        addedBytes = addedBytes + #stagedGuids[i] + 1
    end

    if payload.encoded_bytes + addedBytes > C.POSITION_STORE_MAX_BYTES then
        payload.capped = true
        payload.skipped_ticks = payload.skipped_ticks + 1
        warnAtCap()
        return false
    end

    for i = 1, #stagedGuids do
        local guid = stagedGuids[i]
        payload.guids[#payload.guids + 1] = guid
        guidToIndex[guid] = stagedIndices[guid]
    end

    if #payload.chunks == 0
        or payload.current_chunk_ticks >= C.POSITION_BLOCK_TICKS
    then
        payload.chunks[#payload.chunks + 1] = tick
        payload.current_chunk_ticks = 1
    else
        local chunkIndex = #payload.chunks
        payload.chunks[chunkIndex] = payload.chunks[chunkIndex] .. tick
        payload.current_chunk_ticks = payload.current_chunk_ticks + 1
    end

    payload.tick_count = payload.tick_count + 1
    payload.position_count = payload.position_count + #records
    payload.encoded_bytes = payload.encoded_bytes + addedBytes
    warnAtThresholds()
    return true
end

--- Record units whose map position was unavailable for a sampling tick.
-- @tparam[opt] number count missing positions to add
function Store:RecordMissing(count)
    if not payload and not self:Hydrate() then return end
    payload.missing_positions = payload.missing_positions + math.max(tonumber(count) or 1, 0)
end

--- Return whether the hard cap has stopped capture.
-- @treturn boolean
function Store:IsCapped()
    return blockedReason ~= nil or (payload and payload.capped) or false
end

--- Return a status snapshot for slash commands and diagnostics.
-- @treturn table status counters and configured limits
function Store:GetStatus()
    if not payload and not self:Hydrate() then
        return {
            ready = false,
            blocked_reason = blockedReason,
            encoded_bytes = 0,
            max_bytes = C.POSITION_STORE_MAX_BYTES,
            capped = blockedReason ~= nil,
        }
    end
    return {
        ready = true,
        schema_version = payload.schema_version,
        encoded_bytes = payload.encoded_bytes,
        max_bytes = C.POSITION_STORE_MAX_BYTES,
        tick_count = payload.tick_count,
        position_count = payload.position_count,
        guid_count = #payload.guids,
        chunk_count = #payload.chunks,
        missing_positions = payload.missing_positions,
        skipped_positions = payload.skipped_positions,
        skipped_ticks = payload.skipped_ticks,
        capped = payload.capped,
    }
end
