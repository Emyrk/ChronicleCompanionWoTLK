-- =============================================================================
-- Core/PositionStore.lua
--
-- Bounded account-wide storage for timestamped group positions and vital data.
-- The desktop uploader sends this payload beside WoWCombatLog.txt, then removes
-- ChronicleSidekickBridgeWoTLKDB.position_payload while the game is closed.
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

local vitalStateByGuid = {}
local function newPayload()
    return {
        schema_version = C.POSITION_SCHEMA_VERSION,
        encoding = "b36-v3",
        guids = {},
        chunks = {},
        state_chunks = {},
        current_chunk_ticks = 0,
        current_state_chunk_records = 0,
        tick_count = 0,
        position_count = 0,
        state_count = 0,
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
    vitalStateByGuid = {}
    if blockedReason ~= reason then
        Log:Alert("Position capture disabled: %s", reason)
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
    for i = 1, #payload.state_chunks do
        total = total + #tostring(payload.state_chunks[i])
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

local function validGuid(guid)
    if type(guid) ~= "string" or guid == "" or #guid > C.POSITION_GUID_BYTE_MAX then
        return false
    end
    for i = 1, #guid do
        if guid:byte(i) > 127 then return false end
    end
    return true
end

local function roundCoordinate(value)
    local n = tonumber(value)
    if not n or n ~= n then return nil end
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

local function encodedOrUnknown(value, width, maximum, unknown)
    local n = tonumber(value)
    if not n or n ~= n or n < 0 or n > maximum then n = unknown end
    return fixedBase36(math.floor(n), width)
end

local function percentText(value)
    return encodedOrUnknown(value, C.POSITION_VITAL_PERCENT_WIDTH,
        C.POSITION_VITAL_PERCENT_SCALE, C.POSITION_VITAL_PERCENT_UNKNOWN)
end

local function maxText(value)
    return encodedOrUnknown(value, C.POSITION_VITAL_MAX_WIDTH,
        C.POSITION_VITAL_MAX_UNKNOWN - 1, C.POSITION_VITAL_MAX_UNKNOWN)
end

local function powerTypeText(value)
    return encodedOrUnknown(value, C.POSITION_POWER_TYPE_WIDTH,
        C.POSITION_POWER_TYPE_UNKNOWN - 1, C.POSITION_POWER_TYPE_UNKNOWN)
end

local function rebuildTickStats()
    local totalTicks = 0
    local totalPositions = 0
    local lastChunkTicks = 0
    local recordWidth = C.POSITION_GUID_INDEX_WIDTH
        + C.POSITION_COORD_WIDTH * 2
        + C.POSITION_VITAL_PERCENT_WIDTH * 2

    for chunkIndex = 1, #payload.chunks do
        local chunk = payload.chunks[chunkIndex]
        if chunk == "" or chunk:sub(-1) ~= ";" then
            return false, "tick chunk contains malformed data"
        end

        local chunkTicks = 0
        local offset = 1
        while offset <= #chunk do
            local terminator = chunk:find(";", offset, true)
            if not terminator then return false, "tick chunk contains malformed data" end
            local tick = chunk:sub(offset, terminator - 1)
            local firstSeparator = tick:find(":", 1, true)
            local secondSeparator = firstSeparator
                and tick:find(":", firstSeparator + 1, true)
            local thirdSeparator = secondSeparator
                and tick:find(":", secondSeparator + 1, true)
            if not firstSeparator or firstSeparator == 1
                or not secondSeparator
                or secondSeparator - firstSeparator - 1 ~= C.POSITION_MAP_WIDTH
                or not thirdSeparator
                or thirdSeparator - secondSeparator - 1 ~= C.POSITION_FLOOR_WIDTH
                or tick:find(":", thirdSeparator + 1, true)
            then
                return false, "tick chunk contains malformed data"
            end

            local timestamp = Util.FromBase36(tick:sub(1, firstSeparator - 1))
            local mapId = Util.FromBase36(tick:sub(firstSeparator + 1, secondSeparator - 1))
            local dungeonLevel = Util.FromBase36(tick:sub(secondSeparator + 1, thirdSeparator - 1))
            local records = tick:sub(thirdSeparator + 1)
            if not timestamp or timestamp <= 0 or mapId == nil
                or dungeonLevel == nil or dungeonLevel > C.POSITION_FLOOR_UNKNOWN
                or records == ""
                or #records % recordWidth ~= 0
            then
                return false, "tick chunk contains malformed data"
            end

            local recordCount = #records / recordWidth
            if recordCount > C.POSITION_UNIT_MAX then
                return false, "tick contains too many unit samples"
            end

            local seen = {}
            for recordOffset = 1, #records, recordWidth do
                local record = records:sub(recordOffset, recordOffset + recordWidth - 1)
                local indexEnd = C.POSITION_GUID_INDEX_WIDTH
                local xEnd = indexEnd + C.POSITION_COORD_WIDTH
                local yEnd = xEnd + C.POSITION_COORD_WIDTH
                local healthEnd = yEnd + C.POSITION_VITAL_PERCENT_WIDTH
                local index = Util.FromBase36(record:sub(1, indexEnd))
                local x = Util.FromBase36(record:sub(indexEnd + 1, xEnd))
                local y = Util.FromBase36(record:sub(xEnd + 1, yEnd))
                local health = Util.FromBase36(record:sub(yEnd + 1, healthEnd))
                local resource = Util.FromBase36(record:sub(healthEnd + 1))
                if index == nil or index >= #payload.guids or seen[index]
                    or x == nil or x > C.POSITION_COORD_SCALE
                    or y == nil or y > C.POSITION_COORD_SCALE
                    or health == nil
                    or (health > C.POSITION_VITAL_PERCENT_SCALE
                        and health ~= C.POSITION_VITAL_PERCENT_UNKNOWN)
                    or resource == nil
                    or (resource > C.POSITION_VITAL_PERCENT_SCALE
                        and resource ~= C.POSITION_VITAL_PERCENT_UNKNOWN)
                then
                    return false, "tick chunk contains malformed data"
                end
                seen[index] = true
            end

            chunkTicks = chunkTicks + 1
            totalTicks = totalTicks + 1
            totalPositions = totalPositions + recordCount
            if chunkTicks > C.POSITION_BLOCK_TICKS then
                return false, "tick chunk exceeds its tick limit"
            end
            offset = terminator + 1
        end
        lastChunkTicks = chunkTicks
    end

    payload.tick_count = totalTicks
    payload.position_count = totalPositions
    payload.current_chunk_ticks = lastChunkTicks
    return true
end

local function rebuildVitalState()
    vitalStateByGuid = {}
    local totalRecords = 0
    local lastChunkRecords = 0
    local stateWidth = C.POSITION_GUID_INDEX_WIDTH
        + C.POSITION_VITAL_MAX_WIDTH * 2
        + C.POSITION_POWER_TYPE_WIDTH

    for chunkIndex = 1, #payload.state_chunks do
        local chunk = payload.state_chunks[chunkIndex]
        if chunk == "" or chunk:sub(-1) ~= ";" then
            return false, "vital state chunk contains malformed data"
        end

        local chunkRecords = 0
        local offset = 1
        while offset <= #chunk do
            local terminator = chunk:find(";", offset, true)
            if not terminator then
                return false, "vital state chunk contains malformed data"
            end
            local record = chunk:sub(offset, terminator - 1)
            local separator = record:find(":", 1, true)
            if not separator or separator == 1
                or #record - separator ~= stateWidth
                or record:find(":", separator + 1, true)
                or not Util.FromBase36(record:sub(1, separator - 1))
            then
                return false, "vital state chunk contains malformed data"
            end

            local body = record:sub(separator + 1)
            local indexText = body:sub(1, C.POSITION_GUID_INDEX_WIDTH)
            local stateText = body:sub(C.POSITION_GUID_INDEX_WIDTH + 1)
            local index = Util.FromBase36(indexText)
            if index == nil or index >= #payload.guids
                or not Util.FromBase36(stateText)
            then
                return false, "vital state chunk contains malformed data"
            end

            vitalStateByGuid[payload.guids[index + 1]] = stateText
            chunkRecords = chunkRecords + 1
            totalRecords = totalRecords + 1
            if chunkRecords > C.POSITION_STATE_BLOCK_RECORDS then
                return false, "vital state chunk exceeds its record limit"
            end
            offset = terminator + 1
        end
        lastChunkRecords = chunkRecords
    end

    payload.state_count = totalRecords
    payload.current_state_chunk_records = lastChunkRecords
    return true
end

local function appendStateRecords(records)
    for i = 1, #records do
        if #payload.state_chunks == 0
            or payload.current_state_chunk_records >= C.POSITION_STATE_BLOCK_RECORDS
        then
            payload.state_chunks[#payload.state_chunks + 1] = records[i]
            payload.current_state_chunk_records = 1
        else
            local chunkIndex = #payload.state_chunks
            payload.state_chunks[chunkIndex] = payload.state_chunks[chunkIndex] .. records[i]
            payload.current_state_chunk_records = payload.current_state_chunk_records + 1
        end
    end
end

local function getBridgeDB()
    -- OptionalDeps establishes load order without disabling the main addon
    -- when the storage addon is missing or disabled. Never create its global
    -- here: without its TOC WoW would not persist that table.
    local ok, loaded = false, false
    if type(IsAddOnLoaded) == "function" then
        ok, loaded = pcall(IsAddOnLoaded, C.POSITION_BRIDGE_ADDON)
    end
    if not ok or not loaded then
        return nil, "ChronicleSidekickBridgeWoTLK is not loaded; install and enable it for position tracking"
    end
    local db = ChronicleSidekickBridgeWoTLKDB
    if type(db) ~= "table" then
        return nil, "bridge database is not a table"
    end
    if db.storage_version ~= C.POSITION_BRIDGE_STORAGE_VERSION then
        return nil, "unsupported bridge storage version"
    end

    return db
end

--- Hydrate the position payload from the bridge account-wide SavedVariables.
-- The desktop application resets capture by deleting position_payload while
-- WoW is closed; the next hydrate recreates an empty payload.
-- @treturn boolean true when compatible persistent storage is ready
function Store:Hydrate()
    local db, reason = getBridgeDB()
    if not db then return blockCapture(reason) end

    local legacyDB = Config and Config:GetAccountDB()
    local legacy
    if type(legacyDB) == "table" then legacy = legacyDB.position_payload end
    if legacy ~= nil and db.position_payload ~= nil
        and db.position_payload ~= legacy then
        return blockCapture("both legacy and bridge position payloads exist; upload and clear the legacy payload before capture can resume")
    end
    local migrating = legacy ~= nil
    -- Keep the legacy source until validation succeeds. Both locations are
    -- account-wide, so migration does not assign history to one character.
    local candidate = db.position_payload
    if candidate == nil then candidate = legacy end
    if candidate == nil then candidate = newPayload() end

    if type(candidate) ~= "table" then
        return blockCapture("position_payload is not a table")
    elseif candidate.schema_version ~= C.POSITION_SCHEMA_VERSION then
        return blockCapture("unsupported schema version")
    elseif candidate.encoding ~= "b36-v3" then
        return blockCapture("unsupported encoding")
    elseif type(candidate.guids) ~= "table" then
        return blockCapture("GUID dictionary is not a table")
    elseif type(candidate.chunks) ~= "table" then
        return blockCapture("chunk list is not a table")
    elseif type(candidate.state_chunks) ~= "table" then
        return blockCapture("vital state chunk list is not a table")
    end

    payload = candidate
    if #payload.guids > C.POSITION_GUID_MAX then
        return blockCapture("GUID dictionary exceeds its supported size")
    end
    local seenGuids = {}
    for i = 1, #payload.guids do
        local guid = payload.guids[i]
        if not validGuid(guid) then
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
    for i = 1, #payload.state_chunks do
        if type(payload.state_chunks[i]) ~= "string" then
            return blockCapture("vital state chunk list contains an invalid entry")
        end
    end

    rebuildIndex()
    local tickOK, tickReason = rebuildTickStats()
    if not tickOK then return blockCapture(tickReason) end
    local stateOK, stateReason = rebuildVitalState()
    if not stateOK then return blockCapture(stateReason) end

    blockedReason = nil
    ensureNumber("current_chunk_ticks")
    ensureNumber("current_state_chunk_records")
    ensureNumber("tick_count")
    ensureNumber("position_count")
    ensureNumber("state_count")
    ensureNumber("encoded_bytes")
    ensureNumber("missing_positions")
    ensureNumber("skipped_positions")
    ensureNumber("skipped_ticks")
    ensureBoolean("capped")
    ensureBoolean("warned_soft")
    ensureBoolean("warned_critical")
    ensureBoolean("warned_cap")

    recalculateBytes()
    if payload.encoded_bytes >= C.POSITION_STORE_MAX_BYTES then
        payload.capped = true
    end
    warnAtThresholds()
    if payload.capped then warnAtCap() end
    db.position_payload = payload
    if migrating then legacyDB.position_payload = nil end
    return true
end

--- Return whether the bridge container permits an explicit position reset.
-- Invalid or capped position payloads can still be cleared.
-- @treturn boolean
function Store:CanClear()
    local db = getBridgeDB()
    return db ~= nil
end

--- Explicitly discard captured positions, preserving settings and other payloads.
-- Also removes legacy capture data so hydration cannot restore deleted history.
-- @treturn boolean true when the store was reset
function Store:Clear()
    local db, reason = getBridgeDB()
    if not db then return blockCapture(reason) end
    local legacyDB = Config and Config:GetAccountDB()
    if type(legacyDB) == "table" then legacyDB.position_payload = nil end
    db.position_payload = newPayload()
    payload = nil
    guidToIndex = {}
    vitalStateByGuid = {}
    blockedReason = nil
    return self:Hydrate()
end

--- Append one timestamped set of positions and percentage vitals.
-- Max health, max resource, and resource type are written to the separate state
-- stream on first observation and whenever the encoded state changes.
-- @tparam string timestampMs epoch milliseconds
-- @tparam number mapId current map area ID, or zero when unavailable
-- @tparam table positions unit samples with GUID, coordinates, and vital fields
-- @tparam[opt] number dungeonLevel selected dungeon-map level; nil means unknown
-- @treturn boolean true when the complete tick and its state changes were appended
function Store:AppendTick(timestampMs, mapId, positions, dungeonLevel)
    if not payload and not self:Hydrate() then return false end
    if payload.capped then
        payload.skipped_ticks = payload.skipped_ticks + 1
        warnAtCap()
        return false
    end
    if type(positions) ~= "table" or #positions == 0 then return false end

    local timestamp = tonumber(timestampMs)
    if not timestamp then return false end
    local timestampText = Util.ToBase36(timestamp)
    local encodedMap = fixedBase36(math.max(tonumber(mapId) or 0, 0), C.POSITION_MAP_WIDTH)
    if not encodedMap then encodedMap = string.rep("0", C.POSITION_MAP_WIDTH) end
    local floor = tonumber(dungeonLevel)
    if floor and floor ~= math.floor(floor) then floor = nil end
    local encodedFloor = encodedOrUnknown(floor, C.POSITION_FLOOR_WIDTH,
        C.POSITION_FLOOR_UNKNOWN - 1, C.POSITION_FLOOR_UNKNOWN)

    local records = {}
    local stateRecords = {}
    local stagedVitalState = {}
    local stagedGuids = {}
    local stagedIndices = {}
    local seen = {}

    for i = 1, math.min(#positions, C.POSITION_UNIT_MAX) do
        local position = positions[i]
        local guid = position and position.guid
        if validGuid(guid) and not seen[guid] then
            seen[guid] = true
            local x = roundCoordinate(position.x)
            local y = roundCoordinate(position.y)
            if x and y then
                local index = guidToIndex[guid]
                if index == nil then index = stagedIndices[guid] end
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
                    local healthText = percentText(position.health_permille)
                    local resourceText = percentText(position.resource_permille)
                    local stateText = maxText(position.health_max)
                        .. maxText(position.resource_max)
                        .. powerTypeText(position.resource_type)
                    if indexText and xText and yText and healthText and resourceText then
                        records[#records + 1] = indexText .. xText .. yText
                            .. healthText .. resourceText
                        if vitalStateByGuid[guid] ~= stateText then
                            stateRecords[#stateRecords + 1] = timestampText .. ":"
                                .. indexText .. stateText .. ";"
                            stagedVitalState[guid] = stateText
                        end
                    else
                        payload.skipped_positions = payload.skipped_positions + 1
                    end
                end
            end
        end
    end

    if #records == 0 then return false end

    local tick = timestampText .. ":" .. encodedMap .. ":" .. encodedFloor .. ":"
        .. table.concat(records) .. ";"
    local addedBytes = #tick
    for i = 1, #stateRecords do addedBytes = addedBytes + #stateRecords[i] end
    for i = 1, #stagedGuids do
        addedBytes = addedBytes + #stagedGuids[i] + 1
    end

    -- Commit the dictionary, tick, and state stream together only after the
    -- complete append fits. The cap therefore never leaves a partial tick.
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

    appendStateRecords(stateRecords)
    for guid, stateText in pairs(stagedVitalState) do
        vitalStateByGuid[guid] = stateText
    end

    payload.tick_count = payload.tick_count + 1
    payload.position_count = payload.position_count + #records
    payload.state_count = payload.state_count + #stateRecords
    payload.encoded_bytes = payload.encoded_bytes + addedBytes
    warnAtThresholds()
    if payload.encoded_bytes >= C.POSITION_STORE_MAX_BYTES then
        payload.capped = true
        warnAtCap()
    end
    return true
end

--- Record units whose map position was unavailable for a sampling tick.
-- @tparam[opt] number count missing positions to add
function Store:RecordMissing(count)
    if not payload and not self:Hydrate() then return end
    payload.missing_positions = payload.missing_positions + math.max(tonumber(count) or 1, 0)
end

--- Return whether a validated, persistent storage target is available.
-- @treturn boolean
function Store:IsReady()
    return payload ~= nil or self:Hydrate()
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
        state_count = payload.state_count,
        guid_count = #payload.guids,
        chunk_count = #payload.chunks,
        state_chunk_count = #payload.state_chunks,
        missing_positions = payload.missing_positions,
        skipped_positions = payload.skipped_positions,
        skipped_ticks = payload.skipped_ticks,
        capped = payload.capped,
    }
end
