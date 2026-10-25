local T = _G.Test
local cases = {}

local function add(name, run)
    cases[#cases + 1] = { name = name, run = run }
end

local function loadStore(overrides)
    overrides = overrides or {}
    _G.Chronicle = {
        C = {
            POSITION_BRIDGE_ADDON = "ChronicleSidekickBridgeWoTLK",
            POSITION_BRIDGE_STORAGE_VERSION = 1,
            POSITION_SCHEMA_VERSION = 1,
            POSITION_UNIT_MAX = 50,
            POSITION_GUID_INDEX_WIDTH = 2,
            POSITION_COORD_SCALE = 10000,
            POSITION_COORD_WIDTH = 3,
            POSITION_MAP_WIDTH = 3,
            POSITION_BLOCK_TICKS = 60,
            POSITION_STORE_WARN_BYTES = overrides.warn or 1024,
            POSITION_STORE_CRITICAL_BYTES = overrides.critical or 1536,
            POSITION_STORE_MAX_BYTES = overrides.max or 2048,
            POSITION_GUID_MAX = 1296,
        },
    }
    _G.time = function() return 1786244400 end
    _G.GetTime = function() return 0 end
    dofile("Core/Util.lua")

    local db = overrides.db or { storage_version = 1, unrelated = "keep" }
    if db.storage_version == nil then db.storage_version = 1 end
    _G.ChronicleSidekickBridgeWoTLKDB = db
    _G.IsAddOnLoaded = function(name)
        T.equal(name, "ChronicleSidekickBridgeWoTLK")
        return not overrides.missingBridge
    end
    local account = overrides.account or { unrelated = "main settings" }
    local warnings = {}
    Chronicle.Config = {
        GetAccountDB = function() return account end,
    }
    Chronicle.Logger = {
        Alert = function(_, message) warnings[#warnings + 1] = message end,
    }

    dofile("Core/PositionStore.lua")
    Chronicle.PositionStore:Hydrate()
    return Chronicle.PositionStore, db, warnings, account
end

local function pos(guid, x, y)
    return { guid = guid, x = x, y = y }
end

add("hydrate creates one account-wide payload without replacing other settings", function()
    local store, db = loadStore()
    T.equal(db.unrelated, "keep")
    T.equal(db.position_payload.schema_version, 1)
    T.equal(#db.position_payload.guids, 0)
    T.equal(#db.position_payload.chunks, 0)
    T.equal(store:GetStatus().tick_count, 0)
end)

add("append groups one epoch and map with dictionary-indexed positions", function()
    local store, db = loadStore()
    local positions = {
        pos("0x0000000000000001", 0.1234, 0.5678),
        pos("0x0000000000000002", 1, 0),
    }
    T.truthy(store:AppendTick("1786244400123", 631, positions))

    local payload = db.position_payload
    local util = Chronicle.Util
    local expected = util.ToBase36(1786244400123)
        .. ":" .. util.ToBase36(631, 3) .. ":"
        .. "00" .. util.ToBase36(1234, 3) .. util.ToBase36(5678, 3)
        .. "01" .. util.ToBase36(10000, 3) .. util.ToBase36(0, 3)
        .. ";"

    T.equal(payload.chunks[1], expected)
    T.equal(payload.guids[1], "0x0000000000000001")
    T.equal(payload.guids[2], "0x0000000000000002")
    T.equal(payload.tick_count, 1)
    T.equal(payload.position_count, 2)
end)

add("existing GUIDs are reused across ticks and blocks", function()
    local store, db = loadStore()
    local position = pos("0x0000000000000001", 0.25, 0.75)
    for i = 1, 61 do
        T.truthy(store:AppendTick(tostring(1786244400000 + i * 1000), 631, { position }))
    end
    T.equal(#db.position_payload.guids, 1)
    T.equal(#db.position_payload.chunks, 2)
    T.equal(db.position_payload.tick_count, 61)
end)

add("an append that exactly fills the cap marks the payload capped", function()
    local position = pos("0x0000000000000001", 0.25, 0.75)
    local baseline = loadStore({ warn = 1000000, critical = 1000001, max = 1000002 })
    T.truthy(baseline:AppendTick("1786244400000", 631, { position }))
    local exactBytes = baseline:GetStatus().encoded_bytes

    local store = loadStore({
        warn = exactBytes,
        critical = exactBytes,
        max = exactBytes,
    })
    T.truthy(store:AppendTick("1786244400000", 631, { position }))
    T.truthy(store:IsCapped())
    T.equal(store:GetStatus().encoded_bytes, exactBytes)
end)

add("warnings fire once and the hard cap preserves existing data", function()
    local store, db, warnings = loadStore({ warn = 40, critical = 70, max = 105 })
    local position = pos("0x0000000000000001", 0.25, 0.75)

    T.truthy(store:AppendTick("1786244400000", 631, { position }))
    T.truthy(store:AppendTick("1786244401000", 631, { position }))
    T.truthy(store:AppendTick("1786244402000", 631, { position }))
    local before = db.position_payload.chunks[1]
    T.falsy(store:AppendTick("1786244403000", 631, { position }))
    T.equal(db.position_payload.chunks[1], before)
    T.truthy(db.position_payload.capped)
    T.equal(db.position_payload.skipped_ticks, 1)
    T.equal(#warnings, 3)
end)

add("fifty units at one hertz stay near 1.5 MB per hour", function()
    local store = loadStore({
        warn = 7 * 1024 * 1024,
        critical = 7.5 * 1024 * 1024,
        max = 8 * 1024 * 1024,
    })
    local positions = {}
    for i = 1, 50 do
        positions[i] = pos(string.format("0x%016x", i), i / 100, i / 100)
    end
    for second = 0, 3599 do
        T.truthy(store:AppendTick(tostring(1786244400000 + second * 1000), 631, positions))
    end
    local bytes = store:GetStatus().encoded_bytes
    T.truthy(bytes > 1490000, "expected at least 1.49 MB")
    T.truthy(bytes < 1510000, "expected less than 1.51 MB")
end)

add("invalid or future payloads are preserved and block capture", function()
    local future = {
        schema_version = 99,
        encoding = "future",
        guids = {},
        chunks = { "do-not-delete" },
    }
    local store, db, warnings = loadStore({ db = { position_payload = future } })
    T.equal(db.position_payload, future)
    T.truthy(store:IsCapped())
    T.equal(store:GetStatus().blocked_reason, "unsupported schema version")
    T.equal(#warnings, 1)
    store:Hydrate()
    T.equal(#warnings, 1)
end)

add("malformed chunk data is preserved and blocks capture", function()
    local malformed = {
        schema_version = 1,
        encoding = "b36-v1",
        guids = {},
        chunks = { 42 },
    }
    local store, db = loadStore({ db = { position_payload = malformed } })
    T.equal(db.position_payload, malformed)
    T.truthy(store:IsCapped())
    T.falsy(store:AppendTick("1786244400000", 631, {
        pos("0x0000000000000001", 0.25, 0.75),
    }))
end)

add("duplicate GUID dictionary entries block capture without mutation", function()
    local duplicate = {
        schema_version = 1,
        encoding = "b36-v1",
        guids = { "0x1", "0x1" },
        chunks = {},
    }
    local store, db = loadStore({ db = { position_payload = duplicate } })
    T.equal(db.position_payload, duplicate)
    T.equal(store:GetStatus().blocked_reason, "GUID dictionary contains a duplicate entry")
end)

add("oversized GUID dictionary blocks capture without mutation", function()
    local guids = {}
    for i = 1, 1297 do guids[i] = tostring(i) end
    local oversized = {
        schema_version = 1,
        encoding = "b36-v1",
        guids = guids,
        chunks = {},
    }
    local store, db = loadStore({ db = { position_payload = oversized } })
    T.equal(db.position_payload, oversized)
    T.equal(store:GetStatus().blocked_reason, "GUID dictionary exceeds its supported size")
end)

add("desktop deletion resets the payload on the next hydrate", function()
    local store, db = loadStore()
    T.truthy(store:AppendTick("1786244400000", 631, {
        pos("0x0000000000000001", 0.25, 0.75),
    }))
    db.position_payload = nil
    store:Hydrate()
    T.equal(store:GetStatus().tick_count, 0)
    T.equal(#db.position_payload.guids, 0)
end)

add("missing bridge blocks all writes without creating a fallback payload", function()
    local store, db, warnings, account = loadStore({ missingBridge = true })
    T.falsy(store:IsReady())
    T.falsy(store:AppendTick("1786244400000", 537, { pos("0x1", 0.2, 0.3) }))
    store:RecordMissing(5)
    T.equal(db.position_payload, nil)
    T.equal(account.position_payload, nil)
    T.falsy(store:GetStatus().ready)
    T.contains(store:GetStatus().blocked_reason, "not loaded")
    T.equal(#warnings, 1)
end)

add("missing or incompatible bridge database is preserved", function()
    local store, db = loadStore({ db = { storage_version = 99 } })
    T.falsy(store:IsReady())
    T.equal(db.position_payload, nil)
    T.equal(store:GetStatus().blocked_reason, "unsupported bridge storage version")
    _G.ChronicleSidekickBridgeWoTLKDB = nil
    T.falsy(store:Hydrate())
    T.equal(_G.ChronicleSidekickBridgeWoTLKDB, nil)
    T.equal(store:GetStatus().blocked_reason, "bridge database is not a table")
end)

add("legacy capture migrates once without changing main settings", function()
    local oldStore, oldDB = loadStore()
    T.truthy(oldStore:AppendTick("1786244400000", 537, { pos("0x1", 0.2, 0.3) }))
    local legacy = oldDB.position_payload
    local account = { position_payload = legacy, unrelated = "keep" }
    local store, db = loadStore({ account = account })
    T.truthy(store:IsReady())
    T.equal(db.position_payload, legacy)
    T.equal(account.position_payload, nil)
    T.equal(account.unrelated, "keep")
    T.equal(store:GetStatus().tick_count, 1)
    T.truthy(store:Hydrate())
    T.equal(store:GetStatus().tick_count, 1)
end)

add("invalid legacy capture is not deleted during migration", function()
    local legacy = { schema_version = 99 }
    local account = { position_payload = legacy }
    local store, db = loadStore({ account = account })
    T.falsy(store:IsReady())
    T.equal(account.position_payload, legacy)
    T.equal(db.position_payload, nil)
end)

add("conflicting legacy and bridge data blocks capture without replacing either", function()
    local oldStore, oldDB = loadStore()
    local legacy = oldDB.position_payload
    local account = { position_payload = legacy }
    local destination = { storage_version = 1, position_payload = { preserve = true } }
    local store, db = loadStore({ db = destination, account = account })
    T.falsy(store:IsReady())
    T.equal(db.position_payload.preserve, true)
    T.equal(account.position_payload, legacy)
    T.contains(store:GetStatus().blocked_reason, "both legacy and bridge")
end)

add("explicit clear resets counters, GUIDs and blocks while preserving unrelated data", function()
    local store, db, _, account = loadStore()
    T.truthy(store:AppendTick("1786244400000", 537, { pos("0x1", 0.2, 0.3) }))
    store:RecordMissing(10)
    db.other_payload = "keep"
    T.truthy(store:CanClear())
    T.truthy(store:Clear())
    local status = store:GetStatus()
    T.equal(status.tick_count, 0)
    T.equal(status.guid_count, 0)
    T.equal(status.chunk_count, 0)
    T.equal(status.encoded_bytes, 0)
    T.equal(status.missing_positions, 0)
    T.falsy(status.capped)
    T.equal(db.other_payload, "keep")
    T.equal(account.unrelated, "main settings")
    T.truthy(store:AppendTick("1786244401000", 537, { pos("0x2", 0.4, 0.5) }))
    T.equal(db.position_payload.guids[1], "0x2")
end)

add("explicit clear recovers conflicting or unreadable positions and removes legacy history", function()
    local legacy = { schema_version = 99 }
    local account = { position_payload = legacy, setting = "keep" }
    local store, db = loadStore({ account = account, db = { storage_version = 1, position_payload = false } })
    T.falsy(store:IsReady())
    T.truthy(store:CanClear())
    T.truthy(store:Clear())
    T.equal(account.position_payload, nil)
    T.equal(account.setting, "keep")
    T.equal(db.position_payload.tick_count, 0)
    T.truthy(store:IsReady())
end)

add("clear refuses absent or incompatible bridge without deleting data", function()
    for _, options in ipairs({ { missingBridge = true }, { db = { storage_version = 99 } } }) do
        local legacy = { keep = true }
        options.account = { position_payload = legacy }
        local store, db, _, account = loadStore(options)
        T.falsy(store:CanClear())
        T.falsy(store:Clear())
        T.equal(account.position_payload, legacy)
        T.equal(db.position_payload, nil)
    end
end)

return cases
