-- =============================================================================
-- Capture/VehicleInspect.lua
--
-- Permanent diagnostics for proving vehicle-to-controller attribution. Stock
-- CLEU identifies the actor GUID but does not include an owner GUID, so this
-- tool snapshots the unit-token relationship and correlates it with live CLEU.
-- It never adds combat events to the relay.
-- =============================================================================

local C = Chronicle.C
local Log = Chronicle.Logger
local V = {}
Chronicle.VehicleInspect = V

local watching = false
local watchSink = nil
local history = {}
local mappings = {}
local mappingOrder = {}

local VEHICLE_EVENTS = {
    "UNIT_ENTERING_VEHICLE",
    "UNIT_ENTERED_VEHICLE",
    "UNIT_EXITING_VEHICLE",
    "UNIT_EXITED_VEHICLE",
    "VEHICLE_PASSENGERS_CHANGED",
    "PLAYER_GAINS_VEHICLE_DATA",
    "PLAYER_LOSES_VEHICLE_DATA",
    "VEHICLE_UPDATE",
    "UNIT_PET",
    "PLAYER_ENTERING_WORLD",
}

local function api(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c, d, e, f
end

local function defaultSink(text)
    Log:Info("%s", text)
end

local function emitTo(sink, text)
    local fn = sink or defaultSink
    local ok, err = pcall(fn, text)
    if not ok then
        Log:Warn("Vehicle inspect output failed: %s", tostring(err))
    end
end

local function addHistory(kind, text)
    history[#history + 1] = {
        at = api("GetTime") or 0,
        kind = kind,
        text = text,
    }
    if #history > C.VEHICLE_INSPECT_RECORD_MAX then
        table.remove(history, 1)
    end
end

local function emitRecord(kind, text, sink)
    addHistory(kind, text)
    emitTo(sink, text)
end

local function boolText(value)
    return value and "true" or "false"
end

local function unitSnapshot(unit)
    return {
        unit = unit,
        exists = api("UnitExists", unit) and true or false,
        name = api("UnitName", unit),
        guid = api("UnitGUID", unit),
        in_vehicle = api("UnitInVehicle", unit) and true or false,
        has_vehicle_ui = api("UnitHasVehicleUI", unit) and true or false,
        using_vehicle = api("UnitUsingVehicle", unit) and true or false,
    }
end

local function rememberGUID(guid, pair, role)
    if not guid or guid == "" then return end
    if not mappings[guid] then
        mappingOrder[#mappingOrder + 1] = guid
    end
    mappings[guid] = { pair = pair, role = role }

    while #mappingOrder > C.VEHICLE_INSPECT_MAPPING_MAX do
        local expiredGUID = table.remove(mappingOrder, 1)
        mappings[expiredGUID] = nil
    end
end

local function rememberMapping(pair)
    rememberGUID(pair.vehicle.guid, pair, "vehicle")
    rememberGUID(pair.controller.guid, pair, "controller")
end

local function addPair(snapshot, baseUnit, vehicleUnit, context)
    local controller = unitSnapshot(baseUnit)
    local vehicle = unitSnapshot(vehicleUnit)
    if not vehicle.exists or not vehicle.guid then return end

    local pair = {
        context = context,
        controller = controller,
        vehicle = vehicle,
        captured_at = snapshot.captured_at,
        reason = snapshot.reason,
    }
    snapshot.pairs[#snapshot.pairs + 1] = pair
    rememberMapping(pair)
end

local function isFrameShown(frame)
    if not frame or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown and true or false
end

local function scanSeats(snapshot)
    for i = 1, C.VEHICLE_SEAT_BUTTON_MAX do
        local button = _G["VehicleSeatIndicatorButton" .. i]
        if isFrameShown(button) and button.virtualID then
            local controlType, occupantName, serverName, ejectable, canSwitch =
                api("UnitVehicleSeatInfo", "player", button.virtualID)
            snapshot.seats[#snapshot.seats + 1] = {
                button = i,
                virtual_id = button.virtualID,
                control_type = controlType,
                occupant_name = occupantName,
                server_name = serverName,
                ejectable = ejectable and true or false,
                can_switch = canSwitch and true or false,
            }
        end
    end
end

local function buildSnapshot(reason)
    local snapshot = {
        captured_at = api("GetTime") or 0,
        reason = reason or "manual",
        pairs = {},
        seats = {},
    }

    local localVehicleGUID = api("UnitGUID", "vehicle")
    if localVehicleGUID then
        addPair(snapshot, "player", "vehicle", "local")
    end

    local petGUID = api("UnitGUID", "pet")
    local petIsVehicle = api("UnitIsUnit", "pet", "vehicle")
    if petGUID and (petIsVehicle or petGUID == localVehicleGUID) then
        addPair(snapshot, "player", "pet", "local-alias")
    end

    for i = 1, C.PARTY_MEMBER_MAX do
        local baseUnit = "party" .. i
        if api("UnitHasVehicleUI", baseUnit) then
            addPair(snapshot, baseUnit, "partypet" .. i, "party")
        end
    end

    for i = 1, C.RAID_MEMBER_MAX do
        local baseUnit = "raid" .. i
        local targetsVehicle = api("UnitTargetsVehicleInRaidUI", baseUnit)
        if targetsVehicle or api("UnitHasVehicleUI", baseUnit) then
            addPair(snapshot, baseUnit, "raidpet" .. i, "raid")
        end
    end

    scanSeats(snapshot)
    return snapshot
end

function V:WriteSnapshot(snapshot, sink)
    emitRecord("snapshot", "-- Vehicle snapshot: " .. snapshot.reason .. " --", sink)
    if #snapshot.pairs == 0 then
        emitRecord("snapshot", "  No vehicle unit-token pairs are currently visible", sink)
    end

    for i = 1, #snapshot.pairs do
        local pair = snapshot.pairs[i]
        local controller = pair.controller
        local vehicle = pair.vehicle
        emitRecord("snapshot", string.format(
            "  %s: %s=%s (%s) -> %s=%s (%s)",
            pair.context,
            controller.unit, tostring(controller.name), tostring(controller.guid),
            vehicle.unit, tostring(vehicle.name), tostring(vehicle.guid)), sink)
        emitRecord("snapshot", string.format(
            "    controller in=%s ui=%s using=%s | vehicle in=%s ui=%s using=%s",
            boolText(controller.in_vehicle), boolText(controller.has_vehicle_ui),
            boolText(controller.using_vehicle), boolText(vehicle.in_vehicle),
            boolText(vehicle.has_vehicle_ui), boolText(vehicle.using_vehicle)), sink)
    end

    for i = 1, #snapshot.seats do
        local seat = snapshot.seats[i]
        emitRecord("seat", string.format(
            "  seat button=%d virtual=%s control=%s occupant=%s realm=%s eject=%s switch=%s",
            seat.button, tostring(seat.virtual_id), tostring(seat.control_type),
            tostring(seat.occupant_name), tostring(seat.server_name),
            boolText(seat.ejectable), boolText(seat.can_switch)), sink)
    end
end

function V:Snapshot(reason, sink)
    local snapshot = buildSnapshot(reason or "manual")
    self:WriteSnapshot(snapshot, sink)
    return snapshot
end

function V:StartWatch(sink)
    watching = true
    watchSink = sink or defaultSink
    emitRecord("status", "Vehicle watch started; matching CLEU and transition events will be shown", watchSink)
    self:Snapshot("watch-start", watchSink)
end

function V:StopWatch(sink)
    local output = sink or watchSink
    if not watching then
        emitTo(output, "Vehicle watch is not running")
        return
    end
    emitRecord("status", "Vehicle watch stopped", output)
    watching = false
    watchSink = nil
end

function V:IsWatching()
    return watching
end

function V:Clear(sink)
    history = {}
    mappings = {}
    mappingOrder = {}
    emitTo(sink or watchSink, "Vehicle inspect history and GUID mappings cleared")
end

function V:Dump(sink)
    local output = sink or watchSink
    emitTo(output, string.format("-- Vehicle inspect history: %d records --", #history))
    local first = #history - C.VEHICLE_INSPECT_DUMP_MAX + 1
    if first < 1 then first = 1 end
    for i = first, #history do
        local record = history[i]
        emitTo(output, string.format("  [%s %.3f] %s", record.kind, record.at, record.text))
    end
end

local function eventArgsText(event, ...)
    local values = {}
    for i = 1, select("#", ...) do
        values[#values + 1] = "arg" .. i .. "=" .. tostring(select(i, ...))
    end
    if #values == 0 then
        return event .. " (no args)"
    end
    return event .. " " .. table.concat(values, " ")
end

local function onVehicleEvent(event, ...)
    if not watching then return end

    emitRecord("event", eventArgsText(event, ...), watchSink)
    V:Snapshot(event, watchSink)

    Chronicle.RunNextFrame(function()
        if watching then
            V:Snapshot(event .. ":next-frame", watchSink)
        end
    end)
end

local function describeMatch(guid, cleuSide)
    local match = mappings[guid]
    if not match then return nil end
    local pair = match.pair
    return string.format("%s-%s vehicle=%s controller=%s", cleuSide,
        match.role, tostring(pair.vehicle.guid), tostring(pair.controller.guid))
end

local function onCLEU(event, ...)
    if not watching then return end

    local subevent = select(2, ...)
    local sourceGUID = select(3, ...)
    local sourceName = select(4, ...)
    local sourceFlags = select(5, ...)
    local destGUID = select(6, ...)
    local destName = select(7, ...)
    local destFlags = select(8, ...)
    local sourceMatch = describeMatch(sourceGUID, "source")
    local destMatch = describeMatch(destGUID, "dest")
    if not sourceMatch and not destMatch then return end

    emitRecord("cleu", string.format(
        "CLEU %s src=%s/%s flags=%s dst=%s/%s flags=%s match=%s%s",
        tostring(subevent), tostring(sourceName), tostring(sourceGUID),
        tostring(sourceFlags), tostring(destName), tostring(destGUID),
        tostring(destFlags), sourceMatch or "",
        destMatch and (sourceMatch and "; " or "") .. destMatch or ""), watchSink)
end

for i = 1, #VEHICLE_EVENTS do
    Chronicle.RegisterEvent(VEHICLE_EVENTS[i], onVehicleEvent)
end
Chronicle.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCLEU)
