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
    -- Field limits  (Warmane 3.3.5a -- confirmed by DispatchProbe)
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
    IDENTITY_RETRY_SEC = 3,    -- fast re-poll when UnitName/UnitClass return nil

    -- -----------------------------------------------------------------
    -- CLEU constants
    -- -----------------------------------------------------------------
    RELAY_FAILEDTYPE_ARG = 12, -- select(12, ...) in SPELL_CAST_FAILED

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
