-- =============================================================================
-- Providers/VehicleProvider.lua
--
-- Queues timestamped vehicle control changes from VehicleTracker. The observed
-- timestamp travels with the record because the relay may land it much later.
--
-- Payload format:
--   V<timestampMs>,<A|R>,<vehicleGuid>,<controllerGuid>,<vehicleName>,<controllerName>
-- =============================================================================

local C = Chronicle.C
local Log = Chronicle.Logger
local Relay = Chronicle.Relay
local Tracker = Chronicle.VehicleTracker
local Util = Chronicle.Util

local P = {
    priority = C.VEHICLE_PROVIDER_PRIORITY,
}

local queue = {}
local lastEmitAt = 0

local function wireName(value)
    return Util.Sanitize(value or ""):gsub(",", " ")
end

local function enqueue(change)
    if #queue >= C.VEHICLE_CHANGE_QUEUE_MAX then
        table.remove(queue, 1)
        Log:Warn("VehicleProvider: queue full, dropped oldest control change")
    end
    queue[#queue + 1] = change
    Relay:Kick()
end

--- Return the relay provider label.
--- @treturn string provider label
function P:Label()
    return "Vehicle"
end

--- Return the number of queued vehicle changes.
--- @treturn number pending change count
function P:Dirty()
    return #queue
end

--- Pop and format the oldest observed vehicle change.
--- @treturn string|nil payload
--- @treturn string|nil summary
function P:Poll()
    if #queue == 0 then return nil end

    local change = table.remove(queue, 1)
    local action = change.action == "release" and "R" or "A"
    local payload = string.format("V%s,%s,%s,%s,%s,%s",
        change.timestamp_ms or "0",
        action,
        change.vehicle_guid or "",
        change.controller_guid or "",
        wireName(change.vehicle_name),
        wireName(change.controller_name))

    lastEmitAt = time()
    local summary = string.format("VEH %s %s>%s",
        action, change.controller_name or "?", change.vehicle_name or "?")
    return payload, summary
end

--- Return provider queue and active tracker state for diagnostics.
--- @treturn table provider state
function P:GetState()
    return {
        queue = queue,
        lastEmitAt = lastEmitAt,
        active = Tracker:GetActiveAssignments(),
    }
end

Tracker:RegisterListener(enqueue)
Relay:RegisterProvider(P)
Chronicle.VehicleProvider = P
