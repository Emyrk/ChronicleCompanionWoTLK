local T = _G.Test
local cases = {}

local SELF_GUID = "0x0000000000000001"
local PEER_GUID = "0x0000000000000002"

local function add(name, run)
    cases[#cases + 1] = { name = name, run = run }
end

local function loadProvider(options)
    options = options or {}
    local handlers = {}
    local notified = {}
    local now = 1000
    local uptime = 10

    local function optionalSegment(value, prefix)
        if not value then return nil end
        return prefix
    end

    _G.Chronicle = {
        C = { IDENTITY_RETRY_SEC = 5 },
        Logger = { Debug = function() end },
        Relay = {
            Kick = function() end,
            RegisterProvider = function(_, provider)
                Chronicle.PlayerListProvider = provider
            end,
        },
        Capture = {
            ScanGear = function() return {} end,
            ScanTalents = options.scanTalents or function() return nil end,
            ScanGlyphs = function() return nil end,
            ScanGuild = function() return nil end,
            ScanPet = options.scanPet or function() return nil end,
            ScanHonor = function() return nil end,
            ScanArenaTeams = function() return nil end,
        },
        CIFormat = {
            Identity = function() return "I" end,
            Gear = function() return "G" end,
            Talents = function(value) return optionalSegment(value, "T") end,
            Glyphs = function(value) return optionalSegment(value, "Y") end,
            Guild = function(value) return optionalSegment(value, "U") end,
            Pet = function(value) return optionalSegment(value, "E") end,
            Honor = function(value) return optionalSegment(value, "H") end,
            Arena = function(value) return optionalSegment(value, "A") end,
            Wrap = function(guid, segment) return "P" .. guid .. ";" .. segment end,
        },
        Util = {},
        RegisterEvent = function(event, fn) handlers[event] = fn end,
    }

    _G.time = function() return now end
    _G.GetTime = function() return uptime end
    _G.UnitGUID = function(unit)
        if unit == "player" then return SELF_GUID end
        if unit == "raid1" then return PEER_GUID end
        return nil
    end
    _G.UnitName = function(unit)
        if unit == "player" then return "Self" end
        if unit == "raid1" then return "Peer" end
        return nil
    end
    _G.UnitClass = function() return "Warrior", "WARRIOR" end
    _G.UnitRace = function() return "Human", "Human" end
    _G.UnitSex = function() return 2 end
    _G.UnitLevel = function() return 80 end
    _G.UnitExists = function(unit) return unit == "raid1" end
    _G.UnitIsVisible = function() return true end
    _G.UnitIsConnected = function() return true end
    _G.CanInspect = function() return true end
    _G.CheckInteractDistance = function() return true end
    _G.NotifyInspect = function(unit) notified[#notified + 1] = unit end
    _G.GetNumRaidMembers = function() return 1 end
    _G.GetNumPartyMembers = function() return 0 end
    _G.GetActiveTalentGroup = nil

    dofile("Providers/PlayerListProvider.lua")

    local function setUptime(value)
        uptime = value
    end
    return Chronicle.PlayerListProvider, handlers, notified, setUptime
end

local function cleanAllSegments(provider)
    local state = provider:GetState()
    for _, player in pairs(state.players) do
        for _, segment in pairs(player.segs) do
            segment.dirty = false
            segment.lastEmitAt = 1000
        end
    end
    return state.players[PEER_GUID]
end

add("rejected inspected talents remain dirty and request another inspect", function()
    local provider, handlers, notified, setUptime = loadProvider()
    handlers.PLAYER_LOGIN()
    local peer = cleanAllSegments(provider)
    peer.segs.T.dirty = true

    provider:Poll()
    T.equal(#notified, 1)
    T.equal(notified[1], "raid1")

    handlers.INSPECT_TALENT_READY()
    provider:Poll()

    T.truthy(peer.segs.T.dirty)
    T.equal(peer.segs.T.lastEmitAt, 705)

    setUptime(20)
    provider:Poll()
    T.equal(#notified, 2)
end)

add("legitimately absent optional peer data is marked clean", function()
    local provider, handlers = loadProvider()
    handlers.PLAYER_LOGIN()
    local peer = cleanAllSegments(provider)
    peer.segs.E.dirty = true

    provider:Poll()

    T.falsy(peer.segs.E.dirty)
    T.equal(peer.segs.E.lastEmitAt, 1000)
end)

return cases
