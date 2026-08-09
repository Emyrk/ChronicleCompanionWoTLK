-- =============================================================================
-- Capture/VehicleTracker.lua
--
-- Tracks the time-dependent relationship between player GUIDs and the vehicle
-- or turret GUIDs they control. Repeated vehicle events are reconciled against
-- current state, so an unchanged assignment produces no duplicate change.
-- =============================================================================

local C = Chronicle.C
local T = {}
Chronicle.VehicleTracker = T

local activeByVehicle = {}
local listeners = {}
local nextFramePending = false
local epochAnchor = time()
local uptimeAnchor = GetTime()

local REFRESH_EVENTS = {
    "UNIT_ENTERING_VEHICLE",
    "UNIT_ENTERED_VEHICLE",
    "UNIT_EXITING_VEHICLE",
    "UNIT_EXITED_VEHICLE",
    "VEHICLE_PASSENGERS_CHANGED",
    "PLAYER_GAINS_VEHICLE_DATA",
    "PLAYER_LOSES_VEHICLE_DATA",
    "VEHICLE_UPDATE",
    "UNIT_PET",
    "RAID_ROSTER_UPDATE",
    "PARTY_MEMBERS_CHANGED",
}

local function api(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c
end

local function timestampMs()
    local elapsed = (api("GetTime") or uptimeAnchor) - uptimeAnchor
    local wholeSeconds = math.floor(elapsed)
    local milliseconds = math.floor((elapsed - wholeSeconds) * 1000 + 0.5)
    if milliseconds >= 1000 then
        wholeSeconds = wholeSeconds + 1
        milliseconds = 0
    end

    -- Avoid formatting a 13-digit value through %d: WoW's Lua 5.1 build can
    -- route integer formats through a 32-bit C integer. Joining epoch seconds
    -- and a zero-padded fraction keeps the millisecond timestamp exact.
    return tostring(epochAnchor + wholeSeconds) .. string.format("%03d", milliseconds)
end

local function contextRank(context)
    if context == "local" then return 1 end
    if context == "local-alias" then return 2 end
    if context == "party" then return 3 end
    return 4
end

local function observePair(observed, controllerUnit, vehicleUnit, context)
    local controllerGUID = api("UnitGUID", controllerUnit)
    local vehicleGUID = api("UnitGUID", vehicleUnit)
    if not controllerGUID or not vehicleGUID then return end

    local current = observed[vehicleGUID]
    if current and contextRank(current.context) <= contextRank(context) then return end

    observed[vehicleGUID] = {
        vehicle_guid = vehicleGUID,
        vehicle_name = api("UnitName", vehicleUnit) or "",
        controller_guid = controllerGUID,
        controller_name = api("UnitName", controllerUnit) or "",
        controller_unit = controllerUnit,
        vehicle_unit = vehicleUnit,
        context = context,
    }
end

local function scanVisible()
    local observed = {}
    local localVehicleGUID = api("UnitGUID", "vehicle")

    if localVehicleGUID then
        observePair(observed, "player", "vehicle", "local")
    end

    local petGUID = api("UnitGUID", "pet")
    local petIsVehicle = api("UnitIsUnit", "pet", "vehicle")
    if petGUID and (petIsVehicle or petGUID == localVehicleGUID) then
        observePair(observed, "player", "pet", "local-alias")
    end

    for i = 1, C.PARTY_MEMBER_MAX do
        local controllerUnit = "party" .. i
        -- partypetN is also the normal hunter/warlock pet token. The vehicle UI
        -- flag alone is not reliable enough on this client; UnitUsingVehicle
        -- distinguishes an actively controlled vehicle from an ordinary pet.
        if api("UnitUsingVehicle", controllerUnit)
            and api("UnitHasVehicleUI", controllerUnit)
        then
            observePair(observed, controllerUnit, "partypet" .. i, "party")
        end
    end

    for i = 1, C.RAID_MEMBER_MAX do
        local controllerUnit = "raid" .. i
        local targetsVehicle = api("UnitTargetsVehicleInRaidUI", controllerUnit)
        if api("UnitUsingVehicle", controllerUnit)
            and (targetsVehicle or api("UnitHasVehicleUI", controllerUnit))
        then
            observePair(observed, controllerUnit, "raidpet" .. i, "raid")
        end
    end

    return observed
end

local function notify(change)
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], change)
        if not ok and Chronicle.Logger then
            Chronicle.Logger:Warn("VehicleTracker listener failed: %s", tostring(err))
        end
    end
end

local function releaseAssignment(assignment, observedAt, reason)
    notify({
        action = "release",
        timestamp_ms = observedAt,
        reason = reason,
        vehicle_guid = assignment.vehicle_guid,
        vehicle_name = assignment.vehicle_name,
        controller_guid = assignment.controller_guid,
        controller_name = assignment.controller_name,
        controller_unit = assignment.controller_unit,
        vehicle_unit = assignment.vehicle_unit,
        context = assignment.context,
    })
end

local function assignVehicle(assignment, observedAt, reason)
    assignment.assigned_at_ms = observedAt
    assignment.reason = reason
    notify({
        action = "assign",
        timestamp_ms = observedAt,
        reason = reason,
        vehicle_guid = assignment.vehicle_guid,
        vehicle_name = assignment.vehicle_name,
        controller_guid = assignment.controller_guid,
        controller_name = assignment.controller_name,
        controller_unit = assignment.controller_unit,
        vehicle_unit = assignment.vehicle_unit,
        context = assignment.context,
    })
end

--- Reconcile visible unit-token pairs against the active control state.
--- @tparam[opt] string reason event or caller that triggered the refresh
function T:Refresh(reason)
    local observedAt = timestampMs()
    local observed = scanVisible()

    for vehicleGUID, previous in pairs(activeByVehicle) do
        local current = observed[vehicleGUID]
        if not current or current.controller_guid ~= previous.controller_guid then
            releaseAssignment(previous, observedAt, reason or "refresh")
        end
    end

    for vehicleGUID, current in pairs(observed) do
        local previous = activeByVehicle[vehicleGUID]
        if not previous or previous.controller_guid ~= current.controller_guid then
            assignVehicle(current, observedAt, reason or "refresh")
        elseif current.vehicle_name ~= "" then
            previous.vehicle_name = current.vehicle_name
            previous.controller_name = current.controller_name
            previous.controller_unit = current.controller_unit
            previous.vehicle_unit = current.vehicle_unit
            previous.context = current.context
            observed[vehicleGUID] = previous
        end
    end

    activeByVehicle = observed
end

--- Register a callback for deduplicated assign and release changes.
--- @tparam function fn callback receiving one change table
function T:RegisterListener(fn)
    if type(fn) ~= "function" then return end
    for i = 1, #listeners do
        if listeners[i] == fn then return end
    end
    listeners[#listeners + 1] = fn
end

--- Return current vehicle GUID to controller assignment state.
--- @treturn table assignments keyed by vehicle GUID
function T:GetActiveAssignments()
    return activeByVehicle
end

local function scheduleNextFrame(reason)
    if nextFramePending then return end
    nextFramePending = true
    Chronicle.RunNextFrame(function()
        nextFramePending = false
        T:Refresh(reason .. ":next-frame")
    end)
end

local function onRefreshEvent(event)
    T:Refresh(event)
    scheduleNextFrame(event)
end

for i = 1, #REFRESH_EVENTS do
    Chronicle.RegisterEvent(REFRESH_EVENTS[i], onRefreshEvent)
end

Chronicle.RegisterEvent("PLAYER_ENTERING_WORLD", function(event)
    scheduleNextFrame(event)
end)
