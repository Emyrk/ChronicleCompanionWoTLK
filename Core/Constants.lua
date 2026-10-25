-- =============================================================================
-- Core/Constants.lua
--
-- All tunables and magic values for the addon.  Every number that
-- appears in a module body should trace back here.
-- =============================================================================

Chronicle.C = {
    -- -----------------------------------------------------------------
    -- Wire protocol
    -- -----------------------------------------------------------------
    -- Messages are framed as [N...payload...]  where N is 0-9.
    -- The server accumulates between [N and ].  A new [M before ]
    -- means the previous message was dropped.
    MSG_OPEN        = "[",
    MSG_CLOSE       = "]",
    MSG_CONTINUE    = "~",     -- prefix on middle/last chunks (not first)
    MSG_COUNTER_MAX = 9,       -- wraps: 0,1,2,...,9,0,1,...

    -- -----------------------------------------------------------------
    -- Field limits  (Warmane 3.3.5a -- confirmed by live channel testing)
    -- -----------------------------------------------------------------
    FIELD_MAX_CHARS = 245,     -- engine truncates failedType beyond this

    -- Budget per slot position:
    --   single-slot message: [N + payload + ]  = 242 usable
    --   first chunk:         [N + payload      = 243 usable
    --   middle chunk:        ~  + payload      = 244 usable
    --   last chunk:          ~  + payload + ]  = 243 usable
    -- We use 242 as the "short message" threshold for bin-packing.
    -- If a message (with framing) is <= this, we try to fit a second
    -- message in the same slot.
    BIN_PACK_THRESHOLD = 230,  -- if framed msg <= this, try packing another

    -- -----------------------------------------------------------------
    -- Scan / retry timing
    -- -----------------------------------------------------------------
    RELAY_ACTIVATION_DELAY_SEC = 5,   -- let the combat-log file writer settle
    HEADER_INITIAL_REEMIT_SEC  = 60,  -- quick recovery copy after first header
    HEADER_REEMIT_SEC          = 300, -- steady-state header refresh
    IDENTITY_RETRY_SEC = 3,    -- fast re-poll when UnitName/UnitClass return nil

    -- -----------------------------------------------------------------
    -- CLEU constants
    -- -----------------------------------------------------------------
    RELAY_FAILEDTYPE_ARG = 12, -- select(12, ...) in SPELL_CAST_FAILED

    -- -----------------------------------------------------------------
    -- Provider priorities
    -- -----------------------------------------------------------------
    VEHICLE_PROVIDER_PRIORITY    = 3,
    RAID_GROUP_PROVIDER_PRIORITY = 6,
    META_PROVIDER_PRIORITY       = 7,

    -- -----------------------------------------------------------------
    -- Raid composition
    -- -----------------------------------------------------------------
    -- Eight fixed five-player groups preserve subgroup boundaries. Roster
    -- events can precede raid-unit hydration, so retry briefly before emit.
    RAID_GROUP_MAX                = 8,
    RAID_GROUP_SLOT_MAX           = 5,
    RAID_GROUP_RETRY_SEC          = 0.25,
    RAID_GROUP_RETRY_MAX_ATTEMPTS = 8,

    -- -----------------------------------------------------------------
    -- Vehicle attribution
    -- -----------------------------------------------------------------
    VEHICLE_CHANGE_QUEUE_MAX = 100,

    -- -----------------------------------------------------------------
    -- Vehicle inspect diagnostics
    -- -----------------------------------------------------------------
    PARTY_MEMBER_MAX            = 4,
    RAID_MEMBER_MAX             = 40,
    VEHICLE_SEAT_BUTTON_MAX     = 10,
    VEHICLE_INSPECT_RECORD_MAX  = 100,
    VEHICLE_INSPECT_MAPPING_MAX = 100,
    INSPECT_OUTPUT_LINE_MAX      = 500,
    VEHICLE_INSPECT_DUMP_MAX    = 40,

    -- -----------------------------------------------------------------
    -- Position telemetry SavedVariables
    --
    -- Positions and percentage vitals are captured once per second only while
    -- both combat logging and player combat are active. Max health, max power,
    -- and power type are emitted separately on first observation and change.
    -- Fifty units for one continuous hour are about 2.2 MiB encoded.
    -- -----------------------------------------------------------------
    POSITION_BRIDGE_ADDON          = "ChronicleSidekickBridgeWoTLK",
    POSITION_BRIDGE_STORAGE_VERSION = 1,
    POSITION_SCHEMA_VERSION        = 2,
    POSITION_SAMPLE_INTERVAL_SEC   = 1,
    POSITION_UNIT_MAX              = 50,
    POSITION_BLOCK_TICKS           = 60,
    POSITION_STATE_BLOCK_RECORDS   = 60,
    POSITION_GUID_INDEX_WIDTH      = 2,
    POSITION_GUID_MAX              = 1296,     -- 36^2 dictionary entries
    POSITION_COORD_SCALE           = 10000,
    POSITION_COORD_WIDTH           = 3,
    POSITION_MAP_WIDTH             = 3,
    POSITION_VITAL_PERCENT_SCALE   = 1000,     -- 0.1% resolution
    POSITION_VITAL_PERCENT_WIDTH   = 2,
    POSITION_VITAL_PERCENT_UNKNOWN = 1295,     -- "zz"
    POSITION_VITAL_MAX_WIDTH       = 5,
    POSITION_VITAL_MAX_UNKNOWN     = 60466175, -- "zzzzz"
    POSITION_POWER_TYPE_WIDTH      = 1,
    POSITION_POWER_TYPE_UNKNOWN    = 35,       -- "z"
    POSITION_STORE_WARN_BYTES      = 3145728, -- 3 MiB
    POSITION_STORE_CRITICAL_BYTES  = 3670016, -- 3.5 MiB
    POSITION_STORE_MAX_BYTES       = 4128768, -- 4 MiB file budget less 64 KiB syntax margin
    POSITION_MISSING_WARN_SAMPLES  = 10,

    -- -----------------------------------------------------------------
    -- SPELL_FAILED_* globals to hijack
    --
    -- 44 globals.  The engine
    -- reads the Lua global at CLEU emission time (not a cached C
    -- string), so overwriting these immediately changes what lands
    -- in WoWCombatLog.txt for ALL players on this client -- not just
    -- the local player.
    --
    -- Note: "Not enough rage/energy/mana" have NO matching Lua
    -- global -- the engine formats those C-side.  Those events
    -- will always produce a miss (we re-arm same chunk).
    -- -----------------------------------------------------------------
    HIJACK_GLOBALS = {
        -- Targeting
        "SPELL_FAILED_BAD_TARGETS",
        "SPELL_FAILED_BAD_IMPLICIT_TARGETS",
        "SPELL_FAILED_TARGET_FRIENDLY",
        "SPELL_FAILED_TARGET_ENEMY",
        "SPELL_FAILED_INVALID_TARGET",
        "SPELL_FAILED_NO_TARGETS",
        "SPELL_FAILED_TARGETS_DEAD",
        "SPELL_FAILED_CANT_CAST_ON_TAPPED",
        -- Range / positioning
        "SPELL_FAILED_OUT_OF_RANGE",
        "SPELL_FAILED_LINE_OF_SIGHT",
        "SPELL_FAILED_UNIT_NOT_INFRONT",
        "SPELL_FAILED_NOT_INFRONT",
        "SPELL_FAILED_NOT_BEHIND",
        "SPELL_FAILED_TOO_CLOSE",
        "SPELL_FAILED_NOT_HERE",
        -- Readiness / cooldown
        "SPELL_FAILED_NOT_READY",
        "SPELL_FAILED_ITEM_NOT_READY",
        "SPELL_FAILED_SPELL_IN_PROGRESS",
        "SPELL_FAILED_UNKNOWN_SPELL",
        "SPELL_FAILED_SPELL_UNAVAILABLE",
        "SPELL_FAILED_NO_SPELL",
        "SPELL_FAILED_LOW_CASTLEVEL",
        -- Crowd control / incapacitation
        "SPELL_FAILED_INTERRUPTED",
        "SPELL_FAILED_INTERRUPTED_COMBAT",
        "SPELL_FAILED_SILENCED",
        "SPELL_FAILED_STUNNED",
        "SPELL_FAILED_CHARMED",
        "SPELL_FAILED_CONFUSED",
        "SPELL_FAILED_FLEEING",
        "SPELL_FAILED_PACIFIED",
        "SPELL_FAILED_IMMUNE",
        -- Movement / state
        "SPELL_FAILED_MOVING",
        "SPELL_FAILED_AFFECTING_COMBAT",
        "SPELL_FAILED_CASTER_DEAD",
        "SPELL_FAILED_CASTER_AURASTATE",
        "SPELL_FAILED_ONLY_STEALTHED",
        -- Resource / cap
        "SPELL_FAILED_NO_COMBO_POINTS",
        "SPELL_FAILED_ALREADY_AT_FULL_HEALTH",
        "SPELL_FAILED_ALREADY_AT_FULL_POWER",
        "SPELL_FAILED_MOREPOWERFULSPELLACTIVE",
        "SPELL_FAILED_TOO_MANY_OF_ITEM",
        -- Equipment
        -- EQUIPPED_ITEM_CLASS carries the fishing-pole failure
        -- ("Must have a Fishing Pole equipped") so a /cast Fishing
        -- macro can flush the relay queue out of combat.
        "SPELL_FAILED_EQUIPPED_ITEM_CLASS",
        -- Generic / fallback
        "SPELL_FAILED_ERROR",
        "SPELL_FAILED_TRY_AGAIN",
    },
}
